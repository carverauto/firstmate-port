# firstmate-port

Companion portal for firstmate. Phoenix/Ash LiveView, NATS JetStream, Bazel, Docker Compose.

## Commands

- Local stack: `docker compose up --build` (see `docs/deploy.md`)
- Mix: `mix setup` then `mix phx.server` against compose Postgres
- Tests: `unbuffer mix test` when `unbuffer` is available. Preserve the ReqLLM catalogue preload in `test/test_helper.exs` before database-backed tests.
- Bazel: `./tools/bazel` (forces `--output_base=/tmp/fm-fm-port/bazel`). `--config=remote` is fine; never `--config=ci` locally. See `docs/bazel.md`
- Prefix every `npm` with `sfw`

## Boundaries

- `fm-steer` is the captain CLI. Device-code against this API. It must not import or dial NATS. New CLI surface is thin HTTP only: no ranking, quota math, or provider keys in Go. Captain-facing usage, including the standing prompt that makes stock firstmate mirror steers here without a fork, is `docs/fm-steer.md`.
- Go CLIs keep `cmd/` thin (dispatch + `os.Exit`) over `internal/` (see `internal/fmsteer`). `cmd/nats-tail`, `cmd/discord-inbound` and `cmd/discord-interactions` belong to the extract worker; do not extend them here.
- The portal owns task routing (`FirstmatePort.Router`, `POST /api/route`) and the usage ledger (`FirstmatePort.Portal.UsageAccount`, `/api/usage`, `/usage`). Code review hard-routes to Codex with GPT-6-Astra (`Matrix.hard_route/1`).
- When routing misfires, add the scrubbed task to `FirstmatePort.Router.Evals` first; `mix test` keeps the set green.
- The Lighthouse scheduler (usage ledger, task difficulty, model ranking, fair scheduling) is specified in `openspec/changes/add-lighthouse-scheduler/`. Read its proposal and design before extending the router or the ledger. OpenRouter is deferred (captain, 2026-09-05): the ledger is posted usage only.
- Attribute tenancy on shared Postgres and one NATS account. Streams are `<tenant>.steer` / `<tenant>.inbound`. Seed tenant `local` as an example. The API is the tenant wall and the only JetStream client.
- Tenant credentials belong in portal UI/API and AshCloak-encrypted CNPG rows, never per-tenant Kubernetes secrets or plaintext HTTP/MCP responses. See `docs/credentials.md` for storage, Discord routing, and vault-key operations.
- Fleet search is one projected table in the same CNPG database, not a second store: Postgres full-text search always, embeddings only when an operator sets a model and the tenant fills `embeddings`/`api_key`. Do not add a search engine, a vector extension, or a BM25 extension. See `docs/fleet-search.md`.
- Build/deploy tracking is one append-only log for every system: `kind` names it (`docker`, `k8s`, `bazel`, ...). Add a kind, never a resource or endpoint per system, and never UPDATE an earlier event - a UI row is a projection (`FirstmatePort.BuildEvents`). See `docs/build-events.md`.
- `skills/` holds installable agent skills that drive `fm-steer`. Keep them OSS-portable: no site hostnames, registries, or cluster names.
- Progress is crew work, not a GitHub mirror. `ProgressItem.record` requires a `worker`, so the org poll cannot catalogue Progress - it only enriches rows the crew already logged (title, and a merge/close status event). The `/prs` and `/issues` boards are the org mirror. See `docs/progress.md`.
- The fleet log is append-only. `ProgressItem` is identity; everything that happened to it is a `ProgressEvent` row, and the resource has no update or destroy action on purpose. Status, assignee, duration, tokens, and interrupted are projections (`ProgressProjection`), never stored on the item.
- Missing telemetry is not zero. A metric nobody reported renders as an em dash or "no telemetry yet"; only a real count renders as a number.
- Public-edge access and security posture are documented in `docs/security.md`; read it before adding a public route or changing a router pipeline.
- Do not add `notify.py`, `watch.py`, or the launchd plist. Those stay in firstmate-notify.
- Site hostnames, OIDC issuer URLs, registry namespaces, and email allowlists belong in env samples / compose overrides / `deploy/examples`. Defaults run on localhost.
- Auth is two modes on one image, both environment-driven: local sign-in (`LOCAL_AUTH`, older name `DEV_AUTH`) is a bootstrap admin account and needs no IdP; OIDC is optional. See `docs/deploy.md` "Sign-in".
- The bootstrap password is written once and never rewritten, so a restart cannot rotate it out from under an operator. It reaches them through compose logs or the `firstmate-admin` secret.
- No email-domain allowlist gates the product login. `ALLOWED_EMAIL_DOMAIN` is an opt-in extra restriction on OIDC only, unset by default.
- SaaS (sign-up, tenant provisioning, billing) lives in firstmate-saas, not here. `enable_saas` is a seam only; tenancy is already attribute-based.
- OIDC is generic, never a per-vendor adapter: endpoints come from the issuer's discovery document, and the provider process is `:firstmate_oidc`. Do not name it, or any module, secret, or default, after one vendor - `test/firstmate_port/auth/vendor_neutral_test.exs` enforces this.
- Never put an issuer in `config :ueberauth_oidcc, :issuers`. That library supervises each entry as a permanent child, so a provider that cannot load its configuration takes the node down. `FirstmatePort.Auth.OIDC.Supervisor` owns it as a temporary child instead.
- ghcr.io is the image registry (`ghcr.io/<owner>/firstmate-port`). CI logs in with the workflow `GITHUB_TOKEN`; there are no registry robot secrets. Do not invent a second forge.

## Gotchas

- Ash casts `""` to `nil` on string attributes, so an attribute whose default is `""` reads back as `nil` when unset. Guard with `is_binary(v) and v != ""`, not `v != ""`, or a `:if` renders an empty `<a>`.
- Tailwind v4 scans `lib/firstmate_port_web`, so a hand-rolled CSS class that collides with a utility name loses. `.grid` was one; the tables use `.data-table`.

## Stack

Phoenix 1.8, Ash, AshOban, AshEvents, AshPaperTrail, AshAi MCP at `/mcp`, Bandit, Ueberauth OIDC, Gnat/JetStream. UI is Tailwind v4 + Geist.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
