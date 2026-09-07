defmodule FirstmatePort.CaptainCalls do
  @moduledoc """
  Asking the captain a bounded question in Discord, and turning the answer into
  a captain order the crew already knows how to read.

  Firstmate posts a question; Discord renders it as a select the captain picks
  from; the pick comes back through the same signed `/interactions` endpoint
  every other interaction uses, and lands in the tenant's inbox addressed to the
  task that asked. Nothing new has to poll anything: the crew reads the answer
  with `fm-steer inbox next --task <task>`, exactly as it reads every other
  order.

  The wire shapes are `FirstmatePort.Discord.Ask`; the store is
  `FirstmatePort.Portal.CaptainCall`; the round trip is documented in
  `docs/captain-calls.md`.
  """

  require Logger

  alias FirstmatePort.Discord.Ask
  alias FirstmatePort.Discord.Client
  alias FirstmatePort.Inbox
  alias FirstmatePort.Portal.CaptainCall
  alias FirstmatePort.Portal.Validations.CaptainCallOptions
  alias FirstmatePort.Tenancy

  @doc """
  Puts a question to the captain and returns the call, posted.

  The row is written before the message goes out, so a question the captain can
  see is always a question this database can answer - the other order leaves a
  window where a fast click arrives before the row it names exists. A post that
  Discord refuses leaves the call `:failed` with the reason on it, and the
  caller gets `{:error, {:undeliverable, call}}` rather than a silent success.

  `opts[:req_options]` is passed through to `FirstmatePort.Discord.Client` so
  tests can stub the HTTP call.
  """
  @spec ask(term(), map(), keyword()) ::
          {:ok, CaptainCall.t()}
          | {:error, {:undeliverable, CaptainCall.t()}}
          | {:error, term()}
  def ask(actor, attrs, opts \\ []) when is_map(attrs) do
    ash = Tenancy.opts(actor)
    tenant = Tenancy.slug(actor)

    with {:ok, call} <- CaptainCall.ask(create_attrs(attrs), ash) do
      deliver(tenant, call, ash, opts)
    end
  end

  defp create_attrs(attrs) do
    %{
      question: fetch(attrs, :question),
      options: fetch(attrs, :options),
      channel_id: fetch(attrs, :channel_id),
      task: presence(fetch(attrs, :task)) || Inbox.default_task(),
      allow_other: truthy(fetch(attrs, :allow_other))
    }
  end

  defp deliver(tenant, call, ash, opts) do
    case Client.post_message(tenant, call.channel_id, Ask.message(call), opts) do
      {:ok, message_id} ->
        CaptainCall.delivered(call, %{message_id: message_id}, ash)

      {:error, reason} ->
        Logger.warning("captain call #{call.id} for #{tenant} not posted: #{inspect(reason)}")

        {:ok, failed} =
          CaptainCall.undeliverable(call, %{delivery_error: Client.describe(reason)}, ash)

        {:error, {:undeliverable, failed}}
    end
  end

  @doc """
  Applies one answer read off a verified interaction.

  `tenant` is the tenant the endpoint resolved the signature to, and it is the
  only tenant whose calls can be reached - a `custom_id` naming someone else's
  question finds nothing. The return value is what
  `FirstmatePort.Discord.Ask.response/1` turns into the interaction reply.
  """
  @spec answer(String.t(), Ask.answer()) ::
          {:ok, CaptainCall.t()}
          | {:open_modal, CaptainCall.t()}
          | {:error, term()}
  def answer(tenant, %{call_id: call_id} = answer) do
    ash = Tenancy.opts(actor(tenant))

    # A custom_id that is not a uuid is an invalid argument rather than a miss,
    # and it is still just someone else's component on a shared application.
    case CaptainCall.get(call_id, ash) do
      {:ok, %CaptainCall{status: :open} = call} -> apply_answer(call, answer, ash)
      {:ok, %CaptainCall{} = call} -> {:error, {:already_answered, call}}
      _ -> {:error, :not_found}
    end
  end

  defp apply_answer(call, %{kind: :select, value: value} = answer, ash) do
    cond do
      is_nil(value) ->
        {:error, :no_choice}

      value == Ask.other_value() and call.allow_other ->
        {:open_modal, call}

      true ->
        case chosen(call, value) do
          nil -> {:error, :unknown_option}
          option -> record(call, answer, value, label(option), ash)
        end
    end
  end

  defp apply_answer(call, %{kind: :modal, text: text} = answer, ash) do
    cond do
      not call.allow_other -> {:error, :unknown_option}
      is_nil(presence(text)) -> {:error, :no_choice}
      true -> record(call, answer, String.trim(text), "Something else", ash)
    end
  end

  # The answer is matched against the options this row already carries, so the
  # only values that can be recorded are ones the captain was actually shown.
  defp chosen(%CaptainCall{options: options}, value) do
    Enum.find(options, fn option -> option_field(option, "value") == value end)
  end

  defp label(option), do: option_field(option, "label") || ""

  defp record(call, answer, value, label, ash) do
    attrs = %{
      answer: value,
      answer_label: label,
      answered_by: String.slice(Map.get(answer, :by) || "", 0, 100)
    }

    case CaptainCall.answer(call, attrs, ash) do
      {:ok, answered} ->
        file_order(answered, ash)
        {:ok, answered}

      # The filter carried into the UPDATE is what makes a double click
      # idempotent, and losing that race is the expected outcome, not a fault:
      # the other click already filed the order.
      {:error, _reason} ->
        case CaptainCall.get(call.id, ash) do
          {:ok, %CaptainCall{status: :answered} = current} ->
            {:error, {:already_answered, current}}

          _ ->
            {:error, :not_recorded}
        end
    end
  end

  # The whole point of the round trip: the captain's pick becomes an ordinary
  # order in the tenant's inbox, on the task that asked, so the crew reads it
  # with the command it already uses and nothing new has to poll Discord.
  defp file_order(%CaptainCall{} = call, ash) do
    body = """
    Captain answered: #{shown(call)}

    Question: #{call.question}
    Value: #{call.answer}
    Answered by: #{answered_by(call)}
    Call: #{call.id}\
    """

    case Inbox.put(answerer(call, ash), %{task: call.task, body: body, delivery: "discord"}) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        # The row is the record either way; the order is how the crew hears
        # about it, and an inbox that refused one is worth saying out loud.
        Logger.warning("captain call #{call.id} answered but not filed: #{inspect(reason)}")
        :ok
    end
  end

  # `Inbox.put` stamps the sender off the actor's email. The captain answered in
  # Discord, so that is what the inbox should show - it is provenance, not an
  # identity this app authenticated.
  defp answerer(%CaptainCall{} = call, ash) do
    %{
      role: :human,
      email: "#{answered_by(call)} (discord)",
      id: "captain-call",
      tenant_slug: ash[:tenant]
    }
  end

  defp answered_by(%CaptainCall{answered_by: ""}), do: "captain"
  defp answered_by(%CaptainCall{answered_by: name}), do: name

  defp shown(%CaptainCall{answer_label: "", answer: answer}), do: answer
  defp shown(%CaptainCall{answer_label: label}), do: label

  @doc """
  The interaction response for one answer, ready to be rendered as JSON.

  This is what the endpoint calls: it hands over the tenant the signature
  resolved to and the answer read off the payload, and gets back the reply
  Discord should see.
  """
  @spec respond(String.t(), Ask.answer()) :: map()
  def respond(tenant, answer), do: tenant |> answer(answer) |> Ask.response()

  @doc "Questions this tenant's captain has not answered yet."
  def open(actor), do: CaptainCall.open(Tenancy.opts(actor))

  @doc "Recent questions, answered ones included."
  def recent(actor), do: CaptainCall.recent(Tenancy.opts(actor))

  @doc "One call by id, scoped to the actor's tenant."
  def get(actor, id), do: CaptainCall.get(id, Tenancy.opts(actor))

  @doc "The `fm-captain-call.v1` payload for one call."
  def wire(%CaptainCall{} = call) do
    %{
      "schema" => "fm-captain-call.v1",
      "id" => call.id,
      "status" => Atom.to_string(call.status),
      "question" => call.question,
      "options" => call.options,
      "allow_other" => call.allow_other,
      "task" => call.task,
      "channel_id" => call.channel_id,
      "message_id" => call.message_id,
      "answer" => call.answer,
      "answer_label" => call.answer_label,
      "answered_by" => call.answered_by,
      "answered_at" => call.answered_at && DateTime.to_iso8601(call.answered_at),
      "delivery_error" => call.delivery_error,
      "tenant" => call.tenant_slug,
      "at" => DateTime.to_iso8601(call.inserted_at)
    }
  end

  @doc "The value reserved for the 'Something else' choice."
  def other_value, do: CaptainCallOptions.other_value()

  defp actor(tenant), do: %{role: :agent, email: "discord@localhost", tenant_slug: tenant}

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

  defp fetch(attrs, key), do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_value), do: false
end
