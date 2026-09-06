defmodule FirstmatePort.Auth.CliSessionTest do
  @moduledoc """
  What "revoke" has to mean: the token in the file on the other machine stops
  working, without waiting for it to expire.
  """
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.{CliSession, DeviceCode, Guardian}

  setup do
    {:ok, captain} =
      User.upsert_oidc(
        %{email: "captain-#{System.unique_integer([:positive])}@localhost", name: "Captain"},
        authorize?: false
      )

    {:ok, captain: captain}
  end

  test "a device-code grant records a session the captain can see", %{captain: captain} do
    _token = login(captain, "fm-steer/test")

    {:ok, [session]} = CliSession.mine(actor: captain)
    assert session.user_agent == "fm-steer/test"
    assert session.tenant_slug == captain.tenant_slug
    assert is_nil(session.revoked_at)
    assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt
  end

  test "revoking stops the token on its next request", %{conn: conn, captain: captain} do
    token = login(captain)

    assert conn |> as(token) |> get(~p"/api/cli/inbox") |> json_response(200)

    {:ok, [session]} = CliSession.mine(actor: captain)
    {:ok, revoked} = CliSession.revoke(session, %{}, actor: captain)
    assert revoked.revoked_at

    assert build_conn() |> as(token) |> get(~p"/api/cli/inbox") |> json_response(401)
    assert Guardian.resource_from_token(token) == {:error, :session_revoked}
  end

  test "revoking one session leaves the other machine signed in", %{conn: conn, captain: captain} do
    laptop = login(captain, "fm-steer/laptop")
    workstation = login(captain, "fm-steer/workstation")

    {:ok, sessions} = CliSession.mine(actor: captain)
    laptop_session = Enum.find(sessions, &(&1.user_agent == "fm-steer/laptop"))
    {:ok, _} = CliSession.revoke(laptop_session, %{}, actor: captain)

    assert conn |> as(laptop) |> get(~p"/api/cli/inbox") |> json_response(401)
    assert build_conn() |> as(workstation) |> get(~p"/api/cli/inbox") |> json_response(200)
  end

  test "a CLI token nobody issued is refused", %{conn: conn, captain: captain} do
    {:ok, forged, _} = Guardian.encode_and_sign(captain, %{"typ" => "cli"})

    assert conn |> as(forged) |> get(~p"/api/cli/inbox") |> json_response(401)
  end

  test "one captain cannot list or revoke another's sessions", %{captain: captain} do
    {:ok, other} =
      User.upsert_oidc(%{email: "other-#{System.unique_integer([:positive])}@localhost"},
        authorize?: false
      )

    _token = login(captain)
    {:ok, [session]} = CliSession.mine(actor: captain)

    assert {:ok, []} = CliSession.mine(actor: other)
    assert {:error, _} = CliSession.revoke(session, %{}, actor: other)
  end

  defp login(user, user_agent \\ "fm-steer/test") do
    {:ok, code} = DeviceCode.issue(%{}, authorize?: false)

    {:ok, _} =
      DeviceCode.approve(code, %{user_id: user.id, tenant_slug: user.tenant_slug},
        authorize?: false
      )

    build_conn()
    |> put_req_header("user-agent", user_agent)
    |> post(~p"/api/cli/auth/token", %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => code.device_code
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  defp as(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end
end
