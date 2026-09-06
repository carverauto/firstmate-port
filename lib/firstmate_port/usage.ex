defmodule FirstmatePort.Usage do
  @moduledoc """
  Token-usage and billing math for provider accounts.

  Every number here is derived from facts the product can already see:
  allowance and window configured per account, and `used` posted by agents
  and humans. Nothing is invented: when the allowance is unknown,
  remaining and runway stay `nil` and say so.
  """

  @low_threshold 0.75

  @doc "Remaining allowance, or nil when the allowance is unknown."
  def remaining(%{allowance: nil}), do: nil
  def remaining(%{allowance: a, used: u}), do: a - (u || 0)

  @doc """
  Fraction of allowance consumed, or nil when the allowance is unknown.
  A non-positive allowance leaves nothing to consume, so it reads as fully
  spent — the same account `status/1` calls `:exhausted`.
  """
  def pct_used(%{allowance: nil}), do: nil
  def pct_used(%{allowance: a}) when a <= 0, do: 1.0
  def pct_used(%{allowance: a, used: u}), do: (u || 0) / a

  @doc """
  Account status: `:unknown` (no allowance), `:ok`, `:low` (past 75%),
  or `:exhausted`.
  """
  def status(%{allowance: nil}), do: :unknown
  def status(%{allowance: a}) when a <= 0, do: :exhausted

  def status(account) do
    case pct_used(account) do
      p when p >= 1.0 -> :exhausted
      p when p >= @low_threshold -> :low
      _ -> :ok
    end
  end

  @doc """
  Estimated days until the allowance runs out, from snapshot burn rate.
  Needs at least two snapshots spanning a day with rising usage; otherwise
  nil. `snapshots` are maps (or structs) with `:used` and `:inserted_at`.
  """
  def runway_days(account, snapshots) do
    with remaining when is_number(remaining) <- remaining(account),
         true <- remaining > 0,
         burn when is_number(burn) and burn > 0 <- daily_burn(snapshots) do
      Float.round(remaining / burn, 1)
    else
      _ -> nil
    end
  end

  @doc """
  Average daily consumption across the current billing window.

  `snapshots` are the window's boundary samples from
  `FirstmatePort.Usage.BurnWindow`, which already drops everything at or
  before the last reset.
  """
  def daily_burn(snapshots) do
    ordered = Enum.sort_by(snapshots, &as_unix(inserted_at(&1)))

    case {List.first(ordered), List.last(ordered)} do
      {nil, _} ->
        nil

      {first, last} when first == last ->
        nil

      {first, last} ->
        days = (as_unix(inserted_at(last)) - as_unix(inserted_at(first))) / 86_400
        delta = (used_of(last) || 0) - (used_of(first) || 0)

        if days >= 1 and delta > 0, do: delta / days, else: nil
    end
  end

  @doc "Sort for spend order: lowest `spend_priority` first (spend these first)."
  def sort_for_spend(accounts) do
    Enum.sort_by(accounts, &[&1.spend_priority || 100, &1.provider, &1.label])
  end

  @doc "Enrich an account with computed fields for API and LiveView."
  def summarize(account, snapshots \\ []) do
    %{
      id: account.id,
      provider: account.provider,
      label: account.label,
      unit: account.unit,
      window: account.window,
      allowance: account.allowance,
      used: account.used,
      remaining: remaining(account),
      pct_used: pct_used(account),
      status: status(account),
      runway_days: runway_days(account, snapshots),
      spend_priority: account.spend_priority
    }
  end

  defp inserted_at(%{inserted_at: at}), do: at
  defp used_of(%{used: u}), do: u

  defp as_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp as_unix(_), do: 0
end
