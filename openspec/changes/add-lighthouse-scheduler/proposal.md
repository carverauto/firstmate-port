# Change: Lighthouse — usage ledger, task rating, model ranking, and fair crew scheduling

## Why

The portal already routes a task description to a harness/model/effort
(`lib/firstmate_port/router.ex`) and already tracks per-account allowance and
burn (`lib/firstmate_port/usage.ex`). The two never meet. Routing is stateless:
it cannot see that an account is at 92% of its monthly allowance, it cannot say
what a task will probably cost before dispatching it, and nothing records what a
task actually cost afterwards. Fairness is likewise unspecified — one tenant's
burst can drain a shared provider allowance that the whole crew depends on, and
nothing notices until the allowance is gone.

Lighthouse closes that loop. It is the portal-owned subsystem that keeps the
light on the fleet's spend: it records **actual** model usage per task, projects
**expected** usage before dispatch from the task's difficulty, ranks models from
several independent leaderboard/API inputs rather than one global rank, and
assigns each task a harness, a model, and an effort level under a fair share of
the remaining allowance.

This proposal also settles three product calls that have been drifting as
one-off code patches: what feeds the ledger, how credential-handling tasks are
distinguished from tasks whose code merely mentions credentials, and whether
quota pressure may block work or only warn.

## What Changes

- **Usage ledger becomes per-task, not just per-account.** Add a `UsageEvent`
  resource recording actual spend attributed to a task, tenant, harness, model,
  and effort. `UsageAccount` (`lib/firstmate_port/portal/usage_account.ex`) and
  `UsageSnapshot` keep their present roles; account `used` becomes a
  reconcilable rollup rather than the only record. The ledger is fed by posted
  usage — the API and the portal UI — with no provider sync in this change.
- **Task rating is named and separable.** The axis classifier in
  `Router.classify/2` gains an explicit `difficulty` score and a
  `projected_usage` envelope (expected tokens and cost with a confidence band),
  derived from a calibration table that learns from recorded `UsageEvent`s.
- **Model ranking becomes multi-source with provenance.** Add `ModelScore`
  rows built by a ranking job from Artificial Analysis, LMArena, LiveBench, the
  Hugging Face Open LLM Leaderboard, and task-specific benchmarks (SWE-bench,
  BrowseComp, GAIA), each normalized per axis, weight-capped, and stamped with
  a source and an observation time. No single source may decide a
  route, stale sources are excluded and reported, and the fleet's own eval set
  (`lib/firstmate_port/router/evals.ex`) outranks every public source.
- **Scheduling becomes fair and quota-aware.** Add a scheduler that admits,
  downgrades, re-assigns, or defers a task based on remaining allowance,
  per-tenant fair share, and account spend priority — and that reserves
  projected spend so a burst cannot overcommit a shared allowance. Work is
  moved off a harness whose funding is exhausted (GitHub issue 2), while cost
  pressure alone only lowers effort within the chosen lane.
- **The hard route is spec, not a heuristic.** Kind `review` SHALL route to
  harness `codex` with model `gpt-6-astra`. The scheduler may change effort or
  defer, and SHALL NOT re-route a code review to another harness for cost.
- **Three product calls become recorded decisions** with recommended defaults
  (see `design.md`): what feeds the ledger, credential-phrase routing, who
  rates difficulty, and advisory-vs-blocking enforcement.
- **Ranking, quota math, and the capability matrix stay in Elixir.** `fm-steer`
  (`cmd/fm-steer/main.go`) gains no engine — it stays a thin HTTP client for
  `POST /api/route`, `GET /api/usage`, and the new scheduling endpoints.

This change is the specification for
[issue 2](https://github.com/carverauto/firstmate-port/issues/2): collect stats
on AI models, route tasks to the right agent, assign model and effort, track
token usage, re-assign work off agents hitting usage limits, and post that
telemetry to the portal API for storage and display.

## Impact

- Affected specs: `usage-ledger` (new), `task-rating` (new), `model-ranking`
  (new), `crew-scheduling` (new)
- Affected code:
  - `lib/firstmate_port/router.ex` — classification gains difficulty and
    projection; lane pick gains a quota-aware admission step
  - `lib/firstmate_port/router/matrix.ex` — lane constraints unchanged; hard
    route promoted to a spec requirement
  - `lib/firstmate_port/router/provider_intel.ex` — becomes one adapter among
    several behind a ranking behaviour
  - `lib/firstmate_port/router/evals.ex` — the regression gate for every
    classifier and ranking change
  - `lib/firstmate_port/usage.ex`, `lib/firstmate_port/usage/sync.ex` — burn and
    runway feed admission
  - `lib/firstmate_port/portal/usage_account.ex`,
    `lib/firstmate_port/portal/usage_snapshot.ex` — joined by `UsageEvent`,
    `ModelScore`
  - `lib/firstmate_port_web/controllers/route_controller.ex`,
    `usage_controller.ex` — request/response shape grows projection and
    admission fields
  - `lib/firstmate_port_web/live/usage_live.ex` — shows projection, fair share,
    and ranking provenance
  - `cmd/fm-steer/main.go` — new subcommand surface only, no engine
- Images and deploy docs for this work name **ghcr.io** (captain, 2026-09-05);
  Harbor is no longer the fleet registry.
