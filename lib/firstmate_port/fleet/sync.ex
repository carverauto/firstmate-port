defmodule FirstmatePort.Fleet.Sync do
  @moduledoc """
  Copies the fleet log into its searchable projection.

  This is the synchroniser: it reads the portal's own Postgres rows - GitHub
  items, progress, rolls, no-mistakes runs, diagrams - projects each one with
  `FirstmatePort.Fleet.Projection`, and writes the result to
  `FirstmatePort.Fleet.Document` in the same database. There is no second store
  and no second copy of the poll; a record reaches the index because it is
  already in the log.

  A run is idempotent. Documents whose `content_hash` still matches are left
  alone, so a sync that finds nothing new writes nothing and leaves every
  existing vector valid. Documents whose source record has gone are destroyed,
  which is what keeps the index from answering with rows the log no longer has.
  """

  require Logger

  alias FirstmatePort.Fleet
  alias FirstmatePort.Fleet.{Document, Projection}
  alias FirstmatePort.Tenancy

  @doc "Syncs every tenant. Returns the per-tenant results, failures included."
  def run_all do
    Enum.map(Fleet.tenant_slugs(), fn slug -> {slug, run(slug)} end)
  end

  @doc """
  Syncs one tenant.

  Returns `{:ok, %{scanned:, written:, removed:}}`, or `{:error, reason}` when a
  read or write fails - which is a real failure, and the caller should let it
  surface so the job retries.
  """
  def run(tenant_slug) do
    opts = Tenancy.opts(Fleet.actor(tenant_slug))

    with {:ok, projections} <- project_all(opts),
         {:ok, indexed} <- indexed_hashes(opts),
         {:ok, written} <- write_changed(projections, indexed, opts),
         {:ok, removed} <- remove_orphans(projections, indexed, opts) do
      {:ok, %{scanned: length(projections), written: written, removed: removed}}
    end
  end

  defp project_all(opts) do
    Enum.reduce_while(Projection.sources(), {:ok, []}, fn resource, {:ok, acc} ->
      case read_source(resource, opts) do
        {:ok, records} -> {:cont, {:ok, acc ++ Enum.map(records, &Projection.from/1)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_source(resource, opts) do
    resource
    |> Ash.Query.new()
    |> Ash.Query.select(Projection.select(resource))
    |> Ash.read(opts)
  end

  defp indexed_hashes(opts) do
    Document
    |> Ash.Query.new()
    |> Ash.Query.select([:id, :source, :source_id, :content_hash])
    |> Ash.read(opts)
    |> case do
      {:ok, documents} ->
        {:ok, Map.new(documents, &{{&1.source, &1.source_id}, &1})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_changed(projections, indexed, opts) do
    projections
    |> Enum.reject(&unchanged?(&1, indexed))
    |> Enum.reduce_while({:ok, 0}, fn projection, {:ok, written} ->
      case Document.upsert(projection, opts) do
        {:ok, _document} -> {:cont, {:ok, written + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unchanged?(projection, indexed) do
    case Map.get(indexed, {projection.source, projection.source_id}) do
      %{content_hash: hash} -> hash == projection.content_hash
      nil -> false
    end
  end

  defp remove_orphans(projections, indexed, opts) do
    live = MapSet.new(projections, &{&1.source, &1.source_id})

    indexed
    |> Enum.reject(fn {key, _document} -> MapSet.member?(live, key) end)
    |> Enum.reduce_while({:ok, 0}, fn {_key, document}, {:ok, removed} ->
      case Ash.destroy(document, opts) do
        :ok -> {:cont, {:ok, removed + 1}}
        {:ok, _} -> {:cont, {:ok, removed + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
