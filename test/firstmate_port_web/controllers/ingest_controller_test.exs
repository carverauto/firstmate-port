defmodule FirstmatePortWeb.Api.IngestControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User

  setup do
    token = "fmh_test_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, agent} =
      User.bootstrap_agent(
        %{
          email: "agent-test@localhost",
          name: "test agent",
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    {:ok, human} =
      User.upsert_oidc(%{email: "human@example.com", name: "Human"}, authorize?: false)

    {:ok, token: token, agent: agent, human: human}
  end

  test "MCP tools/list does not fail with a missing tenant", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    refute conn.status in [401, 403, 500]
    body = conn.resp_body
    refute body =~ "TenantRequired"
    refute body =~ "require a tenant"
  end

  test "agent can record a farm01 roll with a copied GitHub URL", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/rolls", %{
        "cluster" => "farm01",
        "namespace" => "serviceradar",
        "status" => "success",
        "image_tag" => "sha-deadbeef",
        "pr_url" => "https://github.com/example/app/pull/4313",
        "outcome" => "web-ng rolled"
      })

    assert %{"id" => id, "url" => url} = json_response(conn, 200)
    assert id
    assert String.starts_with?(url, "http")
    assert String.contains?(url, "/rolls/")
  end

  test "rejects a roll whose PR URL is not full https", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/rolls", %{
        "cluster" => "farm01",
        "namespace" => "serviceradar",
        "status" => "started",
        "image_tag" => "sha-x",
        "pr_url" => "4313"
      })

    assert conn.status in [400, 422]
  end

  test "diagram upload stores the exact base64-decoded bytes", %{conn: conn, token: token} do
    html = "<html><body>interactive</body></html>"
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/diagrams", %{
        "id" => "roundtrip-diagram",
        "title" => "Round trip",
        "html_base64" => Base.encode64(html),
        "png_base64" => Base.encode64(png)
      })

    assert %{"id" => id} = json_response(conn, 200)

    card =
      build_conn()
      |> put_req_header("user-agent", "Mozilla/5.0 (compatible; Discordbot/2.0)")
      |> get("/d/#{id}/card.png")

    assert card.status == 200
    assert card.resp_body == png
  end

  test "diagram upload rejects a field that is not base64", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/diagrams", %{
        "id" => "raw-svg-diagram",
        "title" => "Raw svg",
        "html_base64" => Base.encode64("<html></html>"),
        "svg_base64" => ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error =~ "svg_base64"

    listing =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/diagrams")

    assert %{"data" => rows} = json_response(listing, 200)
    refute Enum.any?(rows, &(&1["id"] == "raw-svg-diagram"))
  end

  test "browser user cannot write rolls", %{conn: conn, human: human} do
    {:ok, jwt, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> jwt)
      |> post(~p"/api/rolls", %{
        "cluster" => "farm01",
        "namespace" => "serviceradar",
        "status" => "started",
        "image_tag" => "sha-x"
      })

    assert conn.status in [401, 403]
  end
end
