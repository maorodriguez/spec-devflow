#!/usr/bin/env bash
# merge.sh — merge (or enable auto-merge for) a PR after checking the flow's preconditions.
#
#   merge.sh <pr> [--auto] [--strategy squash|merge|rebase] [--no-change] [--delete-branch] [--confirm]
#
# Without --confirm it only prints the checks and the exact gh command (dry run).
# Ask the user before re-running with --confirm: merging is visible to everyone and hard to undo.
#
# Checks: PR open and not draft; approved by someone other than the author; checks not failing;
# the OpenSpec change is archived on the PR head (unless --no-change); a recorded agent code review
# covers the PR head with 0 CRITICAL (unless DEVFLOW_REQUIRE_AGENT_REVIEW=0); English merge subject.
# With DEVFLOW_PROPOSAL_GATE=main the archive check is replaced by the two-PR checks (proposal / implementation / archive PR).
# Uses --match-head-commit so GitHub refuses the merge if the head moved after these checks.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

[ $# -ge 1 ] || die "usage: merge.sh <pr> [--auto] [--strategy squash|merge|rebase] [--no-change] [--delete-branch] [--confirm]"
pr="$1"; shift
printf '%s' "$pr" | grep -Eq '^[0-9]+$' || die "invalid PR number: $pr"
auto="${DEVFLOW_AUTO_MERGE:-0}" strategy="${DEVFLOW_MERGE_STRATEGY:-squash}" nochange=0 delbranch=0 confirm=0
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) auto=1; shift;;
    --strategy) strategy="${2:?}"; shift 2;;
    --no-change) nochange=1; shift;;
    --delete-branch) delbranch=1; shift;;
    --confirm) confirm=1; shift;;
    *) die "unknown option: $1";;
  esac
done
case "$strategy" in squash|merge|rebase) ;; *) die "invalid strategy: $strategy";; esac
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then die "gh is not available or not authenticated"; fi

fail=0

info="$(gh pr view "$pr" --json state,isDraft,author,headRefName,headRefOid,baseRefName,reviewDecision,mergeStateStatus \
  --jq '[.state, (.isDraft|tostring), .author.login, .headRefName, .headRefOid, .baseRefName, (.reviewDecision | if . == null or . == "" then "NONE" else . end), (.mergeStateStatus | if . == null or . == "" then "UNKNOWN" else . end)] | join(" ")')" \
  || die "cannot read PR #$pr"
read -r state draft author head head_oid base decision mstate <<EOF
$info
EOF
# title/body can contain spaces and newlines, so they can't go through the space-joined read above.
# (gh has no `--jq -j`; `--jq` prints a string result raw, without quotes.) reviewDecision is "" (not null)
# when the repo does not require reviews, so `// "NONE"` would not fire and the fields would shift.
title="$(gh pr view "$pr" --json title --jq .title)" || die "cannot read the title of PR #$pr"
body="$(gh pr view "$pr" --json body --jq .body)" || die "cannot read the body of PR #$pr"
me="$(gh api user --jq .login 2>/dev/null || echo unknown)"

echo "== PR #$pr ($head -> $base) by $author; you are $me"
if [ "$state" = OPEN ]; then ok "open"; else bad "state is $state"; fi
if [ "$draft" = false ]; then ok "ready for review"; else bad "still a draft (gh pr ready $pr)"; fi

approvers="$(gh pr view "$pr" --json latestReviews --jq "[.latestReviews[] | select(.state==\"APPROVED\" and .author.login != \"$author\") | .author.login] | unique | join(\",\")")"
if [ -n "$approvers" ]; then ok "approved by: $approvers"; else bad "no approval from someone other than the author"; fi
[ "$decision" = CHANGES_REQUESTED ] && bad "changes requested"
[ "$decision" = REVIEW_REQUIRED ] && bad "branch protection still requires reviews"

# shellcheck disable=SC2016  # jq variables, not shell
failing="$(gh pr view "$pr" --json statusCheckRollup --jq '[.statusCheckRollup[]? | select((.conclusion // .state) as $c | ["FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED"] | index($c)) | (.name // .context)] | join(",")')"
# shellcheck disable=SC2016
pending="$(gh pr view "$pr" --json statusCheckRollup --jq '[.statusCheckRollup[]? | select((.status // "") as $s | ["QUEUED","IN_PROGRESS","PENDING","WAITING"] | index($s)) | (.name // .context)] | join(",")')"
if [ -z "$failing" ]; then ok "no failing checks"; else bad "failing checks: $failing"; fi
if [ -n "$pending" ]; then
  if [ "$auto" = 1 ]; then note "pending checks ($pending): auto-merge will wait for them"; else bad "pending checks: $pending (wait, or use --auto)"; fi
fi
case "$mstate" in
  BEHIND) if [ "$auto" = 1 ]; then note "branch is behind $base"; else bad "branch is behind $base; update it first"; fi;;
  DIRTY) bad "merge conflicts with $base";;
  BLOCKED) bad "merge blocked by branch protection (mergeStateStatus=BLOCKED)";;
  *) note "merge state: $mstate";;
esac

change="$(printf '%s\n' "$body" | sed -n 's/^OpenSpec-Change:[[:space:]]*`\{0,1\}\([a-z0-9-]*\).*/\1/p' | head -n1)"
issue_line="$(printf '%s\n' "$body" | grep -Eio '^(closes|fixes|resolves) #[0-9]+' | head -n1)"
git fetch --quiet origin "$head" 2>/dev/null || true
if [ "$nochange" = 1 ]; then
  note "no OpenSpec change expected (--no-change)"
elif [ -z "$change" ]; then
  bad "PR body has no 'OpenSpec-Change:' line (use --no-change for fixes without a change)"
elif proposal_gate_on; then
  # Two-PR mode: the PR is a proposal PR, an implementation PR (change active) or the archive PR (archived).
  git fetch --quiet origin "$base" 2>/dev/null || true
  base_ref="origin/$base"; git rev-parse --verify --quiet "$base_ref" >/dev/null || base_ref="$base"
  if change_active_on "$head_oid" "$change"; then
    if change_active_on "$base_ref" "$change"; then ok "implementation PR: proposal '$change' is already on $base_ref"
    else ok "proposal PR: '$change' is not on $base_ref yet"; fi
    note "archive it afterwards in its own PR (proposal-gate.sh $change --stage archive)"
  elif change_archived_on "$head_oid" "$change"; then
    if change_active_on "$base_ref" "$change"; then ok "archive PR: '$change' is active on $base_ref and archived on the PR head"
    else bad "change '$change' is not active on $base_ref; nothing to archive (implementation not merged?)"; fi
  else
    bad "change '$change' not found on the PR head"
  fi
else
  if git cat-file -e "$head_oid:openspec/changes/$change/proposal.md" 2>/dev/null; then
    bad "change '$change' is not archived on the PR head (openspec archive $change --yes, commit, push)"
  elif git rev-parse --verify --quiet "$head_oid^{commit}" >/dev/null && \
       git ls-tree -d --name-only "$head_oid" "openspec/changes/archive/" 2>/dev/null | grep -Eq "/[0-9]{4}-[0-9]{2}-[0-9]{2}-$change\$"; then
    ok "change '$change' archived on the PR head"
  else
    note "could not verify archive state locally (head $head_oid not fetched?)"
  fi
fi

if [ "${DEVFLOW_REQUIRE_AGENT_REVIEW:-1}" != 0 ]; then
  if git cat-file -e "$head_oid^{commit}" 2>/dev/null; then
    if rs="$(bash "$SCRIPT_DIR/review.sh" status --head "$head_oid" 2>&1)"; then ok "$rs"; else bad "agent code review: $rs"; fi
  else
    note "PR head not available locally; cannot check the agent code review"
  fi
fi

subject="$title (#$pr)"
if printf '%s' "$subject" | grep -Eq "$NON_ENGLISH_RE"; then bad "PR title looks non-English: $title"; fi
mbody=""
[ -z "$issue_line" ] || mbody="$issue_line"
[ -z "$change" ] || mbody="${mbody:+$mbody
}OpenSpec-Change: $change"

cmd=(gh pr merge "$pr" "--$strategy" --match-head-commit "$head_oid")
[ "$auto" = 1 ] && cmd+=(--auto)
if [ "$strategy" != rebase ]; then cmd+=(--subject "$subject"); [ -z "$mbody" ] || cmd+=(--body "$mbody"); fi
[ "$delbranch" = 1 ] && cmd+=(--delete-branch)

echo
echo "command:"; printf '  %q' "${cmd[@]}"; echo
if [ "$fail" != 0 ]; then echo "MERGE BLOCKED"; exit 1; fi
if [ "$confirm" != 1 ]; then echo "DRY RUN: checks passed. Ask the user, then re-run with --confirm."; exit 0; fi
"${cmd[@]}"
