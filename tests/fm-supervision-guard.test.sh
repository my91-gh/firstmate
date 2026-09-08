#!/usr/bin/env bash
# Regression tests for the out-of-band supervision liveness guard
# (bin/fm-supervision-guard.sh).
#
# These reproduce the two confirmed silent-outage incidents and pin the guard's
# recovery/alarm behavior:
#  - 2026-08-12 (away mode): the away daemon reaped while state/.afk stayed
#    present; nothing relaunched it and nothing alarmed.
#  - 2026-09-08 (ordinary supervision): the Stop-hook watcher reaped during an
#    idle window; a parked crewmate's status never became a wake and nothing
#    alarmed for ~63 minutes.
# Both are the same root cause on different paths: no OUT-OF-BAND detection. The
# guard closes that gap; these tests assert it self-recovers (afk) or alarms
# loudly (ordinary), gated so a normal between-turns window never false-trips.
set -u

# Source wake-helpers (which sources lib.sh) so the wedge-alarm notifier is forced
# to the on-disk recorder seam: no test can post a real desktop notification, and
# the recorder logs "<channel>\t<summary>" to FM_WEDGE_ALARM_LOG for assertions.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GUARD="$ROOT/bin/fm-supervision-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-guard)

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
ln -s /bin/bash "$FAKEBIN/claude"

FM_TEST_HARNESS_PIDS=()
guard_test_cleanup() {
  local pid s
  for pid in "${FM_TEST_HARNESS_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  # Reap any real guard daemon hosts this suite launched (test-created sessions
  # only, matched by the guard's own per-home name prefix).
  if command -v tmux >/dev/null 2>&1; then
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^fm-supguard-' | while IFS= read -r s; do
      tmux kill-session -t "$s" 2>/dev/null || true
    done
  fi
  fm_test_cleanup
}
trap guard_test_cleanup EXIT
trap 'guard_test_cleanup; exit 130' INT
trap 'guard_test_cleanup; exit 143' TERM

# 0. Sourced interface: the guard must define discover_supervisor_target and
#    discover_supervisor_backend at load time. Without them the busy gate reads an
#    empty target and always reports not-busy, so a long legitimate turn under the
#    ordinary autoarm model (which never exports FM_SUPERVISOR_TARGET) raises a
#    false SUPERVISION DOWN. Assert the sourced functions exist, not the text.
(
  FM_ROOT_OVERRIDE="$ROOT" . "$GUARD"
  command -v discover_supervisor_target >/dev/null 2>&1 \
    || { printf 'not ok - guard must define discover_supervisor_target\n' >&2; exit 1; }
  command -v discover_supervisor_backend >/dev/null 2>&1 \
    || { printf 'not ok - guard must define discover_supervisor_backend\n' >&2; exit 1; }
) || fail "sourcing the guard must define the supervisor-target discovery functions"
pass "guard sources supervisor-target-lib: discovery functions are defined"

# Fresh home with a live fake-claude primary recorded in state/.lock.
make_home() {
  local name=$1 dir pid
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config"
  # A persistent fake harness: bash invoked through the "claude" symlink must stay
  # the running process (never exec a child) so ps reports it as a live harness.
  # Its fds are redirected so it never holds this $() command substitution's pipe
  # open, which would deadlock the capture on the long-lived child.
  "$FAKEBIN/claude" -c 'while :; do sleep 1; done' >/dev/null 2>&1 &
  pid=$!
  FM_TEST_HARNESS_PIDS+=("$pid")
  printf '%s\n' "$pid" > "$dir/state/.lock"
  printf '%s\n' "$dir"
}

# Run one tick against <home>, autoarm model, pane forced to the given busy state
# (idle by default), capturing stdout. Extra env assignments precede the call.
tick() {
  local dir=$1 busy=${2:-0}
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISION_MODEL=autoarm \
    FM_GUARD_GRACE="${GRACE:-2}" FM_SUPERVISION_GUARD_CONFIRM="${CONFIRM:-90}" \
    FM_SUPERVISION_GUARD_PANE_BUSY="$busy" \
    FM_WEDGE_ALARM_LOG="${WEDGE_LOG:-/dev/null}" \
    "$GUARD" tick 2>/dev/null
}

need_work() { : > "$1/state/task.meta"; }
stale_beacon() { rm -f "$1/state/.last-watcher-beat"; }        # absent -> huge age -> stale
fresh_beacon() { touch "$1/state/.last-watcher-beat"; }
seed_sustained_outage() { printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$1/state/.supervision-guard-outage-since"; }

# 1. No live primary -> nothing to supervise; never alarms.
d=$(make_home no-primary); need_work "$d"; stale_beacon "$d"
deadpid=$(cat "$d/state/.lock"); kill "$deadpid" 2>/dev/null; wait "$deadpid" 2>/dev/null || true
out=$(tick "$d")
case "$out" in
  idle:*) pass "no live primary session -> idle, no supervision action" ;;
  *) fail "no-primary should be idle, got: $out" ;;
esac
[ -e "$d/state/.supervision-guard-outage" ] && fail "no-primary must not write an outage marker"

# 2. Primary alive but no work -> not needed.
d=$(make_home not-needed)
out=$(tick "$d")
case "$out" in
  ok:*not*needed*) pass "primary alive, no work -> supervision not needed" ;;
  *) fail "expected not-needed, got: $out" ;;
esac

# 3. Work in flight, fresh beacon -> healthy.
d=$(make_home healthy); need_work "$d"; fresh_beacon "$d"
out=$(tick "$d")
case "$out" in
  ok:*healthy*) pass "work in flight with a fresh beacon -> healthy" ;;
  *) fail "expected healthy, got: $out" ;;
esac

# 4. Ordinary autoarm, down beacon, captain pane BUSY -> a turn is running; the
#    Stop hook will re-arm. No alarm.
d=$(make_home busy-turn); need_work "$d"; stale_beacon "$d"
WEDGE_LOG="$d/wedge.log"; : > "$WEDGE_LOG"
out=$(tick "$d" 1)
case "$out" in
  ok:*between\ turns*) pass "autoarm down + busy pane -> between-turns, suppressed" ;;
  *) fail "expected between-turns suppression, got: $out" ;;
esac
[ -s "$WEDGE_LOG" ] && fail "busy-turn suppression must not raise an alarm"

# 5. Ordinary autoarm, down, idle, but inside the confirm window -> hold, no alarm.
d=$(make_home confirm-hold); need_work "$d"; stale_beacon "$d"
WEDGE_LOG="$d/wedge.log"; : > "$WEDGE_LOG"
out=$(CONFIRM=600 tick "$d" 0)
case "$out" in
  watch:*holding*) pass "down but within confirm window -> holds, no premature alarm" ;;
  *) fail "expected confirm-window hold, got: $out" ;;
esac
[ -s "$WEDGE_LOG" ] && fail "confirm-window hold must not alarm"

# 6. Ordinary autoarm, down, idle, SUSTAINED -> loud alarm + durable marker.
#    This is the 2026-09-08 regression: a reaped idle-window watcher must become
#    detectable and alarm, without depending on a captain message.
d=$(make_home ordinary-outage); need_work "$d"; stale_beacon "$d"; seed_sustained_outage "$d"
WEDGE_LOG="$d/wedge.log"; : > "$WEDGE_LOG"
out=$(FM_WEDGE_ALARM_CHANNEL=osascript tick "$d" 0)
case "$out" in
  alarm:*ordinary*) pass "sustained ordinary outage -> alarms loudly (2026-09-08 regression)" ;;
  *) fail "expected ordinary-outage alarm, got: $out" ;;
esac
[ -s "$d/state/.supervision-guard-outage" ] || fail "ordinary outage must write a durable marker"
grep -q "^osascript" "$WEDGE_LOG" || fail "ordinary outage must fire the active alarm channel"

# 7. Away mode, down, SUSTAINED -> relaunch the away daemon (self-recovery).
#    This is the 2026-08-12 regression.
d=$(make_home afk-outage); need_work "$d"; stale_beacon "$d"; seed_sustained_outage "$d"
: > "$d/state/.afk"
RELAUNCH_FLAG="$d/relaunched"
out=$(FM_SUPERVISION_GUARD_RELAUNCH_CMD="touch '$RELAUNCH_FLAG'" \
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" \
  FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISION_MODEL=autoarm FM_GUARD_GRACE=2 \
  FM_SUPERVISION_GUARD_CONFIRM=90 FM_SUPERVISION_GUARD_PANE_BUSY=0 \
  "$GUARD" tick 2>/dev/null)
case "$out" in
  recovered:*relaunched*) pass "sustained away-mode outage -> relaunches away daemon (2026-08-12 regression)" ;;
  *) fail "expected away-daemon relaunch, got: $out" ;;
esac
[ -e "$RELAUNCH_FLAG" ] || fail "away-mode recovery must invoke the daemon relaunch"
[ -e "$d/state/.supervision-guard-outage-since" ] && fail "successful recovery must clear the outage clock"

# 8. Away mode, down, SUSTAINED, relaunch FAILS -> alarm (captain is away).
d=$(make_home afk-relaunch-fail); need_work "$d"; stale_beacon "$d"; seed_sustained_outage "$d"
: > "$d/state/.afk"
WEDGE_LOG="$d/wedge.log"; : > "$WEDGE_LOG"
out=$(FM_SUPERVISION_GUARD_RELAUNCH_CMD="exit 1" FM_WEDGE_ALARM_CHANNEL=osascript \
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" \
  FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISION_MODEL=autoarm FM_GUARD_GRACE=2 \
  FM_SUPERVISION_GUARD_CONFIRM=90 FM_SUPERVISION_GUARD_PANE_BUSY=0 \
  FM_WEDGE_ALARM_LOG="$WEDGE_LOG" \
  "$GUARD" tick 2>/dev/null)
case "$out" in
  alarm:*relaunch\ failed*) pass "away-mode relaunch failure -> alarms" ;;
  *) fail "expected relaunch-failure alarm, got: $out" ;;
esac
grep -q "^osascript" "$WEDGE_LOG" || fail "relaunch-failure must fire the active alarm"

# 9. Alarm rate-limit: a second sustained tick inside the re-alarm window does not
#    re-fire the active alert, but the durable marker stays.
d=$(make_home rate-limit); need_work "$d"; stale_beacon "$d"; seed_sustained_outage "$d"
WEDGE_LOG="$d/wedge.log"; : > "$WEDGE_LOG"
for _ in 1 2; do
  FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISION_GUARD_REALARM=1800 tick "$d" 0 >/dev/null
done
fires=$(grep -c "^osascript" "$WEDGE_LOG" || true)
[ "$fires" = 1 ] || fail "active alarm should fire once per re-alarm window, fired $fires times"
[ -s "$d/state/.supervision-guard-outage" ] || fail "durable outage marker must persist across ticks"
pass "active alarm is rate-limited to once per re-alarm window; durable marker persists"

# --- herdr host launch (stubbed backend CLI; runs without a real herdr) --------
# Mirrors the afk-launch herdr unit test: stub the backend CLI and assert the
# guard records the exact non-visible workspace/pane it created.
d=$(make_home herdr-host); need_work "$d"
herdr_rec=$(
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" \
    FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISOR_TARGET="lab:captain" \
    FM_SUPERVISION_GUARD_HOST_BACKEND=herdr FM_SUPERVISION_GUARD_ENTRY=/bin/true \
    FM_SUPERVISION_GUARD_LABEL=g-label bash -c '
      # shellcheck disable=SC1090
      . "'"$GUARD"'"
      fm_backend_source() { return 0; }
      fm_backend_herdr_server_ensure() { return 0; }
      fm_backend_herdr_cli() {
        case "$2" in
          workspace) printf "%s" "{\"result\":{\"workspace\":{\"workspace_id\":\"ws-1\"},\"root_pane\":{\"pane_id\":\"pane-1\"}}}" ;;
          pane) return 0 ;;
        esac
      }
      fm_supervision_guard_launch_host >/dev/null 2>&1
      cat "$FM_STATE_OVERRIDE/.supervision-guard-terminal"
    '
)
if [ "$herdr_rec" = "$(printf 'herdr\tlab:pane-1\tws-1')" ]; then
  pass "herdr host: launches a non-visible workspace and records its exact id"
else
  fail "herdr host record wrong: [$herdr_rec]"
fi

# --- durable-host lifecycle (needs tmux; the guard host is a detached session) --
# Runs the REAL daemon inside the detached host so the guard lock is actually
# taken; that lock is what makes `status` and `ensure` idempotency honest.
if command -v tmux >/dev/null 2>&1; then
  host_env() {
    local dir=$1
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_ROOT_OVERRIDE="$ROOT" FM_GUARD_GRACE=2 FM_WEDGE_ALARM_LOG=/dev/null \
      "$GUARD" "${@:2}"
  }

  d=$(make_home lifecycle); need_work "$d"
  host_env "$d" ensure >/dev/null 2>&1
  if host_env "$d" status >/dev/null 2>&1; then
    pass "ensure launches a detached guard host when supervision is needed"
  else
    fail "ensure should leave a live guard host"
  fi
  sess=$(awk -F'\t' 'NR==1{print $2}' "$d/state/.supervision-guard-terminal" 2>/dev/null)
  tmux has-session -t "$sess" 2>/dev/null || fail "the recorded tmux host session should exist"

  # Idempotent: a second ensure does not create a second host.
  before=$sess
  host_env "$d" ensure >/dev/null 2>&1
  after=$(awk -F'\t' 'NR==1{print $2}' "$d/state/.supervision-guard-terminal" 2>/dev/null)
  [ "$before" = "$after" ] || fail "ensure must be idempotent, not spawn a second host"
  pass "ensure is idempotent when a live guard host already runs"

  host_env "$d" stop >/dev/null 2>&1
  tmux has-session -t "$sess" 2>/dev/null && fail "stop must close the recorded host by exact id"
  [ -e "$d/state/.supervision-guard-terminal" ] && fail "stop must drop the host record"
  pass "stop tears down the guard host and clears its record"

  # ensure no-ops when supervision is not needed.
  d=$(make_home lifecycle-idle)
  host_env "$d" ensure >/dev/null 2>&1
  [ -e "$d/state/.supervision-guard-terminal" ] && fail "ensure must no-op when supervision is not needed"
  pass "ensure no-ops when supervision is not needed"

  # reconcile drops a recorded-but-dead host.
  d=$(make_home reconcile); need_work "$d"
  printf 'tmux\tfm-supguard-dead-session-xyz\n' > "$d/state/.supervision-guard-terminal"
  host_env "$d" reconcile >/dev/null 2>&1
  rec=$(awk -F'\t' 'NR==1{print $2}' "$d/state/.supervision-guard-terminal" 2>/dev/null)
  [ "$rec" = "fm-supguard-dead-session-xyz" ] && fail "reconcile must drop a dead host record"
  # reconcile then ensures a fresh one; tear it down.
  host_env "$d" stop >/dev/null 2>&1
  pass "reconcile drops a recorded-but-dead host and re-ensures"
else
  pass "SKIP durable-host lifecycle (tmux not available)"
fi

pass "all fm-supervision-guard checks passed"
