defmodule FirstmatePortWeb.Api.QueueControllerTest do
  use FirstmatePortWeb.ConnCase, async: false

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian

  # The tracker is one process for the whole node, so each test gets its own
  # tenant: that is also the tenancy the look-in itself relies on.
  setup do
    unique = Integer.to_string(System.unique_integer([:positive]))
    tenant = "queue-ctl-" <> unique
    token = "fmh_queue_" <> unique

    {:ok, agent} =
      User.bootstrap_agent(
        %{
          email: "queue-agent-#{unique}@localhost",
          name: "Queue agent",
          tenant_slug: tenant,
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    {:ok, human} =
      User.upsert_oidc(
        %{
          email: "queue-human-#{unique}@localhost",
          name: "Queue reader",
          tenant_slug: tenant
        },
        authorize?: false
      )

    {:ok, jwt, _} = Guardian.encode_and_sign(human)
    %{agent: agent, agent_token: token, human: human, jwt: jwt, tenant: tenant}
  end

  defp as_agent(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)
  defp as_human(jwt), do: put_req_header(build_conn(), "authorization", "Bearer " <> jwt)

  test "an agent reports a queue fact and a signed-in user reads it back", ctx do
    task = "wire-the-look-in"

    posted =
      as_agent(ctx.agent_token)
      |> post("/api/queues", %{
        task: task,
        worker: "crew-7",
        agent_id: "agent-9f2",
        status: "working",
        model: "claude-opus-5",
        effort: "high",
        tokens_in: 4200,
        tokens_out: 800,
        summary: "wire the queue look-in"
      })
      |> json_response(200)

    assert posted["task"] == task
    assert posted["worker"] == "crew-7"
    assert posted["agent_id"] == "agent-9f2"
    assert posted["status"] == "working"
    assert posted["model"] == "claude-opus-5"
    assert posted["effort"] == "high"
    assert posted["tokens_total"] == 5000
    assert posted["started_at"]
    refute posted["stopped_at"]

    listed = as_human(ctx.jwt) |> get("/api/queues") |> json_response(200)
    assert [%{"task" => ^task, "worker" => "crew-7"}] = listed["data"]
  end

  test "a later report merges onto the tracked entry rather than replacing it", ctx do
    task = "merge-onto-tracked"

    as_agent(ctx.agent_token)
    |> post("/api/queues", %{task: task, worker: "crew-7", model: "claude-opus-5"})
    |> json_response(200)

    stopped =
      as_agent(ctx.agent_token)
      |> post("/api/queues", %{task: task, status: "done", tokens_out: 120})
      |> json_response(200)

    assert stopped["worker"] == "crew-7"
    assert stopped["model"] == "claude-opus-5"
    assert stopped["status"] == "done"
    assert stopped["stopped_at"]
  end

  test "a report without a task is refused", ctx do
    response =
      as_agent(ctx.agent_token) |> post("/api/queues", %{worker: "crew-7"}) |> json_response(422)

    assert response == %{"error" => "missing_task"}
  end

  test "an unknown status is refused", ctx do
    response =
      as_agent(ctx.agent_token)
      |> post("/api/queues", %{task: "queue-bad-status", status: "vibing"})
      |> json_response(422)

    assert response == %{"error" => "invalid_status"}
  end

  test "reporting needs an agent credential", ctx do
    assert build_conn() |> post("/api/queues", %{task: "queue-anon"}) |> json_response(401)

    assert as_human(ctx.jwt)
           |> post("/api/queues", %{task: "queue-human"})
           |> json_response(403)
  end

  test "reading the look-in needs a signed-in account", _ctx do
    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> get("/api/queues")
           |> json_response(401)
  end
end
