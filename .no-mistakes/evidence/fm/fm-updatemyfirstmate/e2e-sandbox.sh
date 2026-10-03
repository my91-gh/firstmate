#!/usr/bin/env bash
# Sandbox end-to-end run of the /updatemyfirstmate mechanics:
# fork sync (bin/fm-fork-sync.sh) then local update (bin/fm-update.sh).
set -u
REPO=$1
W=$(mktemp -d); export TMPDIR=$W/tmp; mkdir -p $TMPDIR $W/fakebin
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
printf '#!/usr/bin/env bash\necho kunchenguid/firstmate\n' > $W/fakebin/gh; chmod +x $W/fakebin/gh
export PATH=$W/fakebin:$PATH FM_FORK_UPSTREAM_URL=$W/upstream.git FM_FORK_SYNC_TEST_CMD='echo "(suite ran on $(git rev-parse --short HEAD))"'
git init -q --bare -b main $W/upstream.git; git init -q --bare -b main $W/origin.git
git init -q -b main $W/seed; cd $W/seed
cp -R "$REPO/bin" . ; echo base > shared.txt; git add -A; git commit -qm base
git push -q $W/upstream.git main; git push -q $W/origin.git main
git clone -q $W/origin.git $W/up; git clone -q $W/origin.git $W/forkdev; git clone -q $W/origin.git $W/mac
cd $W/up; git remote set-url origin $W/upstream.git; echo feature > upstream-feature.txt; git add -A; git commit -qm "upstream: add feature"; git push -q origin main
cd $W/forkdev; echo mine > fork-only.txt; git add -A; git commit -qm "fork: captain's own change"; git push -q origin main
run() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
echo "=== CLEAN PATH ==="
cd $W/mac; git pull -q
S="env FM_ROOT_OVERRIDE=$W/mac $REPO/bin/fm-fork-sync.sh"
run $S check
out=$($S merge); echo; echo "\$ fm-fork-sync.sh merge"; echo "$out"
WT=$(echo "$out" | sed -n 's/^worktree: //p')
run $S push-main $WT
run $S test $WT
run $S push-main $WT
run $S cleanup $WT
echo; echo "\$ git -C origin.git log --oneline -3 main"; git -C $W/origin.git log --oneline -3 main
echo; echo "--- local copy before fm-update.sh: $(git -C $W/mac log --oneline -1)"
run env FM_ROOT_OVERRIDE=$W/mac FM_HOME=$W/mac $W/mac/bin/fm-update.sh
echo "--- local copy after: $(git -C $W/mac log --oneline -1); files: $(cd $W/mac; ls *.txt | tr '\n' ' ')"
run $S check
echo; echo "=== CONFLICT PATH ==="
cd $W/up; git pull -q; echo upstream-edit > shared.txt; git commit -qam "upstream: edit shared"; git push -q origin main
cd $W/forkdev; git pull -q; echo fork-edit > shared.txt; git commit -qam "fork: edit shared"; git push -q origin main
cd $W/mac
run $S check
out=$($S merge); echo; echo "\$ fm-fork-sync.sh merge"; echo "$out"
WT=$(echo "$out" | sed -n 's/^worktree: //p')
printf 'fork-edit\nupstream-edit\n' > $WT/shared.txt; git -C $WT add shared.txt; git -C $WT commit -q --no-edit
run $S test $WT
run $S push-main $WT
run $S push-branch $WT
echo "--- origin main unchanged: $(git -C $W/origin.git log --oneline -1 main)"
echo "--- origin branches: $(git -C $W/origin.git branch --format='%(refname:short)' | tr '\n' ' ')"
run $S cleanup $WT
rm -rf $W
