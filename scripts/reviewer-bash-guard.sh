#!/usr/bin/env bash
# reviewer-bash-guard.sh — Claude Code PreToolUse hook for the devflow-reviewer agent.
# The reviewer must stay read-only; this denies git commands that would mutate repo state.
# Reads the hook's JSON payload from stdin ({"tool_input": {"command": "..."}, ...});
# exit 2 blocks the tool call, anything else allows it.
set -uo pipefail
input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
else
  cmd="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -n1)"
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(add|commit|push|merge|rebase|reset|checkout|switch|stash|cherry-pick|revert|tag)\b'; then
  echo "blocked: devflow-reviewer must stay read-only; git write commands are not allowed here" >&2
  exit 2
fi
exit 0
