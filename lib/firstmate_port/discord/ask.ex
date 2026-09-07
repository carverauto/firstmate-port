defmodule FirstmatePort.Discord.Ask do
  @moduledoc """
  The wire shapes for asking the captain a question in Discord and reading the
  answer back. Pure: it builds and parses maps, and talks to nothing.

  A question goes out as a message carrying a string select. The captain's pick
  comes back as a `MESSAGE_COMPONENT` interaction on the same `custom_id`, and
  the endpoint answers it by editing that message in place, so the question
  visibly becomes its own answer and the select is gone. A call that set
  `allow_other` also carries a "Something else" choice, which opens a modal and
  lets the captain type instead of pick.

  ## The custom_id is the routing

  Discord hands back whatever `custom_id` was on the component, and nothing
  else that identifies the question - so the id has to carry it. Ours is
  `fm:ask:<call id>`, which fits Discord's 100-character cap with room to spare
  and is namespaced so an application shared with another bot never collides.
  Anything that does not start with `fm:ask:` is not ours, and the endpoint
  passes it through to NATS exactly as before.

  The id names a row, it does not authorize anything. Whoever the payload came
  from, the endpoint has already proven the signature belongs to one tenant, and
  the answer is applied against that tenant's calls alone.
  """

  alias FirstmatePort.Portal.CaptainCall
  alias FirstmatePort.Portal.Validations.CaptainCallOptions

  @prefix "fm:ask:"
  @modal_prefix "fm:ask:other:"
  @answer_field "answer"

  # Discord interaction response types.
  @channel_message 4
  @update_message 7
  @modal 9

  # Discord interaction types, as they arrive.
  @message_component 3
  @modal_submit 5

  # Discord component types.
  @action_row 1
  @string_select 3
  @text_input 4

  # Discord text input styles.
  @paragraph 2

  @typedoc "What a returned interaction is asking us to do."
  @type answer :: %{
          call_id: String.t(),
          kind: :select | :modal,
          value: String.t() | nil,
          text: String.t() | nil,
          by: String.t()
        }

  @doc "The `custom_id` that carries `call_id` back on the select."
  def custom_id(call_id), do: @prefix <> call_id

  @doc "The `custom_id` for the modal an `allow_other` call opens."
  def modal_custom_id(call_id), do: @modal_prefix <> call_id

  @doc "The value of the reserved 'Something else' choice."
  def other_value, do: CaptainCallOptions.other_value()

  @doc """
  The Discord message body for a question.

  `allowed_mentions` is empty on purpose: a question is text the crew wrote, and
  a bot that will echo `@everyone` out of a task description is a bot anyone who
  can file a task can use as a megaphone.
  """
  @spec message(CaptainCall.t()) :: map()
  def message(%CaptainCall{} = call) do
    %{
      "content" => call.question,
      "allowed_mentions" => %{"parse" => []},
      "components" => [
        %{
          "type" => @action_row,
          "components" => [
            %{
              "type" => @string_select,
              "custom_id" => custom_id(call.id),
              "placeholder" => "Choose your answer...",
              "min_values" => 1,
              "max_values" => 1,
              "options" => select_options(call)
            }
          ]
        }
      ]
    }
  end

  defp select_options(%CaptainCall{} = call) do
    Enum.map(call.options, &option/1) ++ other_option(call)
  end

  defp option(option) do
    %{"label" => option_field(option, "label"), "value" => option_field(option, "value")}
    |> put_description(option_field(option, "description"))
  end

  defp put_description(option, nil), do: option
  defp put_description(option, ""), do: option
  defp put_description(option, description), do: Map.put(option, "description", description)

  defp other_option(%CaptainCall{allow_other: true}) do
    [
      %{
        "label" => "Something else...",
        "value" => other_value(),
        "description" => "Answer in your own words"
      }
    ]
  end

  defp other_option(_call), do: []

  # Options are string-keyed coming back from Postgres and may be atom-keyed
  # from an Elixir caller that has not been through the database yet. Literal
  # atoms rather than `String.to_existing_atom/1`: the key names are known here,
  # and a dynamic conversion on request-path data is a raise waiting for a key
  # nobody has interned.
  defp option_field(option, "value") when is_map(option),
    do: Map.get(option, "value") || Map.get(option, :value)

  defp option_field(option, "label") when is_map(option),
    do: Map.get(option, "label") || Map.get(option, :label)

  defp option_field(option, "description") when is_map(option),
    do: Map.get(option, "description") || Map.get(option, :description)

  @doc """
  Reads an inbound interaction as an answer to one of our calls, or `:not_ours`.

  Only `MESSAGE_COMPONENT` and `MODAL_SUBMIT` payloads carrying our prefix are
  claimed. Everything else on this endpoint keeps going where it always went.
  """
  @spec route(map()) :: {:ok, answer()} | :not_ours
  def route(
        %{"type" => @modal_submit, "data" => %{"custom_id" => @modal_prefix <> call_id} = data} =
          params
      ) do
    {:ok,
     %{
       call_id: call_id,
       kind: :modal,
       value: nil,
       text: modal_text(data),
       by: who(params)
     }}
  end

  def route(
        %{"type" => @message_component, "data" => %{"custom_id" => @prefix <> call_id} = data} =
          params
      ) do
    {:ok,
     %{
       call_id: call_id,
       kind: :select,
       value: chosen(data),
       text: nil,
       by: who(params)
     }}
  end

  def route(_params), do: :not_ours

  defp chosen(%{"values" => [value | _]}) when is_binary(value), do: value
  defp chosen(_data), do: nil

  # Discord nests modal fields one action row deep, and a row holds one input.
  defp modal_text(%{"components" => rows}) when is_list(rows) do
    rows
    |> Enum.flat_map(fn
      %{"components" => inputs} when is_list(inputs) -> inputs
      _ -> []
    end)
    |> Enum.find_value(fn
      %{"custom_id" => @answer_field, "value" => value} when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp modal_text(_data), do: nil

  # A guild interaction carries `member.user`; a DM carries `user`. Display only.
  defp who(%{"member" => %{"user" => user}}), do: username(user)
  defp who(%{"user" => user}), do: username(user)
  defp who(_params), do: ""

  defp username(%{"global_name" => name}) when is_binary(name) and name != "", do: name
  defp username(%{"username" => name}) when is_binary(name), do: name
  defp username(_user), do: ""

  @doc """
  The interaction response for whatever `FirstmatePort.CaptainCalls` decided.

  A recorded answer edits the question in place - `UPDATE_MESSAGE`, no
  components - so the message becomes the record of what was chosen and cannot
  be answered twice by clicking again. Everything else is an ephemeral note back
  to whoever clicked, because it concerns them and not the channel.

  `UPDATE_MESSAGE` on a modal submit is allowed precisely because the modal was
  opened from a component; that is the only way ours are ever opened.
  """
  @spec response(term()) :: map()
  def response({:ok, %CaptainCall{} = call}) do
    %{
      "type" => @update_message,
      "data" => %{
        "content" => answered_content(call),
        "allowed_mentions" => %{"parse" => []},
        "components" => []
      }
    }
  end

  def response({:open_modal, %CaptainCall{} = call}) do
    %{
      "type" => @modal,
      "data" => %{
        "custom_id" => modal_custom_id(call.id),
        "title" => "Answer in your own words",
        "components" => [
          %{
            "type" => @action_row,
            "components" => [
              %{
                "type" => @text_input,
                "custom_id" => @answer_field,
                "style" => @paragraph,
                "label" => "Your answer",
                "min_length" => 1,
                "max_length" => 1000,
                "required" => true
              }
            ]
          }
        ]
      }
    }
  end

  def response({:error, {:already_answered, %CaptainCall{} = call}}) do
    ephemeral("Already answered: #{shown(call)}.")
  end

  def response({:error, :unknown_option}), do: ephemeral("That is not one of the choices.")

  def response({:error, :no_choice}), do: ephemeral("No choice came back with that interaction.")

  def response({:error, :not_found}),
    do: ephemeral("That question is no longer on file for this tenant.")

  def response({:error, _reason}), do: ephemeral("That answer could not be recorded.")

  defp answered_content(%CaptainCall{} = call) do
    "#{call.question}\n\n**Answered:** #{shown(call)}#{by(call)}"
  end

  defp by(%CaptainCall{answered_by: ""}), do: ""
  defp by(%CaptainCall{answered_by: name}), do: " - #{name}"

  defp shown(%CaptainCall{answer_label: "", answer: answer}), do: answer
  defp shown(%CaptainCall{answer_label: label}), do: label

  # `flags: 64` is Discord's EPHEMERAL: only the person who clicked sees it.
  defp ephemeral(content) do
    %{
      "type" => @channel_message,
      "data" => %{
        "content" => content,
        "allowed_mentions" => %{"parse" => []},
        "flags" => 64
      }
    }
  end
end
