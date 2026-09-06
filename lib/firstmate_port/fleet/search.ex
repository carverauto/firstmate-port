defmodule FirstmatePort.Fleet.Search do
  @moduledoc """
  One search over the fleet log, lexical and - when configured - semantic.

  The lexical pass is Postgres full-text search, ranked by `ts_rank_cd`. It is
  always on, needs no key and no extension, and is the whole of search in a
  default deployment. It is a cover-density rank rather than Okapi BM25;
  `docs/fleet-search.md` is explicit about that, and about why no database was
  added to get the other one.

  The semantic pass embeds the query with the tenant's configured model and
  orders documents by cosine similarity. It finds records that share no words
  with the query, which is the whole point of paying for it.

  The two rankings are combined with reciprocal rank fusion: each result scores
  `1 / (60 + rank)` in every list it appears in, and the scores add. Fusion
  compares positions, not scores, so a `ts_rank_cd` value and a cosine
  similarity never have to be made commensurable - which they are not. With the
  semantic pass off, fusion over one list returns that list's own order, so the
  code path does not fork.

  `semantic:` in the result says which of those happened, including when a
  provider call failed. A search that silently degrades to half its recall is
  worse than one that says so.
  """

  alias FirstmatePort.Fleet.{Document, Embeddings}
  alias FirstmatePort.Tenancy

  @rrf_k 60
  @default_limit 25
  @candidates 50

  @doc """
  Searches the fleet log for `text` as `actor`.

  Options: `:limit` for how many results to return and `:candidates` for how
  deep each pass looks before fusion. Those two are this module's; every other
  option is passed through to `FirstmatePort.Fleet.Embeddings`.

  Returns `{:ok, %{query:, results:, semantic:}}`. Each result is the document,
  its fused `score`, and its position in each pass it appeared in.

  The reads run as `actor`, so the resource's own policies decide what comes
  back. Nothing here substitutes a background actor for the caller's - that is
  what the sync and embedding jobs use, and using it here would hand a
  fleet log to anyone who could reach the endpoint.
  """
  def run(text, actor, opts \\ [])

  # The read policy would refuse this anyway; saying so here means the
  # empty-query shortcut below cannot answer an unauthenticated caller either.
  def run(_text, nil, _opts), do: {:error, :actor_required}

  def run(text, actor, opts) when is_binary(text) do
    query = String.trim(text)
    slug = Tenancy.slug(actor)
    limit = Keyword.get(opts, :limit, @default_limit)
    candidates = max(limit, Keyword.get(opts, :candidates, @candidates))

    if query == "" do
      {:ok, %{query: query, results: [], semantic: Embeddings.state(slug)}}
    else
      ash_opts = Tenancy.opts(actor)

      with {:ok, lexical} <- lexical(query, candidates, ash_opts) do
        {semantic_state, semantic} = semantic(query, slug, candidates, ash_opts, opts)

        {:ok,
         %{
           query: query,
           results: fuse(lexical, semantic, limit),
           semantic: semantic_state
         }}
      end
    end
  end

  @doc "The JSON-ready search response shared by API and MCP callers."
  def response(result) do
    %{
      query: result.query,
      semantic: semantic(result.semantic),
      data: Enum.map(result.results, &summarize/1)
    }
  end

  defp summarize(%{document: document} = result) do
    %{
      id: document.id,
      source: document.source,
      source_id: document.source_id,
      title: document.title,
      url: document.url,
      body: document.body,
      document: document.document,
      occurred_at: document.occurred_at,
      score: result.score,
      lexical_rank: result.lexical_rank,
      semantic_rank: result.semantic_rank
    }
  end

  # The model is named so an operator can see which one answered. The key it was
  # used with is never in a response.
  defp semantic({:ready, model}), do: %{state: "ready", model: model}
  defp semantic({:error, reason}), do: %{state: "error", reason: inspect(reason)}
  defp semantic(state) when is_atom(state), do: %{state: to_string(state)}

  defp lexical(query, candidates, ash_opts) do
    Document.search(query, %{limit: candidates}, ash_opts)
  end

  # One pass over the configuration, not two: asking whether embeddings are on
  # and then embedding would decrypt the tenant's key twice for every search.
  defp semantic(query, slug, candidates, ash_opts, opts) do
    case Embeddings.embed_query(query, slug, Keyword.drop(opts, [:limit, :candidates])) do
      {:ok, %{model: model, vector: vector}} ->
        case Document.nearest(vector, model, %{limit: candidates, query: query}, ash_opts) do
          {:ok, rows} -> {{:ready, model}, rows}
          {:error, reason} -> {{:error, reason}, []}
        end

      {:error, :disabled} ->
        {:off, []}

      {:error, :missing_api_key} ->
        {:missing_api_key, []}

      {:error, reason} ->
        {{:error, reason}, []}
    end
  end

  defp fuse(lexical, semantic, limit) do
    %{}
    |> merge(lexical, :lexical_rank)
    |> merge(semantic, :semantic_rank)
    |> Map.values()
    |> Enum.sort_by(fn result -> {-result.score, result.document.id} end)
    |> Enum.take(limit)
  end

  defp merge(results, documents, field) do
    documents
    |> Enum.with_index(1)
    |> Enum.reduce(results, fn {document, rank}, acc ->
      contribution = 1 / (@rrf_k + rank)

      Map.update(
        acc,
        document.id,
        %{
          document: document,
          score: contribution,
          lexical_rank: nil,
          semantic_rank: nil
        }
        |> Map.put(field, rank),
        fn existing ->
          existing
          |> Map.put(:score, existing.score + contribution)
          |> Map.put(field, rank)
        end
      )
    end)
  end
end
