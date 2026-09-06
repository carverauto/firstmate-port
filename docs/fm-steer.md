# fm-steer

`fm-steer` is the firstmate-port CLI. It authenticates against a firstmate-port
instance with RFC 8628 device code and drives that instance's task inbox over
HTTP: `put`, `next`, `ack`, `list`. It never dials NATS — the Phoenix API is the
only JetStream client and the tenant wall.

This page is for firstmate captains running **stock** firstmate
(`kunchenguid/firstmate`). You do not need a fork of firstmate, a patched
`fm-send`, a `nats` CLI, or NATS credentials. You need the binary, one login, and
a standing instruction that tells firstmate to call it.

## Portal steering

Use the [importable portal-steering package](../integrations/firstmate/README.md)
to make stock firstmate and its crew read and acknowledge messages through the
portal. `fm-steer` itself does not wake terminals: after a successful crew put,
firstmate sends a constant doorbell with `bin/fm-send.sh`. Orders stay on the
portal; failed puts are reported, never sent through the on-disk inbox.

## 1. Point at an instance

Run one locally, or use a shared one:

```sh
cp .env.example .env
export SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker compose up --build
```

Open http://localhost:4000/login. With `LOCAL_AUTH=true` (the Compose default),
sign in with the bootstrap account, `admin@localhost` by default, and the
generated password printed once in `docker compose logs portal` on first boot.
[docs/deploy.md](deploy.md) covers compose, Kubernetes, and
`PUBLIC_URL` (the base the device-approval link is built from — set it whenever
the instance is not on localhost).

## 2. Build the binary

For installation and release downloads, see the
[README's CLI section](../README.md#fm-steer-cli). To build from this checkout
(Go 1.25+):

```sh
go build -o ~/.local/bin/fm-steer ./cmd/fm-steer
```

Bazel builds the same binary:

```sh
./tools/bazel build //:fm-steer     # bazel-bin/fm-steer_/fm-steer
```

Put it on the PATH of the machine firstmate runs on.

## 3. Log in

```sh
fm-steer auth login --instance http://localhost:4000
```

It prints a URL and a user code. Open the URL, sign in, confirm the code matches
what the CLI printed, and click **Approve** on `/login/device`. The CLI stores a
JWT at `$XDG_CONFIG_HOME/fm-steer/credentials.json` (`~/.config/fm-steer/` when
`XDG_CONFIG_HOME` is unset), mode `0600`, together with the instance URL and your
tenant. The token is good for 12 hours.

```sh
fm-steer auth status    # instance + tenant, exit 1 when not logged in
fm-steer auth logout    # removes the credentials file
```

`FIRSTMATE_INSTANCE` supplies the default for `--instance` on every command, so
`export FIRSTMATE_INSTANCE=https://portal.example.com` once and drop the flag.

Approval is a human step in a browser. Do not ask an agent to do it for you.

## 4. Commands

| Command | Flags | Result |
| --- | --- | --- |
| `inbox put` | `--task <id>` (defaults to `firstmate`), `--body <text>` (stdin when omitted) | Prints the stored item as JSON, including its `ack` token |
| `inbox next` | `--task <id>` (optional) | Prints the oldest pending item as JSON; exit 1 and no output when the inbox is empty |
| `inbox ack` | `--ack <token>` (required) | Marks that item handled; prints `acked` and exits 0 even when the portal rejected the token (`{"error":"not_found"}`), so confirm with `inbox list` |
| `inbox list` | `--task <id>` (optional) | Prints `{"data":[...]}` — everything pending or delivered-but-unacked |

Bodies may be multi-line; omit `--body` and pipe them in:

```sh
fm-steer inbox put --task fm-port-steer-docs <<'EOF'
Two things:
1. rebase on main
2. keep the PR draft
EOF
```

Items carry `schema=fm-task-inbox.v1` with `at`, `task`, `seq`, `body`,
`delivery`, `ack`, and `tenant`. `next` marks the item delivered-but-unacked: it
stays in `list` until it is acked, but `next` will not hand it out a second
time, so record the `ack` token when you take one.

## 5. Tell firstmate to use it

Install the [portal-steering package](../integrations/firstmate/README.md#install)
for the standing prompt, worker brief instructions, optional liaison, idempotent
enable, and uninstall back to stock operation.

If you imported this page's old mirror prompt, follow the package's
[migration instructions](../integrations/firstmate/README.md#migrate-from-the-old-mirror-prompt)
before installing.

Nothing polls on its own: firstmate checks when a session runs and you ask it.
Do not treat the portal inbox as a pager.

## 6. Seeing portal messages

- `fm-steer inbox list --task <id>` from any machine holding a token.
- The portal's **Queues** page (`/queues`) streams the fanout live: each `put`
  publishes to `<tenant>.steer.inbox` on your tenant's `<tenant>.steer` stream.

Your JWT carries your tenant, and the API scopes every inbox call to it; a
single-tenant install uses the seeded `local` tenant. The portal's pending set
is in memory, so restarting the portal loses pending and unacked items. There
is no automatic restoration.

## 7. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `not logged in; run fm-steer auth login` | No credentials file, or it has no token |
| `{"error":"unauthorized"}` | Token expired (12h) or the instance was rebuilt — log in again |
| `{"error":"invalid"}` from `put` | Empty body |
| `device code expired` | The approval page was not confirmed within 10 minutes |
| `inbox next` exits 1 silently | Nothing pending; this is the normal empty case |
| Connection refused | Wrong `--instance` / `FIRSTMATE_INSTANCE`, or the portal is not up |

## About the Carverauto fork

Name collision, nothing more. Carverauto's private firstmate overlay has its own
`fm-steer`: a bash dual-write onto NATS from a patched `fm-send`. It is an
optional overlay, not a prerequisite for anything on this page, and it is not
what this repo ships.

The product CLI is the Go `fm-steer` in `cmd/fm-steer`; it speaks HTTP to the
portal and nothing else. The importable package configures portal
steering without forking firstmate.
