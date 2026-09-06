defmodule FirstmatePort.Security.RateLimiterTest do
  use ExUnit.Case, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Security.RateLimiter

  setup do
    subject = "test-#{System.unique_integer([:positive])}"
    on_exit(fn -> RateLimiter.clear(:auth_local, subject) end)
    {:ok, subject: subject}
  end

  test "allows up to the limit and then denies", %{subject: subject} do
    opts = [limit: 3, window_seconds: 60]

    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, retry_after} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert retry_after > 0
    assert retry_after <= 60
  end

  test "a denied attempt is not counted, so hammering does not extend the penalty",
       %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]

    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, first} = RateLimiter.check_and_record(:auth_local, subject, opts)
    Enum.each(1..5, fn _ -> RateLimiter.check_and_record(:auth_local, subject, opts) end)
    assert {:error, last} = RateLimiter.check_and_record(:auth_local, subject, opts)

    # Same single recorded attempt is still the one expiring, so the wait only
    # shrinks with the clock.
    assert last <= first
  end

  test "reset stays anchored to the recorded attempt after delayed denials", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]
    before = System.system_time(:second)
    empty_reset = RateLimiter.reset_at(:auth_local, subject, opts)
    assert empty_reset >= before + 60
    assert empty_reset <= System.system_time(:second) + 60

    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    reset = RateLimiter.reset_at(:auth_local, subject, opts)
    Process.sleep(2_100)

    for _ <- 1..2 do
      before = System.system_time(:second)
      assert {:error, retry_after} = RateLimiter.check_and_record(:auth_local, subject, opts)
      after_request = System.system_time(:second)
      assert RateLimiter.reset_at(:auth_local, subject, opts) == reset
      assert retry_after in max(reset - after_request, 1)..max(reset - before, 1)
      assert reset < before + 60
    end
  end

  test "subjects do not share a budget", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]
    other = subject <> "-other"
    on_exit(fn -> RateLimiter.clear(:auth_local, other) end)

    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert :ok = RateLimiter.check_and_record(:auth_local, other, opts)
  end

  test "buckets do not share a budget", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]
    on_exit(fn -> RateLimiter.clear(:cli_device_auth, subject) end)

    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert :ok = RateLimiter.check_and_record(:cli_device_auth, subject, opts)
  end

  test "clear/2 releases a subject", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]

    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert :ok = RateLimiter.clear(:auth_local, subject)
    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
  end

  test "remaining/3 counts down from the limit", %{subject: subject} do
    opts = [limit: 3, window_seconds: 60]

    assert RateLimiter.remaining(:auth_local, subject, opts) == 3
    assert :ok = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert RateLimiter.remaining(:auth_local, subject, opts) == 2
  end

  describe "resolve_bucket/2" do
    test "an unknown bucket falls back to the configured default" do
      assert {limit, window} = RateLimiter.resolve_bucket(:no_such_bucket)
      assert is_integer(limit) and limit > 0
      assert is_integer(window) and window > 0
    end

    test "explicit opts win over configuration" do
      assert RateLimiter.resolve_bucket(:auth_local, limit: 7, window_seconds: 11) == {7, 11}
    end

    test "runtime configuration overrides the compiled-in bucket" do
      put_env(RateLimiter, buckets: %{auth_local: [limit: 2, window_seconds: 30]})

      assert RateLimiter.resolve_bucket(:auth_local) == {2, 30}
    end
  end
end

