# Project Context

## Purpose
firstmate-port is the OSS companion portal for firstmate: a Phoenix LiveView site where a captain and crew review Archify diagrams, PRs, issues, NATS queues, and no-mistakes runs. Discord inbound is served by Phoenix at POST `/interactions`.

## Tech Stack
- Elixir 1.19 / Phoenix 1.8 LiveView / Bandit
- Ash, AshPostgres, AshPhoenix, AshOban, AshPaperTrail, AshEvents, AshAi MCP
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
- Browser users: OIDC. Agents: hashed service token + MCP at `/mcp`
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
- `fm-steer` is the inbox port (put/next/ack/list). Do not rip the on-disk inbox.
- NATS in cluster shape is 3-replica FileStorage; compose may be single-node
- Tenancy is attribute-based on shared Postgres; one NATS account; streams named `<tenant>.steer` and `<tenant>.inbound`
- Public Discord failures stay generic

## Important Constraints
- Do not copy `notify.py`, `watch.py`, or the launchd plist into this repo
- Do not schedule a Mac Bazel cache wipe in AshOban or Kubernetes
- Do not relocate `~/.no-mistakes` into the cluster
- Local Bazel: `--output_base=/tmp/fm-fm-port/bazel`. `--config=remote` is fine; never `--config=ci` locally
- ghcr.io is the registry; do not invent a second forge

## External Dependencies
- Optional OIDC issuer (Authentik or other)
- GitHub API (fine-grained PAT) when poll is enabled
- ghcr.io for image publish
