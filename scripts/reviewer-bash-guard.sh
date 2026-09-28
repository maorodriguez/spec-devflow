#!/usr/bin/env bash
# reviewer-bash-guard.sh — Claude Code PreToolUse hook for the devflow-reviewer agent.
# The reviewer must stay read-only; this denies git commands that would mutate repo state.
# Reads the hook's JSON payload from stdin ({"tool_input": {"command": "..."}, ...});
# exit 2 blocks the tool call, anything else allows it.
#
# The command is split into segments (; & | ( ) ` and newlines; backslash-newline is joined first),
# and in each segment every token whose basename is `git` is parsed: global options are skipped
# (those taking a value consume it), then the subcommand is checked against the denylist. Quotes,
# backslashes and `$` are stripped from tokens before matching, so `git co""mmit`, `git c\ommit`,
# `git $'commit'`, `git -C dir commit`, `/usr/bin/git commit`, `cd x && git commit`, `$(git commit)`
# and `sh -c 'git commit'` are all caught. It fails closed when the payload cannot be parsed, when
# the subcommand is built from an expansion (`git $x`), and for `-c`/`--config-env` alias keys
# (case-insensitive) or `git config`, so an alias cannot be defined and then used.
# Limits: aliases already present in the user's git config are not resolved, and the shell can
# still build a command dynamically (`eval "$(...)"`, `xargs`, scripts); treat this as a guard
# against accidents, not as a security boundary.
set -uo pipefail

DENY_SUBS=" add commit push merge rebase reset checkout switch stash cherry-pick revert tag update-ref commit-tree restore clean pull am apply mv rm worktree symbolic-ref gc prune config bisect notes replace update-index read-tree submodule sparse-checkout filter-branch "
OPT_WITH_ARG=" -C -c --git-dir --work-tree --namespace --exec-path --super-prefix --config-env "
BRANCH_READ_OPTS=" -a -r -v -vv --list -l --show-current --all --remotes --no-color --color "

block() { echo "blocked: devflow-reviewer must stay read-only; $1" >&2; exit 2; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
# Drop shell quoting characters so `co""mmit`, `c\ommit` and `$'commit'` compare as `commit`.
plain() { printf '%s' "$1" | tr -d "\"'\\\\\$"; }

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -er '.tool_input.command // empty' 2>/dev/null)" || {
    [ -z "$input" ] || printf '%s' "$input" | jq -e . >/dev/null 2>&1 || block "cannot parse the hook payload"
    cmd=""
  }
else
  cmd="$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n1)"
  [ -n "$cmd" ] || [ -z "$input" ] || block "cannot parse the hook payload (install jq)"
  case "$cmd" in *'\u'*) block "cannot decode unicode escapes without jq (install jq)";; esac
  # Decode the JSON string escapes that matter: \\ \" \n \t \r \/ (newline becomes a command separator;
  # backslash + newline is a line continuation and is dropped).
  cmd="$(printf '%s' "$cmd" | sed -e 's/\\\\\\n//g' -e 's/\\\\/@@BS@@/g' -e 's/\\"/"/g' -e 's/\\n/;/g' -e 's/\\t/ /g' -e 's/\\r/ /g' -e 's#\\/#/#g' -e 's/@@BS@@/\\/g')"
fi
[ -n "$cmd" ] || exit 0

# Join backslash-newline continuations, then split into segments.
nl=$'\n'
joined="${cmd//\\$nl/}"
segments="$(printf '%s' "$joined" | tr ';&|()`' '\n')"
while IFS= read -r line; do
  set -f; set -- $line; set +f
  found=0
  while [ $# -gt 0 ]; do
    t="$(plain "$1")"
    if [ "$found" = 0 ]; then
      [ "${t##*/}" != git ] || found=1
      shift; continue
    fi
    case "$OPT_WITH_ARG" in
      *" $t "*)
        if [ $# -ge 2 ]; then
          case "$t" in -c|--config-env) case "$(lower "$(plain "$2")")" in *alias.*) block "git alias definitions are not allowed";; esac;; esac
          shift 2
        else shift; fi
        continue;;
    esac
    case "$(lower "$t")" in *alias.*) block "git alias definitions are not allowed";; esac
    case "$t" in -*) shift; continue;; esac
    case "$1" in *'$'*|*'`'*) block "cannot resolve the git subcommand '$1'";; esac
    sub="$t"; shift
    case "$DENY_SUBS" in *" $sub "*) block "'git $sub' is not allowed here";; esac
    if [ "$sub" = branch ]; then
      for a in "$@"; do
        case "$BRANCH_READ_OPTS" in *" $(plain "$a") "*) ;; *) block "'git branch $a' may modify branches";; esac
      done
    fi
    break
  done
done <<< "$segments"
exit 0
