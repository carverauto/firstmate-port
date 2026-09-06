defmodule FirstmatePort.Router.Matrix do
  @moduledoc """
  Fleet capability matrix for worker routing.

  Each lane is a harness the fleet can actually drive (the same set
  `no-mistakes doctor` probes: claude, codex, grok, opencode). The matrix
  is the base vote in every routing decision, and the eval set in
  `FirstmatePort.Router.Evals` guards regressions.

  Every lane names the concrete model it runs per effort level, so a route
  always answers with a real id — never a placeholder. This table is
  human-owned: when the fleet moves to a new model, edit `:models` here
  and the eval set will tell you what changed.

  Cost/latency/quality are coarse 1-3/1-4 tiers on purpose: exact prices
  move weekly and are not tracked here. Provider intel (Artificial
  Analysis) only annotates the reasons; it never changes the lane or the
  model.
  """

  @lanes [
    %{
      harness: "grok",
      models: %{
        "low" => "grok-4-fast",
        "medium" => "grok-4",
        "high" => "grok-4"
      },
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
      models: %{
        "low" => "qwen3-coder",
        "medium" => "qwen3-coder",
        "high" => "qwen3-coder"
      },
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
      models: %{
        "low" => "gpt-6-astra",
        "medium" => "gpt-6-astra",
        "high" => "gpt-6-astra"
      },
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
      models: %{
        "low" => "claude-haiku-4-5-20251001",
        "medium" => "claude-sonnet-5",
        "high" => "claude-opus-5"
      },
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

  @doc """
  The model a lane runs at `effort`. Falls back to the lane's base effort
  for an unknown level, so this never answers with a placeholder.
  """
  def model(harness, effort) when is_binary(harness) do
    case lane(harness) do
      nil -> nil
      lane -> Map.get(lane.models, effort) || Map.fetch!(lane.models, lane.base_effort)
    end
  end

  # Display names for the ids above: what a human reads in `fm-steer route`.
  @model_display %{
    "gpt-6-astra" => "GPT-6-Astra",
    "claude-opus-5" => "Claude Opus 5",
    "claude-sonnet-5" => "Claude Sonnet 5",
    "claude-haiku-4-5-20251001" => "Claude Haiku 4.5",
    "grok-4" => "Grok 4",
    "grok-4-fast" => "Grok 4 Fast",
    "qwen3-coder" => "Qwen3 Coder"
  }

  @doc "Human-readable name for a model id."
  def model_display(id) when is_binary(id), do: Map.get(@model_display, id, id)

  # Captain-pinned hard routes: {kind => %{harness:, model:}}.
  # Code review always goes to Codex with GPT-6-Astra, never a chat lane.
  @hard_routes %{
    review: %{harness: "codex", model: "gpt-6-astra"}
  }

  @doc "Hard-routed pick for a task kind, or nil when the matrix decides."
  def hard_route(kind) when is_atom(kind), do: Map.get(@hard_routes, kind)
end
