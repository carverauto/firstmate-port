## ADDED Requirements

### Requirement: Tasks Are Classified On Axes

The portal SHALL classify a task description onto the axes `kind`,
`ambiguity`, `blast_radius`, `risk`, `citations_required`, and
`live_web_required`. `kind` SHALL be one of `code`, `research`, `ops`, `docs`,
`review`, `data`, or `chat`; `ambiguity`, `blast_radius`, and `risk` SHALL each
be `low`, `medium`, or `high`. Classification SHALL be deterministic and SHALL
run without network access or a provider API key.

#### Scenario: Code review task
- **WHEN** a description asks for a pull request to be reviewed
- **THEN** kind is `review`

#### Scenario: Production deployment
- **WHEN** a description asks to deploy to production and run a migration
- **THEN** kind is `ops` and blast radius is `high`

#### Scenario: Offline classification
- **WHEN** classification runs with no network and no provider keys configured
- **THEN** axes are still returned

#### Scenario: Description is missing or not text
- **WHEN** a route request carries no description, or a description that is not text
- **THEN** the request is rejected with a client error naming the missing field, and no server error is raised

### Requirement: Difficulty Score

The portal SHALL derive a difficulty score in the range 0.0 to 1.0 from the
classified axes, and SHALL return it with the axes that produced it. Difficulty
SHALL rise with ambiguity, blast radius, and risk, and SHALL be reported
alongside the reasons for its value.

#### Scenario: Simple well-specified task
- **WHEN** a task is low ambiguity, low blast radius, and low risk
- **THEN** difficulty is at the low end of the range

#### Scenario: Ambiguous high-risk task
- **WHEN** a task is high ambiguity and high risk
- **THEN** difficulty is at the high end of the range
- **AND** the axes that raised it are named in the reasons

### Requirement: Credential Handling Is Distinguished From Credential-Adjacent Code

The portal SHALL classify a task as high risk when a credential-handling verb
governs a credential object, and SHALL NOT classify a task as high risk merely
because a credential noun appears in the name of code under repair. Distinct
literal substring lists SHALL NOT be the sole mechanism.

#### Scenario: Storing a credential
- **WHEN** the description is to store an API token in a vault
- **THEN** risk is `high`

#### Scenario: Moving a credential
- **WHEN** the description is to move an API token between configuration stores
- **THEN** risk is `high`

#### Scenario: Fixing a test that names a credential type
- **WHEN** the description is to fix a failing test for the auth token parser
- **THEN** risk is not raised to `high` by the phrase `auth token` alone
- **AND** the task routes as ordinary code work

### Requirement: Projected Usage For A Task

The portal SHALL return, for each routing decision, a projected usage envelope
containing expected tokens, expected cost in the funding account's unit, and a
confidence indicator. Projections SHALL be derived from the task's kind,
difficulty, and assigned effort against a calibration table, and SHALL be
labelled as estimates. When no calibration data supports a projection, the
system SHALL report low confidence rather than omitting the projection.

#### Scenario: Projection accompanies a route
- **WHEN** a task is routed
- **THEN** the response carries expected tokens, expected cost, and a confidence indicator

#### Scenario: Uncalibrated task shape
- **WHEN** no recorded actuals exist for the task's kind and effort bucket
- **THEN** the projection is returned with low confidence and a conservative estimate

#### Scenario: Projection is never presented as a bill
- **WHEN** a projection is rendered in the API or the usage view
- **THEN** it is labelled an estimate and is visually distinct from recorded actuals

### Requirement: Calibration Learns From Recorded Actuals

The calibration table SHALL be updated from recorded usage events, bucketed by
task kind and effort, so that projections converge on observed cost. Calibration
SHALL be resistant to single outliers.

#### Scenario: Repeated observations shift the estimate
- **WHEN** many usage events are recorded for a kind and effort bucket at a cost well above the seeded default
- **THEN** subsequent projections for that bucket rise toward the observed cost

#### Scenario: One extreme outlier
- **WHEN** a single usage event records a cost far outside the bucket's observed distribution
- **THEN** the bucket's projection is not moved substantially by that one event

### Requirement: Axis Overrides From A Rater Agent

The portal SHALL accept per-request axis and difficulty overrides so that a
separate rating agent can supply a judgement. Overrides SHALL be validated
against the allowed values and rejected when invalid. Overrides SHALL NOT
change lane constraints and SHALL NOT change a hard route. The provenance of
each axis SHALL be recorded as `heuristic`, `agent`, or `human`.

#### Scenario: Valid override accepted
- **WHEN** a request supplies ambiguity `high` as an override
- **THEN** routing uses ambiguity `high` and records that axis provenance as supplied

#### Scenario: Invalid override rejected
- **WHEN** a request supplies a kind that is not a known kind
- **THEN** the override is rejected and the heuristic classification is used for that axis

#### Scenario: Override cannot bypass the hard route
- **WHEN** a request classified as kind `review` supplies overrides intended to select a cheaper harness
- **THEN** the assignment remains the hard-routed harness and model

### Requirement: The Fleet Eval Set Is The Regression Gate

The portal SHALL maintain an internal eval set pinning task descriptions to
expected assignments, and the test suite SHALL fail when any case regresses. A
change to classification, ranking, or the capability matrix SHALL be accompanied
by eval cases covering the behaviour it changes, and a real-world misroute SHALL
be added to the eval set before the classifier is amended.

#### Scenario: Regression fails the suite
- **WHEN** a classifier change causes an eval case to route to a different harness than expected
- **THEN** the test suite fails and names the case, the expectation, and the actual assignment

#### Scenario: Misroute is captured before the fix
- **WHEN** a real task is found to have been misrouted
- **THEN** a scrubbed eval case for it exists before the classifier change that addresses it

#### Scenario: Evals run offline
- **WHEN** the eval set runs with no network and no provider keys
- **THEN** every case is evaluated
