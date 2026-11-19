#!/usr/bin/env bash
# bin/fm-repin-local.sh re-pins a local-only task's landing head, through its CLI.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-repin-local)
fm_git_identity fmtest fmtest@example.invalid

APPROVAL='yes, land 0123 as revised'

# A local-only task that reported ready on X, then revised its branch to Y.
make_case() {
  local name=$1
  CASE="$TMP_ROOT/$name"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  HOME_DIR="$CASE/home"
  META="$HOME_DIR/state/local-task.meta"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/fm-guard.sh"
  chmod +x "$HOME_DIR/bin/fm-guard.sh"
  fm_git_worktree "$PROJ" "$WT" fm/local-task
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'first\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m X
  X=$(git -C "$WT" rev-parse HEAD)
  printf 'kind=ship\nmode=local-only\nbranch=fm/local-task\nproject=%s\nworktree=%s\nspawn_gen=fixture-1\n' \
    "$PROJ" "$WT" > "$META"
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
    'done [at=1790000000]: ready in branch fm/local-task' \
    "$HOME_DIR/state" local-task "$META" || fail 'fixture done was not accepted'
  printf 'revised\n' > "$WT/approved.txt"
  git -C "$WT" commit -q -a -m Y
  Y=$(git -C "$WT" rev-parse HEAD)
}

repin() {  # <args...>
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "$ROOT/bin/fm-repin-local.sh" "$@"
}

land() {
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "$ROOT/bin/fm-merge-local.sh" local-task
}

pinned() { sed -n 's/^local_done_head=//p' "$META"; }

backups() { find "$HOME_DIR/state" -maxdepth 1 -name 'local-task.meta.bak-*' | wc -l | tr -d ' '; }

# A refusal exits non-zero with one error line and leaves every record alone.
assert_refusal() {  # <expected-text> <args...>
  local want=$1 out rc=0 before
  shift
  before=$(cat "$META")
  out=$(repin "$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "repin unexpectedly succeeded: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "refusal was not one line: $out"
  case "$out" in
    *"$want"*) ;;
    *) fail "refusal did not name '$want': $out" ;;
  esac
  [ "$(cat "$META")" = "$before" ] || fail 'refusal changed the task record'
  [ "$(backups)" = 0 ] || fail 'refusal left a backup'
  [ ! -e "$HOME_DIR/state/local-task.repin.log" ] || fail 'refusal wrote an audit line'
}

test_success_repins_and_records() {
  local out
  make_case success
  [ "$(pinned)" = "$X" ] || fail 'fixture did not latch X'
  out=$(repin local-task "$Y" --approval "$APPROVAL" 2>&1) || fail "repin failed: $out"
  [ "$(pinned)" = "$Y" ] || fail 'local_done_head was not rewritten to Y'
  [ "$(grep -c '^local_done_head=' "$META")" = 1 ] || fail 'meta does not hold exactly one head'
  [ "$(backups)" = 1 ] || fail 'expected exactly one backup'
  grep -q "^local_done_head=$X\$" "$HOME_DIR"/state/local-task.meta.bak-* || fail 'backup lost the old head'
  grep -v '^local_done_head=' "$META" | cmp -s - <(grep -v '^local_done_head=' "$HOME_DIR"/state/local-task.meta.bak-*) \
    || fail 'repin changed more than the head line'
  [ "$(wc -l < "$HOME_DIR/state/local-task.repin.log" | tr -d ' ')" = 1 ] || fail 'expected one audit line'
  grep -qF "task=local-task old=$X new=$Y approval=$APPROVAL" "$HOME_DIR/state/local-task.repin.log" \
    || fail 'audit line lacks the task, heads or approval words'
  case "$out" in *"fm-merge-local.sh"*) ;; *) fail "next commands omit the merge: $out" ;; esac
  [ -z "$(find "$HOME_DIR/state" -maxdepth 1 -name '.repin-local-*' -o -name '.meta-*.lock' -o -name '.control-*.lock')" ] \
    || fail 'repin left a temp file or lock behind'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'repin moved main'
  pass 'repin rewrites only the head, keeps a backup, appends one audit line and prints the next commands'
}

test_merge_local_accepts_repinned_head() {
  make_case lands
  land >/dev/null 2>&1 && fail 'merge landed the revised branch before the repin'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'pre-repin merge moved main'
  repin local-task "$Y" --approval "$APPROVAL" >/dev/null 2>&1 || fail 'repin failed'
  land >/dev/null 2>&1 || fail 'merge did not accept the re-pinned head'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$Y" ] || fail 'merge did not land Y'
  [ "$(cat "$PROJ/approved.txt")" = revised ] || fail 'merge did not update the checkout'
  pass 'fm-merge-local.sh lands the re-pinned head and refused it before'
}

test_refusals() {
  make_case refusals
  assert_refusal 'full 40-character' local-task "${Y:0:12}" --approval "$APPROVAL"
  assert_refusal 'full 40-character' local-task "refs/heads/fm/local-task" --approval "$APPROVAL"
  assert_refusal 'full 40-character' local-task "$(printf '%s' "$Y" | tr a-f A-F)" --approval "$APPROVAL"
  assert_refusal 'does not exist' local-task 0123456789012345678901234567890123456789 --approval "$APPROVAL"
  assert_refusal 'approval' local-task "$Y"
  assert_refusal 'blank' local-task "$Y" --approval ''
  assert_refusal 'blank' local-task "$Y" --approval '   '
  assert_refusal 'control character' local-task "$Y" --approval "$(printf 'a\nb')"
  assert_refusal 'no meta' absent-task "$Y" --approval "$APPROVAL"
  pass 'missing task, malformed or unknown commit ids, and absent or blank approval refuse without a change'

  # X exists on the branch but is no longer its head.
  git -C "$WT" commit -q --allow-empty -m Z
  assert_refusal 'not the current head' local-task "$Y" --approval "$APPROVAL"
  git -C "$WT" reset -q --hard "$Y"

  printf 'dirty\n' > "$WT/untracked.txt"
  assert_refusal 'uncommitted' local-task "$Y" --approval "$APPROVAL"
  rm -f "$WT/untracked.txt"
  printf 'dirty\n' >> "$WT/approved.txt"
  assert_refusal 'uncommitted' local-task "$Y" --approval "$APPROVAL"
  git -C "$WT" checkout -q -- approved.txt
  pass 'a moved branch or a dirty worktree refuses without a change'

  git -C "$WT" checkout -q --detach
  assert_refusal 'not on its ship branch' local-task "$Y" --approval "$APPROVAL"
  git -C "$WT" checkout -q fm/local-task

  sed -i.orig 's/^mode=local-only$/mode=no-mistakes/' "$META"
  rm -f "$META.orig"
  assert_refusal 'not local-only' local-task "$Y" --approval "$APPROVAL"
  sed -i.orig 's/^mode=no-mistakes$/mode=local-only/' "$META"
  rm -f "$META.orig"

  grep -v '^local_done_head=' "$META" > "$META.new" && mv "$META.new" "$META"
  assert_refusal 'local_done_head' local-task "$Y" --approval "$APPROVAL"
  printf 'local_done_head=%s\nlocal_done_head=%s\n' "$X" "$X" >> "$META"
  assert_refusal 'local_done_head' local-task "$Y" --approval "$APPROVAL"
  pass 'a detached worktree, a non-local-only task, and a missing or duplicate head refuse without a change'
}

test_already_pinned_exits_zero() {
  local out rc=0
  make_case pinned
  out=$(repin local-task "$X" --approval "$APPROVAL" 2>&1) || rc=$?
  # X is no longer the branch head, so the head check refuses it first.
  [ "$rc" -ne 0 ] || fail "a stale head unexpectedly succeeded: $out"
  repin local-task "$Y" --approval "$APPROVAL" >/dev/null 2>&1 || fail 'first repin failed'
  rc=0
  out=$(repin local-task "$Y" --approval "$APPROVAL" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "second repin exited $rc: $out"
  case "$out" in *'already pinned'*) ;; *) fail "second repin did not say already pinned: $out" ;; esac
  [ "$(backups)" = 1 ] || fail 'already pinned wrote another backup'
  [ "$(wc -l < "$HOME_DIR/state/local-task.repin.log" | tr -d ' ')" = 1 ] || fail 'already pinned wrote another audit line'
  pass 'an already pinned head reports so, exits 0 and writes nothing'
}

test_dry_run_writes_nothing() {
  local out before
  make_case dry
  before=$(cat "$META")
  out=$(repin local-task "$Y" --approval "$APPROVAL" --dry-run 2>&1) || fail "dry run failed: $out"
  case "$out" in *"old: $X"*"new: $Y"*) ;; *) fail "dry run did not show the change: $out" ;; esac
  [ "$(cat "$META")" = "$before" ] || fail 'dry run changed the record'
  [ "$(backups)" = 0 ] || fail 'dry run wrote a backup'
  [ ! -e "$HOME_DIR/state/local-task.repin.log" ] || fail 'dry run wrote an audit line'
  [ -z "$(find "$HOME_DIR/state" -maxdepth 1 -name '.control-*.lock' -o -name '.meta-*.lock')" ] || fail 'dry run took a lock'
  assert_refusal 'approval' local-task "$Y" --dry-run
  pass 'dry run checks everything, shows the change and writes nothing'
}

test_usage_and_help() {
  local out rc=0
  make_case usage
  out=$(repin --help 2>&1) || fail 'help failed'
  case "$out" in *'--approval'*'--dry-run'*) ;; *) fail "help omits the options: $out" ;; esac
  repin local-task >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "missing commit id exited $rc, expected 2"
  rc=0
  repin local-task "$Y" --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown option exited $rc, expected 2"
  pass 'help names the options and bad usage exits 2'
}

fm_test_run test_success_repins_and_records test_merge_local_accepts_repinned_head \
  test_refusals test_already_pinned_exits_zero test_dry_run_writes_nothing test_usage_and_help
