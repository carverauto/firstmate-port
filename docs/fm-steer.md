# fm-steer

`fm-steer` is the captain CLI. It talks only to the firstmate-port HTTP API
(device-code auth, inbox, routing, usage). It never dials NATS JetStream:
the portal API is the tenant wall and the only JetStream client.

The only Go in this repo is `fm-steer`, so it ships as a portable binary.
Everything it decides comes from the portal; ranking, quota math, and
provider keys stay server-side.

## Install

```sh
go build -o fm-steer ./cmd/fm-steer
# or: bazel --output_base=/tmp/fm-fm-port/bazel build //:fm-steer
```

## Auth

Device-code login stores a JWT at `$XDG_CONFIG_HOME/fm-steer/credentials.json`
(mode 0600). Every command below uses it.

```sh
fm-steer auth login --instance http://localhost:4000
fm-steer auth status
fm-steer auth logout
```

`FIRSTMATE_INSTANCE` sets the default instance so `--instance` can be omitted.

## Inbox

```sh
fm-steer inbox put --task fm-port --body "hello"
fm-steer inbox next --task fm-port
fm-steer inbox ack --ack <token>
fm-steer inbox list
```

## Route

Ask the portal router which worker to use for a task. The answer carries
harness, model, effort, and why. See `docs/routing.md` for the axes and the
capability matrix.

```sh
fm-steer route "fix the failing test in the ingest controller"
fm-steer route --intel "compare current embedding models for our docs search"
echo "deploy the portal to production" | fm-steer route
```

`--intel` folds in live OpenRouter / Artificial Analysis inputs. Without it
routing is fully offline on the fleet matrix plus the bundled eval set.
`--json` prints the full route response for scripts and rater agents.

## Usage

Show per-account token usage and remaining allowance from the portal ledger.
See `docs/usage.md` for windows, spend priority, and runway.

```sh
fm-steer usage
fm-steer usage --sync
fm-steer usage --json
```

`--sync` asks the portal to refresh syncable accounts first (provider keys
stay server-side; only configured providers refresh, the rest report why
they were skipped), then prints the refreshed ledger. With `--json` the
refresh notes are omitted and only the ledger is printed.

## Tenancy

Credentials carry the tenant from login. Every request is scoped to that
tenant by the API; there is no flag to read another tenant.
