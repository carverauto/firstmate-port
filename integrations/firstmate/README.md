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
reversible in one command.

It augments stock firstmate; it does not replace or fork it. No patched
`fm-send`, no forked firstmate, no NATS credentials on the fleet host. The
portal is the only JetStream client.

## What's in here

| File | What it is |
| --- | --- |
| `install.sh` | Idempotent install / status / uninstall |
| `captain-block.md.tmpl` | The standing prompt, as a copy-paste template |
| `skills/portal-steering/SKILL.md` | The skill: procedures, brief text, second mate, uninstall |
| `skills/portal-steering/secondmate-charter.md` | Charter for the optional liaison second mate |
| `install_test.sh` | Proves the idempotency and uninstall claims below |

Two artifacts, because they carry different weight. The **captain block** is
always-on: it goes into `data/captain.md`, which firstmate reads into every
session's startup digest, and it stays short because that digest has a budget.
The **skill** is the long form - exact recipes, the brief section text, the
liaison charter, troubleshooting - read when it is actually needed.

## Install

You need `fm-steer` on PATH and a portal to point at:

```sh
go build -o ~/.local/bin/fm-steer ./cmd/fm-steer     # from a firstmate-port checkout
fm-steer auth login --instance https://portal.example.com
```

The login is a device-code approval in a browser: it is the operator's step, not
an agent's. One login covers the whole host - firstmate and every crewmate it
spawns run as the same user and share `~/.config/fm-steer/credentials.json`.

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
| `--ring yes\|no` | Whether firstmate rings a crewmate's terminal after a portal put (default `yes`) |
| `--secondmate <id>` / `--no-secondmate` | Record which second mate owns the portal channel (default: none) |
| `--skills-dir <abs dir>` | Also copy the skill into a harness skills directory |

`install.sh status` prints what is installed and what it is set to.

Prefer to do it by hand? Copy `captain-block.md.tmpl` into `$FM_HOME/data/captain.md`
and replace `@@INSTANCE@@`, `@@RING@@`, and `@@SECONDMATE@@`. Keep the two HTML
comment markers exactly as they are - they are what makes a later install or
uninstall replace the block instead of stacking another one.

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
gitignored, for the same reason. `--skills-dir` is the escape hatch for a
harness skills directory that lives outside the checkout, such as
`~/.claude/skills`.

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

It **may** drain the portal, hand orders to the first mate, and put notices back.

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

That removes exactly three things:

1. the marker block from `$FM_HOME/data/captain.md`, leaving the rest of the
   file byte-identical to what it was before install (and deleting the file only
   if the block was its entire content);
2. `$FM_HOME/data/portal-steering/` - the skill, the charter, and the settings;
3. the copy under `--skills-dir`, if one was installed there.

Then, by hand:

- Retire the liaison second mate if you enabled one: `bin/fm-teardown.sh <id>`.
- In any brief of a task still in flight, restore the stock
  `# Firstmate instruction inbox` section - the `bin/fm-brief.sh` text pointing
  at `state/<id>.inbox/` with the `mv <file> handled/` acknowledgement. New
  briefs are stock again on their own, because the generator was never patched.
- Tell any running crewmate, once, that the on-disk inbox is live again.
- Optionally `fm-steer auth logout`.

**Nothing has to be put back for stock operation to resume.** `bin/fm-send.sh`,
`bin/fm-inbox.sh`, `state/<id>.inbox/`, and the `handled/` move were never
modified, disabled, or moved - they simply went unused while the block was
present. Portal items still sitting unacked stay on the portal;
`fm-steer inbox list` shows them, and you can drain or ignore them.

## Tests

```sh
integrations/firstmate/install_test.sh
```

Runs in a temporary directory against throwaway homes and touches no real
firstmate home. CI runs it on every push.
