defmodule FirstmatePort.Fleet.Preparations.LexicalSearch do
  @moduledoc """
  Narrows a read to the documents Postgres' text search matches, best first.

  The filter and the rank use the same `to_tsvector('english', search_text)`
  expression the GIN index in `FirstmatePort.Fleet.Document` is built on, so the
  index answers the filter.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias FirstmatePort.Fleet.Document

  @impl true
  def prepare(query, _opts, _context) do
    text = Ash.Query.get_argument(query, :query)
    limit = Ash.Query.get_argument(query, :limit)

    query
    |> Ash.Query.filter(
      fragment(
        "to_tsvector('english', ?) @@ websearch_to_tsquery('english', ?)",
        search_text,
        ^text
      )
    )
    |> Ash.Query.load(lexical_rank: %{query: text})
    |> Ash.Query.sort([{:lexical_rank, {%{query: text}, :desc}}, {:occurred_at, :desc}])
    |> Ash.Query.select(Document.summary_select())
    |> Ash.Query.limit(limit)
  end
end
