defmodule FirstmatePortWeb.AuthControllerTest do
  use FirstmatePortWeb.ConnCase

  @admin "ops-chief@example.org"

  setup do
    prev_dev = Application.get_env(:firstmate_port, :dev_auth)
    prev_admin = Application.get_env(:firstmate_port, :bootstrap_admin_email)
    Application.put_env(:firstmate_port, :dev_auth, true)
    Application.put_env(:firstmate_port, :bootstrap_admin_email, @admin)

    on_exit(fn ->
      Application.put_env(:firstmate_port, :dev_auth, prev_dev)
      Application.put_env(:firstmate_port, :bootstrap_admin_email, prev_admin)
    end)

    :ok
  end

  test "POST /auth/dev signs in the bootstrap admin outside the domain wall", %{conn: conn} do
    conn = post(conn, ~p"/auth/dev", %{email: @admin})
    assert redirected_to(conn) == "/"
    assert get_session(conn, :guardian_token)
  end

  test "POST /auth/dev still signs in allowlisted and local emails", %{conn: conn} do
    for email <- ["someone@localhost", "friend@example.com"] do
      conn = post(conn, ~p"/auth/dev", %{email: email})
      assert redirected_to(conn) == "/"
    end
  end

  test "POST /auth/dev rejects other emails", %{conn: conn} do
    conn = post(conn, ~p"/auth/dev", %{email: "stranger@elsewhere.dev"})
    assert redirected_to(conn) == "/login"
    refute get_session(conn, :guardian_token)
  end

  test "POST /auth/dev is not found when DEV_AUTH is off", %{conn: conn} do
    Application.put_env(:firstmate_port, :dev_auth, false)
    conn = post(conn, ~p"/auth/dev", %{email: @admin})
    assert response(conn, 404)
  end
end
