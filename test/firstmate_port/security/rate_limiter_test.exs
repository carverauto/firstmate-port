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

    before = System.system_time(:second)
    assert {:ok, 3, reset, 2} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert reset >= before + 60
    assert reset <= System.system_time(:second) + 60
    assert {:ok, 3, ^reset, 1} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:ok, 3, ^reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, 3, ^reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
  end

  test "a denied attempt is not counted, so hammering does not extend the penalty",
       %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]

    assert {:ok, 1, reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)

    for _ <- 1..5 do
      assert {:error, 1, ^reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    end
  end

  test "reset stays anchored to the recorded attempt after delayed denials", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]
    assert {:ok, 1, reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    Process.sleep(2_100)

    for _ <- 1..2 do
      assert {:error, 1, ^reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
      assert reset < System.system_time(:second) + 60
    end
  end

  test "expired attempts release capacity and produce a new reset", %{subject: subject} do
    opts = [limit: 1, window_seconds: 1]
    assert {:ok, 1, reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, 1, ^reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)

    Process.sleep(2_100)

    assert RateLimiter.remaining(:auth_local, subject, opts) == 1
    assert {:ok, 1, next_reset, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert next_reset > reset
  end

  test "subjects do not share a budget", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]
    other = subject <> "-other"
    on_exit(fn -> RateLimiter.clear(:auth_local, other) end)

    assert {:ok, _, _, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, 1, _, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:ok, _, _, _} = RateLimiter.check_and_record(:auth_local, other, opts)
  end

  test "buckets do not share a budget", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]
    on_exit(fn -> RateLimiter.clear(:cli_device_auth, subject) end)

    assert {:ok, _, _, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, 1, _, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:ok, _, _, _} = RateLimiter.check_and_record(:cli_device_auth, subject, opts)
  end

  test "clear/2 releases a subject", %{subject: subject} do
    opts = [limit: 1, window_seconds: 60]

    assert {:ok, _, _, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert {:error, 1, _, 0} = RateLimiter.check_and_record(:auth_local, subject, opts)
    assert :ok = RateLimiter.clear(:auth_local, subject)
    assert {:ok, _, _, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
  end

  test "remaining/3 counts down from the limit", %{subject: subject} do
    opts = [limit: 3, window_seconds: 60]

    assert RateLimiter.remaining(:auth_local, subject, opts) == 3
    assert {:ok, _, _, _} = RateLimiter.check_and_record(:auth_local, subject, opts)
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
