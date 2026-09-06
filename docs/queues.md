# Queues

`/queues` is a live look-in at the crew work in flight for the signed-in
tenant: which task went to which worker, its agent id, the model and effort it
runs at, cumulative token usage, and start/stop times.

It is not the store of record. The fleet log (`/`, `/prs`, `/issues`,
`/no-mistakes`) holds what happened; Queues shows what is happening. Entries
live in `FirstmatePort.Queues.Tracker` memory, never in Postgres, and a restart
starts the page empty.

## Flow

```
fm-steer queue post ──HTTP──▶ POST /api/queues ──▶ Queues.Tracker ──PubSub──▶ QueuesLive
                                     │                    ▲
                                     └── <tenant>.steer.queue ──▶ QueueListener
                                            (JetStream)         (other portal nodes)
```

`fm-steer` never dials NATS. It POSTs a queue fact to the portal; the portal
records it and publishes the normalized entry on `<tenant>.steer.queue`, which
the tenant's existing `<tenant>_steer` stream already owns — no new stream and
no `<tenant>.>` catch-all. `FirstmatePort.NATS.QueueListener` folds messages
from that subject back into the tracker, which is how a second portal node sees
work recorded on the first.

Publishing the normalized entry rather than the raw request is what makes that
round trip safe: the recording node merges its own message back onto an
identical entry and broadcasts nothing. Locally seeded status and start time
remain display defaults and are omitted from published reports, so sparse
reports cannot replace another node’s known status or start time. Reports older than the tracked
`updated_at` cannot replace status, assignment, descriptive fields, or timing.
Input and output token counters each retain their highest reported value, even
from an older report. Without `updated_at`, the portal uses receipt time.

## Reporting

```sh
export FIRSTMATE_AGENT_TOKEN=...   # writes require an agent role
fm-steer queue post --task fm-port-queue-track --worker crew-4 \
  --agent-id agent-7b1 --model claude-opus-5 --effort high --status working
fm-steer queue post --task fm-port-queue-track --tokens-in 41000 --tokens-out 9000
fm-steer queue post --task fm-port-queue-track --status done
fm-steer queue list                # signed-in read of the current look-in
```

Reports are sparse and merge onto what the portal already tracks, so a worker
can send the model up front and the token totals when it finishes. `--task` is
the only required flag. Statuses are `queued`, `working`, `needs-decision`,
`blocked`, `paused`, `done`, and `failed` — the same words firstmate status
lines use. A terminal report stamps the stop time; reporting `working` again
clears it and the elapsed clock resumes, provided the report is not older than
the tracked update. `--started-at` and `--stopped-at` accept RFC3339 times; the
start otherwise defaults to the first report.

`POST /api/queues` needs an agent credential (as with fleet log ingest);
`GET /api/queues` and the page itself need a signed-in account, and both are
scoped to the caller's tenant. Reports use canonical field names, with no
aliases; [Entry.new/2 and Entry.to_report/1](../lib/firstmate_port/queues/entry.ex)
define the accepted fields and normalized wire form. Invalid reports return
HTTP 422. Omitted or null optional values do not explicitly clear prior fields.
GET returns `{"data": [...]}`; POST returns the normalized entry.

If NATS is unavailable, a valid report still succeeds and updates this node's
look-in; publication is best effort and other nodes may not receive it.

## Retention

The tracker keeps finished work for 15 minutes and work that has gone quiet
without reporting a stop for 2 hours, capped at 200 entries per tenant. Removals
are broadcast, so an open page stops showing work that is no longer in flight.

## Broker regression test

With `nats-server` on PATH, run
`NATS_SERVER_TESTS=1 unbuffer mix test test/firstmate_port/queue_broker_test.exs`.
The test starts isolated brokers to check stream provisioning, persisted queue
payloads, and prompt reporting when JetStream is unavailable. Provisioning runs
in the existing listener; queue reports only publish and never wait for stream
management. Stream names use underscores because JetStream forbids dots in names;
subject names retain dots.
