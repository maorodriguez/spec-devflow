#!/usr/bin/env bash
# review.sh — support for the agent code review step.
#
#   review.sh context [--base REF] [--since SHA]   what to review: range, changed files, OpenSpec change (read-only)
#   review.sh record <report.md>                    validate a report and store it for the commit it reviewed
#   review.sh status [--head SHA]                   is HEAD covered by a recorded review with 0 CRITICAL findings?
#   review.sh publish <pr> [--confirm]              post the review for the PR head as a PR comment (dry run by default)
#
# Reports live in <git-common-dir>/devflow/reviews/<sha>.md: shared by all worktrees, never committed.
# A review of commit X also covers HEAD when every change between X and HEAD is under openspec/
# (e.g. the archive commit). Any code change after the reviewed commit requires a new review.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
RDIR="$(review_dir)"

base_ref() {
  local def; def="$(default_branch)"
  if git rev-parse --verify --quiet "origin/$def" >/dev/null; then echo "origin/$def"; else echo "$def"; fi
}

count_sev() { grep -Ec "^- \[$2\]" "$1" || true; }

cmd_context() {
  local base="" since=""
  while [ $# -gt 0 ]; do
    case "$1" in --base) base="${2:?}"; shift 2;; --since) since="${2:?}"; shift 2;; *) die "unknown option: $1";; esac
  done
  [ -n "$base" ] || base="$(base_ref)"
  local head from
  head="$(git rev-parse HEAD)"
  from="${since:-$(git merge-base "$base" HEAD)}" || die "cannot determine merge-base with $base"
  [ -n "$from" ] || die "cannot determine merge-base with $base"
  echo "head=$head"
  echo "base=$base"
  echo "range=${from:0:12}..${head:0:12}${since:+ (incremental since $since)}"
  echo "commits:"; git log --format='  %h %s (%an)' "$from..HEAD"
  echo "changed_files:"; git diff --stat=120 "$from" HEAD | sed 's/^/  /'
  local changes
  changes="$(git diff --name-only "$from" HEAD -- openspec/changes | sed -n 's#^openspec/changes/\(archive/[0-9-]*\)\{0,1\}\([a-z0-9-]*\)/.*#\2#p' | sort -u | paste -sd' ' -)"
  echo "openspec_changes=${changes:-none}"
  echo "next: read the diff with 'git diff $from HEAD', the change artifacts, then apply references/code-review.md"
}

cmd_record() {
  local f="${1:?report file required}" head crit warn sugg
  [ -f "$f" ] || die "report not found: $f"
  grep -q '^# Code review' "$f" || die "report must start with '# Code review' (see references/code-review.md)"
  head="$(sed -n 's/^head:[[:space:]]*\([0-9a-f]\{7,40\}\).*/\1/p' "$f" | head -n1)"
  [ -n "$head" ] || die "report has no 'head: <sha>' line"
  head="$(git rev-parse --verify --quiet "$head^{commit}")" || die "head $head is not a known commit"
  grep -q '^## Findings' "$f" || die "report has no '## Findings' section"
  grep -q '^## Summary' "$f" || die "report has no '## Summary' section"
  if grep -Eq "$NON_ENGLISH_RE" "$f"; then die "report looks non-English; the review must be written in English"; fi
  # When recording from a (detached) review worktree, it must still be clean: the reviewer is read-only.
  if ! git symbolic-ref -q HEAD >/dev/null && [ -n "$(git status --porcelain)" ]; then
    die "the review worktree has changes; the reviewer must not edit files (keep the report outside the worktree)"
  fi
  crit="$(count_sev "$f" CRITICAL)"; warn="$(count_sev "$f" WARNING)"; sugg="$(count_sev "$f" SUGGESTION)"
  mkdir -p "$RDIR"
  cp "$f" "$RDIR/$head.md"
  printf 'recorded=%s\ncritical=%s\nwarning=%s\nsuggestion=%s\n' "$head" "$crit" "$warn" "$sugg"
}

# Find the most recent recorded review that covers HEAD. Prints "<sha> <critical>" or nothing.
covering_review() {
  local head="$1" c sha
  for c in $(git rev-list "$head"); do
    if [ -f "$RDIR/$c.md" ]; then sha="$c"; break; fi
  done
  [ -n "${sha:-}" ] || return 0
  if [ "$sha" != "$head" ] && git diff --name-only "$sha" "$head" | grep -qv '^openspec/'; then
    echo "$sha stale"; return 0
  fi
  echo "$sha $(count_sev "$RDIR/$sha.md" CRITICAL)"
}

# Parse a "<sha> <critical|stale>" record from covering_review() into the caller's sha/crit locals.
parse_review_result() { read -r sha crit <<<"$1"; }

cmd_status() {
  local head=""
  while [ $# -gt 0 ]; do case "$1" in --head) head="${2:?}"; shift 2;; *) die "unknown option: $1";; esac; done
  head="$(git rev-parse --verify "${head:-HEAD}^{commit}")" || die "unknown commit"
  local res sha crit
  res="$(covering_review "$head")"
  if [ -z "$res" ]; then echo "review=missing head=${head:0:12}"; exit 1; fi
  parse_review_result "$res"
  if [ "$crit" = stale ]; then
    echo "review=stale reviewed=${sha:0:12} head=${head:0:12} (code changed since; run an incremental review with --since $sha)"; exit 1
  fi
  echo "review=recorded reviewed=${sha:0:12} head=${head:0:12} critical=$crit warning=$(count_sev "$RDIR/$sha.md" WARNING) suggestion=$(count_sev "$RDIR/$sha.md" SUGGESTION)"
  [ "$crit" = 0 ] || exit 1
  exit 0
}

cmd_publish() {
  local pr="${1:?pr number required}" confirm=0
  shift
  while [ $# -gt 0 ]; do case "$1" in --confirm) confirm=1; shift;; *) die "unknown option: $1";; esac; done
  command -v gh >/dev/null 2>&1 || die "gh not available"
  local head res sha
  head="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)" || die "cannot read PR #$pr"
  if ! git cat-file -e "$head^{commit}" 2>/dev/null; then
    git fetch --quiet origin "$(gh pr view "$pr" --json headRefName --jq .headRefName)" 2>/dev/null || true
    git cat-file -e "$head^{commit}" 2>/dev/null || die "PR head ${head:0:12} is not available locally (fork PR or fetch failed); fetch it and retry"
  fi
  res="$(covering_review "$head")"
  [ -n "$res" ] || die "no recorded review covers the PR head ${head:0:12}"
  local sha crit
  parse_review_result "$res"
  [ "$crit" != stale ] || die "recorded review ${sha:0:12} is stale for head ${head:0:12}; run an incremental review with --since $sha"
  local body; body="$(mktemp)"
  { echo "**Automated code review** (spec-devflow reviewer agent) for \`${sha:0:12}\`."
    echo "This is an advisory review, not an approval; a human approval is still required."
    echo; sed -n '/^## Findings/,$p' "$RDIR/$sha.md"; } > "$body"
  echo "--- comment preview"; cat "$body"
  if [ "$confirm" != 1 ]; then echo "--- DRY RUN: ask the user, then re-run with --confirm"; rm -f "$body"; exit 0; fi
  local rc=0
  gh pr comment "$pr" --body-file "$body" || rc=$?
  rm -f "$body"
  return "$rc"
}

[ $# -ge 1 ] || die "usage: review.sh context|record|status|publish ..."
sub="$1"; shift
case "$sub" in
  context) cmd_context "$@";;
  record) cmd_record "$@";;
  status) cmd_status "$@";;
  publish) cmd_publish "$@";;
  *) die "unknown subcommand: $sub";;
esac
