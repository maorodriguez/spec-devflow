#!/usr/bin/env bash
# devflow-env.sh — environment report for spec-devflow (read-only).
# Output: key=value lines that are easy for an agent to read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error=not_a_git_repo"
  exit 1
fi

kv() { printf '%s=%s\n' "$1" "$2"; }

kv runtime "$(detect_runtime)"
kv repo_toplevel "$(git rev-parse --show-toplevel)"
kv main_worktree "$(main_worktree)"
kv in_linked_worktree "$(in_linked_worktree && echo yes || echo no)"
kv current_branch "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo DETACHED)"
kv default_branch "$(default_branch)"
kv worktree_root "$(worktree_root)"
kv dirty_files "$(git status --porcelain | wc -l | tr -d ' ')"

if has_remote; then kv origin "$(git remote get-url origin)"; else kv origin none; fi

# Orca
if command -v orca >/dev/null 2>&1; then
  if orca status --json >/dev/null 2>&1; then kv orca_available yes; else kv orca_available cli_only_runtime_down; fi
else
  kv orca_available no
fi

# GitHub CLI
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then kv gh authenticated; else kv gh not_authenticated; fi
else
  kv gh missing
fi

# OpenSpec
if command -v openspec >/dev/null 2>&1; then
  kv openspec_version "$(openspec --version 2>/dev/null | head -n1)"
else
  kv openspec_version missing
fi
top="$(git rev-parse --show-toplevel)"
if [ -d "$top/openspec" ]; then kv openspec_dir yes; else kv openspec_dir no; fi
if [ -f "$top/openspec/config.yaml" ] && grep -Eqi '^[[:space:]]*language:[[:space:]]*english' "$top/openspec/config.yaml"; then
  kv openspec_language english
else
  kv openspec_language not_pinned
fi

# Installed OpenSpec commands (to know whether verify etc. exist)
found=""
for f in "$top"/.claude/commands/opsx/*.md "$top"/.opencode/commands/opsx-*.md; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .md)"; n="${n#opsx-}"
  case " $found " in *" $n "*) ;; *) found="$found $n";; esac
done
kv opsx_commands "${found# }"
kv opsx_verify "$(case " $found " in *" verify "*) echo yes;; *) echo no;; esac)"

# openspec-* skills present in both locations (possible duplicates in OpenCode)
dups=""
for d in "$top"/.claude/skills/openspec-*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  [ -d "$top/.opencode/skills/$n" ] && dups="$dups $n"
done
kv duplicate_openspec_skills "${dups# }"

if [ -f "$(main_worktree)/.worktreeinclude" ]; then kv worktreeinclude yes; else kv worktreeinclude no; fi
kv test_cmd "${DEVFLOW_TEST_CMD:-unset}"

# Existing worktrees
echo "worktrees:"
git worktree list | sed 's/^/  /'

# Repo configuration and GitHub merge policy
top_conf="$(git rev-parse --show-toplevel)/.spec-devflow.conf"
if [ -f "$top_conf" ]; then kv devflow_conf "$top_conf"; else kv devflow_conf none; fi
echo "repo_policy:"
bash "$SCRIPT_DIR/repo-policy.sh" | sed 's/^/  /'
