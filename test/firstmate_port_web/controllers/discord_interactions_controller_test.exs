defmodule FirstmatePortWeb.DiscordInteractionsControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.CaptainCalls
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Discord.Ask
  alias FirstmatePort.Discord.Attempts
  alias FirstmatePort.Inbox
  alias FirstmatePort.Portal.CaptainCall
  alias FirstmatePort.Tenancy

  @oss_app "111111111111111111"
  @acme_app "222222222222222222"

  setup do
    previous = Application.get_env(:firstmate_port, :discord_interactions_host)
    Application.put_env(:firstmate_port, :discord_interactions_host, nil)

    on_exit(fn ->
      Application.put_env(:firstmate_port, :discord_interactions_host, previous)
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

    {:ok, owner} =
      User.upsert_oidc(
        %{
          email: "default-owner@example.com",
          name: "Default owner",
          tenant_slug: Tenancy.default_slug()
        },
        authorize?: false
      )

    {:ok, _} =
      Tenant.claim_discord_application(tenant, %{discord_application_id: application_id},
        actor: owner,
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
      Application.put_env(:firstmate_port, :discord_interactions_host, "discord.example.com")

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

    test "a wrong path on that hostname is recorded as one, with the path", %{conn: conn} do
      # The trailing slash a hand-copied Interactions Endpoint URL picks up.
      # Discord reports it exactly like a request that never arrived, so the
      # difference has to be visible somewhere.
      conn =
        %{conn | host: "discord.example.com"}
        |> put_req_header("content-type", "application/json")
        |> post("/interactions/", ~s({"type":1}))

      assert conn.status == 404

      assert %{outcome: :wrong_path, path: "POST /interactions/"} =
               latest(Tenancy.default_slug())
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

  # A question the portal already posted, so the interaction coming back has
  # something to land on. Created directly: posting it would call Discord.
  defp call(slug, attrs \\ %{}) do
    {:ok, call} =
      CaptainCall.ask(
        Map.merge(
          %{
            question: "Ship the release?",
            options: [
              %{"value" => "ship", "label" => "Ship it", "description" => "Tag and push"},
              %{"value" => "hold", "label" => "Hold"},
              %{"value" => "abort", "label" => "Abort"}
            ],
            channel_id: "555555555555555555",
            task: "fm-port"
          },
          attrs
        ),
        actor: agent(slug),
        tenant: slug
      )

    call
  end

  defp agent(slug), do: %{role: :agent, email: "agent@example.com", tenant_slug: slug}

  # A MESSAGE_COMPONENT interaction, shaped the way Discord sends one.
  defp component(application_id, custom_id, values) do
    Jason.encode!(%{
      "type" => 3,
      "application_id" => application_id,
      "member" => %{
        "user" => %{
          "id" => "123456789012345678",
          "username" => "captain",
          "global_name" => "Captain"
        }
      },
      "data" => %{
        "component_type" => 3,
        "custom_id" => custom_id,
        "values" => values
      }
    })
  end

  # A MODAL_SUBMIT interaction, with the one text input our modal carries.
  defp modal(application_id, custom_id, text) do
    Jason.encode!(%{
      "type" => 5,
      "application_id" => application_id,
      "member" => %{
        "user" => %{
          "id" => "123456789012345678",
          "username" => "captain",
          "global_name" => "Captain"
        }
      },
      "data" => %{
        "custom_id" => custom_id,
        "components" => [
          %{
            "type" => 1,
            "components" => [%{"type" => 4, "custom_id" => "answer", "value" => text}]
          }
        ]
      }
    })
  end

  defp reload(call, slug) do
    {:ok, reloaded} = CaptainCall.get(call.id, actor: agent(slug), tenant: slug)
    reloaded
  end

  defp orders(slug, task) do
    {:ok, messages} = Inbox.list(agent(slug), task)
    messages
  end

  describe "interactive captain calls" do
    setup do
      {:ok, _} =
        FirstmatePort.Credentials.Credential.create(
          %{provider: "discord", key: "captain_user_id", value: "123456789012345678"},
          authorize?: false,
          tenant: "local"
        )

      :ok
    end

    test "other users and missing captain configuration refuse every answering path", %{
      conn: conn,
      local: local
    } do
      call = call("local", %{allow_other: true})

      for configured <- [true, false] do
        unless configured do
          FirstmatePort.Repo.query!(
            "DELETE FROM tenant_credentials WHERE tenant_slug = $1 AND provider = $2 AND key = $3",
            ["local", "discord", "captain_user_id"]
          )
        end

        for payload <- [
              component(@oss_app, Ask.custom_id(call.id), ["hold"]),
              component(@oss_app, Ask.custom_id(call.id), [Ask.other_value()]),
              modal(@oss_app, Ask.modal_custom_id(call.id), "hold")
            ] do
          params = Jason.decode!(payload)

          params =
            if configured,
              do: put_in(params, ["member", "user", "id"], "999999999999999999"),
              else: params

          response = conn |> signed(local, Jason.encode!(params)) |> json_response(200)
          assert response["type"] == 4
          assert response["data"]["flags"] == 64
          assert response["data"]["content"] =~ "configured captain"
          assert reload(call, "local").status == :open
          assert orders("local", "fm-port") == []
        end
      end
    end

    test "an inbox validation failure leaves the answer open for retry", %{
      conn: conn,
      local: local
    } do
      call = call("local")

      FirstmatePort.Repo.query!(
        "UPDATE captain_calls SET task = $1 WHERE id = $2",
        [String.duplicate("x", 201), Ecto.UUID.dump!(call.id)]
      )

      payload = component(@oss_app, Ask.custom_id(call.id), ["hold"])
      response = conn |> signed(local, payload) |> json_response(200)
      assert response["type"] == 4
      assert response["data"]["flags"] == 64
      assert reload(call, "local").status == :open
      assert orders("local", nil) == []

      FirstmatePort.Repo.query!(
        "UPDATE captain_calls SET task = $1 WHERE id = $2",
        ["fm-port", Ecto.UUID.dump!(call.id)]
      )

      assert json_response(signed(conn, local, payload), 200)["type"] == 7
      assert [%{"body" => body}] = orders("local", "fm-port")
      assert body =~ "Value: hold"
    end

    test "a DM captain answer preserves long modal text within the message limit", %{
      conn: conn,
      local: local
    } do
      call = call("local", %{question: String.duplicate("q", 2000), allow_other: true})
      text = String.duplicate("a", 1000)
      params = Jason.decode!(modal(@oss_app, Ask.modal_custom_id(call.id), text))
      {member, params} = Map.pop(params, "member")
      payload = params |> Map.put("user", member["user"]) |> Jason.encode!()
      response = conn |> signed(local, payload) |> json_response(200)
      assert response["type"] == 7
      assert response["data"]["components"] == []
      assert String.length(response["data"]["content"]) <= 2000
      assert response["data"]["content"] =~ text
      assert [%{"body" => body}] = orders("local", "fm-port")
      assert body =~ text
    end

    test "a select answers the call, edits the message, and files a captain order",
         %{conn: conn, local: local} do
      call = call("local")

      conn =
        signed(conn, local, component(@oss_app, Ask.custom_id(call.id), ["hold"]))

      body = json_response(conn, 200)

      # 7 is UPDATE_MESSAGE: the question becomes its own answer in place, and
      # the select is gone, so it cannot be clicked a second time.
      assert body["type"] == 7
      assert body["data"]["components"] == []
      assert body["data"]["content"] =~ "Ship the release?"
      assert body["data"]["content"] =~ "Hold"
      assert body["data"]["content"] =~ "Captain"

      answered = reload(call, "local")
      assert answered.status == :answered
      assert answered.answer == "hold"
      assert answered.answer_label == "Hold"
      assert answered.answered_by == "Captain"

      assert [order] = orders("local", "fm-port")
      assert order["task"] == "fm-port"
      assert order["body"] =~ "Captain answered: Hold"
      assert order["body"] =~ "Value: hold"
      assert order["body"] =~ call.id
      assert order["sender"] =~ "Captain"
    end

    test "clicking a second time is not a second order", %{conn: conn, local: local} do
      call = call("local")
      payload = component(@oss_app, Ask.custom_id(call.id), ["ship"])

      assert json_response(signed(conn, local, payload), 200)["type"] == 7

      second = json_response(signed(conn, local, payload), 200)

      # 4 with flags 64 is an ephemeral note to whoever clicked, not a new order.
      assert second["type"] == 4
      assert second["data"]["flags"] == 64
      assert second["data"]["content"] =~ "Already answered"

      assert length(orders("local", "fm-port")) == 1
    end

    test "the write, not the read, is what decides a double click" do
      call = call("local")

      answer = %{
        call_id: call.id,
        kind: :select,
        value: "ship",
        text: nil,
        by: "Captain",
        user_id: "123456789012345678"
      }

      # Answer the call behind CaptainCalls' back, so the second call reaches
      # the UPDATE holding a record that still says :open - which is what two
      # clicks a millisecond apart both hold. A read-then-write would file the
      # order twice here.
      {:ok, _} =
        CaptainCall.answer(call, %{answer: "ship", answer_label: "Ship it"},
          actor: agent("local"),
          tenant: "local"
        )

      assert {:error, {:already_answered, _}} = CaptainCalls.answer("local", answer)
      assert orders("local", "fm-port") == []
    end

    test "a value that was never on the menu is refused", %{conn: conn, local: local} do
      call = call("local")

      body =
        conn
        |> signed(local, component(@oss_app, Ask.custom_id(call.id), ["rm -rf"]))
        |> json_response(200)

      assert body["data"]["content"] =~ "not one of the choices"
      assert reload(call, "local").status == :open
      assert orders("local", "fm-port") == []
    end

    test "one tenant's application cannot answer another tenant's call", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      claim("acme", @acme_app)

      {:ok, _} =
        FirstmatePort.Credentials.Credential.create(
          %{provider: "discord", key: "captain_user_id", value: "123456789012345678"},
          authorize?: false,
          tenant: "acme"
        )

      # The call belongs to local; the interaction is signed by acme's own
      # application, so it verifies - and still finds nothing to answer.
      call = call("local")

      body =
        conn
        |> signed(acme, component(@acme_app, Ask.custom_id(call.id), ["ship"]))
        |> json_response(200)

      assert body["data"]["content"] =~ "no longer on file"
      assert reload(call, "local").status == :open
    end

    test "'Something else' opens a modal and files nothing yet", %{conn: conn, local: local} do
      call = call("local", %{allow_other: true})

      body =
        conn
        |> signed(local, component(@oss_app, Ask.custom_id(call.id), [Ask.other_value()]))
        |> json_response(200)

      # 9 is MODAL.
      assert body["type"] == 9
      assert body["data"]["custom_id"] == Ask.modal_custom_id(call.id)
      assert [%{"components" => [input]}] = body["data"]["components"]
      assert input["custom_id"] == "answer"

      assert reload(call, "local").status == :open
      assert orders("local", "fm-port") == []
    end

    test "the modal escape hatch is not reachable on a call that did not offer it",
         %{conn: conn, local: local} do
      call = call("local")

      body =
        conn
        |> signed(local, component(@oss_app, Ask.custom_id(call.id), [Ask.other_value()]))
        |> json_response(200)

      assert body["data"]["content"] =~ "not one of the choices"
      assert reload(call, "local").status == :open
    end

    test "a modal submit files the captain's own words", %{conn: conn, local: local} do
      call = call("local", %{allow_other: true})

      body =
        conn
        |> signed(
          local,
          modal(@oss_app, Ask.modal_custom_id(call.id), "  ship, but tag it rc1  ")
        )
        |> json_response(200)

      assert body["type"] == 7
      assert body["data"]["components"] == []

      answered = reload(call, "local")
      assert answered.status == :answered
      assert answered.answer == "ship, but tag it rc1"

      assert [order] = orders("local", "fm-port")
      assert order["body"] =~ "ship, but tag it rc1"
    end

    test "a modal submit on a call that did not offer one is refused",
         %{conn: conn, local: local} do
      call = call("local")

      body =
        conn
        |> signed(local, modal(@oss_app, Ask.modal_custom_id(call.id), "anything"))
        |> json_response(200)

      assert body["data"]["content"] =~ "not one of the choices"
      assert reload(call, "local").status == :open
    end

    test "a component that is not ours still goes to NATS", %{conn: conn, local: local} do
      payload = component(@oss_app, "someone-elses-button", ["x"])

      # NATS is down in test, so 502 is the proof it took the old path rather
      # than being claimed by the captain-call handler.
      assert signed(conn, local, payload).status == 502
    end

    test "a custom_id that is not an id at all is answered, not crashed",
         %{conn: conn, local: local} do
      body =
        conn
        |> signed(local, component(@oss_app, Ask.custom_id("not-a-uuid"), ["ship"]))
        |> json_response(200)

      assert body["data"]["content"] =~ "no longer on file"
    end

    test "an unsigned component answers nothing", %{conn: conn} do
      call = call("local")

      conn =
        interact(conn, component(@oss_app, Ask.custom_id(call.id), ["ship"]), timestamp: now())

      assert conn.status == 401
      assert reload(call, "local").status == :open
    end
  end

  describe "why the endpoint refused" do
    test "a verified PING is recorded as answered", %{conn: conn, local: local} do
      assert json_response(signed(conn, local, ping(@oss_app)), 200) == %{"type" => 1}

      assert %{outcome: :pong, verified?: true, type: 1, application_id: @oss_app} =
               latest("local")
    end

    test "a tenant with no key stored is recorded as exactly that", %{conn: conn} do
      # The reported cause of a Discord endpoint that "could not be verified":
      # nothing is stored, so a correctly signed PING has nothing to check
      # against and the operator sees only a 401.
      seed_tenant_without_key("keyless")
      claim("keyless", @acme_app)

      conn = signed(conn, :crypto.generate_key(:eddsa, :ed25519), ping(@acme_app))

      assert conn.status == 401
      assert %{outcome: :no_key, verified?: false} = latest("keyless")

      assert Attempts.describe(:no_key) =~ "no Discord public key stored"
    end

    test "a wrong key is recorded differently from a missing one", %{conn: conn} do
      acme = :crypto.generate_key(:eddsa, :ed25519)
      seed_tenant("acme", acme)
      claim("acme", @acme_app)

      conn = signed(conn, :crypto.generate_key(:eddsa, :ed25519), ping(@acme_app))

      assert conn.status == 401
      assert %{outcome: :bad_signature} = latest("acme")
    end

    test "a clock that has drifted is recorded with the drift", %{conn: conn, local: local} do
      stale = Integer.to_string(System.system_time(:second) - 4000)

      assert signed(conn, local, ping(@oss_app), timestamp: stale).status == 401

      assert %{outcome: :stale_timestamp, skew_seconds: skew} = latest("local")
      assert skew > 3000
    end

    test "a body nothing could read is a 400 that says so, not a size error",
         %{conn: conn, local: local} do
      ts = now()
      body = ping(@oss_app)

      # A content type no parser claims, so `Plug.Parsers` passes the request
      # through without reading the body and nothing is cached. This used to
      # answer 413 "payload too large" for a 30-byte request.
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("x-signature-ed25519", sign(local, ts, body))
        |> put_req_header("x-signature-timestamp", ts)
        |> post("/interactions", body)

      assert conn.status == 400
      assert conn.resp_body == "unreadable body"
      assert %{outcome: :unreadable_body} = latest("local")
    end

    test "an attempt never carries the signature, the body, or the key",
         %{conn: conn, local: local} do
      assert json_response(signed(conn, local, ping(@oss_app)), 200) == %{"type" => 1}

      recorded = latest("local")

      assert Map.keys(recorded) |> Enum.sort() ==
               [
                 :application_id,
                 :at,
                 :description,
                 :outcome,
                 :path,
                 :skew_seconds,
                 :type,
                 :verified?
               ]
    end
  end

  defp latest(slug), do: slug |> Attempts.list() |> List.first()

  defp seed_tenant_without_key(slug) do
    {:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

    {:ok, _} =
      User.upsert_oidc(%{email: "#{slug}@example.com", name: slug, tenant_slug: slug},
        authorize?: false
      )

    :ok
  end

  describe "body size" do
    test "an oversized body is refused without being verified", %{conn: conn, local: local} do
      body = ~s({"type":1,"pad":") <> String.duplicate("a", 100_000) <> ~s("})
      ts = now()

      # Correctly signed, and still refused: the cap is applied while the body is
      # being read, so an oversized payload is never buffered or verified.
      assert_error_sent(413, fn ->
        interact(conn, body, signature: sign(local, ts, body), timestamp: ts)
      end)
    end
  end
end
