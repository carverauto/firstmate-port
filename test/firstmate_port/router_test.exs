defmodule FirstmatePort.RouterTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Router

  test "classify detects a standard code task" do
    axes = Router.classify("fix the failing test in the portal ingest controller")

    assert axes.kind == :code
    assert axes.ambiguity == :low
    assert axes.blast_radius == :low
    assert axes.live_web_required? == false
    assert axes.citations_required? == false
  end

  test "classify detects live web and high blast radius" do
    axes = Router.classify("what is the latest news on the production deploy today?")

    assert axes.live_web_required? == true
    assert axes.blast_radius == :high
  end

  test "classify detects citations and risk" do
    axes =
      Router.classify("review this pull request, cite the audit report, it touches the api key")

    assert axes.kind == :review
    assert axes.citations_required? == true
    assert axes.risk == :high
  end

  test "credential nouns need a handling verb before they raise risk" do
    assert Router.classify("add a token usage counter to the portal").risk == :low
    assert Router.classify("fix the failing test for the auth token parser").risk == :low
    assert Router.classify("write user docs for the billing page").blast_radius == :low

    assert Router.classify("rotate the shared secret").risk == :high
    assert Router.classify("someone leaked the api token in a public log").risk == :high
  end

  test "a token counter task stays in the cheap lane" do
    got = Router.route("add a token usage counter to the portal")

    refute got.harness == "claude"
    assert got.effort == "low"
    assert got.checkpoint == nil
  end

  test "route sends standard code work to codex at medium effort" do
    got = Router.route("fix the failing test in the portal ingest controller")

    assert got.harness == "codex"
    assert got.effort == "medium"
    assert got.model == "harness-default"
    assert got.model_source == "harness_default"
    assert got.checkpoint == nil
    assert got.intel_sources == ["fleet_matrix", "fleet_evals"]
    assert length(got.reasons) > 0
  end

  test "code review hard-routes to codex with GPT-6-Astra" do
    got = Router.route("review this pull request for correctness")

    assert got.harness == "codex"
    assert got.model == "gpt-6-astra"
    assert got.model_display == "GPT-6-Astra"
    assert got.model_source == "fleet_hard_route"
    assert Enum.any?(got.reasons, &String.contains?(&1, "hard-routed"))
  end

  test "route escalates production deploys to claude with a checkpoint" do
    got = Router.route("deploy the portal to production and run the database migration")

    assert got.harness == "claude"
    assert got.effort == "high"
    assert got.checkpoint == "human-review"
    assert Enum.any?(got.reasons, &String.contains?(&1, "checkpoint"))
  end

  test "route sends live-web research to the web lane" do
    got = Router.route("what is the latest news on elixir releases this week?")

    assert got.harness == "grok"
    assert got.effort == "low"
  end

  test "axis overrides let a rater agent force the lane" do
    got =
      Router.route("write user docs for inbox list",
        axes: %{blast_radius: :high, kind: :docs}
      )

    assert got.harness == "claude"
    assert got.checkpoint == "human-review"
  end

  test "unknown axis overrides are ignored" do
    axes = Router.classify("fix a bug", %{kind: :teleport, ambiguity: :high})

    assert axes.kind == :code
    assert axes.ambiguity == :high
  end

  test "intel refines the model inside the lane" do
    intel = %{
      models: [
        %{id: "openai/cheap-code", prompt_price: 0.5, completion_price: 1.0, context: 128_000},
        %{id: "openai/spendy-code", prompt_price: 5.0, completion_price: 10.0, context: 128_000}
      ],
      benchmarks: [],
      sources: ["openrouter"]
    }

    got = Router.route("fix the failing test", intel: intel)

    assert got.harness == "codex"
    assert got.model == "openai/cheap-code"
    assert got.model_source == "openrouter"
    assert "openrouter" in got.intel_sources
  end

  test "bundled eval set stays green" do
    assert Router.check_evals() == []
  end
end
