# firstmate-port

Phoenix/Ash companion portal for firstmate. Crew reviews Archify diagrams, PRs, issues, runs, and usage in one LiveView UI. Discord inbound is served by Phoenix at POST `/interactions`.

## Local

```sh
cp .env.example .env
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker compose up --build
```

OpenSSL generates the secret without compiling Mix dependencies. To reuse it across
shell sessions, save the generated value as `SECRET_KEY_BASE` in `.env`.

http://localhost:4000/login. With `DEV_AUTH=true`, use `captain@localhost`.

Stack: Phoenix 1.8, Ash, AshOban, AshEvents, AshPaperTrail, AshAi MCP at `/mcp`, Bandit, Ueberauth OIDC, Gnat/JetStream, Tailwind v4 + Geist.

Tenancy: shared Postgres and one NATS account. Streams are `<tenant>.steer` / `<tenant>.inbound` (seed tenant `local`). The API is the tenant wall and the only JetStream client.

Images: Harbor is the internal registry; ghcr.io is a later public mirror.

Workstation notification stays in firstmate-notify until Elixir outbound replaces it.

## Docs

- [docs/deploy.md](docs/deploy.md) ghcr.io publish, compose, Kubernetes
- [docs/bazel.md](docs/bazel.md) rules_elixir / BuildBuddy, `--output_base=/tmp/fm-fm-port/bazel`

Prefix every `npm` invocation with `sfw`.

## fm-steer CLI

`fm-steer` (Go) authenticates with RFC 8628 device-code against this API and drives inbox put/next/ack/list over HTTP. It does not dial NATS. JWT is stored at `$XDG_CONFIG_HOME/fm-steer/credentials.json` (mode 0600).

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
