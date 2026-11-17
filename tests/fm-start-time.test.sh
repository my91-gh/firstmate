#!/usr/bin/env bash
# Behavior tests for backlog start times: a queued item can carry a start
# instant, bin/fm-spawn.sh refuses to launch it before then and leaves it
# queued (exit 75, the capacity deferral status), and the watcher's check sweep
# queues one wake when the instant arrives (bin/fm-start-time.sh owns the field).
#
# Every case drives the real scripts against a real markdown backlog. The spawn
# cases use a real project clone with an origin and fake tmux and treehouse
# binaries that log every call, so a deferred spawn is judged by what it left
# behind, never by wording alone.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

unset TASKS_AXI_BACKEND || :

if ! command -v tasks-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  printf '1..0 # SKIP start times need tasks-axi and jq\n'
  exit 0
fi

START_TIME="$ROOT/bin/fm-start-time.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-start-time)
PAST=2020-01-01T00:00:00Z
FUTURE=2099-01-01T00:00:00Z

# --- fixture ----------------------------------------------------------------

make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf '%s\n' "# Task" "## Captain's intent" "Exercise start times for $id." \
      "## Firstmate spec" "None." "# Definition of done" "Delivery contract: mode=no-mistakes" \
      > "$home/data/$id/brief.md"
    tasks-axi add "$id" "item for $id" --kind ship --body "notes for $id" \
      --file "$home/data/backlog.md" >/dev/null
  done
}

start_time() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$START_TIME" "$@"
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

row_body() {  # <home> <id>
  tasks-axi show "$2" --full --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  body: //p' | head -1
}

wake_rows() {  # <home>
  awk -F '\t' 'NF >= 5 && $3 == "check" { print $5 }' "$1/state/.wake-queue" 2>/dev/null || true
}

make_spawn_case() {  # <name> <task-id>
  local case_dir=$TMP_ROOT/$1 fakebin
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$2"
  printf '%s\n' "$case_dir"
}

spawn_ship() {  # <case-dir> <id>
  local case_dir=$1 id=$2 pane
  pane="$case_dir/wt-$id"
  [ -d "$pane" ] || git -C "$case_dir/project" worktree add --quiet -b "wt-$id" "$pane"
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

# --- cases ------------------------------------------------------------------

test_set_show_clear_round_trip_keeps_the_body() {
  local home out
  home="$TMP_ROOT/round-trip"
  make_home "$home" task-a
  [ -z "$(start_time "$home" show task-a)" ] || fail "an item without a start time reported one"
  out=$(start_time "$home" set task-a 2099-03-04T05:06Z) || fail "set refused a UTC time: $out"
  assert_equals "2099-03-04T05:06:00Z" "$(start_time "$home" show task-a)" "show did not report the stored UTC instant"
  assert_contains "$(row_body "$home" task-a)" 'notes for task-a' "set dropped the item's existing notes"
  start_time "$home" set task-a 2099-03-04T07:30:15+02:00 >/dev/null || fail "set refused an offset time"
  assert_equals "2099-03-04T05:30:15Z" "$(start_time "$home" show task-a)" "an offset time was not converted to UTC"
  [ "$(row_body "$home" task-a | grep -o 'fm-start-after=' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a second set left more than one start time on the item"
  start_time "$home" clear task-a >/dev/null || fail "clear failed"
  [ -z "$(start_time "$home" show task-a)" ] || fail "clear left the start time in place"
  assert_equals 'notes for task-a' "$(row_body "$home" task-a)" "clear did not restore the original notes"
  pass "a start time sets, replaces, and clears through the backlog without touching the item's notes"
}

test_invalid_times_are_refused() {
  local home time rc
  home="$TMP_ROOT/invalid"
  make_home "$home" task-a
  for time in 2099-03-04T05:06 2099-13-04T05:06Z 2099-02-30T05:06Z 2099-03-04T05:06+25:00 tomorrow 2099-03-04; do
    rc=0
    start_time "$home" set task-a "$time" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "set accepted the invalid start time $time"
  done
  rc=0
  start_time "$home" set no-such-task "$FUTURE" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "set accepted an item that is not in the backlog"
  [ -z "$(start_time "$home" show task-a)" ] || fail "a refused set still stored a start time"
  pass "a time without Z or an offset, an impossible date, and a missing item are refused"
}

test_gate_defers_only_before_the_start_time() {
  local home out rc=0
  home="$TMP_ROOT/gate"
  make_home "$home" task-a
  start_time "$home" gate task-a || fail "an item with no start time was gated"
  start_time "$home" set task-a "$FUTURE" >/dev/null
  out=$(start_time "$home" gate task-a 2>&1) || rc=$?
  expect_code 75 "$rc" "a future start time did not defer: $out"
  assert_contains "$out" "deferred:" "the deferral was not labelled"
  assert_contains "$out" "$FUTURE" "the deferral did not name the start time"
  start_time "$home" set task-a "$PAST" >/dev/null
  start_time "$home" gate task-a || fail "a start time in the past still deferred"
  tasks-axi update task-a --body 'fm-start-after=2099-99-99T00:00:00Z' --file "$home/data/backlog.md" >/dev/null
  rc=0
  out=$(start_time "$home" gate task-a 2>&1) || rc=$?
  expect_code 3 "$rc" "an unreadable stored start time did not stop the gate: $out"
  pass "the gate exits 75 naming the time until it passes, then admits, and stops on an unreadable time"
}

test_spawn_is_refused_before_the_time_and_allowed_after() {
  local case_dir home out rc=0 calls_before
  case_dir=$(make_spawn_case spawn task-a)
  home="$case_dir/home"
  start_time "$home" set task-a "$FUTURE" >/dev/null
  calls_before=$(wc -l < "$case_dir/calls.log" | tr -d ' ')
  out=$(spawn_ship "$case_dir" task-a) || rc=$?
  expect_code 75 "$rc" "a spawn before the start time was not deferred: $out"
  assert_contains "$out" "deferred:" "the spawn did not report a deferral"
  assert_contains "$out" "$FUTURE" "the spawn deferral did not name the start time"
  assert_absent "$home/state/task-a.meta" "a deferred spawn published a task record"
  assert_absent "$home/data/task-a/launch-brief.md" "a deferred spawn rendered a launch brief"
  assert_equals "$calls_before" "$(wc -l < "$case_dir/calls.log" | tr -d ' ')" \
    "a deferred spawn touched the terminal or worktree pool"
  assert_equals queued "$(row_state "$home" task-a)" "a deferred spawn moved the item out of Queued"
  start_time "$home" set task-a "$PAST" >/dev/null
  rc=0
  out=$(spawn_ship "$case_dir" task-a) || rc=$?
  expect_code 0 "$rc" "a spawn after the start time was refused: $out"
  assert_contains "$out" "spawned task-a" "a spawn after the start time did not launch"
  assert_equals in_flight "$(row_state "$home" task-a)" "the launched item did not move In flight"
  pass "spawn leaves the item queued before the start time and launches it after"
}

test_scan_wakes_once_when_the_time_arrives() {
  local home out rows
  home="$TMP_ROOT/scan"
  make_home "$home" task-a task-b task-c
  start_time "$home" set task-a "$FUTURE" >/dev/null
  start_time "$home" set task-b "$PAST" >/dev/null
  out=$(start_time "$home" scan) || fail "scan failed"
  assert_contains "$out" "task-b" "scan did not name the item whose time arrived"
  assert_not_contains "$out" "task-a" "scan woke for a start time still in the future"
  assert_not_contains "$out" "task-c" "scan woke for an item with no start time"
  rows=$(wake_rows "$home")
  [ "$(printf '%s\n' "$rows" | grep -c .)" = 1 ] || fail "scan queued $(printf '%s\n' "$rows" | grep -c .) wakes: $rows"
  assert_contains "$rows" "check: start-time:" "the wake did not carry the start-time label"
  assert_contains "$rows" "task-b" "the wake did not name the task"
  out=$(start_time "$home" scan) || fail "second scan failed"
  [ -z "$out" ] || fail "a repeat scan announced the same start time again: $out"
  [ "$(wake_rows "$home" | grep -c .)" = 1 ] || fail "a repeat scan queued another wake"
  start_time "$home" set task-b 2021-01-01T00:00Z >/dev/null
  out=$(start_time "$home" scan) || fail "scan after a new time failed"
  assert_contains "$out" "task-b" "a new start time did not re-arm the wake"
  start_time "$home" clear task-b >/dev/null
  assert_absent "$home/state/task-b.start-time-notified" "clear left its announcement record behind"
  pass "scan queues one wake per arrived start time and a new time re-arms it"
}

test_watcher_sweep_surfaces_the_arrival() {
  local home out rc=0 rows
  home="$TMP_ROOT/watcher"
  make_home "$home" task-a
  start_time "$home" set task-a "$PAST" >/dev/null
  out="$home/watcher.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 15 > "$out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher sweep did not wake for an arrived start time (rc=$rc): $(cat "$home/watcher.err")"
  assert_contains "$(cat "$out")" "check: start-time:" "the watcher did not surface the start-time wake"
  assert_contains "$(cat "$out")" "task-a" "the watcher wake did not name the task"
  rows=$(wake_rows "$home" | grep -c . || true)
  [ "$rows" = 1 ] || fail "the watcher sweep queued $rows start-time wakes"
  pass "the watcher's check sweep surfaces an arrived start time as one wake"
}

fm_test_run \
  test_set_show_clear_round_trip_keeps_the_body \
  test_invalid_times_are_refused \
  test_gate_defers_only_before_the_start_time \
  test_spawn_is_refused_before_the_time_and_allowed_after \
  test_scan_wakes_once_when_the_time_arrives \
  test_watcher_sweep_surfaces_the_arrival
