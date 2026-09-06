# Lighthouse — design

## Context

The portal owns routing and the usage ledger; `fm-steer` is a portable Go CLI
that speaks only HTTP to this API and never dials NATS. Today those two halves
are independent:

- `FirstmatePort.Router.route/2` (`lib/firstmate_port/router.ex:61`) classifies a
  description onto axes, filters `Matrix` lanes on hard constraints, picks the
  cheapest survivor, and lets `ProviderIntel` refine the model *inside* the
  chosen lane. It is pure and stateless.
- `FirstmatePort.Usage` (`lib/firstmate_port/usage.ex`) computes remaining,
  percent used, status, and a runway estimate from `UsageAccount` plus
  `UsageSnapshot` history.

Nothing connects them. The router cannot see spend; the ledger never learns what
a route cost. "Cheapest lane" is a *tier* comparison (`cost: 1..3` in
`matrix.ex`), not money, and it is evaluated per task in isolation, so N tasks
each individually cheap can still drain a shared monthly allowance.

Lighthouse is the closed loop over those parts. It is a subsystem, not a new
service: same Phoenix app, same Postgres, same tenancy attribute.

## Goals / Non-Goals

**Goals**

- Record actual model usage per task, attributable to tenant, harness, model,
  and effort.
- Project a task's usage *before* dispatch, from its difficulty, with an honest
  confidence band.
- Rank models from several independent inputs, with provenance and staleness,
  never a single global rank.
- Assign harness, model, and effort under a fair share of remaining allowance.
- Keep every one of those in Elixir. `fm-steer` gains commands, not logic.

**Non-Goals**

- Billing, invoicing, or money movement. The ledger reports what providers
  report; it is not an accounting system of record.
- Replacing the capability matrix with a learned model. The matrix stays a
  small, readable, human-owned table.
- Any provider usage sync, provider spend credential, or OpenRouter integration
  (captain, 2026-09-05; see Decision 1).
- Live-web ranking scrapes at route time. Ranking is a background job; routing
  reads its stored output.
- Rebuilding tenancy, the extract, or the Bazel/OCI stack.

## Architecture

Four parts, each a plain Elixir module tree under `FirstmatePort.Lighthouse`:

```
Rater      description + overrides -> axes + difficulty + projected_usage
Rank       background job          -> ModelScore rows (per model, per axis, per source)
Ledger     UsageAccount/Snapshot/Event -> headroom, burn, runway, actuals
Scheduler  axes + rank + ledger    -> assignment {harness, model, effort, decision}
```

Request path for `POST /api/route`:

1. **Rate.** `Rater.rate/2` returns the existing axes plus `difficulty`
   (0.0–1.0) and `projected_usage`.
2. **Constrain.** `Matrix.lanes/0` filters on hard constraints exactly as today.
   `Matrix.hard_route/1` still short-circuits kind `review`.
3. **Rank.** `Rank.candidates/2` orders models within surviving lanes using
   stored `ModelScore` rows for the axes that matter to this task.
4. **Admit.** `Scheduler.admit/2` checks projected cost against the account the
   candidate would spend from, the tenant's fair share, and account
   `spend_priority`, then returns `:admit`, `:downgrade`, or `:defer`.
5. **Answer.** The response carries harness, model, effort, decision, reasons,
   axes, projection, and the ranking sources actually used.

Completion path: the worker reports actuals to `POST /api/usage/events`; the
ledger writes a `UsageEvent`, releases the reservation, reconciles account
`used`, and feeds the calibration table that projections read.

### Why a reservation, not just a post-hoc counter

Projection without reservation does not prevent overcommit: ten tasks can each
be admitted against the same remaining allowance before any of them reports.
A reservation is a short-lived hold of `projected_usage.expected` against the
account, released on the matching `UsageEvent` or by TTL expiry. This is the
smallest mechanism that makes admission honest, and it is why `UsageEvent`
carries the reservation id.

## Decisions

### Decision 1 — What feeds the ledger: posted usage only

**Captain, 2026-09-05: defer OpenRouter entirely.** We do not know why or what
we would do with it at the moment. This change therefore adds no provider usage
sync at all, and OpenRouter is out of scope as an input, as a credential, and as
a ranking source.

**Options.** (a) The ledger is fed by posted usage — workers and the portal UI
write what was consumed. (b) The ledger polls provider APIs for authoritative
per-account spend. (c) Both, with provider figures overriding posted ones.

**Decision: (a), posted usage only.** `UsageEvent` rows written through the API
and the portal UI are the ledger's input. Account `used` is the rollup of those
rows. No provider is contacted for spend in this change.

**Why.** A sync path is only worth its credential handling, rotation, and
failure modes once the fleet knows which provider relationship it wants. Posted
usage needs no provider credential at all, works for every harness the crew
actually drives, and is the same shape the ledger would keep anyway — provider
figures, if they ever arrive, reconcile *against* posted rows rather than
replacing the model.

**Consequence.** Every figure this pass is `posted`, not provider-verified. The
API and the LiveView SHALL label it so, and SHALL NOT present it as an invoice.

**Revisit when.** The captain picks a provider relationship deliberately. At
that point a sync adapter writes `provider_reported` rows alongside posted ones;
`UsageEvent` already records the account id, so the ledger shape does not change.

### Decision 2 — Credential-phrase routing: an intent lexicon, not more regex

**Problem.** `risk_high/1` matches substrings. Adding `"auth token"` makes
"fix the failing test for the auth token parser" a high-risk credential task;
omitting `"api token"` makes "store the openrouter api token in the vault"
route as cheap chat. Each patch has moved the false positive somewhere else.

**Options.** (a) Keep extending literal lists. (b) A small verb+object intent
lexicon. (c) Send classification to an LLM rater.

**Decision: (b), an intent lexicon, backed by evals.** Separate *handling a
credential* from *working on code that mentions credentials*:

- **Credential objects**: `api key`, `api token`, `auth token`, `secret`,
  `password`, `private key`, `credential`.
- **Handling verbs**: `store`, `rotate`, `move`, `paste`, `commit`, `upload`,
  `share`, `print`, `echo`, `revoke`, `leak`.
- **Engineering-context markers** that pull the same nouns back down:
  `parser`, `test`, `type`, `struct`, `field`, `schema`, `docs`, `fixture`,
  `mock`, `variable name`.

Risk is high when a handling verb governs a credential object **as an adjacent
phrase** and no engineering-context marker applies. Mere co-occurrence anywhere
in the description SHALL NOT be enough (captain, 2026-09-05): "rotate the API
token" matches, while "fix the token parser so the rotate button stops
throwing" does not. This is still deterministic and readable, and it fails in an
explainable direction.

**Process rule that matters more than the lexicon.** Every misroute becomes a
case in `FirstmatePort.Router.Evals` **before** the lexicon is edited. The eval
set is the regression gate; the lexicon is an implementation detail behind it.
That is what stops the next round of regex whack-a-mole.

**Rejected (c)** for the default path: an LLM rater costs tokens on every route
and makes routing non-deterministic and untestable offline. It remains available
as an *override* source — see Decision 3.

### Decision 3 — Who rates difficulty: heuristic default, rater agent as override

**Decision.** The deterministic rater is the default and always runs. A separate
rater agent MAY supply axes and difficulty through the existing per-request
override path (`Router.classify/2`'s `overrides`, exposed as `axes` on
`POST /api/route`). The portal keeps final authority: overrides adjust the
inputs, never the lane rules, never the hard route.

**Why.** This is the captain's "maybe another agent ranks task difficulty"
without making every route depend on a model call. Offline, keyless, and
deterministic remains the default; tests keep running with no network.

**Consequence.** Overrides SHALL be recorded on the assignment so a route's
provenance shows whether a human, an agent, or the heuristic set each axis.

### Decision 4 — Enforcement: advisory first, blocking opt-in per account

**Decision.** The scheduler's default outcome under quota pressure is
`:downgrade` (cheaper effort or cheaper in-lane model) plus a warning.
`:defer` — refusing to admit — happens only when an account sets
`enforce: true`, or when the account is genuinely exhausted with no alternate
account for that harness.

**Why.** A scheduler that starts refusing work on day one, off projections that
have not yet been calibrated against actuals, will be turned off. Advisory
output earns trust first; the calibration table needs real `UsageEvent`s before
its projections deserve veto power.

**Never.** Quota pressure SHALL NOT re-route a code review off Codex
`gpt-6-astra`. Downgrade may lower effort; defer may delay it. Neither may
change the harness or model for kind `review`.

### Decision 5 — `fm-steer` stays a thin client

**Decision.** No ranking engine, capability matrix, quota math, or provider key
in Go. `cmd/fm-steer/main.go` gains subcommands that call the API and print what
it returns. Device-code auth already covers them.

**Why.** Captain's constraint, and a practical one: the ranking inputs and the
ledger change weekly, and a portable binary in the crew's hands cannot be
redeployed on that cadence. One Elixir deployment moves the whole fleet.

### Decision 6 — Ranking never trusts one source

**Decision.** Each source contributes per-axis normalized scores with a weight
cap. No source may exceed 40% of the combined weight for any axis; the fleet's
own eval set is not capped and outvotes all of them. Sources older than their
TTL are excluded from the combination and named in the response as excluded.
Popularity and usage-share metrics are metadata only and SHALL NOT contribute
to a capability score.

**Source roles.**

| Source | Contributes | Caveat encoded in the weights |
|---|---|---|
| Artificial Analysis | quality, price, latency, context, rate limits | Paid API; closest to a gatekeeper; still capped |
| LMArena / LMSYS | human preference | Scraping/API limited; advisory, lowest weight |
| LiveBench | contamination-resistant general quality | Refresh cadence matters; TTL enforced |
| HF Open LLM Leaderboard | open-model general quality | Narrow coverage of hosted frontier models |
| SWE-bench | kind `code` | Task-specific; only weighted for its axis |
| BrowseComp / GAIA | kind `research`, agentic | Task-specific; only weighted for its axis |
| Fleet evals | every axis | Ours; uncapped; the regression gate |

**Why.** This is the captain's Discord input taken literally: treat each as an
*input*, keep our own eval set, and never let one public rank decide. The
combination must stay correct when only a subset of these sources is present.

### Decision 7 — Cost downgrades stay in lane; exhausted funding re-assigns

**Options.** (a) Never move a task off its chosen harness. (b) Let cost pressure
pick a cheaper harness. (c) Keep cost pressure in lane, and move a task only
when its harness can no longer be funded.

**Decision: (c).** Two different triggers, two different outcomes. Cost pressure
yields `downgrade`, which lowers effort or picks a cheaper model *inside* the
admitted lane and never changes who does the work. Exhausted funding yields
`reassign`, which moves the task to the next lane that satisfies every
constraint and still has headroom.

**Why.** GitHub issue 2 asks the router to re-assign work off agents hitting
usage limits, so (a) is not enough. But letting ordinary cost pressure change
the harness (b) would silently swap the worker on routine work and make routing
unpredictable — the crew would stop trusting the assignment. Exhaustion is a
categorically different event: the lane genuinely cannot run the task.

**Never.** A hard-routed kind is not re-assignable. When a code review cannot be
funded it defers on Codex `gpt-6-astra`; it never moves to another harness.

## Risks / Trade-offs

- **Projections start wrong.** The calibration table is seeded with conservative
  defaults and will misprice unusual tasks. → Advisory by default (Decision 4);
  confidence band published with every projection; calibration learns from
  actuals.
- **Attributed spend is mistaken for billed spend.** → Explicitly labelled
  `attributed` in API and UI (Decision 1); provider-synced account totals stay
  the only `provider_reported` figure.
- **Reservations leak** if a worker dies without reporting. → TTL expiry
  releases them, and expiry is recorded so a leaking harness is visible.
- **Ranking sources disagree or go dark.** → Weight caps, TTL exclusion, and a
  documented fallback: with no fresh source, routing runs on matrix + evals
  exactly as it does today.
- **Fair share starves a small tenant** under a noisy neighbour. → Virtual-time
  fairness with a floor: every tenant keeps a reserved minimum share of a
  shared allowance regardless of weight.
- **More surface to keep green.** → Every requirement here is testable offline
  with no network and no keys; that is a hard constraint on the implementation.

## Migration Plan

1. Additive schema only: `usage_events`, `model_scores`, `usage_reservations`.
   No change to `usage_accounts` or `usage_snapshots` columns.
2. Ship the rater and projection as *reported fields* on the existing route
   response. Nothing changes about which lane is chosen. Verify projections
   against actuals with the ledger before step 3.
3. Enable admission in advisory mode (`:downgrade` allowed, `:defer` only for
   exhausted accounts).
4. Enable `enforce: true` per account once calibration is trusted.

Rollback: each step is a config flag; disabling admission returns the router to
its present stateless behaviour, and the ledger keeps recording.

## Open Questions

- What TTL does each ranking source deserve? LiveBench and Artificial Analysis
  refresh on different cadences; the first implementation SHALL make TTL a
  per-source config value rather than guessing one global number.
- Does the crew want per-task cost shown in `fm-steer route` output by default,
  or only under a flag? Recommended: shown, since the projection is the point.
