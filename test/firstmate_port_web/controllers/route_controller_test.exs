defmodule FirstmatePortWeb.RouteControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User

  setup do
    token = "fmh_test_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, _agent} =
      User.bootstrap_agent(
        %{
          email: "route-agent@localhost",
          name: "route agent",
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    {:ok, human} =
      User.upsert_oidc(%{email: "route-human@example.com", name: "Human"}, authorize?: false)

    {:ok, token: token, human: human}
  end

  test "agent routes a code task", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/route", %{"description" => "fix the failing test in the ingest controller"})

    body = json_response(conn, 200)
    assert body["harness"] == "codex"
    assert body["effort"] == "medium"
    assert body["tenant"] == "local"
    assert is_list(body["reasons"]) and length(body["reasons"]) > 0
    assert "fleet_matrix" in body["intel_sources"]
    assert body["axes"]["kind"] == "code"
  end

  test "human user JWT routes too", %{conn: conn, human: human} do
    {:ok, jwt, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human, %{"typ" => "cli"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> jwt)
      |> post(~p"/api/route", %{"description" => "deploy the portal to production"})

    body = json_response(conn, 200)
    assert body["harness"] == "claude"
  end

  test "code review is hard-routed to codex with GPT-6-Astra", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/route", %{"description" => "review this pull request for correctness"})

    body = json_response(conn, 200)
    assert body["harness"] == "codex"
    assert body["model"] == "gpt-6-astra"
    assert body["model_display"] == "GPT-6-Astra"
    assert body["model_source"] == "fleet_hard_route"
  end

  test "rater-agent axis overrides are honored", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/route", %{
        "description" => "write user docs for inbox list",
        "axes" => %{"blast_radius" => "high"}
      })

    body = json_response(conn, 200)
    assert body["harness"] == "claude"
  end

  test "response axes round-trip with the request spelling", %{conn: conn, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/route", %{
        "description" => "write user docs for inbox list",
        "axes" => %{"citations_required" => true}
      })
      |> json_response(200)

    assert body["axes"]["citations_required"] == true
    assert is_boolean(body["axes"]["live_web_required"])
    refute Map.has_key?(body["axes"], "citations_required?")
    refute Map.has_key?(body["axes"], "live_web_required?")
  end

  test "missing description is unprocessable", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/route", %{})

    assert json_response(conn, 422)["error"] =~ "description"
  end

  test "a non-string description is unprocessable, not a 500", %{token: token} do
    for bad <- [42, %{"text" => "fix the test"}, ["fix the test"], true] do
      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/route", %{"description" => bad})
        |> json_response(422)

      assert body["error"] =~ "description"
    end
  end

  test "unauthenticated route is rejected", %{conn: conn} do
    conn = post(conn, ~p"/api/route", %{"description" => "hi"})
    assert json_response(conn, 401)["error"] == "unauthorized"
  end
end
