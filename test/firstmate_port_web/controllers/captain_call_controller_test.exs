defmodule FirstmatePortWeb.Api.CaptainCallControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Discord.Ask

  @channel "555555555555555555"
  @message "666666666666666666"

  @question %{
    "question" => "Ship the release?",
    "channel_id" => @channel,
    "task" => "fm-port",
    "options" => [
      %{"value" => "ship", "label" => "Ship it", "description" => "Tag and push"},
      %{"value" => "hold", "label" => "Hold"}
    ]
  }

  setup do
    previous = Application.get_env(:firstmate_port, :discord_req_options)
    on_exit(fn -> Application.put_env(:firstmate_port, :discord_req_options, previous) end)

    {:ok, local: human("local")}
  end

  defp human(slug) do
    {:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(
        %{
          email: "#{slug}-#{System.unique_integer([:positive])}@example.com",
          name: slug,
          tenant_slug: slug
        },
        authorize?: false
      )

    user
  end

  defp as(conn, %User{} = user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{"tenant" => user.tenant_slug})
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp store_bot_token(slug) do
    {:ok, _} =
      Credential.create(%{provider: "discord", key: "bot_token", value: "a-bot-token-value"},
        authorize?: false,
        tenant: slug
      )
  end

  # Stands in for discord.com. The captured request is what the assertions read,
  # so the shape we actually put on the wire is the shape under test.
  defp stub_discord(fun) do
    test = self()

    Application.put_env(:firstmate_port, :discord_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:discord, conn.method, conn.request_path, Jason.decode!(body)})
        fun.(conn)
      end
    )
  end

  defp accepts do
    stub_discord(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => @message}))
    end)
  end

  defp refuses(status, body) do
    stub_discord(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  describe "POST /api/captain/calls" do
    test "posts a select to Discord and returns the open call", %{conn: conn, local: local} do
      store_bot_token("local")
      accepts()

      body = conn |> as(local) |> post("/api/captain/calls", @question) |> json_response(201)

      assert body["schema"] == "fm-captain-call.v1"
      assert body["status"] == "open"
      assert body["message_id"] == @message
      assert body["task"] == "fm-port"
      assert body["answer"] == ""

      assert_received {:discord, "POST", path, sent}
      assert path == "/api/v10/channels/#{@channel}/messages"
      assert sent["content"] == "Ship the release?"

      # One action row holding one string select (component type 3), carrying
      # the call id so the answer can find its way back.
      assert [%{"type" => 1, "components" => [select]}] = sent["components"]
      assert select["type"] == 3
      assert select["custom_id"] == Ask.custom_id(body["id"])
      assert select["min_values"] == 1
      assert select["max_values"] == 1

      assert Enum.map(select["options"], & &1["value"]) == ["ship", "hold"]
      assert Enum.map(select["options"], & &1["label"]) == ["Ship it", "Hold"]

      # A question is text the crew wrote, so the bot must not be usable as a
      # megaphone by putting @everyone in a task description.
      assert sent["allowed_mentions"] == %{"parse" => []}
    end

    test "allow_other adds the modal escape hatch to the menu", %{conn: conn, local: local} do
      store_bot_token("local")
      accepts()

      conn
      |> as(local)
      |> post("/api/captain/calls", Map.put(@question, "allow_other", true))
      |> json_response(201)

      assert_received {:discord, _method, _path, sent}
      assert [%{"components" => [select]}] = sent["components"]

      assert Enum.map(select["options"], & &1["value"]) ==
               ["ship", "hold", Ask.other_value()]
    end

    test "a tenant with no bot token is told so, without calling Discord",
         %{conn: conn, local: local} do
      body = conn |> as(local) |> post("/api/captain/calls", @question) |> json_response(502)

      assert body["error"] =~ "no discord/bot_token stored"
      assert body["call"]["status"] == "failed"
      refute_received {:discord, _method, _path, _sent}
    end

    test "a question Discord refuses comes back as a failed call with the reason",
         %{conn: conn, local: local} do
      store_bot_token("local")
      refuses(403, %{"code" => 50_001, "message" => "Missing Access"})

      body = conn |> as(local) |> post("/api/captain/calls", @question) |> json_response(502)

      assert body["error"] =~ "403"
      assert body["error"] =~ "50001"
      assert body["call"]["status"] == "failed"
      assert body["call"]["delivery_error"] =~ "is the bot in that channel?"

      # Never the token, and never Discord's own message, which can quote the
      # request back.
      refute body["error"] =~ "a-bot-token-value"
      refute body["error"] =~ "Missing Access"
    end

    test "the choices are bounded before anything is posted", %{conn: conn, local: local} do
      store_bot_token("local")
      accepts()

      for {attrs, expected} <- [
            {%{"options" => []}, "non-empty"},
            {%{
               "options" => [%{"value" => "a", "label" => "A"}, %{"value" => "a", "label" => "B"}]
             }, "unique"},
            {%{"options" => [%{"label" => "no value"}]}, "value"},
            {%{"options" => [%{"value" => "a"}]}, "label"},
            {%{"options" => [%{"value" => Ask.other_value(), "label" => "sneaky"}]}, "reserved"},
            {%{
               "options" => Enum.map(1..26, &%{"value" => "v#{&1}", "label" => "L#{&1}"})
             }, "at most 25"}
          ] do
        body =
          conn
          |> as(local)
          |> post("/api/captain/calls", Map.merge(@question, attrs))
          |> json_response(422)

        assert body["error"] =~ expected
        refute_received {:discord, _method, _path, _sent}
      end
    end

    test "an Elixir caller may use atom keys for the choices", %{local: local} do
      store_bot_token("local")
      accepts()

      # Not reachable over HTTP - JSON always arrives string-keyed - but the
      # same options travel from a create straight into the Discord payload
      # before Postgres has ever normalised them.
      {:ok, call} =
        FirstmatePort.CaptainCalls.ask(local, %{
          question: "Ship it?",
          channel_id: @channel,
          options: [%{value: "ship", label: "Ship it", description: "Tag and push"}]
        })

      assert call.status == :open

      assert_received {:discord, _method, _path, sent}
      assert [%{"components" => [select]}] = sent["components"]

      assert select["options"] == [
               %{"label" => "Ship it", "value" => "ship", "description" => "Tag and push"}
             ]
    end

    test "signing in is the bar", %{conn: conn} do
      assert conn |> post("/api/captain/calls", @question) |> Map.get(:status) == 401
    end
  end

  describe "GET /api/captain/calls" do
    setup do
      store_bot_token("local")
      accepts()
      :ok
    end

    test "lists this tenant's calls and reads one back", %{conn: conn, local: local} do
      created = conn |> as(local) |> post("/api/captain/calls", @question) |> json_response(201)

      listed = conn |> as(local) |> get("/api/captain/calls") |> json_response(200)
      assert Enum.map(listed["data"], & &1["id"]) == [created["id"]]

      open = conn |> as(local) |> get("/api/captain/calls?status=open") |> json_response(200)
      assert Enum.map(open["data"], & &1["id"]) == [created["id"]]

      shown =
        conn |> as(local) |> get("/api/captain/calls/#{created["id"]}") |> json_response(200)

      assert shown["question"] == "Ship the release?"
    end

    test "another tenant's call is simply not there", %{conn: conn, local: local} do
      created = conn |> as(local) |> post("/api/captain/calls", @question) |> json_response(201)

      other = human("other")

      assert conn |> as(other) |> get("/api/captain/calls/#{created["id"]}") |> Map.get(:status) ==
               404

      listed = conn |> as(other) |> get("/api/captain/calls") |> json_response(200)
      assert listed["data"] == []
    end
  end
end
