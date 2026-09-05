defmodule FirstmatePort.UsageTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Usage

  defp account(overrides \\ %{}) do
    Map.merge(
      %{allowance: 100.0, used: 25.0, spend_priority: 100, provider: "openrouter", label: "main"},
      overrides
    )
  end

  test "remaining subtracts used from allowance" do
    assert Usage.remaining(account()) == 75.0
  end

  test "remaining is nil when the allowance is unknown" do
    assert Usage.remaining(account(%{allowance: nil})) == nil
    assert Usage.pct_used(account(%{allowance: nil})) == nil
    assert Usage.status(account(%{allowance: nil})) == :unknown
  end

  test "status moves ok -> low -> exhausted" do
    assert Usage.status(account(%{used: 10.0})) == :ok
    assert Usage.status(account(%{used: 75.0})) == :low
    assert Usage.status(account(%{used: 99.9})) == :low
    assert Usage.status(account(%{used: 100.0})) == :exhausted
    assert Usage.status(account(%{used: 140.0})) == :exhausted
  end

  test "runway divides remaining by daily burn" do
    now = DateTime.utc_now()

    snaps = [
      %{used: 10.0, inserted_at: DateTime.add(now, -4, :day)},
      %{used: 30.0, inserted_at: now}
    ]

    # burn 5/day, remaining 70 -> 14 days
    assert Usage.runway_days(account(%{used: 30.0}), snaps) == 14.0
  end

  test "runway is nil without enough history" do
    now = DateTime.utc_now()
    assert Usage.runway_days(account(), []) == nil
    assert Usage.runway_days(account(), [%{used: 10.0, inserted_at: now}]) == nil

    flat = [
      %{used: 10.0, inserted_at: DateTime.add(now, -4, :day)},
      %{used: 10.0, inserted_at: now}
    ]

    assert Usage.runway_days(account(), flat) == nil
    assert Usage.runway_days(account(%{allowance: nil}), flat) == nil
  end

  test "sort_for_spend spends low priority numbers first" do
    accounts = [
      account(%{label: "b", spend_priority: 200}),
      account(%{label: "a", spend_priority: 10}),
      account(%{label: "c", spend_priority: 10})
    ]

    assert Enum.map(Usage.sort_for_spend(accounts), & &1.label) == ["a", "c", "b"]
  end

  test "summarize carries computed fields" do
    summary =
      Usage.summarize(
        Map.merge(account(), %{
          id: "abc",
          unit: :usd,
          window: :monthly,
          source: :manual,
          reset_at: nil,
          last_synced_at: nil
        })
      )

    assert summary.remaining == 75.0
    assert summary.pct_used == 0.25
    assert summary.status == :ok
    assert summary.runway_days == nil
  end
end
