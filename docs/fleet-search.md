# Fleet search

[`diagrams/fleet-search.html`](diagrams/fleet-search.html) draws this: the
projection, the two ranking passes, and what an optional embedding provider
sees. Its source is
[`diagrams/fleet-search.architecture.json`](diagrams/fleet-search.architecture.json).

The fleet log is already in Postgres. Fleet search projects it into one
searchable table in the same database and puts a box over it.

Nothing here is a second store. `fleet_documents` lives in the same CNPG
cluster, under the same attribute tenancy, as every other portal row.

## What is indexed

`FirstmatePort.Fleet.Sync` projects one document per record, from five sources:

| Source | Row | What is indexed |
| --- | --- | --- |
| `github_item` | Open PR or issue | kind, title, URL, state, check status, BuildBuddy URL, assignment |
| `progress_item` | PR, issue, achievement, note | kind, title, URL, body |
| `roll` | farm/demo image build or helm roll | cluster, namespace, status, image tag, rebuilt, copied, helm revision, PR and issue URLs, outcome |
| `no_mistakes_run` | Pipeline run | run id, branch, step, findings, intent, outcome, public summary, PR URL, response |
| `diagram` | Uploaded Archify diagram | title and notes |

Each document keeps the record as JSON in `document`, and the flattened
`key: value` text of that JSON in `search_text`. The JSON is what a result
quotes; the text is what both indexes are built over.

Left out on purpose:

- **Diagram HTML, PNG and SVG.** Blobs. The title and notes are the searchable
  part, and a sync never loads the payload.
- **no-mistakes logs.** High volume, low search value, and the largest thing
  that would be sent to a provider if embeddings are on. Findings, intent and
  outcome are indexed; the log body is not.
- Values are capped at 2,000 characters each, and a document's text at 8,000.

## Searching

- Portal: `/search`.
- API: `GET /api/fleet/search?q=...&limit=...` with any actor that can sign in
  or hold an agent key.
- MCP: the `search_fleet` tool.

`q` goes to Postgres' `websearch_to_tsquery`, so `"quoted phrases"` and
`-excluded` words behave the way a search box should.

## Ranking

Two passes, fused.

**Lexical** is Postgres full-text search over
`to_tsvector('english', search_text)`, with a GIN expression index, ranked by
`ts_rank_cd`. It is always on, needs no key, and needs no extension that is not
already in the database.

`ts_rank_cd` is cover-density ranking, not Okapi BM25. A `bm25` ranking would
mean a ParadeDB-style extension, which is a new database engine in the cluster;
the fleet log is not big enough to justify one, and the portal deliberately runs
on stock Postgres 16 in Compose and the CloudNativePG image in Kubernetes alike.
If that changes, the swap is one index and one `ORDER BY`.

**Semantic** is optional; see below.

The two are combined with reciprocal rank fusion: a result scores
`1 / (60 + rank)` in each list it appears in, and the scores add. Fusion compares
positions rather than scores, so a `ts_rank_cd` value never has to be made
commensurable with a cosine similarity - they are not. With the semantic pass
off, fusion over one list is that list's own order, so there is a single code
path either way.

The portal names which passes answered. A search that has quietly lost its
semantic half - expired key, provider outage - otherwise looks exactly like a
search with poor recall.

## Embeddings (optional)

Off in a fresh checkout. Nothing leaves the cluster until an operator turns it
on, and turning it on takes two deliberate steps.

**1. Choose a model.** Set it per tenant in the portal at
`/settings/credentials`. Clearing the model disables embeddings.

The spec is `provider:model`. The portal lists these by name:

| Spec | Dimensions |
| --- | --- |
| `openai:text-embedding-3-small` | 1536 |
| `openai:text-embedding-3-large` | 3072 |
| `google:gemini-embedding-001` | 3072 |
| `mistral:mistral-embed` | 1024 |

That list is a convenience, not a gate. Any embedding model `ReqLLM` supports
can be typed in.

The portal checks the shape and that the provider is one this build can reach;
it does not check that the exact model exists. Loading the provider library's
model catalogue costs seconds on its first call, which is the wrong thing to do
on a form submit, and that catalogue lags real providers. Guessing from the name
is no better - `text-embedding-3-small` and `mistral-embed` are named for the
job, `baai/bge-m3` and `voyage-3` are not. A model that turns out not to be an
embedding model surfaces as the provider's own error on the next backfill, and
`/search` reports it rather than hiding it.

**2. Save the key.** In the portal's credential store, slot
`embeddings`/`api_key`. It is encrypted at rest with the rest of the tenant's
secrets (see [credentials.md](credentials.md)), read back only server-side, and
passed per request. It is never in git, never in a Kubernetes secret of its own,
and never written into application environment where another tenant's request
could pick it up.

Until both are set, `/search` says so and runs on text search alone.

### What an operator is agreeing to

Turning embeddings on sends the indexed text of the fleet log to the chosen
provider: PR and issue titles, progress notes, roll outcomes, and no-mistakes
findings and intents. That is the same text the search box matches on. Diagram
payloads and no-mistakes logs are never projected, so they are never sent.

If that is not acceptable for a fleet, leave embeddings off. Text search is the
whole default product and does not degrade without them.

## Keeping it in step

| Job | Schedule | What it does |
| --- | --- | --- |
| `fleet_sync` | every 10 minutes | Projects every tenant's log into `fleet_documents` |
| `fleet_embed` | every 5 minutes | Embeds one batch per tenant, for tenants that have it configured |

Both are AshOban scheduled actions on `FirstmatePort.Jobs.Tick`, in the `fleet`
queue. They are separate on purpose: the projection is local Postgres work that
must keep running when a provider is down, and the backfill is the half allowed
to fail.

A sync is idempotent. Documents whose `content_hash` still matches are skipped,
so a quiet tick writes nothing and leaves every vector valid. Documents whose
source record has gone are removed, so the index cannot answer with rows the log
no longer has.

Changing a document's text does not delete its vector; it marks it stale, and
the old vector keeps answering searches until the next backfill replaces it.

To sync now rather than on the tick:

```sh
curl -X POST -H "authorization: Bearer $FIRSTMATE_AGENT_TOKEN" \
  http://localhost:4000/api/fleet/sync
```

## Where the ceiling is

Vector search is a sequential scan with a per-row dot product. Vectors are
stored unit-normalised, so the dot product *is* cosine similarity and the query
is one `ORDER BY`. There is no approximate-nearest-neighbour index: `pgvector`
is not in the Compose image, and a fleet log is thousands of rows, not millions.

That is the tradeoff, stated plainly. At the point where a fleet log has enough
documents for the scan to be felt, the fix is `pgvector` plus an HNSW index on
the same column, and the rest of this design - the projection, the fusion, the
credential path - is unchanged.
