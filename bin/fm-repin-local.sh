#!/usr/bin/env bash
# Re-pin a local-only task's landing head after the worker revised its ready
# branch, so bin/fm-merge-local.sh can land the revised head the captain
# approved. This script is the single owner of that contract.
#
# Why: bin/fm-dod-lib.sh latches the first reported head as local_done_head= in
# state/<task-id>.meta, and bin/fm-merge-local.sh lands only that exact head. A
# worker that reports ready and then revises its branch leaves the latch on the
# old head. This command replaces the hand edit of that one line. It never
# changes how the latch is first written, and it never lands anything.
#
# The captain still approves every landing. The exact full commit id and the
# captain's own words are required, and nothing is written without both.
#
# Usage:
#   fm-repin-local.sh <task-id> <full-sha> --approval "<captain's exact words>" [--dry-run]
#   fm-repin-local.sh --help
#
# Refusals exit 1 with one "error: repin refused: ..." line and change nothing:
#   - state/<task-id>.meta is absent, or the task mode is not local-only;
#   - the meta has no single valid local_done_head= (a legacy or malformed
#     record must report readiness again through the normal latch);
#   - <full-sha> is not a 40-hex id, or is not a commit in the worktree;
#   - <full-sha> is not the current head of the task's ship branch checked out
#     in the recorded worktree, or that worktree has uncommitted changes;
#   - --approval is missing, blank, or holds a control character.
# A meta that already records <full-sha> reports "already pinned" and exits 0.
# Usage errors exit 2.
#
# On success it takes the task's control lock and meta lock (the order
# bin/fm-merge-local.sh uses), rechecks the task incarnation, then:
#   1. copies the meta to state/<task-id>.meta.bak-<UTC timestamp>;
#   2. rewrites only the local_done_head= line, through a temp file published
#      with fm_backlog_record_publish (atomic rename);
#   3. appends one audit line (time, task, old id, new id, approval words) to
#      state/<task-id>.repin.log, a file no wake source reads.
# It then prints the next commands and runs neither: the hold answer (shown
# unless the task is known not to be held for the captain), then
# bin/fm-merge-local.sh <task-id>.
#
# --dry-run runs every check, prints the change it would make, and writes
# nothing, takes no lock, and appends no audit line.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE and FM_ROOT_OVERRIDE select the home
# and state directory exactly as bin/fm-merge-local.sh does.
# tests/fm-repin-local.test.sh covers this contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
  echo "error: $1" >&2
  echo "usage: fm-repin-local.sh <task-id> <full-sha> --approval \"<captain's exact words>\" [--dry-run]" >&2
  exit 2
}

refuse() {
  echo "error: repin refused: $1" >&2
  exit 1
}

ID='' SHA='' APPROVAL='' APPROVAL_SET=0 DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --approval)
      [ "$#" -ge 2 ] || usage_error "--approval needs the captain's exact words"
      APPROVAL=$2
      APPROVAL_SET=1
      shift
      ;;
    --*) usage_error "unknown option $1" ;;
    *)
      if [ -z "$ID" ]; then ID=$1
      elif [ -z "$SHA" ]; then SHA=$1
      else usage_error "unexpected argument $1"
      fi
      ;;
  esac
  shift
done
[ -n "$ID" ] && [ -n "$SHA" ] || usage_error "a task id and a full commit id are required"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_pr_task_id_valid "$ID" || usage_error "invalid task id"
META="$STATE/$ID.meta"

fm_backlog_directory_present "$STATE" "state directory" \
  || refuse "$FM_BACKLOG_TRANSITION_ERROR"
[ -f "$META" ] || refuse "no meta for task $ID at $META"

# Every check that reads the task record or the worktree. It runs once before
# any write and again under the locks, so a record that changed in between
# refuses instead of being rewritten from stale facts.
OLD_SHA='' BRANCH='' WT='' SPAWN_GEN=''
ALREADY_PINNED=0
check_all() {
  local mode approval_trim
  mode=$(fm_dod_meta_value "$META" mode)
  [ "$mode" = local-only ] \
    || refuse "task $ID is mode=${mode:-unset}, not local-only"

  case "$SHA" in
    *[!0-9a-f]*) refuse "the commit id must be a full 40-character lowercase hex id" ;;
  esac
  [ "${#SHA}" -eq 40 ] || refuse "the commit id must be a full 40-character lowercase hex id"

  [ "$APPROVAL_SET" -eq 1 ] || refuse "--approval with the captain's exact words is required"
  approval_trim=${APPROVAL//[[:space:]]/}
  [ -n "$approval_trim" ] || refuse "--approval is blank; give the captain's exact words"
  case "$APPROVAL" in
    *[[:cntrl:]]*) refuse "--approval holds a control character; give the captain's words on one line" ;;
  esac

  fm_backlog_meta_spawn_gen_optional "$META" "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

  OLD_SHA=$(fm_dod_local_done_head "$META") \
    || refuse "task $ID has no single valid local_done_head; report readiness again first"

  WT=$(fm_dod_meta_value "$META" worktree)
  [ -n "$WT" ] && [ -d "$WT" ] || refuse "task $ID has no usable recorded worktree"
  BRANCH=$(fm_dod_meta_value "$META" branch)
  [ -n "$BRANCH" ] || BRANCH="fm/$ID"
  git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
    || refuse "task $ID has an invalid recorded ship branch '$BRANCH'"

  [ "$(git -C "$WT" cat-file -t "$SHA" 2>/dev/null || true)" = commit ] \
    || refuse "commit $SHA does not exist in the task worktree"
  [ "$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$BRANCH" ] \
    || refuse "the task worktree is not on its ship branch $BRANCH"
  [ "$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null || true)" = "$SHA" ] \
    || refuse "$SHA is not the current head of ship branch $BRANCH"
  [ "$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null || true)" = "$SHA" ] \
    || refuse "the task worktree HEAD is not $SHA"
  [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] \
    || refuse "the task worktree has uncommitted changes"

  ALREADY_PINNED=0
  [ "$OLD_SHA" != "$SHA" ] || ALREADY_PINNED=1
}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$META.bak-$STAMP"
LOG="$STATE/$ID.repin.log"

report_already_pinned() {
  echo "already pinned: task $ID records $SHA as local_done_head; nothing changed"
}

check_all
if [ "$ALREADY_PINNED" -eq 1 ]; then
  report_already_pinned
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: task $ID local_done_head would change"
  echo "  old: $OLD_SHA"
  echo "  new: $SHA"
  echo "  backup: $BACKUP"
  echo "  audit log: $LOG"
  echo "dry-run: nothing written"
  exit 0
fi

REPIN_CONTROL_LOCK='' REPIN_META_LOCK='' REPIN_TMP=''
repin_cleanup() {
  [ -z "$REPIN_TMP" ] || rm -f -- "$REPIN_TMP"
  [ -z "$REPIN_META_LOCK" ] || fm_lock_release "$REPIN_META_LOCK" || true
  [ -z "$REPIN_CONTROL_LOCK" ] || fm_lock_release "$REPIN_CONTROL_LOCK" || true
}
trap repin_cleanup EXIT

REPIN_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$REPIN_CONTROL_LOCK"
REPIN_META_LOCK=$(fm_meta_lock_path "$META") || refuse "invalid task record name for $ID"
fm_lock_acquire_wait "$REPIN_META_LOCK"

EXPECTED_GEN=$SPAWN_GEN EXPECTED_OLD=$OLD_SHA
check_all
[ "$SPAWN_GEN" = "$EXPECTED_GEN" ] || refuse "task $ID changed incarnation while waiting for its locks"
[ "$OLD_SHA" = "$EXPECTED_OLD" ] || refuse "task $ID local_done_head changed while waiting for its locks"
if [ "$ALREADY_PINNED" -eq 1 ]; then
  report_already_pinned
  exit 0
fi

# A same-second retry must not overwrite an earlier backup.
if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  BACKUP="$BACKUP.$$"
fi
cp -p -- "$META" "$BACKUP" || refuse "could not write the backup $BACKUP"

REPIN_TMP=$(mktemp "$STATE/.repin-local-$ID.XXXXXX") || refuse "could not stage the new task record"
cp -p -- "$META" "$REPIN_TMP"
awk -v new="$SHA" '
  /^local_done_head=/ { print "local_done_head=" new; next }
  { print }
' "$META" > "$REPIN_TMP" || refuse "could not stage the new task record"
[ "$(fm_dod_local_done_head "$REPIN_TMP" || true)" = "$SHA" ] \
  || refuse "the staged task record did not carry the new head"
fm_backlog_record_publish "$REPIN_TMP" "$META" "task record" "$STATE" \
  || refuse "$FM_BACKLOG_TRANSITION_ERROR"
REPIN_TMP=''

printf '%s task=%s old=%s new=%s approval=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$OLD_SHA" "$SHA" "$APPROVAL" >> "$LOG"

echo "re-pinned task $ID local_done_head"
echo "  old: $OLD_SHA"
echo "  new: $SHA"
echo "  backup: $BACKUP"
echo "  audit log: $LOG"

hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent >/dev/null 2>&1 || hold_status=$?
echo "next commands (not run):"
case "$hold_status" in
  1|3) ;;
  *)
    DECISION="$FM_HOME/data/$ID/repin-approval.txt"
    printf '  mkdir -p %q && printf "%%s\\n" %q > %q\n' "$FM_HOME/data/$ID" "$APPROVAL" "$DECISION"
    printf '  %q answer %q --decision-file %q --release\n' "$SCRIPT_DIR/fm-captain-hold.sh" "$ID" "$DECISION"
    ;;
esac
printf '  %q %q\n' "$SCRIPT_DIR/fm-merge-local.sh" "$ID"
