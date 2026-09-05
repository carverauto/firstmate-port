# firstmate-portal

## ADDED Requirements

### Requirement: Portal ships without the Mac notifier
The repository SHALL contain the Phoenix/Ash portal, fm-steer, NATS cluster manifests, and related deploy files. It SHALL NOT contain `notify.py`, `watch.py`, or the launchd plist.

#### Scenario: Source tree
- **WHEN** a contributor clones firstmate-port
- **THEN** they can build the portal and fm-steer without any Discord webhook sender from the Mac notifier

### Requirement: Local compose is the default identity
Compiled defaults SHALL run locally via docker compose with generic names (`localhost`, example hostnames). Site-specific hostnames, VIP, Authentik URL, Harbor, and email allowlists SHALL appear only in env samples, compose overrides, or docs.

#### Scenario: First boot
- **WHEN** an operator runs `docker compose up` with `.env` from `.env.example`
- **THEN** the portal listens on localhost without requiring a carverauto hostname

### Requirement: Operator UI
The site SHALL use Tailwind v4 and a self-hosted Geist stack, with one accent color and light/dark themes. Login and empty-fleet surfaces MAY be editorial. PR, issue, and run boards SHALL stay product UI with empty, loading, and error states.

#### Scenario: Anonymous visitor
- **WHEN** a browser opens `/`
- **THEN** they are sent to `/login` rather than bouncing straight into OIDC

### Requirement: firstmatectl uses device-code against the API
The captain CLI SHALL be `firstmatectl`. Login SHALL be RFC 8628 device-code against this Phoenix API. Inbox put/next/ack/list SHALL be HTTP to this API. The CLI SHALL NOT dial NATS. The JWT file SHALL be mode 0600.

#### Scenario: CLI login
- **WHEN** an operator runs `firstmatectl auth login --instance http://localhost:4000`
- **THEN** they receive a verification URL and user code, and after browser approval the CLI stores a JWT

### Requirement: Schema and JetStream account per tenant
Each tenant SHALL have its own Postgres schema and NATS JetStream account. The API SHALL select both from the authenticated tenant. A seed tenant `local` SHALL exist. Rows and streams SHALL NOT leak across tenants.

#### Scenario: Isolated inbox
- **WHEN** two tenants put inbox items
- **THEN** each list sees only its own items

