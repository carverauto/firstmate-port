defmodule FirstmatePortWeb.SessionsLiveTest do
  @moduledoc "Seeing which fm-steer logins are live, and ending one."
  use FirstmatePortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.{CliSession, DeviceCode, Guardian}

  setup %{conn: conn} do
    {:ok, captain} =
      User.upsert_oidc(
        %{email: "captain-#{System.unique_integer([:positive])}@localhost", name: "Captain"},
        authorize?: false
      )

    {:ok, conn: sign_in(conn, captain), captain: captain}
  end

  test "lists the CLI logins with where they came from", %{conn: conn, captain: captain} do
    _token = login(captain, "fm-steer/workstation")

    {:ok, _view, html} = live(conn, ~p"/settings/sessions")

    assert html =~ "fm-steer/workstation"
    assert html =~ "active"
    assert html =~ "never used"
  end

  test "revoking from the page stops that token", %{conn: conn, captain: captain} do
    token = login(captain)

    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> put_req_header("authorization", "Bearer " <> token)
           |> get(~p"/api/cli/inbox")
           |> json_response(200)

    {:ok, view, _html} = live(conn, ~p"/settings/sessions")
    {:ok, [session]} = CliSession.mine(actor: captain)

    html = view |> element("button[phx-value-id='#{session.id}']") |> render_click()
    assert html =~ "revoked"

    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> put_req_header("authorization", "Bearer " <> token)
           |> get(~p"/api/cli/inbox")
           |> json_response(401)
  end

  test "an empty list says how to get one", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/sessions")
    assert html =~ "fm-steer auth login"
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

  defp sign_in(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:guardian_token, token)
  end
end
