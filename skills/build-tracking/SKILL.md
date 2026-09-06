---
name: build-tracking
description: Use when about to run or trigger a build or deployment - docker build/push, kubectl apply, helm upgrade/rollback, bazel build, compose up, or any other build/deploy system. Records the run in firstmate-port with `fm-steer build start` before the work and `fm-steer build finish` after it, reporting who ran it, on what model and effort, and how many tokens it cost.
---

# Build and deployment tracking

Every build and deployment you perform gets two rows in the portal's
append-only build log: one when it starts, one when it ends. You take the
initiative - nothing watches your shell, so a run you do not report is a run
nobody can see.

## The loop

**1. Before the build or deployment starts**

```sh
fm-steer build start \
  --kind docker \
  --target firstmate-port \
  --agent-id "$FIRSTMATE_AGENT_ID" \
  --model opus-5 --effort high
```

It prints JSON. Keep the `run_id` - the finish call needs it:

```json
{"id":"k7m2p9","run_id":"run-3f9a1c7e5b2d4a08","kind":"docker","status":"started","url":"..."}
```

**2. Run the build or deployment.**

**3. When it ends - success or failure**

```sh
fm-steer build finish \
  --run-id run-3f9a1c7e5b2d4a08 \
  --status success \
  --tokens 48210 \
  --outcome "pushed ghcr.io/OWNER/firstmate-port:sha-deadbeef"
```

`--status` is `success`, `failure`, or `cancelled`. **Always finish the run**,
including when the build fails - `--status failure` with the reason in
`--outcome` is the record. An unfinished run shows as still running forever.

## What to report

| Flag | Say |
|---|---|
| `--kind` | the build or deploy system: `docker`, `k8s`, `helm`, `bazel`, `compose`, `nix`, ... Lowercase, one word. Required on `start`. |
| `--target` | what is built or deployed: an image name, a chart, a Bazel label. |
| `--agent-id` | which agent did the work. Your own id, not the human's. |
| `--model` / `--effort` | the model you are running as and its reasoning effort. |
| `--tokens` | tokens the run cost you, **cumulative for the whole run**, on the finish call. Omit it when you cannot count them; never guess. |
| `--image` / `--image-tag` | for container work: repository and tag. |
| `--cluster` / `--namespace` | for cluster work. |
| `--started-at` / `--finished-at` | RFC 3339 timestamps on `start` / `finish`, respectively. Each defaults to the current UTC time; override it when reporting work that already started or finished. |

`finish` requires `--run-id`; `--status` defaults to `success`, so explicitly
set it for failures or cancellations. The API carries the rest of the
run's context forward from the start event, so repeat a field only to correct
or add to it.

## Setup

Ingest writes need an agent role. Export once per session:

```sh
export FIRSTMATE_INSTANCE=https://firstmate.example.com   # your portal
export FIRSTMATE_AGENT_TOKEN=...                          # agent API token
export FIRSTMATE_AGENT_ID=crew-7
export FIRSTMATE_MODEL=opus-5
export FIRSTMATE_EFFORT=high
```

`FIRSTMATE_AGENT_ID`, `FIRSTMATE_MODEL`, and `FIRSTMATE_EFFORT` become the
defaults for `--agent-id`, `--model`, and `--effort` on `start`. On `finish`,
these fields are sent only when explicitly supplied as flags. Without `FIRSTMATE_INSTANCE` the CLI uses the
host from `fm-steer auth login`, then `http://localhost:4000`.

Install the CLI with `go install
github.com/mfreeman451/firstmate-port/cmd/fm-steer@latest`, or take a release
binary. Install this skill by copying its directory into your agent's skills
directory (`~/.claude/skills/build-tracking/` for Claude Code).

## Rules

- **Report, do not block.** If `fm-steer` cannot reach the portal, say so and
  carry on with the build. Tracking never gates a deployment.
- **One run, one `run_id`.** Reuse the id from `start`; do not invent a second
  one for the same build. Let `start` generate it unless your wrapper already
  has a natural id (a CI run id, a pipeline id) to pass to `--run-id`.
- **Never rewrite history.** The log is append-only. To correct or extend a
  run, post another event with the same `run_id`; the dashboard folds a run's
  events into one row, newest report winning.
- **No secrets in `--outcome`.** It is displayed in the portal. Registry
  credentials, kubeconfigs, and tokens stay out of every flag.
