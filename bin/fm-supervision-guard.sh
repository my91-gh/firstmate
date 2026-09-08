#!/usr/bin/env bash
# fm-supervision-guard.sh - out-of-band supervision liveness guard.
#
# WHY THIS EXISTS. Every other supervision detect/re-arm path is IN-BAND: it runs
# only when a turn fires. bin/fm-guard.sh warns as part of a fleet command,
# bin/fm-turnend-guard.sh fires at a turn boundary, and bin/fm-claude-stop-autoarm.sh
# re-arms the watcher at Stop. When the host's low-memory guard reaps the process
# that hosts supervision - the away-mode daemon, or the ordinary Claude Stop-hook
# watcher living in the hook's own process tree - and the fleet is idle, no turn
# fires, so none of those in-band mechanisms run. The fleet then sits unsupervised
# and SILENT until an unrelated captain message happens to start a turn. Two
# confirmed incidents (docs/verification/supervision.md, data/learnings.md
# 2026-08-12): the away daemon reaped during away mode, and the ordinary watcher
# down for ~63 minutes during an idle window while a crewmate waited parked.
#
# This guard closes that gap with an OUT-OF-BAND monitor whose own survival does
# not depend on the reaped host: it runs in a detached tmux session (the durable,
# universally-available reference host, the same class of terminal-backed host
# that survived reaping where the harness-native background job did not) and
# periodically re-checks supervision health for THIS home only. On a sustained,
# genuine outage it either self-recovers (relaunches the away daemon) or raises a
# loud, backend-independent active alarm plus a durable record - never a silent
# fail-open into an unsupervised fleet.
#
# HOME-SCOPED. Every path acts on FM_HOME's own state only. It never sweeps a
# shared endpoint namespace, never kills a sibling home's watcher, and never uses
# `pkill -f`. The detached tmux host is named per home and torn down by exact id.
#
# Subcommands (see fm_supervision_guard_usage):
#   tick       one health-check pass (the testable unit): recover or alarm, then exit 0.
#   daemon     the durable loop: run tick every interval while supervision is
#              needed, then exit when the home goes idle or the primary session dies.
#   ensure     idempotent: if supervision is needed and no live guard daemon runs,
#              launch one in a detached tmux host and record it. No-op otherwise.
#   stop       stop this home's guard daemon and close its recorded host by exact id.
#   reconcile  session-start recovery: drop a recorded-but-dead host, then ensure.
#   status     print whether a live guard daemon runs for this home (0 live, 1 not).
#
# Test seams: FM_SUPERVISION_GUARD_ENTRY overrides the command run in the created
# tmux host (a harmless placeholder for topology tests). FM_SUPERVISION_GUARD_ONESHOT=1
# makes `daemon` run exactly one tick and exit. FM_SUPERVISION_GUARD_PANE_BUSY
# (0|1) forces the busy verdict instead of reading a real pane. FM_WEDGE_ALARM_EXEC
# records the active alarm instead of posting a real notification.
set -u

FM_SUPERVISION_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_SUPERVISION_GUARD_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
# One extra confirmation window beyond GRACE: the outage must persist across at
# least this long (one tick) before the guard acts, so a single transient read
# during a normal between-turns gap never triggers recovery or an alarm.
GUARD_CONFIRM=${FM_SUPERVISION_GUARD_CONFIRM:-90}
# How long between ticks in the durable loop.
GUARD_INTERVAL=${FM_SUPERVISION_GUARD_INTERVAL:-60}
# Re-raise the active alarm at most once per this window while an ordinary-path
# outage persists, so a long outage does not spam notifications.
GUARD_REALARM=${FM_SUPERVISION_GUARD_REALARM:-1800}

WATCH="$FM_SUPERVISION_GUARD_DIR/fm-watch.sh"
LOCK="$STATE/.supervision-guard.lock"
RECORD="$STATE/.supervision-guard-terminal"
OUTAGE_SINCE="$STATE/.supervision-guard-outage-since"
OUTAGE_MARKER="$STATE/.supervision-guard-outage"
ALARM_STAMP="$STATE/.supervision-guard-alarmed"
LOG="${FM_SUPERVISION_GUARD_LOG:-$STATE/.supervision-guard.log}"

# shellcheck source=bin/fm-supervision-lib.sh
. "$FM_SUPERVISION_GUARD_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_SUPERVISION_GUARD_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_SUPERVISION_GUARD_DIR/fm-session-lock-lib.sh"
# pane_is_busy for the busy gate. Source-safe; adds no state.
# shellcheck source=bin/fm-supervisor-inject.sh
. "$FM_SUPERVISION_GUARD_DIR/fm-supervisor-inject.sh"
# discover_supervisor_target / discover_supervisor_backend for the busy gate and
# host-backend selection. Source-safe; adds no state.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_SUPERVISION_GUARD_DIR/fm-supervisor-target-lib.sh"

# The guard writes its own operational log; the shared wedge-alarm library resolves
# `log` at call time, so defining it before sourcing keeps alarm diagnostics in the
# guard log rather than the library's stderr fallback.
log() {
  [ -n "${LOG:-}" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || true
}
WEDGE_ALARM_TITLE="firstmate: SUPERVISION DOWN"
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$FM_SUPERVISION_GUARD_DIR/fm-wedge-alarm-lib.sh"

fm_supervision_guard_usage() {
  sed -n '30,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_supervision_guard_now() { date +%s; }

# --- health assessment ------------------------------------------------------

# True when a live primary session owns this home. The guard exists to keep a
# live primary supervised; with no live primary there is nothing to wake, so the
# guard neither recovers nor alarms (a future session start re-establishes both).
fm_supervision_guard_primary_alive() {
  local pid
  pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid"
}

# Affirmative-busy check for the ordinary autoarm path only. A test seam wins so
# the tick is exercisable without a real pane; otherwise read the captured captain
# pane. Only an AFFIRMATIVE busy verdict suppresses recovery: an idle or unreadable
# pane must not hide a real outage, so anything but a confirmed-busy pane proceeds.
fm_supervision_guard_pane_busy() {
  case "${FM_SUPERVISION_GUARD_PANE_BUSY:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  local target backend
  target="${FM_SUPERVISOR_TARGET:-}"
  backend="${FM_SUPERVISOR_BACKEND:-tmux}"
  [ -n "$target" ] || return 1
  pane_is_busy "$target" "$backend" 2>/dev/null
}

fm_supervision_guard_clear_outage() {
  rm -f "$OUTAGE_SINCE" "$OUTAGE_MARKER" "$ALARM_STAMP" 2>/dev/null || true
}

# Record the first-observed epoch of the current outage episode and echo how many
# seconds it has persisted. A fresh episode starts the clock and returns 0.
fm_supervision_guard_outage_age() {
  local now since
  now=$(fm_supervision_guard_now)
  since=$(cat "$OUTAGE_SINCE" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      printf '%s\n' "$now" > "$OUTAGE_SINCE" 2>/dev/null || true
      printf '0\n'
      return 0
      ;;
  esac
  printf '%s\n' "$((now - since))"
}

# --- recovery / alarm -------------------------------------------------------

# Away mode: relaunch the away daemon in its own terminal-backed host. Idempotent
# and home-scoped - fm-afk-launch.sh refreshes the flag when a live daemon already
# holds the lock and relaunches only a genuinely dead one. The captured captain
# pane is inherited from this guard's environment so the relaunched daemon injects
# into the captain, not the guard's own host.
fm_supervision_guard_relaunch_afk() {
  local out rc
  if [ -n "${FM_SUPERVISION_GUARD_RELAUNCH_CMD:-}" ]; then
    sh -c "$FM_SUPERVISION_GUARD_RELAUNCH_CMD" >/dev/null 2>&1
    return $?
  fi
  out=$("$FM_SUPERVISION_GUARD_DIR/fm-afk-launch.sh" start 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || log "afk relaunch failed (rc=$rc): $out"
  return "$rc"
}

# Ordinary path: raise a loud, durable, backend-independent alarm. The durable
# marker survives for the next session start to surface; the active alert reaches
# the captain outside the terminal. Re-armed at most once per GUARD_REALARM window.
fm_supervision_guard_alarm() {  # <reason> <age>
  local reason=$1 age=$2 now last summary
  now=$(fm_supervision_guard_now)
  {
    printf 'firstmate SUPERVISION DOWN: %s, unrecovered for %ss as of %s\n' \
      "$reason" "$age" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'The background watcher that turns crewmate status into wake events is gone and no turn is firing to re-arm it.\n'
    printf 'Send any message to firstmate to resume supervision; work already done is safe and durable.\n'
  } > "$OUTAGE_MARKER" 2>/dev/null || true

  last=$(cat "$ALARM_STAMP" 2>/dev/null || true)
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  if [ "$last" -gt 0 ] && [ "$((now - last))" -lt "$GUARD_REALARM" ]; then
    return 0
  fi
  printf '%s\n' "$now" > "$ALARM_STAMP" 2>/dev/null || true
  log "ERROR: supervision down ($reason) unrecovered ${age}s; raising active alarm. Marker $OUTAGE_MARKER written."
  summary="supervision down (${reason}) ${age}s - send any message to firstmate to resume; see $OUTAGE_MARKER"
  wedge_alarm_notify "$summary" "$OUTAGE_MARKER" "$WEDGE_ALARM_TITLE"
  return 0
}

# --- tick -------------------------------------------------------------------
# One health-check pass. Always exits 0: the guard recovers or alarms, it never
# blocks. Prints one status line to stdout and the log.
fm_supervision_guard_tick() {
  local afk=0 model verdict_ok verdict_reason age line
  mkdir -p "$STATE" 2>/dev/null || true

  if ! fm_supervision_guard_primary_alive; then
    fm_supervision_guard_clear_outage
    line="idle: no live primary session; nothing to supervise"
    printf '%s\n' "$line"; log "$line"; return 0
  fi

  fm_supervision_status "$STATE" "$GRACE"
  if [ "$FM_SUP_NEEDED" != true ]; then
    fm_supervision_guard_clear_outage
    line="ok: supervision not needed (no work, no relay poll, no event source)"
    printf '%s\n' "$line"; log "$line"; return 0
  fi

  fm_watcher_supervision_verdict "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$FM_ROOT"
  verdict_ok=$FM_WATCHER_VERDICT_OK
  verdict_reason=$FM_WATCHER_VERDICT_REASON
  if [ "$verdict_ok" = true ]; then
    fm_supervision_guard_clear_outage
    line="ok: supervision healthy"
    printf '%s\n' "$line"; log "$line"; return 0
  fi

  [ -e "$STATE/.afk" ] && afk=1
  model=$(fm_supervision_model)

  # Busy gate: only for the ordinary (non-afk) autoarm model. There the watcher is
  # legitimately absent DURING a turn and the Stop hook re-arms it when the turn
  # ends, so an affirmatively-busy captain pane is a running turn, not an outage.
  # Under away mode the Stop hook stands down and the away daemon owns re-arming,
  # so a busy pane there does not imply recovery; skip the gate.
  if [ "$afk" -eq 0 ] && [ "$model" = autoarm ] && fm_supervision_guard_pane_busy; then
    fm_supervision_guard_clear_outage
    line="ok: watcher between turns; captain pane busy (turn running, Stop hook will re-arm)"
    printf '%s\n' "$line"; log "$line"; return 0
  fi

  # Sustained-outage confirmation: require the down state to persist across at
  # least one confirmation window before acting, so a momentary read never trips.
  age=$(fm_supervision_guard_outage_age)
  if [ "$age" -lt "$GUARD_CONFIRM" ]; then
    line="watch: supervision down ($verdict_reason), ${age}s < ${GUARD_CONFIRM}s confirm window; holding"
    printf '%s\n' "$line"; log "$line"; return 0
  fi

  if [ "$afk" -eq 1 ]; then
    if fm_supervision_guard_relaunch_afk; then
      fm_supervision_guard_clear_outage
      line="recovered: away daemon relaunched after ${age}s outage ($verdict_reason)"
      printf '%s\n' "$line"; log "$line"; return 0
    fi
    # Relaunch failed: the captain is away and cannot see the pane, so alarm.
    fm_supervision_guard_alarm "away daemon down, relaunch failed" "$age"
    line="alarm: away daemon relaunch failed after ${age}s ($verdict_reason)"
    printf '%s\n' "$line"; log "$line"; return 0
  fi

  fm_supervision_guard_alarm "$verdict_reason" "$age"
  line="alarm: ordinary supervision down ($verdict_reason) ${age}s; captain notified"
  printf '%s\n' "$line"; log "$line"; return 0
}

# --- durable host lifecycle -------------------------------------------------

fm_supervision_guard_lock_live() {
  local pid identity actual
  [ -d "$LOCK" ] || return 1
  pid=$(cat "$LOCK/pid" 2>/dev/null) || return 1
  identity=$(cat "$LOCK/pid-identity" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$identity" ] || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$actual" = "$identity" ]
}

fm_supervision_guard_lock_acquire() {
  local identity attempt=0
  mkdir -p "$STATE" || return 1
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    if mkdir "$LOCK" 2>/dev/null; then
      identity=$(fm_pid_identity "$$" 2>/dev/null) || { rm -rf "$LOCK"; return 1; }
      if [ -z "$identity" ] \
        || ! printf '%s' "$$" > "$LOCK/pid" \
        || ! printf '%s' "$identity" > "$LOCK/pid-identity"; then
        rm -rf "$LOCK"
        return 1
      fi
      return 0
    fi
    if fm_supervision_guard_lock_live; then
      return 1
    fi
    rm -rf "$LOCK" 2>/dev/null || return 1
  done
  return 1
}

fm_supervision_guard_lock_release() {
  local pid
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$LOCK" 2>/dev/null || true
}

# The command run inside the detached host. Real launch loops the daemon; a test
# overrides it with a harmless placeholder to assert topology without a real loop.
fm_supervision_guard_entry_cmd() {
  printf '%s' "${FM_SUPERVISION_GUARD_ENTRY:-$FM_SUPERVISION_GUARD_DIR/fm-supervision-guard.sh}"
}

# The record is one line: "<backend>\t<target>\t<extra>". For tmux, target is the
# detached session name. For herdr, target is "<session>:<pane>" and extra is the
# dedicated workspace id kept for documentation (closing the pane takes its
# single-tab workspace with it). These read helpers set FM_GUARD_HOST_*.
fm_supervision_guard_host_read() {
  FM_GUARD_HOST_BACKEND=""; FM_GUARD_HOST_TARGET=""
  [ -f "$RECORD" ] || return 1
  IFS=$'\t' read -r FM_GUARD_HOST_BACKEND FM_GUARD_HOST_TARGET _ < "$RECORD" || return 1
  [ -n "$FM_GUARD_HOST_BACKEND" ] && [ -n "$FM_GUARD_HOST_TARGET" ]
}

fm_supervision_guard_tmux_session() {
  local hash
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  printf 'fm-supguard-%s' "$hash"
}

# Which detached-host backend to use. An explicit override wins; otherwise mirror
# the captain's own backend (the away daemon relaunch and busy gate reach the
# captain there), falling back to tmux.
fm_supervision_guard_host_backend() {
  case "${FM_SUPERVISION_GUARD_HOST_BACKEND:-}" in
    herdr|tmux) printf '%s' "$FM_SUPERVISION_GUARD_HOST_BACKEND"; return 0 ;;
  esac
  case "${FM_SUPERVISOR_BACKEND:-}" in
    herdr|tmux) printf '%s' "$FM_SUPERVISOR_BACKEND"; return 0 ;;
  esac
  local b
  b=$(discover_supervisor_backend 2>/dev/null || true)
  case "$b" in herdr|tmux) printf '%s' "$b" ;; *) printf tmux ;; esac
}

fm_supervision_guard_host_close() {
  if fm_supervision_guard_host_read; then
    case "$FM_GUARD_HOST_BACKEND" in
      tmux) tmux kill-session -t "$FM_GUARD_HOST_TARGET" 2>/dev/null || true ;;
      herdr)
        local session=${FM_GUARD_HOST_TARGET%%:*} pane=${FM_GUARD_HOST_TARGET#*:}
        if [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$FM_GUARD_HOST_TARGET" ]; then
          fm_backend_source herdr 2>/dev/null && fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1 || true
        fi ;;
    esac
  fi
  rm -f "$RECORD" 2>/dev/null || true
}

# The command the detached host runs: this same script's `daemon`, carrying the
# captured captain pane so a later away-daemon relaunch injects into the captain
# (not the guard's own host) and the busy gate reads the right pane.
fm_supervision_guard_host_cmd() {
  local entry target backend overrides=""
  entry=$(fm_supervision_guard_entry_cmd)
  target="${FM_SUPERVISOR_TARGET:-$(discover_supervisor_target 2>/dev/null || true)}"
  backend="${FM_SUPERVISOR_BACKEND:-$(discover_supervisor_backend 2>/dev/null || printf tmux)}"
  # Propagate the home's own state/root overrides so the detached daemon monitors
  # exactly this home (a secondmate home or a test may set these explicitly).
  [ -n "${FM_STATE_OVERRIDE:-}" ] && overrides="$overrides FM_STATE_OVERRIDE=$(printf '%q' "$FM_STATE_OVERRIDE")"
  [ -n "${FM_ROOT_OVERRIDE:-}" ] && overrides="$overrides FM_ROOT_OVERRIDE=$(printf '%q' "$FM_ROOT_OVERRIDE")"
  printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q FM_SUPERVISION_GUARD_ROLE=daemon%s %q daemon' \
    "$FM_HOME" "$target" "$backend" "$overrides" "$entry"
}

fm_supervision_guard_launch_tmux() {
  local session cmd
  command -v tmux >/dev/null 2>&1 || { log "cannot establish guard host: tmux not found"; return 1; }
  session=$(fm_supervision_guard_tmux_session)
  cmd=$(fm_supervision_guard_host_cmd)
  tmux kill-session -t "$session" 2>/dev/null || true
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    log "failed to create detached tmux guard host '$session'"
    return 1
  fi
  printf 'tmux\t%s\t\n' "$session" > "$RECORD" 2>/dev/null || {
    tmux kill-session -t "$session" 2>/dev/null || true
    log "failed to record tmux guard host '$session'"; return 1; }
  log "guard host launched in detached tmux session '$session'"
  return 0
}

# Launch a NON-VISIBLE herdr workspace (--no-focus, dedicated single-pane) in the
# captain's session, never a split of the captain's pane. Mirrors the away-mode
# daemon's proven terminal-backed host (bin/fm-afk-launch.sh), the host class that
# survived reaping where the harness-native background job did not.
fm_supervision_guard_launch_herdr() {
  local target session out wsid pane cmd label
  target="${FM_SUPERVISOR_TARGET:-$(discover_supervisor_target 2>/dev/null || true)}"
  session=${target%%:*}
  if [ -z "$session" ] || [ "$session" = "$target" ]; then
    log "cannot derive herdr session from captain target '$target'"; return 1
  fi
  fm_backend_source herdr || { log "herdr backend adapter unavailable"; return 1; }
  fm_backend_herdr_server_ensure "$session" || { log "herdr server not ready for '$session'"; return 1; }
  label="${FM_SUPERVISION_GUARD_LABEL:-firstmate-supervision-guard-$$-${RANDOM:-0}-$(date '+%s')}"
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    log "herdr workspace create did not yield exact ids"; return 1
  fi
  cmd=$(fm_supervision_guard_host_cmd)
  if ! printf 'herdr\t%s:%s\t%s\n' "$session" "$pane" "$wsid" > "$RECORD" 2>/dev/null; then
    fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1 || true
    log "failed to record herdr guard host"; return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_supervision_guard_host_close
    log "failed to run guard daemon in herdr pane $session:$pane"; return 1
  fi
  log "guard host launched in non-visible herdr workspace $wsid (pane $session:$pane)"
  return 0
}

# Launch the durable host on the resolved backend.
fm_supervision_guard_launch_host() {
  local backend
  backend=$(fm_supervision_guard_host_backend)
  case "$backend" in
    herdr) fm_supervision_guard_launch_herdr ;;
    tmux) fm_supervision_guard_launch_tmux ;;
    *) log "no detached-host primitive for backend '$backend'"; return 1 ;;
  esac
}

# Idempotent: ensure a live guard daemon exists for this home when supervision is
# needed. No-op when not needed, or when a live daemon already runs.
fm_supervision_guard_ensure() {
  if ! fm_supervision_needed "$STATE" "$GRACE"; then
    return 0
  fi
  if ! fm_supervision_guard_primary_alive; then
    return 0
  fi
  if fm_supervision_guard_lock_live; then
    return 0
  fi
  # The daemon lock is not live, so any recorded host is defunct even if its pane
  # lingers after the daemon exited (herdr leaves the pane; a new launch would
  # otherwise orphan it). Tear it down by exact id before relaunching.
  [ -f "$RECORD" ] && fm_supervision_guard_host_close
  fm_supervision_guard_launch_host || return 1
  # Wait briefly for the daemon inside the host to take the lock, so an immediate
  # follow-up ensure is a no-op instead of relaunching into the startup window.
  # Best-effort: a daemon that never takes the lock is retried by the next ensure.
  local i=0
  while [ "$i" -lt 50 ]; do
    fm_supervision_guard_lock_live && break
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

fm_supervision_guard_reconcile() {
  # Drop a recorded host whose daemon is no longer live, even when supervision is
  # not currently needed, so a stale record never lingers. ensure re-establishes
  # one when work is in flight.
  if [ -f "$RECORD" ] && ! fm_supervision_guard_lock_live; then
    fm_supervision_guard_host_close
  fi
  fm_supervision_guard_ensure
}

fm_supervision_guard_stop() {
  local pid
  if fm_supervision_guard_lock_live; then
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  fi
  fm_supervision_guard_host_close
  rm -rf "$LOCK" 2>/dev/null || true
  fm_supervision_guard_clear_outage
  log "guard stopped"
  return 0
}

fm_supervision_guard_status() {
  if fm_supervision_guard_lock_live; then
    printf 'live: guard daemon pid=%s\n' "$(cat "$LOCK/pid" 2>/dev/null)"
    return 0
  fi
  printf 'down: no live guard daemon for this home\n'
  return 1
}

# The durable loop. Owns the guard lock for its lifetime and ticks until the home
# goes idle or the primary session dies, so an idle home never keeps a guard.
fm_supervision_guard_daemon() {
  if ! fm_supervision_guard_lock_acquire; then
    log "another guard daemon already owns this home; standing down"
    return 0
  fi
  trap 'fm_supervision_guard_lock_release; exit 0' TERM INT
  trap fm_supervision_guard_lock_release EXIT
  log "guard daemon started pid=$$"
  while :; do
    fm_supervision_guard_tick >/dev/null 2>&1 || true
    if [ "${FM_SUPERVISION_GUARD_ONESHOT:-}" = 1 ]; then
      break
    fi
    if ! fm_supervision_guard_primary_alive; then
      log "primary session gone; guard daemon exiting"
      break
    fi
    if ! fm_supervision_needed "$STATE" "$GRACE"; then
      log "home idle; guard daemon exiting"
      break
    fi
    sleep "$GUARD_INTERVAL"
  done
  fm_supervision_guard_lock_release
  trap - TERM INT EXIT
  return 0
}

fm_supervision_guard_main() {
  case "${1:-tick}" in
    tick) fm_supervision_guard_tick ;;
    daemon) fm_supervision_guard_daemon ;;
    ensure) fm_supervision_guard_ensure ;;
    reconcile) fm_supervision_guard_reconcile ;;
    stop) fm_supervision_guard_stop ;;
    status) fm_supervision_guard_status ;;
    -h|--help|help) fm_supervision_guard_usage ;;
    *) fm_supervision_guard_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_supervision_guard_main "$@"
fi
