defmodule FirstmatePort.Security.LockoutsTest do
  use ExUnit.Case, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Security.Lockouts

  setup do
    email = "crew-#{System.unique_integer([:positive])}@example.com"
    on_exit(fn -> Lockouts.clear(email) end)
    {:ok, email: email}
  end

  defp configure(opts), do: put_env(Lockouts, opts)

  test "locks the account once the threshold is crossed", %{email: email} do
    configure(threshold: 3, window_seconds: 900, lock_seconds: 900)

    assert :ok = Lockouts.record_failed_login(email)
    assert :ok = Lockouts.record_failed_login(email)
    assert is_nil(Lockouts.active_lockout(email))

    assert {:locked, expires_at} = Lockouts.record_failed_login(email)
    assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
    assert %DateTime{} = Lockouts.active_lockout(email)
  end

  test "the lock follows the account, not the source address", %{email: email} do
    configure(threshold: 2, window_seconds: 900, lock_seconds: 900)

    assert :ok = Lockouts.record_failed_login(email, %{ip: "198.51.100.1"})
    assert {:locked, _} = Lockouts.record_failed_login(email, %{ip: "203.0.113.4"})
    assert %DateTime{} = Lockouts.active_lockout(email)
  end

  test "identifiers are normalized so casing and whitespace cannot dodge the count",
       %{email: email} do
    configure(threshold: 2, window_seconds: 900, lock_seconds: 900)

    assert :ok = Lockouts.record_failed_login("  " <> String.upcase(email) <> " ")
    assert {:locked, _} = Lockouts.record_failed_login(email)
    assert %DateTime{} = Lockouts.active_lockout(String.upcase(email))
  end

  test "a successful sign-in clears the count", %{email: email} do
    configure(threshold: 2, window_seconds: 900, lock_seconds: 900)

    assert :ok = Lockouts.record_failed_login(email)
    assert :ok = Lockouts.clear(email)
    assert :ok = Lockouts.record_failed_login(email)
    assert is_nil(Lockouts.active_lockout(email))
  end

  test "an expired lock releases the account and forgives the failures behind it",
       %{email: email} do
    # A one-second lock, so the test can watch it expire rather than mock a clock.
    configure(threshold: 2, window_seconds: 900, lock_seconds: 1)

    assert :ok = Lockouts.record_failed_login(email)
    assert {:locked, _} = Lockouts.record_failed_login(email)

    Process.sleep(1_100)
    assert is_nil(Lockouts.active_lockout(email))

    # The failures that caused the expired lock must not still be counted, or
    # the next honest typo would re-lock the account immediately.
    assert :ok = Lockouts.record_failed_login(email)
    assert is_nil(Lockouts.active_lockout(email))
  end

  test "failures older than the window stop counting", %{email: email} do
    configure(threshold: 2, window_seconds: 1, lock_seconds: 900)

    assert :ok = Lockouts.record_failed_login(email)
    Process.sleep(1_100)
    assert :ok = Lockouts.record_failed_login(email)
    assert is_nil(Lockouts.active_lockout(email))
  end

  test "a blank or missing identifier is ignored rather than counted as one account" do
    assert :ok = Lockouts.record_failed_login(nil)
    assert :ok = Lockouts.record_failed_login("   ")
    assert is_nil(Lockouts.active_lockout(nil))
    assert is_nil(Lockouts.active_lockout("   "))
  end
end
