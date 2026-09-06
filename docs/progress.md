# Progress: the fleet log and its event log

**Progress is crew work.** The PRs, issues, and tasks this fleet actually
worked, reviewed, or closed — with the worker, the runtime, the model, the
effort, the tokens, the interruptions, and where it got to. It is not a mirror
of a GitHub organisation, and an org's pull-request listing must never fill it.
GitHub is a link and a merge/open enricher for rows that already exist.

The fleet log is append-only. A progress item is identity — a PR, an issue, an
achievement, a note. Everything that *happened* to it is a row in
`progress_events`, and nothing ever rewrites one of those rows.

Reaching complete, being merged, going back in progress, a reassignment, an
extra contributor, an interruption: each is a new event. The table on `/` and
`/progress`, the details view, and the charts are all projections of that log.

- `FirstmatePort.Portal.ProgressItem` — the subject row (`kind`, `title`, `url`).
- `FirstmatePort.Portal.ProgressEvent` — the append-only log. Read and append
  only; the resource defines no update or destroy action, and
  `test/firstmate_port/portal/progress_event_test.exs` holds that line.
- `FirstmatePort.Portal.ProgressProjection` — the read model. Newest event wins
  for status and assignee; the full ordered list survives for the details view.
- `FirstmatePort.Portal.ProgressStatus` — the status vocabulary and the GitHub
  mapping.
- `FirstmatePort.Portal.ProgressLog` — the write side. Everything appends.

These events do not replace firstmate's on-disk inbox and status files. They are
what the portal shows; the files are still how firstmate steers.

## Status

A closed vocabulary, in lifecycle order:

| status | means |
|---|---|
| `draft` | opened, not yet offered for review |
| `in_progress` | being worked |
| `ready_for_review` | waiting on a reviewer |
| `ready_for_merge` | reviewed, waiting to land |
| `stalled` | nobody is moving it |
| `merged` | a pull request that landed |
| `complete` | closed, finished, or a thing that already happened |

`merged` and `complete` are terminal: the latest status event sets completion
time only while the current status is terminal. Returning to an active status
clears the projected completion time without changing history.

An item whose log carries no `:status` event falls back to its kind — `pr` and
`issue` read as `in_progress`, `achievement` and `note` as `complete` — and the
UI marks that with a `*` and says it is derived rather than reported.

## What the poll fills, and what it does not

`FirstmatePort.Jobs.GitHubPoll` mirrors an org's open PRs and issues onto the
**GithubItem board** — the `/prs` and `/issues` pages, which are meant to be
that mirror. Against Progress it only ever *enriches*:

- it cannot create a `ProgressItem`, because `:record` requires a worker and an
  org listing has none to name;
- it refreshes the title of a row the crew already logged;
- it appends a status event when a PR merges or an issue closes.

It maps only the three states GitHub can actually observe, and never reads the
author:

| GitHub | status |
|---|---|
| pull request with `merged_at` set | `merged` |
| open pull request or issue | `in_progress` |
| closed issue | `complete` |
| closed, unmerged pull request | `complete` |

A new observed `merged` or `complete` is eligible to append; projections still
order events by their occurrence time. An observed `in_progress` is
**dropped** whenever the crew has already said something more specific — draft,
ready for review, ready for merge, stalled all look "open" to the search API,
and the poll must not drag a crew judgement backwards. See
`ProgressStatus.github_may_report?/2`.

It never invents an assignee, a runtime, a model, an effort, a duration, or a
token count. A PR author is not evidence that anyone was assigned, and it is
certainly not evidence of which model ran.

The poll skips a status already explicitly projected and a transition already
recorded at the same observed timestamp. Merge and close events retain GitHub’s
observed timestamps, so repeated polls cannot replay an old transition after
newer crew work.
Open observations use GitHub's `updated_at` and are skipped when it is missing
or invalid, so a delayed open response cannot outrank a later merge or close.
See the observation-ordering regressions in
`test/firstmate_port/github_poll_test.exs`.

## Ingest contract

This is what firstmate and fm-steer post. Agent bearer token,
`Content-Type: application/json`.

### Open a row — `POST /api/progress`

```json
{
  "kind": "pr",
  "title": "Paginate the fleet log and add a progress page",
  "url": "https://github.com/carverauto/firstmate-port/pull/9001",
  "worker": "fm-port-progress-page",
  "assigned_at": "2026-09-05T16:03:00Z"
}
```

`worker` is **required**, and a request without one is refused with `400`. That
is the whole guard: a row that cannot name whose work it is does not belong in
Progress, and a GitHub mirror has no worker to name. The worker is not stored on
the row — it opens the row's log with an `:assignment` event. `assigned_at`
places that event in time and defaults to now; set it when backfilling work that
happened before it was logged.

| field | type | notes |
|---|---|---|
| `kind` | `pr` \| `issue` \| `achievement` \| `note` | required |
| `title` | string | required |
| `url` | string | required https URL for `pr` and `issue` |
| `worker` | string | **required** — the crew member doing the work |
| `assigned_at` | ISO 8601 | when they picked it up; defaults to now |
| `body` | string | optional |

### Append an event — `POST /api/progress/events`

Name the item with **either** `item_id` (the portal id) or `url` (the GitHub URL
the producer already holds). The endpoint never creates the item, so a typo
cannot fork a second fleet-log row — it returns `404` instead.

```json
{
  "item_id": "abc123xyz0",
  "type": "contribution",
  "worker": "fm-port-progress-page",
  "role": "implement",
  "runtime": "claude-code",
  "model": "claude-opus-5",
  "effort": "xhigh",
  "duration_ms": 5400000,
  "tokens": 412000,
  "interrupted": false,
  "detail": "first pass",
  "occurred_at": "2026-09-06T01:00:00Z"
}
```

| field | type | notes |
|---|---|---|
| `item_id` / `url` | string | one of the two is required |
| `type` | `status`, `assignment`, `contribution`, `interruption`, `note` | required |
| `status` | one of the seven above | required on `status`; canonical underscore spellings only |
| `worker` | string | required on `assignment` and `contribution` |
| `role` | `implement` \| `review` | on `contribution`; review work shows as review |
| `runtime` | string | the agent runtime or tool, e.g. `claude-code` |
| `model` | string | e.g. `claude-opus-5` |
| `effort` | string | e.g. `xhigh` |
| `duration_ms` | integer ≥ 0 | summed across events for the item's duration |
| `tokens` | integer ≥ 0 | summed across events |
| `interrupted` | boolean | required on `interruption`; absent means *unknown*, not *no* |
| `detail` | string | required on `note` |
| `occurred_at` | ISO 8601 | defaults to now |

Every field the producer omits stays missing rather than becoming a zero. The UI
distinguishes "nobody reported this" from "this measured zero" everywhere.

Reads:

- `GET /api/progress?limit=&offset=` — newest first, `limit` defaults to 50 and
  is capped at `ProgressItem.max_page_size/0`. Each row carries its projection
  (`status`, `assignee`, `workers`, `duration_ms`, `tokens`, `interrupted`).
  Response is `{"data": [...], "meta": {"total", "limit", "offset"}}`.
- `GET /api/progress/:id?limit=&offset=` — one item plus an event-log page, oldest
  first. Limit defaults to 100 and is capped at 100. `event_count` is the full
  count; `meta` contains `total`, `limit`, `offset`, and `next_offset` (null at
  the end). Follow `next_offset` to retrieve the complete log.

MCP exposes event append and paginated reads as `post_progress_event` and
`list_progress_events`; both use `item_id`, not URL lookup. Item creation and
paged identity reads are `post_progress` and `list_progress`.

## The portal surfaces

- `/` — the newest `ProgressItem.preview_size/0` rows only, fetched with a
  server-side limit. Below them, an always-visible "see all" link. The full
  list is never rendered and hidden.
- `/progress` — charts over the tenant, then the archive a page at a time
  (prev/next, page numbers, `?page=`).
- Details view — the same component on both pages, opened by clicking anywhere
  in a row, by the row's Details control (the keyboard path — a `<tr>` cannot
  take focus), or by `?item=<id>` so a URL opens the row directly. Esc, an
  overlay click, and the close button all patch back to the page it opened over.

  It carries the status timeline (how long the row held each status), tokens by
  contributor, and heuristics derived from the log — elapsed vs reported time,
  how long it has been quiet, who reviewed, how many hands touched it, whether
  it was interrupted. Everything there is derived from timestamps and counts
  already in the log; nothing is guessed.

Charts aggregate over the newest `ProgressItem.stats_cap/0` items and say so
when there are more, so a chart is never an unbounded table scan.

`fm-steer progress post --item-id <id> --type status --status merged` appends
an event using `FIRSTMATE_AGENT_TOKEN`. Use `--url` instead of `--item-id` when
holding the GitHub link. Assignment and contribution events accept `--worker`,
`--runtime`, `--model`, `--effort`, and `--role`; telemetry uses `--tokens`,
`--duration-ms`, and `--interrupted=true|false`. Omitted telemetry stays missing.
`--occurred-at` supplies an ISO 8601 backfill timestamp; `--detail` adds notes.

Recording crew work at an existing hidden imported URL claims that identity by
appending its first assignment. The old row and its history are preserved.

Event reads are bounded to 100 rows. HTTP uses `limit` and `offset` with
continuation metadata; MCP `list_progress_events` accepts the same arguments
and callers continue until a page contains fewer than `limit` events. Both
modals have Previous/Next events controls. Assignment and contribution history,
the timeline, and contributor bars describe the selected event page; summary
status, assignee, duration, tokens, and interruption cover the whole log through
database aggregation. Worker-name previews are capped at 100, with
`worker_count` and `workers_truncated` describing the complete set in HTTP.
