# firstmate-port

Companion portal for firstmate. Phoenix/Ash LiveView, NATS JetStream, Bazel, Docker Compose.

## Commands

- Local stack: `docker compose up --build` (see `docs/deploy.md`)
- Mix: `mix setup` then `mix phx.server` against compose Postgres
- Tests: `unbuffer mix test` when `unbuffer` is available. Preserve the ReqLLM catalogue preload in `test/test_helper.exs` before database-backed tests.
- Bazel: `./tools/bazel` (forces `--output_base=/tmp/fm-fm-port/bazel`). `--config=remote` is fine; never `--config=ci` locally. See `docs/bazel.md`
- Prefix every `npm` with `sfw`

## Boundaries

- Inbound Discord picks its tenant from the `Host`, not the signature: `discord-<tenant><DISCORD_HOST_SUFFIX>`, verified against that tenant's key alone. Those hostnames serve `POST /interactions` and nothing else, and get no HTTP-to-HTTPS redirect route (behind a proxy that fetches the origin over port 80 it loops). See `docs/credentials.md`, "Publishing the interactions hostname".
