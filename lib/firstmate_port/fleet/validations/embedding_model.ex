defmodule FirstmatePort.Fleet.Validations.EmbeddingModel do
  @moduledoc """
  Validates a tenant's model choice through `Embeddings.validate_spec/1`.

  Empty clears the choice and disables embeddings. See that function for the
  shape and provider checks; exact model support is checked by the provider
  when embeddings are requested.
  """

  use Ash.Resource.Validation

  alias FirstmatePort.Fleet.Embeddings

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :embedding_model) do
      value when value in [nil, ""] ->
        :ok

      value ->
        case Embeddings.validate_spec(value) do
          :ok ->
            :ok

          {:error, message} ->
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :embedding_model,
               message: message
             )}
        end
    end
  end
end
