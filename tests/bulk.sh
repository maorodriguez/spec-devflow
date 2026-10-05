#!/usr/bin/env bash
# tests/bulk.sh — regression tests for scripts/bulk.sh (bulk apply helper).
#
#   tests/bulk.sh
#
# Builds a throwaway repo with a bare origin and several OpenSpec changes committed on main, then checks
# list (gate on and off, a change only on a branch, finished, archived, invalid and proposal-less
# directories, an integration ref, a ref without changes), new (single, duplicate and ineligible changes
# refused, existing branches and worktrees under every naming refused, rollback when a creation fails, the
# issue syntax, valid JSON for odd paths and refs) and prompt (every obligation present, refusals), and that
# the script contains no push/merge/archive/PR commands. Real git, no OpenSpec CLI; the JSON checks need
# python3 or jq and are skipped without them. Exit status 1 on any failure. Needs bash and git.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BULK="$ROOT/scripts/bulk.sh"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT

printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 DEVFLOW_WORKTREE_ROOT="$tmp/wts"
unset DEVFLOW_PROPOSAL_GATE DEVFLOW_DEFAULT_BRANCH DEVFLOW_RUNTIME DEVFLOW_TEST_CMD CLAUDECODE OPENCODE OPENCODE_CLIENT

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
cd "$tmp/repo" || exit 1
git checkout -q -b main
echo base > README.md; git add -A; git commit -q -m init; git push -q -u origin main
base_sha="$(git rev-parse HEAD)"
mk() { # $1 = change, rest = lines of tasks.md
  local c="$1"; shift
  mkdir -p "openspec/changes/$c"; echo "# p" > "openspec/changes/$c/proposal.md"; printf '%s\n' "$@" > "openspec/changes/$c/tasks.md"
}
mk alpha '# Tasks' '- [ ] 1.1 first alpha task' '- [ ] 1.2 second alpha task'
mk beta '# Tasks' '- [x] 1.1 done beta task' '- [ ] 2.1 pending beta task'
mk gamma '# Tasks' '- [x] 1.1 done gamma task'
mk Bad_Name '- [ ] 1.1 invalid directory name'
mkdir -p openspec/changes/nopro; echo '- [ ] 1.1 task without proposal' > openspec/changes/nopro/tasks.md
mkdir -p openspec/changes/archive/2026-01-01-old; echo "# p" > openspec/changes/archive/2026-01-01-old/proposal.md
git add -A; git commit -q -m "docs: propose alpha beta gamma"; git push -q origin main
git checkout -q -b integ; mk epsilon '- [ ] 1.1 epsilon task'; git add -A; git commit -q -m "docs: propose epsilon"
git checkout -q -b feat/delta-proposal main; mk delta '- [ ] 1.1 delta task'; git add -A; git commit -q -m "docs: propose delta"
git checkout -q main

fail=0
run() { # $1 = off|main (proposal gate), rest = bulk.sh args; stdout in $tmp/out, stderr in $tmp/err
  local gate="$1"; shift
  ( cd "$tmp/repo" && DEVFLOW_PROPOSAL_GATE="$gate" bash "$BULK" "$@" ) >"$tmp/out" 2>"$tmp/err"
}
expect() { # $1 = expected exit code, $2 = label, rest = command
  local want="$1" label="$2" r; shift 2
  "$@"; r=$?
  if [ "$r" = "$want" ]; then echo "  ok    $label"; else echo "  FAIL  $label (expected exit $want, got $r)"; sed 's/^/        /' "$tmp/out" "$tmp/err"; fail=1; fi
}
saw() { # $1 = 0 (must appear) | 1 (must not), $2 = label, $3 = fixed text, $4 = file (default out)
  local f="${4:-$tmp/out}" r
  if grep -qF -- "$3" "$f"; then r=0; else r=1; fi
  if [ "$r" = "$1" ]; then echo "  ok    $2"; else echo "  FAIL  $2 (text '$3' $([ "$1" = 0 ] && echo missing || echo present))"; sed 's/^/        /' "$f"; fail=1; fi
}
check() { # $1 = label, rest = test command that must succeed
  local label="$1"; shift
  if "$@"; then echo "  ok    $label"; else echo "  FAIL  $label"; fail=1; fi
}
json_valid() { # $1 = file; 0 valid, 1 invalid, 2 no parser available
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(sys.stdin)' < "$1" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then jq -e . < "$1" >/dev/null 2>&1
  else return 2; fi
}
valid_json() { # $1 = label, $2 = file
  json_valid "$2"; case $? in 0) echo "  ok    $1";; 2) echo "  skip  $1 (no python3 or jq)";; *) echo "  FAIL  $1"; sed 's/^/        /' "$2"; fail=1;; esac
}
nothing_created() { [ -z "$(ls "$tmp/wts" 2>/dev/null)" ] && [ "$(git -C "$tmp/repo" worktree list | wc -l | tr -d ' ')" = 1 ]; }

echo "== list, gate off"
expect 0 "list succeeds" run off list --no-fetch
valid_json "the output is valid JSON" "$tmp/out"
saw 0 "alpha is eligible with 2 pending" '"change":"alpha","ref":"origin/main","pending":2,"done":0,"eligible":true,"needs_confirmation":true'
saw 0 "beta counts done and pending" '"change":"beta","ref":"origin/main","pending":1,"done":1,"eligible":true'
saw 0 "gamma is not eligible: nothing pending" '"change":"gamma","ref":"origin/main","pending":0,"done":1,"eligible":false,"needs_confirmation":false,"reason":"no pending tasks"'
saw 0 "a directory without proposal.md says so" '"change":"nopro","ref":"origin/main","pending":0,"done":0,"eligible":false,"needs_confirmation":false,"reason":"no proposal.md on origin/main"'
saw 1 "an invalid directory name is not listed" '"change":"Bad_Name"'
saw 0 "...and is skipped with a warning" "skipping openspec/changes/Bad_Name" "$tmp/err"
saw 1 "the archive folder is not listed as a change" '"change":"archive"'
saw 1 "a change only on a branch is not listed" '"change":"delta"'
expect 0 "a named change missing from the ref is reported" run off list delta --no-fetch
saw 0 "...as not eligible with the reason" '"eligible":false,"needs_confirmation":false,"reason":"not on origin/main"'
expect 0 "an integration ref lists its own changes" run off list --ref integ --no-fetch
saw 0 "...including epsilon" '"change":"epsilon","ref":"integ"'
expect 0 "a ref without changes lists nothing" run off list --ref "$base_sha" --no-fetch
check "...an exactly empty array" test "$(cat "$tmp/out")" = "$(printf '[\n]')"
saw 0 "...and warns that it reads committed state" "committed state" "$tmp/err"
git branch 'q"uote' main
expect 0 "a ref with a double quote is accepted" run off list --ref 'q"uote' --no-fetch
valid_json "...and the output is still valid JSON" "$tmp/out"
saw 0 "...with the quote escaped" '"ref":"q\"uote"'

echo "== list, gate on"
expect 0 "list succeeds" run main list --no-fetch
saw 0 "alpha is eligible without needing confirmation" '"change":"alpha","ref":"origin/main","pending":2,"done":0,"eligible":true,"needs_confirmation":false'
expect 0 "a proposal that never reached main is explained" run main list delta --no-fetch
saw 0 "...as not reached" 'proposal has not reached origin/main'
expect 1 "--ref other than the default branch is rejected" run main list --ref integ --no-fetch
saw 0 "...saying why" "must be the default branch" "$tmp/err"

echo "== new: refusals create nothing"
expect 1 "a single change is refused" run off new alpha --no-fetch
saw 0 "...pointing to the normal flow" "at least two changes" "$tmp/err"
expect 1 "the same change twice is refused" run off new alpha alpha --no-fetch
saw 0 "...naming it" "'alpha' is given more than once" "$tmp/err"
expect 1 "a malformed issue is refused" run off new alpha:x beta --no-fetch
saw 0 "...saying why" "invalid issue number" "$tmp/err"
expect 1 "an ineligible change is refused" run off new alpha gamma --no-fetch
saw 0 "...naming it and the reason" "gamma(no pending tasks)" "$tmp/err"
expect 1 "with the gate on a proposal not on main is refused" run main new alpha delta --no-fetch
check "nothing was created by those refusals" nothing_created

git branch feat/42-alpha main
expect 1 "an issue-numbered branch of the normal flow counts as existing" run off new alpha beta --no-fetch
saw 0 "...naming the change" "alpha(branch feat/42-alpha" "$tmp/err"
check "nothing was created" nothing_created
git branch -q -D feat/42-alpha
git branch fix/beta main
expect 1 "a branch of another type counts as existing" run off new alpha beta --no-fetch
saw 0 "...naming the change" "beta(branch fix/beta" "$tmp/err"
git branch -q -D fix/beta
git push -q origin main:refs/heads/feat/9-alpha; git fetch -q origin
expect 1 "a branch only on origin counts as existing" run off new alpha beta --no-fetch
saw 0 "...naming the change" "alpha(branch origin/feat/9-alpha" "$tmp/err"
git push -q origin --delete feat/9-alpha; git fetch -q --prune origin
git worktree add -q -b chore/7-beta "$tmp/elsewhere" origin/main
expect 1 "a worktree outside the configured root counts as existing" run off new alpha beta --no-fetch
saw 0 "...naming the change" "beta(" "$tmp/err"
saw 0 "...and the worktree" "worktree on a matching branch" "$tmp/err"
git worktree remove "$tmp/elsewhere"; git branch -q -D chore/7-beta
check "nothing was created" nothing_created

echo "== new: path and issue checks"
mkdir -p "$tmp/wts/feat-5-beta"
expect 1 "a directory at the issue-numbered worktree path is refused up front" run off new alpha beta:5 --no-fetch
saw 0 "...as an up-front refusal naming the change" "already has a worktree or branch: beta(path" "$tmp/err"
saw 0 "...and the path" "feat-5-beta" "$tmp/err"
saw 1 "...not as a creation that failed and was rolled back" "creating the worktree of" "$tmp/err"
check "nothing else was created" test -z "$(ls "$tmp/wts" | grep -v '^feat-5-beta$')"
rmdir "$tmp/wts/feat-5-beta"; rmdir "$tmp/wts" 2>/dev/null
expect 1 "an issue with a line break is refused by new" run off new "alpha:42"$'\n'"x" beta --no-fetch
saw 0 "...saying why" "invalid issue number" "$tmp/err"
check "...creating nothing" nothing_created

echo "== new: rollback when a creation fails"
# DEVFLOW_WT_SH injects the failure on every ref backend: the wrapper runs the real wt.sh and fails the 2nd `new`
# (FAIL_MODE=before: without running it; after: after it created the worktree; dirty: after it, leaving a file;
# branchonly: only the branch was created).
cat > "$tmp/wt-fail.sh" <<'WRAP'
#!/usr/bin/env bash
n="$(cat "$COUNT" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$COUNT"
if [ "$1" = new ] && [ "$n" -ge 2 ]; then
  [ "$FAIL_MODE" != before ] || { echo "injected failure" >&2; exit 1; }
  [ "$FAIL_MODE" != branchonly ] || { git branch "$2/$3" "$BASE_REF"; echo "injected failure after creating the branch" >&2; exit 1; }
  out="$(bash "$REAL_WT" "$@")" || exit 1
  [ "$FAIL_MODE" != dirty ] || touch "$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')/dirty"
  echo "injected failure after creating" >&2; exit 1
fi
exec bash "$REAL_WT" "$@"
WRAP
failing() { # $1 = FAIL_MODE, rest = bulk.sh args (gate off)
  local mode="$1"; shift; rm -f "$tmp/count"
  ( export DEVFLOW_WT_SH="$tmp/wt-fail.sh" COUNT="$tmp/count" FAIL_MODE="$mode" REAL_WT="$ROOT/scripts/wt.sh" BASE_REF=origin/main; run off "$@" )
}
expect 1 "a failure on the second change fails the run" failing before new alpha beta --no-fetch
check "...printing no JSON" test ! -s "$tmp/out"
saw 0 "...saying everything was removed" "everything created before it was removed" "$tmp/err"
check "...removing the first worktree" test ! -e "$tmp/wts/feat-alpha"
check "...and its branch" test -z "$(git branch --list feat/alpha)"
check "...leaving only the main worktree" nothing_created
expect 1 "the rollback also works when the base is a local branch" failing before new alpha beta --ref integ --no-fetch
saw 0 "...removing everything" "everything created before it was removed" "$tmp/err"
check "...leaving only the main worktree" nothing_created
check "...and no leftover branch" test -z "$(git branch --list 'feat/alpha' 'feat/beta')"
expect 1 "a creation that fails after making its worktree is rolled back too" failing after new alpha beta --no-fetch
check "...removing both worktrees" nothing_created
check "...and both branches" test -z "$(git branch --list 'feat/alpha' 'feat/beta')"
expect 1 "a failed worktree with uncommitted files is kept and reported" failing dirty new alpha beta --no-fetch
saw 0 "...naming what remains" "could not remove:" "$tmp/err"
saw 0 "...with the branch" "(feat/beta)" "$tmp/err"
check "...removing the clean first worktree" test ! -e "$tmp/wts/feat-alpha"
rm -f "$tmp/wts/feat-beta/dirty"; git worktree remove "$tmp/wts/feat-beta"; git branch -q -D feat/beta
check "...and nothing else is left once cleaned" nothing_created

expect 1 "a branch created without a worktree is cleaned up too" failing branchonly new alpha beta --no-fetch
saw 0 "...claiming success only because nothing remains" "everything created before it was removed" "$tmp/err"
check "...leaving no branch" test -z "$(git branch --list 'feat/alpha' 'feat/beta')"
check "...and only the main worktree" nothing_created
mkdir -p "$tmp/realroot"; ln -s "$tmp/realroot" "$tmp/linkroot"
( export DEVFLOW_WORKTREE_ROOT="$tmp/linkroot/wts"; failing after new alpha beta --no-fetch ); r=$?
check "a worktree folder behind a symbolic link is rolled back (exit 1)" test "$r" = 1
saw 0 "...claiming success only because nothing remains" "everything created before it was removed" "$tmp/err"
check "...leaving no worktree behind" test "$(git worktree list | wc -l | tr -d ' ')" = 1
check "...and no branch" test -z "$(git branch --list 'feat/alpha' 'feat/beta')"
check "...and no directory in the real folder" test -z "$(ls "$tmp/realroot/wts" 2>/dev/null)"

echo "== new: success with an issue"
expect 0 "two eligible changes get a worktree each" run off new alpha:42 beta --no-fetch
valid_json "the output is valid JSON" "$tmp/out"
saw 0 "...alpha carries its issue in branch and worktree" '"change":"alpha","issue":42,"worktree":"'"$tmp"'/wts/feat-42-alpha","branch":"feat/42-alpha","base":"origin/main"'
saw 0 "...beta has no issue" '"change":"beta","issue":null,"worktree":"'"$tmp"'/wts/feat-beta","branch":"feat/beta","base":"origin/main"'
check "alpha worktree carries its change" test -f "$tmp/wts/feat-42-alpha/openspec/changes/alpha/tasks.md"
check "beta worktree carries its change" test -f "$tmp/wts/feat-beta/openspec/changes/beta/tasks.md"
expect 1 "an existing worktree or branch is refused" run off new alpha beta --no-fetch
saw 0 "...naming both" "already has a worktree or branch: alpha(" "$tmp/err"
saw 0 "...including beta" "beta(" "$tmp/err"

echo "== prompt"
expect 0 "a prompt is printed for a worktree" run off prompt alpha --worktree "$tmp/wts/feat-42-alpha"
saw 0 "...names the worktree" "$tmp/wts/feat-42-alpha"
saw 0 "...names the branch" "branch feat/42-alpha"
saw 0 "...names the change" "OpenSpec change: alpha"
saw 0 "...lists the pending tasks" "- 1.1 first alpha task"
saw 0 "...requires apply" "Apply the change"
saw 0 "...requires verify" "/opsx:verify alpha"
saw 0 "...inlines the completeness check" "(a) completeness"
saw 0 "...inlines the correctness check" "(b) correctness"
saw 0 "...inlines the coherence check" "(c) coherence"
saw 1 "...without pointing to a file the worker may lack" "SKILL.md step 5"
saw 0 "...derives the issue from the branch" "--issue 42 --change alpha --task <id>"
saw 0 "...forbids push, PRs, merge and archive" "Do NOT push, open or comment on pull requests, merge, archive the change"
saw 0 "...asks for the report" "- Status: ready-for-review | blocked | partial"
saw 0 "...states what was not done" "Not done: no push, no PR, no merge, no archive."
saw 0 "...uses commit.sh" "$ROOT/scripts/commit.sh"
saw 0 "...runs the project's tests" "the project's tests"
expect 0 "a prompt for a change without issue omits --issue" run off prompt beta --worktree "$tmp/wts/feat-beta"
saw 1 "...no --issue flag" "--issue"
( export DEVFLOW_TEST_CMD="npm test"; run off prompt beta --worktree "$tmp/wts/feat-beta" ); saw 0 "DEVFLOW_TEST_CMD is used for the test run" "Then run npm test."
expect 0 "an explicit --issue is accepted" run off prompt beta --worktree "$tmp/wts/feat-beta" --issue 7
saw 0 "...and used" "--issue 7 --change beta"
expect 1 "a missing worktree is rejected" run off prompt alpha --worktree "$tmp/nope"
expect 1 "an issue with a line break is refused by prompt" run off prompt beta --worktree "$tmp/wts/feat-beta" --issue "7"$'\n'"x"
saw 0 "...saying why" "--issue must be a number" "$tmp/err"
git worktree add -q -b scratch/g "$tmp/gw" origin/main
expect 1 "a change with no pending tasks is refused" run off prompt gamma --worktree "$tmp/gw"
saw 0 "...saying there is nothing to apply" "nothing to apply" "$tmp/err"
git worktree add -q --detach "$tmp/det" origin/main
expect 1 "a detached worktree is refused" run off prompt alpha --worktree "$tmp/det"
saw 0 "...saying why" "detached HEAD" "$tmp/err"

echo "== valid JSON for odd paths"
for c in alpha beta; do git worktree remove "$tmp/wts/feat-${c/alpha/42-alpha}"; done; git branch -q -D feat/42-alpha feat/beta
odd="$tmp/w\"q\\s"$'\001'
( export DEVFLOW_WORKTREE_ROOT="$odd"; run off new alpha beta --type chore --no-fetch ); r=$?
check "a root with a quote and a backslash is accepted" test "$r" = 0
valid_json "...and the output is valid JSON" "$tmp/out"
saw 0 "...with quote, backslash and control character escaped" 'w\"q\\s\u0001/chore-alpha'
for c in alpha beta; do git worktree remove "$odd/chore-$c"; done; git branch -q -D chore/alpha chore/beta
ctl="$tmp/c"$'\001'"x"
( export DEVFLOW_WORKTREE_ROOT="$ctl"; run off new alpha beta --type docs --no-fetch ); r=$?
check "a root with only a control character is accepted" test "$r" = 0
valid_json "...and the output is valid JSON" "$tmp/out"
saw 0 "...with the control character escaped" 'c\u0001x/docs-alpha'

for c in alpha beta; do git worktree remove "$ctl/docs-$c"; done; git branch -q -D docs/alpha docs/beta
hi="$tmp/c"$'\001'"af"$'\303\251'
( export LC_ALL=C DEVFLOW_WORKTREE_ROOT="$hi"; run off new alpha beta --type test --no-fetch ); r=$?
check "a root with a control character and non-ASCII bytes is accepted in the C locale" test "$r" = 0
valid_json "...and the output is valid JSON" "$tmp/out"
saw 0 "...escaping the control character" 'c\u0001af'
saw 0 "...and keeping the non-ASCII bytes as they are" $'\303\251'"/test-alpha"

echo "== help"
expect 0 "--help succeeds" run off --help
saw 0 "...and keeps the guarantee that nothing is published" "never pushes, merges, archives, comments or opens pull requests"

echo "== the helper never publishes"
if grep -nE 'git push|git merge|gh pr|gh api|openspec archive' "$BULK" >"$tmp/out"; then echo "  FAIL  bulk.sh contains publishing commands"; cat "$tmp/out"; fail=1; else echo "  ok    no push, merge, PR or archive commands in bulk.sh"; fi

echo
if [ "$fail" = 0 ]; then echo "bulk: ok"; else echo "bulk: FAILED"; fi
exit "$fail"
