defmodule FirstmatePortWeb.AuthRuntimeTest do
  @moduledoc """
  The two supported runtimes, from the outside: a minimal stack on local auth
  with no identity provider, and a stack where OIDC is configured but the
  provider never becomes usable. Both must keep serving.
  """
  use FirstmatePortWeb.ConnCase

  alias FirstmatePort.Accounts.Bootstrap
  alias FirstmatePort.Accounts.Password
  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.OIDC

  @password "correct-horse-battery-staple"

  setup do
    original_oidc = Application.get_env(:firstmate_port, OIDC)
    original_local = Application.get_env(:firstmate_port, :local_auth)
    original_domain = Application.get_env(:firstmate_port, :allowed_email_domain)

    on_exit(fn ->
      Application.put_env(:firstmate_port, OIDC, original_oidc)
      Application.put_env(:firstmate_port, :local_auth, original_local)
      Application.put_env(:firstmate_port, :allowed_email_domain, original_domain)
    end)

    :ok
  end

  defp put_oidc(cfg), do: Application.put_env(:firstmate_port, OIDC, cfg)
  defp put_local_auth(on?), do: Application.put_env(:firstmate_port, :local_auth, on?)

  defp create_admin(email) do
    {:ok, user} =
      User.bootstrap_admin(
        %{email: email, name: "firstmate admin", hashed_password: Password.hash(@password)},
        authorize?: false
      )

    user
  end

  describe "local auth, no identity provider (docker compose, and k8s before an IdP exists)" do
    setup do
      put_oidc(issuer: nil, client_id: nil, client_secret: nil)
      put_local_auth(true)
      create_admin("admin@localhost")
      :ok
    end

    test "healthz stays up", %{conn: conn} do
      assert text_response(get(conn, ~p"/healthz"), 200) =~ "ok"
    end

    test "login offers the local account form and no provider button", %{conn: conn} do
      html = html_response(get(conn, ~p"/login"), 200)

      assert html =~ "Enter the port"
      assert html =~ ~s(name="password")
      refute html =~ "Continue with identity provider"
      refute html =~ "Sign-in is not configured"
    end

    test "the bootstrap account signs in", %{conn: conn} do
      conn = post(conn, ~p"/auth/local", %{"email" => "admin@localhost", "password" => @password})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :guardian_token)
    end

    test "an email with no password does not sign in", %{conn: conn} do
      # The old behaviour: any address on the allowed domain was let straight in.
      conn = post(conn, ~p"/auth/local", %{"email" => "stranger@localhost", "password" => ""})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :guardian_token)
    end

    test "a wrong password does not sign in", %{conn: conn} do
      conn = post(conn, ~p"/auth/local", %{"email" => "admin@localhost", "password" => "nope"})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :guardian_token)
    end

    test "an unknown account is refused the same way as a wrong password", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/local", %{"email" => "nobody@localhost", "password" => @password})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :guardian_token)
    end

    test "a random local address with the admin password does not sign in", %{conn: conn} do
      # Regression: local sign-in is bound to the one bootstrap admin account,
      # never to any local-looking mailbox. The old hole accepted any
      # @localhost or @example.com address.
      for domain <- ["localhost", "example.com"] do
        intruder =
          "intruder-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}@#{domain}"

        conn = post(conn, ~p"/auth/local", %{"email" => intruder, "password" => @password})

        assert redirected_to(conn) == "/login"
        refute get_session(conn, :guardian_token)
      end
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
      create_admin("admin@localhost")
      :ok
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

  describe "first-run bootstrap account" do
    setup do
      put_oidc(issuer: nil, client_id: nil, client_secret: nil)
      put_local_auth(true)
      :ok
    end

    test "a fresh portal can be signed into without any identity provider", %{conn: conn} do
      System.put_env("BOOTSTRAP_ADMIN_EMAIL", "captain@example.test")
      System.put_env("BOOTSTRAP_ADMIN_PASSWORD", "operator-chosen-secret")

      on_exit(fn ->
        System.delete_env("BOOTSTRAP_ADMIN_EMAIL")
        System.delete_env("BOOTSTRAP_ADMIN_PASSWORD")
      end)

      assert :ok = Bootstrap.ensure_admin!()

      conn =
        post(conn, ~p"/auth/local", %{
          "email" => "captain@example.test",
          "password" => "operator-chosen-secret"
        })

      assert redirected_to(conn) == "/"
      assert get_session(conn, :guardian_token)
    end

    test "only the configured bootstrap email signs in with its password", %{conn: conn} do
      System.put_env("BOOTSTRAP_ADMIN_EMAIL", "captain@localhost")
      System.put_env("BOOTSTRAP_ADMIN_PASSWORD", "operator-chosen-secret")

      on_exit(fn ->
        System.delete_env("BOOTSTRAP_ADMIN_EMAIL")
        System.delete_env("BOOTSTRAP_ADMIN_PASSWORD")
      end)

      assert :ok = Bootstrap.ensure_admin!()

      for intruder <- ["someone-else@localhost", "root@localhost", "captain@example.com"] do
        refused =
          post(conn, ~p"/auth/local", %{
            "email" => intruder,
            "password" => "operator-chosen-secret"
          })

        assert redirected_to(refused) == "/login"
        refute get_session(refused, :guardian_token)
      end

      admitted =
        post(conn, ~p"/auth/local", %{
          "email" => "captain@localhost",
          "password" => "operator-chosen-secret"
        })

      assert redirected_to(admitted) == "/"
      assert get_session(admitted, :guardian_token)
    end

    test "the generated first-boot password signs in and is printed only once", %{conn: conn} do
      Logger.put_module_level(Bootstrap, :info)
      on_exit(fn -> Logger.delete_module_level(Bootstrap) end)
      original_email = System.get_env("BOOTSTRAP_ADMIN_EMAIL")
      original_password = System.get_env("BOOTSTRAP_ADMIN_PASSWORD")
      System.put_env("BOOTSTRAP_ADMIN_EMAIL", "generated@example.test")
      System.delete_env("BOOTSTRAP_ADMIN_PASSWORD")

      on_exit(fn ->
        for {key, value} <- [
              {"BOOTSTRAP_ADMIN_EMAIL", original_email},
              {"BOOTSTRAP_ADMIN_PASSWORD", original_password}
            ] do
          if value, do: System.put_env(key, value), else: System.delete_env(key)
        end
      end)

      log = ExUnit.CaptureLog.capture_log([level: :info], fn -> Bootstrap.ensure_admin!() end)
      assert log =~ "generated@example.test"
      assert [_, password] = Regex.run(~r/password: ([A-Za-z0-9_-]+)/, log)

      signed_in =
        post(conn, ~p"/auth/local", %{"email" => "generated@example.test", "password" => password})

      assert redirected_to(signed_in) == "/"
      assert get_session(signed_in, :guardian_token)

      second_log =
        ExUnit.CaptureLog.capture_log([level: :info], fn -> Bootstrap.ensure_admin!() end)

      refute second_log =~ password
      {:ok, user} = User.get_by_email("generated@example.test", authorize?: false)
      assert User.valid_password?(user, password)
    end

    test "a second boot does not rotate the password" do
      System.put_env("BOOTSTRAP_ADMIN_EMAIL", "stable@example.test")
      System.put_env("BOOTSTRAP_ADMIN_PASSWORD", "first-password")
      on_exit(fn -> System.delete_env("BOOTSTRAP_ADMIN_EMAIL") end)
      on_exit(fn -> System.delete_env("BOOTSTRAP_ADMIN_PASSWORD") end)

      assert :ok = Bootstrap.ensure_admin!()
      {:ok, first} = User.get_by_email("stable@example.test", authorize?: false)

      System.put_env("BOOTSTRAP_ADMIN_PASSWORD", "second-password")
      assert :ok = Bootstrap.ensure_admin!()
      {:ok, second} = User.get_by_email("stable@example.test", authorize?: false)

      assert second.hashed_password == first.hashed_password
      assert User.valid_password?(second, "first-password")
      refute User.valid_password?(second, "second-password")
    end

    test "no account is created when local auth is off" do
      put_local_auth(false)
      System.put_env("BOOTSTRAP_ADMIN_EMAIL", "unwanted@example.test")
      on_exit(fn -> System.delete_env("BOOTSTRAP_ADMIN_EMAIL") end)

      assert :ok = Bootstrap.ensure_admin!()
      assert {:error, _} = User.get_by_email("unwanted@example.test", authorize?: false)
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
      conn = post(conn, ~p"/auth/local", %{"email" => "admin@localhost", "password" => @password})

      assert response(conn, 404)
    end
  end
end
