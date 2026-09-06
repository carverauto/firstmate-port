defmodule FirstmatePortWeb.Api.BuildEventsControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User

  setup do
    token = "fmh_test_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, _agent} =
      User.bootstrap_agent(
        %{
          email: "build-api-agent@localhost",
          name: "build api agent",
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    {:ok, token: token}
  end

  # Each request gets a fresh conn: the CLI posts start and finish from
  # separate processes, so the API may not depend on a reused connection.
  defp agent_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  defp post_event(token, params) do
    token |> agent_conn() |> post(~p"/api/build-events", params)
  end

  test "an agent records a start and a finish for one run", %{token: token} do
    started =
      token
      |> post_event(%{
        "run_id" => "api-run-1",
        "kind" => "docker",
        "target" => "firstmate-port",
        "status" => "started",
        "agent_id" => "crew-7",
        "model" => "opus-5",
        "effort" => "high",
        "started_at" => "2026-09-06T01:00:00Z"
      })
      |> json_response(200)

    assert started["run_id"] == "api-run-1"
    assert started["status"] == "started"
    assert started["kind"] == "docker"
    assert String.starts_with?(started["url"], "http")

    finished =
      token
      |> post_event(%{
        "run_id" => "api-run-1",
        "status" => "success",
        "tokens" => "48210",
        "outcome" => "pushed to ghcr.io",
        "finished_at" => "2026-09-06T01:04:00Z"
      })
      |> json_response(200)

    assert finished["status"] == "success"
    assert finished["id"] != started["id"]
    # The finish call omitted kind; the API carried it forward from the start.
    assert finished["kind"] == "docker"

    runs =
      token |> agent_conn() |> get(~p"/api/build-runs") |> json_response(200)

    assert [run] = runs["data"]
    assert run["run_id"] == "api-run-1"
    assert run["status"] == "success"
    assert run["tokens"] == 48_210
    assert run["model"] == "opus-5"
    assert run["effort"] == "high"
    assert run["agent_id"] == "crew-7"
    assert run["duration_ms"] == 240_000
    assert run["events"] == 2

    events =
      token
      |> agent_conn()
      |> get(~p"/api/build-events?run_id=api-run-1")
      |> json_response(200)

    assert length(events["data"]) == 2
  end

  test "the run list is capped at ten by default", %{token: token} do
    for n <- 1..11 do
      assert token
             |> post_event(%{
               "run_id" => "api-cap-#{n}",
               "kind" => "k8s",
               "status" => "started",
               "agent_id" => "crew-7"
             })
             |> json_response(200)
    end

    runs = token |> agent_conn() |> get(~p"/api/build-runs") |> json_response(200)
    assert length(runs["data"]) == 10

    all = token |> agent_conn() |> get(~p"/api/build-runs?limit=50") |> json_response(200)
    assert length(all["data"]) == 11
  end

  test "a payload with no kind is rejected without writing a row", %{token: token} do
    body =
      token
      |> post_event(%{"run_id" => "api-run-2", "status" => "started", "agent_id" => "crew-7"})
      |> json_response(422)

    assert body["error"]

    events = token |> agent_conn() |> get(~p"/api/build-events") |> json_response(200)
    assert events["data"] == []
  end

  test "an unauthenticated caller cannot record a build event", %{conn: conn} do
    conn =
      post(conn, ~p"/api/build-events", %{
        "run_id" => "api-run-3",
        "kind" => "docker",
        "status" => "started",
        "agent_id" => "crew-7"
      })

    assert conn.status in [401, 403]
  end
end
