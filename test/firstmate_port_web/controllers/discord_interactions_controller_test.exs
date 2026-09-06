defmodule FirstmatePortWeb.DiscordInteractionsControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Tenancy

  @oss_app "111111111111111111"
  @acme_app "222222222222222222"

  setup do
    previous = Application.get_env(:firstmate_port, :discord_interactions_hosts)
    Application.put_env(:firstmate_port, :discord_interactions_hosts, [])

    on_exit(fn ->
      Application.put_env(:firstmate_port, :discord_interactions_hosts, previous)
    end)

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

  defp claim(slug, application_id) do
    {:ok, tenant} = Tenant.get_by_slug(slug, authorize?: false)

    {:ok, _} =
      Tenant.claim_discord_application(tenant, %{discord_application_id: application_id},
        authorize?: false
      )

    :ok
  end

  defp sign({_public, private}, ts, body) do
    :crypto.sign(:eddsa, :none, ts <> body, [private, :ed25519])
    |> Base.encode16(case: :lower)
  end

  defp now, do: Integer.to_string(System.system_time(:second))

  # A PING shaped the way Discord sends one: the application it is calling for
  # is named in the payload.
  defp ping(application_id \\ nil)
  defp ping(nil), do: ~s({"type":1})
  defp ping(application_id), do: ~s({"type":1,"application_id":"#{application_id}"})

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

  describe "one application (nothing claimed)" do
    test "PING with valid Ed25519 returns PONG", %{conn: conn, local: local} do
      conn = signed(conn, local, ping(@oss_app))

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "PONG even when the payload names no application at all", %{conn: conn, local: local} do
      conn = signed(conn, local, ping())

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "missing signature is 401", %{conn: conn} do
      conn = interact(conn, ping(@oss_app), timestamp: now())

      assert conn.status == 401
      assert conn.resp_body == "unauthorized"
    end

    test "invalid signature is 401", %{conn: conn} do
      conn =
        interact(conn, ping(@oss_app),
          signature: String.duplicate("00", 64),
          timestamp: now()
        )

      assert conn.status == 401
    end

    test "a signature no tenant can verify is 401", %{conn: conn} do
      conn = signed(conn, :crypto.generate_key(:eddsa, :ed25519), ping(@oss_app))

      assert conn.status == 401
    end

    test "a body altered after signing is 401", %{conn: conn, local: local} do
      ts = now()

      conn =
        interact(conn, ~s({"type":1,"tampered":true}),
          signature: sign(local, ts, ping()),
          timestamp: ts
        )

      assert conn.status == 401
    end

    test "a stale timestamp is 401 even with a good signature", %{conn: conn, local: local} do
      stale = Integer.to_string(System.system_time(:second) - 4000)
      conn = signed(conn, local, ping(@oss_app), timestamp: stale)

      assert conn.status == 401
    end

    test "a missing timestamp is 401", %{conn: conn, local: local} do
      conn = interact(conn, ping(@oss_app), signature: sign(local, "", ping(@oss_app)))

      assert conn.status == 401
    end

    test "an unparseable timestamp is 401", %{conn: conn, local: local} do
      conn = signed(conn, local, ping(@oss_app), timestamp: "not-a-number")

      assert conn.status == 401
    end

    test "signed command with NATS down is 502 so Discord retries", %{conn: conn, local: local} do
      conn = signed(conn, local, ~s({"type":2,"data":{"name":"ping"}}))

      assert conn.status == 502
    end
  end

  describe "many applications on one URL" do
    test "an application resolves to the tenant that claimed it", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      claim("acme", @acme_app)

      conn = signed(conn, acme, ping(@acme_app))

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "the default tenant keeps answering for applications nobody claimed", %{
      conn: conn,
      local: local
    } do
      seed_tenant("acme", :crypto.generate_key(:eddsa, :ed25519))
      claim("acme", @acme_app)

      conn = signed(conn, local, ping(@oss_app))

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "one tenant's key cannot answer for another tenant's application", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      beta = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      seed_tenant("beta", beta)
      claim("acme", @acme_app)

      # beta's app signing while naming acme's application.
      conn = signed(conn, beta, ping(@acme_app))

      assert conn.status == 401
    end

    test "the default tenant's key cannot answer for a claimed application", %{
      conn: conn,
      local: local
    } do
      seed_tenant("acme", :crypto.generate_key(:eddsa, :ed25519))
      claim("acme", @acme_app)

      conn = signed(conn, local, ping(@acme_app))

      assert conn.status == 401
    end

    test "a claim of its own does not stop the default tenant answering", %{
      conn: conn,
      local: local
    } do
      claim("local", @oss_app)

      # Every one of these is the default tenant's key over the default tenant's
      # request. Nothing about how the payload names - or fails to name - an
      # application may turn a correctly signed interaction into a 401; that is
      # what Discord's endpoint validation would trip over.
      assert json_response(signed(conn, local, ping(@oss_app)), 200) == %{"type" => 1}

      assert json_response(signed(conn, local, ping("999999999999999999")), 200) ==
               %{"type" => 1}

      assert json_response(signed(conn, local, ping()), 200) == %{"type" => 1}
    end

    test "an unclaimed application and an unverifiable key are indistinguishable", %{
      conn: conn,
      local: local
    } do
      seed_tenant("acme", :crypto.generate_key(:eddsa, :ed25519))
      claim("acme", @acme_app)

      unknown_application = signed(conn, local, ping(@acme_app))
      unknown_key = signed(conn, :crypto.generate_key(:eddsa, :ed25519), ping(@oss_app))

      assert unknown_application.status == unknown_key.status
      assert unknown_application.resp_body == unknown_key.resp_body
    end

    test "no near-miss on a claimed id reaches the tenant holding it", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      claim("acme", @acme_app)

      # Signed by acme's key every time. A claim is matched whole, so padding,
      # quoting, a JSON number instead of a string, or an operator object all
      # miss it and land on the default tenant - whose key is not acme's.
      for body <- [
            ~s({"type":1,"application_id":"#{@acme_app}' or 1=1"}),
            ~s({"type":1,"application_id":" #{@acme_app} "}),
            ~s({"type":1,"application_id":"#{@acme_app}0"}),
            ~s({"type":1,"application_id":#{@acme_app}}),
            ~s({"type":1,"application_id":null}),
            ~s({"type":1,"application_id":{"$ne":null}}),
            ~s({"type":1,"application_id":["#{@acme_app}"]})
          ] do
        assert signed(conn, acme, body).status == 401, "#{body} reached acme"
      end
    end

    test "a verified command is published on the claiming tenant's subject", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      claim("acme", @acme_app)

      body = ~s({"type":2,"application_id":"#{@acme_app}","data":{"name":"ping"}})

      # NATS is down in test, so a 502 is the proof the request got past
      # verification and was routed at all - and it was routed as acme.
      assert signed(conn, acme, body).status == 502
    end
  end

  describe "published interactions hostnames serve nothing else" do
    setup do
      Application.put_env(:firstmate_port, :discord_interactions_hosts, [
        "discord.example.com"
      ])

      :ok
    end

    test "the portal, MCP, auth, and health are all 404 there", %{conn: conn} do
      for path <- ["/", "/login", "/mcp", "/healthz", "/api/credentials", "/auth/oidc"] do
        conn = get(%{conn | host: "discord.example.com"}, path)

        assert conn.status == 404, "#{path} answered #{conn.status} on an interactions hostname"
      end
    end

    test "POST to another path is 404 there", %{conn: conn} do
      conn =
        %{conn | host: "discord.example.com"}
        |> put_req_header("content-type", "application/json")
        |> post("/api/diagrams", ~s({}))

      assert conn.status == 404
    end

    test "interactions still answer on the published hostname", %{conn: conn, local: local} do
      conn = signed(conn, local, ping(@oss_app), host: "discord.example.com")

      assert json_response(conn, 200) == %{"type" => 1}
    end

    test "the portal still answers on its own hostname", %{conn: conn} do
      conn = get(%{conn | host: "firstmate.example.com"}, "/healthz")

      assert conn.status == 200
    end

    test "the hostname does not decide the tenant", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      claim("acme", @acme_app)

      # Every tenant is served by the one published hostname.
      conn = signed(conn, acme, ping(@acme_app), host: "discord.example.com")

      assert json_response(conn, 200) == %{"type" => 1}
    end
  end

  describe "body size" do
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
