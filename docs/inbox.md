# The inbox

One tenant-scoped queue that firstmate, the second mate, and the crew all pass
messages through, so the captain can watch the traffic on the portal instead of
reading someone's filesystem.

`fm-steer` is the client and it speaks HTTP only. The Phoenix API is the tenant
wall and the only JetStream client, so no CLI ever dials NATS. Firstmate keeps
its own on-disk inbox and status files; this store is separate and is reached
over the API.

## The shape

There is one inbox per tenant, not one per direction. `task` routes within it:

- `firstmate` is firstmate's own mailbox, and is what a bare `put` files under.
  The second mate reporting "this is done" needs no routing key.
- Any other task addresses that crew lane.

A message is `pending` until a reader claims it with `next`, `delivered` while
that reader works, and `acked` once they confirm it. Acked rows stay - the
history is the point. Claiming takes a row lock (`FOR UPDATE SKIP LOCKED`), so
two crewmates polling `next` at the same time are never handed the same order.

## From the CLI

```sh
fm-steer auth login                      # defaults to https://firstmate.carverauto.dev
fm-steer inbox put --body "PR is green"  # files under task 'firstmate'
fm-steer inbox next                      # oldest message for any task
fm-steer inbox ack --ack <ack-from-next>
fm-steer inbox list                      # what is still outstanding
```

Address a crew lane with `--task`:

```sh
fm-steer inbox put --task fm-port --body "rebase onto main"
fm-steer inbox next --task fm-port
```

`--instance http://localhost:4000` (or `FIRSTMATE_INSTANCE`) points the CLI at a
local portal. The instance is stored in `credentials.json`, so it is only needed
at login.

## From the portal

`/inbox` shows the traffic as it happens - a message filed from a script appears
without a reload - and the captain can send an order or ack one from the page.
It is the same queue: an order sent there is one the crew takes with
`fm-steer inbox next`. The page shows the newest 200 messages, including
acknowledged ones. Use `/inbox?task=<task>` to filter before that history limit.
The waiting count includes all pending and delivered messages in the tenant,
regardless of the selected task or history window.

## What the payload looks like

Each message returned by `put`, `next`, or the `list` response's `data` array
carries the `fm-task-inbox.v1` schema. An empty `next` returns HTTP 204;
`ack` returns `{"ok": true}`. A message looks like:

```json
{
  "schema": "fm-task-inbox.v1",
  "task": "firstmate",
  "seq": 7,
  "body": "PR is green",
  "delivery": "",
  "sender": "captain@localhost",
  "claimed_by": "",
  "status": "pending",
  "ack": "01a07455-71a0-7571-ae40-6f319cd3ecc5",
  "tenant": "local",
  "at": "2026-09-06T01:29:11.840467Z"
}
```

`ack` is the token `ack` takes. `seq` climbs per tenant and is what to use when
talking about a message.

## Why it is a table

Messages are rows in Postgres, so they survive a restart and more than one
portal node can serve `next` safely. The JetStream fan-out to
`<tenant>.steer.inbox` happens after the row is committed and off the request
path: creating a stream is a round trip with no deadline of its own, and a
JetStream that is slow or down must cost the fan-out, not the message.
