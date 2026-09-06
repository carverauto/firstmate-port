defmodule FirstmatePortWeb.Plugs.RateLimitTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Accounts.Password
  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Security.Lockouts
  alias FirstmatePort.Security.RateLimiter

  # The suite runs with every bucket raised out of the way (config/test.exs);
  # these tests tighten one bucket back down for their own duration. Everything
  # here shares 127.0.0.1 as the client address, which is exactly the subject
  # the plug keys on.
  defp tighten(bucket, limit, subject \\ "127.0.0.1") do
    put_env(RateLimiter, buckets: %{bucket => [limit: limit, window_seconds: 60]})
    on_exit(fn -> RateLimiter.clear(bucket, subject) end)
    RateLimiter.clear(bucket, subject)
  end

  test "requires an explicit response mode" do
    for mode <- [nil, :auto, :invalid] do
      assert_raise ArgumentError, ~r/:response_mode is required and must be :json or :html/, fn ->
        FirstmatePortWeb.Plugs.RateLimit.init(bucket: :auth_local, response_mode: mode)
      end
    end
  end

  describe "JSON endpoints" do
    test "answer 429 with retry-after once the bucket is spent" do
      tighten(:cli_device_auth, 1)

      assert build_conn() |> post(~p"/api/cli/auth/device") |> json_response(200)

      conn = post(build_conn(), ~p"/api/cli/auth/device")
      assert %{"error" => "rate_limited", "retry_after" => retry_after} = json_response(conn, 429)
      assert retry_after > 0
      assert [value] = get_resp_header(conn, "retry-after")
      assert String.to_integer(value) == retry_after
    end

    test "the device-code token endpoint answers slow_down so fm-steer backs off" do
      tighten(:cli_token_poll, 1)

      body = %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => "nope"
      }

      # First call is allowed through and rejected on its merits, not by the limiter.
      assert build_conn() |> post(~p"/api/cli/auth/token", body) |> json_response(400)

      conn = post(build_conn(), ~p"/api/cli/auth/token", body)
      assert %{"error" => "slow_down"} = json_response(conn, 429)
    end
  end

  describe "authenticated usage API" do
    test "limits usage writes by actor and sends API security headers" do
      token = "usage-rate-limit-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        User.bootstrap_agent(
          %{
            email: "#{token}@localhost",
            name: "Usage agent",
            hashed_api_key: User.hash_token(token)
          },
          authorize?: false
        )

      subject = {"127.0.0.1", agent.id}
      tighten(:api_write, 1, subject)
      params = %{"provider" => "anthropic", "label" => "rate-limit", "used" => 1.0}

      request = fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/usage", params)
      end

      conn = request.()
      assert %{"used" => 1.0} = json_response(conn, 200)
      assert ["1"] = get_resp_header(conn, "x-ratelimit-limit")
      assert ["0"] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [reset] = get_resp_header(conn, "x-ratelimit-reset")
      assert String.to_integer(reset) >= System.system_time(:second)
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "default-src 'none'"
      assert get_resp_header(conn, "content-security-policy-report-only") == []
      assert RateLimiter.remaining(:api_write, subject) == 0

      conn = request.()
      assert %{"error" => "rate_limited", "retry_after" => retry_after} = json_response(conn, 429)
      assert retry_after > 0
      assert [value] = get_resp_header(conn, "retry-after")
      assert String.to_integer(value) == retry_after
      assert [^policy] = get_resp_header(conn, "content-security-policy")
    end

    test "counts anonymous requests before rejecting them and protects the rejection" do
      tighten(:api_write, 1, {"127.0.0.1", :anonymous})

      conn = post(build_conn(), ~p"/api/usage", %{})
      assert %{"error" => "unauthorized"} = json_response(conn, 401)
      assert ["0"] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "default-src 'none'"

      for {method, path} <- [{:get, ~p"/api/usage"}, {:post, ~p"/api/route"}] do
        conn = dispatch(build_conn(), @endpoint, method, path, %{})
        assert %{"error" => "rate_limited"} = json_response(conn, 429)
        assert [_retry_after] = get_resp_header(conn, "retry-after")
        assert [^policy] = get_resp_header(conn, "content-security-policy")
      end
    end
  end

  describe "rate limit headers" do
    test "are on allowed responses and count down" do
      tighten(:cli_device_auth, 5)

      conn = post(build_conn(), ~p"/api/cli/auth/device")
      assert ["5"] = get_resp_header(conn, "x-ratelimit-limit")
      assert ["4"] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [reset] = get_resp_header(conn, "x-ratelimit-reset")
      assert String.to_integer(reset) > System.system_time(:second)

      conn = post(build_conn(), ~p"/api/cli/auth/device")
      assert ["3"] = get_resp_header(conn, "x-ratelimit-remaining")
    end

    test "delayed denials keep the original reset and a matching retry-after" do
      tighten(:cli_device_auth, 1)
      first = post(build_conn(), ~p"/api/cli/auth/device")
      assert json_response(first, 200)
      assert [reset_header] = get_resp_header(first, "x-ratelimit-reset")
      reset = String.to_integer(reset_header)
      Process.sleep(2_100)

      for _ <- 1..2 do
        before = System.system_time(:second)
        conn = post(build_conn(), ~p"/api/cli/auth/device")
        after_request = System.system_time(:second)
        assert %{"retry_after" => retry_after} = json_response(conn, 429)
        assert [^reset_header] = get_resp_header(conn, "x-ratelimit-reset")
        assert [retry_header] = get_resp_header(conn, "retry-after")
        assert String.to_integer(retry_header) == retry_after
        assert retry_after in max(reset - after_request, 1)..max(reset - before, 1)
        assert reset < before + 60
      end
    end

    test "report nothing remaining on a denial" do
      tighten(:cli_device_auth, 1)

      post(build_conn(), ~p"/api/cli/auth/device")
      conn = post(build_conn(), ~p"/api/cli/auth/device")

      assert ["0"] = get_resp_header(conn, "x-ratelimit-remaining")
    end
  end

  describe "browser sign-in" do
    setup do
      put_env(:local_auth, true)
      :ok
    end

    test "redirects to the sign-in page with a flash rather than a bare 429" do
      tighten(:auth_local, 1)

      email = "rate-limited-#{System.unique_integer([:positive])}@localhost"

      {:ok, _user} =
        User.bootstrap_admin(
          %{email: email, name: "Admin", hashed_password: Password.hash("known-password")},
          authorize?: false
        )

      on_exit(fn -> Lockouts.clear(email) end)
      params = %{"email" => email, "password" => "wrong-password"}
      first = post(build_conn(), ~p"/auth/local", params)
      assert redirected_to(first) == "/login"

      assert Phoenix.Flash.get(first.assigns.flash, :error) ==
               "That email and password did not match an account."

      conn = post(build_conn(), ~p"/auth/local", params)
      assert redirected_to(conn, 303) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
    end
  end

  describe "the Discord interactions endpoint" do
    test "is limited but still refuses an unsigned request rather than hanging" do
      tighten(:discord_interactions, 1)

      body = Jason.encode!(%{"type" => 1})

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/interactions", body)

      assert response(conn, 401)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/interactions", body)

      assert json_response(conn, 429)
    end
  end
end
