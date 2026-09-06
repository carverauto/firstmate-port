defmodule FirstmatePort.Fleet.Preparations.VectorSearch do
  @moduledoc """
  Orders documents by how close their stored vector is to the query vector.

  Only vectors from the same model and of the same width are considered.
  `unnest/2` pairs two arrays positionally and stops at the longer one, so
  comparing a 1536-wide vector with a 3072-wide one would silently score against
  nulls instead of failing; the width filter is what makes that impossible.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias FirstmatePort.Fleet.Document

  @impl true
  def prepare(query, _opts, _context) do
    embedding = Ash.Query.get_argument(query, :embedding)
    model = Ash.Query.get_argument(query, :model)
    limit = Ash.Query.get_argument(query, :limit)
    dimensions = length(embedding)

    query
    |> Ash.Query.filter(
      not is_nil(embedded_at) and embedding_model == ^model and
        embedding_dimensions == ^dimensions
    )
    |> Ash.Query.load(similarity: %{embedding: embedding})
    |> Ash.Query.sort([{:similarity, {%{embedding: embedding}, :desc}}, {:occurred_at, :desc}])
    |> Ash.Query.select(Document.summary_select())
    |> Ash.Query.limit(limit)
  end
end
