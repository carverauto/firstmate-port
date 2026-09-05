# Design

## Defaults vs examples
Compiled defaults run locally: `localhost`, `DEV_AUTH`, `ALLOWED_EMAIL_DOMAIN=localhost`, single-node NATS. Site hostnames, Authentik, Harbor, and email allowlists belong in `.env`, compose overrides, and `deploy/examples`.

## Auth
OIDC via Ueberauth when `OIDC_ISSUER` / client secret are set. `DEV_AUTH=true` offers a local email form for compose. Agents use `FIRSTMATE_AGENT_TOKEN` (hashed) for MCP and ingest writes.

## NATS
Kubernetes: 3-replica FileStorage cluster, headless service, port 6222, PVCs, durable streams `firstmate-steer` (`firstmate.steer.>`) and `captain-inbound` (`firstmate.discord.inbound`). No `firstmate.>` catch-all. Compose: one nats-server with JetStream.

## UI
Operator product UI. Login and empty fleet can be editorial. PR/issue/run boards stay dense product tables. Tailwind v4, Geist, teal accent, dual theme, WCAG AA, `prefers-reduced-motion`.
