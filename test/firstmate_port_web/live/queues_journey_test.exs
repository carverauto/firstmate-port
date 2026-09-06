defmodule FirstmatePortWeb.QueuesJourneyTest do
  use FirstmatePortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Queues

  # The tracker is one process for the whole node, so each test gets its own
  # tenant: that is also the tenancy the look-in itself relies on.
  setup do
    unique = Integer.to_string(System.unique_integer([:positive]))
    tenant = "queue-live-" <> unique
    token = "fmh_queue_live_" <> unique

    {:ok, _agent} =
      User.bootstrap_agent(
        %{
          email: "queue-live-agent-#{unique}@localhost",
          name: "Queue agent",
          tenant_slug: tenant,
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    {:ok, human} =
      User.upsert_oidc(
        %{
          email: "queue-live-human-#{unique}@localhost",
          name: "Queue reader",
          tenant_slug: tenant
        },
        authorize?: false
      )

    {:ok, jwt, _} = Guardian.encode_and_sign(human)
    conn = build_conn() |> init_test_session(%{}) |> put_session(:guardian_token, jwt)
    %{conn: conn, agent_token: token, tenant: tenant}
  end

  test "the look-in is signed-in only", _ctx do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/queues")
  end

  test "a task firstmate hands out shows up live with its worker facts", ctx do
    {:ok, view, html} = live(ctx.conn, "/queues")

    assert html =~ "No work in flight"
    assert html =~ "live look-in"
    refute html =~ "farm01"

    task = "finish-queue-tracking"

    posted =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.agent_token)
      |> post("/api/queues", %{
        task: task,
        worker: "crew-4",
        agent_id: "agent-7b1",
        status: "working",
        model: "claude-opus-5",
        effort: "high",
        tokens_in: 9_000,
        tokens_out: 1_000,
        summary: "finish queue tracking"
      })
      |> json_response(200)

    assert posted["task"] == task

    rendered = render(view)
    assert rendered =~ task
    assert rendered =~ "crew-4"
    assert rendered =~ "agent-7b1"
    assert rendered =~ "claude-opus-5"
    assert rendered =~ "high"
    assert rendered =~ "10,000"
    assert rendered =~ "working"
    assert rendered =~ "1 in flight"
    refute rendered =~ "No work in flight"

    # Finishing the task moves it out of the in-flight count without dropping it.
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.agent_token)
    |> post("/api/queues", %{task: task, status: "done", tokens_out: 1_500})
    |> json_response(200)

    finished = render(view)
    assert finished =~ "0 in flight"
    assert finished =~ "1 finished"
    assert finished =~ "10,500"
  end

  test "another tenant's work never reaches this look-in", ctx do
    {:ok, view, _html} = live(ctx.conn, "/queues")

    {:ok, _} =
      Queues.record(ctx.tenant <> "-neighbour", %{"task" => "not-mine", "worker" => "crew-9"})

    refute render(view) =~ "not-mine"
    assert render(view) =~ "No work in flight"
  end

  test "raw subject traffic still shows alongside the worker table", ctx do
    {:ok, view, _html} = live(ctx.conn, "/queues")

    Phoenix.PubSub.broadcast(
      FirstmatePort.PubSub,
      FirstmatePort.NATS.QueueListener.topic(ctx.tenant),
      {:nats_event,
       %{
         subject: "#{ctx.tenant}.steer.inbox",
         body: "{\"task\":\"peek\"}",
         at: DateTime.utc_now()
       }}
    )

    rendered = render(view)
    assert rendered =~ "#{ctx.tenant}.steer.inbox"
    assert rendered =~ "peek"
  end
end
