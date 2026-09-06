# firstmate-port

Phoenix/Ash companion portal for firstmate. Crew reviews Archify diagrams, PRs, issues, opt-in build tracking (Kubernetes, Docker, BuildBuddy), NATS queues, token usage, and no-mistakes runs in one LiveView UI. Discord inbound is served by Phoenix at POST `/interactions`.

Each tenant stores its own credentials - Discord keys, GitHub tokens, provider API keys - in the portal, encrypted with AshCloak before they reach Postgres. No per-tenant `kubectl create secret`.

Terms of Service and Privacy Policy are available from the footer on the
sign-in and portal pages, at `/terms` and `/privacy`.

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

- [docs/fm-steer.md](docs/fm-steer.md) `fm-steer` for stock firstmate captains: login, commands, and the standing prompt that makes firstmate mirror steers to the portal (no fork required)
- [docs/credentials.md](docs/credentials.md) how a tenant stores Discord and other secrets
- [docs/fleet-search.md](docs/fleet-search.md) searching the fleet log, and the optional embeddings
- [docs/security.md](docs/security.md) running the portal on a public hostname: client-IP config, rate limits, lockout, CSP
- [docs/deploy.md](docs/deploy.md) image publishing, compose, Kubernetes
- [docs/build-tracking.md](docs/build-tracking.md) opt-in tracking and BuildBuddy secrets
- [docs/bazel.md](docs/bazel.md) rules_elixir / BuildBuddy, `--output_base=/tmp/fm-fm-port/bazel`
- [docs/build-events.md](docs/build-events.md) the append-only build/deploy log and its API
- [docs/diagrams/](docs/diagrams/) Archify diagrams of the deployment, source specs beside the rendered HTML

User docs are served by the portal itself, one copy only, from the marketing
landing page at `/steer`:

- `/steer/docs/fm-steer` CLI: auth, inbox, route, usage
- `/steer/docs/routing` task router: axes, matrix, intel, evals
- `/steer/docs/usage` token usage ledger: accounts, runway, readings

Run `mix phx.server` and open <http://localhost:4000/steer/docs>.

Prefix every `npm` invocation with `sfw`.

## fm-steer CLI

`fm-steer` (Go) authenticates with RFC 8628 device-code against this API and drives inbox put/next/ack/list, `route "<task>"` (the portal picks harness, model and effort and says why), and `usage` (per-account token counters and remaining allowance) over HTTP. It does not dial NATS. JWT is stored at `$XDG_CONFIG_HOME/fm-steer/credentials.json` (mode 0600).

Fleet log ingest (`rolls|diagrams|no-mistakes post`, e.g.
`fm-steer rolls post --cluster c1 --namespace n1 --status success --image-tag sha-abc`)
sends `POST /api/rolls|diagrams|no-mistakes`. Writes require an agent role,
so set `FIRSTMATE_AGENT_TOKEN` to an agent API token (env only, never printed
or stored). Without it, the CLI falls back to stored login credentials; a
regular device-code user JWT cannot authorize ingest writes. When neither
`--instance`, `FIRSTMATE_INSTANCE`, nor stored credentials name a host, the CLI
targets `http://localhost:4000`. Set `FIRSTMATE_INSTANCE` for your deployment.

Before recording rolls, enable [Kubernetes tracking](docs/build-tracking.md#switches).

With the agent token supplied in your environment:

```sh
fm-steer diagrams post --title "Request flow" --html-file diagram.html
fm-steer no-mistakes post --run-id run-123 --branch fm/example --step review
```

Use `fm-steer <kind> post --help` for the available fields. For crew-work
tracking, dashboard navigation, and `fm-steer progress post`, see the
[Progress guide](docs/progress.md).

### Build and deployment tracking

`fm-steer build start` and `fm-steer build finish` bracket a build or a
deployment, whatever performs it - `--kind` names the system (`docker`, `k8s`,
`bazel`, ...) rather than the API growing an endpoint per system. `start`
prints the `run_id` that `finish` reports against, and the pair records who ran
it, on what model and effort, and what it cost in tokens:

```sh
fm-steer build start --kind docker --target firstmate-port --agent-id crew-7
fm-steer build finish --run-id run-3f9a1c7e5b2d4a08 --status success --tokens 48210
```

`FIRSTMATE_AGENT_ID`, `FIRSTMATE_MODEL`, and `FIRSTMATE_EFFORT` supply the
defaults on `start`. The log is append-only and a dashboard row is a projection over one
`run_id`; see [docs/build-events.md](docs/build-events.md).

Crew make these calls themselves. The installable
[`build-tracking` skill](skills/build-tracking/SKILL.md) is what tells them to:
copy that directory into the agent's skills directory
(`~/.claude/skills/build-tracking/` for Claude Code).

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
- `skills/` installable agent skills that drive the CLI
- `k8s/` portal + 3-node NATS + CNPG (Discord interactions are served by Phoenix at `/interactions`; no sidecars)
- `docker-compose.yml` portal + Postgres + single-node JetStream
