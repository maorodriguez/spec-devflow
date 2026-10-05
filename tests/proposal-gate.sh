#!/usr/bin/env bash
# tests/proposal-gate.sh — regression tests for the proposal gate (DEVFLOW_PROPOSAL_GATE=main):
# scripts/proposal-gate.sh, the PR classification helpers in scripts/lib.sh and how preflight.sh uses them.
#
#   tests/proposal-gate.sh
#
# Builds a throwaway repo with a bare origin and walks the three PRs of the two-PR mode (proposal,
# implementation, archive) in linked worktrees, checking what is allowed and what is blocked: proposal only
# on a branch, dirty or different proposal, open tasks, mixed PRs, stale or main-checkout archive, and the
# gate off, renamed files and phases skipped. preflight.sh and merge.sh (dry run) run with `openspec` and
# `gh` stubbed. Exit status 1 on any failure. Needs bash and git.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/proposal-gate.sh"
PREFLIGHT="$ROOT/scripts/preflight.sh"
LIB="$ROOT/scripts/lib.sh"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT

# Isolate from the user's git configuration (signing, hooks, default branch...).
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset DEVFLOW_PROPOSAL_GATE DEVFLOW_DEFAULT_BRANCH DEVFLOW_ARCHIVE_TIMING DEVFLOW_AUTOMATED CI GITHUB_ACTIONS

mkdir "$tmp/stubs"
printf '#!/bin/sh\nexit 0\n' > "$tmp/stubs/openspec"
# gh stub: answers the `pr view` queries of merge.sh for the PR described by GH_HEAD_REF / GH_HEAD_OID; fails otherwise.
cat > "$tmp/stubs/gh" <<'STUB'
#!/bin/sh
case "$*" in
  "auth status"*) exit 0;;
  "api user"*) echo me;;
  *"--json state,isDraft,author"*) echo "OPEN false author $GH_HEAD_REF $GH_HEAD_OID main NONE CLEAN";;
  *"--json title"*) echo "docs: demo";;
  *"--json body"*) printf 'OpenSpec-Change: demo\n';;
  *latestReviews*) echo reviewer;;
  *statusCheckRollup*) echo "";;
  *) exit 1;;
esac
STUB
chmod +x "$tmp/stubs/openspec" "$tmp/stubs/gh"

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
cd "$tmp/repo" || exit 1
git checkout -q -b main
mkdir src; echo orig > src/orig.txt; git add -A; git commit -q -m init && git push -q -u origin main

fail=0
expect() { # $1 = expected exit code, $2 = label, rest = command (output kept in $tmp/out)
  local want="$1" label="$2" r; shift 2
  "$@" >"$tmp/out" 2>&1; r=$?
  if [ "$r" = "$want" ]; then echo "  ok    $label"; else echo "  FAIL  $label (expected exit $want, got $r)"; sed 's/^/        /' "$tmp/out"; fail=1; fi
}
saw() { # $1 = 0 (must appear) | 1 (must not appear), $2 = label, $3 = fixed text in $tmp/out
  if grep -qF -- "$3" "$tmp/out"; then r=0; else r=1; fi
  if [ "$r" = "$1" ]; then echo "  ok    $2"; else echo "  FAIL  $2 (pattern '$3' $([ "$1" = 0 ] && echo missing || echo present))"; sed 's/^/        /' "$tmp/out"; fail=1; fi
}
gate() { DEVFLOW_PROPOSAL_GATE=main DEVFLOW_DEFAULT_BRANCH=main bash "$GATE" "$@" --no-fetch; }
pre() { PATH="$tmp/stubs:$PATH" DEVFLOW_REQUIRE_AGENT_REVIEW=0 DEVFLOW_DEFAULT_BRANCH=main DEVFLOW_PROPOSAL_GATE="$1" bash "$PREFLIGHT" demo --stage ready; }
mrg() { ( cd "$1" && GH_HEAD_OID="$(git rev-parse HEAD)" GH_HEAD_REF="$(git rev-parse --abbrev-ref HEAD)" PATH="$tmp/stubs:$PATH" DEVFLOW_REQUIRE_AGENT_REVIEW=0 DEVFLOW_DEFAULT_BRANCH=main DEVFLOW_PROPOSAL_GATE="${2:-main}" bash "$ROOT/scripts/merge.sh" 7 ); }
kind() { ( . "$LIB"; classify_change_pr origin/main HEAD demo ); }
scope() { ( . "$LIB"; pr_scope_check "$1" origin/main HEAD demo ); }
newwt() { git fetch -q origin; git worktree add -q --no-track -b "$1" "$tmp/$1" origin/main; } # worktree from the updated main
commit() { git add -A && git commit -q -m "$1"; }
unset -f test 2>/dev/null

echo "== gate off"
newwt pA; cd "$tmp/pA" || exit 1
expect 0 "off: apply passes without checking" bash "$GATE" demo --stage apply --no-fetch

echo "== PR 1: proposal"
mkdir -p openspec/changes/demo; echo "# p" > openspec/changes/demo/proposal.md; echo '- [ ] 1.1 do it' > openspec/changes/demo/tasks.md
commit "docs: propose demo"
expect 1 "apply is blocked while the proposal is only on the branch" gate demo --stage apply
saw 0 "...with the skill's message" "has not reached main"
git fetch -q origin
[ "$(kind)" = proposal ] && echo "  ok    classified as proposal" || { echo "  FAIL  classified as $(kind), expected proposal"; fail=1; }
expect 0 "proposal-only content fits" scope proposal
pre main >"$tmp/out" 2>&1; saw 0 "preflight reports the proposal PR" "proposal PR: content fits"
saw 0 "...tolerating its pending tasks" "info  tasks.md: 1 pending"
mkdir -p src; echo x > src/code.txt; commit "feat: sneak code into the proposal"
expect 1 "a proposal PR with code is blocked" scope proposal
saw 0 "...naming the offending file" "src/code.txt"
pre main >"$tmp/out" 2>&1; saw 0 "preflight blocks the mixed PR" "FAIL  proposal PR touches files outside"
git reset -q --hard HEAD~1
git mv src/orig.txt openspec/changes/demo/orig.txt; commit "docs: move a file into the proposal"
expect 1 "a proposal PR hiding a deletion behind a rename is blocked" scope proposal
saw 0 "...showing the deleted file" "src/orig.txt"
git reset -q --hard HEAD~1
expect 0 "merge.sh (dry run) accepts the proposal PR" mrg "$tmp/pA"
saw 0 "...as a proposal PR" "proposal PR for 'demo'"
git push -q origin HEAD:main

echo "== skipping the implementation"
cd "$tmp/repo" && newwt pS && cd "$tmp/pS" || exit 1
mkdir -p openspec/changes/archive; git mv openspec/changes/demo openspec/changes/archive/2026-01-01-demo
echo '- [x] 1.1 do it' > openspec/changes/archive/2026-01-01-demo/tasks.md; commit "docs: archive without implementing"
git fetch -q origin
expect 1 "an archive PR while main still has pending tasks is blocked" scope archive
saw 0 "...saying the implementation is not merged" "implementation is not merged"
expect 1 "merge.sh (dry run) blocks it too" mrg "$tmp/pS"
saw 0 "...with the reason" "MERGE BLOCKED"

echo "== PR 2: implementation"
cd "$tmp/repo" && newwt pB && cd "$tmp/pB" || exit 1
expect 0 "apply passes once the proposal is on main" gate demo --stage apply
echo more >> openspec/changes/demo/proposal.md
expect 1 "an uncommitted proposal file is blocked" gate demo --stage apply
mkdir -p src; ( cd src && expect 1 "...also when run from a subdirectory" gate demo --stage apply )
git checkout -q -- openspec
expect 1 "an unknown change is blocked" gate other --stage apply
expect 1 "an invalid change id is rejected" gate Bad_ID --stage apply
cd "$tmp/repo" && git worktree add -q --no-track -b pX "$tmp/pX" origin/main && cd "$tmp/pX" || exit 1
echo "changed after approval" >> openspec/changes/demo/proposal.md; commit "docs: edit the proposal"
expect 1 "a proposal that differs from main is blocked" gate demo --stage apply
saw 0 "...explaining why" "differs from"
cd "$tmp/pB" || exit 1
echo y > src/feature.txt; commit "feat: partial implementation"
git fetch -q origin
[ "$(kind)" = implementation ] && echo "  ok    classified as implementation" || { echo "  FAIL  classified as $(kind), expected implementation"; fail=1; }
expect 1 "an implementation PR with pending tasks is blocked" scope implementation
echo '- [x] 1.1 do it' > openspec/changes/demo/tasks.md; commit "feat: finish the implementation"
expect 0 "a finished implementation PR fits" scope implementation
echo "rewritten" >> openspec/changes/demo/proposal.md; commit "feat: also rewrite the approved spec"
expect 1 "an implementation PR that edits the approved proposal is blocked" scope implementation
saw 0 "...explaining why" "changes the approved proposal"
git reset -q --hard HEAD~1
expect 0 "merge.sh (dry run) accepts the implementation PR" mrg "$tmp/pB"
saw 0 "...as an implementation PR" "implementation PR for 'demo'"
expect 1 "merge.sh with the gate off keeps the single-PR rule (unchanged)" mrg "$tmp/pB" off
saw 0 "...asking to archive" "is not archived on the PR head"
saw 1 "...without PR kinds" "implementation PR for"
pre main >"$tmp/out" 2>&1; saw 0 "preflight reports the implementation PR" "implementation PR: content fits"
saw 1 "...without archive complaints" "archived"
git push -q origin HEAD:main

echo "== PR 3: archive"
cd "$tmp/repo" && git fetch -q origin
expect 1 "archive from the main checkout is blocked" gate demo --stage archive
saw 0 "...asking for a worktree" "main checkout"
cd "$tmp/pA" || exit 1
expect 1 "archive from a worktree behind main is blocked" gate demo --stage archive
cd "$tmp/repo" && newwt pC && cd "$tmp/pC" || exit 1
expect 0 "archive from a fresh worktree after the merge passes" gate demo --stage archive
mkdir -p openspec/changes/archive; git mv openspec/changes/demo openspec/changes/archive/2026-01-01-demo; commit "docs: archive demo"
[ "$(kind)" = archive ] && echo "  ok    classified as archive" || { echo "  FAIL  classified as $(kind), expected archive"; fail=1; }
expect 0 "an archive-only diff fits" scope archive
( cd "$tmp/pC/src" && [ "$(kind)" = archive ] ) && echo "  ok    classification also works from a subdirectory" || { echo "  FAIL  classification from a subdirectory"; fail=1; }
expect 0 "merge.sh (dry run) accepts the archive PR" mrg "$tmp/pC"
saw 0 "...as an archive PR" "archive PR for 'demo'"
git mv src/orig.txt openspec/orig.txt; commit "docs: move code under openspec/"
expect 1 "an archive PR hiding a deletion behind a rename is blocked" scope archive
saw 0 "...showing the deleted file" "src/orig.txt"
git reset -q --hard HEAD~1
pre main >"$tmp/out" 2>&1; saw 0 "preflight accepts the archive PR with the gate on" "archive PR: content fits"
saw 1 "...without the old 'archived in this PR' failure" "FAIL  change is archived"
pre off >"$tmp/out" 2>&1; saw 0 "gate off: preflight keeps the single-PR rule (unchanged)" "FAIL  change is already archived but archive timing is after-approval"
saw 1 "gate off: no proposal gate section" "== proposal gate"
echo z > src/extra.txt; commit "feat: code in the archive PR"
expect 1 "an archive PR with code outside openspec/ is blocked" scope archive
git reset -q --hard HEAD~1
git push -q origin HEAD:main; git fetch -q origin
expect 1 "once archived on main, archive is blocked" gate demo --stage archive
expect 1 "once archived on main, apply is blocked" gate demo --stage apply

echo
if [ "$fail" = 0 ]; then echo "proposal-gate: ok"; else echo "proposal-gate: FAILED"; fi
exit "$fail"
