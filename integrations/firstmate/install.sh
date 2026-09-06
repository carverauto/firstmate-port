#!/usr/bin/env bash
# install.sh - add, inspect, or remove firstmate-port portal steering in a
# firstmate home.
#
# Portal steering moves firstmate's message passing off on-disk inbox files and
# onto a firstmate-port instance reached with the fm-steer CLI. This script owns
# the two things that must not accumulate or drift: one marker-delimited block in
# the home's data/captain.md, and one installer-owned directory beside it.
#
#   install.sh install   --instance <url> [--fm-home <dir>] [--ring yes|no]
#                        [--secondmate <id> | --no-secondmate] [--skills-dir <dir>]
#   install.sh status    [--fm-home <dir>]
#   install.sh uninstall [--fm-home <dir>] [--skills-dir <dir>]
#
# Install is idempotent: re-running replaces the block between the markers in
# place and overwrites the files it owns by name. It never appends a second
# block, never edits a line outside the markers, and never seeds or retires a
# second mate.
#
# REMOVAL SAFETY. This script contains no recursive delete and no wildcard
# delete. Install removes nothing at all. Uninstall deletes only:
#   - named files, one at a time, through remove_owned_file, which refuses an
#     empty directory, an empty filename, a filename carrying / or .., a
#     non-absolute directory, and anything that is not a regular file; and
#   - the directory itself with rmdir, which fails loudly rather than erasing a
#     directory that still holds something this installer did not write.
# Both are gated by assert_owned_skill_dir: non-empty, absolute, a real
# directory rather than a symlink, named exactly portal-steering, and holding a
# SKILL.md this installer wrote.
#
# Nothing is written inside the firstmate checkout outside gitignored data/.
# Firstmate's fast-forward self-update skips a home whose checkout is dirty, so
# an untracked file under .agents/skills/ or bin/ would quietly stop that home
# from ever updating. --skills-dir is the one escape hatch, for a harness skills
# directory that lives outside the checkout.
#
# FM_HOME supplies the default for --fm-home. There is no guessed fallback.
set -euo pipefail

BEGIN_MARKER='<!-- BEGIN firstmate-port portal-steering -->'
END_MARKER='<!-- END firstmate-port portal-steering -->'
SKILL_NAME='portal-steering'
OWNED_FILES='SKILL.md secondmate-charter.md settings.env'

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEMPLATE="$SELF_DIR/captain-block.md.tmpl"
SOURCE_SKILL_DIR="$SELF_DIR/skills/$SKILL_NAME"

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# A constant emptied by a bad edit must never reach a path expression.
[ -n "$SKILL_NAME" ] || die "internal: SKILL_NAME is empty"
[ -n "$OWNED_FILES" ] || die "internal: OWNED_FILES is empty"
[ -n "$BEGIN_MARKER" ] && [ -n "$END_MARKER" ] || die "internal: markers are empty"

# ---------------------------------------------------------------- arguments --

CMD=${1:-}
[ -n "$CMD" ] || { usage >&2; exit 2; }
shift || true

FM_HOME_ARG=""; INSTANCE=""; RING=""
SECONDMATE=""; SECONDMATE_SET=0
SKILLS_DIR=""; SKILLS_DIR_SET=0

while [ $# -gt 0 ]; do
  case $1 in
    --fm-home)       FM_HOME_ARG=${2:-}; shift 2 ;;
    --instance)      INSTANCE=${2:-}; shift 2 ;;
    --ring)          RING=${2:-}; shift 2 ;;
    --secondmate)    SECONDMATE=${2:-}; SECONDMATE_SET=1; shift 2 ;;
    --no-secondmate) SECONDMATE=""; SECONDMATE_SET=1; shift ;;
    --skills-dir)    SKILLS_DIR=${2:-}; SKILLS_DIR_SET=1; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

FM_HOME_DIR=${FM_HOME_ARG:-${FM_HOME:-}}
[ -n "$FM_HOME_DIR" ] || die "no firstmate home: pass --fm-home <dir> or export FM_HOME"
[ -d "$FM_HOME_DIR" ] || die "not a directory: $FM_HOME_DIR"
FM_HOME_DIR=$(cd -- "$FM_HOME_DIR" && pwd -P)

DATA_DIR="$FM_HOME_DIR/data"
CAPTAIN_FILE="$DATA_DIR/captain.md"
OWNED_DIR="$DATA_DIR/$SKILL_NAME"
SETTINGS_FILE="$OWNED_DIR/settings.env"

# ------------------------------------------------------------ safety guards --

# Every directory this script may delete from must pass here first. Anything
# that is not this installer's own skill directory is refused, not deleted.
assert_owned_skill_dir() {
  local dir=${1:-}
  [ -n "$dir" ] || die "refusing to act on an empty directory path"
  case $dir in
    /*) ;;
    *)  die "refusing a non-absolute removal path: $dir" ;;
  esac
  case $dir in
    */"$SKILL_NAME") ;;
    *) die "refusing to remove $dir: it is not named $SKILL_NAME" ;;
  esac
  [ ! -L "$dir" ] || die "refusing to remove $dir: it is a symlink, not the installed directory"
  [ -d "$dir" ] || die "refusing to remove $dir: not a directory"
  [ -f "$dir/SKILL.md" ] || die "refusing to remove $dir: no SKILL.md, so this installer did not write it"
  grep -Fqx "name: $SKILL_NAME" "$dir/SKILL.md" ||
    die "refusing to remove $dir: its SKILL.md is not the $SKILL_NAME skill"
}

# Delete exactly one named regular file from an already-asserted directory.
# Both halves of the path are checked non-empty here, immediately before the
# only rm in this script.
remove_owned_file() {
  local dir=${1:-} name=${2:-} target
  [ -n "$dir" ] || die "refusing to remove a file: empty directory"
  [ -n "$name" ] || die "refusing to remove a file: empty filename"
  case $name in
    */*|*..*) die "refusing to remove a file: unexpected filename $name" ;;
  esac
  target="$dir/$name"
  [ -n "$target" ] || die "refusing to remove a file: empty path"
  [ -e "$target" ] || return 0
  [ -f "$target" ] || die "refusing to remove $target: not a regular file"
  [ ! -L "$target" ] || die "refusing to remove $target: it is a symlink"
  rm -f -- "$target"
}

# Remove only the files this installer writes, then rmdir. A file the operator
# added makes rmdir fail, and the directory is left in place with a notice.
remove_owned_skill_dir() {
  local dir=${1:-} name
  assert_owned_skill_dir "$dir"
  for name in $OWNED_FILES; do
    remove_owned_file "$dir" "$name"
  done
  if rmdir -- "$dir" 2>/dev/null; then
    note "removed $dir"
  else
    note "left $dir in place: it holds files this installer did not write"
    note "  inspect it and remove it by hand if you no longer want it"
  fi
}

# Refuse to dirty the firstmate checkout: data/ must be gitignored when the home
# is a git work tree, because a dirty home is silently skipped by self-update.
assert_data_ignored() {
  git -C "$FM_HOME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if git -C "$FM_HOME_DIR" check-ignore -q data; then
    return 0
  fi
  die "$FM_HOME_DIR is a git work tree where data/ is not gitignored.
    Installing there would leave the checkout dirty, and firstmate's
    fast-forward self-update skips a dirty home. Add data/ to .gitignore, or
    point --fm-home at a real firstmate home."
}

# ----------------------------------------------------------------- settings --

SET_INSTANCE=""; SET_RING=""; SET_SECONDMATE=""; SET_SKILLS_DIR=""
load_settings() {
  [ -f "$SETTINGS_FILE" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    key=${line%%=*}; value=${line#*=}
    value=${value%\"}; value=${value#\"}
    case $key in
      instance)   SET_INSTANCE=$value ;;
      ring)       SET_RING=$value ;;
      secondmate) SET_SECONDMATE=$value ;;
      skills_dir) SET_SKILLS_DIR=$value ;;
    esac
  done < "$SETTINGS_FILE"
}

# -------------------------------------------------------------- block edits --

block_present() {
  [ -f "$CAPTAIN_FILE" ] || return 1
  grep -Fqx "$BEGIN_MARKER" "$CAPTAIN_FILE"
}

marker_line() { grep -Fxn "$1" "$CAPTAIN_FILE" | head -1 | cut -d: -f1; }

# Exactly one BEGIN and one END, in that order, or refuse rather than guess.
assert_markers_sane() {
  [ -f "$CAPTAIN_FILE" ] || return 0
  local begins ends b e
  begins=$(grep -Fxc "$BEGIN_MARKER" "$CAPTAIN_FILE" || true)
  ends=$(grep -Fxc "$END_MARKER" "$CAPTAIN_FILE" || true)
  [ "$begins" = "$ends" ] ||
    die "$CAPTAIN_FILE has $begins begin and $ends end markers; fix it by hand"
  [ "${begins:-0}" -le 1 ] ||
    die "$CAPTAIN_FILE has $begins portal-steering blocks; delete the extras by hand"
  [ "${begins:-0}" = 1 ] || return 0
  b=$(marker_line "$BEGIN_MARKER"); e=$(marker_line "$END_MARKER")
  [ "$b" -lt "$e" ] ||
    die "$CAPTAIN_FILE has the end marker before the begin marker; fix it by hand"
}

render_block() {
  local instance=$1 ring=$2 secondmate=$3 body sm
  [ -f "$TEMPLATE" ] || die "missing template: $TEMPLATE"
  body=$(cat -- "$TEMPLATE")
  if [ -n "$secondmate" ]; then
    sm="\`$secondmate\`, which owns the portal channel"
  else
    sm="not enabled; do not seed one without asking me"
  fi
  body=${body//@@INSTANCE@@/$instance}
  body=${body//@@RING@@/$ring}
  body=${body//@@SECONDMATE@@/$sm}
  printf '%s\n' "$body"
}

# Replace between the markers in place, or append after one blank separator.
# Never appends a second block; never rewrites a line outside the markers.
write_block() {
  local blockfile=$1 tmp
  mkdir -p "$DATA_DIR"
  tmp=$(mktemp "$DATA_DIR/.captain.md.XXXXXX")
  if block_present; then
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v blockfile="$blockfile" '
      $0 == begin { while ((getline line < blockfile) > 0) print line; close(blockfile); skip = 1; next }
      $0 == end   { skip = 0; next }
      !skip
    ' "$CAPTAIN_FILE" > "$tmp"
  else
    if [ -s "$CAPTAIN_FILE" ]; then
      cat -- "$CAPTAIN_FILE" > "$tmp"
      if [ -n "$(tail -c 1 "$tmp")" ]; then
        printf '\n' >> "$tmp"   # the file did not end in a newline
      fi
      printf '\n' >> "$tmp"     # one blank line separates the block
    else
      : > "$tmp"
    fi
    cat -- "$blockfile" >> "$tmp"
  fi
  mv -- "$tmp" "$CAPTAIN_FILE"
}

# Delete the marker block and the one blank separator line install added, so an
# appended block leaves the file byte-identical to what it was before install.
remove_block() {
  local tmp b e from
  block_present || return 0
  b=$(marker_line "$BEGIN_MARKER"); e=$(marker_line "$END_MARKER")
  from=$b
  if [ "$b" -gt 1 ] && [ -z "$(sed -n "$((b - 1))p" "$CAPTAIN_FILE" | tr -d '[:space:]')" ]; then
    from=$((b - 1))
  fi
  tmp=$(mktemp "$DATA_DIR/.captain.md.XXXXXX")
  awk -v from="$from" -v to="$e" 'NR < from || NR > to' "$CAPTAIN_FILE" > "$tmp"
  if [ -n "$(tr -d '[:space:]' < "$tmp")" ]; then
    mv -- "$tmp" "$CAPTAIN_FILE"
    note "removed the portal-steering block from $CAPTAIN_FILE"
  else
    mv -- "$tmp" "$CAPTAIN_FILE"
    remove_owned_file "$DATA_DIR" "captain.md"
    note "removed $CAPTAIN_FILE (the portal-steering block was its only content)"
  fi
}

# ------------------------------------------------------------------ install --

cmd_install() {
  assert_data_ignored
  load_settings

  [ -n "$INSTANCE" ] || INSTANCE=$SET_INSTANCE
  [ -n "$INSTANCE" ] || die "no portal URL: pass --instance <url> (your firstmate-port instance)"
  case $INSTANCE in
    http://*|https://*) ;;
    *) die "--instance must be an http:// or https:// URL, got: $INSTANCE" ;;
  esac
  INSTANCE=${INSTANCE%/}

  [ -n "$RING" ] || RING=${SET_RING:-yes}
  case $RING in yes|no) ;; *) die "--ring takes yes or no, got: $RING" ;; esac

  [ "$SECONDMATE_SET" -eq 1 ] || SECONDMATE=$SET_SECONDMATE
  case $SECONDMATE in
    '') ;;
    *[!A-Za-z0-9._-]*) die "--secondmate takes a task id ([A-Za-z0-9._-]), got: $SECONDMATE" ;;
  esac

  [ "$SKILLS_DIR_SET" -eq 1 ] || SKILLS_DIR=$SET_SKILLS_DIR
  if [ -n "$SKILLS_DIR" ]; then
    case $SKILLS_DIR in
      /*) ;;
      *)  die "--skills-dir must be an absolute path, got: $SKILLS_DIR" ;;
    esac
  fi

  assert_markers_sane
  [ -f "$SOURCE_SKILL_DIR/SKILL.md" ] || die "missing skill source: $SOURCE_SKILL_DIR/SKILL.md"

  local tmpblock
  tmpblock=$(mktemp "${TMPDIR:-/tmp}/portal-steering-block.XXXXXX")
  render_block "$INSTANCE" "$RING" "$SECONDMATE" > "$tmpblock"
  write_block "$tmpblock"
  remove_owned_file "$(dirname -- "$tmpblock")" "$(basename -- "$tmpblock")"

  mkdir -p "$OWNED_DIR"
  cp -- "$SOURCE_SKILL_DIR/SKILL.md" "$OWNED_DIR/SKILL.md"
  cp -- "$SOURCE_SKILL_DIR/secondmate-charter.md" "$OWNED_DIR/secondmate-charter.md"
  {
    printf '# written by integrations/firstmate/install.sh; change it by re-running install\n'
    printf 'instance="%s"\n' "$INSTANCE"
    printf 'ring="%s"\n' "$RING"
    printf 'secondmate="%s"\n' "$SECONDMATE"
    printf 'skills_dir="%s"\n' "$SKILLS_DIR"
  } > "$SETTINGS_FILE"

  if [ -n "$SKILLS_DIR" ]; then
    mkdir -p "$SKILLS_DIR/$SKILL_NAME"
    cp -- "$SOURCE_SKILL_DIR/SKILL.md" "$SKILLS_DIR/$SKILL_NAME/SKILL.md"
    cp -- "$SOURCE_SKILL_DIR/secondmate-charter.md" "$SKILLS_DIR/$SKILL_NAME/secondmate-charter.md"
  fi

  note "portal steering installed in $FM_HOME_DIR"
  note "  captain block   $CAPTAIN_FILE"
  note "  skill           $OWNED_DIR/SKILL.md"
  note "  instance        $INSTANCE"
  note "  ring after put  $RING"
  note "  second mate     ${SECONDMATE:-not enabled}"
  if [ -n "$SKILLS_DIR" ]; then
    note "  harness copy    $SKILLS_DIR/$SKILL_NAME/"
  fi
  note ""
  note "Log in once on this host before the first steer:"
  note "  fm-steer auth login --instance $INSTANCE"
  return 0
}

# ------------------------------------------------------------------- status --

cmd_status() {
  load_settings
  note "firstmate home  $FM_HOME_DIR"
  if block_present; then note "captain block   present ($CAPTAIN_FILE)"
  else note "captain block   absent"; fi
  if [ -f "$OWNED_DIR/SKILL.md" ]; then note "skill           present ($OWNED_DIR/SKILL.md)"
  else note "skill           absent"; fi
  note "instance        ${SET_INSTANCE:-unset}"
  note "ring after put  ${SET_RING:-unset}"
  note "second mate     ${SET_SECONDMATE:-not enabled}"
  note "harness copy    ${SET_SKILLS_DIR:-none}"
  block_present || [ -f "$OWNED_DIR/SKILL.md" ]
}

# ---------------------------------------------------------------- uninstall --

cmd_uninstall() {
  load_settings
  assert_markers_sane
  local removed=0 harness

  if block_present; then remove_block; removed=1; fi
  if [ -d "$OWNED_DIR" ] && [ ! -L "$OWNED_DIR" ]; then
    remove_owned_skill_dir "$OWNED_DIR"; removed=1
  fi

  harness=${SKILLS_DIR:-$SET_SKILLS_DIR}
  if [ -n "$harness" ]; then
    case $harness in
      /*) if [ -d "$harness/$SKILL_NAME" ] && [ ! -L "$harness/$SKILL_NAME" ]; then
            remove_owned_skill_dir "$harness/$SKILL_NAME"; removed=1
          fi ;;
      *)  die "--skills-dir must be an absolute path, got: $harness" ;;
    esac
  fi

  if [ "$removed" -eq 0 ]; then
    note "portal steering was not installed in $FM_HOME_DIR; nothing to remove"
    return 0
  fi

  note ""
  note "Back to stock firstmate. bin/fm-send.sh, bin/fm-inbox.sh and"
  note "state/<id>.inbox/ were never modified, so on-disk steering is live again."
  note "Finish by hand:"
  note "  - retire the liaison second mate if one was enabled: bin/fm-teardown.sh <id>"
  note "  - in any in-flight data/<id>/brief.md, restore the stock"
  note "    '# Firstmate instruction inbox' section (the bin/fm-brief.sh text that"
  note "    points at state/<id>.inbox/ and acknowledges with mv <file> handled/)"
  note "  - tell any running crewmate once that the on-disk inbox is live again"
  note "  - optionally: fm-steer auth logout"
  return 0
}

case $CMD in
  install)   cmd_install ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)         usage >&2; exit 2 ;;
esac
