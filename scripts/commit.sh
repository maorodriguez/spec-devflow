#!/usr/bin/env bash
# commit.sh — create a commit with the right identity, trailers and language checks.
#
#   commit.sh -m "<subject>" [-m "<body>"] [--issue N] [--change ID] [--task 2.1]... \
#             [--allow-non-english] [--dry-run] [-- <extra git commit args>]
#
# Stages nothing: stage files yourself (git add <paths>) before calling it.
# human mode:     uses your git config identity, strips AI attribution lines.
# automated mode: sets GIT_AUTHOR_*/GIT_COMMITTER_* for this commit only (actor -> bot -> Claude).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

subject="" body="" issue="" change="" allow_ne=0 dry=0
tasks=()
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m) if [ -z "$subject" ]; then subject="${2:?}"; else body="${body:+$body

}${2:?}"; fi; shift 2;;
    --issue) issue="${2:?}"; shift 2;;
    --change) change="${2:?}"; shift 2;;
    --task) tasks+=("${2:?}"); shift 2;;
    --allow-non-english) allow_ne=1; shift;;
    --dry-run) dry=1; shift;;
    --) shift; extra=("$@"); break;;
    *) die "unknown option: $1";;
  esac
done
[ -n "$subject" ] || die "a subject is required (-m)"

# Isolation guards.
in_linked_worktree || die "refusing to commit in the main checkout; work in a worktree"
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$branch" ] || die "HEAD is detached; switch to the change branch"
[ "$branch" != "$(default_branch)" ] || die "refusing to commit on the default branch ($branch)"

# Conventional Commits subject.
printf '%s' "$subject" | grep -Eq '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: .+' \
  || die "subject must follow Conventional Commits, e.g. 'feat(ui): add theme toggle'"
[ "${#subject}" -le 72 ] || warn "subject is ${#subject} chars (keep it <= 72)"

# English check (heuristic).
if [ "$allow_ne" != 1 ] && printf '%s\n%s' "$subject" "$body" | grep -Eq "$NON_ENGLISH_RE"; then
  die "commit message looks non-English (accented letters or ¿/¡ found). Rewrite it in English, or pass --allow-non-english for proper names."
fi

resolve_identity
if [ "$ID_MODE" = human ] && [ "$ID_STATUS" != ok ]; then
  die "no git identity configured; ask the user to run: git config user.name \"Name\" && git config user.email email"
fi

msg="$(mktemp)"; trap 'rm -f "$msg"' EXIT
{ printf '%s\n' "$subject"; [ -z "$body" ] || printf '\n%s\n' "$body"; } > "$msg"
# In human mode drop any AI attribution a tool may have injected into the body.
if [ "$ID_MODE" = human ]; then
  grep -Ev "$AI_ATTRIBUTION_RE" "$msg" > "$msg.clean" || true; mv "$msg.clean" "$msg"
fi

trailers=()
[ -z "$issue" ] || trailers+=(--trailer "Refs: #$issue")
[ -z "$change" ] || trailers+=(--trailer "OpenSpec-Change: $change")
for t in ${tasks[@]+"${tasks[@]}"}; do trailers+=(--trailer "OpenSpec-Task: $t"); done

git diff --cached --quiet && die "nothing staged; git add the files for this commit first"

echo "identity: $ID_MODE / $ID_NAME <$ID_EMAIL> ($ID_SOURCE)"
if [ "$dry" = 1 ]; then
  echo "--- message"; cat "$msg"; printf '%s\n' ${trailers[@]+"${trailers[@]}"} | paste -sd' ' -; exit 0
fi

if [ "$ID_MODE" = automated ]; then
  GIT_AUTHOR_NAME="$ID_NAME" GIT_AUTHOR_EMAIL="$ID_EMAIL" \
  GIT_COMMITTER_NAME="$ID_NAME" GIT_COMMITTER_EMAIL="$ID_EMAIL" \
    git commit -F "$msg" ${trailers[@]+"${trailers[@]}"} ${extra[@]+"${extra[@]}"}
else
  git commit -F "$msg" ${trailers[@]+"${trailers[@]}"} ${extra[@]+"${extra[@]}"}
fi
git log -1 --format='committed %h by %an <%ae>'
