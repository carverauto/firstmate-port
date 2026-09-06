defmodule FirstmatePortWeb.FleetLogJourneyTest do
  use FirstmatePortWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "scheduled GitHub ingestion and agent posts populate the signed-in Fleet log", %{conn: conn} do
    previous = Req.default_options()
    old_token = System.get_env("GITHUB_TOKEN")
    old_org = System.get_env("GITHUB_ORG")

    on_exit(fn ->
      Req.default_options(previous)
      for {key, value} <- [{"GITHUB_TOKEN", old_token}, {"GITHUB_ORG", old_org}] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env("GITHUB_TOKEN", "fixture-token\n")
    System.put_env("GITHUB_ORG", " example \n")

    Req.default_options(plug: fn request ->
      assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer fixture-token"]
      query = URI.decode_query(request.query_string)["q"]
      assert query in ["org:example is:pr is:open", "org:example is:issue is:open"]
      kind = if query == "org:example is:pr is:open", do: "pull", else: "issues"
      Req.Test.json(request, %{"items" => [%{
        "html_url" => "https://github.com/example/portal/#{kind}/42",
        "title" => "Fleet #{kind} fixture"
      }]})
    end)

    assert {:ok, :ok} = FirstmatePort.Jobs.Tick
      |> Ash.ActionInput.for_action(:github_poll, %{})
      |> Ash.run_action()

    token = "fmh_fleet_journey"
    {:ok, _} = FirstmatePort.Accounts.User.bootstrap_agent(%{
      email: "fleet-agent@localhost", name: "Fleet agent",
      hashed_api_key: FirstmatePort.Accounts.User.hash_token(token)
    }, authorize?: false)

    for {path, payload} <- [
      {"/api/rolls", %{cluster: "local", namespace: "portal", status: "success", image_tag: "sha-fleet"}},
      {"/api/diagrams", %{id: "fleet-journey", title: "Fleet ingestion diagram", html_base64: Base.encode64("<html><body>Fleet diagram</body></html>")}},
      {"/api/no-mistakes", %{run_id: "fleet-journey", branch: "fm/fleet-journey", step: "test", outcome: "passed"}}
    ] do
      response = build_conn() |> put_req_header("authorization", "Bearer " <> token) |> post(path, payload)
      assert %{"id" => _} = json_response(response, 200)
    end

    {:ok, human} = FirstmatePort.Accounts.User.upsert_oidc(%{email: "fleet-human@localhost", name: "Fleet reviewer"}, authorize?: false)
    {:ok, jwt, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human)
    conn = conn |> init_test_session(%{}) |> put_session(:guardian_token, jwt)
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Fleet pull fixture"
    assert html =~ "Fleet issues fixture"
    assert html =~ "sha-fleet"
    assert html =~ "Fleet ingestion diagram"
    assert html =~ "fm/fleet-journey"
    assert has_element?(view, "a[href^='/rolls/']", "sha-fleet")

    if evidence = System.get_env("FLEET_TEST_EVIDENCE") do
      File.write!(Path.join(evidence, "fleet-log.html"), html)
    end
  end
end
