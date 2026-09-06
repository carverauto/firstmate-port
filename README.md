# firstmate-port

Phoenix/Ash companion portal for firstmate. Crew reviews Archify diagrams, PRs, issues, NATS queues, and no-mistakes runs in one LiveView UI, and searches the [indexed fleet log](docs/fleet-search.md) at `/search`. Discord inbound is served by Phoenix at POST `/interactions`.

Each tenant stores its own credentials - Discord keys, GitHub tokens, provider API keys - in the portal, encrypted with AshCloak before they reach Postgres. No per-tenant `kubectl create secret`.

## Local

```sh
cp .env.example .env
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker compose up --build
```

OpenSSL generates the secret without compiling Mix dependencies. To reuse it across
shell sessions, save the generated value as `SECRET_KEY_BASE` in `.env`.

http://localhost:4000/login. The admin account and its password are printed once
on first boot: `docker compose logs portal | grep -A4 "first-run sign-in"`. No
identity provider needed.

Stack: Phoenix 1.8, Ash, AshOban, AshEvents, AshPaperTrail, AshAi MCP at `/mcp`, Bandit, Ueberauth OIDC, Gnat/JetStream, Tailwind v4 + Geist.

## Docs

- [docs/credentials.md](docs/credentials.md) how a tenant stores Discord and other secrets
- [docs/fleet-search.md](docs/fleet-search.md) searching the fleet log, and the optional embeddings
- [docs/deploy.md](docs/deploy.md) image publishing, compose, Kubernetes
- [docs/bazel.md](docs/bazel.md) rules_elixir / BuildBuddy, `--output_base=/tmp/fm-fm-port/bazel`

Prefix every `npm` invocation with `sfw`.

## fm-steer CLI

`fm-steer` (Go) authenticates with RFC 8628 device-code against this API and drives inbox put/next/ack/list over HTTP. It does not dial NATS. JWT is stored at `$XDG_CONFIG_HOME/fm-steer/credentials.json` (mode 0600).

Fleet log ingest (`rolls|diagrams|no-mistakes post`, e.g.
`fm-steer rolls post --cluster c1 --namespace n1 --status success --image-tag sha-abc`)
sends `POST /api/rolls|diagrams|no-mistakes`. Writes require an agent role,
so set `FIRSTMATE_AGENT_TOKEN` to an agent API token (env only, never printed
or stored). Without it, the CLI falls back to stored login credentials; a
regular device-code user JWT cannot authorize ingest writes. When neither
`--instance`, `FIRSTMATE_INSTANCE`, nor stored credentials name a host, the CLI
targets `http://localhost:4000`. Set `FIRSTMATE_INSTANCE` for your deployment.

With the agent token supplied in your environment:

```sh
fm-steer diagrams post --title "Request flow" --html-file diagram.html
fm-steer no-mistakes post --run-id run-123 --branch fm/example --step review
```

Use `fm-steer <kind> post --help` for the available fields. Progress is populated
by the [GitHub poll](docs/deploy.md#github-fleet-log-ingestion).

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
- `cmd/fm-steer` HTTP inbox + Fleet log ingest CLI (device-code; does not dial NATS)
- `k8s/` portal + 3-node NATS + CNPG (Discord interactions are served by Phoenix at `/interactions`; no sidecars)
- `docker-compose.yml` portal + Postgres + single-node JetStream
