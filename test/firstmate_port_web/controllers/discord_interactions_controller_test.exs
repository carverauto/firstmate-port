defmodule FirstmatePortWeb.DiscordInteractionsControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Tenancy

  setup do
    previous = Application.get_env(:firstmate_port, :discord_host_suffix)
    on_exit(fn -> Application.put_env(:firstmate_port, :discord_host_suffix, previous) end)

    local = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, _} = Tenant.seed(%{slug: "local", name: "local"}, authorize?: false)
    store_key("local", local)

    {:ok, local: local}
  end

  defp store_key(slug, {public, _private}) do
    {:ok, _} =
      Credential.create(
        %{provider: "discord", key: "public_key", value: Base.encode16(public, case: :lower)},
        authorize?: false,
        tenant: slug
      )
  end

  defp seed_tenant(slug, key) do
    {:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(%{email: "#{slug}@example.com", name: slug, tenant_slug: slug},
        authorize?: false
      )

    {:ok, _} =
      Credential.create(
        %{
          provider: "discord",
          key: "public_key",
          value: Base.encode16(elem(key, 0), case: :lower)
        },
        Tenancy.opts(user)
      )

    user
  end

  defp sign({_public, private}, ts, body) do
    :crypto.sign(:eddsa, :none, ts <> body, [private, :ed25519])
    |> Base.encode16(case: :lower)
  end

  defp now, do: Integer.to_string(System.system_time(:second))

  defp interact(conn, body, opts) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")

    conn =
      case opts[:host] do
        nil -> conn
        host -> %{conn | host: host}
      end

    conn =
      case opts[:signature] do
        nil -> conn
        signature -> put_req_header(conn, "x-signature-ed25519", signature)
      end

    conn =
      case opts[:timestamp] do
        nil -> conn
        timestamp -> put_req_header(conn, "x-signature-timestamp", timestamp)
      end

    post(conn, "/interactions", body)
  end

  defp signed(conn, key, body, opts \\ []) do
    ts = opts[:timestamp] || now()
    interact(conn, body, Keyword.merge(opts, signature: sign(key, ts, body), timestamp: ts))
  end

  describe "single-tenant (no Discord host suffix configured)" do
    setup do
      Application.put_env(:firstmate_port, :discord_host_suffix, nil)
      :ok
    end

    test "PING with valid Ed25519 returns PONG", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":1}))

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "missing signature is 401", %{conn: conn} do
      conn = interact(conn, ~s({"type":1}), timestamp: now())

      assert conn.status == 401
      assert conn.resp_body == "unauthorized"
    end

    test "invalid signature is 401", %{conn: conn} do
      conn =
        interact(conn, ~s({"type":1}),
          signature: String.duplicate("00", 64),
          timestamp: now()
        )

      assert conn.status == 401
    end

    test "a signature no tenant can verify is 401", %{conn: conn} do
      conn = signed(conn, :crypto.generate_key(:eddsa, :ed25519), ~s({"type":1}))

      assert conn.status == 401
    end

    test "a body altered after signing is 401", %{conn: conn, local: local} do
      ts = now()

      conn =
        interact(conn, ~s({"type":1,"tampered":true}),
          signature: sign(local, ts, ~s({"type":1})),
          timestamp: ts
        )

      assert conn.status == 401
    end

    test "a stale timestamp is 401 even with a good signature", %{conn: conn, local: local} do
      stale = Integer.to_string(System.system_time(:second) - 4000)
      conn = signed(conn, local, ~s({"type":1}), timestamp: stale)

      assert conn.status == 401
    end

    test "a missing timestamp is 401", %{conn: conn, local: local} do
      conn = interact(conn, ~s({"type":1}), signature: sign(local, "", ~s({"type":1})))

      assert conn.status == 401
    end

    test "an unparseable timestamp is 401", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":1}), timestamp: "not-a-number")

      assert conn.status == 401
    end

    test "signed command with NATS down is 502 so Discord retries", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":2,"data":{"name":"ping"}}))

      assert conn.status == 502
    end
  end

  describe "multi-tenant (Discord host suffix configured)" do
    setup do
      Application.put_env(:firstmate_port, :discord_host_suffix, ".example.com")
      :ok
    end

    test "the OSS hostname is the default tenant", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":1}), host: "discord-firstmate.example.com")

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "a tenant's own hostname verifies its own key", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)

      conn = signed(conn, acme, ~s({"type":1}), host: "discord-acme.example.com")

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "one tenant's key is 401 on another tenant's hostname", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)

      # acme's app signing on the OSS hostname...
      conn = signed(conn, acme, ~s({"type":1}), host: "discord-firstmate.example.com")
      assert conn.status == 401
    end

    test "the OSS key is 401 on a tenant hostname", %{conn: conn, local: local} do
      seed_tenant("acme", :crypto.generate_key(:eddsa, :ed25519))

      conn = signed(conn, local, ~s({"type":1}), host: "discord-acme.example.com")

      assert conn.status == 401
    end

    test "a hostname for a tenant that does not exist is 401", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":1}), host: "discord-nobody.example.com")

      assert conn.status == 401
    end

    test "a hostname outside the suffix is 401", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":1}), host: "discord-firstmate.evil.test")

      assert conn.status == 401
    end

    test "a non-Discord hostname does not fall back to the default tenant", %{
      conn: conn,
      local: local
    } do
      conn = signed(conn, local, ~s({"type":1}), host: "firstmate.example.com")

      assert conn.status == 401
    end

    test "an unknown host and an unknown key are indistinguishable", %{conn: conn, local: local} do
      unknown_host = signed(conn, local, ~s({"type":1}), host: "discord-nobody.example.com")

      unknown_key =
        signed(
          conn,
          :crypto.generate_key(:eddsa, :ed25519),
          ~s({"type":1}),
          host: "discord-firstmate.example.com"
        )

      assert unknown_host.status == unknown_key.status
      assert unknown_host.resp_body == unknown_key.resp_body
    end

    test "two tenants sharing an app key each stay on their own hostname", %{conn: conn} do
      shared = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", shared)
      seed_tenant("beta", shared)

      for host <- ["discord-acme.example.com", "discord-beta.example.com"] do
        conn = signed(conn, shared, ~s({"type":1}), host: host)
        assert json_response(conn, 200) == %{"type" => 1}
      end
    end
  end

  describe "Discord hostnames serve nothing but the interactions endpoint" do
    setup do
      Application.put_env(:firstmate_port, :discord_host_suffix, ".example.com")
      :ok
    end

    test "the portal, MCP, auth, and health are all 404 there", %{conn: conn} do
      for path <- ["/", "/login", "/mcp", "/healthz", "/api/credentials", "/auth/oidc"] do
        conn = get(%{conn | host: "discord-firstmate.example.com"}, path)

        assert conn.status == 404, "#{path} answered #{conn.status} on a Discord hostname"
      end
    end

    test "POST to another path is 404 there", %{conn: conn} do
      conn =
        %{conn | host: "discord-firstmate.example.com"}
        |> put_req_header("content-type", "application/json")
        |> post("/api/diagrams", ~s({}))

      assert conn.status == 404
    end

    test "the portal still answers on its own hostname", %{conn: conn} do
      conn = get(%{conn | host: "firstmate.example.com"}, "/healthz")

      assert conn.status == 200
    end
  end

  describe "body size" do
    setup do
      Application.put_env(:firstmate_port, :discord_host_suffix, nil)
      :ok
    end

    test "an oversized body is refused without being verified", %{conn: conn, local: local} do
      body = ~s({"type":1,"pad":") <> String.duplicate("a", 100_000) <> ~s("})
      ts = now()

      # Correctly signed, and still refused: the cap is applied while the body is
      # being read, so an oversized payload is never buffered or verified.
      assert_error_sent 413, fn ->
        interact(conn, body, signature: sign(local, ts, body), timestamp: ts)
      end
    end
  end
end
