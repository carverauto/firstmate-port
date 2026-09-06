# Build and deployment events

One append-only log covers every build and deploy system. `kind` names the
system (`docker`, `k8s`, `helm`, `bazel`, ...) so adding a system means
sending a new `kind`, never a new table or a new endpoint.

Crew record their own runs: `fm-steer build start` before the work and
`fm-steer build finish` after it. The
[`build-tracking` skill](../skills/build-tracking/SKILL.md) is what tells a
worker to do that; install it alongside the CLI.

## The row is a projection

Nothing updates an earlier row. A run is a set of events sharing a `run_id`,
and `FirstmatePort.BuildEvents.runs/1` folds them into the row a dashboard
shows:

- the newest event that reported a field wins; an event that omits a field
  leaves it alone,
- `started_at` is the earliest report, `finished_at` the latest,
- `tokens` is the newest non-zero report, so callers send cumulative usage for
  the run rather than a per-event delta,
- `status` is the newest event's status, and `finished?` is any status other
  than `started`.

`runs/1` takes `:limit` (the home page shows the last 10) plus the usual Ash
`:actor` and `:tenant`; `FirstmatePort.BuildEvents.run/2` folds one run id.

A finish call rarely repeats the run's context, so
`FirstmatePort.Changes.InheritBuildRun` copies the missing fields from the
run's previous event onto the new row as it is written. Every row stays
self-describing without anything being rewritten.

## API

| Method | Path | Who |
|---|---|---|
| `POST` | `/api/build-events` | agent role (`FIRSTMATE_AGENT_TOKEN`) |
| `GET` | `/api/build-events[?run_id=]` | any signed-in actor |
| `GET` | `/api/build-runs[?limit=]` | any signed-in actor - the folded rows |

`POST` body (only `run_id`, `kind`, `status`, and `agent_id` are required, and
`kind`/`agent_id` are inherited from the run's previous event when omitted):

```json
{
  "run_id": "run-3f9a1c7e5b2d4a08",
  "kind": "docker",
  "target": "firstmate-port",
  "status": "started",
  "agent_id": "crew-7",
  "model": "opus-5",
  "effort": "high",
  "tokens": 48210,
  "started_at": "2026-09-06T01:00:00Z",
  "finished_at": null,
  "image": "ghcr.io/OWNER/firstmate-port",
  "image_tag": "sha-deadbeef",
  "cluster": "prod",
  "namespace": "firstmate",
  "outcome": "pushed",
  "pr_url": "https://github.com/OWNER/REPO/pull/1"
}
```

`status` is one of `started`, `success`, `failure`, `cancelled`. `pr_url` must
be a full `https://` URL. `GET /api/build-runs` returns the same fields folded,
plus `duration_ms`, `events`, `finished?`, and `updated_at`.

The same writes are available over MCP as `post_build_event` and
`list_build_events`, for agents that speak MCP instead of shelling out.
