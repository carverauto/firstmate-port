defmodule FirstmatePort.RouterTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Router
  alias FirstmatePort.Router.Matrix

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

  test "kind words do not fire inside longer unrelated words" do
    assert Router.classify("implement a preview pane for the diagram html").kind == :code
    assert Router.classify("explain how the retry loops work in the fanout job").kind == :chat
    assert Router.classify("compare the latest props and stops in the ui").kind == :research

    assert Router.classify("review this pull request").kind == :review
    assert Router.classify("reviewing the pull request for races").kind == :review
    assert Router.classify("the ops runbook needs a restart step").kind == :ops
  end

  test "risk words do not fire inside longer unrelated words" do
    assert Router.classify("suspend the discord fanout job").risk == :low
    assert Router.classify("add a prefix to the changelog entries").risk == :low
    assert Router.classify("document the surcharge rules for the plan").risk == :low
    assert Router.classify("recharge the prepaid credits").risk == :low

    assert Router.classify("spend the remaining credits on the crew key").risk == :medium
    assert Router.classify("charge the customer for the overage").risk == :high
  end

  test "a suspend task stays in the cheap lane" do
    got = Router.route("suspend the discord fanout job")

    assert got.harness == "grok"
    assert got.effort == "low"
  end

  test "a docs task naming a prefix is not code" do
    assert Router.classify("add a prefix to the changelog entries").kind == :docs
  end

  test "a prefixed code verb keeps the code lane" do
    assert Router.classify("hotfix the crash in the router").kind == :code

    got = Router.route("hotfix the crash in the router")

    assert got.harness == "codex"
    assert got.effort == "medium"
  end

  test "a prefixed ops verb keeps its kind and blast radius" do
    for text <- ["redeploy the api gateway", "undeploy the canary", "autoscale the workers"] do
      assert Router.classify(text).kind == :ops, "#{text} lost its ops kind"
    end

    for text <- ["redeploy the api gateway", "undeploy the canary"] do
      assert Router.classify(text).blast_radius == :high, "#{text} lost its blast radius"
    end

    got = Router.route("redeploy the api gateway")

    assert got.harness == "claude"
    assert got.effort == "high"
  end

  test "a preview feature is not hard-routed to the code-review model" do
    got = Router.route("implement a preview pane for the diagram html")

    assert got.harness == "codex"
    assert got.model == "gpt-6-astra"
    refute got.model_source == "fleet_hard_route"
  end

  test "a credential that only modifies another noun does not raise risk" do
    assert Router.classify("fix the memory leak in the token bucket cache").risk == :low
    assert Router.classify("implement the usage page that exposes token counts").risk == :low
    assert Router.classify("dump the token counts for the usage page to a csv").risk == :low
    assert Router.classify("the rate limiter leaks tokens under load").risk == :low
    assert Router.classify("fix the failing test for the auth token parser").risk == :low
  end

  test "a credential is risky on either side of its handling verb" do
    assert Router.classify("rotate the openrouter api token").risk == :high
    assert Router.classify("expose the auth token in the api response").risk == :high
    assert Router.classify("we hardcoded a secret in the repo").risk == :high

    assert Router.classify("the api token was leaked in a public log").risk == :high
    assert Router.classify("our openrouter secret got exposed in the repo").risk == :high
    assert Router.classify("the shared secret leaked into a public channel").risk == :high
  end

  test "storing or moving an api token is credential work, not cheap chat" do
    assert Router.classify("store the openrouter api token in the vault").risk == :high
    assert Router.classify("move the api token out of the repo into the vault").risk == :high

    got = Router.route("store the openrouter api token in the vault")
    assert got.harness == "claude"
    assert got.effort == "high"
    assert got.model == "claude-opus-5"
  end

  test "credential rotation runs the top claude model" do
    got = Router.route("rotate the openrouter api token")

    assert got.harness == "claude"
    assert got.effort == "high"
    assert got.model == "claude-opus-5"
  end

  test "a token counter task stays in the cheap lane" do
    got = Router.route("add a token usage counter to the portal")

    refute got.harness == "claude"
    assert got.effort == "low"
  end

  test "route sends standard code work to codex at medium effort" do
    got = Router.route("fix the failing test in the portal ingest controller")

    assert got.harness == "codex"
    assert got.effort == "medium"
    assert got.model == "gpt-6-astra"
    assert got.model_display == "GPT-6-Astra"
    assert got.model_source == "fleet_matrix"
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

  test "route escalates production deploys to claude at high effort" do
    got = Router.route("deploy the portal to production and run the database migration")

    assert got.harness == "claude"
    assert got.effort == "high"
    assert got.model == "claude-opus-5"
    assert Enum.any?(got.reasons, &String.contains?(&1, "blast_radius"))
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
  end

  test "unknown axis overrides are ignored" do
    axes = Router.classify("fix a bug", %{kind: :teleport, ambiguity: :high})

    assert axes.kind == :code
    assert axes.ambiguity == :high
  end

  test "intel annotates the answer but never narrows the model" do
    intel = %{
      benchmarks: [%{"model" => "codex-1", "quality_score" => 71}],
      sources: ["artificial-analysis"]
    }

    got = Router.route("fix the failing test", intel: intel)
    plain = Router.route("fix the failing test")

    assert got.harness == plain.harness
    assert got.model == "gpt-6-astra"
    assert got.model_source == "fleet_matrix"
    assert "artificial-analysis" in got.intel_sources
    assert Enum.any?(got.reasons, &String.contains?(&1, "Artificial Analysis"))
  end

  test "every lane names a real model, scaled by effort" do
    assert Router.route("what does the fm-steer status command print?").model == "grok-4-fast"
    assert Router.route("write user docs for the inbox list command").model == "qwen3-coder"
    assert Router.route("fix the failing test in the ingest controller").model == "gpt-6-astra"
    assert Router.route("deploy the portal to production").model == "claude-opus-5"

    claude_medium = Router.route("write user docs for inbox list", axes: %{ambiguity: :medium})
    assert claude_medium.model == "claude-sonnet-5"

    for description <- ["fix the failing test", "deploy the portal to production", "hi there"] do
      got = Router.route(description)
      refute got.model == "harness-default"
      assert got.model_display != got.model or got.model == got.model_display
    end
  end

  test "a cheap task in the claude lane runs the cheap claude model" do
    got = Router.route("summarize the compliance rules and cite the sources required")

    assert got.harness == "claude"
    assert got.effort == "low"
    assert got.model == "claude-haiku-4-5-20251001"
    assert got.model_display == "Claude Haiku 4.5"

    harder =
      Router.route("summarize the compliance rules and cite the sources required",
        axes: %{ambiguity: :medium}
      )

    assert harder.harness == "claude"
    assert harder.effort == "medium"
    assert harder.model == "claude-sonnet-5"

    escalated =
      Router.route("summarize the compliance rules and cite the sources required",
        axes: %{risk: :high}
      )

    assert escalated.effort == "high"
    assert escalated.model == "claude-opus-5"
  end

  test "an escalated task keeps the claude base model, not the cheap one" do
    got = Router.route("fix the failing test using the latest elixir release notes")

    assert got.harness == "claude"
    assert got.effort == "medium"
    assert got.model == "claude-sonnet-5"

    assert Enum.any?(got.reasons, &String.contains?(&1, "no lane satisfies every constraint"))
  end

  test "no model the matrix declares is unreachable, and no route needs an undeclared one" do
    levels = [:low, :medium, :high]

    reached =
      for kind <- Router.kinds(),
          ambiguity <- levels,
          blast <- levels,
          risk <- levels,
          cites <- [true, false],
          web <- [true, false],
          into: MapSet.new() do
        Router.route("a task",
          axes: %{
            kind: kind,
            ambiguity: ambiguity,
            blast_radius: blast,
            risk: risk,
            citations_required?: cites,
            live_web_required?: web
          }
        ).model
      end

    assert MapSet.equal?(reached, MapSet.new(Matrix.declared_models())),
           "declared but unreachable: #{inspect(MapSet.difference(MapSet.new(Matrix.declared_models()), reached))}"
  end

  test "an eval case that names no model cannot pass" do
    assert ["nameless: expected codex/medium/-" <> _] =
             Router.check_evals(
               cases: [
                 %{
                   name: "nameless",
                   description: "fix the failing test in the ingest controller",
                   expect_harness: "codex",
                   expect_effort: "medium"
                 }
               ]
             )
  end

  test "bundled eval set stays green" do
    assert Router.check_evals() == []
  end
end
