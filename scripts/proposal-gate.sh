#!/usr/bin/env bash
# proposal-gate.sh — enforce "every OpenSpec state change crosses the default branch before the next phase".
#
#   proposal-gate.sh <change-id> --stage apply|archive [--no-fetch]
#
# Active only when DEVFLOW_PROPOSAL_GATE=main (two-PR mode); otherwise it reports "gate off" and exits 0.
# --stage apply:   before implementing. The proposal must be committed on the default branch and the
#                  working tree must have no uncommitted files under openspec/changes/<id>/.
# --stage archive: before archiving. The implementation must already be on the default branch (all tasks
#                  done there), the change must still be active there, and HEAD must contain the default
#                  branch tip, so the archive PR is built from the merged state.
# Reads and fetches only; modifies nothing. Exits non-zero when a check fails.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

[ $# -ge 1 ] || die "usage: proposal-gate.sh <change-id> --stage apply|archive [--no-fetch]"
change="$1"; shift
stage="" fetch=1
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:?}"; shift 2;;
    --no-fetch) fetch=0; shift;;
    *) die "unknown option: $1";;
  esac
done
case "$stage" in apply|archive) ;; *) die "--stage must be apply or archive";; esac
is_kebab "$change" || die "invalid change id: $change"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

fail=0
if ! proposal_gate_on; then echo "proposal gate off (DEVFLOW_PROPOSAL_GATE=main enables it)"; exit 0; fi

def="$(default_branch)"
if [ "$fetch" = 1 ] && has_remote; then git fetch --quiet origin "$def" 2>/dev/null || note "could not fetch origin/$def; using the local ref"; fi
ref="$(default_ref)"
top="$(git rev-parse --show-toplevel)"

echo "== proposal gate ($stage) for $change against $ref"
dirty="$(git status --porcelain -- "openspec/changes/$change" | wc -l | tr -d ' ')"

case "$stage" in
  apply)
    if [ "$dirty" = 0 ]; then ok "no uncommitted files under openspec/changes/$change/"; else bad "$dirty uncommitted file(s) under openspec/changes/$change/; commit them first"; fi
    if change_active_on "$ref" "$change"; then
      ok "proposal is on $ref"
    elif change_archived_on "$ref" "$change"; then
      bad "change is already archived on $ref; nothing to apply"
    else
      bad "the proposal change has not reached $def. A proposal can be drafted on a branch, but apply must start only after that proposal state is available on $def. Merge the proposal PR first; then apply can run from a branch or a worktree."
    fi;;
  archive)
    br="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ -n "$br" ] && [ "$br" != "$def" ]; then ok "branch: $br (worktree on top of $def)"; else bad "archive from a worktree branch (not detached, not $def)"; fi
    if [ "$dirty" = 0 ]; then ok "clean openspec/changes/$change/"; else bad "$dirty uncommitted file(s) under openspec/changes/$change/"; fi
    if git merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then ok "HEAD contains $ref"; else bad "HEAD does not contain $ref; rebuild this worktree from the updated $def"; fi
    if change_active_on "$ref" "$change"; then
      ok "change is active on $ref"
      open="$(git show "$ref:openspec/changes/$change/tasks.md" 2>/dev/null | grep -Ec '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' || true)"
      if [ "${open:-0}" = 0 ]; then ok "tasks.md on $ref has 0 pending task(s)"; else bad "tasks.md on $ref has $open pending task(s): the implementation is not merged yet"; fi
    elif change_archived_on "$ref" "$change"; then
      bad "change is already archived on $ref"
    else
      bad "change '$change' does not exist on $ref: the implementation has not been merged back to $def. Verify makes a change eligible to merge; it does not replace the merge."
    fi;;
esac
echo
if [ "$fail" = 0 ]; then echo "GATE OK"; else echo "GATE BLOCKED"; fi
exit "$fail"
