# firstmate-portal

## ADDED Requirements

### Requirement: Portal ships without the Mac notifier
The repository SHALL contain the Phoenix/Ash portal, fm-steer, NATS cluster manifests, and related deploy files. It SHALL NOT contain `notify.py`, `watch.py`, or the launchd plist.

#### Scenario: Source tree
- **WHEN** a contributor clones firstmate-port
- **THEN** they can build the portal and fm-steer without any Discord webhook sender from the Mac notifier

### Requirement: Local compose is the default identity
Compiled defaults SHALL run locally via docker compose with generic names (`localhost`, example hostnames). Site-specific hostnames, VIP, OIDC issuer URL, registry namespace, and email allowlists SHALL appear only in env samples, compose overrides, or docs.

#### Scenario: First boot
- **WHEN** an operator runs `docker compose up` with `.env` from `.env.example`
- **THEN** the portal listens on localhost without requiring a carverauto hostname

### Requirement: Operator UI
The site SHALL use Tailwind v4 and a self-hosted Geist stack, with one accent color and light/dark themes. Login and empty-fleet surfaces MAY be editorial. PR, issue, and run boards SHALL stay product UI with empty, loading, and error states.

#### Scenario: Anonymous visitor
- **WHEN** a browser opens `/`
- **THEN** they are sent to `/login` rather than bouncing straight into OIDC

### Requirement: fm-steer uses device-code against the API
The captain CLI SHALL be `fm-steer`. Login SHALL be RFC 8628 device-code against this Phoenix API. Inbox put/next/ack/list SHALL be HTTP to this API. The CLI SHALL NOT dial NATS. The JWT file SHALL be mode 0600, and SHALL record the instance the CLI was logged in against so later commands need no `--instance`.

#### Scenario: CLI login
- **WHEN** an operator runs `fm-steer auth login --instance http://localhost:4000`
- **THEN** they receive a verification URL and user code, and after browser approval the CLI stores a JWT

### Requirement: CLI sessions are visible and revocable
Each issued CLI token SHALL have a session record identified by the token's `jti`, carrying the requesting client, the instance, and when it was approved and last used. A signed-in user SHALL see their own sessions in the portal and SHALL be able to revoke one. A CLI token whose session is missing or revoked SHALL be refused. Sessions SHALL NOT be visible or revocable across users.

#### Scenario: Revoked CLI token
- **WHEN** a captain revokes a session in the portal
- **THEN** the CLI holding that token is refused on its next request and is told to sign in again

### Requirement: One durable inbox per tenant carries both directions
The inbox SHALL be persisted, so queued messages survive a restart and more than one node can serve `next`. A message SHALL be claimed by exactly one reader. There SHALL be one inbox per tenant with `task` routing within it and no second broker; a message with no task SHALL be filed under `firstmate`. Publishing to JetStream SHALL happen after the message is stored and SHALL NOT block the request or another message.

#### Scenario: Both mates on one queue
- **WHEN** one mate puts a message and another runs `next`
- **THEN** the second receives it, a concurrent `next` receives nothing, and the portal shows the exchange

#### Scenario: JetStream is unavailable
- **WHEN** the fan-out to JetStream cannot complete
- **THEN** the message is still stored, returned to the caller, and readable by `next`

### Requirement: Attribute tenancy on shared Postgres and one NATS account
Tenancy SHALL be attribute-based on a shared Postgres database and a single NATS account. Streams SHALL be named `<tenant>.whatever` (for example `acme.steer` and `acme.inbound`). The Phoenix API SHALL be the only JetStream client and the tenant wall. A seed tenant `local` SHALL exist as an example, not a compiled-in site identity. One tenant SHALL NOT see another tenant's rows, streams, or consumers.

#### Scenario: Isolated inbox
- **WHEN** two tenants put inbox items
- **THEN** each list sees only its own items

#### Scenario: Isolated rows
- **WHEN** two tenants record portal rows
- **THEN** each list sees only its own rows

