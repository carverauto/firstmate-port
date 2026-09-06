defmodule FirstmatePort.Fleet.Changes.PutEmbedding do
  @moduledoc """
  Writes a vector and stamps it with the text it was computed from.

  `embedded_hash` is taken from the row rather than the caller: it is the record
  of *which* text this vector describes, and a caller that could set it could
  mark a stale vector fresh.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    embedding = Ash.Changeset.get_argument(changeset, :embedding)
    model = Ash.Changeset.get_argument(changeset, :model)

    changeset
    |> Ash.Changeset.change_attribute(:embedding, embedding)
    |> Ash.Changeset.change_attribute(:embedding_model, model)
    |> Ash.Changeset.change_attribute(:embedding_dimensions, length(embedding))
    |> Ash.Changeset.change_attribute(:embedded_hash, changeset.data.content_hash)
    |> Ash.Changeset.change_attribute(:embedded_at, DateTime.utc_now())
  end
end
