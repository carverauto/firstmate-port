defmodule FirstmatePort.Validations.HttpsUrl do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, opts, _context) do
    field = Keyword.fetch!(opts, :attribute)
    required? = Keyword.get(opts, :required?, false)
    value = Ash.Changeset.get_attribute(changeset, field)

    cond do
      is_nil(value) or value == "" ->
        if required?, do: {:error, field: field, message: "must be a full https URL"}, else: :ok

      true ->
        case FirstmatePort.Links.https(value) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, field: field, message: "must be a full https URL"}
        end
    end
  end
end
