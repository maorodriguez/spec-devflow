#!/usr/bin/env bash
# wt.sh — worktree management for spec-devflow.
#
#   wt.sh new <type> <slug> [--issue N] [--base REF] [--from-branch BRANCH] [--orca] [--no-fetch]
#   wt.sh review <pr> [--no-fetch]
#   wt.sh review --branch <branch>          (local review of a branch tip, no PR or remote needed)
#   wt.sh list
#   wt.sh remove <name|path> [--delete-branch]
#
# Principles: never modifies the main checkout (except fetch and worktree metadata),
# never forces deletions, never sets tracking to the default branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

MAIN="$(main_worktree)"
ROOT="$(worktree_root)"
TYPES="feat fix chore docs refactor test perf ci build"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Make sure the worktree root is ignored by git (uses .git/info/exclude: local, not versioned).
ensure_ignored() {
  case "$ROOT" in "$MAIN"/*) ;; *) return 0;; esac
  local rel="${ROOT#"$MAIN"/}"
  if ! git -C "$MAIN" check-ignore -q "$rel/.devflow-probe" 2>/dev/null; then
    local excl
    excl="$(git -C "$MAIN" rev-parse --git-common-dir)/info/exclude"
    case "$excl" in /*) ;; *) excl="$MAIN/$excl";; esac
    mkdir -p "$(dirname "$excl")"
    printf '/%s/\n' "$rel" >> "$excl"
    warn "added '/$rel/' to $excl so worktrees don't show up as untracked files. Consider adding it to .gitignore too."
  fi
}

# Copy the literal paths listed in .worktreeinclude that exist and are git-ignored
# (same rule as Orca; Claude Code also accepts patterns, which are skipped here with a warning).
copy_includes() {
  local dest="$1" f="$MAIN/.worktreeinclude" line
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
    [ -n "$line" ] || continue
    case "$line" in *'*'*|*'?'*|*'['*|'!'*) warn ".worktreeinclude: pattern '$line' skipped (literal paths only)"; continue;; esac
    line="${line#/}"; line="${line%/}"
    if [ ! -e "$MAIN/$line" ]; then continue; fi
    if ! git -C "$MAIN" check-ignore -q -- "$line"; then warn ".worktreeinclude: '$line' is not git-ignored; not copied"; continue; fi
    if [ -e "$dest/$line" ]; then continue; fi
    mkdir -p "$(dirname "$dest/$line")"
    cp -R "$MAIN/$line" "$dest/$line"
    echo "copied: $line"
  done < "$f"
}

fetch_origin() {
  [ "${NO_FETCH:-0}" = 1 ] && return 0
  has_remote || return 0
  git -C "$MAIN" fetch --quiet origin "$@" || warn "git fetch failed; using local refs"
}

cmd_new() {
  [ $# -ge 2 ] || usage 1
  local type="$1" slug="$2"; shift 2
  local issue="" base="" from="" orca=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) issue="${2:?}"; shift 2;;
      --base) base="${2:?}"; shift 2;;
      --from-branch) from="${2:?}"; shift 2;;
      --orca) orca=1; shift;;
      --no-fetch) NO_FETCH=1; shift;;
      *) die "unknown option: $1";;
    esac
  done
  case " $TYPES " in *" $type "*) ;; *) die "invalid type '$type' (use one of: $TYPES)";; esac
  is_kebab "$slug" || die "slug '$slug' must be English kebab-case: ^[a-z0-9]+(-[a-z0-9]+)*\$"
  [ -z "$issue" ] || printf '%s' "$issue" | grep -Eq '^[0-9]+$' || die "--issue must be a number"

  local branch name path
  if [ -n "$from" ]; then
    branch="$from"
  else
    branch="$type/${issue:+$issue-}$slug"
  fi
  name="$type-${issue:+$issue-}$slug"
  git check-ref-format --branch "$branch" >/dev/null || die "invalid branch name: $branch"

  if [ "$orca" = 1 ]; then
    command -v orca >/dev/null 2>&1 || die "--orca requested but the 'orca' CLI is not on PATH"
    local parent="--no-parent"
    in_linked_worktree && parent="--parent-worktree active"
    echo "expected_branch=$branch"
    echo "# Orca derives the branch from the name; check the real branch in the JSON and, if it differs and was not pushed yet, rename it:"
    echo "#   git -C <path> branch -m <expected_branch>"
    # shellcheck disable=SC2086
    exec orca worktree create --name "$name" --setup inherit $parent --json
  fi

  mkdir -p "$ROOT"
  ensure_ignored
  path="$ROOT/$name"
  [ -e "$path" ] && die "$path already exists (use that worktree or remove it with 'wt.sh remove $name')"

  if [ -n "$from" ]; then
    fetch_origin "$from"
    if git show-ref --verify --quiet "refs/heads/$from"; then
      git -C "$MAIN" worktree add "$path" "$from"
    elif git show-ref --verify --quiet "refs/remotes/origin/$from"; then
      git -C "$MAIN" worktree add --track -b "$from" "$path" "origin/$from"
    else
      die "branch '$from' exists neither locally nor on origin"
    fi
  else
    git show-ref --verify --quiet "refs/heads/$branch" && die "branch $branch already exists; use --from-branch $branch"
    if [ -z "$base" ]; then
      local def; def="$(default_branch)"
      fetch_origin "$def"
      if git show-ref --verify --quiet "refs/remotes/origin/$def"; then base="origin/$def"; else base="$def"; fi
    fi
    # --no-track: the branch does NOT track its base; the first push uses -u origin <branch>.
    git -C "$MAIN" worktree add --no-track -b "$branch" "$path" "$base"
  fi

  copy_includes "$path"
  echo "worktree=$path"
  echo "branch=$branch"
  echo "base=${base:-$from}"
}

cmd_review() {
  [ $# -ge 1 ] || usage 1
  local ref path name
  if [ "$1" = "--branch" ]; then
    local b="${2:?branch required}"
    git rev-parse --verify --quiet "$b^{commit}" >/dev/null || die "branch $b not found"
    name="review-$(printf '%s' "$b" | tr '/' '-')"
    ref="$b"
  else
    local pr="$1"; shift
    while [ $# -gt 0 ]; do case "$1" in --no-fetch) NO_FETCH=1; shift;; *) die "unknown option: $1";; esac; done
    printf '%s' "$pr" | grep -Eq '^[0-9]+$' || die "invalid PR number: $pr"
    has_remote || die "no 'origin' remote"
    ref="refs/devflow/pr/$pr"; name="review-pr-$pr"
    if [ "${NO_FETCH:-0}" != 1 ]; then
      git -C "$MAIN" fetch --quiet origin "+pull/$pr/head:$ref" || die "could not fetch pull/$pr/head from origin"
    fi
  fi
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || die "$ref does not exist"
  path="$ROOT/$name"
  mkdir -p "$ROOT"; ensure_ignored
  if [ -e "$path" ]; then
    [ -z "$(git -C "$path" status --porcelain)" ] || die "$path has changes; a review worktree must not be edited"
    git -C "$path" checkout --quiet --detach "$(git rev-parse "$ref^{commit}")"
    echo "updated"
  else
    git -C "$MAIN" worktree add --detach "$path" "$(git rev-parse "$ref^{commit}")"
    copy_includes "$path"
  fi
  echo "worktree=$path"
  echo "head=$(git rev-parse "$ref^{commit}")"
}

cmd_list() {
  local p b
  git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print}' | while IFS= read -r p; do
    [ -d "$p" ] || { echo "$p  (missing on disk; run 'git worktree prune')"; continue; }
    b="$(git -C "$p" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached@$(git -C "$p" rev-parse --short HEAD)")"
    printf '%s\t%s\tchanges=%s\n' "$p" "$b" "$(git -C "$p" status --porcelain | wc -l | tr -d ' ')"
  done
}

cmd_remove() {
  [ $# -ge 1 ] || usage 1
  local target="$1" delbranch=0; shift
  while [ $# -gt 0 ]; do case "$1" in --delete-branch) delbranch=1; shift;; *) die "unknown option: $1";; esac; done
  local path
  case "$target" in
    /*) path="$target";;
    .|..|*/*) path="$(cd "$target" 2>/dev/null && pwd -P || true)";;
    *) if [ -d "$ROOT/$target" ]; then path="$ROOT/$target"; else path="$(cd "$target" 2>/dev/null && pwd -P || true)"; fi;;
  esac
  [ -n "$path" ] && [ -d "$path" ] || die "worktree '$target' not found"
  path="$(cd "$path" && pwd -P)"
  [ "$path" = "$(cd "$MAIN" && pwd -P)" ] && die "refusing to remove the main checkout"
  git worktree list --porcelain | grep -Fqx "worktree $path" || die "$path is not a registered worktree"
  case "$(pwd -P)/" in "$path"/*) die "you are inside $path; leave it before removing it";; esac

  [ -z "$(git -C "$path" status --porcelain)" ] || die "$path has uncommitted changes or untracked files; resolve them first"
  local branch
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$branch" ]; then
    local unpushed
    unpushed="$(git -C "$path" log --oneline "$branch" --not --remotes 2>/dev/null | wc -l | tr -d ' ')"
    [ "$unpushed" = 0 ] || die "branch $branch has $unpushed commit(s) not on any remote; push them or discard them manually"
  fi

  git -C "$MAIN" worktree remove "$path"
  echo "removed: $path"
  if [ "$delbranch" = 1 ] && [ -n "$branch" ]; then
    if git -C "$MAIN" branch -d "$branch" 2>/dev/null; then
      echo "deleted local branch: $branch"
    else
      warn "git does not consider '$branch' merged (common with squash). Check with 'gh pr view' and delete it with 'git branch -D $branch' if appropriate."
    fi
  fi
}

[ $# -ge 1 ] || usage 1
sub="$1"; shift
case "$sub" in
  new) cmd_new "$@";;
  review) cmd_review "$@";;
  list) cmd_list;;
  remove) cmd_remove "$@";;
  -h|--help|help) usage 0;;
  *) die "unknown subcommand: $sub";;
esac
