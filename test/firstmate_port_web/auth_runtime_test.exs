defmodule FirstmatePortWeb.AuthRuntimeTest do
  @moduledoc """
  The two supported runtimes, from the outside: a minimal stack on local auth
  with no identity provider, and a stack where OIDC is configured but the
  provider never becomes usable. Both must keep serving.
  """
  use FirstmatePortWeb.ConnCase

  alias FirstmatePort.Auth.OIDC

  setup do
    original_oidc = Application.get_env(:firstmate_port, OIDC)
    original_local = Application.get_env(:firstmate_port, :dev_auth)

    on_exit(fn ->
      Application.put_env(:firstmate_port, OIDC, original_oidc)
      Application.put_env(:firstmate_port, :dev_auth, original_local)
    end)

    :ok
  end

  defp put_oidc(cfg), do: Application.put_env(:firstmate_port, OIDC, cfg)
  defp put_local_auth(on?), do: Application.put_env(:firstmate_port, :dev_auth, on?)

  describe "local auth, no identity provider (docker compose, and k8s before an IdP exists)" do
    setup do
      put_oidc(issuer: nil, client_id: nil, client_secret: nil)
      put_local_auth(true)
    end

    test "healthz stays up", %{conn: conn} do
      assert text_response(get(conn, ~p"/healthz"), 200) =~ "ok"
    end

    test "login offers the local email form and no provider button", %{conn: conn} do
      html = html_response(get(conn, ~p"/login"), 200)

      assert html =~ "Enter the port"
      refute html =~ "Continue with identity provider"
      refute html =~ "Sign-in is not configured"
    end

    test "a stranger can sign in locally with an allowed email", %{conn: conn} do
      conn = post(conn, ~p"/auth/dev", %{"email" => "stranger@localhost"})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :guardian_token)
    end

    test "the provider route redirects instead of failing", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "OIDC configured but the provider never loads" do
    setup do
      # Nothing starts a provider process for this issuer, which is the state
      # the portal is left in after a discovery, JWKS, TLS, or CA failure.
      put_oidc(
        issuer: "https://idp.example.com",
        client_id: "firstmate-port",
        client_secret: "secret"
      )

      put_local_auth(true)
    end

    test "the portal keeps serving", %{conn: conn} do
      assert text_response(get(conn, ~p"/healthz"), 200) =~ "ok"
    end

    test "OIDC reads as unavailable, not as unconfigured" do
      assert OIDC.configured?()
      refute OIDC.ready?()
      refute OIDC.enabled?()
      assert OIDC.status() == :unavailable
    end

    test "login keeps local sign-in and says the provider is unreachable", %{conn: conn} do
      html = html_response(get(conn, ~p"/login"), 200)

      assert html =~ "Enter the port"
      assert html =~ "not reachable"
      refute html =~ "Continue with identity provider"
    end

    test "the provider route redirects rather than raising", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc")

      assert redirected_to(conn) == "/login"
    end

    test "the callback route redirects rather than raising", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "whatever", "state" => "x"})

      assert redirected_to(conn) == "/login"
    end

    test "authorization server metadata says so instead of inventing endpoints", %{conn: conn} do
      body = json_response(get(conn, ~p"/.well-known/oauth-authorization-server"), 503)

      assert body["error"] == "oidc_not_configured"
    end
  end

  describe "no sign-in configured at all" do
    setup do
      put_oidc(issuer: nil, client_id: nil, client_secret: nil)
      put_local_auth(false)
    end

    test "healthz stays up", %{conn: conn} do
      assert text_response(get(conn, ~p"/healthz"), 200) =~ "ok"
    end

    test "login says so plainly", %{conn: conn} do
      html = html_response(get(conn, ~p"/login"), 200)

      assert html =~ "Sign-in is not configured"
      refute html =~ "Continue with identity provider"
      refute html =~ "Enter the port"
    end

    test "local sign-in is not reachable", %{conn: conn} do
      conn = post(conn, ~p"/auth/dev", %{"email" => "stranger@localhost"})

      assert response(conn, 404)
    end
  end
end
