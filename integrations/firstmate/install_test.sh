#!/usr/bin/env bash
# install_test.sh - prove the two properties the portal-steering installer
# claims: installing twice is the same as installing once, and uninstalling
# returns the home to exactly what it was before.
#
# Runs entirely in a temporary directory. Touches no real firstmate home.
#
#   integrations/firstmate/install_test.sh
set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
INSTALL="$SELF_DIR/install.sh"
INSTANCE='http://localhost:4000'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/portal-steering-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want [$1], got [$2])"; fi; }

# A throwaway firstmate home: a git work tree with data/ gitignored, like stock.
new_home() {
  local home="$WORK/$1"
  mkdir -p "$home/data"
  git -C "$home" init -q
  printf 'data/\nstate/\n' > "$home/.gitignore"
  git -C "$home" add .gitignore >/dev/null
  git -C "$home" -c user.email=t@e -c user.name=t commit -qm init >/dev/null
  printf '%s' "$home"
}

blocks_in() { grep -Fxc '<!-- BEGIN firstmate-port portal-steering -->' "$1" 2>/dev/null || true; }

printf 'portal-steering installer\n'

# -- install is idempotent ---------------------------------------------------

HOME1=$(new_home home1)
cat > "$HOME1/data/captain.md" <<'PRE'
# Captain preferences

- I like short status lines.
PRE
cp "$HOME1/data/captain.md" "$WORK/captain.before"

"$INSTALL" install --fm-home "$HOME1" --instance "$INSTANCE" >/dev/null
cp "$HOME1/data/captain.md" "$WORK/captain.once"

"$INSTALL" install --fm-home "$HOME1" --instance "$INSTANCE" >/dev/null
"$INSTALL" install --fm-home "$HOME1" --instance "$INSTANCE" >/dev/null

check 1 "$(blocks_in "$HOME1/data/captain.md")" "three installs leave exactly one block"
if cmp -s "$WORK/captain.once" "$HOME1/data/captain.md"; then
  ok "re-installing is byte-identical to installing once"
else
  bad "re-installing changed the file"
fi
if grep -q '^- I like short status lines\.$' "$HOME1/data/captain.md"; then
  ok "pre-existing captain content survives install"
else
  bad "pre-existing captain content was lost"
fi
if grep -Fq "$INSTANCE" "$HOME1/data/captain.md"; then
  ok "the block names the operator's instance"
else
  bad "the block does not name the instance"
fi
if [ -f "$HOME1/data/portal-steering/SKILL.md" ] &&
   [ -f "$HOME1/data/portal-steering/secondmate-charter.md" ]; then
  ok "skill and charter are installed under data/"
else
  bad "skill or charter missing"
fi

# The home's git checkout must stay clean, or firstmate's self-update skips it.
check "" "$(git -C "$HOME1" status --porcelain)" "the firstmate checkout stays clean"

# -- changing a setting replaces in place ------------------------------------

"$INSTALL" install --fm-home "$HOME1" --instance "$INSTANCE" --secondmate portal-liaison >/dev/null
check 1 "$(blocks_in "$HOME1/data/captain.md")" "changing settings still leaves one block"
if grep -q 'which owns the portal channel' "$HOME1/data/captain.md"; then
  ok "--secondmate is rendered into the block"
else
  bad "--secondmate was not rendered"
fi

# Omitted flags keep the recorded settings rather than resetting them.
cp "$HOME1/data/portal-steering/settings.env" "$WORK/settings.before"
"$INSTALL" install --fm-home "$HOME1" >/dev/null
if cmp -s "$WORK/settings.before" "$HOME1/data/portal-steering/settings.env"; then
  ok "a bare re-run preserves persisted settings"
else
  bad "a bare re-run changed persisted settings"
fi
if grep -q 'which owns the portal channel' "$HOME1/data/captain.md" &&
   grep -Fq "$INSTANCE" "$HOME1/data/captain.md"; then
  ok "a bare re-run keeps the recorded settings"
else
  bad "a bare re-run lost the recorded settings"
fi

"$INSTALL" install --fm-home "$HOME1" --no-secondmate >/dev/null
if grep -q 'it is not enabled; do not seed one' "$HOME1/data/captain.md"; then
  ok "--no-secondmate clears the liaison line"
else
  bad "--no-secondmate did not clear the liaison line"
fi

# -- uninstall restores the home ---------------------------------------------

"$INSTALL" uninstall --fm-home "$HOME1" >/dev/null
if cmp -s "$WORK/captain.before" "$HOME1/data/captain.md"; then
  ok "uninstall restores captain.md byte-for-byte"
else
  bad "uninstall did not restore captain.md"
fi
if [ -e "$HOME1/data/portal-steering" ]; then
  bad "uninstall left the installed directory behind"
else
  ok "uninstall removes the installed directory"
fi
if "$INSTALL" status --fm-home "$HOME1" >/dev/null 2>&1; then
  bad "status still reports an install after uninstall"
else
  ok "status reports nothing installed after uninstall"
fi
"$INSTALL" uninstall --fm-home "$HOME1" >/dev/null
ok "uninstalling twice is not an error"

# -- a home with no captain.md at all ----------------------------------------

HOME2=$(new_home home2)
"$INSTALL" install --fm-home "$HOME2" --instance "$INSTANCE" >/dev/null
check 1 "$(blocks_in "$HOME2/data/captain.md")" "install creates captain.md when absent"
"$INSTALL" uninstall --fm-home "$HOME2" >/dev/null
if [ -e "$HOME2/data/captain.md" ]; then
  bad "uninstall left an empty captain.md behind"
else
  ok "uninstall removes a captain.md that held only the block"
fi

# -- guards ------------------------------------------------------------------

HOME3="$WORK/home3"
mkdir -p "$HOME3/data"
git -C "$HOME3" init -q
git -C "$HOME3" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init >/dev/null
if "$INSTALL" install --fm-home "$HOME3" --instance "$INSTANCE" >/dev/null 2>&1; then
  bad "installed into a checkout where data/ is not gitignored"
else
  ok "refuses a checkout where data/ is not gitignored"
fi

HOME4=$(new_home home4)
if "$INSTALL" install --fm-home "$HOME4" --instance 'portal.example.com' >/dev/null 2>&1; then
  bad "accepted an instance that is not an http(s) URL"
else
  ok "refuses an instance that is not an http(s) URL"
fi
if "$INSTALL" install --fm-home "$HOME4" >/dev/null 2>&1; then
  bad "installed with no instance and nothing recorded"
else
  ok "refuses to install without an instance"
fi
if "$INSTALL" install --fm-home "$HOME4" --instance "$INSTANCE" --ring no >/dev/null 2>&1; then
  bad "accepted the removed --ring option"
else
  ok "refuses the removed --ring option"
fi
if "$INSTALL" install --fm-home "$HOME4" --instance "$INSTANCE" --secondmate 'a b/c' >/dev/null 2>&1; then
  bad "accepted a second mate id with a path separator"
else
  ok "refuses a second mate id that is not a task id"
fi
if "$INSTALL" install --fm-home "$HOME4" --instance "$INSTANCE" --skills-dir "$WORK/extra-skills" >/dev/null 2>&1; then
  bad "accepted the removed --skills-dir option"
else
  ok "refuses the removed --skills-dir option"
fi

if [ ! -e "$HOME4/data/captain.md" ] &&
   [ ! -e "$HOME4/data/portal-steering" ] && [ ! -e "$WORK/extra-skills" ]; then
  ok "rejected options leave no installation files"
else
  bad "rejected options wrote installation files"
fi

# A second block, however it got there, is a refusal rather than a guess.
HOME5=$(new_home home5)
"$INSTALL" install --fm-home "$HOME5" --instance "$INSTANCE" >/dev/null
cat "$HOME5/data/captain.md" "$HOME5/data/captain.md" > "$WORK/doubled"
cp "$WORK/doubled" "$HOME5/data/captain.md"
if "$INSTALL" install --fm-home "$HOME5" --instance "$INSTANCE" >/dev/null 2>&1; then
  bad "installed over two existing blocks instead of refusing"
else
  ok "refuses a captain.md that already holds two blocks"
fi
check 2 "$(blocks_in "$HOME5/data/captain.md")" "the refusal changed nothing"

# -- removal never touches a directory this installer did not write -----------

HOME6=$(new_home home6)
"$INSTALL" install --fm-home "$HOME6" --instance "$INSTANCE" >/dev/null
OWNED="$HOME6/data/portal-steering"
printf 'my own notes\n' > "$OWNED/NOTES.md"
"$INSTALL" uninstall --fm-home "$HOME6" >/dev/null
if [ -f "$OWNED/NOTES.md" ]; then
  ok "uninstall leaves a file it did not write, and the directory holding it"
else
  bad "uninstall deleted a file it did not write"
fi

# A foreign directory that merely shares the name is refused outright.
HOME7=$(new_home home7)
FOREIGN="$HOME7/data/portal-steering"
mkdir -p "$FOREIGN"
printf -- '---\nname: something-else\n---\n' > "$FOREIGN/SKILL.md"
printf 'precious\n' > "$FOREIGN/data.txt"
if "$INSTALL" uninstall --fm-home "$HOME7" >/dev/null 2>&1; then
  bad "uninstall removed a directory this installer did not write"
else
  ok "uninstall refuses a same-named directory it did not write"
fi
if [ -f "$FOREIGN/data.txt" ]; then
  ok "the foreign directory's contents are intact"
else
  bad "the foreign directory lost content"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
