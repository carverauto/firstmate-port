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
- events are ordered by insertion time: `started_at` is the first non-null
  reported start time, `finished_at` the last non-null reported finish time
  (not the minimum and maximum timestamp values). Without a reported start
  time, the projection uses the first event's insertion time,
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
  "outcome": "pushed"
}
```

`status` is one of `started`, `success`, `failure`, `cancelled`.
Successful `POST` calls return `id`, `run_id`, `kind`, `status`, and `url`.
Both `GET` endpoints wrap their rows in `{"data": [...]}` and scope them to
the caller's tenant. Raw events include `id` and `recorded_at`;
`GET /api/build-runs` returns the payload fields folded, plus `id` (the last
event's id), `duration_ms`, `events`, `finished?`, `updated_at`, and `url`.
The run list is ordered by most recent activity and defaults to 10 rows;
positive `limit` values are capped at 200, while missing, nonpositive, or
unparseable values use the default. The raw event list is not capped.

`duration_ms` is the reported finish time minus the projected start time,
or `null` without a finish time. Direct API callers supply their own times;
the CLI's timestamp defaults and overrides are covered by the
[build-tracking skill](../skills/build-tracking/SKILL.md#what-to-report).
