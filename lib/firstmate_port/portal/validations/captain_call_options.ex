defmodule FirstmatePort.Portal.Validations.CaptainCallOptions do
  @moduledoc """
  Holds a captain call's choices to what Discord will actually render, and to
  what the answer path can safely match against.

  Two jobs, and the second is the one that matters. Discord's own limits (at
  most 25 options, 100 characters per label, value, and description) are
  checked here so a question is refused when it is asked rather than at the
  POST to Discord, where the caller is long gone and all that is left is a row
  nobody can answer.

  Beyond that, the options are the *whole* of what an answer may be. A returned
  interaction is verified as coming from the tenant's Discord application, but
  its `values` array is still just bytes on the wire, and matching them against
  this list is what stops a crafted payload from filing an order the captain was
  never shown. Duplicate values would make that match ambiguous, so they are
  refused too.
  """

  use Ash.Resource.Validation

  # Discord: a string select carries 1-25 options, and label, value, and
  # description are each capped at 100 characters.
  @max_options 25
  @max_field 100

  @doc "The value reserved for the 'Something else' choice on an `allow_other` call."
  def other_value, do: "__other__"

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :options) do
      options when is_list(options) and options != [] ->
        limit =
          if Ash.Changeset.get_attribute(changeset, :allow_other), do: 24, else: @max_options

        check(options, limit)

      _ ->
        error("must be a non-empty list of choices")
    end
  end

  defp check(options, limit) when length(options) > limit do
    error("must be at most #{limit} choices; Discord will not render more")
  end

  defp check(options, _limit) do
    with :ok <- Enum.reduce_while(options, :ok, &check_one/2) do
      check_unique(options)
    end
  end

  defp check_one(option, _acc) do
    case one(option) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp one(%{} = option) do
    value = field(option, "value")
    label = field(option, "label")
    description = field(option, "description")

    cond do
      not usable?(value) ->
        error("every choice needs a value of 1-#{@max_field} characters")

      value == other_value() ->
        error("#{other_value()} is reserved for the 'Something else' choice")

      not usable?(label) ->
        error("every choice needs a label of 1-#{@max_field} characters")

      not is_nil(description) and not usable?(description) ->
        error("a choice description must be at most #{@max_field} characters")

      true ->
        :ok
    end
  end

  defp one(_option), do: error("every choice must be an object")

  defp check_unique(options) do
    values = Enum.map(options, &field(&1, "value"))

    if length(Enum.uniq(values)) == length(values) do
      :ok
    else
      error("choice values must be unique; an answer has to name exactly one of them")
    end
  end

  # Params arrive as string keys from JSON and atom keys from Elixir callers.
  # Literal atoms, never `String.to_existing_atom/1`: this runs on request data.
  defp field(option, "value") when is_map(option),
    do: Map.get(option, "value") || Map.get(option, :value)

  defp field(option, "label") when is_map(option),
    do: Map.get(option, "label") || Map.get(option, :label)

  defp field(option, "description") when is_map(option),
    do: Map.get(option, "description") || Map.get(option, :description)

  defp usable?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and String.length(value) <= @max_field
  end

  defp usable?(_value), do: false

  defp error(message), do: {:error, field: :options, message: message}
end
