defmodule FirstmatePortWeb.Plugs.LockoutCheckTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Accounts.Password
  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Security.Lockouts
  alias FirstmatePortWeb.Plugs.LockoutCheck

  setup do
    email = "locked-#{System.unique_integer([:positive])}@localhost"
    put_env(:local_auth, true)
    put_env(Lockouts, threshold: 2, window_seconds: 900, lock_seconds: 900)
    on_exit(fn -> Lockouts.clear(email) end)

    {:ok, _user} =
      User.bootstrap_admin(
        %{email: email, name: "Admin", hashed_password: Password.hash("known-password")},
        authorize?: false
      )

    {:ok, email: email}
  end

  test "repeated rejected sign-ins lock the account out of the form", %{email: email} do
    params = %{"email" => email, "password" => "wrong-password"}

    conn = post(build_conn(), ~p"/auth/local", params)
    assert redirected_to(conn) == "/login"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "That email and password did not match an account."

    conn = post(build_conn(), ~p"/auth/local", params)
    assert redirected_to(conn) == "/login"

    # Third attempt never reaches the sign-in logic: the lockout answers first.
    conn = post(build_conn(), ~p"/auth/local", params)
    assert redirected_to(conn, 303) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed sign-ins"
    assert [_retry_after] = get_resp_header(conn, "retry-after")

    refute is_nil(Lockouts.active_lockout(params["email"]))
  end

  test "a successful sign-in clears the failures behind it", %{email: email} do
    bad = %{"email" => email, "password" => "wrong-password"}
    assert build_conn() |> post(~p"/auth/local", bad) |> redirected_to() == "/login"

    conn =
      post(build_conn(), ~p"/auth/local", %{"email" => email, "password" => "known-password"})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :guardian_token)
    assert is_nil(Lockouts.active_lockout(email))

    conn = post(build_conn(), ~p"/auth/local", bad)
    assert redirected_to(conn) == "/login"
    assert is_nil(Lockouts.active_lockout(email))

    post(build_conn(), ~p"/auth/local", bad)
    refute is_nil(Lockouts.active_lockout(email))
  end

  test "an array-shaped email cannot bypass an active lockout", %{email: email} do
    assert :ok = Lockouts.record_failed_login(email)
    assert {:locked, locked_until} = Lockouts.record_failed_login(email)

    body = URI.encode_query([{"email[]", email}, {"password", "known-password"}])

    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(~p"/auth/local", body)

    assert redirected_to(conn) == "/login"
    refute get_session(conn, :guardian_token)

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "That email and password did not match an account."

    assert Lockouts.active_lockout(email) == locked_until
  end

  test "non-binary credentials are rejected without coercion", %{email: email} do
    for params <- [
          %{"email" => [email], "password" => "known-password"},
          %{"email" => %{"value" => email}, "password" => "known-password"},
          %{"email" => nil, "password" => "known-password"},
          %{"email" => email, "password" => ["known-password"]},
          %{"email" => email, "password" => %{"value" => "known-password"}},
          %{"email" => email, "password" => nil}
        ] do
      Lockouts.clear(email)
      conn = post(build_conn(), ~p"/auth/local", params)

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :guardian_token)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password did not match an account."
    end
  end

  describe "the plug itself" do
    test "lets a request with no identifier through" do
      conn =
        :post
        |> Plug.Test.conn("/auth/local", %{})
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:params, %{})
        |> LockoutCheck.call(LockoutCheck.init(actor_id_param: "email"))

      refute conn.halted
    end

    test "redirects locked callers regardless of Accept header" do
      email = "json-#{System.unique_integer([:positive])}@example.com"
      put_env(Lockouts, threshold: 1, window_seconds: 900, lock_seconds: 900)
      on_exit(fn -> Lockouts.clear(email) end)
      assert {:locked, _} = Lockouts.record_failed_login(email)

      conn =
        :post
        |> Plug.Test.conn("/auth/local", %{})
        |> put_req_header("accept", "application/json")
        |> assign(:flash, %{})
        |> Map.put(:params, %{"email" => email})
        |> LockoutCheck.call(LockoutCheck.init(actor_id_param: "email"))

      assert conn.halted
      assert redirected_to(conn, 303) == "/login"
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many failed sign-ins"
    end

    test "requires an identifier source" do
      assert_raise ArgumentError, "LockoutCheck requires :actor_id_param", fn ->
        LockoutCheck.init([])
      end
    end
  end
end

