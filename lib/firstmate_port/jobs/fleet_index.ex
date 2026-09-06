defmodule FirstmatePort.Jobs.FleetIndex do
  @moduledoc """
  The scheduled half of fleet search: project the log, then embed what changed.

  Two jobs rather than one. The projection is local Postgres work that should
  keep running when a provider is down or a key has expired; the backfill talks
  to a paid API and is allowed to fail. Keeping them apart means an outage at a
  provider never stops the fleet log from being searchable.

  Both run across every tenant. A failure in one tenant is returned so the job
  fails and Oban retries with backoff, and the tenants that did succeed keep
  their work - the writes are idempotent, so the retry redoes nothing.
  """

  require Logger

  alias FirstmatePort.Fleet.{Embedder, Sync}

  @doc "Projects every tenant's fleet log into `fleet_documents`."
  def sync do
    Sync.run_all()
    |> log("fleet sync")
    |> collapse()
  end

  @doc "Embeds one batch per tenant, for the tenants that have embeddings configured."
  def embed do
    Embedder.run_all()
    |> log("fleet embed")
    |> collapse()
  end

  defp log(results, label) do
    for {slug, {:ok, summary}} <- results, summary_worth_logging?(summary) do
      Logger.info("#{label} #{slug}: #{inspect(summary)}")
    end

    for {slug, {:error, reason}} <- results do
      Logger.warning("#{label} #{slug} failed: #{inspect(reason)}")
    end

    results
  end

  # A quiet tenant is the normal case and should not fill the log every tick.
  defp summary_worth_logging?(%{written: 0, removed: 0}), do: false
  defp summary_worth_logging?(%{embedded: 0}), do: false
  defp summary_worth_logging?(_summary), do: true

  defp collapse(results) do
    case Enum.find(results, &match?({_slug, {:error, _reason}}, &1)) do
      nil -> :ok
      {slug, {:error, reason}} -> {:error, {slug, reason}}
    end
  end
end
