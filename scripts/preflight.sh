#!/usr/bin/env bash
# preflight.sh — checks before marking a PR ready or archiving.
#
#   preflight.sh <change-id> [--stage ready|merge]   # with OpenSpec
#   preflight.sh --no-change [--stage ready|merge]   # fixes/chores without an OpenSpec change
#
# --stage ready (default): before marking the PR ready for review.
#   The change must be active if DEVFLOW_ARCHIVE_TIMING resolves to after-approval,
#   and already archived if it resolves to before-review.
# --stage merge: before merging. The change must be archived.
# Both stages require a recorded agent code review covering HEAD with 0 CRITICAL findings
# (DEVFLOW_REQUIRE_AGENT_REVIEW=0 disables it).
#
# Optional environment:
#   DEVFLOW_TEST_CMD   test command to run (e.g. "pnpm test")
# Exits non-zero when a blocking check fails. Modifies nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

[ $# -ge 1 ] || die "usage: preflight.sh <change-id>|--no-change [--stage ready|merge]"
change=""; [ "$1" = "--no-change" ] || change="$1"
shift
stage=ready
while [ $# -gt 0 ]; do
  case "$1" in --stage) stage="${2:?}"; shift 2;; *) die "unknown option: $1";; esac
done
case "$stage" in ready|merge) ;; *) die "invalid stage: $stage";; esac

fail=0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
top="$(git rev-parse --show-toplevel)"

echo "== isolation"
if in_linked_worktree; then ok "working in linked worktree: $top"; else bad "you are in the main checkout; work must happen in a worktree"; fi
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
def="$(default_branch)"
if [ -z "$branch" ]; then bad "HEAD is detached; switch to the change branch"
elif [ "$branch" = "$def" ]; then bad "you are on the default branch ($def)"
else ok "branch: $branch"; fi

if [ -n "$change" ]; then
  timing="$(bash "$SCRIPT_DIR/repo-policy.sh" --get archive_timing 2>/dev/null)"
  case "$timing" in before-review|after-approval) ;; *) timing="${DEVFLOW_ARCHIVE_TIMING:-after-approval}"; [ "$timing" = auto ] && timing=after-approval;; esac
  if [ "$stage" = merge ] || [ "$timing" = before-review ]; then expect=archived; else expect=active; fi
  echo "== openspec ($change) — stage=$stage, archive timing=$timing, expected: $expect"
  dir="$top/openspec/changes/$change"
  archived_dir="$(find "$top/openspec/changes/archive" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -E "/[0-9]{4}-[0-9]{2}-[0-9]{2}-$change\$" | sort | tail -n1)"
  if [ -d "$dir" ]; then
    if [ "$expect" = archived ]; then bad "change is still active; archive it now: openspec archive $change --yes"; else ok "openspec/changes/$change exists"; fi
    if command -v openspec >/dev/null 2>&1; then
      if out="$(cd "$top" && openspec validate "$change" --strict --no-interactive 2>&1)"; then ok "openspec validate --strict"
      else bad "openspec validate --strict:"; printf '%s\n' "$out" | sed 's/^/        /'; fi
    else bad "openspec CLI not installed"; fi
    if [ -f "$dir/tasks.md" ]; then
      open="$(grep -Ec '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$dir/tasks.md" || true)"
      done_="$(grep -Eic '^[[:space:]]*[-*][[:space:]]+\[x\]' "$dir/tasks.md" || true)"
      if [ "${open:-0}" = 0 ]; then ok "tasks.md: $done_ done, 0 pending"; else bad "tasks.md: ${open} pending task(s)"; fi
    else note "no tasks.md"; fi
    if grep -Eq '#[0-9]+' "$dir/proposal.md" 2>/dev/null; then ok "proposal.md references an issue"; else note "proposal.md does not reference an issue (#N)"; fi
    ne_files="$(grep -rlE "$NON_ENGLISH_RE" "$dir" 2>/dev/null | sed "s#^$top/##" | paste -sd' ' -)"
    if [ -z "$ne_files" ]; then ok "change artifacts look English"; else note "possible non-English text in: $ne_files (proper names are fine)"; fi
  elif [ -n "$archived_dir" ]; then
    if [ "$expect" = archived ]; then ok "change archived: ${archived_dir#"$top"/}"; else bad "change is already archived but archive timing is after-approval (archive only after the PR is approved)"; fi
    if command -v openspec >/dev/null 2>&1; then
      if out="$(cd "$top" && openspec validate --specs --strict --no-interactive 2>&1)"; then ok "openspec validate --specs --strict"
      else bad "openspec validate --specs --strict:"; printf '%s\n' "$out" | sed 's/^/        /'; fi
      if out="$(cd "$top" && openspec validate --archived --no-interactive 2>&1)"; then ok "archived changes have all tasks done"
      else bad "openspec validate --archived:"; printf '%s\n' "$out" | sed 's/^/        /'; fi
    else bad "openspec CLI not installed"; fi
  else
    bad "openspec/changes/$change does not exist (active or archived)"
  fi
fi

echo "== git"
dirty="$(git status --porcelain | wc -l | tr -d ' ')"
if [ "$dirty" = 0 ]; then ok "clean tree"; else bad "$dirty uncommitted file(s)"; fi
if [ -n "$branch" ]; then
  if up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    case "$up" in */"$def") bad "branch tracks $up; fix with: git branch --unset-upstream && git push -u origin $branch";; esac
    if has_remote; then git fetch --quiet origin "$branch" 2>/dev/null || true; fi
    ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
    behind="$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo '?')"
    if [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then ok "in sync with $up"; else bad "vs $up: $ahead to push, $behind to pull"; fi
  else
    bad "branch not pushed (git push -u origin $branch)"
  fi
  base_ref="$def"; git rev-parse --verify --quiet "origin/$def" >/dev/null && base_ref="origin/$def"
  if [ "$base_ref" = "origin/$def" ]; then
    b="$(git rev-list --count "HEAD..origin/$def")"
    if [ "$b" = 0 ]; then ok "up to date with origin/$def"; else note "origin/$def has $b new commit(s); consider rebase/merge"; fi
  fi

  echo "== authorship and language (commits in $base_ref..HEAD)"
  resolve_identity
  commits="$(git rev-list "$base_ref..HEAD" 2>/dev/null)"
  if [ -z "$commits" ]; then
    note "no commits on the branch yet"
  else
    n="$(printf '%s\n' "$commits" | wc -l | tr -d ' ')"
    wrong_author="" attributed="" non_english=""
    for c in $commits; do
      ae="$(git log -1 --format=%ae "$c")"; an="$(git log -1 --format=%an "$c")"
      if [ "$ID_MODE" = human ] && [ "$ae" != "$ID_EMAIL" ]; then wrong_author="$wrong_author ${c:0:7}($an)"; fi
      if [ "$ID_MODE" = human ] && git log -1 --format=%B "$c" | grep -Eq "$AI_ATTRIBUTION_RE"; then attributed="$attributed ${c:0:7}"; fi
      if git log -1 --format=%B "$c" | grep -Eq "$NON_ENGLISH_RE"; then non_english="$non_english ${c:0:7}"; fi
    done
    if [ "$ID_MODE" = human ]; then
      if [ -z "$wrong_author" ]; then ok "$n commit(s) authored by $ID_NAME <$ID_EMAIL>"; else bad "commits not authored by $ID_EMAIL:$wrong_author"; fi
      if [ -z "$attributed" ]; then ok "no AI attribution in commit messages"; else bad "AI attribution found in:$attributed (reword before pushing, or install the commit-msg hook)"; fi
    else
      note "automated mode: expected identity $ID_NAME <$ID_EMAIL> ($ID_SOURCE)"
    fi
    if [ -z "$non_english" ]; then ok "commit messages look English"; else bad "possible non-English commit messages:$non_english"; fi
  fi
fi

echo "== agent code review"
if [ "${DEVFLOW_REQUIRE_AGENT_REVIEW:-1}" = 0 ]; then
  note "agent code review not required (DEVFLOW_REQUIRE_AGENT_REVIEW=0)"
else
  rs="$(bash "$SCRIPT_DIR/review.sh" status 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then ok "$rs"; else bad "$rs — run the reviewer agent (SKILL.md step 7)"; fi
fi

echo "== tests"
if [ -n "${DEVFLOW_TEST_CMD:-}" ]; then
  if (cd "$top" && sh -c "$DEVFLOW_TEST_CMD"); then ok "$DEVFLOW_TEST_CMD"; else bad "$DEVFLOW_TEST_CMD"; fi
else note "DEVFLOW_TEST_CMD not set; run the project's tests manually"; fi

echo "== github"
if command -v gh >/dev/null 2>&1 && [ -n "$branch" ]; then
  if pr="$(gh pr view "$branch" --json number,state,isDraft,url,author --jq '"#\(.number) \(.state) draft=\(.isDraft) author=\(.author.login) \(.url)"' 2>/dev/null)"; then
    ok "PR: $pr"
    body="$(gh pr view "$branch" --json title,body --jq '.title + "\n" + .body' 2>/dev/null || true)"
    if printf '%s' "$body" | grep -Eq "$NON_ENGLISH_RE"; then note "PR title/body may contain non-English text"; fi
    if [ "${ID_MODE:-human}" = human ] && printf '%s' "$body" | grep -Eq "$AI_ATTRIBUTION_RE"; then bad "PR body contains an AI attribution footer; remove it"; fi
  else note "no PR for $branch (or gh has no access)"; fi
else note "gh not available"; fi

echo
if [ "$fail" = 0 ]; then echo "PREFLIGHT OK"; else echo "PREFLIGHT FAILED"; fi
exit "$fail"
