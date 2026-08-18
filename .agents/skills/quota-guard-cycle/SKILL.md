---
name: quota-guard-cycle
description: >-
  Agent-only procedure for provider-quota exhaustion and recovery.
  Load on any `check:` wake whose payload names `quota-guard alert:` or
  `quota-guard resume:`, and before pausing or restarting work for quota.
  Owns which work is paused, how it is paused without losing anything, the
  durable record that makes the pause survivable, and what restarts it.
user-invocable: false
metadata:
  internal: true
---

# Quota alert, pause, and resume

`bin/fm-quota-guard.sh` watches Claude and Codex quota and signals; it never acts.
This skill is the single owner of what Firstmate does with those two signals.
The script's header and `--help` own every command, flag, path, and threshold, so read them there rather than restating them here.

## The one rule that makes this safe

Pausing is never teardown.
No step in this procedure may tear down a task, discard a worktree, drop uncommitted work, force anything, or merge anything.
A worker that is paused for quota is still a live worker holding its own unlanded work, and the whole point of pausing it is that it stops burning a window it cannot win against - not that its work is abandoned.
Hard rules 2 and 3 stay fully in force throughout, and a quota alert is never authority for a destructive or irreversible action.

## On an alert wake

The wake names the provider, the window, current usage, and when that window resets.

1. Pause every task under way.
   Interrupt each live worker with `bin/fm-control.sh <task-id> interrupt`, which stops the current turn and deliberately leaves the worker, its local copy, and its uncommitted changes alone.
2. Record each paused task with the guard's `pause-task` command against the exact window from the wake.
   That durable record is what survives a Firstmate restart; conversation memory is not a record, and a pause you cannot prove later is a pause you will not undo.
3. Do the recording even when an interrupt could not be confirmed, then reconcile that worker's real state with `bin/fm-crew-state.sh` before treating it as paused.
   A worker that is already stopped needs no interrupt and is still recorded.
4. Dispatch no new work for the paused window until the resume arrives.
   Queue the request in the backlog instead, under the existing backlog contract in `AGENTS.md` section 10.

A second alert for the same window will not arrive, because the guard alerts once per exhaustion episode.
If the fleet is empty, the alert still matters: it is what tells you not to dispatch into an exhausted window.

## On a resume wake

The wake names the window that refreshed, and the guard has already confirmed both that the window's reset passed and that usage actually dropped, so the window is genuinely usable again.

1. Ask the guard for the tasks paused for that window with `resume-tasks`, which prints them and clears the ledger in one step.
2. Restart each one with a short `bin/fm-send.sh` line telling it to continue its brief.
   Restarting is data-plane text, not a lifecycle verb, because the worker was interrupted rather than stopped.
3. Reconcile before you trust it: a worker whose recorded endpoint is gone is a stuck-worker case, so load `stuck-crewmate-recovery` for that one instead of re-sending into nothing.
4. Re-evaluate queued work whose quota blocker has now cleared, exactly as after any teardown or heartbeat.

An empty `resume-tasks` result is normal and needs no action: nothing was under way when that window went down.

## Telling the captain

Work stopping for hours is captain-relevant, so say it once when it happens and once when it clears.
Follow `AGENTS.md` section 9 and translate it into outcomes: the provider is out of capacity until a stated time, this is what is waiting on it, and it restarts on its own.
Never expose the wake, the window id, the ledger, the guard, or any other internal term in that message, and never re-report the same unchanged wait as progress.

## Where this comes from

Every session start arms the guard idempotently through `bin/fm-bootstrap.sh`, so a running home already has one and no turn needs to remember to start it.
Arming is deliberately fail-open: a home with no guard loses this safety net but never loses its session start.
Use the guard's `status` command when you need to see live windows, open episodes, and the paused-task ledger together.
