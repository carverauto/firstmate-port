defmodule FirstmatePort.Router.Evals do
  @moduledoc """
  The fleet's own eval set for routing. Each case pins a task description
  to the expected lane and effort. `FirstmatePort.Router.check_evals/1`
  runs them; the router test fails on any mismatch.

  Extend this set when the fleet misroutes a real task: add the description
  (scrubbed) with the lane it should have taken, then fix the classifier or
  matrix until the set is green. This set — not any public leaderboard — is
  the regression gate for routing quality.
  """

  @cases [
    %{
      name: "trivial chat",
      description: "what does the fm-steer status command print?",
      expect_harness: "grok",
      expect_effort: "low"
    },
    %{
      name: "live research",
      description: "what is the latest news on elixir 1.20 release notes for this week?",
      expect_harness: "grok",
      expect_effort: "low"
    },
    %{
      name: "docs edit",
      description: "write user docs for the fm-steer inbox list command",
      expect_harness: "opencode",
      expect_effort: "low"
    },
    %{
      name: "standard code fix",
      description: "fix the failing test in the portal ingest controller for diagram uploads",
      expect_harness: "codex",
      expect_effort: "medium"
    },
    %{
      name: "plain code review",
      description: "review this pull request for correctness and flag any race conditions",
      expect_harness: "codex",
      expect_effort: "medium",
      expect_model: "gpt-6-astra"
    },
    %{
      name: "code review with citations",
      description:
        "review this pull request and cite the audit report lines that justify approval",
      expect_harness: "codex",
      expect_effort: "medium",
      expect_model: "gpt-6-astra"
    },
    %{
      name: "token counter feature",
      description: "implement a token usage counter in the portal",
      expect_harness: "codex",
      expect_effort: "medium"
    },
    %{
      name: "token parser bugfix",
      description: "fix the failing test for the auth token parser",
      expect_harness: "codex",
      expect_effort: "medium"
    },
    %{
      name: "billing page docs",
      description: "write user docs for the billing page",
      expect_harness: "opencode",
      expect_effort: "low"
    },
    %{
      name: "memory leak fix",
      description: "fix the memory leak in the token bucket cache",
      expect_harness: "codex",
      expect_effort: "medium"
    },
    %{
      name: "token counts on the usage page",
      description: "implement the usage page that exposes token counts",
      expect_harness: "codex",
      expect_effort: "medium"
    },
    %{
      name: "leaked credential",
      description: "someone leaked the shared secret into a public channel",
      expect_harness: "claude",
      expect_effort: "high"
    },
    %{
      name: "ambiguous investigation",
      description:
        "figure out why the fleet rolls are flaky on farm01; the cause is unknown, " <>
          "explore several hypotheses and propose a design with trade-offs",
      expect_harness: "claude",
      expect_effort: "high"
    },
    %{
      name: "prod deploy",
      description: "deploy the portal to production and run the database migration",
      expect_harness: "claude",
      expect_effort: "high"
    },
    %{
      name: "secret rotation",
      description: "rotate the customer-facing api key and the shared secret in production",
      expect_harness: "claude",
      expect_effort: "high"
    }
  ]

  @doc "Eval cases: `%{name:, description:, expect_harness:, expect_effort:}`."
  def cases, do: @cases
end
