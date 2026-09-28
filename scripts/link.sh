#!/usr/bin/env bash
# link.sh — show what already exists for a piece of work (read-only).
#
#   link.sh --change <change-id>
#   link.sh --issue <number>
#   link.sh --pr <number>
#
# Reports: change state (active/archived/absent), linked issue(s), branches, worktrees and PR.
# Uses gh when available; git-only information is always reported.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
[ $# -eq 2 ] || die "usage: link.sh --change <id> | --issue <n> | --pr <n>"
kind="$1"; val="$2"
MAIN="$(main_worktree)"
has_gh=0; command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && has_gh=1
change="" issue="" pr=""

case "$kind" in
  --change) is_kebab "$val" || die "invalid change id: $val"; change="$val";;
  --issue)  printf '%s' "$val" | grep -Eq '^[0-9]+$' || die "--issue must be a number"; issue="$val";;
  --pr)     printf '%s' "$val" | grep -Eq '^[0-9]+$' || die "--pr must be a number"; pr="$val";;
  *) die "unknown option: $kind";;
esac

# Derive the change id from an issue or PR body when possible.
if [ -z "$change" ] && [ "$has_gh" = 1 ]; then
  if [ -n "$issue" ]; then
    change="$(gh issue view "$issue" --json body --jq .body 2>/dev/null | sed -n 's/^OpenSpec-Change:[[:space:]]*`\{0,1\}\([a-z0-9-]*\).*/\1/p' | head -n1)"
  elif [ -n "$pr" ]; then
    change="$(gh pr view "$pr" --json body --jq .body 2>/dev/null | sed -n 's/^OpenSpec-Change:[[:space:]]*`\{0,1\}\([a-z0-9-]*\).*/\1/p' | head -n1)"
  fi
fi
echo "change=${change:-unknown}"

if [ -n "$change" ]; then
  if [ -d "$MAIN/openspec/changes/$change" ]; then echo "change_state=active_on_main_checkout"
  elif find "$MAIN/openspec/changes/archive" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -Eq "/[0-9]{4}-[0-9]{2}-[0-9]{2}-$change\$"; then echo "change_state=archived"
  else echo "change_state=not_on_main_checkout"; fi
fi

# Issues that declare this change.
if [ -z "$issue" ] && [ -n "$change" ] && [ "$has_gh" = 1 ]; then
  issue="$(gh issue list --state all --search "\"OpenSpec-Change: $change\" in:body" --json number --jq '.[].number' 2>/dev/null | paste -sd, -)"
fi
echo "issue=${issue:-none}"

# Branches whose name ends with the change id (or carry the issue number).
pat=""
[ -z "$change" ] || pat="$change"
if [ -n "$pat" ] || [ -n "$issue" ]; then
  has_remote && git -C "$MAIN" fetch --quiet origin 2>/dev/null || true
  branches="$(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin \
    | grep -v '^origin/HEAD$' | sed 's#^origin/##' | sort -u \
    | grep -E "(^|/)([0-9]+-)?${pat:-__none__}$|/${issue%%,*}-" 2>/dev/null | paste -sd, -)"
  echo "branches=${branches:-none}"
fi

# Worktrees on those branches.
wts=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) p="${line#worktree }";;
    "branch refs/heads/"*) b="${line#branch refs/heads/}"
      case ",${branches:-}," in *",$b,"*) wts="${wts:+$wts,}$p";; esac;;
  esac
done <<WT
$(git -C "$MAIN" worktree list --porcelain)
WT
echo "worktrees=${wts:-none}"

# Where the change lives on those branches (it may not be on the default branch yet).
if [ -n "$change" ] && [ -n "${branches:-}" ]; then
  on=""
  for b in $(printf '%s' "$branches" | tr ',' ' '); do
    ref="$b"; git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$b" >/dev/null || ref="origin/$b"
    if git -C "$MAIN" cat-file -e "$ref:openspec/changes/$change/proposal.md" 2>/dev/null; then on="${on:+$on,}$b"; fi
  done
  echo "change_active_on_branches=${on:-none}"
fi

# PR for the branch (or the one given).
if [ "$has_gh" = 1 ]; then
  if [ -z "$pr" ] && [ -n "${branches:-}" ]; then
    for b in $(printf '%s' "$branches" | tr ',' ' '); do
      pr="$(gh pr list --state all --head "$b" --json number,state --jq '.[] | "#\(.number) \(.state)"' 2>/dev/null | head -n1)"
      [ -n "$pr" ] && break
    done
  elif [ -n "$pr" ]; then
    pr="#$pr $(gh pr view "${pr#\#}" --json state,headRefName --jq '"\(.state) \(.headRefName)"' 2>/dev/null)"
  fi
  echo "pr=${pr:-none}"
else
  echo "pr=unknown (gh unavailable)"
fi
