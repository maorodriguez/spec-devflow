#!/usr/bin/env bash
# repo-policy.sh — inspect how GitHub protects the default branch and how PRs can be merged (read-only).
#
#   repo-policy.sh                 key=value report + recommendations
#   repo-policy.sh --get <key>     print a single value (e.g. archive_timing, dismiss_stale)
#   repo-policy.sh --print-ruleset print a recommended ruleset JSON and the gh command to create it
#                                  (never applied by this script; changing repo settings needs the owner's decision)
#
# Sources: repository rulesets (GET repos/{r}/rules/branches/{b}, readable with read access) and
# classic branch protection (GET repos/{r}/branches/{b}/protection, needs admin; reported as unknown otherwise).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

mode="report"; getkey=""
case "${1:-}" in
  --get) mode="get"; getkey="${2:?key required}";;
  --print-ruleset) mode=ruleset;;
  "") ;;
  *) die "unknown option: $1";;
esac

if [ "$mode" = ruleset ]; then
  cat <<'EOF'
# Recommended ruleset for the default branch. Review it, add your CI check names to
# required_status_checks, then (as a repo admin, after deciding to) run:
#   gh api -X POST repos/{owner}/{repo}/rulesets --input ruleset.json
{
  "name": "protect-default-branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"] } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "REPLACE-WITH-YOUR-CI-CHECK-NAME" } ] } }
  ]
}
# Repository merge settings to pair with it (also an admin decision):
#   gh api -X PATCH repos/{owner}/{repo} -F allow_auto_merge=true -F delete_branch_on_merge=true \
#     -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
EOF
  exit 0
fi

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  if [ "$mode" = get ]; then echo unknown; else echo "policy=unknown (gh unavailable or not authenticated)"; fi
  exit 0
fi

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || { echo "policy=unknown (not a GitHub repo?)"; exit 0; }
branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || default_branch)"

# Repository merge settings.
settings="$(gh api "repos/$repo" --jq '[.allow_squash_merge, .allow_merge_commit, .allow_rebase_merge, .allow_auto_merge, .delete_branch_on_merge, .squash_merge_commit_title, .squash_merge_commit_message] | map(tostring) | join(" ")' 2>/dev/null || echo "")"
read -r s_squash s_merge s_rebase s_auto s_delete s_sqtitle s_sqmsg <<EOF
${settings:-unknown unknown unknown unknown unknown unknown unknown}
EOF

# Rulesets that apply to the default branch (one fetch, sliced four ways).
if rules_json="$(gh api "repos/$repo/rules/branches/$branch" 2>/dev/null)"; then
  rules_pr="$(printf '%s' "$rules_json" | jq '[.[] | select(.type=="pull_request") | .parameters] | if length==0 then "none" else ((map(.required_approving_review_count) | max | tostring) + " " + (map(.dismiss_stale_reviews_on_push) | any | tostring) + " " + (map(.require_last_push_approval) | any | tostring) + " " + (map(.required_review_thread_resolution) | any | tostring)) end' 2>/dev/null || echo error)"
  rules_checks="$(printf '%s' "$rules_json" | jq '[.[] | select(.type=="required_status_checks") | .parameters] | if length==0 then "none" else ((map(.required_status_checks | length) | add | tostring) + " " + (map(.strict_required_status_checks_policy) | any | tostring)) end' 2>/dev/null || echo error)"
  rules_mq="$(printf '%s' "$rules_json" | jq '[.[] | select(.type=="merge_queue")] | length > 0' 2>/dev/null || echo unknown)"
  rules_methods="$(printf '%s' "$rules_json" | jq '[.[] | select(.type=="pull_request") | .parameters.allowed_merge_methods // empty] | flatten | unique | join(",")' 2>/dev/null || echo "")"
else
  rules_pr=error; rules_checks=error; rules_mq=unknown; rules_methods=""
fi

# Classic branch protection (admin only).
classic="$(gh api "repos/$repo/branches/$branch/protection" --jq '[(.required_pull_request_reviews.required_approving_review_count // 0 | tostring), (.required_pull_request_reviews.dismiss_stale_reviews // false | tostring), (.required_status_checks.strict // false | tostring), ((.required_status_checks.checks // []) | length | tostring), ((.required_pull_request_reviews != null) | tostring)] | join(" ")' 2>/dev/null || echo unavailable)"

requires_pr=false approvals=0 dismiss_stale=false last_push=false threads=false checks=0 strict=false source=""
if [ "$rules_pr" != none ] && [ "$rules_pr" != error ]; then
  read -r a d l t <<EOF
$rules_pr
EOF
  requires_pr=true; approvals="$a"; dismiss_stale="$d"; last_push="$l"; threads="$t"; source="rulesets"
fi
if [ "$rules_checks" != none ] && [ "$rules_checks" != error ]; then
  read -r c s <<EOF
$rules_checks
EOF
  checks="$c"; strict="$s"; source="${source:-rulesets}"
fi
if [ "$classic" != unavailable ]; then
  read -r ca cd cs cc cp <<EOF
$classic
EOF
  [ "$cp" = true ] && requires_pr=true
  [ "$ca" -gt "$approvals" ] 2>/dev/null && approvals="$ca"
  [ "$cd" = true ] && dismiss_stale=true
  [ "$cs" = true ] && strict=true
  [ "$cc" -gt "$checks" ] 2>/dev/null && checks="$cc"
  source="${source:+$source+}classic"
fi
classic_state="read"; [ "$classic" = unavailable ] && classic_state="not readable (needs admin) or not configured"

# Archive timing: explicit config wins; "auto" follows the stale-review setting.
timing="${DEVFLOW_ARCHIVE_TIMING:-auto}"
if [ "$timing" = auto ]; then
  if [ "$dismiss_stale" = true ]; then timing=before-review; else timing=after-approval; fi
fi
strategy="${DEVFLOW_MERGE_STRATEGY:-squash}"
automerge="${DEVFLOW_AUTO_MERGE:-0}"

if [ "$mode" = get ]; then
  case "$getkey" in
    archive_timing) echo "$timing";; dismiss_stale) echo "$dismiss_stale";; merge_strategy) echo "$strategy";;
    auto_merge) echo "$automerge";; auto_merge_allowed) echo "$s_auto";; requires_pr) echo "$requires_pr";;
    merge_queue) echo "$rules_mq";; *) die "unknown key: $getkey";;
  esac
  exit 0
fi

echo "repo=$repo"
echo "default_branch=$branch"
echo "protection_source=${source:-none}"
echo "classic_protection=$classic_state"
echo "requires_pr=$requires_pr"
echo "required_approvals=$approvals"
echo "dismiss_stale=$dismiss_stale"
echo "require_last_push_approval=$last_push"
echo "require_thread_resolution=$threads"
echo "required_checks=$checks"
echo "require_up_to_date=$strict"
echo "merge_queue=$rules_mq"
echo "allowed_methods_repo=squash:$s_squash merge:$s_merge rebase:$s_rebase${rules_methods:+ (ruleset: $rules_methods)}"
echo "auto_merge_allowed=$s_auto"
echo "delete_branch_on_merge=$s_delete"
echo "squash_commit=$s_sqtitle/$s_sqmsg"
echo "archive_timing=$timing"
echo "merge_strategy=$strategy"
echo "auto_merge=$automerge"

echo "recommendations:"
n=0
rec() { echo "  - $*"; n=$((n+1)); }
[ "$requires_pr" = true ] || rec "require a pull request before merging into $branch (no direct pushes)"
[ "$approvals" -ge 1 ] 2>/dev/null || rec "require at least 1 approving review"
[ "$checks" -ge 1 ] 2>/dev/null || rec "require status checks (CI, including 'openspec validate --all --strict')"
[ "$strict" = true ] || [ "$rules_mq" = true ] || rec "require branches to be up to date before merging (or use a merge queue)"
[ "$strategy" != squash ] || [ "$s_squash" = true ] || [ "$s_squash" = unknown ] || rec "squash merging is disabled in the repo but DEVFLOW_MERGE_STRATEGY=squash"
[ "$strategy" != squash ] || [ "$s_sqmsg" = PR_BODY ] || [ "$s_sqmsg" = unknown ] || rec "set the squash commit message to 'Pull request title and description' so Closes/OpenSpec-Change reach $branch"
[ "$automerge" != 1 ] || [ "$s_auto" = true ] || rec "DEVFLOW_AUTO_MERGE=1 but auto-merge is not allowed in the repo settings"
[ "$s_delete" = true ] || [ "$s_delete" = unknown ] || rec "enable 'automatically delete head branches' (auto-merge does not delete them)"
[ "$n" -gt 0 ] || echo "  (none)"
echo "  (repo-policy.sh --print-ruleset prints a ready-made ruleset; applying it is a repo admin decision)"
