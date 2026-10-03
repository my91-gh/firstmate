#!/usr/bin/env bash
# Tests for bin/fm-fork-sync.sh: bringing upstream's main into a fork's main.
#
# The guarantees under test:
#   - Wrong remotes are refused: origin that is the upstream itself, an
#     `upstream` remote pointing elsewhere, and an origin GitHub does not report
#     as a fork of upstream. A missing `upstream` remote is added.
#   - A fork that already contains upstream is reported `current` and nothing
#     is merged or created.
#   - A clean merge happens in a disposable worktree (never the primary
#     checkout), carries the established merge-commit message, and reaches
#     origin main only as a fast-forward after the suite passed on that exact
#     HEAD; a failing suite blocks the push.
#   - A conflict leaves the worktree in the merge state, lists every conflicted
#     file, and a resolved conflict can never be pushed to main - only to the
#     deterministic PR branch, with main untouched.
#   - A dirty primary checkout, a moved origin main, and a directory that is not
#     one of the script's worktrees are all refused without forcing anything.
#   - Uncommitted edits in the merge worktree can never be stamped as tested or
#     pushed, whether they exist before the suite or appear while it runs.
#   - A stale PR branch from an earlier sync of the same upstream tip is
#     reported, never overwritten, and the push succeeds once it is deleted.
#   - A pushed PR branch is reported `up-to-date` while it still contains the
#     fork's main and the upstream tip, and `outdated` once the fork moves.
#   - A merge that fails without conflicts leaves no worktree behind.
#   - `commit` finishes a resolved merge through the git hooks; a refusing hook
#     is surfaced verbatim, creates no commit, and leaves the merge state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-fork-sync.sh"
MSG="Merge upstream kunchenguid/main into fork main"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-fork-sync-tests)

# Fresh world: bare upstream, a bare fork (origin) cloned from it, and the
# primary checkout cloned from the fork. The fake gh reports the fork's parent
# from $w/gh-parent; `upstream` is added by the script unless $2 is given.
new_world() {
  local name=$1 w seed
  w="$TMP_ROOT/$name"
  mkdir -p "$w/fakebin" "$w/tmp"
  git init -q --bare -b main "$w/upstream.git"
  git init -q --bare -b main "$w/origin.git"
  seed="$w/seed"
  git init -q -b main "$seed"
  printf 'base\n' > "$seed/shared.txt"
  printf 'u0\n' > "$seed/a.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -qm base
  git -C "$seed" push -q "$w/upstream.git" main
  git -C "$seed" push -q "$w/origin.git" main
  git clone -q "$w/origin.git" "$w/primary"
  printf 'kunchenguid/firstmate\n' > "$w/gh-parent"
  cat > "$w/fakebin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_GH_PARENT_FILE"
SH
  chmod +x "$w/fakebin/gh"
  printf '%s\n' "$w"
}

# Commit one file to a bare repo from a throwaway clone. Args: world bare file content.
commit_to() {
  local w=$1 bare=$2 file=$3 content=$4 c
  c="$w/clone-$bare"
  rm -rf "$c"
  git clone -q "$w/$bare.git" "$c"
  printf '%s\n' "$content" > "$c/$file"
  git -C "$c" add -A
  git -C "$c" commit -qm "$bare: $file"
  git -C "$c" push -q origin main
  rm -rf "$c"
}

# Run the helper against the world; stdout and stderr are both captured.
sync_run() {
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" TMPDIR="$w/tmp" FAKE_GH_PARENT_FILE="$w/gh-parent" \
    FM_ROOT_OVERRIDE="$w/primary" FM_FORK_UPSTREAM_URL="${FORK_URL:-$w/upstream.git}" \
    "$SYNC" "$@" 2>&1
}

wt_of() { printf '%s\n' "$1" | sed -n 's/^worktree: //p'; }

test_wrong_remotes_refused() {
  local w out
  w=$(new_world wrong)
  git -C "$w/primary" remote add upstream "$w/origin.git"
  out=$(sync_run "$w" check) && fail "upstream remote pointing elsewhere was accepted"
  assert_contains "$out" "expected $w/upstream.git" "names the expected upstream"

  git -C "$w/primary" remote set-url upstream "$w/upstream.git"
  printf 'someone/else\n' > "$w/gh-parent"
  out=$(sync_run "$w" check) && fail "origin that is a fork of another repo was accepted"
  assert_contains "$out" "is not a fork of kunchenguid/firstmate" "refuses a non-fork origin"

  printf '\n' > "$w/gh-parent"
  out=$(sync_run "$w" check) && fail "origin that is no fork at all was accepted"
  assert_contains "$out" "no parent" "reports the missing parent"

  printf 'kunchenguid/firstmate\n' > "$w/gh-parent"
  out=$(FORK_URL="$w/origin.git" sync_run "$w" check) && fail "origin that is the upstream itself was accepted"
  assert_contains "$out" "the upstream repo itself" "refuses origin == upstream"
  pass "T1 wrong remotes are refused"
}

test_missing_upstream_added_and_current() {
  local w out
  w=$(new_world current)
  git -C "$w/primary" remote get-url upstream >/dev/null 2>&1 && fail "fixture already has an upstream remote"
  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "upstream-remote: added" "the missing upstream remote is added"
  assert_contains "$out" "fork-of: kunchenguid/firstmate" "fork relationship verified"
  assert_contains "$out" "state: current" "a fork containing upstream is current"
  out=$(sync_run "$w" merge) || fail "merge on a current fork failed: $out"
  assert_contains "$out" "merge: not-needed" "nothing to merge"
  assert_not_contains "$out" "worktree:" "no worktree is created when current"
  [ -z "$(ls -A "$w/tmp")" ] || fail "a temp directory was left behind"

  # A fork AHEAD of upstream (its own commits on top) is still current.
  commit_to "$w" origin own.txt own
  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "state: current" "fork-only commits do not make it behind"
  pass "T2 missing upstream remote added; already-current fork is left alone"
}

test_clean_merge_flow() {
  local w out wt old_origin head primary_head
  w=$(new_world clean)
  commit_to "$w" upstream b.txt up-b
  commit_to "$w" origin c.txt fork-c
  old_origin=$(git -C "$w/origin.git" rev-parse main)
  primary_head=$(git -C "$w/primary" rev-parse HEAD)

  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "state: behind" "upstream has new commits"
  assert_contains "$out" "upstream-new-commits: 1" "counts the arriving commits"
  assert_contains "$out" "upstream-commit: " "lists the arriving commits"
  assert_contains "$out" "branch-on-origin: no" "no conflict branch yet"

  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  assert_contains "$out" "merge: clean" "disjoint changes merge cleanly"
  wt=$(wt_of "$out")
  [ -d "$wt" ] || fail "no worktree at '$wt'"
  assert_not_equals "$w/primary" "$wt" "the merge runs outside the primary checkout"
  [ "$(git -C "$w/primary" rev-parse HEAD)" = "$primary_head" ] || fail "primary checkout HEAD moved"
  [ ! -e "$w/primary/b.txt" ] || fail "primary checkout received the merge"
  assert_equals "$MSG" "$(git -C "$wt" log -1 --format=%s)" "established merge-commit message"
  assert_equals 3 "$(git -C "$wt" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "a two-parent merge commit"

  if out=$(sync_run "$w" push-main "$wt"); then fail "push-main ran before the suite"; fi
  assert_contains "$out" "has not passed" "an untested merge is refused"
  if out=$(FM_FORK_SYNC_TEST_CMD=false sync_run "$w" test "$wt"); then fail "a failing suite passed"; fi
  assert_contains "$out" "tests: failed" "failing suite is reported"
  if out=$(sync_run "$w" push-main "$wt"); then fail "push-main ran after a failing suite"; fi
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved despite failing tests"

  out=$(FM_FORK_SYNC_TEST_CMD='test -f b.txt && test -f c.txt' sync_run "$w" test "$wt") || fail "suite did not run in the merge result: $out"
  assert_contains "$out" "tests: passed" "passing suite is reported"
  head=$(git -C "$wt" rev-parse HEAD)
  out=$(sync_run "$w" push-main "$wt") || fail "push-main failed: $out"
  assert_contains "$out" "pushed-main: $head" "reports the pushed commit"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$head" ] || fail "origin main is not the merge commit"
  git -C "$w/origin.git" merge-base --is-ancestor "$old_origin" "$head" || fail "push was not a fast-forward"

  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "state: current" "fork is current after the push"
  out=$(sync_run "$w" cleanup "$wt") || fail "cleanup failed: $out"
  [ ! -e "$wt" ] || fail "worktree survived cleanup"
  [ -z "$(ls -A "$w/tmp")" ] || fail "a temp directory was left behind"
  pass "T3 clean merge: isolated, tested, fast-forwarded to origin main"
}

test_conflict_flow() {
  local w out wt old_origin br
  w=$(new_world conflict)
  commit_to "$w" upstream shared.txt upstream-side
  commit_to "$w" upstream d.txt up-d
  commit_to "$w" origin shared.txt fork-side
  commit_to "$w" origin a.txt fork-a
  old_origin=$(git -C "$w/origin.git" rev-parse main)

  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  assert_contains "$out" "merge: conflict" "overlapping edits conflict"
  assert_contains "$out" "conflict: shared.txt" "lists the conflicted file"
  assert_not_contains "$out" "conflict: a.txt" "does not list unrelated files"
  wt=$(wt_of "$out")
  if out=$(sync_run "$w" cleanup "$wt"); then fail "cleanup discarded an unfinished merge"; fi
  assert_contains "$out" "--abandon" "cleanup names the explicit flag"
  if out=$(sync_run "$w" test "$wt"); then fail "test ran on an unresolved merge"; fi
  assert_contains "$out" "not committed" "unresolved merge is refused by test"

  printf 'resolved\n' > "$wt/shared.txt"
  git -C "$wt" add shared.txt
  git -C "$wt" commit -q --no-edit
  FM_FORK_SYNC_TEST_CMD=true sync_run "$w" test "$wt" >/dev/null || fail "suite stamp failed"
  if out=$(sync_run "$w" push-main "$wt"); then fail "a resolved conflict reached main"; fi
  assert_contains "$out" "reviewed PR" "resolved conflict is steered to the PR path"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved"

  out=$(sync_run "$w" push-branch "$wt") || fail "push-branch failed: $out"
  br=$(printf '%s\n' "$out" | sed -n 's/^pushed-branch: //p')
  case "$br" in sync/upstream-*) ;; *) fail "unexpected branch name '$br'" ;; esac
  git -C "$w/origin.git" merge-base --is-ancestor "$(git -C "$w/upstream.git" rev-parse main)" "$br" ||
    fail "branch lacks upstream"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved by push-branch"
  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "state: behind" "main is still behind until the PR merges"
  assert_contains "$out" "branch: $br" "check reports the same branch name"
  assert_contains "$out" "branch-on-origin: yes" "check sees the waiting conflict branch"
  sync_run "$w" cleanup "$wt" >/dev/null || fail "cleanup after resolution failed"

  # An abandoned conflict needs the explicit flag.
  out=$(sync_run "$w" merge) || fail "second merge failed: $out"
  wt=$(wt_of "$out")
  sync_run "$w" cleanup "$wt" --abandon >/dev/null || fail "--abandon cleanup failed"
  [ ! -e "$wt" ] || fail "abandoned worktree survived"
  pass "T4 conflict: listed, resolution cannot reach main, ships as a PR branch"
}

test_refusals() {
  local w out wt
  w=$(new_world refuse)
  commit_to "$w" upstream b.txt up-b

  printf 'dirty\n' >> "$w/primary/a.txt"
  if out=$(sync_run "$w" merge); then fail "merge ran with a dirty primary checkout"; fi
  assert_contains "$out" "uncommitted changes" "dirty primary checkout refused"
  [ -z "$(ls -A "$w/tmp")" ] || fail "a worktree was created despite the dirty checkout"
  git -C "$w/primary" checkout -q -- a.txt

  if out=$(sync_run "$w" push-main "$w/primary"); then fail "push-main accepted the primary checkout"; fi
  assert_contains "$out" "not a fm-fork-sync worktree" "only its own worktrees are accepted"

  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  wt=$(wt_of "$out")
  FM_FORK_SYNC_TEST_CMD=true sync_run "$w" test "$wt" >/dev/null || fail "suite stamp failed"
  commit_to "$w" origin c.txt fork-moved
  if out=$(sync_run "$w" push-main "$wt"); then fail "push-main overwrote a moved origin main"; fi
  assert_equals fork-moved "$(git -C "$w/origin.git" show main:c.txt)" "the moved origin main is intact"
  sync_run "$w" cleanup "$wt" >/dev/null || fail "cleanup failed"
  pass "T5 dirty checkout, foreign directory, and a moved origin main are refused"
}

test_uncommitted_worktree_never_stamped() {
  local w out wt old_origin
  w=$(new_world dirtywt)
  commit_to "$w" upstream b.txt up-b
  old_origin=$(git -C "$w/origin.git" rev-parse main)
  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  wt=$(wt_of "$out")

  printf 'u0\n' > "$wt/a.txt.fixed"
  printf 'edited\n' > "$wt/a.txt"
  if out=$(FM_FORK_SYNC_TEST_CMD='grep -q edited a.txt' sync_run "$w" test "$wt"); then
    fail "test stamped a worktree with uncommitted edits"
  fi
  assert_contains "$out" "uncommitted changes" "dirty worktree refused before the suite"
  assert_not_contains "$out" "tests: passed" "the suite did not run on uncommitted content"
  if out=$(sync_run "$w" push-main "$wt"); then fail "push-main pushed with uncommitted edits"; fi
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved"

  git -C "$wt" checkout -q -- a.txt
  rm "$wt/a.txt.fixed"
  FM_FORK_SYNC_TEST_CMD=true sync_run "$w" test "$wt" >/dev/null || fail "clean worktree was not stamped"
  printf 'edited\n' > "$wt/a.txt"
  if out=$(sync_run "$w" push-main "$wt"); then fail "push-main pushed edits made after the stamp"; fi
  assert_contains "$out" "uncommitted changes" "edits after the stamp are refused"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved"
  git -C "$wt" checkout -q -- a.txt

  if out=$(FM_FORK_SYNC_TEST_CMD='printf "x\n" > a.txt' sync_run "$w" test "$wt"); then
    fail "a suite that dirtied the worktree was stamped"
  fi
  assert_contains "$out" "uncommitted changes" "edits made during the suite are refused"
  git -C "$wt" checkout -q -- a.txt
  if out=$(sync_run "$w" push-main "$wt"); then fail "push-main used a stale stamp"; fi
  assert_contains "$out" "has not passed" "a refused test run clears the old stamp"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved"
  sync_run "$w" cleanup "$wt" --abandon >/dev/null || fail "cleanup failed"
  pass "T6 uncommitted worktree edits are never stamped or pushed"
}

test_stale_pr_branch() {
  local w out wt br stale
  w=$(new_world stale)
  commit_to "$w" upstream shared.txt upstream-side
  commit_to "$w" origin shared.txt fork-side

  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  wt=$(wt_of "$out")
  printf 'first\n' > "$wt/shared.txt"
  git -C "$wt" commit -qam resolved
  out=$(sync_run "$w" push-branch "$wt") || fail "push-branch failed: $out"
  br=$(printf '%s\n' "$out" | sed -n 's/^pushed-branch: //p')
  stale=$(git -C "$w/origin.git" rev-parse "$br")
  sync_run "$w" cleanup "$wt" >/dev/null || fail "cleanup failed"

  out=$(sync_run "$w" merge) || fail "second merge failed: $out"
  wt=$(wt_of "$out")
  printf 'second\n' > "$wt/shared.txt"
  git -C "$wt" commit -qam resolved-again
  if out=$(sync_run "$w" push-branch "$wt"); then fail "push-branch overwrote a stale branch"; fi
  assert_contains "$out" "already on origin" "the stale branch is named as the cause"
  assert_contains "$out" "git push origin --delete $br" "the refusal says how to proceed"
  assert_equals "$stale" "$(git -C "$w/origin.git" rev-parse "$br")" "the stale branch is untouched"

  git -C "$w/primary" push -q origin --delete "$br"
  out=$(sync_run "$w" push-branch "$wt") || fail "push-branch after deleting the stale branch failed: $out"
  assert_equals "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$w/origin.git" rev-parse "$br")" "the new resolution is on origin"
  sync_run "$w" cleanup "$wt" >/dev/null || fail "cleanup failed"
  pass "T7 a stale PR branch is reported, never forced, and replaced once deleted"
}

test_pushed_branch_state() {
  local w out wt br sha
  w=$(new_world branchstate)
  commit_to "$w" upstream shared.txt upstream-side
  commit_to "$w" origin shared.txt fork-side

  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  wt=$(wt_of "$out")
  printf 'resolved\n' > "$wt/shared.txt"
  git -C "$wt" commit -qam resolved
  out=$(sync_run "$w" push-branch "$wt") || fail "push-branch failed: $out"
  br=$(printf '%s\n' "$out" | sed -n 's/^pushed-branch: //p')
  sha=$(git -C "$w/origin.git" rev-parse "$br")
  sync_run "$w" cleanup "$wt" >/dev/null || fail "cleanup failed"

  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "branch-on-origin: yes" "the pushed branch is seen"
  assert_contains "$out" "branch-state: up-to-date" "a branch on the current main and upstream tip is reusable"

  commit_to "$w" origin c.txt fork-moved
  out=$(sync_run "$w" check) || fail "check failed: $out"
  assert_contains "$out" "branch: $br" "the branch name still follows the upstream tip"
  assert_contains "$out" "branch-state: outdated" "a branch behind the moved main is outdated"
  assert_equals "$sha" "$(git -C "$w/origin.git" rev-parse "$br")" "check never touches the branch"
  pass "T8 a pushed PR branch is reported up-to-date or outdated against the fork's main"
}

test_failed_merge_leaves_no_worktree() {
  local w out old_origin
  w=$(new_world mergefail)
  commit_to "$w" upstream b.txt up-b
  old_origin=$(git -C "$w/origin.git" rev-parse main)
  printf '#!/bin/sh\necho hook-refused >&2\nexit 1\n' > "$w/primary/.git/hooks/pre-merge-commit"
  chmod +x "$w/primary/.git/hooks/pre-merge-commit"

  if out=$(sync_run "$w" merge); then fail "a merge refused by a hook succeeded"; fi
  assert_contains "$out" "merge failed without conflicts" "the failure is reported"
  assert_contains "$out" "hook-refused" "git's own reason is shown"
  [ -z "$(ls -A "$w/tmp")" ] || fail "the failed merge left a worktree behind"
  assert_equals 1 "$(git -C "$w/primary" worktree list --porcelain | grep -c '^worktree ')" "no worktree stays registered"
  [ "$(git -C "$w/origin.git" rev-parse main)" = "$old_origin" ] || fail "origin main moved"
  pass "T9 a merge that fails without conflicts removes its worktree"
}

test_commit_respects_hooks() {
  local w out wt before
  w=$(new_world hooks)
  commit_to "$w" upstream shared.txt upstream-side
  commit_to "$w" origin shared.txt fork-side
  mkdir -p "$w/hooks"
  printf '#!/bin/sh\necho "secret-check: GEMINI_API_KEY found" >&2\nexit 1\n' > "$w/hooks/pre-commit"
  chmod +x "$w/hooks/pre-commit"
  git -C "$w/primary" config core.hooksPath "$w/hooks"

  out=$(sync_run "$w" merge) || fail "merge failed: $out"
  wt=$(wt_of "$out")
  before=$(git -C "$wt" rev-parse HEAD)
  if out=$(sync_run "$w" commit "$wt"); then fail "commit ran with unresolved conflicts"; fi
  assert_contains "$out" "unresolved conflicts" "unresolved conflicts are refused"

  printf 'resolved\n' > "$wt/shared.txt"
  git -C "$wt" add shared.txt
  if out=$(sync_run "$w" commit "$wt"); then fail "commit succeeded past a refusing hook"; fi
  assert_contains "$out" "secret-check: GEMINI_API_KEY found" "the hook's exact message is shown"
  assert_contains "$out" "left in the merge state" "the refusal says the worktree is kept"
  assert_equals "$before" "$(git -C "$wt" rev-parse HEAD)" "no commit was created"
  [ -e "$(git -C "$wt" rev-parse --absolute-git-dir)/MERGE_HEAD" ] || fail "the merge state was lost"
  assert_equals "M  shared.txt" "$(git -C "$wt" status --porcelain)" "the staged resolution is untouched"

  printf '#!/bin/sh\nexit 0\n' > "$w/hooks/pre-commit"
  out=$(sync_run "$w" commit "$wt") || fail "commit with a passing hook failed: $out"
  assert_contains "$out" "committed: $(git -C "$wt" rev-parse HEAD)" "reports the merge commit"
  assert_equals 3 "$(git -C "$wt" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "a two-parent merge commit"
  assert_equals "$MSG" "$(git -C "$wt" log -1 --format=%s)" "the merge message is kept"
  if out=$(sync_run "$w" commit "$wt"); then fail "commit ran with no merge in progress"; fi
  assert_contains "$out" "no merge in progress" "a finished merge is refused"
  sync_run "$w" cleanup "$wt" >/dev/null || fail "cleanup failed"
  pass "T10 commit goes through the hooks and stops on a refusal with the hook's message"
}

test_wrong_remotes_refused
test_missing_upstream_added_and_current
test_clean_merge_flow
test_conflict_flow
test_refusals
test_uncommitted_worktree_never_stamped
test_stale_pr_branch
test_pushed_branch_state
test_failed_merge_leaves_no_worktree
test_commit_respects_hooks

echo "# all fm-fork-sync tests passed"
