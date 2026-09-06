## ADDED Requirements

### Requirement: Per-Account Allowance And Remaining

The portal SHALL expose, for every provider account visible to the actor's
tenant, the configured allowance, the amount used, the remaining allowance, the
percentage consumed, the reset window, and a status of `ok`, `low`,
`exhausted`, or `unknown`. When the allowance is not known the system SHALL
report `unknown` and SHALL NOT invent a remaining figure.

#### Scenario: Account with a known allowance
- **WHEN** an account has allowance 100.0 and used 80.0
- **THEN** remaining is 20.0, percent used is 0.8, and status is `low`

#### Scenario: Account with no configured allowance
- **WHEN** an account has a null allowance and used 40.0
- **THEN** remaining is null, percent used is null, and status is `unknown`
- **AND** the response states that the allowance is unknown rather than showing zero

#### Scenario: Exhausted account
- **WHEN** used is greater than or equal to allowance
- **THEN** status is `exhausted`

### Requirement: Actual Model Usage Is Recorded Per Task

The portal SHALL record a usage event for each completed unit of model work,
carrying the tenant, the usage account, the task reference, the harness, the
model, the effort, the tokens consumed, the cost in the account's unit, and the
time of completion. Usage events SHALL be additive and immutable; corrections
SHALL be recorded as a further compensating event rather than by mutating a
recorded event.

#### Scenario: Worker reports completed work
- **WHEN** a worker posts a usage event for a task with harness `codex`, model `gpt-6-astra`, effort `medium`, and a token count
- **THEN** the event is persisted against the actor's tenant and the named account
- **AND** the account's `used` rollup reflects the event

#### Scenario: Correcting an overstated event
- **WHEN** a previously recorded event is found to be wrong
- **THEN** a compensating event is recorded
- **AND** the original event remains readable in the ledger

#### Scenario: Event for an account in another tenant
- **WHEN** a worker posts a usage event naming an account that belongs to a different tenant
- **THEN** the request is rejected and no event is recorded

### Requirement: The Ledger Is Fed By Posted Usage

Recorded usage SHALL enter the ledger only by being posted — by a worker through
the API, or by a human through the portal UI. The portal SHALL NOT contact a
provider to read spend, and SHALL NOT require a provider spend credential for
the ledger to function.

#### Scenario: Worker posts consumption
- **WHEN** a worker posts what a completed task consumed
- **THEN** the figure is recorded and the account rollup reflects it

#### Scenario: Human records a reading
- **WHEN** an operator enters a usage figure through the portal UI
- **THEN** the figure is recorded against the named account

#### Scenario: No provider is contacted
- **WHEN** any usage figure is produced
- **THEN** it derives from posted records and no provider spend API is called

### Requirement: Recorded Usage Is Labelled By Origin

Every reported figure SHALL carry the origin it came from: `posted` for figures
written by a worker or an operator, and `provider_reported` for totals a
provider confirmed. The API and the usage view SHALL both carry this label so a
posted figure is never presented as an invoice.

#### Scenario: Tenant total from posted events
- **WHEN** a tenant's spend is derived by summing posted usage events
- **THEN** the figure is returned with origin `posted`

#### Scenario: Posted figure is not presented as billed
- **WHEN** a posted figure is rendered in the API or the usage view
- **THEN** it is labelled `posted` and is not described as an amount billed by the provider

### Requirement: Burn Rate And Runway

The portal SHALL derive a daily burn rate from recorded usage history and SHALL
report an estimated runway in days until an account's allowance is exhausted.
When there is insufficient history to support an estimate, the runway SHALL be
null and SHALL NOT be extrapolated from a single observation.

#### Scenario: Sufficient history
- **WHEN** usage history spans at least one day with rising usage and the account has remaining allowance
- **THEN** a runway in days is reported

#### Scenario: Single observation only
- **WHEN** only one usage observation exists for an account
- **THEN** the runway is null

#### Scenario: Flat or falling usage
- **WHEN** usage has not increased across the observed history
- **THEN** the runway is null rather than infinite

### Requirement: Credentials Are Read From The Environment And Never Emitted

Any API token the portal holds — such as a ranking-source key — SHALL be read
from the runtime environment at the moment of use. Tokens SHALL NOT be written
to the database, to logs, to API responses, to diagrams, or to version control.
A missing token SHALL degrade the feature that needs it and SHALL NOT fail an
unrelated request.

#### Scenario: Token absent
- **WHEN** a feature that needs a token runs with that token unconfigured
- **THEN** the feature reports that it is unavailable and the reason
- **AND** requests that do not need that token still succeed

#### Scenario: No token value in any output
- **WHEN** any usage endpoint or view renders account details
- **THEN** no token value appears in the output

### Requirement: Spend Order Across Accounts

When more than one account can fund a given harness, the portal SHALL select
accounts in ascending `spend_priority`, and SHALL skip accounts whose status is
`exhausted`. The selected account SHALL be reported with the assignment so the
choice is auditable.

#### Scenario: Two funding accounts
- **WHEN** two accounts can fund the same harness with priorities 10 and 50 and both have headroom
- **THEN** the account with priority 10 is selected

#### Scenario: Preferred account exhausted
- **WHEN** the priority 10 account is exhausted and the priority 50 account has headroom
- **THEN** the priority 50 account is selected and the reason names the exhausted account
