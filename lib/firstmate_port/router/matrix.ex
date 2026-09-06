defmodule FirstmatePort.Router.Matrix do
  @moduledoc """
  Fleet capability matrix for worker routing.

  Each lane is a harness the fleet can actually drive (the same set
  `no-mistakes doctor` probes: claude, codex, grok, opencode). The matrix
  is the base vote in every routing decision, and the eval set in
  `FirstmatePort.Router.Evals` guards regressions.

  Every lane names the concrete model it runs at each effort it can
  actually reach, so a route always answers with a real id — never a
  placeholder, and never an entry no task can select. This table is
  human-owned: when the fleet moves to a new model, edit `:models` here
  and the eval set will tell you what changed.

  `:min_effort` is how cheap a lane is willing to go when nothing about the
  task is hard. It matters only for claude, which is the lane every
  capability-constrained task falls into: a plain question that merely
  needs citations should not pay for Opus.

  Cost/latency/quality are coarse 1-3/1-4 tiers on purpose: exact prices
  move weekly and are not tracked here. Provider intel (Artificial
  Analysis) only annotates the reasons; it never changes the lane or the
  model.
  """

  # Captain-pinned hard routes: {kind => %{harness:, model:}}.
  # Code review always goes to Codex with GPT-6-Astra, never a chat lane.
  @hard_routes %{
    review: %{harness: "codex", model: "gpt-6-astra"}
  }

  @lanes [
    %{
      harness: "grok",
      models: %{"low" => "grok-4-fast"},
      base_effort: "low",
      min_effort: "low",
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
      models: %{"low" => "qwen3-coder"},
      base_effort: "low",
      min_effort: "low",
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
      models: %{"medium" => "gpt-6-astra"},
      base_effort: "medium",
      min_effort: "medium",
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
      min_effort: "low",
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
  The model a lane runs at `effort`. Every effort a lane can reach is
  declared, so an undeclared pair means the matrix and the effort rules
  have drifted apart — that raises rather than inventing a model.
  """
  def model(harness, effort) when is_binary(harness) do
    Map.fetch!(lane(harness).models, effort)
  end

  @doc "Every model id the matrix can answer with, including hard routes."
  def declared_models do
    (Enum.flat_map(@lanes, &Map.values(&1.models)) ++
       Enum.map(Map.values(@hard_routes), & &1.model))
    |> Enum.uniq()
  end

  # Display names for the ids above: what a human reads in `fm-steer route`.
  @model_display %{
    "gpt-6-astra" => "GPT-6-Astra",
    "claude-opus-5" => "Claude Opus 5",
    "claude-sonnet-5" => "Claude Sonnet 5",
    "claude-haiku-4-5-20251001" => "Claude Haiku 4.5",
    "grok-4-fast" => "Grok 4 Fast",
    "qwen3-coder" => "Qwen3 Coder"
  }

  @doc "Human-readable name for a model id."
  def model_display(id) when is_binary(id), do: Map.get(@model_display, id, id)

  @doc "Hard-routed pick for a task kind, or nil when the matrix decides."
  def hard_route(kind) when is_atom(kind), do: Map.get(@hard_routes, kind)
end
