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

- [docs/deploy.md](docs/deploy.md) ghcr.io publish, compose, Kubernetes
- [docs/bazel.md](docs/bazel.md) rules_elixir / BuildBuddy, `--output_base=/tmp/fm-fm-port/bazel`

Prefix every `npm` invocation with `sfw`.

## fm-steer CLI

`fm-steer` authenticates with RFC 8628 device-code against this API and drives inbox put/next/ack/list over HTTP. It does not dial NATS. JWT is stored at `$XDG_CONFIG_HOME/fm-steer/credentials.json` (mode 0600).

Install from source (Go 1.25+):

```sh
go install github.com/mfreeman451/firstmate-port/cmd/fm-steer@latest
```

The repo is private, so `go install` needs read access (`gh auth` / git
credentials). Without Go, download a release binary instead: every `v*` tag
publishes `fm-steer_<tag>_<os>_<arch>` assets (linux amd64/arm64, darwin
amd64/arm64) plus `SHA256SUMS` on the GitHub Release.

## Layout

- `lib/` Phoenix/Ash portal
- `cmd/fm-steer` HTTP inbox CLI (device-code; does not dial NATS)
- `k8s/` portal + 3-node NATS + CNPG (Discord interactions are served by Phoenix at `/interactions`; no sidecars)
- `docker-compose.yml` portal + Postgres + single-node JetStream
