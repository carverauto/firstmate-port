defmodule FirstmatePort.BuildEventsTest do
  use FirstmatePort.DataCase, async: true

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.BuildEvents
  alias FirstmatePort.Portal.BuildEvent

  setup do
    {:ok, agent} =
      User.bootstrap_agent(
        %{
          email: "build-agent@localhost",
          name: "build agent",
          hashed_api_key: User.hash_token("fmh_build_test")
        },
        authorize?: false
      )

    {:ok, agent: agent, opts: FirstmatePort.Tenancy.opts(agent)}
  end

  defp record!(attrs, opts) do
    {:ok, event} = BuildEvent.record(attrs, opts)
    event
  end

  test "a finish event inherits the run's context instead of rewriting the start row", %{
    opts: opts
  } do
    started_at = ~U[2026-09-06T01:00:00.000000Z]

    start =
      record!(
        %{
          run_id: "run-1",
          kind: "k8s",
          target: "serviceradar-web",
          status: :started,
          agent_id: "crew-7",
          model: "opus-5",
          effort: "high",
          cluster: "farm01",
          namespace: "serviceradar",
          image_tag: "sha-abc",
          started_at: started_at
        },
        opts
      )

    finish =
      record!(
        %{run_id: "run-1", status: :success, tokens: 42_000, outcome: "rolled"},
        opts
      )

    assert finish.id != start.id
    assert finish.kind == "k8s"
    assert finish.agent_id == "crew-7"
    assert finish.model == "opus-5"
    assert finish.effort == "high"
    assert finish.cluster == "farm01"
    assert finish.namespace == "serviceradar"
    assert finish.image_tag == "sha-abc"
    assert finish.started_at == started_at

    # The start row is untouched: the log is append-only.
    {:ok, reloaded} = BuildEvent.get(start.id, opts)
    assert reloaded.status == :started
    assert reloaded.tokens == 0
    # Ash casts an empty string to nil, so an unreported field stays blank.
    assert reloaded.outcome in [nil, ""]
  end

  test "explicit finish values win over the inherited ones", %{opts: opts} do
    record!(
      %{run_id: "run-2", kind: "docker", status: :started, agent_id: "crew-1", model: "opus-5"},
      opts
    )

    finish =
      record!(
        %{run_id: "run-2", kind: "k8s", status: :success, agent_id: "crew-2", model: "sonnet-5"},
        opts
      )

    assert finish.kind == "k8s"
    assert finish.agent_id == "crew-2"
    assert finish.model == "sonnet-5"
  end

  test "a run projection folds the newest report of each field", %{opts: opts} do
    started_at = ~U[2026-09-06T01:00:00.000000Z]
    finished_at = ~U[2026-09-06T01:04:00.000000Z]

    record!(
      %{
        run_id: "run-3",
        kind: "docker",
        target: "firstmate-port",
        status: :started,
        agent_id: "crew-7",
        model: "opus-5",
        effort: "high",
        started_at: started_at
      },
      opts
    )

    record!(
      %{
        run_id: "run-3",
        status: :success,
        tokens: 48_210,
        outcome: "pushed to ghcr.io",
        image_tag: "sha-deadbeef",
        finished_at: finished_at
      },
      opts
    )

    {:ok, run} = BuildEvents.run("run-3", opts)

    assert run.run_id == "run-3"
    assert run.kind == "docker"
    assert run.target == "firstmate-port"
    assert run.status == :success
    assert run.finished?
    assert run.agent_id == "crew-7"
    assert run.model == "opus-5"
    assert run.effort == "high"
    assert run.tokens == 48_210
    assert run.outcome == "pushed to ghcr.io"
    assert run.image_tag == "sha-deadbeef"
    assert run.started_at == started_at
    assert run.finished_at == finished_at
    assert run.duration_ms == 240_000
    assert run.events == 2
  end

  test "an unfinished run projects as started with no finish time", %{opts: opts} do
    record!(%{run_id: "run-4", kind: "bazel", status: :started, agent_id: "crew-7"}, opts)

    {:ok, run} = BuildEvents.run("run-4", opts)

    assert run.status == :started
    refute run.finished?
    assert run.finished_at == nil
    assert run.duration_ms == nil
    assert run.started_at
  end

  test "runs are newest first and :limit keeps the last N", %{opts: opts} do
    for n <- 1..3 do
      record!(
        %{run_id: "run-limit-#{n}", kind: "docker", status: :started, agent_id: "crew-7"},
        opts
      )
    end

    {:ok, runs} = BuildEvents.runs(Keyword.put(opts, :limit, 2))

    assert length(runs) == 2
    assert Enum.map(runs, & &1.run_id) == ["run-limit-3", "run-limit-2"]
  end

  test "a run with no events is not found", %{opts: opts} do
    assert {:error, :not_found} = BuildEvents.run("run-missing", opts)
  end

  test "recording requires an agent actor" do
    {:ok, human} =
      User.upsert_oidc(%{email: "build-human@example.com", name: "Human"}, authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             BuildEvent.record(
               %{run_id: "run-5", kind: "docker", status: :started, agent_id: "crew-7"},
               FirstmatePort.Tenancy.opts(human)
             )
  end

  test "an internal write with authorization off still inherits the run's context" do
    opts = [tenant: FirstmatePort.Tenancy.default_slug(), authorize?: false]

    record!(%{run_id: "run-7", kind: "helm", status: :started, agent_id: "crew-7"}, opts)
    finish = record!(%{run_id: "run-7", status: :success}, opts)

    assert finish.kind == "helm"
    assert finish.agent_id == "crew-7"
  end

  test "kind is required when no earlier event carries one", %{opts: opts} do
    assert {:error, %Ash.Error.Invalid{}} =
             BuildEvent.record(%{run_id: "run-6", status: :success, agent_id: "crew-7"}, opts)
  end
end
