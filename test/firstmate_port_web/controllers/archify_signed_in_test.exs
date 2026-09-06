defmodule FirstmatePortWeb.ArchifySignedInTest do
  @moduledoc """
  The Archify path as the captain uses it: upload with the credential they
  already have from `fm-steer auth login`, then open the link.
  """
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.{DeviceCode, Guardian}

  @html "<html><body>architecture</body></html>"

  setup do
    {:ok, captain} =
      User.upsert_oidc(
        %{email: "captain-#{System.unique_integer([:positive])}@localhost", name: "Captain"},
        authorize?: false
      )

    {:ok, captain: captain}
  end

  test "a signed-in captain uploads a diagram and reads it back", %{
    conn: conn,
    captain: captain
  } do
    id = "signed-in-#{System.unique_integer([:positive])}"

    %{"id" => ^id, "url" => url} =
      conn
      |> as(captain)
      |> post(~p"/api/diagrams", %{
        "id" => id,
        "title" => "Signed in upload",
        "html_base64" => Base.encode64(@html)
      })
      |> json_response(200)

    assert String.ends_with?(url, "/d/" <> id)

    browser =
      build_conn()
      |> as(captain)
      |> put_req_header("accept", "text/html")
      |> get("/d/#{id}")

    assert response(browser, 200) == @html

    listing = build_conn() |> as(captain) |> get(~p"/api/diagrams") |> json_response(200)
    assert Enum.any?(listing["data"], &(&1["id"] == id))
  end

  test "a signed-out visitor is sent to sign in, not told it is missing", %{
    conn: conn,
    captain: captain
  } do
    id = "redirect-#{System.unique_integer([:positive])}"

    conn
    |> as(captain)
    |> post(~p"/api/diagrams", %{
      "id" => id,
      "title" => "Redirect",
      "html_base64" => Base.encode64(@html)
    })
    |> json_response(200)

    signed_out = get(build_conn(), "/d/#{id}")
    assert redirected_to(signed_out) == "/login"
    assert Plug.Conn.get_session(signed_out, :return_to) == "/d/#{id}"
  end

  test "the MCP endpoint answers a signed-in captain", %{conn: conn, captain: captain} do
    conn =
      conn
      |> as(captain)
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    refute conn.status in [401, 403, 500]
    assert conn.resp_body =~ "upload_diagram"
  end

  test "uploading still needs a credential", %{conn: conn} do
    assert conn
           |> put_req_header("accept", "application/json")
           |> post(~p"/api/diagrams", %{
             "id" => "anonymous",
             "title" => "No",
             "html_base64" => Base.encode64(@html)
           })
           |> json_response(401)
  end

  # The captain's real credential is a device-code session, so the test uses one
  # rather than a hand-signed token.
  defp as(conn, %User{} = user) do
    {:ok, code} = DeviceCode.issue(%{}, authorize?: false)

    {:ok, _} =
      DeviceCode.approve(code, %{user_id: user.id, tenant_slug: user.tenant_slug},
        authorize?: false
      )

    token =
      build_conn()
      |> post(~p"/api/cli/auth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => code.device_code
      })
      |> json_response(200)
      |> Map.fetch!("access_token")

    {:ok, _} = Guardian.decode_and_verify(token)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end
end
