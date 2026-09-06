defmodule FirstmatePort.Fleet.Embedder do
  @moduledoc """
  Fills in the vectors, a batch at a time.

  The backfill only ever runs when a tenant has a model and a key; with either
  missing it reports that and does nothing, because an unconfigured portal is
  the normal case, not a failure. A provider error *is* a failure and is
  returned, so the scheduled job fails and Oban retries it with backoff rather
  than quietly leaving the index half-embedded.

  Documents are taken oldest-change-first, so a run that cannot embed one
  document keeps failing on the same visible document instead of wandering
  through the log.
  """

  alias FirstmatePort.Fleet
  alias FirstmatePort.Fleet.{Document, Embeddings}
  alias FirstmatePort.Tenancy

  @batch 32

  @doc "Runs the backfill for every tenant. Returns the per-tenant results."
  def run_all(opts \\ []) do
    Enum.map(Fleet.tenant_slugs(), fn slug -> {slug, run(slug, opts)} end)
  end

  @doc """
  Embeds up to one batch for one tenant.

  Returns `{:ok, %{embedded: count, state: state}}` where `state` is `:off`,
  `:missing_api_key`, `:idle` (nothing to do), or `{:ready, model}`.

  `:batch` is this module's option; every other option is passed through to
  `FirstmatePort.Fleet.Embeddings`.
  """
  def run(tenant, opts \\ []) do
    slug = Tenancy.slug(tenant)
    ash_opts = Tenancy.opts(Fleet.actor(slug))
    batch = Keyword.get(opts, :batch, @batch)

    case Embeddings.model(slug) do
      :error ->
        {:ok, %{embedded: 0, state: :off}}

      {:ok, model} ->
        with {:ok, documents} <- Document.needs_embedding(model, %{limit: batch}, ash_opts) do
          embed(documents, slug, ash_opts, Keyword.delete(opts, :batch))
        end
    end
  end

  defp embed([], _slug, _ash_opts, _opts), do: {:ok, %{embedded: 0, state: :idle}}

  defp embed(documents, slug, ash_opts, opts) do
    case Embeddings.embed(Enum.map(documents, &text/1), slug, opts) do
      {:ok, %{model: model, vectors: vectors}} ->
        documents
        |> Enum.zip(vectors)
        |> Enum.reduce_while({:ok, %{embedded: 0, state: {:ready, model}}}, fn
          {document, vector}, {:ok, %{embedded: embedded} = acc} ->
            case Document.put_embedding(document, %{embedding: vector, model: model}, ash_opts) do
              {:ok, _document} -> {:cont, {:ok, %{acc | embedded: embedded + 1}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end)

      {:error, :missing_api_key} ->
        {:ok, %{embedded: 0, state: :missing_api_key}}

      {:error, :disabled} ->
        {:ok, %{embedded: 0, state: :off}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A document always has a title, so this never asks a provider to embed
  # nothing - which would fail the same document on every run.
  defp text(%Document{search_text: "", title: title}), do: title
  defp text(%Document{search_text: search_text}), do: search_text
end
