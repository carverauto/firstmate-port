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

  test "GET /login has no farm-rolls copy and leaks no env var names", %{conn: conn} do
    body = conn |> get(~p"/login") |> html_response(200)
    refute body =~ "farm rolls"
    refute body =~ "Farm / demo rolls"
    refute body =~ "ALLOWED_EMAIL_DOMAIN"
    refute body =~ "OIDC_ISSUER"
    refute body =~ "OIDC_CLIENT_SECRET"
    refute body =~ "DEV_AUTH"
  end
end
