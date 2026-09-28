#!/usr/bin/env bash
# setup.sh — one-step project setup after installing the skill.
#
#   setup.sh [--hooks] [--runtime claude|opencode|both]
#
# Runs from inside the target project (any subdirectory): initializes OpenSpec if missing,
# generates the planner/implementer/reviewer agents and, with --hooks, installs the commit-msg
# hook that strips AI attribution. Nothing is committed; review and commit the result yourself.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

hooks=0 runtime=both
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) hooks=1; shift;;
    --runtime) runtime="${2:?}"; shift 2;;
    *) die "unknown option: $1";;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
TOP="$(git rev-parse --show-toplevel)"
cd "$TOP"

if [ -d openspec ]; then
  echo "openspec: already initialized"
else
  command -v openspec >/dev/null 2>&1 || die "openspec not found; install it first: npm i -g @fission-ai/openspec"
  tools="claude,opencode"
  case "$runtime" in claude) tools=claude;; opencode) tools=opencode;; esac
  openspec init --tools "$tools"
fi

bash "$SCRIPT_DIR/agents.sh" generate --runtime "$runtime"
[ "$hooks" != 1 ] || bash "$SCRIPT_DIR/install-hooks.sh"

echo "done. Review and commit: git add .claude .opencode openspec && git commit -m 'chore: add spec-devflow'"
