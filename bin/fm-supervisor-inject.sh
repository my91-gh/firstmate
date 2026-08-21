#!/usr/bin/env bash
# fm-supervisor-inject.sh - verified one-shot injection into Firstmate's primary.
#
# This source-safe library is the single owner of the shared delivery boundary
# used by the away-mode daemon and quota-reset nudges. It adds no harness screen
# knowledge. Busy signatures remain owned by bin/fm-busy-lib.sh, composer proof
# remains owned by the backend adapters, and typed operational inputs remain
# owned by bin/fm-operational-input.sh.
#
# fm_supervisor_inject <kind> <body> <target> <backend> <retries> <sleep-secs>
# types once only when the target exists, the primary is not busy, and the
# composer is positively empty. It then retries Enter only through the backend
# submit primitive. It returns nonzero for every unsafe or unconfirmed result.
#
# Executed form, used as a detached one-shot accelerator by the quota guard:
#   FM_HOME=<home> FM_STATE_OVERRIDE=<home-state> \
#   FM_SUPERVISOR_TARGET=<target> FM_SUPERVISOR_BACKEND=<tmux|herdr> \
#   FM_SUPERVISOR_SESSION_PID=<pid> FM_SUPERVISOR_SESSION_IDENTITY=<identity> \
#   fm-supervisor-inject.sh <kind> <body>
#
# The executed form has no target discovery or fallback. It also requires the
# exact live session pid still recorded in this home's state/.lock and the same
# process identity captured at binding time. The caller can therefore bind a
# target only while it runs inside that home's lock-owning primary, and a stale,
# reused, or replaced primary makes the later injection inert.
# Bash 3.2 compatible.
set -u

FM_SUPERVISOR_INJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-backend.sh
. "$FM_SUPERVISOR_INJECT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$FM_SUPERVISOR_INJECT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$FM_SUPERVISOR_INJECT_DIR/fm-busy-lib.sh"

FM_SUPERVISOR_INJECT_REASON=
export FM_SUPERVISOR_INJECT_REASON

fm_supervisor_primary_harness() {
  local harness=${FM_SUPERVISOR_PRIMARY_HARNESS:-${FM_DAEMON_PRIMARY_HARNESS:-}}
  if [ -z "$harness" ]; then
    harness=$("$FM_SUPERVISOR_INJECT_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
    [ -n "$harness" ] || harness=unknown
    FM_SUPERVISOR_PRIMARY_HARNESS=$harness
  fi
  printf '%s' "$harness"
}

# Compatibility name retained for daemon callers and tests that predate this
# extraction. It delegates to the shared owner above.
fm_daemon_primary_harness() {
  fm_supervisor_primary_harness
}

pane_is_busy() {  # <target> [backend]
  local target=$1 backend=${2:-tmux} native tail40 harness
  harness=$(fm_supervisor_primary_harness)
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$native" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match "$harness"
}

pane_input_pending() {  # <target> [backend]
  local target=$1 backend=${2:-tmux}
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]
}

fm_supervisor_inject_collapse() {  # <text>
  local text=$1
  text=${text//$'\n'/ - }
  printf '%s' "$text"
}

fm_supervisor_inject() {  # <kind> <body> <target> <backend> <retries> <sleep-secs>
  local kind=$1 body=$2 target=$3 backend=$4 retries=$5 sleep_s=$6
  local composer encoded verdict
  FM_SUPERVISOR_INJECT_REASON=

  case "$backend" in
    tmux|herdr) ;;
    *) FM_SUPERVISOR_INJECT_REASON="unsupported backend $backend"; return 1 ;;
  esac
  body=$(fm_supervisor_inject_collapse "$body")
  fm_operational_input_encode "$kind" "$body" encoded \
    || { FM_SUPERVISOR_INJECT_REASON="invalid operational input"; return 1; }
  fm_backend_target_exists "$backend" "$target" \
    || { FM_SUPERVISOR_INJECT_REASON="primary target missing"; return 1; }
  if pane_is_busy "$target" "$backend"; then
    FM_SUPERVISOR_INJECT_REASON="primary busy"
    return 1
  fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    FM_SUPERVISOR_INJECT_REASON="primary composer not confirmed empty (${composer:-unknown})"
    return 1
  fi
  verdict=$(fm_backend_send_text_submit \
    "$backend" "$target" "$encoded" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    FM_SUPERVISOR_INJECT_REASON=delivered
    return 0
  fi
  FM_SUPERVISOR_INJECT_REASON="submit unconfirmed after $retries retries ($verdict)"
  return 1
}

fm_supervisor_inject_main() {
  local kind=${1-} body=${2-} state lock_pid current_identity
  [ "$#" -eq 2 ] && [ -n "$kind" ] && [ -n "$body" ] || return 2
  state=${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "${FM_SUPERVISOR_SESSION_PID:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$lock_pid" = "$FM_SUPERVISOR_SESSION_PID" ] || return 1
  kill -0 "$FM_SUPERVISOR_SESSION_PID" 2>/dev/null || return 1
  current_identity=$(fm_pid_identity "$FM_SUPERVISOR_SESSION_PID" 2>/dev/null) || return 1
  [ -n "${FM_SUPERVISOR_SESSION_IDENTITY:-}" ] \
    && [ "$current_identity" = "$FM_SUPERVISOR_SESSION_IDENTITY" ] || return 1
  [ -n "${FM_SUPERVISOR_TARGET:-}" ] && [ -n "${FM_SUPERVISOR_BACKEND:-}" ] || return 1
  fm_supervisor_inject "$kind" "$body" \
    "$FM_SUPERVISOR_TARGET" "$FM_SUPERVISOR_BACKEND" \
    "${FM_INJECT_CONFIRM_RETRIES:-3}" "${FM_INJECT_CONFIRM_SLEEP:-0.5}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_SUPERVISOR_INJECT_DIR/fm-wake-lib.sh"
  fm_supervisor_inject_main "$@"
  exit $?
fi
