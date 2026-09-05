defmodule FirstmatePortWeb.CliAuthControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.DeviceCode

  test "device-code issue then pending poll", %{conn: conn} do
    conn = post(conn, ~p"/api/cli/auth/device", %{})
    body = json_response(conn, 200)
    assert body["device_code"]
    assert body["user_code"]
    assert body["verification_uri"] =~ "/login/device"

    conn = post(build_conn(), ~p"/api/cli/auth/token", %{"device_code" => body["device_code"]})
    assert json_response(conn, 400)["error"] == "authorization_pending"
  end

  test "approved device-code returns a CLI JWT", %{conn: conn} do
    {:ok, user} =
      User.upsert_oidc(%{email: "captain@localhost", name: "Captain"}, authorize?: false)

    {:ok, code} = DeviceCode.issue(%{}, authorize?: false)

    {:ok, _} =
      DeviceCode.approve(code, %{user_id: user.id, tenant_slug: user.tenant_slug},
        authorize?: false
      )

    conn =
      post(conn, ~p"/api/cli/auth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => code.device_code
      })

    body = json_response(conn, 200)
    assert body["access_token"]
    assert body["tenant"] == "local"

    conn =
      post(build_conn(), ~p"/api/cli/auth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => code.device_code
      })

    assert json_response(conn, 400)["error"] == "invalid_grant"
  end

  test "ack of a missing inbox token is not found", %{conn: conn} do
    {:ok, a} =
      User.upsert_oidc(%{email: "ack@localhost", name: "Ack", tenant_slug: "local"},
        authorize?: false
      )

    {:ok, token, _} = FirstmatePort.Auth.Guardian.encode_and_sign(a, %{"typ" => "cli"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/cli/inbox/ack", %{"ack" => "999"})

    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "inbox is tenant-scoped", %{conn: conn} do
    {:ok, a} =
      User.upsert_oidc(%{email: "a@localhost", name: "A", tenant_slug: "local"},
        authorize?: false
      )

    {:ok, b} =
      User.upsert_oidc(%{email: "b@localhost", name: "B", tenant_slug: "acme"},
        authorize?: false
      )

    {:ok, token_a, _} = FirstmatePort.Auth.Guardian.encode_and_sign(a, %{"typ" => "cli"})
    {:ok, token_b, _} = FirstmatePort.Auth.Guardian.encode_and_sign(b, %{"typ" => "cli"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token_a)
      |> post(~p"/api/cli/inbox/put", %{"task" => "fm-port", "body" => "hello"})

    assert json_response(conn, 200)["task"] == "fm-port"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token_a)
      |> get(~p"/api/cli/inbox")

    assert [%{"body" => "hello"}] = json_response(conn, 200)["data"]

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token_b)
      |> get(~p"/api/cli/inbox")

    assert json_response(conn, 200)["data"] == []
  end
end
