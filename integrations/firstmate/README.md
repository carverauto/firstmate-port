# Portal steering for firstmate

An importable package that points a stock [firstmate](https://github.com/kunchenguid/firstmate)
fleet at a firstmate-port portal, so the fleet's messages live in the portal
instead of in inbox files on the fleet host.

Stock firstmate passes messages as files: `bin/fm-send.sh` writes a numbered
record into `state/<id>.inbox/`, and the worker acknowledges it by moving that
file into `handled/`. That works, and it keeps working - but it is only readable
from that one machine. With this package installed, the message body and its
acknowledgement go through the `fm-steer` CLI to your portal, so a steer, a
completion notice, or a captain's order is visible from a phone, from another
laptop, or from anything else holding a token.

Nothing else about firstmate changes. Spawning, supervision, status files,
worktrees, briefs, and merges are untouched. This is a transport swap, and it is
reversible using the uninstall procedure below.

It augments stock firstmate; it does not replace or fork it. No patched
`fm-send`, no forked firstmate, no NATS credentials on the fleet host. The
portal is the only JetStream client.

## What's in here

| File | What it is |
| --- | --- |
| `install.sh` | Idempotent install / status / uninstall |
| `captain-block.md.tmpl` | Standing prompt template rendered by the installer |
| `skills/portal-steering/SKILL.md` | The skill: procedures, brief text, second mate, uninstall |
| `skills/portal-steering/secondmate-charter.md` | Charter for the optional liaison second mate |
| `install_test.sh` | Proves the idempotency and uninstall claims below |

Two artifacts, because they carry different weight. The **captain block** is
always-on: it goes into `data/captain.md`, which firstmate reads into every
session's startup digest, and it stays short because that digest has a budget.
The **skill** is the long form - exact recipes, the brief section text, the
liaison charter, troubleshooting - read when it is actually needed.

The portal inbox is in memory: restarting the portal loses pending and unacked
items, with no automatic restoration. Failed puts must be reported and stopped;
orders never fall back to disk. Every successful crew put gets the ordinary
`fm-send.sh` doorbell, carrying no order body.

## Migrate from the old mirror prompt

Before installing, edit `$FM_HOME/data/captain.md` and remove the previously
imported `## Portal mirror (fm-steer)` section from `docs/fm-steer.md`, including
all its bullets and nested command example. Also remove its optional companion
block beginning "When I ask you to check the portal" through its final ack
confirmation bullet. Preserve unrelated captain preferences. These old blocks
have no installer markers, so the installer cannot remove them for you. The new
portal-steering block must be the only live-delivery rule.

## Install

You need `fm-steer` on PATH and a portal to point at:

```sh
go build -o ~/.local/bin/fm-steer ./cmd/fm-steer     # from a firstmate-port checkout
fm-steer auth login --instance https://portal.example.com
```

The login is a device-code approval in a browser: it is the operator's step, not
an agent's. Firstmate and its crewmates share that login when they use the same
credentials location. See the [CLI login guide](../../docs/fm-steer.md#3-log-in)
for credential storage and the `XDG_CONFIG_HOME` override.

The installer migrates no existing inbox messages. Before enabling portal
delivery for an existing task, pause new steers and reconcile outstanding stock
orders in `state/<id>.inbox/` with its worker and the captain. Confirm each was
acted on and acknowledged under the stock procedure or explicitly cancelled by
the captain. Leave uncertain records untouched and postpone that task's switch;
do not assume they have portal copies. Once reconciled, replace the task's brief
using the skill's instructions and tell the worker portal delivery is active.
Only the exact constant doorbell body for that task may be cleared as a doorbell.

Then, from a firstmate-port checkout:

```sh
integrations/firstmate/install.sh install \
  --fm-home "$FM_HOME" \
  --instance https://portal.example.com
```

Options:

| Flag | Effect |
| --- | --- |
| `--instance <url>` | Your portal. Required on the first install; remembered after that |
| `--secondmate <id>` / `--no-secondmate` | Record which second mate owns the portal channel (default: none) |

`install.sh status` prints what is installed and what it is set to.

Use `install.sh` for every import so the captain block, skill, and charter are
installed together.

### Where it installs, and why not somewhere else

Everything lands under `$FM_HOME/data/`, which stock firstmate gitignores:

```
$FM_HOME/data/captain.md                          one marker-delimited block
$FM_HOME/data/portal-steering/SKILL.md            the skill
$FM_HOME/data/portal-steering/secondmate-charter.md
$FM_HOME/data/portal-steering/settings.env        what install was last told
```

Do **not** hand-copy the skill into `$FM_HOME/.agents/skills/`, tempting as that
is - it is firstmate's own skill directory, but it is tracked. An untracked
directory there makes the checkout dirty, and firstmate's fast-forward
self-update skips a dirty home, so that home would quietly stop updating
forever. `install.sh` refuses to install into a checkout where `data/` is not
gitignored, for the same reason.

## What changes, in one table

| Message | Stock firstmate | With this installed |
| --- | --- | --- |
| captain → firstmate | `bin/fm-inbox.sh note <text>` | `fm-steer inbox put` (no `--task`; key `firstmate`) |
| firstmate → crewmate | `bin/fm-send.sh <id> <text>` | `fm-steer inbox put --task <id>` |
| crewmate reads it | list `state/<id>.inbox/*.msg` | `fm-steer inbox next --task <id>` |
| crewmate acknowledges | `mv <file> handled/` | `fm-steer inbox ack --ack <token>` |
| crewmate → firstmate | `state/<id>.status` line | unchanged - status files stay on disk |

Status files stay on disk deliberately. A status line is a wake event the
watcher reads locally, not a message, and routing a supervision loop through an
HTTP call would be a worse system.

There is one portal inbox; task keys partition it. A bare `put` with no `--task`
files under the key `firstmate` - a message for the first mate itself. Do not
stand up a second portal channel or a mirror queue.

## The optional second mate

Off unless you ask for it, and independent of everything above.

A **portal liaison** is an ordinary firstmate second mate - a persistent direct
report with its own isolated `FM_HOME` - given one narrow job: carry orders from
the portal to the first mate, and carry completion notices back. It exists so
the portal channel has an owner that is never mid-turn on fleet work.

It **may** drain inbound orders under `firstmate`, relay through its parent
channel, and put notices under `captain`. While enabled, the liaison alone reads
`firstmate`; otherwise firstmate reads it. The captain writes orders with
`fm-steer inbox put --task firstmate`, reads notices with
`fm-steer inbox next --task captain`, and acknowledges after reading. Neither
firstmate nor the liaison consumes `captain`. Crew continue using their work item
keys.

It **may not** run the fleet, dispatch or spawn crewmates, take project work, or
merge anything. An order it cannot relay goes back to the captain as a notice.

`skills/portal-steering/secondmate-charter.md` is the charter to seed it with;
your firstmate's own `secondmate-provisioning` skill owns the exact provisioning
sequence. Record the choice with `install.sh install --secondmate <id>` so the
standing block says who owns the channel. Retire it with
`bin/fm-teardown.sh <id>`, then `install.sh install --no-secondmate`.

The installer never seeds or retires a second mate - it only records which one
owns the channel - so re-running it can never duplicate or orphan one.

## Idempotency

Installing twice is the same as installing once:

- `data/captain.md` gets exactly **one** block, between
  `<!-- BEGIN firstmate-port portal-steering -->` and its matching `END`. A
  re-run replaces what is between the markers in place. It never appends a
  second block and never edits a line outside them, so conflicting standing
  instructions cannot accumulate in the captain's context.
- `data/portal-steering/` is owned by the installer and its files are
  overwritten by name.
- Omitted flags keep the recorded settings; changing one replaces that line
  rather than stacking a second one. Change settings by re-running install, not
  by hand-editing the block - hand edits are lost on the next run, which is the
  point.
- A `captain.md` that somehow holds two blocks is a refusal, not a guess. Fix it
  by hand and re-run.

`install_test.sh` asserts all of this, including that installing three times
leaves the file byte-identical to installing once.

## Uninstall - back to stock

```sh
integrations/firstmate/install.sh uninstall --fm-home "$FM_HOME"
```

That removes exactly two things:

1. the marker block from `$FM_HOME/data/captain.md`, leaving the rest of the
   file byte-identical to what it was before install (and deleting the file only
   if the block was its entire content);
2. `$FM_HOME/data/portal-steering/` - the skill, the charter, and the settings.
   Operator-added files and the directory holding them remain.

Then, by hand:

- Retire the liaison second mate if you enabled one: `bin/fm-teardown.sh <id>`.
- In any brief of a task still in flight, restore the stock
  `# Firstmate instruction inbox` section - the `bin/fm-brief.sh` text pointing
  at `state/<id>.inbox/` with the `mv <file> handled/` acknowledgement. New
  briefs are stock again on their own, because the generator was never patched.
- Tell any running crewmate, once, that the on-disk inbox is live again.
- Optionally `fm-steer auth logout`.

**Complete the manual steps above before resuming stock delivery to running workers.** `bin/fm-send.sh`,
`bin/fm-inbox.sh`, `state/<id>.inbox/`, and the `handled/` move were never
modified, disabled, or moved - they simply went unused while the block was
present. Portal items still sitting unacked stay on the portal;
`fm-steer inbox list` shows them, and you can drain or ignore them.

## Tests

```sh
integrations/firstmate/install_test.sh
```

Runs in a temporary directory against throwaway homes and touches no real
firstmate home. See the [CI workflow](../../.github/workflows/ci.yml) for automated runs.
