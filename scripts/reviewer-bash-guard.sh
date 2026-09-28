#!/usr/bin/env bash
# reviewer-bash-guard.sh — Claude Code PreToolUse hook for the devflow-reviewer agent.
# The reviewer must stay read-only; this denies git commands that would mutate repo state.
# Reads the hook's JSON payload from stdin ({"tool_input": {"command": "..."}, ...});
# exit 2 blocks the tool call, anything else allows it.
#
# The command is split into segments (; & | ( ) `), and in each segment every token whose basename
# is `git` is parsed: global options are skipped (those taking a value consume it), then the
# subcommand is checked against the denylist. So `git -C dir commit`, `/usr/bin/git commit`,
# `cd x && git commit`, `$(git commit)` and `sh -c 'git commit'` are all caught. If the payload
# cannot be parsed the guard fails closed. It does not resolve git aliases from config.
set -uo pipefail

DENY_SUBS=" add commit push merge rebase reset checkout switch stash cherry-pick revert tag update-ref commit-tree restore clean pull am apply mv rm worktree symbolic-ref gc prune "
OPT_WITH_ARG=" -C -c --git-dir --work-tree --namespace --exec-path --super-prefix --config-env "
BRANCH_READ_OPTS=" -a -r -v -vv --list -l --show-current --all --remotes --no-color --color "

block() { echo "blocked: devflow-reviewer must stay read-only; $1" >&2; exit 2; }

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
else
  cmd="$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n1)"
  [ -n "$cmd" ] || [ -z "$input" ] || block "cannot parse the hook payload (install jq)"
fi
[ -n "$cmd" ] || exit 0

segments="$(printf '%s' "$cmd" | tr ';&|()`' '\n')"
while IFS= read -r line; do
  set -f; set -- $line; set +f
  found=0
  while [ $# -gt 0 ]; do
    t="${1#[\'\"]}"; t="${t%[\'\"]}"
    if [ "$found" = 0 ]; then
      [ "${t##*/}" != git ] || found=1
      shift; continue
    fi
    case "$OPT_WITH_ARG" in
      *" $t "*)
        if [ "$t" = -c ] && [ $# -ge 2 ]; then case "$2" in alias.*|\"alias.*|\'alias.*) block "git alias definitions are not allowed";; esac; fi
        [ $# -ge 2 ] && shift 2 || shift; continue;;
    esac
    case "$t" in -*) shift; continue;; esac
    sub="$t"; shift
    case "$DENY_SUBS" in *" $sub "*) block "'git $sub' is not allowed here";; esac
    if [ "$sub" = branch ]; then
      for a in "$@"; do
        case "$BRANCH_READ_OPTS" in *" $a "*) ;; *) block "'git branch $a' may modify branches";; esac
      done
    fi
    break
  done
done <<< "$segments"
exit 0
