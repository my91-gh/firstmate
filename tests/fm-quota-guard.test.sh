#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-guard.sh - the quota ALERT -> PAUSE -> RESUME loop.
#
# Every case drives the real script through its documented interface and asserts
# only on observable effects: the durable wake queue, the durable paused records,
# the log on disk, and command output. Quota readings are injected through the
# script's documented FM_QUOTA_GUARD_QUOTA_CMD seam, so quota-axi's stable
# schemaVersion 3 data contract is pinned by fixture rather than reached over the
# network. Nothing here asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-quota-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-guard)

# The decision clock is pinned through the script's FM_QUOTA_GUARD_NOW seam, so
# "before the reset" and "after the reset" are properties of the fixture rather
# than of the day the suite happens to run. Wall-clock-relative literals would
# silently invert the moment real time passed them.
FIXED_NOW=1787054400             # 2026-08-18T12:00:00Z
NOW_EPOCH=                       # a case sets this to move the clock on purpose
PAST_NOW=2026-08-18T03:00:00Z    # a reset passed even earlier
BEFORE_NOW=2026-08-18T06:00:00Z  # a reset the pinned clock has already passed
AFTER_NOW=2026-08-19T00:00:00Z   # a reset still ahead of the pinned clock
LATER_NOW=2026-08-19T06:00:00Z   # later still, for an early window roll
LATEST_NOW=2026-08-19T12:00:00Z  # later again, for the roll that resumes

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- fixtures ---------------------------------------------------------------

# make_home <name>: an isolated state root with its own wake queue and guard dir.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# A provider block. window specs are "id:kind:percentUsed:resetsAt" triples.
provider_json() {  # <provider> <stale:true|false> <window-spec>...
  local provider=$1 stale=$2 spec id kind pct resets first=1
  printf '{"provider":"%s","label":"%s","source":"oauth","plan":"pro","windows":[' \
    "$provider" "$provider"
  shift 2
  for spec in "$@"; do
    IFS=: read -r id kind pct resets <<< "$spec"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"id":"%s","label":"%s","kind":"%s","percentUsed":%s,"resetsAt":"%s","percentRemaining":0}' \
      "$id" "$id" "$kind" "$pct" "$resets"
  done
  printf '],"state":{"status":"fresh","stale":%s,"refreshedAt":"2026-08-18T00:00:00Z"}}' "$stale"
}

# write_quota <home> <provider-json>...: install the fixture the guard will read.
write_quota() {
  local home=$1 first=1 block
  shift
  {
    printf '{"generatedAt":"2026-08-18T00:00:00Z","schemaVersion":3,"providers":['
    for block in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '%s' "$block"
    done
    printf ']}\n'
  } > "$home/quota.json"
}

# Default healthy fixture: everything well below the threshold.
write_healthy() {  # <home>
  local home=$1
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:20:2026-08-18T21:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
}

# run_guard <home> [env-assignments...] -- <args...>
run_guard() {
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" \
  FM_QUOTA_GUARD_QUOTA_CMD="cat $home/quota.json" \
  FM_QUOTA_GUARD_NOW="${NOW_EPOCH:-$FIXED_NOW}" \
    "$GUARD" "$@"
}

queue() { printf '%s/state/.wake-queue\n' "$1"; }
guard_log() { printf '%s/state/.quota-guard/guard.log\n' "$1"; }
record() { printf '%s/state/.quota-guard/paused/%s\n' "$1" "$2"; }

# count_wakes <home> <key>: durable queue records whose key field matches exactly.
count_wakes() {
  local home=$1 key=$2
  awk -F '\t' -v k="$key" 'NF >= 5 && $4 == k { n++ } END { print n + 0 }' \
    "$(queue "$home")" 2>/dev/null || printf '0\n'
}

# --- alert: the 95% edge trigger --------------------------------------------

# The core contract: an episode opens exactly once. A window that sits above the
# threshold for many polls must produce ONE alert, not one per poll, or every
# supervision turn during an outage would be spent re-reading the same wake.
test_alert_is_edge_triggered_once_per_episode() {
  local home n
  home=$(make_home edge-trigger)
  write_healthy "$home"

  run_guard "$home" poll >/dev/null 2>&1
  n=$(count_wakes "$home" "quota-guard:alert:claude/five_hour")
  [ "$n" -eq 0 ] || fail "a window below the threshold must not alert (got $n)"
  assert_absent "$(record "$home" claude.five_hour)" \
    "a window below the threshold must not leave a paused record"

  # Cross the threshold and stay there for three more polls.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:96:2026-08-18T21:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  run_guard "$home" poll >/dev/null 2>&1
  run_guard "$home" poll >/dev/null 2>&1

  n=$(count_wakes "$home" "quota-guard:alert:claude/five_hour")
  [ "$n" -eq 1 ] || fail "crossing the threshold must enqueue exactly one alert across repeated polls (got $n)"

  assert_present "$(record "$home" claude.five_hour)" \
    "an open episode must leave a durable paused record"
  assert_grep "resets_at=2026-08-18T21:00:00Z" "$(record "$home" claude.five_hour)" \
    "the paused record must carry the window's resetsAt"
  assert_grep "percent_used=96" "$(record "$home" claude.five_hour)" \
    "the paused record must carry the observed percentUsed"

  # The alert wake must name provider, window, usage and reset for the handler.
  assert_grep "quota-guard alert: claude/five_hour" "$(queue "$home")" \
    "the alert wake must name the provider and window"
  assert_grep "96% used" "$(queue "$home")" "the alert wake must carry current percentUsed"
  assert_grep "2026-08-18T21:00:00Z" "$(queue "$home")" "the alert wake must carry resetsAt"

  # Untouched windows must stay untouched.
  n=$(count_wakes "$home" "quota-guard:alert:claude/seven_day")
  [ "$n" -eq 0 ] || fail "a window below the threshold must not alert when a sibling window does"
  n=$(count_wakes "$home" "quota-guard:alert:codex/weekly")
  [ "$n" -eq 0 ] || fail "codex must not alert because a claude window did"

  pass "alert is edge-triggered once per exhaustion episode, per window"
}

# 95 is "reaches OR crosses", so the boundary value itself must alert. An
# off-by-one here would silently never fire for a provider that reports integers
# and stops exactly at its limit.
test_threshold_boundary_reaches_and_crosses() {
  local home
  home=$(make_home boundary)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:94.9:2026-08-18T21:00:00Z" \
      "seven_day:weekly:95:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "94.9% is below the 95% threshold and must not alert"
  [ "$(count_wakes "$home" "quota-guard:alert:claude/seven_day")" -eq 1 ] \
    || fail "exactly 95% reaches the threshold and must alert"

  pass "the threshold triggers at and above 95%, including a fractional reading"
}

# --- resume: reset AND proof of refresh --------------------------------------

test_resume_requires_reset_and_refresh() {
  local home n
  home=$(make_home resume)
  # Open an episode on a window whose reset is already in the past.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:2020-01-01T00:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "setup: the episode must open"

  # The reset time has passed, but quota has NOT refreshed. Resuming here would
  # put every worker straight back into the wall.
  run_guard "$home" poll >/dev/null 2>&1
  n=$(count_wakes "$home" "quota-guard:resume:claude/five_hour")
  [ "$n" -eq 0 ] || fail "a passed reset with usage still at the wall must not resume (got $n)"
  assert_present "$(record "$home" claude.five_hour)" \
    "a premature resume must not clear the paused record"
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "staying paused must not re-alert"

  # Now the window genuinely refreshed.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:3:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  n=$(count_wakes "$home" "quota-guard:resume:claude/five_hour")
  [ "$n" -eq 1 ] || fail "a passed reset plus a confirmed refresh must resume exactly once (got $n)"
  assert_absent "$(record "$home" claude.five_hour)" \
    "resuming must clear the window's paused record"
  assert_grep "quota-guard resume: claude/five_hour" "$(queue "$home")" \
    "the resume wake must name the provider and window"

  # A further poll on the refreshed window must stay quiet.
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 1 ] \
    || fail "a cleared episode must not resume again"

  pass "resume needs both the reset and a confirmed refresh, then fires exactly once"
}

# A refresh alone, before the recorded reset, is not a resume: the guard keeps
# the episode until the window it recorded actually turns over.
test_refresh_before_reset_does_not_resume() {
  local home
  home=$(make_home early-refresh)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  # Usage drops but the SAME far-future window is still the one in force.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:5:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 0 ] \
    || fail "a usage drop inside the same unexpired window must not resume"
  assert_present "$(record "$home" claude.five_hour)" \
    "the episode must stay open until its window turns over"

  pass "a usage drop inside the recorded window does not resume on its own"
}

# A window that rolled EARLY still rolled: a strictly later resetsAt plus usage
# back below the threshold is genuine proof of refresh, and it never resumes
# without that usage drop.
test_rolled_window_resumes_on_new_reset_plus_refresh() {
  local home
  home=$(make_home rolled)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:97:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  # A strictly later reset, but usage still at the wall: still no resume.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:97:$LATER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 0 ] \
    || fail "a rolled window with usage still at the wall must not resume"
  assert_grep "resets_at=$LATER_NOW" "$(record "$home" claude.five_hour)" \
    "a rolled window must update the recorded reset so the next check tests the real window"
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "following a rolled reset must not re-alert; it is the same episode"

  # Now the roll is accompanied by a real drop.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:2:$LATEST_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 1 ] \
    || fail "a rolled window with usage back below the threshold must resume once"

  pass "an early window roll resumes only together with a confirmed usage drop"
}

# Alert and resume must be tellable apart by the handler, or Firstmate cannot
# know whether to pause or restart work.
test_alert_and_resume_wakes_are_distinguishable() {
  local home alert_line resume_line
  home=$(make_home distinguishable)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:2020-01-01T00:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:1:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  alert_line=$(awk -F '\t' '$4 == "quota-guard:alert:claude/five_hour" { print $5 }' "$(queue "$home")")
  resume_line=$(awk -F '\t' '$4 == "quota-guard:resume:claude/five_hour" { print $5 }' "$(queue "$home")")

  [ -n "$alert_line" ] || fail "the alert wake must survive in the durable queue"
  [ -n "$resume_line" ] || fail "the resume wake must survive in the durable queue"
  [ "$alert_line" != "$resume_line" ] || fail "alert and resume payloads must differ"
  assert_contains "$alert_line" "alert" "the alert payload must be self-describing"
  assert_contains "$resume_line" "resume" "the resume payload must be self-describing"
  assert_not_contains "$resume_line" "quota-guard alert" "the resume payload must not read as an alert"

  pass "alert and resume wakes carry distinct keys and distinct payloads"
}

# The reset side of every decision reads the clock through FM_QUOTA_GUARD_NOW.
# Pinning that seam is what makes "before the reset" and "after the reset"
# properties of the fixture, so the seam itself is asserted here: the same
# fixture and the same durable record must decide differently on either side of
# the window's reset, with nothing but the injected instant changed.
test_reset_decisions_read_the_injected_clock() {
  local home
  home=$(make_home clock-seam)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "setup: the episode must open"

  # The window reads as refreshed, but the injected now is before its reset.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:2:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 0 ] \
    || fail "before the injected now reaches the reset, the episode must stay open"

  # Nothing changes but the clock, which now sits past the reset.
  NOW_EPOCH=$((FIXED_NOW + 172800))
  run_guard "$home" poll >/dev/null 2>&1
  NOW_EPOCH=
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 1 ] \
    || fail "moving the injected clock past the reset must resume the episode"

  pass "reset decisions follow the injected clock, so no assertion rides the wall clock"
}

# An alert wake that cannot be enqueued must not be lost while the window is
# still exhausted: Firstmate would keep dispatching into it and then receive a
# resume for a pause it never performed. The episode keeps owing the alert until
# delivery is recorded, and that recorded delivery is what makes it one alert.
# The retried wake must describe the reading that OPENED the episode, because a
# wake that says "at 97% used" while quoting a later, healthier reading would
# pause the whole fleet on a payload that contradicts itself.
test_alert_wake_is_retried_while_the_window_is_still_exhausted() {
  local home seq payload
  home=$(make_home alert-retry)
  # The episode opens on a window whose reset has already passed, so the only
  # thing standing between the later refresh and a resume is the owed alert.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:$BEFORE_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"

  # Make the durable queue refuse an append for one cycle, the way a full disk or
  # an unwritable state directory would.
  seq="$home/state/.wake-queue.seq"
  mkdir -p "$seq" || fail "setup: could not block the wake queue"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "setup: no alert can be enqueued while the queue refuses appends"
  assert_present "$(record "$home" claude.five_hour)" \
    "an alert that could not be enqueued must leave the episode open"
  assert_grep "could not be enqueued" "$(guard_log "$home")" \
    "a failed alert enqueue must be logged loudly"

  # The queue recovers while the window is still exhausted, and the reading has
  # moved on. The retry must still quote the stored 99% and the stored reset.
  rmdir "$seq" || fail "setup: could not restore the wake queue"
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:97:$PAST_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "an alert that failed to enqueue must be retried and delivered exactly once"

  payload=$(awk -F '\t' '$4 == "quota-guard:alert:claude/five_hour" { print $5 }' "$(queue "$home")")
  assert_contains "$payload" "99% used" \
    "a retried alert must quote the percentUsed stored when the episode opened"
  assert_contains "$payload" "$BEFORE_NOW" \
    "a retried alert must quote the resetsAt stored when the episode opened"
  assert_not_contains "$payload" "97% used" \
    "a retried alert must not describe a later reading than the one it was raised for"
  assert_not_contains "$payload" "$PAST_NOW" \
    "a retried alert must not describe a later reset than the one it was raised for"

  # Delivery is recorded durably, so no later cycle re-alerts.
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "an episode whose alert was delivered must never re-alert"

  # And an episode that really was alerted still owes its resume on refresh.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:2:$PAST_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 1 ] \
    || fail "an episode whose alert was delivered must resume exactly once on refresh"
  assert_absent "$(record "$home" claude.five_hour)" \
    "resuming must clear the paused record"

  pass "an owed alert is retried on the reading that opened the episode, and delivered once"
}

# The other half: an alert that was never delivered and whose window recovered on
# its own is abandoned, not sent late. Pausing the whole fleet for a window that
# is healthy again is worse than never alerting for it, and since Firstmate was
# never told to pause there is nothing to resume either.
test_undelivered_alert_is_suppressed_once_the_window_recovers() {
  local home seq
  home=$(make_home alert-suppressed)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:$BEFORE_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"

  seq="$home/state/.wake-queue.seq"
  mkdir -p "$seq" || fail "setup: could not block the wake queue"
  run_guard "$home" poll >/dev/null 2>&1
  assert_present "$(record "$home" claude.five_hour)" "setup: the episode must open"
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "setup: no alert can be enqueued while the queue refuses appends"

  # The queue recovers, but so has the window.
  rmdir "$seq" || fail "setup: could not restore the wake queue"
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:2:$BEFORE_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "an alert never delivered must not be sent once the window is healthy again"
  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 0 ] \
    || fail "a pause Firstmate never performed must not produce a resume wake"
  assert_absent "$(record "$home" claude.five_hour)" \
    "a suppressed episode must be closed, not left open forever"
  assert_grep "recovered to 2% before its alert could be delivered" "$(guard_log "$home")" \
    "a suppressed alert must be logged loudly enough to diagnose"

  # And the window is free to open a fresh episode when it is exhausted again.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "a suppressed episode must not stop the window alerting when it exhausts again"

  pass "an undelivered alert is suppressed when the window recovers first, with no resume"
}

# The delivery note is the only thing standing between one alert and one alert
# every two minutes, so it must survive the paused directory turning unwritable -
# a permissions change or a read-only remount - while the wake queue still works.
# Resume must not be gated on it either, or such a fault would strand the whole
# fleet paused forever.
test_delivery_note_survives_an_unwritable_paused_directory() {
  local home seq paused n
  [ "$(id -u)" -ne 0 ] || { pass "skipped as root: file modes do not restrict writes"; return 0; }

  home=$(make_home unwritable-paused)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:$BEFORE_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"

  # Open the episode with the alert still owed, so the delivery note has to be
  # written on a later cycle - the cycle that runs against the unwritable dir.
  seq="$home/state/.wake-queue.seq"
  mkdir -p "$seq" || fail "setup: could not block the wake queue"
  run_guard "$home" poll >/dev/null 2>&1
  assert_present "$(record "$home" claude.five_hour)" "setup: the episode must open"
  rmdir "$seq" || fail "setup: could not restore the wake queue"

  paused="$home/state/.quota-guard/paused"
  chmod a-w "$paused" || fail "setup: could not make the paused directory unwritable"

  run_guard "$home" poll >/dev/null 2>&1
  run_guard "$home" poll >/dev/null 2>&1
  run_guard "$home" poll >/dev/null 2>&1
  n=$(count_wakes "$home" "quota-guard:alert:claude/five_hour")
  [ "$n" -eq 1 ] || {
    chmod u+w "$paused"
    fail "an enqueued alert whose note could not be rewritten must not re-alert every cycle (got $n)"
  }

  # The window refreshes while the directory is still unwritable. The episode was
  # genuinely alerted, so it still owes its resume.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:2:$BEFORE_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  n=$(count_wakes "$home" "quota-guard:resume:claude/five_hour")
  chmod u+w "$paused" || fail "could not restore the paused directory"
  [ "$n" -eq 1 ] \
    || fail "a write fault must never stop a genuinely alerted episode resuming (got $n)"

  pass "an unwritable paused directory neither repeats the alert nor blocks the resume"
}

# quota-axi can report a window with no resetsAt at all. An episode opened there
# has no time condition it can ever satisfy, so without adopting the first usable
# reset it stays open forever and every task in its ledger stays paused.
test_episode_opened_without_a_usable_reset_still_resumes() {
  local home

  # <home> <unusable-resetsAt>
  check_unusable_reset() {
    local home=$1 bad=$2
    write_quota "$home" \
      "$(provider_json claude false \
        "five_hour:session:99:$bad" \
        "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
      "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
    run_guard "$home" poll >/dev/null 2>&1
    [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
      || fail "setup: a window with an unusable resetsAt ('$bad') must still open an episode"

    # A usable reset arrives and has already passed, but usage is still at the
    # wall. Adoption moves the time condition only; it must not resume alone.
    write_quota "$home" \
      "$(provider_json claude false \
        "five_hour:session:99:$BEFORE_NOW" \
        "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
      "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
    run_guard "$home" poll >/dev/null 2>&1
    [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 0 ] \
      || fail "adopting a passed reset must not resume while usage is still at the wall"
    assert_grep "resets_at=$BEFORE_NOW" "$(record "$home" claude.five_hour)" \
      "the episode must adopt the first usable reset time the provider reports"

    # Now the window has genuinely refreshed.
    write_quota "$home" \
      "$(provider_json claude false \
        "five_hour:session:2:$BEFORE_NOW" \
        "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
      "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
    run_guard "$home" poll >/dev/null 2>&1
    [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 1 ] \
      || fail "an episode opened without a usable reset must resume on a passed reset plus a refresh"
    assert_absent "$(record "$home" claude.five_hour)" \
      "resuming must clear the window's paused record"
    [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
      || fail "adopting a reset time must not re-alert; it is the same episode"
  }

  home=$(make_home no-reset-missing)
  check_unusable_reset "$home" ""
  home=$(make_home no-reset-unparseable)
  check_unusable_reset "$home" "not-a-time"

  pass "an episode opened without a usable resetsAt adopts one and still resumes on proof of refresh"
}

# --- resilience: bad data never decides anything -----------------------------

test_stale_and_missing_data_never_decide() {
  local home log
  home=$(make_home resilience)
  log=$(guard_log "$home")

  # 1. A provider that declares its own data stale.
  write_quota "$home" \
    "$(provider_json claude true \
      "five_hour:session:99:2020-01-01T00:00:00Z" \
      "seven_day:weekly:99:2020-01-01T00:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "a stale provider reading must not open an episode"
  assert_grep "stale" "$log" "a stale provider must be logged loudly"

  # 2. A provider missing from the output entirely.
  write_quota "$home" "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "a missing provider must not open an episode"
  assert_grep "provider missing" "$log" "a missing provider must be logged loudly"

  # 3. A provider present but the tracked window absent.
  write_quota "$home" \
    "$(provider_json claude false "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  assert_grep "window missing" "$log" "a missing window must be logged loudly"

  # 4. A non-numeric percentUsed.
  cat > "$home/quota.json" <<'EOF'
{"generatedAt":"2026-08-18T00:00:00Z","schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},
  "windows":[{"id":"five_hour","kind":"session","percentUsed":"n/a","resetsAt":"2026-08-18T21:00:00Z"}]}]}
EOF
  run_guard "$home" poll >/dev/null 2>&1
  assert_grep "percentUsed absent or not a number" "$log" \
    "a non-numeric percentUsed must be logged loudly"

  # 5. The quota command itself fails.
  FM_STATE_OVERRIDE="$home/state" FM_QUOTA_GUARD_QUOTA_CMD="false" \
    FM_QUOTA_GUARD_NOW="$FIXED_NOW" "$GUARD" poll >/dev/null 2>&1 \
    || fail "a failing quota command must not fail the poll"
  assert_grep "quota read failed" "$log" "a failing quota read must be logged loudly"

  # 6. The quota command emits unparseable output.
  FM_STATE_OVERRIDE="$home/state" FM_QUOTA_GUARD_QUOTA_CMD="printf 'not json'" \
    FM_QUOTA_GUARD_NOW="$FIXED_NOW" "$GUARD" poll >/dev/null 2>&1 \
    || fail "unparseable quota output must not fail the poll"

  # Through all six, nothing was decided and no record was written.
  assert_absent "$(record "$home" claude.five_hour)" \
    "no unusable reading may open an episode"
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 0 ] \
    || fail "no unusable reading may enqueue an alert"

  # And the loop still works afterwards: resilience means continuing, not surviving.
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:2026-08-18T21:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "the guard must still alert normally after a run of bad polls"

  pass "stale, missing, malformed and failed readings are logged and never decide"
}

# A stale reading must not close an open episode either - that is the direction
# that would resume work into an exhausted window.
test_stale_reading_cannot_resume_an_open_episode() {
  local home
  home=$(make_home stale-resume)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:2020-01-01T00:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  # Stale data that would otherwise look like a clean refresh.
  write_quota "$home" \
    "$(provider_json claude true \
      "five_hour:session:0:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 0 ] \
    || fail "a stale reading must never close an open episode"
  assert_present "$(record "$home" claude.five_hour)" \
    "a stale reading must leave the paused record intact"

  pass "a stale reading cannot resume work into a possibly exhausted window"
}

# --- durability --------------------------------------------------------------

# The whole point of a durable record: a guard that restarts mid-episode still
# owes the resume.
test_open_episode_survives_a_guard_restart() {
  local home
  home=$(make_home crash-safe)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:2020-01-01T00:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1
  assert_present "$(record "$home" claude.five_hour)" "setup: the episode must open"

  # Simulate a crash: drop every volatile artifact except the durable records.
  rm -f "$home/state/.quota-guard/last-poll" "$(guard_log "$home")"
  rm -rf "$home/state/.quota-guard/guard.lock" "$home/state/.quota-guard/poll.lock"

  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:1:$AFTER_NOW" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  [ "$(count_wakes "$home" "quota-guard:resume:claude/five_hour")" -eq 1 ] \
    || fail "a fresh guard process must still owe the resume for a pending episode"
  [ "$(count_wakes "$home" "quota-guard:alert:claude/five_hour")" -eq 1 ] \
    || fail "a restart must not re-alert an episode it inherited"

  pass "an open episode survives a guard restart and its resume is not lost"
}

# --- log retention -----------------------------------------------------------

# The header's ceiling is (LOG_KEEP + 1) * LOG_MAX_BYTES. Drive far more log
# volume than that ceiling through the real rotation path and assert the total on
# disk stays bounded, so an unbounded log can never fill the captain's disk.
#
# The case measures the volume it actually generates and asserts that volume
# EXCEEDS the ceiling before asserting the bound holds. Without that check the
# test passes trivially whenever the fixture happens to log less than the cap -
# which is exactly how a removed rotation call would slip through unnoticed.
test_log_stays_under_its_retention_cap() {
  local home cap keep polls dir total ceiling unrotated files

  # A small cap and a noisy fixture reach the ceiling in a few polls. Each guard
  # invocation is a process, so the count is kept low deliberately: the bound
  # being proved does not depend on how many polls it took to overrun it.
  cap=300
  keep=2
  polls=8
  ceiling=$(( (keep + 1) * cap ))

  # A reading that logs one line per tracked window plus the poll summary, so
  # each cycle writes a realistic multi-line record rather than a single line.
  seed_noisy_quota() {
    write_quota "$1" \
      "$(provider_json claude true \
        "five_hour:session:50:2026-08-18T21:00:00Z" \
        "seven_day:weekly:50:2026-08-23T18:00:00Z")" \
      "$(provider_json codex true "weekly:weekly:50:2026-08-20T15:00:00Z")"
  }

  # Control run: the same fixture and the same number of polls with rotation far
  # out of reach, to measure how many bytes this workload really produces.
  home=$(make_home log-cap-control)
  seed_noisy_quota "$home"
  for _ in $(seq 1 "$polls"); do
    FM_STATE_OVERRIDE="$home/state" \
    FM_QUOTA_GUARD_QUOTA_CMD="cat $home/quota.json" \
    FM_QUOTA_GUARD_LOG_MAX_BYTES=100000000 FM_QUOTA_GUARD_LOG_KEEP=2 \
    FM_QUOTA_GUARD_NOW="$FIXED_NOW" \
      "$GUARD" poll >/dev/null 2>&1
  done
  unrotated=$(wc -c < "$(guard_log "$home")" | tr -d '[:space:]')

  # Non-vacuity: this workload must genuinely overrun the ceiling, or the bound
  # below proves nothing.
  [ "$unrotated" -gt "$ceiling" ] \
    || fail "test setup is vacuous: $polls polls wrote only $unrotated bytes, under the $ceiling ceiling"

  # Capped run: identical workload, real rotation.
  home=$(make_home log-cap)
  seed_noisy_quota "$home"
  dir="$home/state/.quota-guard"
  for _ in $(seq 1 "$polls"); do
    FM_STATE_OVERRIDE="$home/state" \
    FM_QUOTA_GUARD_QUOTA_CMD="cat $home/quota.json" \
    FM_QUOTA_GUARD_LOG_MAX_BYTES=$cap FM_QUOTA_GUARD_LOG_KEEP=$keep \
    FM_QUOTA_GUARD_NOW="$FIXED_NOW" \
      "$GUARD" poll >/dev/null 2>&1
  done

  total=$(cat "$dir"/guard.log "$dir"/guard.log.* 2>/dev/null | wc -c | tr -d '[:space:]')
  [ "$total" -gt 0 ] || fail "the guard must actually be writing a log"
  # A single append may cross the active cap, so allow one line of overshoot.
  [ "$total" -le $((ceiling + 512)) ] \
    || fail "total log bytes ($total) exceeded the retention ceiling ($ceiling); unrotated volume was $unrotated"

  files=$(find "$dir" -maxdepth 1 -name 'guard.log*' | wc -l | tr -d '[:space:]')
  [ "$files" -le $((keep + 1)) ] \
    || fail "rotations beyond the keep count must be deleted, found $files files"
  assert_absent "$dir/guard.log.$((keep + 1))" "no rotation beyond the keep count may survive"

  pass "the rotating log stays under (keep + 1) x max-bytes with rotations pruned ($unrotated bytes written, $total retained)"
}

# --- single instance and lifecycle ------------------------------------------

test_second_start_is_a_harmless_no_op() {
  local home out rc pid start_pid waited
  home=$(make_home single-instance)
  write_healthy "$home"

  # tests/lib.sh disables arming for every suite so no test leaks a daemon.
  # This case is about the real single-instance behaviour, so it opts back in and
  # is responsible for stopping what it starts.
  FM_STATE_OVERRIDE="$home/state" \
  FM_QUOTA_GUARD_QUOTA_CMD="cat $home/quota.json" \
  FM_QUOTA_GUARD_INTERVAL=1 FM_QUOTA_GUARD_NO_ARM=0 \
    "$GUARD" arm >/dev/null 2>&1 || fail "arm must start a guard"

  pid=$(cat "$home/state/.quota-guard/guard.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "an armed guard must record its pid in the lock"

  # A second start must decline quietly and exit 0, not run a second poller.
  # Run it BOUNDED: if the single-instance check ever regressed, `start` would
  # enter its poll loop and never return, hanging the whole suite instead of
  # failing it. This asserts "it exited" as part of the behaviour under test.
  run_guard "$home" start > "$home/start.out" 2>&1 &
  start_pid=$!
  waited=0
  while kill -0 "$start_pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    waited=$((waited + 1))
    sleep 0.1
  done
  if kill -0 "$start_pid" 2>/dev/null; then
    kill -TERM "$start_pid" 2>/dev/null || true
    wait "$start_pid" 2>/dev/null || true
    fail "a second start ran its poll loop instead of declining to the live guard"
  fi
  wait "$start_pid"; rc=$?
  out=$(cat "$home/start.out")
  expect_code 0 "$rc" "a second start while one is live"
  assert_contains "$out" "already running" "a second start must report the live guard"
  assert_contains "$out" "$pid" "a second start must name the live guard's pid"

  # arm is likewise idempotent.
  FM_STATE_OVERRIDE="$home/state" \
  FM_QUOTA_GUARD_QUOTA_CMD="cat $home/quota.json" \
  FM_QUOTA_GUARD_NO_ARM=0 \
    "$GUARD" arm >/dev/null 2>&1 || fail "a second arm must be a harmless no-op"
  [ "$(cat "$home/state/.quota-guard/guard.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    || fail "a second arm must not replace the live guard"

  out=$(run_guard "$home" stop 2>&1); rc=$?
  expect_code 0 "$rc" "stop on a live guard"
  assert_contains "$out" "stopped" "stop must confirm the guard stopped"

  out=$(run_guard "$home" stop 2>&1); rc=$?
  expect_code 0 "$rc" "stop when nothing is running"
  assert_contains "$out" "not running" "stop must be idempotent"

  pass "the guard is single-instance; a second start or arm is a harmless no-op"
}

# A guard that outlives the home it watches is an immortal orphan: fixture homes
# and retired homes are deleted while their guard keeps polling a directory that
# no longer exists, and they accumulate one per home ever started. Reproduced by
# deleting the home under a live guard.
test_guard_exits_when_its_home_disappears() {
  local home pid waited
  home=$(make_home orphan)
  write_healthy "$home"

  FM_STATE_OVERRIDE="$home/state" \
  FM_QUOTA_GUARD_QUOTA_CMD="cat $home/quota.json" \
  FM_QUOTA_GUARD_INTERVAL=1 FM_QUOTA_GUARD_NO_ARM=0 \
    "$GUARD" arm >/dev/null 2>&1 || fail "arm must start a guard"
  pid=$(cat "$home/state/.quota-guard/guard.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "an armed guard must record its pid"
  kill -0 "$pid" 2>/dev/null || fail "the guard must be alive before the home is removed"

  rm -rf "$home/state/.quota-guard"

  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    waited=$((waited + 1))
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "the guard kept running after its home was deleted (immortal orphan)"
  fi

  pass "a guard exits on its own once the home it watches is gone"
}

# --- the per-task pause ledger ----------------------------------------------

test_paused_task_ledger_round_trip() {
  local home out rc
  home=$(make_home task-ledger)
  write_healthy "$home"

  run_guard "$home" pause-task fm-alpha claude/five_hour >/dev/null \
    || fail "pause-task must record a task"
  run_guard "$home" pause-task fm-beta claude/five_hour >/dev/null \
    || fail "pause-task must record a second task"
  run_guard "$home" pause-task fm-gamma codex/weekly >/dev/null \
    || fail "pause-task must record a task against another window"

  # Idempotent per task and window.
  run_guard "$home" pause-task fm-alpha claude/five_hour >/dev/null \
    || fail "pause-task must be idempotent"

  out=$(run_guard "$home" status 2>&1)
  assert_contains "$out" "fm-alpha" "status must list a paused task"
  assert_contains "$out" "fm-gamma" "status must list tasks paused for other windows"

  out=$(run_guard "$home" resume-tasks claude/five_hour 2>/dev/null)
  assert_contains "$out" "fm-alpha" "resume-tasks must return the tasks paused for that window"
  assert_contains "$out" "fm-beta" "resume-tasks must return every task paused for that window"
  assert_not_contains "$out" "fm-gamma" "resume-tasks must not release another window's tasks"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "resume-tasks must return exactly the two tasks paused for that window"

  # The ledger is cleared, so a second resume releases nothing twice.
  out=$(run_guard "$home" resume-tasks claude/five_hour 2>/dev/null)
  [ -z "$out" ] || fail "resume-tasks must clear the ledger it released"

  out=$(run_guard "$home" resume-tasks codex/weekly 2>/dev/null)
  assert_contains "$out" "fm-gamma" "the other window's ledger must be untouched"

  # An unknown window and an unsafe task id are refused, not silently accepted.
  run_guard "$home" pause-task fm-alpha claude/nope >/dev/null 2>&1 \
    && fail "an untracked window must be refused"
  run_guard "$home" pause-task "../escape" claude/five_hour >/dev/null 2>&1 \
    && fail "an unsafe task id must be refused"

  pass "the per-task pause ledger records, lists, releases once, and refuses bad input"
}

# --- status and help ---------------------------------------------------------

test_status_reports_windows_and_records_without_mutating() {
  local home out before after
  home=$(make_home status)
  write_quota "$home" \
    "$(provider_json claude false \
      "five_hour:session:99:2026-08-18T21:00:00Z" \
      "seven_day:weekly:40:2026-08-23T18:00:00Z")" \
    "$(provider_json codex false "weekly:weekly:10:2026-08-20T15:00:00Z")"
  run_guard "$home" poll >/dev/null 2>&1

  before=$(cat "$(queue "$home")")
  out=$(run_guard "$home" status 2>&1)
  after=$(cat "$(queue "$home")")

  assert_contains "$out" "claude/five_hour" "status must list every tracked window"
  assert_contains "$out" "claude/seven_day" "status must list every tracked window"
  assert_contains "$out" "codex/weekly" "status must list every tracked window"
  assert_contains "$out" "not running" "status must report guard liveness"
  assert_contains "$out" "99% used" "status must report current usage"
  assert_contains "$out" "waiting for reset" "status must report an open episode"
  [ "$before" = "$after" ] || fail "status must not mutate the wake queue"

  # A degraded quota read must not break status.
  out=$(FM_STATE_OVERRIDE="$home/state" FM_QUOTA_GUARD_QUOTA_CMD="false" \
    FM_QUOTA_GUARD_NOW="$FIXED_NOW" "$GUARD" status 2>&1) \
    || fail "status must survive an unavailable quota read"
  assert_contains "$out" "unavailable" "status must say so when the quota read fails"
  assert_contains "$out" "waiting for reset" "status must still report durable records"

  pass "status reports live windows and durable records without mutating anything"
}

test_help_documents_the_interface() {
  local out rc
  out=$("$GUARD" --help 2>&1); rc=$?
  expect_code 2 "$rc" "--help"
  for word in start arm poll status stop pause-task resume-tasks \
    FM_QUOTA_GUARD_INTERVAL FM_QUOTA_GUARD_THRESHOLD FM_QUOTA_GUARD_QUOTA_CMD; do
    assert_contains "$out" "$word" "--help must document $word"
  done
  out=$("$GUARD" bogus-verb 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown verb"

  # Help is rendered from the header, so a range that outlives its header spills
  # script source into the operator's terminal. Pin the boundary, not the length.
  assert_not_contains "$out" "SCRIPT_DIR=" "--help must not leak script source"
  assert_not_contains "$out" "set -u" "--help must not leak script source"
  assert_not_contains "$out" "shellcheck source" "--help must not leak shell directives"
  assert_contains "$out" "durable per-task pause ledger" "--help must render the whole header, not a truncated prefix"

  pass "--help documents every subcommand and override, and renders exactly the header"
}

test_alert_is_edge_triggered_once_per_episode
test_threshold_boundary_reaches_and_crosses
test_resume_requires_reset_and_refresh
test_refresh_before_reset_does_not_resume
test_rolled_window_resumes_on_new_reset_plus_refresh
test_alert_and_resume_wakes_are_distinguishable
test_reset_decisions_read_the_injected_clock
test_alert_wake_is_retried_while_the_window_is_still_exhausted
test_undelivered_alert_is_suppressed_once_the_window_recovers
test_delivery_note_survives_an_unwritable_paused_directory
test_episode_opened_without_a_usable_reset_still_resumes
test_stale_and_missing_data_never_decide
test_stale_reading_cannot_resume_an_open_episode
test_open_episode_survives_a_guard_restart
test_log_stays_under_its_retention_cap
test_second_start_is_a_harmless_no_op
test_guard_exits_when_its_home_disappears
test_paused_task_ledger_round_trip
test_status_reports_windows_and_records_without_mutating
test_help_documents_the_interface
