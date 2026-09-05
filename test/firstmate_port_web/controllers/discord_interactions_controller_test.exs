defmodule FirstmatePortWeb.DiscordInteractionsControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Tenancy

  setup do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    hex = Base.encode16(pub, case: :lower)
    previous = Application.get_env(:firstmate_port, :discord_public_key)
    Application.put_env(:firstmate_port, :discord_public_key, hex)
    on_exit(fn -> Application.put_env(:firstmate_port, :discord_public_key, previous) end)
    {:ok, pub: pub, priv: priv}
  end

  test "PING with valid Ed25519 returns PONG", %{conn: conn, priv: priv} do
    body = ~s({"type":1})
    ts = "1710000000"
    sig = sign(priv, ts, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-ed25519", sig)
      |> put_req_header("x-signature-timestamp", ts)
      |> post("/interactions", body)

    assert json_response(conn, 200) == %{"type" => 1}
  end

  test "missing signature is 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/interactions", ~s({"type":1}))

    assert conn.status == 401
  end

  test "invalid signature is 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-ed25519", String.duplicate("00", 64))
      |> put_req_header("x-signature-timestamp", "1")
      |> post("/interactions", ~s({"type":1}))

    assert conn.status == 401
  end

  test "signed command with NATS down is 502 so Discord retries", %{
    conn: conn,
    priv: priv
  } do
    body = ~s({"type":2,"data":{"name":"ping"}})
    ts = "1710000000"
    sig = sign(priv, ts, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-ed25519", sig)
      |> put_req_header("x-signature-timestamp", ts)
      |> post("/interactions", body)

    assert conn.status == 502
  end

  test "a tenant's stored public key verifies without the bootstrap env", %{conn: conn} do
    Application.put_env(:firstmate_port, :discord_public_key, nil)

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, _} = Tenant.seed(%{slug: "alpha", name: "alpha"}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(%{email: "alpha@example.com", name: "alpha", tenant_slug: "alpha"},
        authorize?: false
      )

    {:ok, _} =
      Credential.create(
        %{provider: "discord", key: "public_key", value: Base.encode16(pub, case: :lower)},
        Tenancy.opts(user)
      )

    body = ~s({"type":1})
    ts = "1710000000"

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-ed25519", sign(priv, ts, body))
      |> put_req_header("x-signature-timestamp", ts)
      |> post("/interactions", body)

    assert json_response(conn, 200) == %{"type" => 1}
  end

  test "a signature no tenant can verify is 401", %{conn: conn} do
    Application.put_env(:firstmate_port, :discord_public_key, nil)

    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    body = ~s({"type":1})
    ts = "1710000000"

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-ed25519", sign(priv, ts, body))
      |> put_req_header("x-signature-timestamp", ts)
      |> post("/interactions", body)

    assert conn.status == 401
  end

  defp sign(priv, ts, body) do
    :crypto.sign(:eddsa, :none, ts <> body, [priv, :ed25519])
    |> Base.encode16(case: :lower)
  end
end
