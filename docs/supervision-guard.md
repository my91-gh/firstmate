# Out-of-band supervision liveness guard

`bin/fm-supervision-guard.sh` is the out-of-band monitor that keeps a reaped supervision process from silently leaving the fleet unsupervised.
Its script header owns the exact subcommands, flags, and test seams; this document owns the mechanism, the ownership boundaries, and the safety rationale.
Active verification lives in [`verification/supervision.md`](verification/supervision.md).

## The gap it closes

Every other supervision detect/re-arm path is in-band: it runs only when a turn fires.
`bin/fm-guard.sh` warns as part of a fleet command, `bin/fm-turnend-guard.sh` fires at a turn boundary, and `bin/fm-claude-stop-autoarm.sh` re-arms the Claude watcher at Stop.
When the host's low-memory guard reaps the process that hosts supervision and the fleet is idle, no turn fires, so none of those mechanisms run.
The reaped host is either the away-mode daemon (`bin/fm-supervise-daemon.sh` and its `bin/fm-watch.sh` child) or the ordinary Claude Stop-hook watcher, which lives in the hook's own process tree.
The fleet then sits unsupervised and silent until an unrelated captain message happens to start a turn.

Two confirmed incidents share this one root cause on different paths:

- 2026-08-12 (away mode): the away daemon was reaped repeatedly while `state/.afk` stayed present; nothing relaunched it and nothing alarmed.
- 2026-09-08 (ordinary supervision): the Stop-hook watcher was reaped during an idle window; a crewmate that parked awaiting a `/no-mistakes` instruction never became a wake, and nothing alarmed for about 63 minutes.

## Design

The guard is an out-of-band monitor whose own survival does not depend on the reaped host.
It runs in a detached terminal, the same class of terminal-backed host that survived reaping where the harness-native background job did not (`data/learnings.md` 2026-08-12).
It uses the captain's own backend when that is a non-visible herdr workspace (`--no-focus`) or a detached tmux session, both established with the same primitives the away-mode daemon host uses (`bin/fm-afk-launch.sh`).
It periodically re-checks supervision health for its own `FM_HOME` only and, on a sustained genuine outage, either self-recovers or raises a loud, backend-independent active alarm plus a durable record.
It never fails open into an unsupervised fleet.

### Health assessment

Each tick reads durable state only and decides in this order:

- No live primary session (`state/.lock` names a dead pid): nothing to wake, so the guard neither recovers nor alarms and clears any outage clock.
  A future session start re-establishes both the primary and the guard.
- Supervision not needed (no in-flight work, no relay poll, no event source): healthy, clear the outage clock.
- Supervision healthy per the model-aware verdict (`fm_watcher_supervision_verdict`): clear the outage clock.
- Supervision down: apply the gates below before acting.

### Busy gate

The gate distinguishes a reaped-and-idle watcher from a watcher that is legitimately absent during a long turn.
Under the Claude auto-arm model the watcher runs only between turns, so an affirmatively busy captain pane means a turn is running and the Stop hook will re-arm the watcher when it ends; the guard suppresses recovery there.
The gate applies only to the ordinary (non-afk) auto-arm path.
Under away mode the Stop hook stands down and the away daemon owns re-arming, so a busy pane does not imply recovery and the gate is skipped.
Only an affirmatively busy pane suppresses; an idle or unreadable pane must never hide a real outage, so anything but a confirmed-busy pane proceeds.

### Sustained-outage gate

The down state must persist across at least one confirmation window (`FM_SUPERVISION_GUARD_CONFIRM`, default 90s) beyond the beacon grace before the guard acts, so a single transient read during a normal between-turns gap never triggers recovery or an alarm.
The first-observed epoch is recorded in `state/.supervision-guard-outage-since` and cleared on any return to health.

### Recovery and alarm

- Away mode (`state/.afk` present): relaunch the away daemon through `bin/fm-afk-launch.sh start`.
  That call is idempotent and home-scoped: it refreshes the flag when a live daemon already holds the lock and relaunches only a genuinely dead one, and the captured captain pane is inherited so the relaunched daemon injects into the captain.
  If the relaunch fails, the guard alarms, because the captain is away and cannot see the pane.
- Ordinary path: raise a loud, durable, backend-independent alarm.
  The durable marker `state/.supervision-guard-outage` survives for the next session start to surface, and the active alert (`wedge_alarm_notify` in `bin/fm-wedge-alarm-lib.sh`) reaches the captain outside the terminal.
  The active alert is re-armed at most once per `FM_SUPERVISION_GUARD_REALARM` window (default 1800s) so a long outage does not spam notifications, while the durable marker persists across ticks.

An ordinary-path outage is recovered when the captain returns and a turn fires, which re-arms the watcher through the normal Stop-hook path; the guard's job there is to make the outage loud rather than to inject into a present captain's pane.

## Home-scoping

Every path acts on `FM_HOME`'s own state only.
The guard never sweeps a shared endpoint namespace, never kills a sibling home's watcher, and never uses `pkill -f`.
The detached tmux host is named per home from a hash of `FM_HOME`, and the herdr host is a dedicated per-home workspace; both are torn down by exact id.

## Lifecycle and wiring

The guard is alive precisely when supervision is needed, established at the points where a turn has just run:

- `bin/fm-watch-arm.sh` calls `ensure` on every arm, so the guard tracks the watcher it just established (Claude auto-arm, persistent-harness arms, and standalone arms).
- `bin/fm-afk-launch.sh start` calls `ensure` on away-mode entry.
- `bin/fm-bootstrap.sh` calls `reconcile` at every locked session start, which drops a recorded-but-dead host and re-establishes the guard when work is in flight; this is what brings a guard reaped during an idle stretch back at the next session start.

`ensure` is idempotent and best-effort: it is a no-op when supervision is not needed, when no live primary session owns the home, or when a live guard daemon already runs, and it never blocks or fails its caller.
The guard daemon exits on its own when the home goes idle or the primary session dies, so an idle home never keeps a guard running.
The guard host command carries `FM_SUPERVISION_GUARD_ROLE=daemon`, which suppresses a recursive `ensure` from any arm the daemon path might reach.

## Configuration

All knobs are environment overrides with safe defaults; see the script header for the complete list.

- `FM_SUPERVISION_GUARD_INTERVAL` (default 60s): seconds between ticks in the durable loop.
- `FM_SUPERVISION_GUARD_CONFIRM` (default 90s): the sustained-outage confirmation window.
- `FM_SUPERVISION_GUARD_REALARM` (default 1800s): the minimum interval between active alerts for one ordinary-path outage.
- `FM_GUARD_GRACE` (default 300s): the shared beacon-freshness grace, the same definition the watcher and the in-band guards use.
- The active-alert channel is `config/wedge-alarm` (see [`wedge-alarm.md`](wedge-alarm.md)).

## Relationship to the in-band guards

The in-band guards remain the primary, fast path when a turn is running.
This guard is the backstop for the one case they structurally cannot cover: an outage during an idle window with no turn to carry them.
It complements, and does not replace, `bin/fm-turnend-guard.sh` and `bin/fm-guard.sh`.
