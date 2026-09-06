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
they cannot sign in.

## Progress

The Progress tab is filled by the GitHub poll, which reads its PAT and
organisation from the tenant's credential slots (see `docs/credentials.md`).

## Append-only progress events (contract, not yet built)

This is the agreed shape for the next slice. It is written down here so the
worker that owns fleet-log ingest builds to it; nothing in this repository
implements it yet.

- The fleet log is a log. An agent that "edits" progress - status, assignee,
  extra workers, an interruption - **POSTs a new event**. It never `UPDATE`s a
  historical row.
- What the UI shows is a **projection** over those events, rebuilt from them
  rather than stored as the truth. The progress-page worker owns that
  projection.
- Merkle trees, hash chains, and provenance proofs are explicitly out of scope.
  Tabled; do not build them.

The inbox is a queue, not part of this log, and is not affected: `claim` and
`ack` move a message's delivery status, while the message itself - who sent it,
when, and what it said - is written once and never rewritten. See
`docs/inbox.md`.
