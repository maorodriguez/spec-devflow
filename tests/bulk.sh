#!/usr/bin/env bash
# tests/bulk.sh — regression tests for scripts/bulk.sh (bulk apply helper).
#
#   tests/bulk.sh
#
# Builds a throwaway repo with a bare origin and several OpenSpec changes committed on main, then checks
# list (gate on and off, a change only on a branch, finished and archived changes, an integration ref, a ref
# without changes), new (single change refused, ineligible refused, three worktrees, existing refused, gate
# on) and prompt (every obligation present), and that the script contains no push/merge/archive/PR commands.
# Real git, no OpenSpec CLI. Exit status 1 on any failure. Needs bash and git.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BULK="$ROOT/scripts/bulk.sh"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT

printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 DEVFLOW_WORKTREE_ROOT="$tmp/wts"
unset DEVFLOW_PROPOSAL_GATE DEVFLOW_DEFAULT_BRANCH DEVFLOW_RUNTIME CLAUDECODE OPENCODE OPENCODE_CLIENT

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
mkdir -p openspec/changes/archive/2026-01-01-old; echo "# p" > openspec/changes/archive/2026-01-01-old/proposal.md
git add -A; git commit -q -m "docs: propose alpha beta gamma"; git push -q origin main
git checkout -q -b integ; mk epsilon '- [ ] 1.1 epsilon task'; git add -A; git commit -q -m "docs: propose epsilon"
git checkout -q -b feat/delta-proposal main; mk delta '- [ ] 1.1 delta task'; git add -A; git commit -q -m "docs: propose delta"
git checkout -q main

fail=0
run() { # $1 = off|main (proposal gate), rest = bulk.sh args; output in $tmp/out, status in $?
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

echo "== list, gate off"
expect 0 "list succeeds" run off list --no-fetch
saw 0 "alpha is eligible with 2 pending" '"change":"alpha","ref":"origin/main","pending":2,"done":0,"eligible":true,"needs_confirmation":true'
saw 0 "beta counts done and pending" '"change":"beta","ref":"origin/main","pending":1,"done":1,"eligible":true'
saw 0 "gamma is not eligible: nothing pending" '"change":"gamma","ref":"origin/main","pending":0,"done":1,"eligible":false,"needs_confirmation":false,"reason":"no pending tasks"'
saw 1 "the archive folder is not listed as a change" '"change":"archive"'
saw 1 "a change only on a branch is not listed" '"change":"delta"'
expect 0 "a named change missing from the ref is reported" run off list delta --no-fetch
saw 0 "...as not eligible with the reason" '"eligible":false,"needs_confirmation":false,"reason":"not on origin/main"'
expect 0 "an integration ref lists its own changes" run off list --ref integ --no-fetch
saw 0 "...including epsilon" '"change":"epsilon","ref":"integ"'
expect 0 "a ref without changes lists nothing" run off list --ref "$base_sha" --no-fetch
saw 0 "...an empty array" '[' ; saw 1 "...with no entries" '"change"'
saw 0 "...and warns that it reads committed state" "committed state" "$tmp/err"

echo "== list, gate on"
expect 0 "list succeeds" run main list --no-fetch
saw 0 "alpha is eligible without needing confirmation" '"change":"alpha","ref":"origin/main","pending":2,"done":0,"eligible":true,"needs_confirmation":false'
expect 0 "a proposal that never reached main is explained" run main list delta --no-fetch
saw 0 "...as not reached" 'proposal has not reached origin/main'
expect 1 "--ref other than the default branch is rejected" run main list --ref integ --no-fetch
saw 0 "...saying why" "must be the default branch" "$tmp/err"

echo "== new"
expect 1 "a single change is refused" run off new alpha --no-fetch
saw 0 "...pointing to the normal flow" "at least two changes" "$tmp/err"
expect 1 "an ineligible change is refused" run off new alpha gamma --no-fetch
saw 0 "...naming it and the reason" "gamma(no pending tasks)" "$tmp/err"
expect 1 "with the gate on a proposal not on main is refused" run main new alpha delta --no-fetch
[ ! -e "$tmp/wts" ] && echo "  ok    nothing was created by the refusals" || { echo "  FAIL  a refusal created worktrees"; fail=1; }
expect 0 "two eligible changes get a worktree each" run off new alpha beta --no-fetch
saw 0 "...alpha on its own branch" '"change":"alpha","worktree":"'"$tmp"'/wts/feat-alpha","branch":"feat/alpha","base":"origin/main"'
saw 0 "...beta on its own branch" '"change":"beta","worktree":"'"$tmp"'/wts/feat-beta","branch":"feat/beta","base":"origin/main"'
for c in alpha beta; do [ -f "$tmp/wts/feat-$c/openspec/changes/$c/tasks.md" ] && echo "  ok    $c worktree carries its change" || { echo "  FAIL  $c worktree lacks its change"; fail=1; }; done
git worktree list | grep -q "feat/alpha" && git worktree list | grep -q "feat/beta" && echo "  ok    git lists both worktrees" || { echo "  FAIL  worktrees not registered"; fail=1; }
expect 1 "an existing worktree or branch is refused" run off new alpha beta --no-fetch
saw 0 "...naming both" "already has a worktree or branch: alpha beta" "$tmp/err"

echo "== prompt"
expect 0 "a prompt is printed for a worktree" run off prompt alpha --worktree "$tmp/wts/feat-alpha"
saw 0 "...names the worktree" "$tmp/wts/feat-alpha"
saw 0 "...names the branch" "branch feat/alpha"
saw 0 "...names the change" "OpenSpec change: alpha"
saw 0 "...lists the pending tasks" "- 1.1 first alpha task"
saw 0 "...requires apply" "Apply the change"
saw 0 "...requires verify" "/opsx:verify alpha"
saw 0 "...asks for the manual verification fallback" "by hand (SKILL.md step 5)"
saw 0 "...forbids push, PRs, merge and archive" "Do NOT push, open or comment on pull requests, merge, archive the change"
saw 0 "...asks for the report" "- Status: ready-for-review | blocked | partial"
saw 0 "...states what was not done" "Not done: no push, no PR, no merge, no archive."
saw 0 "...uses commit.sh" "$ROOT/scripts/commit.sh"
expect 1 "a missing worktree is rejected" run off prompt alpha --worktree "$tmp/nope"

echo "== the helper never publishes"
if grep -nE 'git push|git merge|gh pr|gh api|openspec archive' "$BULK" >"$tmp/out"; then echo "  FAIL  bulk.sh contains publishing commands"; cat "$tmp/out"; fail=1; else echo "  ok    no push, merge, PR or archive commands in bulk.sh"; fi

echo
if [ "$fail" = 0 ]; then echo "bulk: ok"; else echo "bulk: FAILED"; fi
exit "$fail"
