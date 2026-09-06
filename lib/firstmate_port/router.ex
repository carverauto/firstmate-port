defmodule FirstmatePort.Router do
  @moduledoc """
  Task router owned by the portal. Given a task description, returns the
  worker harness, model, and effort plus the reasons why.

  Classification is a deterministic keyword heuristic (v1). Any axis can be
  overridden by the caller — that is the rater-agent path: a separate agent
  ranks difficulty and passes explicit axes, and the router still owns the
  final lane pick. fm-steer calls this through `POST /api/route`; it never
  routes locally and never touches JetStream.

  Decision order, never a single global rank:

  1. `Matrix` lanes (fleet capability) filter on hard constraints.
  2. Cheapest surviving lane wins; ties break on latency, then quality.
  3. Provider intel (`ProviderIntel`, Artificial Analysis) only annotates
     the reasons; it never changes the lane or the model.
  4. `Evals` pins known tasks to lanes so regressions fail tests.
  """

  alias FirstmatePort.Router.{Evals, Matrix, ProviderIntel}

  @efforts ["low", "medium", "high"]
  @ambiguities [:low, :medium, :high]
  @radii [:low, :medium, :high]
  @risks [:low, :medium, :high]
  @kinds [:code, :research, :ops, :docs, :review, :data, :chat]

  @doc """
  Classify a task description onto routing axes.

  Returns `%{kind:, ambiguity:, blast_radius:, citations_required?:,
  risk:, live_web_required?:}`. Pass `overrides` (atom keys) to force any
  axis — the rater-agent path.
  """
  def classify(description, overrides \\ %{}) when is_binary(description) do
    text = String.downcase(description)

    %{
      kind: detect_kind(text),
      ambiguity: detect_level(text, ambiguity_high(text), ambiguity_medium(text)),
      blast_radius: detect_level(text, blast_high(text), blast_medium(text)),
      citations_required?: cites?(text),
      risk: detect_level(text, risk_high(text), risk_medium(text)),
      live_web_required?: live_web?(text)
    }
    |> Map.merge(normalize_overrides(overrides))
  end

  @doc """
  Route a task description to `%{harness:, model:, model_source:, effort:,
  reasons:, axes:, intel_sources:, checkpoint:}`.

  Options:

  - `:axes` — axis overrides (rater-agent path).
  - `:intel` — provider intel map from `ProviderIntel.fetch/0`, or nil to
    route offline on matrix + evals only (the default; no network in tests).
  """
  def route(description, opts \\ []) when is_binary(description) do
    axes = classify(description, Keyword.get(opts, :axes, %{}))
    intel = Keyword.get(opts, :intel)

    case Matrix.hard_route(axes.kind) do
      nil -> matrix_route(axes, intel)
      pinned -> hard_route_result(axes, intel, pinned)
    end
  end

  defp answer(
         harness,
         model,
         model_display,
         model_source,
         effort,
         reasons,
         axes,
         intel,
         checkpoint
       ) do
    %{
      harness: harness,
      model: model,
      model_display: model_display,
      model_source: model_source,
      effort: effort,
      reasons: reasons ++ checkpoint_reasons(checkpoint),
      axes: axes,
      intel_sources: Enum.uniq(["fleet_matrix", "fleet_evals"] ++ ProviderIntel.sources(intel)),
      checkpoint: checkpoint
    }
  end

  defp hard_route_result(axes, intel, pinned) do
    lane = Matrix.lane(pinned.harness)
    effort = effort_for(lane, axes)

    answer(
      pinned.harness,
      pinned.model,
      pinned.model_display,
      "fleet_hard_route",
      effort,
      [
        "kind=#{axes.kind} is hard-routed to #{pinned.harness} with #{pinned.model_display}: " <>
          "code review never goes to a chat or docs lane"
      ],
      axes,
      intel,
      checkpoint_for(axes)
    )
  end

  defp matrix_route(axes, intel) do
    lanes = Matrix.lanes()
    {lane, reasons} = pick_lane(lanes, axes)
    effort = effort_for(lane, axes)
    {model, model_source, model_reasons} = ProviderIntel.select_model(lane.harness, intel)

    answer(
      lane.harness,
      model,
      display_for(lane.harness, model),
      model_source,
      effort,
      reasons ++ model_reasons,
      axes,
      intel,
      checkpoint_for(axes)
    )
  end

  defp display_for(_harness, "harness-default"), do: "harness default"
  defp display_for(_harness, model), do: model

  @doc "Effort levels, cheapest first."
  def efforts, do: @efforts

  @doc "Known task kinds."
  def kinds, do: @kinds

  # -- lane picking -----------------------------------------------------

  defp pick_lane(lanes, axes) do
    {survivors, reasons} =
      Enum.reduce(lanes, {[], []}, fn lane, {kept, notes} ->
        case lane_ok(lane, axes) do
          :ok -> {[lane | kept], notes}
          {:no, why} -> {kept, ["#{lane.harness} excluded: #{why}" | notes]}
        end
      end)

    survivors = Enum.reverse(survivors)

    case survivors do
      [] ->
        {Matrix.lane("claude"),
         reasons ++ ["no lane satisfies every constraint; escalated to claude for human triage"]}

      [only] ->
        {only, ["#{only.harness} is the only lane satisfying #{summarize_axes(axes)}"] ++ reasons}

      many ->
        best = Enum.min_by(many, &{&1.cost, &1.latency, -&1.quality})

        {best,
         [
           "#{best.harness} wins on expected quality x cost x latency " <>
             "among #{Enum.map_join(many, ", ", & &1.harness)}"
         ] ++ reasons}
    end
  end

  defp lane_ok(lane, axes) do
    cond do
      axes.live_web_required? and not lane.live_web ->
        {:no, "task needs live web"}

      axes.citations_required? and not lane.citations ->
        {:no, "task needs citations"}

      axes.kind not in lane.kinds ->
        {:no, "kind=#{axes.kind} outside lane"}

      level_gt?(axes.blast_radius, lane.max_blast_radius) ->
        {:no, "blast_radius=#{axes.blast_radius} exceeds lane max"}

      level_gt?(axes.ambiguity, lane.max_ambiguity) ->
        {:no, "ambiguity=#{axes.ambiguity} exceeds lane max"}

      level_gt?(axes.risk, lane.max_risk) ->
        {:no, "risk=#{axes.risk} exceeds lane max"}

      true ->
        :ok
    end
  end

  defp summarize_axes(axes) do
    "kind=#{axes.kind}, ambiguity=#{axes.ambiguity}, blast_radius=#{axes.blast_radius}, " <>
      "risk=#{axes.risk}, live_web=#{axes.live_web_required?}, citations=#{axes.citations_required?}"
  end

  defp level_gt?(a, b), do: level_rank(a) > level_rank(b)

  defp level_rank(:low), do: 0
  defp level_rank(:medium), do: 1
  defp level_rank(:high), do: 2

  defp effort_for(lane, axes) do
    base = Enum.find_index(@efforts, &(&1 == lane.base_effort)) || 1

    bump =
      cond do
        axes.blast_radius == :high -> 2
        axes.ambiguity == :high or axes.risk == :high -> 1
        true -> 0
      end

    Enum.at(@efforts, min(base + bump, length(@efforts) - 1))
  end

  defp checkpoint_for(%{blast_radius: :high}), do: "human-review"
  defp checkpoint_for(%{risk: :high}), do: "human-review"
  defp checkpoint_for(_), do: nil

  defp model_ok?(%{expect_model: want}, %{model: got}), do: want == got
  defp model_ok?(_case, _got), do: true

  defp checkpoint_reasons(nil), do: []

  defp checkpoint_reasons(checkpoint),
    do: ["checkpoint=#{checkpoint}: high blast radius or risk needs a human before side effects"]

  # -- classification heuristics -----------------------------------------

  defp normalize_overrides(overrides) when is_map(overrides) do
    Map.take(overrides, [
      :kind,
      :ambiguity,
      :blast_radius,
      :citations_required?,
      :risk,
      :live_web_required?
    ])
    |> Map.reject(fn
      {:kind, k} -> k not in @kinds
      {:ambiguity, l} -> l not in @ambiguities
      {:blast_radius, l} -> l not in @radii
      {:risk, l} -> l not in @risks
      {_k, _v} -> false
    end)
  end

  defp detect_kind(text) do
    # Action verbs outrank nouns: "latest news on elixir" is research even
    # though it names a language, and bare nouns ("test" is inside "latest")
    # never decide a kind on their own.
    cond do
      match_any?(text, ["review", "pull request", "approve", "audit the code", "code review"]) ->
        :review

      match_any?(text, [
        "deploy",
        "rollback",
        "helm",
        "k8s",
        "kubernetes",
        "restart",
        "scale",
        "migrate production",
        "dns",
        "firewall",
        "server",
        "ops"
      ]) ->
        :ops

      match_any?(text, [
        "implement",
        "fix",
        "hotfix",
        "bug",
        "refactor",
        "function",
        "module",
        "test suite",
        "failing test",
        "stacktrace",
        "compile",
        "failing build"
      ]) ->
        :code

      match_any?(text, [
        "document",
        "readme",
        "changelog",
        "user docs",
        "write docs",
        "landing page",
        "copy for"
      ]) ->
        :docs

      match_any?(text, [
        "dataset",
        "csv",
        "etl",
        "parquet",
        "analyze the logs",
        "log analysis",
        "metrics"
      ]) ->
        :data

      live_web?(text) ->
        :research

      match_any?(text, [
        "compare",
        "research",
        "evaluate",
        "benchmark",
        "landscape",
        "survey",
        "what is the best",
        "which model",
        "literature"
      ]) ->
        :research

      true ->
        :chat
    end
  end

  defp detect_level(_text, true, _medium), do: :high
  defp detect_level(_text, _high, true), do: :medium
  defp detect_level(_text, _high, _medium), do: :low

  defp blast_high(text) do
    match_any?(text, [
      "production",
      " prod ",
      "prod.",
      "deploy",
      "delete",
      "destroy",
      "drop table",
      "rollback",
      "customer",
      "money",
      "payment",
      "dns",
      "firewall",
      "credential",
      "auth system",
      "migrate production"
    ])
  end

  defp blast_medium(text) do
    # Bare "release" is excluded: "release notes" is reading, not shipping.
    match_any?(text, [
      "staging",
      "migration",
      "schema",
      "publish",
      "release to",
      "rollout",
      "roll out",
      "ship to",
      "go-live",
      "launch",
      "external",
      "webhook",
      "email to",
      "notify"
    ])
  end

  defp ambiguity_high(text) do
    match_any?(text, [
      "figure out",
      "explore",
      "unknown",
      "ambiguous",
      "not sure",
      "investigate",
      "vague",
      "spike",
      "unclear",
      "fuzzy"
    ]) or String.length(text) > 1200
  end

  defp ambiguity_medium(text) do
    match_any?(text, [
      "probably",
      "maybe",
      "might",
      "several",
      "various",
      "trade-off",
      "tradeoff",
      "design",
      "proposal"
    ]) or String.length(text) > 400
  end

  defp risk_high(text) do
    match_any?(text, [
      "password",
      "api key",
      "api token",
      "private key",
      "customer data",
      "pii",
      "payment",
      "charge",
      "refund",
      "delete",
      "destroy",
      "publish publicly",
      "datacenter",
      "root access"
    ]) or credential_handling?(text)
  end

  # "token" and "secret" are homonyms in ordinary work ("token usage
  # counter", "the memory leak in the token bucket"), so they raise risk
  # only when a handling verb governs them: either the verb heads the noun
  # phrase the credential ends ("rotate the openrouter api token") or the
  # credential is the subject of the verb ("the api token was leaked").
  # A credential that only modifies another noun ("token counts", "token
  # bucket") is never the thing being handled.
  @credential_handling ~r/
    (?:rotat|revok|leak|exfiltrat|hardcod|hard-cod|steal|stole|expos)\w*\s+
    (?:(?:the|a|an|our|your|my|its|this|that|all|any)\s+)?
    (?:[\w-]+\s+){0,3}
    (?:secret|token)s?
    (?=
      [\s.,;:!?)]*$
      | [.,;:!?)]
      | \s+(?:in|into|to|from|on|at|for|with|and|or|via|by|before|after|so|because|when|while|if|that|which|but|then)\b
    )
    |
    (?:secret|token)s?\s+
    (?:(?:was|were|is|are|got|been|being|has|have|had)\s+){0,3}
    (?:rotat|revok|leak|exfiltrat|hardcod|hard-cod|stolen|expos)\w*
  /x

  defp credential_handling?(text), do: Regex.match?(@credential_handling, text)

  defp risk_medium(text) do
    match_any?(text, [
      "external api",
      "third-party",
      "post to",
      "send to",
      "merge",
      "force-push",
      "spend"
    ])
  end

  defp cites?(text) do
    match_any?(text, [
      "cite",
      "citation",
      "sources required",
      "with sources",
      "references required",
      "compliance",
      "audit report",
      "paper"
    ])
  end

  defp live_web?(text) do
    match_any?(text, [
      "latest",
      "current price",
      "today",
      "this week",
      "news",
      "what happened",
      "browse",
      "look up online",
      "search the web",
      "live data",
      "stock",
      "release notes for",
      "changelog for",
      "who won"
    ])
  end

  # Bare tokens that a longer word swallows: "review" inside "preview",
  # "ops" inside "loops", "spend" inside "suspend", "fix" inside "prefix",
  # "charge" inside "surcharge". These match only at a word start, so the
  # prefixed spelling that IS the verb ("hotfix") is listed in its own
  # table. "deploy" and "scale" stay substrings so prefixed ops verbs
  # ("redeploy", "autoscale") keep their kind.
  @anchored ~w(review ops spend fix charge hotfix)

  defp match_any?(text, patterns) do
    Enum.any?(patterns, fn
      pattern when pattern in @anchored -> starts_a_word?(text, pattern)
      pattern -> String.contains?(text, pattern)
    end)
  end

  defp starts_a_word?(text, pattern) do
    text
    |> :binary.matches(pattern)
    |> Enum.any?(fn {at, _len} -> at == 0 or not word_char?(:binary.at(text, at - 1)) end)
  end

  defp word_char?(c), do: c in ?a..?z or c in ?0..?9 or c == ?_

  @doc """
  Run the bundled eval set through `route/2` and report mismatches.
  Used by tests and by operators extending the set in `Evals`.
  """
  def check_evals(opts \\ []) do
    Evals.cases()
    |> Enum.map(fn c ->
      got = route(c.description, opts)
      {c, got}
    end)
    |> Enum.reject(fn {c, got} ->
      got.harness == c.expect_harness and got.effort == c.expect_effort and
        model_ok?(c, got)
    end)
    |> Enum.map(fn {c, got} ->
      "#{c.name}: expected #{c.expect_harness}/#{c.expect_effort}/#{Map.get(c, :expect_model, "-")}, " <>
        "got #{got.harness}/#{got.effort}/#{got.model} for #{inspect(c.description)}"
    end)
  end
end
