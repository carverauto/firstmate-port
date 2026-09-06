defmodule FirstmatePortWeb.SearchLive do
  @moduledoc """
  One box over the whole fleet log.

  The query lives in the URL, so a search is a link a captain can paste into a
  ticket and land on the same results. `handle_params/3` is where it is read;
  `mount/3` would not re-run on a patch.

  The page says which passes answered. A search that quietly lost its semantic
  half - an expired key, a provider outage - looks exactly like a search with
  poor recall, so the banner names the state rather than leaving it to be
  guessed.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Fleet.Search

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @snippet 240

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "search")
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:semantic, :off)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, run(socket, params["q"] || "")}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?#{[q: query]}")}
  end

  defp run(socket, query) do
    case Search.run(query, socket.assigns.current_user) do
      {:ok, result} ->
        socket
        |> assign(:query, result.query)
        |> assign(:results, result.results)
        |> assign(:semantic, result.semantic)
        |> assign(:error, nil)

      {:error, error} ->
        socket
        |> assign(:query, query)
        |> assign(:results, [])
        |> assign(:error, inspect(error))
    end
  end

  defp banner(:off) do
    "Postgres text search. Choose an embedding model in Credentials to add semantic search."
  end

  defp banner(:missing_api_key) do
    "Postgres text search. A model is chosen, but this tenant has no embeddings/api_key credential yet."
  end

  defp banner({:ready, model}), do: "Postgres text search and #{model} embeddings."

  defp banner({:error, _reason}) do
    "Postgres text search only: the embedding provider did not answer this query."
  end

  defp destination(%{url: url}) when is_binary(url) and url != "", do: url
  defp destination(%{source: :diagram, source_id: id}), do: ~p"/d/#{id}"
  defp destination(%{source: :roll, source_id: id}), do: ~p"/rolls/#{id}"
  defp destination(%{source: :no_mistakes_run}), do: ~p"/no-mistakes"
  defp destination(%{source: :progress_item}), do: ~p"/?tab=progress"
  defp destination(_document), do: nil

  defp snippet(%{body: body}) when is_binary(body) and body != "" do
    String.slice(body, 0, @snippet)
  end

  defp snippet(_document), do: ""

  defp matched(%{lexical_rank: nil, semantic_rank: _rank}), do: "meaning"
  defp matched(%{semantic_rank: nil}), do: "words"
  defp matched(_result), do: "words + meaning"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Search the fleet log</h1>
        <p class="meta">{banner(@semantic)}</p>
      </header>

      <p :if={@error} class="empty-copy" role="alert">{@error}</p>

      <section class="plate">
        <form phx-submit="search" class="axi-form">
          <label>
            Query
            <input
              type="search"
              name="q"
              value={@query}
              autocomplete="off"
              placeholder="buildbuddy flake on the roll job"
            />
          </label>
          <button type="submit" class="btn btn-primary">Search</button>
        </form>
        <p class="hint">
          Quoted "phrases" and -excluded words work. Everything the portal records is indexed:
          PRs, issues, progress, rolls, no-mistakes runs, and diagram titles.
        </p>
      </section>

      <section class="plate">
        <h2>Results</h2>
        <p :if={@query == ""} class="empty-state">Type something to search.</p>
        <p :if={@query != "" and @results == []} class="empty-state">
          Nothing matched. A record reaches the index on the next fleet sync, so a PR opened in
          the last few minutes may not be here yet.
        </p>
        <ol class="rows">
          <li :for={result <- @results} id={result.document.id}>
            <span>
              <span class="kind">{result.document.source}</span>
              <.link :if={destination(result.document)} href={destination(result.document)}>
                {result.document.title}
              </.link>
              <span :if={is_nil(destination(result.document))}>{result.document.title}</span>
              <span :if={snippet(result.document) != ""} class="meta">
                {snippet(result.document)}
              </span>
            </span>
            <span class="meta">
              <span class="kind">{matched(result)}</span>
              <time>{result.document.occurred_at}</time>
            </span>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
