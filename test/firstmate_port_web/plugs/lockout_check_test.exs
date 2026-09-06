defmodule FirstmatePortWeb.Plugs.LockoutCheckTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Security.Lockouts
  alias FirstmatePortWeb.Plugs.LockoutCheck

  setup do
    email = "locked-#{System.unique_integer([:positive])}@localhost"
    put_env(:dev_auth, true)
    put_env(Lockouts, threshold: 2, window_seconds: 900, lock_seconds: 900)
    on_exit(fn -> Lockouts.clear(email) end)
    {:ok, email: email}
  end

  test "repeated rejected sign-ins lock the account out of the form", %{email: email} do
    # This address is not on the local allowlist, so each attempt is a failure.
    params = %{"email" => "intruder-#{System.unique_integer([:positive])}@nope.invalid"}
    on_exit(fn -> Lockouts.clear(params["email"]) end)

    conn = post(build_conn(), ~p"/auth/dev", params)
    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not on the local allowlist"

    conn = post(build_conn(), ~p"/auth/dev", params)
    assert redirected_to(conn) == "/login"

    # Third attempt never reaches the sign-in logic: the lockout answers first.
    conn = post(build_conn(), ~p"/auth/dev", params)
    assert redirected_to(conn, 303) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed sign-ins"
    assert [_retry_after] = get_resp_header(conn, "retry-after")

    refute is_nil(Lockouts.active_lockout(params["email"]))
    _ = email
  end

  test "a successful sign-in clears the failures behind it", %{email: email} do
    bad = %{"email" => "wrong-#{System.unique_integer([:positive])}@nope.invalid"}
    on_exit(fn -> Lockouts.clear(bad["email"]) end)

    post(build_conn(), ~p"/auth/dev", bad)

    conn = post(build_conn(), ~p"/auth/dev", %{"email" => email})
    assert redirected_to(conn) == "/"
    assert is_nil(Lockouts.active_lockout(email))
  end

  describe "the plug itself" do
    test "lets a request with no identifier through" do
      conn =
        :post
        |> Plug.Test.conn("/auth/dev", %{})
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:params, %{})
        |> LockoutCheck.call(LockoutCheck.init(actor_id_param: "email"))

      refute conn.halted
    end

    test "answers JSON callers with 423 rather than a redirect" do
      email = "json-#{System.unique_integer([:positive])}@example.com"
      put_env(Lockouts, threshold: 1, window_seconds: 900, lock_seconds: 900)
      on_exit(fn -> Lockouts.clear(email) end)
      assert {:locked, _} = Lockouts.record_failed_login(email)

      conn =
        :post
        |> Plug.Test.conn("/auth/dev", %{})
        |> Map.put(:params, %{"email" => email})
        |> LockoutCheck.call(LockoutCheck.init(actor_id_param: "email", response_mode: :json))

      assert conn.halted
      assert conn.status == 423
      assert Jason.decode!(conn.resp_body)["error"] == "account_temporarily_locked"
    end

    test "requires an identifier source" do
      assert_raise ArgumentError, ~r/actor_id_param/, fn -> LockoutCheck.init([]) end
    end
  end
end
