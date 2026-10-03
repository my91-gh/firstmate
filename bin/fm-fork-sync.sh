#!/usr/bin/env bash
# Bring upstream's main into the fork's main - the mechanical half of the
# /updatemyfirstmate skill, which then hands the local update to fm-update.sh.
#
# `origin` must be a GitHub fork of the upstream repo (default
# kunchenguid/firstmate) and the `upstream` remote must point at that repo;
# a missing `upstream` remote is added, anything else is refused. The merge
# never happens in the primary checkout: it runs in a disposable worktree cut
# from origin/main, and the fork's main is never rebased or force-pushed.
#
# Subcommands (each prints parseable `key: value` lines; exit 0 = success):
#   check
#       Verify the remotes, fetch both, and print `state: current|behind`.
#       `current` means origin/main already contains upstream/main, so the
#       caller skips straight to the local update. Also prints the upstream
#       tip, the count and subjects of the arriving commits, the deterministic
#       conflict-PR branch name for this upstream tip, and whether that branch
#       is already on origin (a conflict PR may already be waiting). When it is,
#       `branch-state: up-to-date` means the branch still contains both the
#       current origin main and the upstream tip, so a PR can be opened from it
#       as is; `branch-state: outdated` means the fork's main moved since.
#   merge
#       Refuse when the primary checkout has uncommitted tracked changes. Cut
#       a disposable worktree from origin/main and merge upstream/main into it
#       with a merge commit. Prints `worktree: <path>` and either
#       `merge: clean` (a single merge commit, recorded as the only commit
#       push-main will publish) or `merge: conflict` plus one `conflict: <path>`
#       line per unmerged file; the conflicted worktree is left in the merge
#       state for the caller to resolve, commit, and test. A merge that fails
#       without conflicts removes its worktree before failing.
#   commit <worktree>
#       Finish a resolved conflict merge with a plain `git commit --no-edit`,
#       hooks included (never --no-verify). Refuses while conflicts remain
#       unresolved. When a git hook refuses the commit, it prints the hook's
#       exact output, exits non-zero, and leaves the worktree in the merge
#       state; the caller reports that message to the captain and stops.
#   test <worktree>
#       Run the repository's test suite on the merge result (default
#       `bin/fm-test-run.sh --all` in the worktree, overridable with
#       FM_FORK_SYNC_TEST_CMD) and, on success, stamp that exact HEAD as tested.
#       Refuses a worktree with uncommitted or untracked changes, before the
#       suite runs and again before stamping, so only committed content passes.
#   push-main <worktree>
#       Fast-forward origin main to the clean merge commit. Refuses unless the
#       merge was clean and still unmodified, the suite passed on that exact
#       HEAD, and the push is a plain fast-forward. A resolved conflict can
#       never take this path - it ships as a reviewed PR.
#   push-branch <worktree>
#       Push the committed merge to origin as the conflict-PR branch printed by
#       `check` (never forced); the caller then opens the PR against main.
#       When a stale branch from an earlier sync of the same upstream tip is
#       already on origin and does not fast-forward, it refuses and says so.
#   cleanup <worktree> [--abandon]
#       Remove the disposable worktree. A worktree still holding an unfinished
#       merge or uncommitted changes needs --abandon.
#
# FM_FORK_UPSTREAM_URL / FM_FORK_UPSTREAM_PARENT override the expected upstream
# repo (URL, and the owner/name GitHub reports as origin's parent), and
# FM_FORK_BRANCH overrides the branch (main); they exist for the test suite.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
UPSTREAM_URL="${FM_FORK_UPSTREAM_URL:-https://github.com/kunchenguid/firstmate.git}"
UPSTREAM_PARENT="${FM_FORK_UPSTREAM_PARENT:-kunchenguid/firstmate}"
BRANCH="${FM_FORK_BRANCH:-main}"
MERGE_MSG="Merge upstream ${UPSTREAM_PARENT%%/*}/$BRANCH into fork $BRANCH"
WT_PREFIX=fm-fork-sync

die() { echo "fm-fork-sync: $*" >&2; exit 1; }
git_root() { git -C "$FM_ROOT" "$@"; }

normalize_url() {
  printf '%s\n' "$1" | sed -e 's#^git@github.com:#https://github.com/#' \
    -e 's#^ssh://git@github.com/#https://github.com/#' -e 's#/*$##' -e 's#\.git$##'
}

# Echo "added" when the upstream remote had to be created; die on any mismatch.
verify_remotes() {
  local origin_url upstream_url parent
  origin_url=$(git_root remote get-url origin 2>/dev/null) || die "no origin remote in $FM_ROOT"
  [ "$(normalize_url "$origin_url")" != "$(normalize_url "$UPSTREAM_URL")" ] ||
    die "origin is $origin_url, the upstream repo itself; point origin at your fork"
  if upstream_url=$(git_root remote get-url upstream 2>/dev/null); then
    [ "$(normalize_url "$upstream_url")" = "$(normalize_url "$UPSTREAM_URL")" ] ||
      die "remote 'upstream' is $upstream_url, expected $UPSTREAM_URL"
  else
    git_root remote add upstream "$UPSTREAM_URL"
    echo "upstream-remote: added"
  fi
  parent=$(gh repo view "$origin_url" --json parent \
    --jq '.parent | if . then .owner.login + "/" + .name else "" end' 2>/dev/null) ||
    die "cannot ask GitHub whether $origin_url is a fork (is gh signed in?)"
  [ "$parent" = "$UPSTREAM_PARENT" ] ||
    die "origin $origin_url is not a fork of $UPSTREAM_PARENT (GitHub reports: ${parent:-no parent})"
  echo "origin: $origin_url"
  echo "upstream: $UPSTREAM_URL"
  echo "fork-of: $parent"
}

fetch_both() {
  git_root fetch -q origin || die "fetch origin failed"
  git_root fetch -q upstream || die "fetch upstream failed"
  git_root rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null || die "origin/$BRANCH not found"
  git_root rev-parse --verify -q "refs/remotes/upstream/$BRANCH" >/dev/null || die "upstream/$BRANCH not found"
}

is_current() { git_root merge-base --is-ancestor "refs/remotes/upstream/$BRANCH" "refs/remotes/origin/$BRANCH"; }
sync_branch() { echo "sync/upstream-$(git_root rev-parse --short=12 "refs/remotes/upstream/$BRANCH")"; }

cmd_check() {
  verify_remotes
  fetch_both
  if is_current; then
    echo "state: current"
    return 0
  fi
  local br sha
  br=$(sync_branch)
  echo "state: behind"
  echo "upstream-tip: $(git_root rev-parse "refs/remotes/upstream/$BRANCH")"
  echo "upstream-new-commits: $(git_root rev-list --count "refs/remotes/origin/$BRANCH..refs/remotes/upstream/$BRANCH")"
  git_root log --format='upstream-commit: %h %s' -n 30 "refs/remotes/origin/$BRANCH..refs/remotes/upstream/$BRANCH"
  echo "branch: $br"
  sha=$(git_root ls-remote origin "refs/heads/$br" | cut -f1)
  if [ -z "$sha" ]; then
    echo "branch-on-origin: no"
    return 0
  fi
  echo "branch-on-origin: yes"
  git_root fetch -q origin "refs/heads/$br" || die "fetch of $br failed"
  if git_root merge-base --is-ancestor "refs/remotes/origin/$BRANCH" "$sha" &&
    git_root merge-base --is-ancestor "refs/remotes/upstream/$BRANCH" "$sha"; then
    echo "branch-state: up-to-date"
  else
    echo "branch-state: outdated"
  fi
}

# Validate that $1 is one of this script's disposable worktrees and echo its
# git dir. Dies for anything else, so no subcommand can touch another checkout.
wt_gitdir() {
  local wt=$1 top
  [ -d "$wt" ] || die "no such worktree: $wt"
  case "$(basename "$(dirname "$wt")")" in "$WT_PREFIX".*) ;; *) die "not a $WT_PREFIX worktree: $wt" ;; esac
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || die "not a git worktree: $wt"
  [ "$(cd "$top" && pwd -P)" = "$(cd "$wt" && pwd -P)" ] || die "not a worktree root: $wt"
  git -C "$wt" rev-parse --absolute-git-dir
}

remove_wt() {
  git_root worktree remove --force "$1"
  rmdir "$(dirname "$1")" 2>/dev/null || true
}

cmd_merge() {
  verify_remotes
  fetch_both
  if is_current; then
    echo "merge: not-needed"
    return 0
  fi
  [ -z "$(git_root status --porcelain --untracked-files=no)" ] ||
    die "the primary checkout has uncommitted changes; commit or discard them first"
  local dir wt gd conflicts merge_out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/$WT_PREFIX.XXXXXX")
  wt="$dir/wt"
  git_root worktree add -q --detach "$wt" "refs/remotes/origin/$BRANCH" || { rmdir "$dir"; die "cannot create the merge worktree"; }
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  echo "worktree: $wt"
  if merge_out=$(git -C "$wt" merge -q --no-ff -m "$MERGE_MSG" "refs/remotes/upstream/$BRANCH" 2>&1); then
    printf 'clean %s\n' "$(git -C "$wt" rev-parse HEAD)" > "$gd/$WT_PREFIX-outcome"
    echo "merge: clean"
    return 0
  fi
  conflicts=$(git -C "$wt" diff --name-only --diff-filter=U)
  if [ -z "$conflicts" ] || [ ! -e "$gd/MERGE_HEAD" ]; then
    remove_wt "$wt"
    die "merge failed without conflicts and its worktree was removed: $merge_out"
  fi
  echo conflict > "$gd/$WT_PREFIX-outcome"
  echo "merge: conflict"
  printf '%s\n' "$conflicts" | sed 's/^/conflict: /'
}

# Die unless the worktree $1 has no uncommitted or untracked changes.
require_clean_tree() {
  [ -z "$(git -C "$1" status --porcelain)" ] ||
    die "the worktree has uncommitted changes; commit them so HEAD is what gets tested and pushed"
}

# Die unless the merge in $1 is committed, matches HEAD exactly, and contains
# both branch tips.
require_committed_merge() {
  local wt=$1 gd=$2
  [ ! -e "$gd/MERGE_HEAD" ] || die "the merge is not committed yet"
  [ -z "$(git -C "$wt" diff --name-only --diff-filter=U)" ] || die "unresolved conflicts remain"
  require_clean_tree "$wt"
  git -C "$wt" merge-base --is-ancestor "refs/remotes/upstream/$BRANCH" HEAD || die "HEAD lacks upstream/$BRANCH"
  git -C "$wt" merge-base --is-ancestor "refs/remotes/origin/$BRANCH" HEAD || die "HEAD lacks origin/$BRANCH; fetch moved, redo the merge"
}

cmd_commit() {
  local wt=${1:?usage: fm-fork-sync.sh commit <worktree>} gd out
  gd=$(wt_gitdir "$wt")
  [ -e "$gd/MERGE_HEAD" ] || die "no merge in progress in $wt"
  [ -z "$(git -C "$wt" diff --name-only --diff-filter=U)" ] ||
    die "unresolved conflicts remain; resolve and git add them first"
  if ! out=$(git -C "$wt" commit --no-edit 2>&1); then
    printf '%s\n' "$out" >&2
    die "git refused the merge commit (see its output above); the worktree is left in the merge state; report this to the captain and never bypass hooks"
  fi
  echo "committed: $(git -C "$wt" rev-parse HEAD)"
}

cmd_test() {
  local wt=${1:?usage: fm-fork-sync.sh test <worktree>} gd head
  gd=$(wt_gitdir "$wt")
  rm -f "$gd/$WT_PREFIX-tested"
  require_committed_merge "$wt" "$gd"
  head=$(git -C "$wt" rev-parse HEAD)
  if (cd "$wt" && eval "${FM_FORK_SYNC_TEST_CMD:-bin/fm-test-run.sh --all}"); then
    [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || die "HEAD moved while the suite ran; rerun test"
    require_clean_tree "$wt"
    echo "$head" > "$gd/$WT_PREFIX-tested"
    echo "tests: passed"
  else
    rm -f "$gd/$WT_PREFIX-tested"
    echo "tests: failed"
    return 1
  fi
}

cmd_push_main() {
  local wt=${1:?usage: fm-fork-sync.sh push-main <worktree>} gd head outcome
  gd=$(wt_gitdir "$wt")
  require_committed_merge "$wt" "$gd"
  head=$(git -C "$wt" rev-parse HEAD)
  outcome=$(cat "$gd/$WT_PREFIX-outcome" 2>/dev/null || true)
  [ "$outcome" = "clean $head" ] ||
    die "only an unmodified clean merge may be pushed to $BRANCH; a resolved conflict ships as a reviewed PR (push-branch)"
  [ "$(cat "$gd/$WT_PREFIX-tested" 2>/dev/null || true)" = "$head" ] ||
    die "the test suite has not passed on $head; run: fm-fork-sync.sh test $wt"
  git -C "$wt" push -q origin "$head:refs/heads/$BRANCH" ||
    die "origin/$BRANCH moved or the push was refused; nothing was forced, rerun the sync"
  echo "pushed-main: $head"
}

cmd_push_branch() {
  local wt=${1:?usage: fm-fork-sync.sh push-branch <worktree>} gd br
  gd=$(wt_gitdir "$wt")
  require_committed_merge "$wt" "$gd"
  br=$(sync_branch)
  if ! git -C "$wt" push -q origin "HEAD:refs/heads/$br"; then
    [ -z "$(git -C "$wt" ls-remote --heads origin "refs/heads/$br")" ] ||
      die "$br is already on origin from an earlier sync and this merge does not fast-forward it; nothing was forced; ask the captain before deleting it (git push origin --delete $br), then rerun push-branch"
    die "push of $br was refused; nothing was forced"
  fi
  echo "pushed-branch: $br"
}

cmd_cleanup() {
  local wt=${1:?usage: fm-fork-sync.sh cleanup <worktree> [--abandon]} gd
  gd=$(wt_gitdir "$wt")
  if [ "${2:-}" != --abandon ] && { [ -e "$gd/MERGE_HEAD" ] || [ -n "$(git -C "$wt" status --porcelain)" ]; }; then
    die "the worktree holds an unfinished merge or changes; pass --abandon to discard it"
  fi
  remove_wt "$wt"
  echo "cleaned: $wt"
}

case "${1:-}" in
  check) cmd_check ;;
  merge) cmd_merge ;;
  commit) shift; cmd_commit "$@" ;;
  test) shift; cmd_test "$@" ;;
  push-main) shift; cmd_push_main "$@" ;;
  push-branch) shift; cmd_push_branch "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  -h|--help|help) sed -n '2,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//' ;;
  *) echo "usage: fm-fork-sync.sh check|merge|commit|test|push-main|push-branch|cleanup [args] (see --help)" >&2; exit 2 ;;
esac
