## 1. Ledger: record what was actually spent

- [ ] 1.0 Remove `lib/firstmate_port/usage/sync.ex` and its tests, and drop the provider-sync surface (`POST /api/usage/sync`, the `--sync` CLI path, the `:openrouter` source enum). The ledger is posted usage only (captain, 2026-09-05). Do this once the no-mistakes run returns the branch.
- [ ] 1.1 Add `FirstmatePort.Portal.UsageEvent` (tenant, usage account, task ref, harness, model, effort, tokens, cost, unit, reservation ref, occurred at). Additive and immutable; corrections are compensating events.
- [ ] 1.2 Add `FirstmatePort.Portal.UsageReservation` (tenant, usage account, projected tokens and cost, task ref, expires at, released at, release reason).
- [ ] 1.3 Migrations for `usage_events` and `usage_reservations`. No column changes to `usage_accounts` or `usage_snapshots`.
- [ ] 1.4 Extend `FirstmatePort.Usage` with `headroom/2` (remaining minus live reservations) and a tenant rollup that labels figures `attributed` vs `provider_reported`.
- [ ] 1.5 `POST /api/usage/events` for workers to report actuals; reconcile account `used` and release the matching reservation.
- [ ] 1.6 Reservation expiry sweep (AshOban) that releases expired holds and records the expiry.
- [ ] 1.7 Tests: rollup labelling, headroom under concurrent reservations, cross-tenant event rejection, compensating events, expiry restores headroom.

## 2. Rater: difficulty and projected usage

- [ ] 2.1 Extract classification from `lib/firstmate_port/router.ex` into `FirstmatePort.Lighthouse.Rater`, preserving current axis behaviour.
- [ ] 2.2 Add `difficulty` (0.0–1.0) derived from axes, returned with the reasons that set it.
- [ ] 2.3 Replace the credential substring lists with the Decision 2 intent lexicon: a handling verb must govern a credential object as an **adjacent phrase** (not mere co-occurrence), and engineering-context markers pull it back down.
- [ ] 2.4 Add eval cases for the three vault/store misroutes and for the auth-token-parser bugfix **before** 2.3 lands.
- [ ] 2.5 Add `FirstmatePort.Lighthouse.Calibration`: seeded conservative defaults per (kind, effort) bucket, updated from `UsageEvent` medians, outlier-resistant.
- [ ] 2.6 Add `projected_usage` (expected tokens, expected cost, confidence) to the route response, labelled an estimate.
- [ ] 2.7 Record axis provenance (`heuristic` / `agent` / `human`) and reject invalid overrides.
- [ ] 2.8 Tests: difficulty monotonicity, credential lexicon cases, projection confidence when uncalibrated, override validation, override cannot bypass the hard route.

## 3. Rank: multi-source model scores

- [ ] 3.1 Define a `FirstmatePort.Lighthouse.Rank.Source` behaviour (fetch, normalize per axis, declare TTL and weight cap).
- [ ] 3.2 Refit `lib/firstmate_port/router/provider_intel.ex` as the Artificial Analysis adapter behind that behaviour; drop popularity from any capability contribution, and remove its OpenRouter path (captain, 2026-09-05).
- [ ] 3.3 Add adapters for LMArena, LiveBench, HF Open LLM Leaderboard, and task-specific benchmarks (SWE-bench for `code`; BrowseComp/GAIA for `research`), each opt-in and keyless-tolerant.
- [ ] 3.4 Add `FirstmatePort.Portal.ModelScore` (model, axis, score, source, observed at, tenant-independent) plus migration.
- [ ] 3.5 Background refresh job (AshOban) writing `ModelScore`; failures recorded, previous scores retained.
- [ ] 3.6 Combine scores with per-source weight caps and per-source TTL exclusion; report sources used and sources excluded.
- [ ] 3.7 Route reads stored scores only — no live fetch on the request path.
- [ ] 3.8 Tests: cap enforcement, TTL exclusion, single-source degradation, zero-source fallback to matrix + evals, popularity excluded, offline route.

## 4. Scheduler: admission, fairness, assignment

- [ ] 4.1 Add `FirstmatePort.Lighthouse.Scheduler` returning `{:admit | :downgrade | :defer, assignment, reasons}`.
- [ ] 4.2 Funding-account selection by ascending `spend_priority`, skipping exhausted accounts; name the account in the assignment.
- [ ] 4.3 Admission compares projection against headroom; advisory default per Decision 4, `defer` only when enforcing or exhausted with no alternate.
- [ ] 4.4 Downgrade lowers effort or in-lane model only; never changes harness.
- [ ] 4.4a Re-assignment (`reassign`): when every funding account for the chosen harness is exhausted, move the task to the next constraint-satisfying lane with headroom; record the harness moved off and why; defer when no funded lane remains (issue 2).
- [ ] 4.5 Hard route for kind `review` is unconditional on harness and model; only effort or defer may vary.
- [ ] 4.6 Tenant fair share: virtual-time ordering by cumulative admitted spend over configured weight, with a configured minimum share floor.
- [ ] 4.7 Reserve on admit; wire release to `POST /api/usage/events`.
- [ ] 4.8 Tests: admission decisions across headroom cases, enforcing vs advisory, downgrade stays in lane, re-assignment off an exhausted harness, defer when no funded lane remains, code review defers rather than re-assigns, review hard route under pressure and under overrides, fairness under a flooding tenant, minimum share floor, cross-tenant isolation.

## 5. API and LiveView

- [ ] 5.1 Extend `POST /api/route` response with difficulty, projected usage, funding account, admission decision, axis provenance, and ranking sources used/excluded.
- [ ] 5.2 Reject non-text and missing descriptions with a client error, never a server error.
- [ ] 5.3 Extend `GET /api/usage` with headroom, live reservations, and the `attributed` / `provider_reported` labels.
- [ ] 5.4 `lib/firstmate_port_web/live/usage_live.ex`: show projection vs actual, headroom, fair-share standing, and ranking provenance; estimates visually distinct from actuals.
- [ ] 5.5 Tests: controller contracts, tenancy on every new endpoint, no token value in any response.

## 6. fm-steer (thin client only)

- [ ] 6.1 Surface difficulty, projection, funding account, and admission decision in `fm-steer route` output.
- [ ] 6.2 Surface headroom and reservations in `fm-steer usage` output.
- [ ] 6.3 Non-zero exit and a clear message when the portal is unreachable; no local fallback assignment.
- [ ] 6.4 Assert in tests that no ranking, matrix, quota math, or provider key exists in the Go tree.

## 7. Docs

- [ ] 7.1 `docs/routing.md`: difficulty, projection, admission, hard route, ranking provenance.
- [ ] 7.2 `docs/usage.md`: ledger model, attributed vs provider-reported, reservations, runway.
- [ ] 7.3 New `docs/lighthouse.md`: the closed loop and the six decisions with their revisit conditions.
- [ ] 7.4 Marketing page and user docs stay rendered HTML, not raw markdown in a preformatted block.
- [ ] 7.5 Archify the Lighthouse loop (rate → rank → admit → reserve → record → calibrate) as an architecture diagram.

## 8. Registry rename (captain, 2026-09-05)

Completed on `main` before this change merged: ghcr.io is the image registry
(`ghcr.io/<owner>/firstmate-port`), CI authenticates with the workflow
`GITHUB_TOKEN`, and no registry robot secrets remain. No work outstanding here.
