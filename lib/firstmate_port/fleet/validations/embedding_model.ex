defmodule FirstmatePort.Fleet.Validations.EmbeddingModel do
  @moduledoc """
  Refuses a model spec the portal could not actually embed with.

  Empty clears the choice and falls back to the deployment default, so that is
  always allowed. Anything else has to be a `provider:model` spec the provider
  library recognises as an embedding model - a chat model pasted into the box is
  a mistake worth catching in the form.
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
