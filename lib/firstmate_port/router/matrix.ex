defmodule FirstmatePort.Router.Matrix do
  @moduledoc """
  Fleet capability matrix for worker routing.

  Each lane is a harness the fleet can actually drive (the same set
  `no-mistakes doctor` probes: claude, codex, grok, opencode). The matrix
  is the base vote in every routing decision: provider intel (OpenRouter /
  Artificial Analysis) only refines the model pick inside the chosen lane,
  and the eval set in `FirstmatePort.Router.Evals` guards regressions.

  Cost/latency/quality are coarse 1-3/1-4 tiers on purpose: exact prices
  move weekly and live in provider intel, not here. Do not add model IDs
  here; models resolve at route time (see `FirstmatePort.Router`).
  """

  @lanes [
    %{
      harness: "grok",
      base_effort: "low",
      quality: 2,
      cost: 1,
      latency: 1,
      kinds: [:chat, :research],
      live_web: true,
      citations: false,
      max_ambiguity: :medium,
      max_blast_radius: :low,
      max_risk: :low
    },
    %{
      harness: "opencode",
      base_effort: "low",
      quality: 2,
      cost: 1,
      latency: 1,
      kinds: [:docs, :chat],
      live_web: false,
      citations: false,
      max_ambiguity: :low,
      max_blast_radius: :low,
      max_risk: :low
    },
    %{
      harness: "codex",
      base_effort: "medium",
      quality: 3,
      cost: 2,
      latency: 2,
      kinds: [:code, :ops, :review, :data],
      live_web: false,
      citations: true,
      max_ambiguity: :medium,
      max_blast_radius: :medium,
      max_risk: :medium
    },
    %{
      harness: "claude",
      base_effort: "medium",
      quality: 4,
      cost: 3,
      latency: 2,
      kinds: [:code, :research, :ops, :docs, :data, :chat],
      live_web: false,
      citations: true,
      max_ambiguity: :high,
      max_blast_radius: :high,
      max_risk: :high
    }
  ]

  @doc "All routing lanes, cheapest first."
  def lanes, do: @lanes

  @doc "Lane for a harness name, or nil."
  def lane(harness) when is_binary(harness) do
    Enum.find(@lanes, &(&1.harness == harness))
  end

  @doc "Harness names the fleet can route to."
  def harnesses, do: Enum.map(@lanes, & &1.harness)

  # Captain-pinned hard routes: {kind => %{harness:, model:, model_display:}}.
  # Code review always goes to Codex with GPT-6-Astra, never a chat lane.
  @hard_routes %{
    review: %{harness: "codex", model: "gpt-6-astra", model_display: "GPT-6-Astra"}
  }

  @doc "Hard-routed pick for a task kind, or nil when the matrix decides."
  def hard_route(kind) when is_atom(kind), do: Map.get(@hard_routes, kind)
end
