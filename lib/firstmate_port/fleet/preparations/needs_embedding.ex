defmodule FirstmatePort.Fleet.Preparations.NeedsEmbedding do
  @moduledoc """
  The next batch for the embedding backfill: never embedded, embedded from text
  that has since changed, or embedded by a different model.

  Oldest change first. A backfill that keeps failing on one document therefore
  keeps failing on the same one, where it is visible, rather than wandering.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    model = Ash.Query.get_argument(query, :model)
    limit = Ash.Query.get_argument(query, :limit)

    query
    |> Ash.Query.filter(
      is_nil(embedded_at) or embedded_hash != content_hash or embedding_model != ^model
    )
    |> Ash.Query.sort(updated_at: :asc)
    |> Ash.Query.select([:id, :title, :content_hash, :search_text, :tenant_slug])
    |> Ash.Query.limit(limit)
  end
end
