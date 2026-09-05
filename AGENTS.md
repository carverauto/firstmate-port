# firstmate-port

Companion portal for firstmate. Phoenix/Ash LiveView, NATS JetStream, Bazel, Docker Compose.

## Commands

- Local stack: `docker compose up --build` (see `docs/deploy.md`)
- Mix: `mix setup` then `mix phx.server` against compose Postgres
- Tests: `unbuffer mix test` when `unbuffer` is available
- Bazel: `./tools/bazel` (forces `--output_base=/tmp/fm-fm-port/bazel`). `--config=remote` is fine; never `--config=ci` locally. See `docs/bazel.md`
- Prefix every `npm` with `sfw`

## Boundaries

- `fm-steer` is the captain CLI. Device-code against this API. It must not import or dial NATS.
- Attribute tenancy on shared Postgres and one NATS account. Streams are `<tenant>.steer` / `<tenant>.inbound`. Seed tenant `local` as an example. The API is the tenant wall and the only JetStream client.
- Do not add `notify.py`, `watch.py`, or the launchd plist. Those stay in firstmate-notify.
- Site hostnames, Authentik, Harbor, and email allowlists belong in env samples / compose overrides / `deploy/examples`. Defaults run on localhost.
- Harbor is the internal image registry. ghcr.io is a later public mirror; do not invent a second forge.

## Stack

Phoenix 1.8, Ash, AshOban, AshEvents, AshPaperTrail, AshAi MCP at `/mcp`, Bandit, Ueberauth OIDC, Gnat/JetStream. UI is Tailwind v4 + Geist.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
