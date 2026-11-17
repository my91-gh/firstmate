#!/usr/bin/env bash
# fm-start-time.sh - give a queued backlog item a start time: its worker is
# dispatched only once that instant has arrived.
#
# Usage: fm-start-time.sh set <task-id> <time>
#        fm-start-time.sh clear <task-id>
#        fm-start-time.sh show <task-id>
#        fm-start-time.sh gate <task-id>
#        fm-start-time.sh scan
#        fm-start-time.sh --help
#
# <time> is an absolute instant: YYYY-MM-DDTHH:MM[:SS] followed by Z (UTC) or
# an explicit offset such as +02:00 or -0500. A time without Z or an offset is
# refused, never read as local time. It is stored in UTC as YYYY-MM-DDTHH:MM:SSZ.
#
# Storage: tasks-axi has no start-time field, so the instant is the FIRST line
# of the item's body, `fm-start-after=<UTC instant>`, written and removed
# through bin/fm-tasks-axi.sh `update --body-file`; the rest of the body is
# kept as it was. `set` replaces an earlier time, `clear` removes the line, and
# `show` prints the stored instant (nothing when none is set). Only a first-line
# marker counts, so prose that quotes the token is never read as a time.
#
# gate: run by bin/fm-spawn.sh before a fresh worker launches. It exits 0 when
# the item has no start time or the time has passed; otherwise it prints one
# `deferred:` line naming the time and exits 75, the capacity deferral status,
# so the item stays queued rather than blocked or failed. A stored time that
# cannot be read exits 3, and any other failure to read the item exits 1.
#
# scan: run by bin/fm-watch.sh on every check sweep (FM_CHECK_INTERVAL, default
# 300 s), so a wake follows a start time by at most one sweep. For each queued
# item whose time has arrived it queues one `check: start-time:` wake naming the
# task and prints the same line; state/<task>.start-time-notified remembers the
# instant already announced, so a repeat sweep is silent and a new `set` re-arms
# it. A marker whose item no longer carries a start time is pruned. A home
# without a readable tasks-axi backlog scans nothing and exits 0.
#
# The addressed backlog is the one bin/fm-tasks-axi.sh addresses: FM_DATA_OVERRIDE,
# else $FM_HOME/data. docs/configuration.md "Backlog backend" owns the field.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_START_TIME_DEFER_EXIT=75
MARKER_KEY='fm-start-after='

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-start-time: %s\n' "$*" >&2
  exit 1
}

# Print <input> as a UTC YYYY-MM-DDTHH:MM:SSZ instant; return 1 on any other shape.
canonical_instant() {  # <time>
  local re='^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2})(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})$'
  local day hm sec zone sign zh zm base_epoch epoch wall
  [[ $1 =~ $re ]] || return 1
  day=${BASH_REMATCH[1]} hm=${BASH_REMATCH[2]} sec=${BASH_REMATCH[3]:-:00} zone=${BASH_REMATCH[4]}
  wall="${day}T${hm}${sec}Z"
  base_epoch=$(fm_utc_iso_to_epoch "$wall") || return 1
  # An impossible date (month 13, day 31 of a short month) must not roll over.
  [ "$(epoch_to_instant "$base_epoch")" = "$wall" ] || return 1
  epoch=$base_epoch
  if [ "$zone" != Z ]; then
    sign=${zone:0:1} zone=${zone:1}
    zone=${zone/:/}
    zh=${zone:0:2} zm=${zone:2:2}
    [ $((10#$zh)) -le 23 ] && [ $((10#$zm)) -le 59 ] || return 1
    if [ "$sign" = + ]; then
      epoch=$((base_epoch - 10#$zh * 3600 - 10#$zm * 60))
    else
      epoch=$((base_epoch + 10#$zh * 3600 + 10#$zm * 60))
    fi
  fi
  epoch_to_instant "$epoch"
}

epoch_to_instant() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

require_tasks_axi() {
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"
  command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"
}

# Print the decoded body of <id> (empty when none); return the read's status.
read_body() {  # <id>
  local out status raw
  out=$(fm_backlog_row_show "$DATA" "$1" --full)
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return "$status"
  fi
  raw=$(printf '%s\n' "$out" | sed -n 's/^  body: //p' | head -n 1)
  case "$raw" in
    '"'*) printf '%s' "$raw" | jq -r . ;;
    *) printf '%s' "$raw" ;;
  esac
}

# The stored instant on <body>'s first line, or nothing.
body_instant() {  # <body>
  local first=${1%%$'\n'*}
  case "$first" in
    "$MARKER_KEY"[0-9][0-9][0-9][0-9]-*Z) printf '%s' "${first#"$MARKER_KEY"}" ;;
  esac
}

write_body() {  # <id> <body>
  local tmp rc=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-start-time.XXXXXX") || fail "cannot create a temporary body file"
  printf '%s\n' "$2" > "$tmp"
  "$SCRIPT_DIR/fm-tasks-axi.sh" update "$1" --body-file "$tmp" >/dev/null || rc=$?
  rm -f -- "$tmp"
  [ "$rc" -eq 0 ] || fail "could not update the body of backlog item $1"
}

body_without_marker() {  # <body>
  if [ -n "$(body_instant "$1")" ]; then
    case "$1" in
      *$'\n'*) printf '%s' "${1#*$'\n'}" ;;
    esac
  else
    printf '%s' "$1"
  fi
}

task_id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|-*|.*) return 1 ;; esac
}

cmd_set() {
  local id=${1:-} time=${2:-} instant body rest
  [ "$#" -eq 2 ] || fail "usage: fm-start-time.sh set <task-id> <time>"
  task_id_valid "$id" || fail "invalid task id: $id"
  instant=$(canonical_instant "$time") \
    || fail "invalid start time '$time': use YYYY-MM-DDTHH:MM[:SS] followed by Z or an offset such as +02:00"
  require_tasks_axi
  body=$(read_body "$id") || exit 1
  rest=$(body_without_marker "$body")
  write_body "$id" "${MARKER_KEY}${instant}${rest:+$'\n'$rest}"
  rm -f -- "$STATE/$id.start-time-notified"
  printf 'start time of %s set to %s\n' "$id" "$instant"
}

cmd_clear() {
  local id=${1:-} body
  [ "$#" -eq 1 ] || fail "usage: fm-start-time.sh clear <task-id>"
  task_id_valid "$id" || fail "invalid task id: $id"
  require_tasks_axi
  body=$(read_body "$id") || exit 1
  if [ -n "$(body_instant "$body")" ]; then
    write_body "$id" "$(body_without_marker "$body")"
  fi
  rm -f -- "$STATE/$id.start-time-notified"
  printf 'start time of %s cleared\n' "$id"
}

cmd_show() {
  local id=${1:-} body
  [ "$#" -eq 1 ] || fail "usage: fm-start-time.sh show <task-id>"
  task_id_valid "$id" || fail "invalid task id: $id"
  require_tasks_axi
  body=$(read_body "$id") || exit 1
  body_instant "$body"
  [ -z "$(body_instant "$body")" ] || printf '\n'
}

cmd_gate() {
  local id=${1:-} listing instant epoch now
  [ "$#" -eq 1 ] || fail "usage: fm-start-time.sh gate <task-id>"
  task_id_valid "$id" || fail "invalid task id: $id"
  require_tasks_axi
  listing=$(queued_start_times) || exit 1
  instant=$(printf '%s\n' "$listing" | awk -v id="$id" '$1 == id { print $2; exit }')
  [ -n "$instant" ] || exit 0
  epoch=$(fm_utc_iso_to_epoch "$instant") || {
    printf 'fm-start-time: backlog item %s carries an unreadable start time: %s\n' "$id" "$instant" >&2
    exit 3
  }
  now=$(date +%s)
  [ "$now" -lt "$epoch" ] || exit 0
  printf 'deferred: task %s has a start time of %s (now %s) and was not launched; its backlog item stays queued - dispatch it again once that time has arrived\n' \
    "$id" "$instant" "$(epoch_to_instant "$now")" >&2
  exit "$FM_START_TIME_DEFER_EXIT"
}

# Print "<id> <stored instant>" for every queued item whose body starts with a
# start time. One listing read serves a whole sweep, and a spawn's gate reads it
# instead of a per-item show, so the spawn's own row reads stay the only shows.
queued_start_times() {
  local listing line
  listing=$(fm_backlog_row_list "$DATA" --state queued --fields body --limit 100000) || return 1
  while IFS= read -r line; do
    [[ $line =~ ^\ \ ([A-Za-z0-9._-]+),.*,\"?${MARKER_KEY}([^\\\",]*) ]] || continue
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done <<EOF_LISTING
$listing
EOF_LISTING
}

cmd_scan() {
  local starts id instant epoch now seen='' marker note recorded
  command -v tasks-axi >/dev/null 2>&1 || exit 0
  starts=$(queued_start_times) || exit 0
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  now=$(date +%s)
  while read -r id instant; do
    [ -n "$id" ] || continue
    seen="$seen $id "
    epoch=$(fm_utc_iso_to_epoch "$instant") || continue
    [ "$now" -ge "$epoch" ] || continue
    marker="$STATE/$id.start-time-notified"
    recorded=$(cat "$marker" 2>/dev/null || true)
    [ "$recorded" != "$instant" ] || continue
    note="task $id may be dispatched now: its start time $instant has arrived"
    fm_wake_append check "start-time-$id" "check: start-time: $note" || continue
    printf '%s\n' "$instant" > "$marker"
    printf '%s\n' "$note"
  done <<EOF_STARTS
$starts
EOF_STARTS
  for marker in "$STATE"/*.start-time-notified; do
    [ -e "$marker" ] || continue
    id=${marker##*/}
    id=${id%.start-time-notified}
    case "$seen" in *" $id "*) ;; *) rm -f -- "$marker" ;; esac
  done
}

case "${1:-}" in
  -h|--help) usage ;;
  set) shift; cmd_set "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  show) shift; cmd_show "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  *) usage >&2; exit 2 ;;
esac
