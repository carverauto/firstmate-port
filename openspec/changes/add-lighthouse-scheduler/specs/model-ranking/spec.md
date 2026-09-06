## ADDED Requirements

### Requirement: Ranking Runs In The Portal API

Model ranking, the capability matrix, and quota arithmetic SHALL live in the
Elixir portal. Client programs, including the `fm-steer` CLI, SHALL NOT
implement ranking, hold a capability matrix, compute quota, or hold provider
API keys. Clients SHALL obtain assignments by calling the portal API.

#### Scenario: CLI asks for a route
- **WHEN** the CLI is asked to route a task
- **THEN** it sends the description to the portal API and prints the returned assignment

#### Scenario: CLI cannot reach the portal
- **WHEN** the portal API is unreachable
- **THEN** the CLI reports the failure and exits non-zero
- **AND** it does not fall back to a locally computed assignment

### Requirement: Ranking Combines Multiple Independent Sources

Model ranking SHALL combine several independent inputs, which MAY include
Artificial Analysis, LMArena, LiveBench, the Hugging Face Open LLM Leaderboard,
and task-specific benchmarks such as SWE-bench, BrowseComp, and GAIA. Each contributing source SHALL be normalized per axis and recorded with
its identity and observation time. A single public leaderboard SHALL NOT
determine an assignment.

#### Scenario: Several sources available
- **WHEN** more than one ranking source has fresh data for a model
- **THEN** the model's score combines them and the response names every source used

#### Scenario: Only one source available
- **WHEN** exactly one public source has fresh data
- **THEN** its contribution is capped, the assignment still respects the capability matrix and eval set, and the response states that ranking input was limited

#### Scenario: No source available
- **WHEN** no ranking source has fresh data
- **THEN** routing proceeds on the capability matrix and eval set alone and the response states that no ranking input was used

### Requirement: No Single Source May Dominate

No individual public source SHALL contribute more than a configured maximum
share of the combined weight for any axis. The fleet's own eval set SHALL NOT be
capped and SHALL take precedence over public sources when they disagree.

#### Scenario: One source would otherwise dominate
- **WHEN** one source supplies far more data points than the others for an axis
- **THEN** its combined weight for that axis does not exceed the configured cap

#### Scenario: Public source disagrees with the fleet eval set
- **WHEN** a public source ranks a model above the lane that the eval set pins for a task shape
- **THEN** the eval set's expectation governs and the test suite enforces it

### Requirement: Popularity Is Not Capability

Popularity, download counts, and usage-share metrics SHALL be treated as
metadata only and SHALL NOT contribute to a model's capability score.

#### Scenario: Popular but weaker model
- **WHEN** a source reports a model as the most used while capability sources rank it lower for the task's axis
- **THEN** popularity does not raise its capability score

#### Scenario: Popularity shown as metadata
- **WHEN** popularity data is available
- **THEN** it may be displayed as metadata and is labelled as such

### Requirement: Source Freshness And Provenance

Every stored ranking score SHALL carry its source and observation time. A source
whose data is older than its configured time-to-live SHALL be excluded from the
combination, and the exclusion SHALL be reported with the assignment.
Time-to-live SHALL be configurable per source rather than a single global value.

#### Scenario: Stale source excluded
- **WHEN** a source's most recent observation is older than its configured time-to-live
- **THEN** it is excluded from the score and named as excluded in the response

#### Scenario: Provenance is reported
- **WHEN** an assignment is returned
- **THEN** it names the ranking sources used and the time each was observed

### Requirement: Ranking Fetches Do Not Block Routing

Ranking data SHALL be gathered by a background job and stored. A routing request
SHALL read stored scores and SHALL NOT depend on a live call to an external
ranking source. Failures to fetch SHALL NOT fail a routing request.

#### Scenario: External source is down during a route
- **WHEN** a ranking source is unreachable while a routing request is served
- **THEN** the request succeeds using stored scores or the matrix alone

#### Scenario: Background refresh fails
- **WHEN** a scheduled ranking refresh fails
- **THEN** the failure is recorded, previously stored scores are retained, and routing continues

### Requirement: Ranking Refines The Model Within A Lane

Ranking SHALL be applied to select a model within a lane that the capability
matrix has already admitted. Ranking SHALL NOT admit a lane that the matrix
excluded on a hard constraint, and SHALL NOT override a hard route.

#### Scenario: Ranking prefers an excluded lane
- **WHEN** ranking scores a model highest but its lane was excluded because the task requires live web access the lane lacks
- **THEN** that lane remains excluded

#### Scenario: Ranking within the admitted lane
- **WHEN** several models are available inside the admitted lane
- **THEN** ranking chooses among them and the reason names the scores that decided it
