#!/usr/bin/env bash
# identity.sh — report which identity commits will use (read-only).
#
#   identity.sh            key=value report
#   identity.sh --check    exit 1 if human mode has no usable git identity
#
# Modes:
#   human      (default) the person's own git config user.name / user.email
#   automated  DEVFLOW_AUTOMATED=1 or CI: DEVFLOW_ACTOR_* -> DEVFLOW_BOT_* -> Claude (last resort)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
resolve_identity

echo "mode=$ID_MODE"
echo "status=$ID_STATUS"
echo "name=${ID_NAME:-}"
echo "email=${ID_EMAIL:-}"
echo "source=$ID_SOURCE"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "gh_login=$(gh api user --jq .login 2>/dev/null || echo unknown)"
else
  echo "gh_login=unavailable"
fi

# Claude Code attribution settings (project and local), informational.
top="$(git rev-parse --show-toplevel)"
attr="unset"
for f in "$top/.claude/settings.local.json" "$top/.claude/settings.json" "$HOME/.claude/settings.json"; do
  if [ -f "$f" ] && grep -q '"attribution"' "$f"; then attr="$f"; break; fi
done
echo "claude_attribution_setting=$attr"
hooks_dir="$(git rev-parse --git-path hooks)"
if [ -f "$hooks_dir/commit-msg" ] && grep -q 'spec-devflow' "$hooks_dir/commit-msg"; then
  echo "commit_msg_hook=installed"
else
  echo "commit_msg_hook=absent"
fi

if [ "${1:-}" = "--check" ] && [ "$ID_STATUS" != ok ]; then
  echo "devflow: set your identity first: git config user.name \"Your Name\" && git config user.email you@example.com" >&2
  exit 1
fi
exit 0
