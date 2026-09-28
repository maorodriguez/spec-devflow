#!/usr/bin/env bash
# reviewer-bash-guard.sh — Claude Code PreToolUse hook for the devflow-reviewer agent.
# The reviewer must stay read-only, so its Bash tool runs an ALLOWLIST: every command in the line
# must be a known read-only (or test/lint) command, otherwise the call is blocked.
# Reads the hook's JSON payload from stdin ({"tool_input": {"command": "..."}, ...});
# exit 2 blocks the tool call, anything else allows it.
#
# The command is tokenized quote-aware (single quotes, double quotes, backslashes) and split into
# segments at ; & | ( ) and newlines. Each segment's command word must be a bare name on the
# allowlist (no paths, no expansions) and its arguments are checked per command: git only runs
# read-only subcommands with a few safe global options, find/rg/sed/sort/... lose their
# write/exec flags, gh/openspec/npm/... are limited to read/test/lint subcommands.
# Blocked outright: command and process substitution ($( ) ` <( )), redirections other than
# 2>&1 and >/dev/null, environment assignments before a command (GIT_CONFIG_*, ...), a git
# subcommand or option built from a variable, unterminated quotes, and unparseable payloads.
# Because unknown commands and unknown git subcommands are denied, git aliases from the user's
# config cannot be used either. Test commands: the builtin runners below, plus DEVFLOW_TEST_CMD
# read from the MAIN worktree's .spec-devflow.conf (never from the worktree under review).
# Limit: allowed test/lint runners execute the project's own code; that is inherent to running tests.
set -uo pipefail

READ_CMDS=" ls cat head tail wc sort uniq cut tr nl tac column diff cmp file stat pwd echo printf true false basename dirname realpath readlink date cd test [ [[ : grep egrep fgrep rg jq "
GIT_SUBS=" status log diff show rev-parse rev-list ls-files ls-tree cat-file blame shortlog describe merge-base name-rev grep diff-tree diff-index for-each-ref show-ref count-objects check-ignore whatchanged range-diff show-branch var version help cherry "
BRANCH_READ_OPTS=" -a -r -v -vv --list -l --show-current --all --remotes --no-color --color "

block() { echo "blocked: devflow-reviewer is read-only and runs on an allowlist; $1" >&2; exit 2; }

# --- payload -> command string -------------------------------------------------------------
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
  # Decode the JSON string escapes left to right: \\ \" \n \t \r \/ (anything else is kept as is).
  raw="$cmd"; cmd=""; k=0; len=${#raw}
  while [ "$k" -lt "$len" ]; do
    ch="${raw:$k:1}"; k=$((k+1))
    if [ "$ch" = '\' ] && [ "$k" -lt "$len" ]; then
      ch="${raw:$k:1}"; k=$((k+1))
      case "$ch" in n) ch=$'\n';; t|r) ch=" ";; esac
    fi
    cmd="$cmd$ch"
  done
fi
[ -n "$cmd" ] || exit 0

# Redirections that cannot write anywhere useful are dropped before tokenizing.
cmd="$(printf '%s' "$cmd" | sed -E 's/[0-9]*>&[0-9-]//g; s/&?[0-9]*>>?[[:space:]]*\/dev\/null//g')"

# --- trusted test command (main worktree only) -----------------------------------------------
TEST_CMD=""
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common" ] && [ -f "${common%/.git}/.spec-devflow.conf" ]; then
  TEST_CMD="$(sed -n 's/^DEVFLOW_TEST_CMD=//p' "${common%/.git}/.spec-devflow.conf" | head -n1 | sed -E "s/^[\"']//; s/[\"']$//")"
fi

# --- per-command checks --------------------------------------------------------------------------
W=(); D=()
nargs=0

# Is any argument (from index $1 on) one of the given globs? usage: has_arg <from> <glob>...
has_arg() { local k="$1" p a; shift; while [ "$k" -lt "$nargs" ]; do a="${W[$k]}"; for p in "$@"; do case "$a" in $p) return 0;; esac; done; k=$((k+1)); done; return 1; }

check_git() {
  local j="$1" a sub
  while [ "$j" -lt "$nargs" ]; do
    a="${W[$j]}"
    case "$a" in
      -C) [ $((j+1)) -lt "$nargs" ] || block "git -C needs a directory"; j=$((j+2));;
      --no-pager|--no-optional-locks|-P|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) j=$((j+1));;
      -*) block "git option '$a' is not allowed";;
      *) break;;
    esac
  done
  [ "$j" -lt "$nargs" ] || return 0
  sub="${W[$j]}"
  [ "${D[$j]}" = 0 ] || block "the git subcommand must not come from an expansion"
  j=$((j+1))
  case "$sub" in
    branch)
      while [ "$j" -lt "$nargs" ]; do
        case "$BRANCH_READ_OPTS" in *" ${W[$j]} "*) ;; *) block "'git branch ${W[$j]}' may modify branches";; esac
        j=$((j+1))
      done;;
    worktree) [ "${W[$j]:-}" = list ] || block "only 'git worktree list' is allowed";;
    stash) case "${W[$j]:-}" in list|show) ;; *) block "only 'git stash list|show' is allowed";; esac;;
    *) case "$GIT_SUBS" in *" $sub "*) ;; *) block "'git $sub' is not on the allowlist (read-only git only)";; esac;;
  esac
  # Read-only subcommands that can still write a file or launch a program.
  has_arg "$j" '--output' '--output=*' '-o' '-O*' '--open-files-in-pager*' '--ext-diff' && block "git option that writes files or runs programs"
  return 0
}

check_segment() {
  local i=0 w name
  nargs=${#W[@]}
  while [ "$i" -lt "$nargs" ]; do
    case "${W[$i]}" in do|then|else|elif|if|while|until|'!'|'{') i=$((i+1));; *) break;; esac
  done
  [ "$i" -lt "$nargs" ] || return 0
  w="${W[$i]}"
  case "$w" in done|fi|esac|'}'|for) return 0;; esac
  [ "${D[$i]}" = 0 ] || block "the command name must not come from an expansion"
  case "$w" in *=*) block "environment assignments before a command are not allowed";; esac

  if [ -n "$TEST_CMD" ]; then
    local text="${W[*]:$i}"
    case "$text" in "$TEST_CMD"|"$TEST_CMD "*) return 0;; esac
  fi

  local a1="${W[$((i+1))]:-}" a2="${W[$((i+2))]:-}"
  # review.sh, directly or through bash/sh
  case "$w" in
    bash|sh)
      if [ "$a1" = -n ] && [ -n "$a2" ]; then return 0; fi
      case "$a1" in scripts/review.sh|./scripts/review.sh|*/scripts/review.sh) w="$a1"; i=$((i+1)); a1="$a2";; *) block "'$w' may only run 'bash -n <file>' or review.sh context|status";; esac;;
  esac
  case "$w" in
    scripts/review.sh|./scripts/review.sh|*/scripts/review.sh)
      case "$a1" in context|status) return 0;; *) block "only 'review.sh context|status' is allowed";; esac;;
    */*) block "commands must be bare names on the allowlist (no paths): $w";;
  esac
  name="$w"
  case "$name" in *[!A-Za-z0-9_.+:\[-]*) block "unexpected characters in command name";; esac

  local from=$((i+1))
  case "$name" in
    git) check_git "$from"; return 0;;
    find) has_arg "$from" -exec -execdir -ok -okdir -delete '-fprint*' -fls && block "find with -exec/-delete/-fprint is not allowed"; return 0;;
    rg) has_arg "$from" '--pre*' '--hostname-bin*' -z --search-zip && block "rg option that runs programs"; return 0;;
    sort) has_arg "$from" '-o*' '--output*' && block "sort -o writes a file"; return 0;;
    date) has_arg "$from" -s '--set*' && block "date -s sets the clock"; return 0;;
    uniq) local pos=0 k="$from"; while [ "$k" -lt "$nargs" ]; do case "${W[$k]}" in -*) ;; *) pos=$((pos+1));; esac; k=$((k+1)); done
          [ "$pos" -le 1 ] || block "uniq with an output file writes a file"; return 0;;
    sed)
      has_arg "$from" '-i*' '--in-place*' '-f' '--file*' '-e' '--expression*' && block "sed may only print line ranges: sed -n '10,20p' file"
      local k="$from" script=""
      while [ "$k" -lt "$nargs" ]; do case "${W[$k]}" in -*) ;; *) script="${W[$k]}"; break;; esac; k=$((k+1)); done
      case "$script" in ''|*[!0-9,\$pq]*) block "sed may only print line ranges: sed -n '10,20p' file";; esac
      return 0;;
    openspec) case "$a1" in validate|list|show|status|--version|-v) return 0;; *) block "only 'openspec validate|list|show|status' is allowed";; esac;;
    gh)
      case "$a1 $a2" in "pr view"|"pr diff"|"pr checks"|"pr list"|"issue view"|"issue list") return 0;; *) block "only read-only 'gh pr|issue view|diff|checks|list' is allowed";; esac;;
    npm|pnpm|yarn)
      case "$a1" in test|t) return 0;; run) case "$a2" in test|lint|typecheck|check) return 0;; esac;; esac
      block "only '$name test' and '$name run test|lint|typecheck|check' are allowed";;
    go) case "$a1" in test|vet) return 0;; *) block "only 'go test|vet' is allowed";; esac;;
    cargo) case "$a1" in test|clippy|check) return 0;; *) block "only 'cargo test|clippy|check' is allowed";; esac;;
    make) case "$a1" in test|check|lint) return 0;; *) block "only 'make test|check|lint' is allowed";; esac;;
    pytest|shellcheck) return 0;;
  esac
  case "$READ_CMDS" in *" $name "*) return 0;; esac
  block "'$name' is not on the allowlist"
}

# --- quote-aware tokenizer ----------------------------------------------------------------------
cur=""; curd=0; inword=0; q=""; esc=0
nl=$'\n'
flush_word() {
  if [ "$inword" = 1 ]; then W[${#W[@]}]="$cur"; D[${#D[@]}]="$curd"; fi
  cur=""; curd=0; inword=0
}
end_segment() {
  flush_word
  if [ "${#W[@]}" -gt 0 ]; then check_segment; fi
  W=(); D=()
}

n=${#cmd}; pos=0
while [ "$pos" -lt "$n" ]; do
  c="${cmd:$pos:1}"; pos=$((pos+1))
  if [ "$esc" = 1 ]; then
    esc=0
    [ "$c" = "$nl" ] && continue          # backslash-newline: line continuation
    cur="$cur$c"; inword=1; continue
  fi
  case "$q" in
    "'") if [ "$c" = "'" ]; then q=""; else cur="$cur$c"; fi; continue;;
    '"')
      case "$c" in
        '"') q="";;
        '\') esc=1;;
        '`') block "command substitution is not allowed";;
        '$') [ "${cmd:$pos:1}" != "(" ] || block "command substitution is not allowed"; curd=1; cur="$cur$c";;
        *) cur="$cur$c";;
      esac
      continue;;
  esac
  case "$c" in
    '\') esc=1; inword=1;;
    "'") q="'"; inword=1;;
    '"') q='"'; inword=1;;
    '`') block "command substitution is not allowed";;
    '$') [ "${cmd:$pos:1}" != "(" ] || block "command substitution is not allowed"; curd=1; inword=1; cur="$cur$c";;
    ';'|'&'|'|'|'('|')'|"$nl") end_segment;;
    '<'|'>') block "redirections and process substitution are not allowed (only 2>&1 and >/dev/null)";;
    ' '|$'\t') flush_word;;
    *) cur="$cur$c"; inword=1;;
  esac
done
[ -z "$q" ] || block "unterminated quote"
end_segment
exit 0
