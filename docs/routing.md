# Routing

`POST /api/route` answers one question: given a task description, which
worker harness, model, and effort should run it, and why. `fm-steer route`
is the CLI surface; the decision lives in `FirstmatePort.Router` and never
in the CLI or in JetStream.

## Axes

Every task is classified on six axes:

| Axis | Values | Example signals |
|---|---|---|
| kind | code, research, ops, docs, review, data, chat | verbs outrank nouns |
| ambiguity | low, medium, high | "figure out", "unknown", long briefs |
| blast_radius | low, medium, high | production, deploy, delete, customer |
| citations_required | boolean | "cite", "audit report", compliance |
| risk | low, medium, high | "rotate the token", payments, customer data |
| live_web_required | boolean | "latest", "news", "this week" |

Classification is a deterministic keyword heuristic (v1, in
`FirstmatePort.Router`). Any axis can be overridden per request: that is the
rater-agent path, where a separate agent ranks difficulty and the router
still owns the final pick.

```sh
curl -X POST $PORTAL/api/route -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"description": "deploy the portal to production",
       "axes": {"blast_radius": "high"}}'
```

## Capability matrix

`FirstmatePort.Router.Matrix` lists the lanes the fleet can actually drive
(claude, codex, grok, opencode) with coarse quality, cost, and latency
tiers. Routing filters lanes on hard constraints (live web, citations, kind,
axis ceilings), then picks the cheapest survivor, breaking ties on latency
and quality. Effort (`low`, `medium`, `high`) starts at the lane default and
rises with ambiguity, blast radius, and risk. High blast radius or risk adds
a `human-review` checkpoint to the response.

## Hard routes

Code review (`kind: review`) bypasses the matrix: it always returns
`harness: codex`, `model: gpt-6-astra` (displayed as GPT-6-Astra), with
`model_source: fleet_hard_route`. Review never goes to Muse or Grok, even
with provider intel enabled. Other kinds still use the matrix.

## Provider intel

OpenRouter (model metadata, pricing, context) and Artificial Analysis
(quality, latency) are *inputs*, used only to refine the model pick inside
the chosen lane. They are consulted only when the request sets
`"intel": true`, and need no API key to read (`OPENROUTER_API_KEY` raises
rate limits; `AA_API_KEY` enables Artificial Analysis, a paid API). No
single public leaderboard ever decides: the matrix is the base vote, the
bundled eval set is the regression gate, and popularity is never treated as
capability.

Without intel the response uses `model: "harness-default"`, meaning the
worker harness resolves its own default model. With intel the router names
the cheapest matching OpenRouter model id and says so in `model_source`.

## Response

```json
{
  "tenant": "local",
  "harness": "codex",
  "model": "harness-default",
  "model_source": "harness_default",
  "effort": "medium",
  "reasons": ["codex wins on expected quality x cost x latency among codex, claude"],
  "axes": {"kind": "code", "ambiguity": "low", "blast_radius": "low",
            "citations_required": false, "risk": "low", "live_web_required": false},
  "intel_sources": ["fleet_matrix", "fleet_evals"],
  "checkpoint": null
}
```

## Eval set

`FirstmatePort.Router.Evals` pins known tasks to lanes. `mix test`
fails on any mismatch (`Router.check_evals/0`). When the fleet misroutes a
real task, add the scrubbed description with the lane it should have taken,
then fix the classifier or matrix until the set is green.

## Architecture

`docs/architecture/router-usage.html` is the Archify diagram for this
system: router, usage ledger, fm-steer, trust boundaries, and the JetStream
rule (spec: `docs/architecture/router-usage.architecture.json`).
