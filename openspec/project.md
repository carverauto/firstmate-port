# Project Context

## Purpose
See [README.md](../README.md) for the product introduction and common usage.

## Tech Stack
- Elixir 1.19 / Phoenix 1.8 LiveView / Bandit
- Ash, AshPostgres, AshPhoenix, AshOban, AshPaperTrail, AshEvents, AshAi MCP, AshCloak (tenant credentials) + Cloak vault
- Guardian + Ueberauth/ueberauth_oidcc + PKCE. No AshAuthentication tokens. No AshJsonApi.
- Gnat / NATS JetStream
- Go CLI: `fm-steer` (stdlib only; HTTP to the API, never NATS). Discord inbound is Phoenix (`POST /interactions`); no Go/Python sidecars.
- Tailwind v4 + Geist
- Bazel (rules_elixir / BuildBuddy remote-exec)
- Docker Compose (portal, Postgres, single-node JetStream)
- ghcr.io for images (`ghcr.io/<owner>/firstmate-port`)

## Project Conventions

### Code Style
- Elixir: mix format, pattern match in tests, `unbuffer mix test` when available
- Go: stdlib only
- Prefix every `npm` with `sfw`

### Architecture Patterns
- Browser sign-in: see [Deploy](../docs/deploy.md#sign-in). Agents: hashed service token + MCP at `/mcp`
- GitHub URLs stored exactly as copied from the API; never assembled from owner/repo/number
- Site-specific hostnames and allowlists live in env samples / compose overrides / docs, never as the only compiled-in identity

### Testing Strategy
- Go tests for CLI env/flag behaviour
- Elixir ExUnit + SQL sandbox (Postgres 16)

### Git Workflow
- Feature branches `fm/*`. Never push or merge the default branch from a crewmate.
- Delivery is no-mistakes; do not merge.

## Domain Context
- Discord cannot render HTML; Archify URLs are the product
- `fm-steer` is the CLI port to the portal API (see `/steer/docs/fm-steer`). Do not rip the on-disk inbox.
- NATS in cluster shape is 3-replica FileStorage; compose may be single-node
- Tenancy is attribute-based on shared Postgres; one NATS account; streams named `<tenant>.steer` and `<tenant>.inbound`
- Tenant credential storage, Discord routing, and vault-key operations: see [docs/credentials.md](../docs/credentials.md).
- The portal hostname is public, on the shared Envoy Gateway alongside the Discord interactions hostname. Public-edge posture is [docs/security.md](../docs/security.md).
- `/terms` and `/privacy` are public because Discord's Developer Portal requires reachable URLs for both; operator identity on them is config, not compiled-in copy
- Public Discord failures stay generic

## Important Constraints
- Do not copy `notify.py`, `watch.py`, or the launchd plist into this repo
- Do not schedule a Mac Bazel cache wipe in AshOban or Kubernetes
- Do not relocate `~/.no-mistakes` into the cluster
- Do not `kubectl create secret` per-tenant credentials, and never return a stored secret over HTTP or MCP
- Do not add a public route without deciding its rate-limit bucket and CSP preset; do not put MCP or NATS on a public hostname
- Local Bazel: `--output_base=/tmp/fm-fm-port/bazel`. `--config=remote` is fine; never `--config=ci` locally
- ghcr.io is the registry; do not invent a second forge

## External Dependencies
- Optional OIDC issuer: any OpenID Connect provider, discovered from the issuer URL. No per-vendor adapter.
- GitHub API (fine-grained PAT) when poll is enabled
- ghcr.io for image publish
