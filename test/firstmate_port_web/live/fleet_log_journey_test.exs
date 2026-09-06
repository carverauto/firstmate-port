defmodule FirstmatePortWeb.FleetLogJourneyTest do
  @moduledoc """
  End to end over the signed-in Fleet log.

  The load-bearing assertion is the negative one: a scheduled GitHub poll fills
  the PRs and Issues boards, which *are* mirrors of open org work, and leaves
  Progress alone. Progress is crew work — the PRs, issues, and tasks this fleet
  actually worked — and it only fills from posts that name a worker.
  """

  use FirstmatePortWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "the GitHub poll fills the boards, and only crew posts fill Progress", %{conn: conn} do
    previous = Req.default_options()
    previous_tracking = Application.get_env(:firstmate_port, :build_tracking, [])
    old_token = System.get_env("GITHUB_TOKEN")
    old_org = System.get_env("GITHUB_ORG")

    on_exit(fn ->
      Req.default_options(previous)
      Application.put_env(:firstmate_port, :build_tracking, previous_tracking)

      for {key, value} <- [{"GITHUB_TOKEN", old_token}, {"GITHUB_ORG", old_org}] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    Application.put_env(:firstmate_port, :build_tracking, kubernetes_enabled: true)

    System.put_env("GITHUB_TOKEN", "fixture-token\n")
    System.put_env("GITHUB_ORG", " example \n")

    Req.default_options(
      plug: fn request ->
        assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer fixture-token"]
        query = URI.decode_query(request.query_string)["q"]

        assert query in [
                 "org:example is:pr is:open",
                 "org:example is:issue is:open",
                 "org:example is:pr is:closed",
                 "org:example is:issue is:closed"
               ]

        kind = if String.contains?(query, "is:pr"), do: "pull", else: "issues"
        state = if String.contains?(query, "is:open"), do: "open", else: "closed"

        Req.Test.json(request, %{
          "items" => [
            %{
              "html_url" => "https://github.com/example/portal/#{kind}/42",
              "title" => "Org #{kind} #{state} fixture",
              "state" => state
            }
          ]
        })
      end
    )

    assert {:ok, :ok} =
             FirstmatePort.Jobs.Tick
             |> Ash.ActionInput.for_action(:github_poll, %{})
             |> Ash.run_action()

    token = "fmh_fleet_journey"

    {:ok, _} =
      FirstmatePort.Accounts.User.bootstrap_agent(
        %{
          email: "fleet-agent@localhost",
          name: "Fleet agent",
          hashed_api_key: FirstmatePort.Accounts.User.hash_token(token)
        },
        authorize?: false
      )

    agent_conn = fn -> build_conn() |> put_req_header("authorization", "Bearer " <> token) end

    for {path, payload} <- [
          {"/api/rolls",
           %{cluster: "local", namespace: "portal", status: "success", image_tag: "sha-fleet"}},
          {"/api/diagrams",
           %{
             id: "fleet-journey",
             title: "Fleet ingestion diagram",
             html_base64: Base.encode64("<html><body>Fleet diagram</body></html>")
           }},
          {"/api/no-mistakes",
           %{run_id: "fleet-journey", branch: "fm/fleet-journey", step: "test", outcome: "passed"}}
        ] do
      assert %{"id" => _} = json_response(post(agent_conn.(), path, payload), 200)
    end

    # Crew work: this is the only thing that opens a Progress row.
    crew_url = "https://github.com/example/portal/pull/7"

    assert %{"id" => progress_id} =
             agent_conn.()
             |> post("/api/progress", %{
               kind: "pr",
               title: "Crew-logged fleet work",
               url: crew_url,
               worker: "fm-fleet-journey"
             })
             |> json_response(200)

    # A post with no worker is refused, so nothing can quietly catalogue an org.
    assert %{"error" => refusal} =
             agent_conn.()
             |> post("/api/progress", %{kind: "note", title: "unattributed"})
             |> json_response(400)

    assert refusal =~ "worker is required"

    {:ok, human} =
      FirstmatePort.Accounts.User.upsert_oidc(
        %{email: "fleet-human@localhost", name: "Fleet reviewer"},
        authorize?: false
      )

    {:ok, jwt, _} = FirstmatePort.Auth.Guardian.encode_and_sign(human)
    conn = conn |> init_test_session(%{}) |> put_session(:guardian_token, jwt)
    {:ok, view, html} = live(conn, "/")

    # The boards, the deploys, the diagrams and the pipeline runs all filled.
    assert html =~ "sha-fleet"
    assert html =~ "Fleet ingestion diagram"
    assert html =~ "fm/fleet-journey"
    assert has_element?(view, "a[href^='/rolls/']", "sha-fleet")

    {:ok, _prs, prs_html} = live(conn, "/prs")
    assert prs_html =~ "Org pull open fixture"

    # Progress carries the crew's row and nothing the poll listed.
    assert html =~ "Crew-logged fleet work"
    assert html =~ "fm-fleet-journey"
    refute html =~ "Org pull open fixture"
    refute html =~ "Org issues open fixture"
    refute html =~ "Org pull closed fixture"
    refute html =~ "unattributed"

    assert %{"data" => rows, "meta" => %{"total" => 1}} =
             agent_conn.() |> get("/api/progress") |> json_response(200)

    assert [%{"id" => ^progress_id, "assignee" => "fm-fleet-journey"}] = rows

    if evidence = System.get_env("FLEET_TEST_EVIDENCE") do
      File.write!(Path.join(evidence, "fleet-log.html"), html)
    end
  end
end
