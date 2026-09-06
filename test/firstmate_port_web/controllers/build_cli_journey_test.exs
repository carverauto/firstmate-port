defmodule FirstmatePortWeb.BuildCliJourneyTest do
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Accounts.User

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "crew reports docker, k8s and other systems through fm-steer and HTTP", %{tmp_dir: tmp_dir} do
    binary = Path.join(tmp_dir, "fm-steer")
    {output, code} = System.cmd("go", ["build", "-o", binary, "./cmd/fm-steer"], stderr_to_stdout: true)
    assert code == 0, output

    token = "fmh_" <> Base.encode16(:crypto.strong_rand_bytes(24))
    {:ok, _agent} = User.bootstrap_agent(%{
      email: "build-journey@localhost",
      name: "Build journey",
      hashed_api_key: User.hash_token(token)
    }, authorize?: false)

    server = start_supervised!({Bandit, plug: FirstmatePortWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    instance = "http://127.0.0.1:#{port}"
    env = [
      {"XDG_CONFIG_HOME", tmp_dir},
      {"FIRSTMATE_INSTANCE", instance},
      {"FIRSTMATE_AGENT_TOKEN", token},
      {"FIRSTMATE_AGENT_ID", "environment-agent"},
      {"FIRSTMATE_MODEL", "environment-model"},
      {"FIRSTMATE_EFFORT", "low"}
    ]

    transcript = Enum.map_join([{"docker", "success"}, {"k8s", "failure"}, {"bazel", "cancelled"}], "\n", fn {kind, status} ->
      start_args = ["build", "start", "--kind", kind, "--target", "example-app",
        "--agent-id", "crew-7", "--model", "model-flag", "--effort", "high",
        "--cluster", "example-cluster", "--namespace", "example",
        "--started-at", "2026-09-06T01:00:00Z"]
      {start_output, 0} = System.cmd(binary, start_args, env: env)
      start = Jason.decode!(start_output)
      assert %{"run_id" => run_id, "status" => "started", "kind" => ^kind} = start
      assert run_id != ""

      finish_args = ["build", "finish", "--run-id", run_id, "--status", status,
        "--tokens", "48210", "--outcome", "verification #{status}",
        "--finished-at", "2026-09-06T01:04:00Z"]
      {finish_output, 0} = System.cmd(binary, finish_args, env: env)
      assert %{"run_id" => ^run_id, "status" => ^status, "kind" => ^kind} = Jason.decode!(finish_output)

      response = Req.get!(instance <> "/api/build-events", params: [run_id: run_id], auth: {:bearer, token})
      assert response.status == 200
      assert %{"data" => events} = response.body
      assert [started] = Enum.filter(events, &(&1["status"] == "started"))
      assert [finished] = Enum.filter(events, &(&1["status"] == status))
      assert [_, _] = events
      assert started["tokens"] == 0
      assert started["finished_at"] == nil
      assert finished["id"] != started["id"]
      assert finished["tokens"] == 48_210
      for event <- events do
        assert %{"agent_id" => "crew-7", "model" => "model-flag", "effort" => "high",
          "cluster" => "example-cluster", "namespace" => "example", "kind" => ^kind} = event
        refute Map.has_key?(event, "pr_url")
      end

      runs = Req.get!(instance <> "/api/build-runs", auth: {:bearer, token})
      assert runs.status == 200
      assert [run] = Enum.filter(runs.body["data"], &(&1["run_id"] == run_id))
      assert %{"duration_ms" => 240_000, "events" => 2, "tokens" => 48_210,
        "status" => ^status, "agent_id" => "crew-7", "model" => "model-flag", "effort" => "high"} = run

      "$ fm-steer #{Enum.map_join(start_args, " ", &inspect/1)}\n#{start_output}" <>
        "$ fm-steer #{Enum.map_join(finish_args, " ", &inspect/1)}\n#{finish_output}" <>
        "GET /api/build-events?run_id=#{run_id}\n#{Jason.encode!(response.body, pretty: true)}\n" <>
        "GET /api/build-runs (matching run)\n#{Jason.encode!(run, pretty: true)}\n"
    end)

    if path = System.get_env("BUILD_JOURNEY_EVIDENCE") do
      File.write!(path, "Actual fm-steer binary → HTTP API → isolated PostgreSQL.\n" <>
        "Environment attribution differs from explicit start flags; finish inherits the start.\n\n" <> transcript)
    end
  end
end
