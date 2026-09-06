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

Progress records crew work. Agents open a subject row with a required worker,
then append status, assignment, contribution, interruption, or note events at
`POST /api/progress/events` (MCP `post_progress_event`). Historical events are
never updated or deleted; the portal displays their projection.

The GitHub poll populates the PR and issue boards and enriches progress rows
that the crew already recorded. It reads each tenant's PAT and organisation
from credential slots. See [GitHub credentials](credentials.md#github) and
[the progress contract](progress.md) for event fields, ordering, and polling
behavior.

Merkle trees, hash chains, and provenance proofs remain out of scope.

The inbox is a queue, not part of this log, and is not affected: `claim` and
`ack` move a message's delivery status, while the message itself - who sent it,
when, and what it said - is written once and never rewritten. See
`docs/inbox.md`.
