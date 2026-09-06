defmodule FirstmatePortWeb.CredentialsJourneyTest do
  use FirstmatePortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Repo

  @interactions_host "discord.example.com"
  @application_id "333333333333333333"

  setup do
    previous = Application.get_env(:firstmate_port, :discord_interactions_host)
    Application.put_env(:firstmate_port, :discord_interactions_host, @interactions_host)

    on_exit(fn ->
      Application.put_env(:firstmate_port, :discord_interactions_host, previous)
    end)

    :ok
  end

  test "portal storage enables Discord and API rotation and deletion revoke its keys", %{
    conn: conn
  } do
    {:ok, _} = Tenant.seed(%{slug: "journey", name: "Journey"}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(
        %{email: "journey@example.com", name: "Journey", tenant_slug: "journey"},
        authorize?: false
      )

    {:ok, token, _} = Guardian.encode_and_sign(user, %{"tenant" => "journey"})
    signed_in = conn |> init_test_session(%{}) |> put_session(:guardian_token, token)
    api = fn -> build_conn() |> put_req_header("authorization", "Bearer " <> token) end
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    key = Base.encode16(public, case: :lower)

    {:ok, view, empty} = live(signed_in, ~p"/settings/credentials")
    assert empty =~ "Environment keys are not accepted"
    capture("credentials-empty.html", empty)
    assert ping(private).status == 401

    claimed =
      view
      |> form("#discord-application-0", %{"application_id" => @application_id})
      |> render_submit()

    assert claimed =~ @application_id

    stored =
      view
      |> form("#credential-form-1", %{"value" => key, "description" => "Discord application"})
      |> render_submit()

    refute stored =~ key
    assert stored =~ "discord/public_key"
    capture("credentials-stored.html", stored)

    %{rows: [[ciphertext]]} =
      Repo.query!("SELECT encrypted_value FROM tenant_credentials WHERE tenant_slug = $1", [
        "journey"
      ])

    refute ciphertext == key
    assert :binary.match(ciphertext, key) == :nomatch
    pong = ping(private)
    assert json_response(pong, 200) == %{"type" => 1}
    listed = api.() |> get(~p"/api/credentials")

    assert [%{"provider" => "discord", "key" => "public_key", "tenant" => "journey"}] =
             json_response(listed, 200)["data"]

    refute listed.resp_body =~ key

    {replacement, replacement_private} = :crypto.generate_key(:eddsa, :ed25519)

    rotated =
      api.()
      |> put(~p"/api/credentials/discord/public_key", %{"value" => Base.encode16(replacement)})

    assert rotated.status == 200
    assert ping(private).status == 401
    assert ping(replacement_private).status == 200
    deleted = api.() |> delete(~p"/api/credentials/discord/public_key")
    assert deleted.status == 204
    assert ping(replacement_private).status == 401

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM tenant_credentials WHERE tenant_slug = $1", [
               "journey"
             ])

    capture("credentials-journey.txt", """
    Authenticated tenant: journey
    Discord interactions URL (one for the deployment): https://#{@interactions_host}/interactions
    Portal /settings/credentials: empty state instructs storing discord/public_key; environment keys are not accepted.
    POST /interactions before portal save: 401
    Portal Discord application claim: #{@application_id} -> tenant journey
    Portal Save discord/public_key: stored; full value absent from rendered page.
    PostgreSQL encrypted_value: #{byte_size(ciphertext)} bytes; does not contain submitted plaintext.
    POST /interactions signed with saved key: #{pong.status} #{pong.resp_body}
    GET /api/credentials: #{listed.status} #{listed.resp_body}
    PUT /api/credentials/discord/public_key: #{rotated.status}
    POST /interactions with old key after rotation: 401
    POST /interactions with replacement key: 200
    DELETE /api/credentials/discord/public_key: #{deleted.status}
    POST /interactions with deleted key: 401
    PostgreSQL remaining credentials for journey: 0
    """)
  end

  # Posts as Discord would: to the deployment's one interactions hostname, naming
  # the application in the payload and signing a timestamp Discord could
  # plausibly have just sent.
  defp ping(private) do
    body = ~s({"type":1,"application_id":"#{@application_id}"})
    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      :crypto.sign(:eddsa, :none, timestamp <> body, [private, :ed25519])
      |> Base.encode16(case: :lower)

    conn = build_conn()

    %{conn | host: @interactions_host}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-signature-ed25519", signature)
    |> put_req_header("x-signature-timestamp", timestamp)
    |> post("/interactions", body)
  end

  defp capture(name, content) do
    if directory = System.get_env("CREDENTIALS_EVIDENCE_DIR") do
      File.write!(Path.join(directory, name), content)
    end
  end
end
