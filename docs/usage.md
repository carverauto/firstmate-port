# Usage and billing

`GET /api/usage`, the `/usage` portal page, and `fm-steer usage` read the
same ledger: per-account token and billing counters with remaining
allowance. Every row is tenant-scoped by the caller's credential.

## Accounts

One row per provider account: provider (`openrouter`, `anthropic`, ...),
label, unit (`usd`, `tokens`, `credits`), allowance per window (`monthly`,
`weekly`, `daily`, `one_time`), used amount, optional reset time, spend
priority, source (`manual` or `openrouter`), and notes.

```sh
curl -X POST $PORTAL/api/usage -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"provider": "openrouter", "label": "captain",
       "unit": "usd", "allowance": 100, "window": "monthly",
       "spend_priority": 10}'
```

Agents post readings with the `record_usage` MCP tool or `POST /api/usage`
(upsert on provider plus label). Only the fields present in the request are
written, so posting `{"provider", "label", "used"}` leaves a configured
allowance, window, spend priority, and source alone. Humans add accounts on
the `/usage` page.

## Remaining, status, runway

Remaining is allowance minus used. Status is `ok` below 75 percent, `low`
above it, `exhausted` at or past the cap, and `unknown` when no allowance
is set. Nothing is invented: unknown allowances stay `nil` through the API,
the CLI, and the UI.

Runway (days until the allowance runs out) comes from snapshot burn rate:
at least two `record_usage_snapshot` samples spanning a day with rising
usage. Without that history the API reports `runway_days: null` instead of
guessing.

## Spend priority

Lower numbers burn first. Sort shared work toward the account with the
lowest spend priority that still has headroom; the usage list already
arrives in spend order.

## Sync

`POST /api/usage/sync` (or `fm-steer usage --sync`, or the portal Sync
button) refreshes every syncable account and appends a snapshot per success.
Provider API tokens are read from the environment at runtime and never touch
git, chat, or the database:

| Variable | Effect |
|---|---|
| `OPENROUTER_API_KEY` | Syncs OpenRouter key usage (`limit` becomes allowance; a missing limit keeps any manual allowance) |
| `AA_API_KEY` | Routing intel only; Artificial Analysis sells benchmarks, not spend |

Providers without a live sync report `synced: false` with the reason and
keep their manual readings. Copy `.env.example` for the full list.
