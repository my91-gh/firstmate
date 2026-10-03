---
name: updatemyfirstmate
description: >-
  Resynchronize the captain's GitHub fork of firstmate with kunchenguid/firstmate, then update this Mac's firstmate from the fork.
  Use when the captain invokes /updatemyfirstmate (e.g. "/updatemyfirstmate", "sync my fork with upstream and update firstmate").
  Merges upstream's main into the fork's main in an isolated copy, ships a clean merge after the tests pass, opens a pull request for any conflict resolution, and then runs the /updatefirstmate flow so the local copy and every second mate follow the fork.
user-invocable: true
metadata:
  internal: true
---

# updatemyfirstmate

`/updatefirstmate` only fast-forwards this repo from `origin`, which is the captain's fork.
This skill adds the step before it: bring upstream's `main` into the fork's `main`, then run `/updatefirstmate`.
`bin/fm-fork-sync.sh` owns the mechanics and every refusal; its header owns the subcommands and output lines.
Never merge in the primary checkout, never rebase or force-push the fork's `main`, and never push a resolved conflict to `main`.

## What it does

1. **Check the remotes and compare.**
   ```sh
   bin/fm-fork-sync.sh check
   ```
   It verifies `origin` is a fork of `kunchenguid/firstmate`, adds the `upstream` remote when missing, fetches both, and prints `state: current|behind`.
   A refusal (origin is not a fork, `upstream` points elsewhere, GitHub unreachable) is the final answer: report it and stop.
   On `state: current`, go to step 6.
   On `state: behind`, it lists the arriving upstream commits.
   When it prints `branch-on-origin: yes`, a conflict PR for this exact upstream tip may already be waiting: look it up with `gh-axi pr list --head <branch>`.
   An open one means report it and stop; a merged one means rerun the check.
   A closed one, or no pull request at all, means the branch is stale: delete it with `git push origin --delete <branch>`, then continue.
   Never force-push over it; `push-branch` refuses a stale branch that the new merge does not fast-forward.

2. **Merge in an isolated copy.**
   ```sh
   bin/fm-fork-sync.sh merge
   ```
   It refuses when the primary checkout has uncommitted changes.
   Otherwise it prints `worktree: <path>` and either `merge: clean` or `merge: conflict` with one `conflict: <file>` line per file.

3. **Clean merge: test, then fast-forward the fork.**
   A clean merge carries only upstream's already-reviewed changes, so it ships without a pull request.
   ```sh
   bin/fm-fork-sync.sh test <worktree>
   bin/fm-fork-sync.sh push-main <worktree>
   ```
   `test` runs the repository's full suite on the merge result and can take a long time; run it in the background and poll.
   `push-main` refuses unless the suite passed on that exact commit and the push is a plain fast-forward.
   A failing suite stops the sync: report which tests failed and leave the fork untouched.
   Then go to step 5.

4. **Conflicts: resolve, test, open a pull request, stop.**
   Resolve each conflicted file in the worktree, keeping the fork's own changes and upstream's intent.
   Read both sides and `git log` of the file before choosing; never take one side wholesale to make the conflict disappear.
   Then `git add` the files, `git commit --no-edit` in the worktree, run `bin/fm-fork-sync.sh test <worktree>`, and push the branch:
   ```sh
   bin/fm-fork-sync.sh push-branch <worktree>
   ```
   Open the pull request on the fork with `gh-axi pr create --repo <fork> --base main --head <branch> --title ... --body-file ...`.
   The body lists every conflicted file, how each was resolved and why, and the test result (say plainly if tests failed).
   The body also tells the captain to merge it with "Create a merge commit", never squash or rebase.
   A squash or rebase drops upstream's history from the fork's `main`, so every later sync would hit the same conflicts again.
   Resolutions are new content, so the captain's merge approval is required; never merge it.
   Report the full pull request URL, remind the captain to merge it with "Create a merge commit", and stop.
   After the captain merges it, a rerun of `/updatemyfirstmate` finds the fork current and continues at step 6.

5. **Clean up.**
   ```sh
   bin/fm-fork-sync.sh cleanup <worktree>
   ```
   After a conflict pull request is opened, clean up the same way.
   Use `--abandon` only to drop an unfinished merge the captain no longer wants.

6. **Update this Mac.**
   Run the `/updatefirstmate` flow in full: load the `updatefirstmate` skill and follow its steps (`bin/fm-update.sh`, the AGENTS.md re-read, the second-mate restarts, the re-read nudges).
   Do not repeat those steps here.

7. **Report to the captain in plain outcomes** under `AGENTS.md` section 9.
   Say which upstream changes arrived in the fork (a few headline commits, not a list of hashes), or that the fork was already current.
   Say whether a conflict pull request is waiting for approval, with its full URL, and that the local copy was not updated because of it.
   Otherwise report what the `/updatefirstmate` flow updated locally, with the same honesty about skipped or only-nudged second mates.

## Safety

- **Isolated and non-destructive.**
  The merge happens in a disposable copy cut from `origin/main`; the primary checkout is never touched.
  Nothing is forced, rebased, stashed, or discarded.
- **Merge authority.**
  Only an unmodified clean merge of upstream's own commits reaches the fork's `main` without a pull request, and only after the tests pass.
  Anything resolved by hand waits for the captain's merge approval.
- **Fork identity.**
  The helper refuses any `origin` that GitHub does not report as a fork of `kunchenguid/firstmate`, so the sync can never push into the wrong repository.
