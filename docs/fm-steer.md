# fm-steer

`fm-steer` is the firstmate-port CLI. It authenticates against a firstmate-port
instance with RFC 8628 device code and drives that instance's task inbox over
HTTP: `put`, `next`, `ack`, `list`. It never dials NATS — the Phoenix API is the
only JetStream client and the tenant wall.

This page is for firstmate captains running **stock** firstmate
(`kunchenguid/firstmate`). You do not need a fork of firstmate, a patched
`fm-send`, a `nats` CLI, or NATS credentials. You need the binary, one login, and
a standing instruction that tells firstmate to call it.

## What it is not

`fm-steer inbox put` does **not** steer a worker. In stock firstmate the steer
is `bin/fm-send.sh`, and the durable record is the task's on-disk inbox under
`state/<id>.inbox/`, which the worker acknowledges by moving the message into
`handled/`. Nothing in firstmate-port reads or writes those files.

`fm-steer` adds a second, portal-side copy of the same text so the steer is
visible in the portal (and to anything else holding a token for your tenant).
Mirror after the send; never in place of it.

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

There are no prebuilt downloads; build from this repo (Go 1.25):

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
| `inbox put` | `--task <id>` (required), `--body <text>` (stdin when omitted) | Prints the stored item as JSON, including its `ack` token |
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

Stock firstmate has no post-`fm-send` hook, and it does not need one: firstmate
is an agent, so ask it. Put the block below in `data/captain.md` in your
firstmate home (`$FM_HOME`) — that file is gitignored and firstmate reads it into
the session-start context digest, so the instruction survives restarts. For one
session only, pasting it into chat works the same way.

Replace `<INSTANCE_URL>` with your portal:

````markdown
## Portal mirror (fm-steer)

- My firstmate-port portal is <INSTANCE_URL>. `fm-steer` is on PATH and logged in.
- After a steer originating locally from me succeeds through `bin/fm-send.sh`,
  mirror the same text to the portal by piping the body in on stdin with a
  quoted heredoc. Never mirror portal-origin deliveries: a body obtained from
  `fm-steer inbox next` must not be put back with `fm-steer inbox put`.

  ```sh
  fm-steer inbox put --task <task-id> <<'FMSTEER'
  <the same text I sent, verbatim>
  FMSTEER
  ```

  Never pass the text with `--body "..."`. Steers are routinely multi-line and
  contain quotes, backticks, and `$`, all of which the shell would mangle or
  expand; the quoted heredoc sends exactly what I sent.
- Keep the returned mirror item's `ack` and `task` associated with the successful
  local send in the captain's notes. This copy enters the portal's pending queue
  even though it was already delivered locally; a later portal check must not
  send it again.
- Mirror after the on-disk enqueue, never instead of it. `state/<id>.inbox/` is
  the delivery record; fm-steer is only a copy for the portal. Never delete,
  move, or edit anything under `state/<id>.inbox/` because of fm-steer.
- A failing `fm-steer` call is a notice, not a failed steer. Say so in one line
  and carry on. Do not resend `fm-send` over it.
- If it prints `not logged in` or `{"error":"unauthorized"}`, tell me and stop
  using it. The device-code approval is mine to do in a browser; do not attempt
  to log in on my behalf.
- `fm-steer` speaks HTTP to the portal only. Never give it a NATS URL, NATS
  credentials, or a token on the command line.
````

Add this second block if you also want firstmate to pick up steers you filed
from another machine (from a phone, from a laptop away from the fleet):

```markdown
- When I ask you to check the portal, discover the items with
  `fm-steer inbox list` (optionally `--task <id>` for a task I name). Use each
  item's `task` field to identify its destination. For explicitly named tasks,
  or each task in the fleet, call `fm-steer inbox next --task <id>` to take a
  pending item. Always pass `--task`; never take an item across all tasks.
  Exit 1 with no output means nothing is pending for that task, not the fleet.
- If an item is a confirmed mirror of a successful local send, acknowledge it
  without sending it again. Use the saved mirror `ack` and `task` and the local
  delivery record to confirm this; identical body text alone is not proof.
  If prior delivery is uncertain, report the item for me to resolve instead of
  guessing, resending, or acknowledging it.
- For a new portal steer, deliver the returned item's `body` with
  `bin/fm-send.sh` to the task named in the item's own `task` field, and only
  after that send succeeds run
  `fm-steer inbox ack --ack <the item's ack>`. Never ack something you have not
  delivered. Never mirror this portal-origin delivery back with `inbox put`.
- `fm-steer inbox ack` prints `acked` even when the portal rejected the token, so
  confirm with `fm-steer inbox list --task <the item's task>` that the item is gone.
```

Nothing polls on its own — firstmate checks when a session runs and you ask it
to. Do not treat the portal inbox as a pager.

## 6. Seeing the mirror

- `fm-steer inbox list --task <id>` from any machine holding a token.
- The portal's **Queues** page (`/queues`) streams the fanout live: each `put`
  publishes to `<tenant>.steer.inbox` on your tenant's `<tenant>.steer` stream.

Your JWT carries your tenant, and the API scopes every inbox call to it; a
single-tenant install uses the seeded `local` tenant. The portal's pending set
is in-memory, so restarting the portal clears it — another reason the on-disk
inbox stays the record of what was steered.

## 7. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `not logged in; run fm-steer auth login` | No credentials file, or it has no token |
| `{"error":"unauthorized"}` | Token expired (12h) or the instance was rebuilt — log in again |
| `{"error":"invalid"}` from `put` | Empty `--task` or empty body |
| `device code expired` | The approval page was not confirmed within 10 minutes |
| `inbox next` exits 1 silently | Nothing pending; this is the normal empty case |
| Connection refused | Wrong `--instance` / `FIRSTMATE_INSTANCE`, or the portal is not up |

## About the Carverauto fork

Name collision, nothing more. Carverauto's private firstmate overlay has its own
`fm-steer`: a bash dual-write onto NATS from a patched `fm-send`. It is an
optional overlay, not a prerequisite for anything on this page, and it is not
what this repo ships.

The product CLI is the Go `fm-steer` in `cmd/fm-steer`; it speaks HTTP to the
portal and nothing else. A standing instruction, as above, gets you the portal
mirror without forking firstmate or replacing `fm-send`.
