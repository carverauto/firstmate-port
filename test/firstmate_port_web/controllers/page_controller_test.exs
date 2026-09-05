defmodule FirstmatePortWeb.PageControllerTest do
  use FirstmatePortWeb.ConnCase

  test "GET / redirects anonymous browsers to login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET /healthz is public", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert text_response(conn, 200) =~ "ok"
  end

  test "GET /login is public", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Sign in"
  end
end
