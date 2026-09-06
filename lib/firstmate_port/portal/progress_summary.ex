defmodule FirstmatePort.Portal.ProgressSummary do
  @moduledoc "Database aggregates for bounded progress projections."

  alias FirstmatePort.Repo

  def load([], _opts), do: {:ok, %{}}

  def load(ids, opts) when length(ids) <= 1000 do
    query = """
    SELECT i.id,
      (SELECT status FROM progress_events WHERE tenant_slug = $1 AND item_id = i.id
       AND type = 'status' ORDER BY occurred_at DESC, inserted_at DESC, id DESC LIMIT 1),
      (SELECT occurred_at FROM progress_events WHERE tenant_slug = $1 AND item_id = i.id
       AND type = 'status' ORDER BY occurred_at DESC, inserted_at DESC, id DESC LIMIT 1),
      (SELECT worker FROM progress_events WHERE tenant_slug = $1 AND item_id = i.id
       AND type = 'assignment' ORDER BY occurred_at DESC, inserted_at DESC, id DESC LIMIT 1),
      min(e.occurred_at), max(e.occurred_at), sum(e.duration_ms), sum(e.tokens),
      bool_or(e.interrupted), count(e.id),
      count(e.id) FILTER (WHERE e.type = 'contribution' AND e.role = 'review'),
      count(DISTINCT e.worker) FILTER (WHERE e.type IN ('assignment', 'contribution') AND e.worker <> ''),
      ARRAY(SELECT DISTINCT worker FROM progress_events WHERE tenant_slug = $1 AND item_id = i.id
            AND type IN ('assignment', 'contribution') AND worker <> '' ORDER BY worker LIMIT 100)
    FROM progress_items i
    LEFT JOIN progress_events e ON e.item_id = i.id AND e.tenant_slug = i.tenant_slug
    WHERE i.tenant_slug = $1 AND i.id = ANY($2::text[])
      AND EXISTS (SELECT 1 FROM progress_events a WHERE a.item_id = i.id
                  AND a.tenant_slug = i.tenant_slug AND a.type = 'assignment')
    GROUP BY i.id
    """

    with {:ok, result} <- query(query, ids, opts) do
      {:ok, Map.new(result.rows, &summary/1)}
    end
  end

  defp query(sql, ids, opts) do
    if Keyword.get(opts, :actor) do
      Repo.query(sql, [Keyword.fetch!(opts, :tenant), ids])
    else
      {:error, :forbidden}
    end
  end

  defp summary([
         id,
         status,
         status_at,
         worker,
         started,
         last,
         duration,
         tokens,
         interrupted,
         count,
         reviews,
         worker_count,
         workers
       ]) do
    {id,
     %{
       status: status && String.to_existing_atom(status),
       status_at: utc(status_at),
       assignee: worker,
       started_at: utc(started),
       last_event_at: utc(last),
       duration_ms: integer(duration),
       tokens: integer(tokens),
       interrupted:
         case interrupted do
           nil -> :unknown
           true -> :yes
           false -> :no
         end,
       event_count: count,
       review_count: reviews,
       worker_count: worker_count,
       workers: workers
     }}
  end

  defp integer(nil), do: nil
  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(value), do: value
  defp utc(nil), do: nil
  defp utc(%DateTime{} = value), do: value
  defp utc(value), do: DateTime.from_naive!(value, "Etc/UTC")
end
