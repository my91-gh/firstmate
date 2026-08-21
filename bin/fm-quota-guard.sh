#!/usr/bin/env bash
# fm-quota-guard.sh - watch Claude and Codex quota and drive Firstmate's
# ALERT -> PAUSE -> RESUME cycle for work already under way.
#
# WHY THIS EXISTS. A crewmate that runs out of provider quota mid-task does not
# stop cleanly: it burns turns against a wall, and the work is neither landed nor
# safely parked. Quota exhaustion is knowable BEFORE it bites (quota-axi reports
# percentUsed and the window's resetsAt), but only if something watches
# continuously - a session that is busy supervising will not poll on its own.
# So this is a background loop, and it produces DURABLE WAKES rather than acting:
# the guard signals, Firstmate decides and acts. See the quota-guard-cycle skill
# for what Firstmate does with each wake.
#
# Usage:
#   fm-quota-guard.sh start          run the poll loop in the foreground
#   fm-quota-guard.sh arm            idempotently launch a detached loop
#   fm-quota-guard.sh poll           run exactly ONE poll cycle and exit
#   fm-quota-guard.sh status         print tracked windows and paused records
#   fm-quota-guard.sh stop           stop this home's running guard
#   fm-quota-guard.sh pause-task <task-id> <provider>/<window>
#   fm-quota-guard.sh resume-tasks <provider>/<window>
#   fm-quota-guard.sh --help
#
# start        Poll every FM_QUOTA_GUARD_INTERVAL seconds until stopped. Holds
#              this home's single-instance guard lock; a second start while a
#              live guard holds it prints one line and exits 0, so re-running it
#              is a harmless no-op rather than a second poller. Traps INT/TERM/HUP
#              and releases the lock on the way out.
# arm          What a session start calls. Returns immediately, leaves nothing on
#              stdout, and is a no-op when a live guard already holds the lock.
#              Detached three ways for the reasons bin/fm-startup-network.sh
#              documents: stdio to /dev/null (the digest's stdout is a pipe read
#              to EOF), nohup (outlive the launching shell), and its own process
#              group (the digest's bounded child terminates its whole group).
#              Fail-open by contract: a missing default reader (quota-axi) or a
#              missing jq is a silent exit 0, because bin/fm-bootstrap.sh already
#              owns the MISSING diagnostic for both, and no guard failure may
#              block a session start. An explicit FM_QUOTA_GUARD_QUOTA_CMD
#              supplies its own reader, so arming is not gated on quota-axi then.
# poll         One cycle, for operators and tests. Takes the same per-cycle poll
#              lock the loop takes, so a hand-run poll alongside a live guard
#              serializes instead of racing it into a duplicate wake.
# status       Live quota read plus every durable record. Never mutates.
# stop         Signal only the pid recorded in THIS home's guard lock, so it can
#              never reach a sibling firstmate home's guard.
# pause-task   Record that <task-id> was paused for a window, so the pause
#              survives a Firstmate restart. Idempotent per task and window.
# resume-tasks Print every task id paused for a window, newline separated, and
#              clear those records. Empty output means nothing was paused for it.
#
# TRACKED WINDOWS, and why exactly these three. quota-axi (schemaVersion 3)
# reports Claude with two windows - five_hour (kind session) and seven_day (kind
# weekly) - and Codex with one, weekly. Either Claude window alone can stop every
# Claude-backed worker, so both are tracked independently. The set is a constant
# here, not configuration: a window this guard does not know how to name is a
# window Firstmate cannot pause work for.
#
# ALERT is EDGE-TRIGGERED, and the durable paused record IS the edge. When a
# tracked window first reaches the threshold, the guard writes that window's
# paused record and enqueues exactly one alert wake. What suppresses every later
# alert is the RECORDED DELIVERY of that wake - alert_delivered=1 in the record -
# and not the mere existence of the record, so an exhausted window that stays
# exhausted for hours produces one wake, not one every two minutes.
#
# An alert wake that cannot be enqueued is never dropped. The episode stays open
# with alert_delivered=0, the failure is logged loudly, and the enqueue is
# RETRIED on every later cycle for as long as the window is still at or above
# the threshold. A retried alert quotes the percent_used and resets_at STORED in
# the record, never the current reading, so the wake always describes the
# exhaustion it was raised for and can never contradict itself.
#
# The note is written BEFORE the wake is enqueued, and that ordering is what
# makes alert_delivered=0 mean something. Recorded first, a note the guard could
# not write stops the enqueue outright, so the guard can never send an alert it
# has no record of sending. Were the order reversed, a note lost to a full or
# read-only filesystem would be indistinguishable from an alert that was never
# sent - and the guard would then have to guess, on the one decision where
# guessing wrong pauses the fleet forever.
#
# An episode is CLOSED SILENTLY - record removed, no alert wake and no resume
# wake - only on POSITIVE PROOF that its alert was never delivered: the record
# reads alert_delivered=0 AND no alert wake for that window is queued, and the
# window has since dropped back below the threshold. Firstmate was never told to
# pause, so there is nothing to resume, and pausing the fleet for a window that
# is healthy again is worse than never alerting for one that recovered on its
# own. The suppression is logged.
#
# ANY OTHER STATE COUNTS AS DELIVERED. A record whose note is missing, garbled,
# or unreadable - one written by an older guard, or damaged by a write fault -
# closes through the ordinary resume path and emits its resume wake. The
# asymmetry is deliberate: a resume for a pause that never happened costs one
# empty resume-tasks call, while a suppressed resume for a pause that did happen
# leaves every crewmate parked forever. So resume is never gated on the note,
# and no write fault can strand the fleet paused.
#
# The note is written through the record rewrite when it can be, and APPENDED
# when it cannot, because an append needs write permission on the record file
# alone. A paused directory that turns unwritable - a permissions change, a
# read-only remount - fails every rewrite, and an alert whose note cannot be
# written at all is an alert this guard declines to send, which without the
# fallback would mean an exhausted window nobody is told about. The record's
# last assignment of a field wins, which is what makes that append an update.
#
# A CLOSED EPISODE IS CLOSED EXACTLY ONCE, even when its record cannot be
# removed. The same unwritable paused directory that fails a rewrite also fails
# the unlink, and a record left on disk would otherwise be decided again on every
# later cycle - enqueuing one more resume wake every poll interval, forever. So a
# record that survives its own removal is APPENDED an episode_closed=1 marker,
# which like the delivery note needs write permission on the record file alone,
# and a record carrying it is read as absent: it neither resumes again nor
# suppresses a genuinely new episode, and the removal is retried on each later
# cycle so the stale file goes as soon as the directory allows it.
#
# One residual caveat, stated rather than hidden: if the note is written and the
# enqueue then fails AND the guard cannot restore the note to 0, the episode
# reads as delivered without an alert having been sent. It will not alert again
# and may emit a resume for a pause that never happened. That is the safe
# direction of the same asymmetry, it is logged as an ERROR, and it still cannot
# strand the fleet.
#
# RESUME requires PROOF OF REFRESH, not just elapsed time. A resetsAt that has
# passed is necessary but not sufficient: the provider may not have rolled the
# window yet, and resuming there would put every worker straight back into the
# wall. So resume needs BOTH a time condition and a fresh read showing
# percentUsed back below the threshold. The time condition is satisfied by the
# recorded resetsAt having passed, OR by the provider now reporting a resetsAt
# strictly later than the recorded one - a window that rolled early is still a
# genuine roll, and that second path never resumes without the usage drop, so it
# cannot resume prematurely. When the recorded reset passes with usage still at
# the threshold, the guard records the provider's new resetsAt in place and stays
# paused WITHOUT re-alerting: the episode is still the same episode. Only a
# resetsAt that can actually be read as a time replaces the recorded one; an
# unreadable reading is logged and ignored, because overwriting a usable recorded
# reset time with an unusable one would leave the episode with no time it can
# ever compare, and so with no way to resume.
#
# An episode opened while resetsAt was missing or unparseable is still
# resumable. The first later reading that carries a usable resetsAt is adopted
# into the record, so the ordinary reset-passed path can run instead of the
# episode staying open forever with every task in its ledger paused. Adoption
# moves only the time condition; the usage drop is still required, so it is
# never a way to resume on elapsed time alone.
#
# STALE AND MISSING DATA NEVER DECIDE ANYTHING. A failed quota-axi call, a
# provider absent from the output, a provider whose state.stale is true, a
# missing window, and a non-numeric percentUsed are each logged loudly and then
# skipped for that cycle. None of them opens an episode and none of them closes
# one, because acting on data the provider itself will not vouch for is how a
# guard resumes into an exhausted window. One bad poll never ends the loop.
#
# LOG RETENTION, and the cap arithmetic. The loop writes one rotating log at
# state/.quota-guard/guard.log. The active log is rotated once it reaches
# FM_QUOTA_GUARD_LOG_MAX_BYTES (default 2000000, ~2 MB) and
# FM_QUOTA_GUARD_LOG_KEEP (default 4) rotations are retained, so the worst case
# on disk is the active log plus its rotations:
#     (LOG_KEEP + 1) * LOG_MAX_BYTES = 5 * 2000000 = 10000000 bytes (~10 MB).
# The bound holds for any run length because rotation is checked before every
# append and the oldest rotation is deleted, not archived. A single append can
# overshoot the active cap by at most the length of one line, which is bounded by
# the fixed field set below, so the ~10 MB figure is the real ceiling rather than
# an average.
#
# ENVIRONMENT (documented overrides; defaults in parentheses):
#   FM_QUOTA_GUARD_INTERVAL        seconds between polls (120)
#   FM_QUOTA_GUARD_THRESHOLD       percentUsed that opens an episode (95)
#   FM_QUOTA_GUARD_QUOTA_CMD       command producing quota-axi JSON on stdout
#                                  ("quota-axi --json --provider claude,codex");
#                                  the seam tests use to inject fixture JSON
#   FM_QUOTA_GUARD_LOG_MAX_BYTES   active log rotation size (2000000)
#   FM_QUOTA_GUARD_LOG_KEEP        rotations retained (4)
#   FM_QUOTA_GUARD_NO_ARM          when set to 1, `arm` is a documented no-op.
#                                  `arm` starts a REAL background process, so any
#                                  suite that drives a session start would spawn
#                                  one per fixture home and leak it. tests/lib.sh
#                                  exports this for every suite, which is why no
#                                  test can spawn one by forgetting to.
#   FM_QUOTA_GUARD_NOW             epoch seconds to use as "now" instead of the
#                                  system clock. Every reset-time decision reads
#                                  the clock through this seam, so a test can put
#                                  a window before or after its reset without
#                                  waiting for one, and an operator can replay a
#                                  decision at a chosen instant.
#
# STATE, all under this home's state/ and gitignored with it:
#   .quota-guard/guard.lock          single-instance lock (bin/fm-wake-lib.sh)
#   .quota-guard/poll.lock           serializes one poll cycle against another
#   .quota-guard/guard.log[.1-.N]    the rotating log described above
#   .quota-guard/last-poll           epoch, ISO time, and one-line poll summary
#   .quota-guard/paused/<p>.<w>      one durable episode record per window
#   .quota-guard/paused-tasks/<p>.<w>/<task-id>
#                                    Firstmate's durable per-task pause ledger
#   .quota-guard/primary-binding     primary session pid and process identity,
#                                    backend, target, and harness captured by
#                                    `arm` inside this home's lock-owning session;
#                                    reset nudges refuse a missing, stale, reused,
#                                    or changed binding
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

GUARD_DIR="$STATE/.quota-guard"
GUARD_LOCK="$GUARD_DIR/guard.lock"
POLL_LOCK="$GUARD_DIR/poll.lock"
LOG_FILE="$GUARD_DIR/guard.log"
LAST_POLL="$GUARD_DIR/last-poll"
PAUSED_DIR="$GUARD_DIR/paused"
PAUSED_TASKS_DIR="$GUARD_DIR/paused-tasks"
PRIMARY_BINDING="$GUARD_DIR/primary-binding"

# The constant tracked set. See the TRACKED WINDOWS note in the header.
TRACKED_WINDOWS="claude/five_hour claude/seven_day codex/weekly"

INTERVAL=${FM_QUOTA_GUARD_INTERVAL:-120}
THRESHOLD=${FM_QUOTA_GUARD_THRESHOLD:-95}
QUOTA_CMD=${FM_QUOTA_GUARD_QUOTA_CMD:-"quota-axi --json --provider claude,codex"}
LOG_MAX_BYTES=${FM_QUOTA_GUARD_LOG_MAX_BYTES:-2000000}
LOG_KEEP=${FM_QUOTA_GUARD_LOG_KEEP:-4}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# Print the header block itself, stopping at the first non-comment line, so the
# help can never drift out of sync with the header the way a hardcoded line range
# does the moment the header grows.
usage() {
  LC_ALL=C awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit 2
}

for _name in INTERVAL THRESHOLD LOG_MAX_BYTES LOG_KEEP; do
  case "${!_name}" in
    ''|*[!0-9]*) die "$_name must be a non-negative integer (got '${!_name}')" ;;
  esac
done
unset _name
[ "$INTERVAL" -ge 1 ] || die "FM_QUOTA_GUARD_INTERVAL must be at least 1"
[ "$LOG_MAX_BYTES" -ge 1 ] || die "FM_QUOTA_GUARD_LOG_MAX_BYTES must be at least 1"

mkdir -p "$GUARD_DIR" "$PAUSED_DIR" "$PAUSED_TASKS_DIR" 2>/dev/null || true

# --- small utilities ---------------------------------------------------------

# The decision clock. Every reset comparison goes through here, so injecting
# FM_QUOTA_GUARD_NOW is enough to place a window on either side of its reset.
now_epoch() {
  case "${FM_QUOTA_GUARD_NOW:-}" in
    ''|*[!0-9]*) date -u +%s ;;
    *) printf '%s\n' "$FM_QUOTA_GUARD_NOW" ;;
  esac
}

# Display timestamps only. POLL_ISO lets one cycle reuse a single `date` call
# rather than forking one per window and per log line.
POLL_ISO=
now_iso() {
  local n
  [ -z "$POLL_ISO" ] || { printf '%s\n' "$POLL_ISO"; return 0; }
  case "${FM_QUOTA_GUARD_NOW:-}" in
    ''|*[!0-9]*) date -u +%Y-%m-%dT%H:%M:%SZ ;;
    *)
      n=$FM_QUOTA_GUARD_NOW
      date -u -r "$n" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$n" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || printf '@%s\n' "$n"
      ;;
  esac
}

# The path is passed as an ARGUMENT rather than redirected in: a `< missing`
# redirection fails in the shell before `2>/dev/null` is applied, so the absent
# log on the very first append would print a spurious error every run.
file_size() {  # <path> -> bytes, 0 when absent or unreadable
  local n
  read -r n _ < <(wc -c "$1" 2>/dev/null) || n=
  case "$n" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# Rotate BEFORE appending, so the active log can only exceed its cap by the one
# line that crossed it. Oldest rotation is deleted rather than archived, which is
# what makes the header's (LOG_KEEP + 1) * LOG_MAX_BYTES ceiling a real bound.
rotate_log() {
  local i prev
  [ "$(file_size "$LOG_FILE")" -ge "$LOG_MAX_BYTES" ] || return 0
  if [ "$LOG_KEEP" -le 0 ]; then
    : > "$LOG_FILE" 2>/dev/null || true
    return 0
  fi
  rm -f "$LOG_FILE.$LOG_KEEP" 2>/dev/null || true
  i=$LOG_KEEP
  while [ "$i" -gt 1 ]; do
    prev=$((i - 1))
    [ -f "$LOG_FILE.$prev" ] && mv -f "$LOG_FILE.$prev" "$LOG_FILE.$i" 2>/dev/null
    i=$prev
  done
  [ -f "$LOG_FILE" ] && mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
  return 0
}

log() {  # <level> <message>
  local level=$1 msg=$2
  rotate_log
  printf '%s\t%s\t%s\n' "$(now_iso)" "$level" \
    "$(printf '%s' "$msg" | LC_ALL=C tr '\t\r\n' '   ')" \
    >> "$LOG_FILE" 2>/dev/null || true
}

write_atomic() {  # <path>  (content on stdin)
  local path=$1 tmp
  tmp="$path.tmp.$$"
  cat > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Numeric comparison that tolerates a fractional percentUsed, which bash
# arithmetic cannot compare on its own.
pct_at_least() {  # <value> <threshold>
  LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# ISO-8601 -> epoch seconds, without GNU date (absent on macOS) and without
# python3 (not a required tool here). Handles the fractional seconds and the
# "Z" / "+HH:MM" / "-HHMM" offsets quota-axi emits. Interval expressions like
# {4} are avoided on purpose: not every awk on a supported platform has them.
iso_to_epoch() {  # <iso8601> -> epoch on stdout, nonzero when unparseable
  local iso=$1
  [ -n "$iso" ] || return 1
  LC_ALL=C awk -v s="$iso" '
    function days_from_civil(y, m, d,   era, yoe, doy, doe) {
      if (m <= 2) y -= 1
      era = (y >= 0 ? y : y - 399)
      era = int(era / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    BEGIN {
      if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][Tt ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) exit 1
      y  = substr(s, 1, 4) + 0
      mo = substr(s, 6, 2) + 0
      d  = substr(s, 9, 2) + 0
      h  = substr(s, 12, 2) + 0
      mi = substr(s, 15, 2) + 0
      se = substr(s, 18, 2) + 0
      if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60) exit 1
      rest = substr(s, 20)
      sub(/^\.[0-9]+/, "", rest)
      off = 0
      if (rest == "" || rest == "Z" || rest == "z") {
        off = 0
      } else if (rest ~ /^[+-][0-9][0-9]:?[0-9][0-9]$/) {
        sign = (substr(rest, 1, 1) == "-") ? -1 : 1
        oh = substr(rest, 2, 2) + 0
        om = substr(rest, length(rest) - 1, 2) + 0
        off = sign * (oh * 3600 + om * 60)
      } else {
        exit 1
      }
      printf "%d\n", days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - off
    }
  '
}

window_key_valid() {  # <provider>/<window>
  local w
  for w in $TRACKED_WINDOWS; do
    [ "$w" = "$1" ] && return 0
  done
  return 1
}

record_path() {  # <provider>/<window> -> paused record path
  printf '%s/%s\n' "$PAUSED_DIR" "${1%/*}.${1#*/}"
}

tasks_path() {  # <provider>/<window> -> per-window task ledger dir
  printf '%s/%s\n' "$PAUSED_TASKS_DIR" "${1%/*}.${1#*/}"
}

# The LAST assignment of a field wins, so a value appended to the record updates
# it exactly as a rewrite would. Records normally hold one line per field, so
# this differs from first-wins only where an append has already been used.
record_get() {  # <record-path> <field>
  LC_ALL=C awk -F= -v k="$2" '
    $1 == k { sub(/^[^=]*=/, ""); v = $0; found = 1 }
    END { if (found) print v }
  ' "$1" 2>/dev/null
}

# One owner for every mutation of an open episode's record. Each <field>=<value>
# argument ends up present exactly once and every other line is kept, so a record
# is updated in place rather than rewritten from a partial idea of its fields.
# The new content is built in full before anything is written: a failed awk must
# leave the durable record alone rather than truncate the episode away.
record_set() {  # <record-path> <field>=<value>...
  local rec=$1 spec out
  shift
  spec=$(printf '%s\n' "$@")
  # The spec travels in the environment rather than through -v: -v applies
  # escape processing, and the one true awk refuses a newline in such a value
  # outright, so a multi-field update would fail on macOS alone.
  out=$(FM_QUOTA_GUARD_RECORD_SPEC="$spec" LC_ALL=C awk '
    BEGIN {
      n = split(ENVIRON["FM_QUOTA_GUARD_RECORD_SPEC"], lines, "\n")
      for (i = 1; i <= n; i++) {
        eq = index(lines[i], "=")
        if (eq > 0) { k = substr(lines[i], 1, eq - 1); want[k] = lines[i]; order[i] = k }
      }
    }
    {
      eq = index($0, "=")
      k = (eq > 0) ? substr($0, 1, eq - 1) : ""
      if (k != "" && (k in want)) { if (!(k in done)) print want[k]; done[k] = 1; next }
      print
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (k != "" && !(k in done)) { print want[k]; done[k] = 1 }
      }
    }
  ' "$rec") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | write_atomic "$rec"
}

# An epoch is usable only when it is a whole number that arithmetic comparison
# can actually take. A record written before its window had a resetsAt carries an
# empty one, and `[ "$now" -ge "" ]` is a shell error rather than a decision.
epoch_usable() {  # <value>
  case "${1:-}" in
    ''|-) return 1 ;;
    -*) case "${1#-}" in ''|*[!0-9]*) return 1 ;; esac ;;
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

# --- quota reading -----------------------------------------------------------

# One TSV line per tracked window: <key> <status> <percentUsed> <resetsAt>.
# Every unusable shape gets its own status token so the caller can log the real
# reason rather than a generic failure, and so no unusable shape can be mistaken
# for a usable reading.
# shellcheck disable=SC2016 # jq owns every $ expression in this literal program.
QUOTA_EXTRACT='
def firstof(f): [ f ] | if length == 0 then null else .[0] end;
($tracked | split(" ")[]) as $t
| ($t | split("/")) as $parts
| $parts[0] as $p
| $parts[1] as $w
| (firstof(.providers[]? | select(.provider == $p))) as $prov
| if $prov == null then [$t, "no-provider", "", ""]
  elif ($prov.state.stale == true) then [$t, "stale", "", ""]
  else (firstof($prov.windows[]? | select(.id == $w))) as $win
    | if $win == null then [$t, "no-window", "", ""]
      elif (($win.percentUsed | type) != "number") then [$t, "no-percent", "", ""]
      else [$t, "ok", ($win.percentUsed | tostring), ($win.resetsAt // "" | tostring)]
      end
  end
| @tsv
'

read_quota_windows() {  # -> TSV on stdout; nonzero when the read itself failed
  local json
  json=$(eval "$QUOTA_CMD" 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r --arg tracked "$TRACKED_WINDOWS" "$QUOTA_EXTRACT" 2>/dev/null
}

# --- the poll cycle ----------------------------------------------------------

# Open the episode durably. The record says its alert is still owed in so many
# words, because only a note that positively reads not-delivered can ever be
# grounds for cancelling an episode without resuming it.
open_episode() {  # <key> <pct> <resets_at>
  local key=$1 pct=$2 resets_at=$3 rec resets_epoch
  rec=$(record_path "$key")
  resets_epoch=$(iso_to_epoch "$resets_at" 2>/dev/null) || resets_epoch=
  if ! write_atomic "$rec" <<EOF
provider=${key%/*}
window=${key#*/}
threshold=$THRESHOLD
percent_used=$pct
resets_at=$resets_at
resets_epoch=$resets_epoch
alert_delivered=0
alerted_at=$(now_iso)
alerted_epoch=$(now_epoch)
EOF
  then
    log ERROR "could not write paused record for $key; no alert enqueued"
    return 1
  fi
  return 0
}

# The durable note of whether this episode's alert is owed or sent. Rewritten in
# place when the paused directory allows it, appended when it does not: an append
# needs write permission on the record file alone, so a directory that has turned
# unwritable cannot stop the guard accounting for an alert.
mark_alert_state() {  # <record-path> <0|1>
  record_set "$1" "alert_delivered=$2" && return 0
  printf 'alert_delivered=%s\n' "$2" >> "$1" 2>/dev/null
}

# Proof that the alert was never sent, which is the only thing that may cancel an
# episode without resuming it. The record must say so itself, and the queue must
# not still be holding an alert for the window - a note that is missing, garbled
# or unreadable proves nothing and is never treated as proof.
alert_provably_undelivered() {  # <key> <record-path>
  [ "$(record_get "$2" alert_delivered)" = 0 ] || return 1
  fm_wake_queued_keys check 2>/dev/null | grep -Fxq "quota-guard:alert:$1" && return 1
  return 0
}

# Remove a closed episode's record. A record that outlives its removal would be
# decided again on the next cycle, so a failure here is logged rather than
# swallowed and the caller marks the record closed instead.
clear_record() {  # <key> <record-path>
  rm -f "$2" 2>/dev/null || true
  [ -f "$2" ] || return 0
  log ERROR "$1 could not remove its paused record; the record is marked closed instead"
  return 1
}

# The durable note that an episode is over even though its record is still on
# disk. Like the owed-alert note it is appended, so write permission on the
# record file alone is enough: a paused directory that has turned unwritable can
# stop the unlink but cannot stop the guard recording that the episode ended.
mark_episode_closed() {  # <record-path>
  printf 'episode_closed=1\n' >> "$1" 2>/dev/null
}

record_closed() {  # <record-path>
  [ "$(record_get "$1" episode_closed)" = 1 ]
}

# The episode's one alert, noted before it is sent so that the guard never sends
# an alert it cannot account for. An enqueue that fails leaves the episode owing
# its alert and a later cycle tries again.
deliver_alert() {  # <key> <pct> <resets_at> <record-path>
  local key=$1 pct=$2 resets_at=$3 rec=$4
  if ! mark_alert_state "$rec" 1; then
    log ERROR "$key is at ${pct}% (threshold ${THRESHOLD}%) but its paused record could not be marked as alerted, so no alert wake was enqueued; the episode stays open and the alert is retried next cycle"
    return 1
  fi
  if ! fm_wake_append check "quota-guard:alert:$key" \
    "check: quota-guard alert: $key at ${pct}% used (threshold ${THRESHOLD}%), resets at ${resets_at:-unknown}; pause work per the quota-guard-cycle skill"
  then
    log ERROR "$key is at ${pct}% (threshold ${THRESHOLD}%) but the alert wake could not be enqueued; the episode stays open and the alert is retried next cycle"
    mark_alert_state "$rec" 0 \
      || log ERROR "$key could not restore the owed-alert note after a failed enqueue; this episode will not alert again and may emit a resume for a pause that never happened"
    return 1
  fi
  log ALERT "$key at ${pct}% used (threshold ${THRESHOLD}%); resets_at=${resets_at:-unknown}; alert wake enqueued"
  return 0
}

close_episode() {  # <key> <pct>
  local key=$1 pct=$2 rec
  rec=$(record_path "$key")
  if fm_wake_append check "quota-guard:resume:$key" \
    "check: quota-guard resume: $key refreshed to ${pct}% used (below threshold ${THRESHOLD}%); restart work paused for it per the quota-guard-cycle skill"
  then
    if clear_record "$key" "$rec"; then
      log RESUME "$key refreshed to ${pct}%; resume wake enqueued and paused record cleared"
    elif mark_episode_closed "$rec"; then
      log RESUME "$key refreshed to ${pct}%; resume wake enqueued and its paused record marked closed because it could not be removed"
    else
      log ERROR "$key refreshed to ${pct}% and its resume wake was enqueued, but its paused record could be neither removed nor marked closed; later cycles may enqueue the resume again"
    fi
    return 0
  else
    log ERROR "$key refreshed to ${pct}% but the resume wake could not be enqueued; record kept for the next cycle"
    return 1
  fi
}

# Launch one accelerator after every resume from this poll is durable. The
# detached process prevents an unavailable backend from holding the poll lock or
# stopping this loop. It rechecks this home's exact session pid before it types,
# and the shared injector refuses busy or non-empty primary composers.
launch_resume_nudge() {
  local current_pid current_identity bound_pid bound_identity
  local bound_backend bound_target bound_harness message
  [ ! -e "$STATE/.afk" ] || { log NUDGE "reset nudge skipped because away-mode supervision is active"; return 0; }
  bound_pid=$(sed -n 's/^session_pid=//p' "$PRIMARY_BINDING" 2>/dev/null)
  bound_identity=$(sed -n 's/^session_identity=//p' "$PRIMARY_BINDING" 2>/dev/null)
  bound_backend=$(sed -n 's/^backend=//p' "$PRIMARY_BINDING" 2>/dev/null)
  bound_target=$(sed -n 's/^target=//p' "$PRIMARY_BINDING" 2>/dev/null)
  bound_harness=$(sed -n 's/^harness=//p' "$PRIMARY_BINDING" 2>/dev/null)
  case "$bound_pid" in
    ''|*[!0-9]*) log NUDGE "resume wakes retained; no home-bound primary nudge is available"; return 1 ;;
  esac
  current_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  [ "$current_pid" = "$bound_pid" ] \
    || { log NUDGE "resume wakes retained; the home primary session binding changed"; return 1; }
  kill -0 "$current_pid" 2>/dev/null \
    || { log NUDGE "resume wakes retained; the home primary session is gone"; return 1; }
  current_identity=$(fm_pid_identity "$current_pid" 2>/dev/null || true)
  [ -n "$bound_identity" ] && [ "$current_identity" = "$bound_identity" ] \
    || { log NUDGE "resume wakes retained; the home primary session identity changed"; return 1; }
  [ -n "$bound_target" ] && [ -n "$bound_backend" ] && [ -n "$bound_harness" ] \
    || { log NUDGE "resume wakes retained; no home-bound primary target is available"; return 1; }

  message="FIRSTMATE WATCHER WAKE: quota guard queued one or more quota resumes. Run bin/fm-wake-drain.sh first and handle the queued wakes. The queued wakes are durable; this message only starts the idle turn."
  nohup env \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_TARGET="$bound_target" \
    FM_SUPERVISOR_BACKEND="$bound_backend" \
    FM_SUPERVISOR_SESSION_PID="$bound_pid" \
    FM_SUPERVISOR_SESSION_IDENTITY="$bound_identity" \
    FM_SUPERVISOR_PRIMARY_HARNESS="$bound_harness" \
    FM_INJECT_CONFIRM_RETRIES=3 \
    FM_INJECT_CONFIRM_SLEEP=0.5 \
    "$SCRIPT_DIR/fm-supervisor-inject.sh" watcher "$message" \
    >/dev/null 2>&1 </dev/null &
  log NUDGE "resume wakes enqueued; one home-bound idle-primary nudge launched"
  return 0
}

write_primary_binding() {
  local session_pid session_identity backend target harness tmp
  fm_session_lock_owned_by_self "$STATE" || return 1
  session_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$session_pid" in ''|*[!0-9]*) return 1 ;; esac
  session_identity=$(fm_pid_identity "$session_pid" 2>/dev/null) || return 1

  if [ -n "${TMUX_PANE:-}" ]; then
    backend=tmux
    target=$TMUX_PANE
  elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    backend=herdr
    target="${HERDR_SESSION:-default}:$HERDR_PANE_ID"
  else
    return 1
  fi
  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
  case "$harness" in claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;; *) return 1 ;; esac

  tmp="$PRIMARY_BINDING.tmp.$$"
  if printf 'session_pid=%s\nsession_identity=%s\nbackend=%s\ntarget=%s\nharness=%s\n' \
    "$session_pid" "$session_identity" "$backend" "$target" "$harness" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$PRIMARY_BINDING" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# One tracked window, one reading. Returns a short verdict word for the summary.
evaluate_window() {  # <key> <status> <pct> <resets_at>
  local key=$1 status=$2 pct=$3 resets_at=$4
  local rec recorded_epoch recorded_at observed_epoch time_ok=0 now open_record

  rec=$(record_path "$key")

  if [ "$status" != ok ]; then
    case "$status" in
      stale)       log WARN "$key skipped: provider reports its quota data stale; neither alert nor resume decided this cycle" ;;
      no-provider) log WARN "$key skipped: provider missing from quota output; neither alert nor resume decided this cycle" ;;
      no-window)   log WARN "$key skipped: window missing from provider output; neither alert nor resume decided this cycle" ;;
      no-percent)  log WARN "$key skipped: percentUsed absent or not a number; neither alert nor resume decided this cycle" ;;
      *)           log WARN "$key skipped: unusable reading ($status); neither alert nor resume decided this cycle" ;;
    esac
    printf 'skipped\n'
    return 0
  fi

  # A record marked closed is not an open episode; it only outlived its own
  # removal. Retry that removal - the fault that blocked it may be gone - and
  # decide the window as if no record were there either way, so a closed episode
  # can never be closed a second time.
  if [ -f "$rec" ] && record_closed "$rec"; then
    rm -f "$rec" 2>/dev/null || true
    open_record=0
  elif [ -f "$rec" ]; then
    open_record=1
  else
    open_record=0
  fi

  if [ "$open_record" -eq 0 ]; then
    if pct_at_least "$pct" "$THRESHOLD"; then
      open_episode "$key" "$pct" "$resets_at" || { printf 'error\n'; return 0; }
      deliver_alert "$key" "$pct" "$resets_at" "$rec" \
        && { printf 'alerted\n'; return 0; }
      printf 'error\n'
      return 0
    fi
    printf 'clear\n'
    return 0
  fi

  # An episode whose alert is PROVABLY still owed. A window that has recovered
  # before that alert was ever sent is abandoned outright: Firstmate was never
  # told to pause, so there is nothing to resume, and pausing the fleet for a
  # window that is healthy again is worse than never alerting at all. Otherwise
  # the alert is retried, quoting the reading that opened the episode rather than
  # this cycle's, so the wake cannot describe a window it does not mean. Every
  # other state - noted as delivered, or not provable either way - falls through
  # to the ordinary close path below, which can only ever emit a resume.
  if alert_provably_undelivered "$key" "$rec"; then
    if ! pct_at_least "$pct" "$THRESHOLD"; then
      clear_record "$key" "$rec" || mark_episode_closed "$rec" \
        || log ERROR "$key could be neither removed nor marked closed; a later cycle may decide it again"
      log SUPPRESS "$key recovered to ${pct}% before its alert could be delivered; episode closed with no alert and no resume wake"
      printf 'suppressed\n'
      return 0
    fi
    deliver_alert "$key" "$(record_get "$rec" percent_used)" \
      "$(record_get "$rec" resets_at)" "$rec" \
      && { printf 'alerted\n'; return 0; }
    printf 'error\n'
    return 0
  fi

  # The alert is delivered. Never re-alert; decide only whether it can close.
  recorded_epoch=$(record_get "$rec" resets_epoch)
  recorded_at=$(record_get "$rec" resets_at)
  observed_epoch=$(iso_to_epoch "$resets_at" 2>/dev/null) || observed_epoch=
  now=$(now_epoch)

  # An episode opened while the window had no usable resetsAt can never satisfy
  # the time condition on its own, so it would stay open forever with every task
  # in its ledger paused. Adopt the first usable one the provider reports, which
  # restores the ordinary reset-passed path without weakening it: the usage drop
  # below is still required.
  if ! epoch_usable "$recorded_epoch" && epoch_usable "$observed_epoch"; then
    if record_set "$rec" "resets_at=$resets_at" "resets_epoch=$observed_epoch"; then
      recorded_epoch=$observed_epoch
      recorded_at=$resets_at
      log WAIT "$key had no usable recorded reset time; adopted the observed resets_at=$resets_at so the episode can resume once it passes"
    else
      log ERROR "$key could not adopt the observed reset time; the episode stays open"
    fi
  fi

  if epoch_usable "$recorded_epoch" && [ "$now" -ge "$recorded_epoch" ]; then
    time_ok=1
  fi
  if epoch_usable "$recorded_epoch" && epoch_usable "$observed_epoch" \
    && [ "$observed_epoch" -gt "$recorded_epoch" ]; then
    time_ok=1
  fi

  if [ "$time_ok" -eq 1 ] && ! pct_at_least "$pct" "$THRESHOLD"; then
    if close_episode "$key" "$pct"; then
      printf 'resumed\n'
    else
      printf 'error\n'
    fi
    return 0
  fi

  if [ "$time_ok" -eq 1 ]; then
    # The reset came and went with usage still at the wall. Keep the episode and
    # follow the provider's new resetsAt so the next check tests the real window.
    # A reading that cannot be read as a time is not followed: replacing a usable
    # recorded epoch with an unusable one would leave the episode with no time it
    # can ever compare, and so with no way to resume.
    if [ -n "$resets_at" ] && [ "$resets_at" != "$recorded_at" ] \
      && epoch_usable "$observed_epoch"; then
      record_set "$rec" "resets_at=$resets_at" "resets_epoch=$observed_epoch" \
        || log ERROR "$key could not refresh its recorded reset time"
      log WAIT "$key reset time passed but usage is still ${pct}%; still paused, now tracking resets_at=$resets_at"
    elif [ -n "$resets_at" ] && [ "$resets_at" != "$recorded_at" ]; then
      log WAIT "$key reset time passed but usage is still ${pct}%; its new resets_at=$resets_at cannot be read as a time, so the episode keeps resets_at=${recorded_at:-unknown}"
    else
      log WAIT "$key reset time passed but usage is still ${pct}%; still paused, not resuming"
    fi
    printf 'waiting\n'
    return 0
  fi

  log WAIT "$key still paused at ${pct}%; waiting for reset ${recorded_at:-unknown}"
  printf 'paused\n'
  return 0
}

poll_once() {
  local tsv key status pct resets_at verdict
  local n_alerted=0 n_resumed=0 n_paused=0 n_skipped=0 n_clear=0 n_error=0 summary
  local n_suppressed=0

  # One display timestamp for the whole cycle: every log line and record written
  # by this poll shares it, which also keeps the cycle to a single `date` fork.
  POLL_ISO=
  POLL_ISO=$(now_iso)

  if ! command -v jq >/dev/null 2>&1; then
    log ERROR "jq is unavailable; this cycle decided nothing"
    printf '%s\t%s\t%s\n' "$(now_epoch)" "$(now_iso)" "poll failed: jq unavailable" \
      > "$LAST_POLL" 2>/dev/null || true
    return 0
  fi

  if ! tsv=$(read_quota_windows) || [ -z "$tsv" ]; then
    log ERROR "quota read failed or returned nothing (command: $QUOTA_CMD); this cycle decided nothing"
    printf '%s\t%s\t%s\n' "$(now_epoch)" "$(now_iso)" "poll failed: quota read unavailable" \
      > "$LAST_POLL" 2>/dev/null || true
    return 0
  fi

  while IFS=$(printf '\t') read -r key status pct resets_at; do
    [ -n "$key" ] || continue
    window_key_valid "$key" || continue
    verdict=$(evaluate_window "$key" "$status" "$pct" "$resets_at")
    case "$verdict" in
      alerted) n_alerted=$((n_alerted + 1)) ;;
      resumed) n_resumed=$((n_resumed + 1)) ;;
      paused|waiting) n_paused=$((n_paused + 1)) ;;
      skipped) n_skipped=$((n_skipped + 1)) ;;
      clear) n_clear=$((n_clear + 1)) ;;
      error) n_error=$((n_error + 1)) ;;
      suppressed) n_suppressed=$((n_suppressed + 1)) ;;
    esac
  done <<EOF
$tsv
EOF

  if [ "$n_resumed" -gt 0 ]; then
    launch_resume_nudge || true
  fi
  summary="clear=$n_clear paused=$n_paused alerted=$n_alerted resumed=$n_resumed skipped=$n_skipped suppressed=$n_suppressed errors=$n_error"
  printf '%s\t%s\t%s\n' "$(now_epoch)" "$(now_iso)" "$summary" > "$LAST_POLL" 2>/dev/null || true
  log POLL "$summary"
  POLL_ISO=
  return 0
}

# Serialize one cycle against another so a hand-run poll during a live guard can
# never open the same episode twice. A cycle that cannot get the lock in time is
# skipped rather than queued: the next cycle re-derives the same state anyway.
poll_once_locked() {
  local waited=0
  while ! fm_lock_try_acquire "$POLL_LOCK"; do
    waited=$((waited + 1))
    if [ "$waited" -ge 50 ]; then
      log WARN "another poll cycle held the poll lock; skipping this cycle"
      return 0
    fi
    sleep 0.1
  done
  poll_once
  fm_lock_release "$POLL_LOCK"
}

# --- lock helpers ------------------------------------------------------------

guard_live_pid() {  # print the pid of a live guard holding the lock, else nonzero
  local pid
  pid=$(cat "$GUARD_LOCK/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# --- commands ----------------------------------------------------------------

GUARD_LOCK_HELD=0
release_guard_lock() {
  [ "$GUARD_LOCK_HELD" -eq 1 ] || return 0
  GUARD_LOCK_HELD=0
  fm_lock_release "$GUARD_LOCK"
}

on_signal() {
  log STOP "guard received a stop signal; releasing the lock and exiting"
  release_guard_lock
  exit 0
}

cmd_start() {
  local pid
  if ! fm_lock_try_acquire "$GUARD_LOCK"; then
    pid=$(guard_live_pid) \
      && { printf 'quota guard: already running pid=%s\n' "$pid"; return 0; }
    printf 'quota guard: could not acquire the guard lock and no live guard holds it\n' >&2
    return 1
  fi
  GUARD_LOCK_HELD=1
  trap on_signal INT TERM HUP
  trap release_guard_lock EXIT
  log START "guard started pid=$$ interval=${INTERVAL}s threshold=${THRESHOLD}% windows='$TRACKED_WINDOWS'"
  while :; do
    # A guard must not outlive the home it watches. A deleted state directory
    # (a torn-down fixture, a retired home) or a lock this process no longer owns
    # both mean this loop has nothing left to guard, and a loop that ignores that
    # becomes an immortal orphan - they accumulate one per home ever started,
    # polling forever against a directory that is gone. Checked before every
    # cycle so an orphan lives at most one interval.
    if [ ! -d "$GUARD_DIR" ]; then
      GUARD_LOCK_HELD=0
      exit 0
    fi
    if [ "$(cat "$GUARD_LOCK/pid" 2>/dev/null || true)" != "$$" ]; then
      log STOP "guard pid=$$ no longer owns this home's guard lock; exiting"
      GUARD_LOCK_HELD=0
      exit 0
    fi
    poll_once_locked
    # Sleep as a job and wait on it, so a stop signal is handled at once instead
    # of after the remaining interval.
    sleep "$INTERVAL" &
    wait $! 2>/dev/null || true
  done
}

cmd_arm() {
  local pid monitor_was_on=0
  [ "${FM_QUOTA_GUARD_NO_ARM:-0}" != 1 ] || return 0
  # Refresh the nudge identity even when this home already has a live guard.
  # This lets a replacement primary take custody without restarting the guard.
  # Failure is intentionally inert: quota detection and durable wake delivery
  # do not depend on this optional accelerator.
  write_primary_binding || true
  guard_live_pid >/dev/null 2>&1 && return 0
  # quota-axi is only the DEFAULT reader. An explicit FM_QUOTA_GUARD_QUOTA_CMD
  # replaces it outright, so gating on that binary would refuse to arm a guard
  # that never intended to call it. jq parses every reading, so it is required
  # either way.
  [ -n "${FM_QUOTA_GUARD_QUOTA_CMD:-}" ] || command -v quota-axi >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-quota-guard.sh" start >/dev/null 2>&1 </dev/null &
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  # Confirm it actually took the lock rather than reporting a fork as success.
  local waited=0
  while [ "$waited" -lt 30 ]; do
    pid=$(guard_live_pid 2>/dev/null) && { printf 'quota guard: armed pid=%s\n' "$pid" >&2; return 0; }
    waited=$((waited + 1))
    sleep 0.1
  done
  printf 'quota guard: could not confirm a live guard after arming\n' >&2
  return 1
}

cmd_stop() {
  local pid waited=0
  if ! pid=$(guard_live_pid); then
    printf 'quota guard: not running\n'
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt 50 ]; do
    fm_pid_alive "$pid" || { printf 'quota guard: stopped pid=%s\n' "$pid"; return 0; }
    waited=$((waited + 1))
    sleep 0.1
  done
  printf 'quota guard: pid=%s did not exit after TERM\n' "$pid" >&2
  return 1
}

cmd_status() {
  local pid tsv key status pct resets_at rec last line task count
  if pid=$(guard_live_pid); then
    printf 'guard: running pid=%s\n' "$pid"
  else
    printf 'guard: not running\n'
  fi
  printf 'threshold: %s%%  interval: %ss  log-cap: %s bytes x %s files\n' \
    "$THRESHOLD" "$INTERVAL" "$LOG_MAX_BYTES" "$((LOG_KEEP + 1))"
  if [ -s "$LAST_POLL" ]; then
    line=$(cat "$LAST_POLL" 2>/dev/null || true)
    printf 'last poll: %s (%s)\n' "$(printf '%s' "$line" | cut -f2)" "$(printf '%s' "$line" | cut -f3)"
  else
    printf 'last poll: none recorded\n'
  fi

  printf '\ntracked windows:\n'
  if ! command -v jq >/dev/null 2>&1; then
    printf '  unavailable: jq is not installed\n'
  elif ! tsv=$(read_quota_windows) || [ -z "$tsv" ]; then
    printf '  unavailable: quota read failed (command: %s)\n' "$QUOTA_CMD"
  else
    while IFS=$(printf '\t') read -r key status pct resets_at; do
      [ -n "$key" ] || continue
      window_key_valid "$key" || continue
      if [ "$status" = ok ]; then
        printf '  %s: %s%% used, resets %s\n' "$key" "$pct" "${resets_at:-unknown}"
      else
        printf '  %s: unusable reading (%s)\n' "$key" "$status"
      fi
    done <<EOF
$tsv
EOF
  fi

  printf '\npaused windows:\n'
  count=0
  for key in $TRACKED_WINDOWS; do
    rec=$(record_path "$key")
    [ -f "$rec" ] || continue
    record_closed "$rec" && continue
    count=$((count + 1))
    printf '  %s: alerted %s at %s%% used, waiting for reset %s\n' \
      "$key" "$(record_get "$rec" alerted_at)" "$(record_get "$rec" percent_used)" \
      "$(record_get "$rec" resets_at)"
  done
  [ "$count" -eq 0 ] && printf '  none\n'

  printf '\npaused tasks:\n'
  count=0
  for key in $TRACKED_WINDOWS; do
    last=$(tasks_path "$key")
    [ -d "$last" ] || continue
    for task in "$last"/*; do
      [ -f "$task" ] || continue
      count=$((count + 1))
      printf '  %s: paused for %s\n' "$(basename "$task")" "$key"
    done
  done
  [ "$count" -eq 0 ] && printf '  none\n'
  return 0
}

# The ledger keys a file by task id, so it is held to exactly the shape
# bin/fm-pr-lib.sh owns, plus the same 64-character bound the rest of the home
# applies. Reused rather than restated so a later tightening reaches here too.
task_id_valid() {
  fm_task_id_path_safe "$1" || return 1
  [ "${#1}" -le 64 ]
}

cmd_pause_task() {  # <task-id> <provider>/<window>
  local id=$1 key=$2 dir
  task_id_valid "$id" || die "invalid task id: $id"
  window_key_valid "$key" || die "unknown window '$key' (tracked: $TRACKED_WINDOWS)"
  dir=$(tasks_path "$key")
  mkdir -p "$dir" 2>/dev/null || die "could not create the paused-task ledger for $key"
  printf 'paused_at=%s\npaused_epoch=%s\nwindow=%s\n' "$(now_iso)" "$(now_epoch)" "$key" \
    > "$dir/$id" 2>/dev/null || die "could not record $id as paused for $key"
  log PAUSE-TASK "$id recorded as paused for $key"
  printf 'quota guard: %s paused for %s\n' "$id" "$key"
}

cmd_resume_tasks() {  # <provider>/<window>
  local key=$1 dir task id found=0
  window_key_valid "$key" || die "unknown window '$key' (tracked: $TRACKED_WINDOWS)"
  dir=$(tasks_path "$key")
  [ -d "$dir" ] || return 0
  for task in "$dir"/*; do
    [ -f "$task" ] || continue
    id=$(basename "$task")
    printf '%s\n' "$id"
    rm -f "$task" 2>/dev/null || true
    found=$((found + 1))
  done
  rmdir "$dir" 2>/dev/null || true
  [ "$found" -eq 0 ] || log RESUME-TASKS "$found task(s) released for $key"
  return 0
}

# --- dispatch ----------------------------------------------------------------

[ $# -ge 1 ] || usage
CMD=$1
shift || true
case "$CMD" in
  start)        [ $# -eq 0 ] || usage; cmd_start ;;
  arm)          [ $# -eq 0 ] || usage; cmd_arm ;;
  poll)         [ $# -eq 0 ] || usage; poll_once_locked ;;
  status)       [ $# -eq 0 ] || usage; cmd_status ;;
  stop)         [ $# -eq 0 ] || usage; cmd_stop ;;
  pause-task)   [ $# -eq 2 ] || usage; cmd_pause_task "$1" "$2" ;;
  resume-tasks) [ $# -eq 1 ] || usage; cmd_resume_tasks "$1" ;;
  -h|--help|help) usage ;;
  *)            usage ;;
esac
