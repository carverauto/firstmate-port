defmodule FirstmatePort.Usage.BurnWindow do
  @moduledoc """
  The two snapshots `FirstmatePort.Usage.daily_burn/1` needs: the first and
  last reading of an account's current billing window.

  The window starts at the last drop in `used` — that is what a provider
  reset looks like — and the cut is made in SQL. A ledger render asks for
  this once per account, so it must stay two rows no matter how many
  readings a busy fleet has posted.
  """

  @window_days 35

  @doc """
  Boundary samples for an account, oldest first: `[]`, `[only]`, or
  `[first, last]` as `%{used:, inserted_at:}`.
  """
  def for_account(usage_account_id, tenant_slug) do
    %{rows: rows} =
      FirstmatePort.Repo.query!(
        """
        WITH win AS (
          SELECT used, inserted_at,
                 lag(used) OVER (ORDER BY inserted_at) AS prev
            FROM usage_snapshots
           WHERE tenant_slug = $1
             AND usage_account_id = $2
             AND inserted_at > now() - ($3 || ' days')::interval
        ),
        cut AS (
          SELECT coalesce(max(inserted_at), '-infinity'::timestamptz) AS at
            FROM win
           WHERE prev IS NOT NULL AND used < prev
        ),
        current AS (
          SELECT used, inserted_at FROM win, cut WHERE inserted_at >= cut.at
        )
        SELECT used, inserted_at FROM (
          (SELECT used, inserted_at FROM current ORDER BY inserted_at ASC LIMIT 1)
          UNION
          (SELECT used, inserted_at FROM current ORDER BY inserted_at DESC LIMIT 1)
        ) bounds
        ORDER BY inserted_at ASC
        """,
        [tenant_slug, Ecto.UUID.dump!(usage_account_id), to_string(@window_days)]
      )

    Enum.map(rows, fn [used, inserted_at] ->
      %{used: used, inserted_at: DateTime.from_naive!(inserted_at, "Etc/UTC")}
    end)
  end
end
