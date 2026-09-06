# Fleet log

What the portal shows about work in flight: diagrams, progress (PRs, issues,
achievements), farm/demo rolls, and no-mistakes runs.

## Diagrams

Archify uploads interactive HTML through `POST /api/diagrams` or the
`upload_diagram` MCP tool. Either credential works: the crew's agent key, or the
captain's own `fm-steer` session - the tenant an upload lands in is the actor's
own either way. Uploads appear on the Fleet log's Diagrams tab and at `/d/:id`.

`/d/:id` is tenant data, so it needs a signed-in reader. A visitor who is not
signed in is sent to sign in and returned to the diagram, rather than told it
does not exist. Link-unfurling crawlers get the Open Graph card instead, since
they cannot sign in; this unauthenticated preview uses the default tenant.

Stored HTML is served unchanged with a Content-Security-Policy sandbox granting
`allow-scripts` but not `allow-same-origin`. Self-contained inline HTML/SVG/JS
remains interactive in an opaque origin, without access to the portal
origin's DOM or storage. Sandbox restrictions also block forms, popups, and
downloads; diagrams must not rely on those capabilities when viewed here.

## Progress

The Progress tab is filled by the GitHub poll, which reads its PAT and
organisation from the tenant's credential slots (see `docs/credentials.md`).

## Append-only progress events

`POST /api/progress` (or MCP `post_progress`) records the immutable initial
state in `progress_items`. Existing rows serve as initial events too.
`POST /api/progress/:id/events` (or MCP `post_progress_event`, with `item_id`)
appends a row to `progress_events`. It accepts `kind`, `title`, `status`,
`assignee`, `extra_workers`, and `interruption`. Omitted or null fields leave
state unchanged; empty strings clear status, assignee, or interruption, and an
empty list clears extra workers. Only tenant-scoped agents can record progress.

All progress reads, including the portal, API, MCP, and GitHub poll, project
initial state plus events in ascending database sequence (`seq`) order.
Event UUIDs identify records in the shared event log; the sequence orders patches.
The last supplied value for each field wins. Historical rows have no update or delete action. GitHub
polling appends title/kind changes and preserves crew-owned fields. See
[GitHub configuration and polling scope](credentials.md#github).

Merkle trees, hash chains, and provenance proofs remain out of scope.

The inbox is a queue, not part of this log, and is not affected: `claim` and
`ack` move a message's delivery status, while the message itself - who sent it,
when, and what it said - is written once and never rewritten. See
`docs/inbox.md`.
