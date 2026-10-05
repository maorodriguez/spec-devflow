#!/usr/bin/env bash
# tests/proposal-gate.sh — regression tests for scripts/proposal-gate.sh (DEVFLOW_PROPOSAL_GATE=main).
#
#   tests/proposal-gate.sh
#
# Builds a throwaway repo with a bare origin and checks the exit code of each stage in the situations
# that matter: proposal only on a branch, proposal merged, dirty proposal files, open tasks, stale
# worktree, archived change, and gate off. Exit status 1 on any failure. Needs bash and git.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/proposal-gate.sh"
tmp="$(mktemp -d)"; tmp="$(cd "$tmp" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset DEVFLOW_PROPOSAL_GATE DEVFLOW_DEFAULT_BRANCH

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
cd "$tmp/repo" || exit 1
git checkout -q -b main
git commit -q --allow-empty -m init && git push -q -u origin main

fail=0
expect() { # $1 = expected exit code, $2 = label, rest = command
  local want="$1" label="$2" r; shift 2
  "$@" >"$tmp/out" 2>&1; r=$?
  if [ "$r" = "$want" ]; then echo "  ok    $label"; else echo "  FAIL  $label (expected $want, got $r)"; sed 's/^/        /' "$tmp/out"; fail=1; fi
}
gate() { DEVFLOW_PROPOSAL_GATE=main DEVFLOW_DEFAULT_BRANCH=main bash "$GATE" "$@" --no-fetch; }
fetch() { git fetch -q origin; }
add_change() { # $1 = dir, $2 = tasks line
  mkdir -p "openspec/changes/$1"; echo "# p" > "openspec/changes/$1/proposal.md"; printf '%s\n' "$2" > "openspec/changes/$1/tasks.md"
}

echo "== gate off"
git checkout -q -b feat/x
expect 0 "off: apply passes without checking" bash "$GATE" demo --stage apply --no-fetch

echo "== apply"
add_change demo '- [ ] 1.1 do it'; git add -A; git commit -q -m "docs: propose demo"
expect 1 "proposal only on the branch is blocked" gate demo --stage apply
git push -q origin HEAD:main; fetch
expect 0 "proposal on origin/main passes" gate demo --stage apply
echo more >> openspec/changes/demo/proposal.md
expect 1 "uncommitted proposal file is blocked" gate demo --stage apply
git checkout -q -- openspec
expect 1 "unknown change is blocked" gate other --stage apply
expect 1 "invalid change id is rejected" gate Bad_ID --stage apply

echo "== archive"
expect 1 "open tasks on main block the archive" gate demo --stage archive
git checkout -q -b feat/impl; echo '- [x] 1.1 do it' > openspec/changes/demo/tasks.md; git commit -q -am "feat: impl"
git push -q origin HEAD:main; fetch
git checkout -q -b archive/demo origin/main
expect 0 "merged implementation with a fresh worktree passes" gate demo --stage archive
git checkout -q feat/x
expect 1 "worktree behind origin/main is blocked" gate demo --stage archive
git checkout -q archive/demo
mkdir -p openspec/changes/archive; git mv openspec/changes/demo openspec/changes/archive/2026-01-01-demo; git commit -q -m "docs: archive demo"
git push -q origin HEAD:main; fetch
expect 1 "already archived on main is blocked (archive stage)" gate demo --stage archive
expect 1 "already archived on main is blocked (apply stage)" gate demo --stage apply

echo
if [ "$fail" = 0 ]; then echo "proposal-gate: ok"; else echo "proposal-gate: FAILED"; fi
exit "$fail"
