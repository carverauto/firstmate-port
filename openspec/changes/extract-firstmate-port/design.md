# Design

## Defaults vs examples
Compiled defaults run locally: `localhost`, single-node NATS. Site hostnames, issuer URLs, registry namespaces, and email allowlists belong in `.env`, compose overrides, and `deploy/examples`.

## Auth
Runtime sign-in modes and bootstrap credentials are documented in [Deploy: Sign-in](../../../docs/deploy.md#sign-in). Agents use `FIRSTMATE_AGENT_TOKEN` (hashed) for MCP and ingest writes.

## NATS
Kubernetes: 3-replica FileStorage cluster, headless service, port 6222, PVCs. One NATS account. Per-tenant streams `<tenant>.steer` (`<tenant>.steer.>`) and `<tenant>.inbound` (`<tenant>.discord.inbound`). No `<tenant>.>` catch-all. Compose: one nats-server with JetStream. The Phoenix API is the only JetStream client.

## UI
Operator product UI. Login and empty fleet can be editorial. PR/issue/run boards stay dense product tables. Tailwind v4, Geist, teal accent, dual theme, WCAG AA, `prefers-reduced-motion`.
