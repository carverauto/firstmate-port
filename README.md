# firstmate-port

Phoenix LiveView companion portal for firstmate. Crew reviews Archify diagrams, PRs, issues, farm rolls, NATS queues, and no-mistakes runs. The Mac Discord notifier (`notify.py`, `watch.py`, launchd) stays in firstmate-notify.

## Local

```sh
cp .env.example .env
# SECRET_KEY_BASE=$(mix phx.gen.secret)
docker compose up --build
```

http://localhost:4000/login. With `DEV_AUTH=true`, use `captain@localhost`.

Stack: Phoenix 1.8, Ash, AshOban, AshEvents, AshPaperTrail, AshAi MCP, Bandit, Ueberauth OIDC, Gnat/JetStream LiveView, Tailwind v4.

## Docs

- [docs/deploy.md](docs/deploy.md) Harbor publish, compose, Kubernetes
- [docs/bazel.md](docs/bazel.md) rules_elixir / BuildBuddy, `--output_base=/tmp/fm-fm-port/bazel`
- [docs/fm-steer.md](docs/fm-steer.md) CLI: auth, inbox, route, usage
- [docs/routing.md](docs/routing.md) task router: axes, matrix, intel, evals
- [docs/usage.md](docs/usage.md) token usage ledger: accounts, runway, sync

Marketing landing page and user docs are served at `/steer`.

Prefix every `npm` invocation with `sfw`.

CLI: `fm-steer` authenticates with RFC 8628 device-code against this API and drives inbox put/next/ack/list, `route "<task>"` (portal picks harness/model/effort plus why), and `usage [--sync]` (per-account token counters) over HTTP. It does not dial NATS. JWT is stored at `$XDG_CONFIG_HOME/fm-steer/credentials.json` (mode 0600).

## Layout

- `lib/` Phoenix/Ash portal
- `cmd/fm-steer` HTTP inbox CLI (device-code; does not dial NATS)
- `cmd/nats-tail`, `cmd/discord-inbound`, `cmd/discord-interactions`
- `k8s/` portal + 3-node NATS + CNPG
- `docker-compose.yml` portal + Postgres + single-node JetStream
