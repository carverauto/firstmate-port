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

  test "a zero or negative allowance is set, so it is exhausted not unknown" do
    assert Usage.status(account(%{allowance: 0.0, used: 25.0})) == :exhausted
    assert Usage.remaining(account(%{allowance: 0.0, used: 25.0})) == -25.0

    assert Usage.status(account(%{allowance: 0.0, used: 0.0})) == :exhausted
    assert Usage.status(account(%{allowance: -10.0, used: 0.0})) == :exhausted

    assert Usage.status(account(%{allowance: nil})) == :unknown
  end

  test "runway scores the current window, not history across a reset" do
    now = DateTime.utc_now()

    across_reset = [
      %{used: 10.0, inserted_at: DateTime.add(now, -34, :day)},
      %{used: 90.0, inserted_at: DateTime.add(now, -15, :day)},
      %{used: 5.0, inserted_at: DateTime.add(now, -10, :day)},
      %{used: 20.0, inserted_at: now}
    ]

    # Only the post-reset run counts: 15 used over 10 days is 1.5/day,
    # remaining 80 -> 53.3 days, not the 272 the spent window implies.
    assert Usage.runway_days(account(%{used: 20.0}), across_reset) == 53.3
  end

  test "runway is nil when the window just reset and only one sample follows" do
    now = DateTime.utc_now()

    snaps = [
      %{used: 10.0, inserted_at: DateTime.add(now, -34, :day)},
      %{used: 90.0, inserted_at: DateTime.add(now, -15, :day)},
      %{used: 20.0, inserted_at: now}
    ]

    assert Usage.runway_days(account(%{used: 20.0}), snaps) == nil
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
          reset_at: nil
        })
      )

    assert summary.remaining == 75.0
    assert summary.pct_used == 0.25
    assert summary.status == :ok
    assert summary.runway_days == nil
  end
end
