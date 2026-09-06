## ADDED Requirements

### Requirement: Assignment Of Harness, Model, And Effort

For a rated task the portal SHALL return an assignment naming the harness, the
model, the effort level, the funding account, and the reasons for each choice.
Effort SHALL be one of `low`, `medium`, or `high`, and SHALL rise with the
task's difficulty. The assignment SHALL also carry the axes used, the projected
usage, and the ranking sources consulted.

#### Scenario: Ordinary code task
- **WHEN** a well-specified code fix is routed
- **THEN** the assignment names a harness, a model, an effort, a funding account, and the reasons

#### Scenario: Difficult ambiguous task
- **WHEN** a task is high ambiguity and high blast radius
- **THEN** the assigned effort is higher than for an equivalent low-difficulty task in the same lane

#### Scenario: Reasons are legible
- **WHEN** an assignment is returned
- **THEN** the reasons state which lanes were excluded and why, and which consideration decided the winner

### Requirement: Capability Constraints Are Hard

A harness lane SHALL NOT be assigned work that exceeds its recorded maximum
ambiguity, blast radius, or risk, that falls outside its supported task kinds,
or that requires a capability the lane lacks, such as live web access or
citation support. When no lane satisfies every constraint, the portal SHALL
escalate to the most capable lane and SHALL mark the task for human review.

#### Scenario: Task needs live web
- **WHEN** a task requires live web access
- **THEN** lanes without live web access are excluded and the reason says so

#### Scenario: Risk exceeds every lane
- **WHEN** no lane's maximum risk covers the task
- **THEN** the task escalates to the most capable lane and is marked for human review

### Requirement: Code Review Is Hard-Routed To Codex Astra

When the classified kind is `review`, the portal SHALL assign harness `codex`
with model `gpt-6-astra`. This assignment SHALL NOT be changed by ranking, by
cost, by quota pressure, or by caller-supplied axis overrides. Code review SHALL
NOT be assigned to any other harness.

#### Scenario: Plain code review
- **WHEN** a task asks for a pull request to be reviewed
- **THEN** the assignment is harness `codex` with model `gpt-6-astra`

#### Scenario: Code review under quota pressure
- **WHEN** the funding account for a code review is under quota pressure
- **THEN** the harness and model remain `codex` and `gpt-6-astra`
- **AND** only the effort may be lowered, or the task deferred

#### Scenario: Cheaper model ranks higher
- **WHEN** ranking scores another model above `gpt-6-astra` for the review task
- **THEN** the assignment still uses `codex` with `gpt-6-astra`

### Requirement: Quota-Aware Admission

Before an assignment is issued, the portal SHALL compare the task's projected
usage against the remaining allowance of the funding account and SHALL return an
admission decision of `admit`, `downgrade`, `reassign`, or `defer` together with
the reason. The decision SHALL be reported with the assignment.

#### Scenario: Ample headroom
- **WHEN** projected usage is small relative to the remaining allowance
- **THEN** the decision is `admit`

#### Scenario: Projection exceeds remaining allowance
- **WHEN** projected usage exceeds the remaining allowance on every funding account for the lane
- **THEN** the decision is `downgrade` or `defer` and the reason names the account and the shortfall

#### Scenario: Allowance unknown
- **WHEN** the funding account has no known allowance
- **THEN** the decision is `admit` and the reason states that headroom could not be evaluated

### Requirement: Work Is Re-Assigned Off Agents That Hit Usage Limits

The portal SHALL re-assign a task off any harness whose funding accounts are all
exhausted or at their provider limit, moving it to the next best lane that
satisfies every constraint for that task and still has headroom, and SHALL
record the re-assignment with the harness it moved off and why. When no
alternative lane both satisfies the constraints and has headroom, the portal
SHALL defer rather than assign work it cannot fund. Re-assignment SHALL NOT
apply to a hard-routed kind.

#### Scenario: Assigned harness is out of allowance
- **WHEN** every funding account for the chosen harness is exhausted and another lane satisfies the task's constraints with headroom
- **THEN** the decision is `reassign`, the task is assigned to that lane, and the reason names the exhausted harness

#### Scenario: No funded lane remains
- **WHEN** no lane that satisfies the task's constraints has any headroom
- **THEN** the decision is `defer` and the reason names the accounts that are exhausted

#### Scenario: Re-assignment never moves a code review
- **WHEN** the funding for a code review is exhausted
- **THEN** the assignment remains harness `codex` with model `gpt-6-astra` and the decision is `defer`, never `reassign`

#### Scenario: Re-assignment respects capability constraints
- **WHEN** a task requiring live web access is re-assigned
- **THEN** only lanes with live web access are considered

### Requirement: Advisory Enforcement By Default

Under quota pressure the portal SHALL default to `downgrade` and SHALL warn.
It SHALL return `defer` only when the funding account is configured to enforce
its allowance, or when the account is exhausted and no alternate funding account
exists for the lane. Downgrade SHALL lower effort or select a cheaper model
within the already-admitted lane, and SHALL NOT change the harness; moving a
task to a different harness is `reassign`, which is triggered by exhausted
funding rather than by cost pressure.

#### Scenario: Pressure on a non-enforcing account
- **WHEN** projected usage would exceed a comfortable share of a non-enforcing account's remaining allowance
- **THEN** the decision is `downgrade` with a warning, and work is still assigned

#### Scenario: Pressure on an enforcing account
- **WHEN** the same pressure applies to an account configured to enforce
- **THEN** the decision is `defer` and the reason names the enforcing account

#### Scenario: Downgrade stays in lane
- **WHEN** a task is downgraded
- **THEN** the harness is unchanged and only the effort or the in-lane model differs

### Requirement: Projected Spend Is Reserved Until Reconciled

On admission the portal SHALL reserve the projected usage against the funding
account so that concurrent admissions cannot each be granted the same headroom.
A reservation SHALL be released when its matching usage event is recorded, or on
expiry of a time-to-live. Expired reservations SHALL be recorded so that a
harness which repeatedly fails to report is visible.

#### Scenario: Concurrent admissions
- **WHEN** several tasks are admitted concurrently against one account
- **THEN** each admission accounts for the reservations already held, and their combined reservations do not exceed the remaining allowance

#### Scenario: Reservation released on report
- **WHEN** a usage event is recorded for a reserved task
- **THEN** the reservation is released and the account reflects the actual usage rather than the projection

#### Scenario: Worker never reports
- **WHEN** a reservation reaches its time-to-live with no matching usage event
- **THEN** the reservation is released, the expiry is recorded, and the account's headroom is restored

### Requirement: Fair Share Across Tenants

When several tenants draw on a shared allowance, the portal SHALL allocate work
so that a tenant's cumulative admitted spend, relative to its configured weight,
determines its priority for the next admission. Every tenant SHALL retain a
configured minimum share of a shared allowance regardless of the demand of
others.

#### Scenario: One tenant floods the queue
- **WHEN** one tenant submits far more work than another against a shared allowance
- **THEN** the quieter tenant's next task is still admitted within its minimum share

#### Scenario: Equal weights, unequal spend
- **WHEN** two tenants have equal weight and one has consumed substantially more of the shared allowance
- **THEN** the tenant with less cumulative spend is admitted first

#### Scenario: Weighted tenants
- **WHEN** one tenant is configured with a higher weight
- **THEN** it is admitted proportionally more often than a lower-weighted tenant under sustained contention

### Requirement: Tenancy Is Enforced On Every Scheduling Surface

Routing, admission, usage reporting, and ranking readouts SHALL be scoped to the
actor's tenant. A caller SHALL NOT observe or consume another tenant's accounts,
reservations, usage events, or assignments.

#### Scenario: Cross-tenant read attempt
- **WHEN** an actor requests usage for an account outside its tenant
- **THEN** the request is refused and no figures from the other tenant are returned

#### Scenario: Assignment names only in-tenant accounts
- **WHEN** an assignment selects a funding account
- **THEN** the selected account belongs to the actor's tenant
