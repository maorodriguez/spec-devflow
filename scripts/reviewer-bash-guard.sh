#!/usr/bin/env bash
# reviewer-bash-guard.sh — Claude Code PreToolUse hook for the devflow-reviewer agent.
# The reviewer must stay read-only, so its Bash tool runs a small ALLOWLIST: every command in the
# line must be a known read-only command (or an exact test/lint invocation), otherwise the call is
# blocked. Reads the hook's JSON payload from stdin ({"tool_input": {"command": "..."}, ...});
# exit 2 blocks the tool call, anything else allows it.
#
# The command is tokenized quote-aware (single quotes, double quotes, backslashes) and split into
# segments at ; & | ( ) and newlines. Each segment's command word must be a bare name on the
# allowlist (no paths, no expansions). The allowed commands have no write or exec options
# (ls cat head tail wc cut tr nl tac column diff cmp jq grep stat ...); commands that do (find,
# sed, sort, rg, date, file, ...) are deliberately NOT on the list. For git, gh, openspec, the
# test runners and review.sh every argument must be a literal word (no $expansions, globs or
# braces, which could smuggle in an option), and git only runs read-only subcommands.
# Blocked outright: command and process substitution ($( ) ` <( )), redirections other than
# 2>&1 and >/dev/null, environment assignments before a command (GIT_CONFIG_*, ...), paths as
# command names, unterminated quotes and unparseable payloads. Unknown commands and unknown git
# subcommands are denied, so git aliases from the user's config cannot be used either.
# Test commands: exact `npm test`, `npm run test|lint|typecheck|check`, `go test|vet [./pkg/...]`,
# `cargo test|clippy|check`, `make test|check|lint`, `pytest` with a few flags, `shellcheck`, and the
# exact DEVFLOW_TEST_CMD read from the MAIN worktree's .spec-devflow.conf (never from the
# worktree under review). Limit: those runners execute the project's own code, and review.sh is
# whatever copy the reviewed change contains; review untrusted changes in a sandbox.
set -uo pipefail

READ_CMDS=" ls cat head tail wc cut tr nl tac column diff cmp jq grep egrep fgrep stat pwd echo printf true false basename dirname realpath readlink cd test [ [[ : "
GIT_SUBS=" status log diff show rev-parse rev-list ls-files ls-tree cat-file blame shortlog describe merge-base name-rev grep diff-tree diff-index for-each-ref show-ref count-objects check-ignore whatchanged range-diff show-branch var version cherry "
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

# Redirections that cannot write anywhere are dropped before tokenizing; each must be a whole token
# (`>&1foo` and `>/dev/nullx` are file redirections and stay in the text, where `>` is then blocked).
B='([[:space:];&|)]|$)'
cmd="$(printf '%s' "$cmd" | sed -E "s/[0-9]*>&([0-9]+|-)$B/\\2/g; s/&?[0-9]*>>?[[:space:]]*\\/dev\\/null$B/\\1/g")"

# --- trusted test command (main worktree only) -----------------------------------------------
TEST_CMD=""
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common" ] && [ -f "${common%/.git}/.spec-devflow.conf" ]; then
  TEST_CMD="$(sed -n 's/^DEVFLOW_TEST_CMD=//p' "${common%/.git}/.spec-devflow.conf" | head -n1 | sed -E "s/^[\"']//; s/[\"']\$//")"
fi

# --- per-command checks --------------------------------------------------------------------------
W=(); D=(); G=()      # words, "came from an expansion", "contains an unquoted glob/brace"
nargs=0

# Every word from index $1 on must be literal: no $expansion, unquoted glob or brace expansion.
literal_args() { local k="$1"; while [ "$k" -lt "$nargs" ]; do
  if [ "${D[$k]}" != 0 ] || [ "${G[$k]}" != 0 ]; then block "arguments of '${W[$1-1]}' must be literal words (no \$var, unquoted *?[ or {})"; fi
  k=$((k+1)); done; }

# Is any argument (from index $1 on) one of the given globs? usage: has_arg <from> <glob>...
has_arg() { local k="$1" p a; shift; while [ "$k" -lt "$nargs" ]; do a="${W[$k]}"; for p in "$@"; do case "$a" in $p) return 0;; esac; done; k=$((k+1)); done; return 1; }

# Each word from index $1 on must be a path/package (./..., a/b) or one of the given literal flags.
only_paths_or() { local k="$1" a f ok; shift; while [ "$k" -lt "$nargs" ]; do a="${W[$k]}"; ok=0
  case "$a" in -*) for f in "$@"; do [ "$a" != "$f" ] || ok=1; done;; *[!A-Za-z0-9_./:@-]*) ;; *) ok=1;; esac
  [ "$ok" = 1 ] || block "argument '$a' is not allowed here"; k=$((k+1)); done; }

check_git() {
  local j="$1" a sub
  literal_args "$j"
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
  # Options that write a file or launch a program, including git's unique-prefix abbreviations
  # (`--open` is `--open-files-in-pager`, `--out` is `--output`, `--ext` is `--ext-diff`).
  has_arg "$j" -o '-O*' '--op*' '--ou*' '--ext*' && block "git option that writes files or runs programs"
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

  # The exact trusted test command (no extra arguments).
  if [ -n "$TEST_CMD" ] && [ "${W[*]:$i}" = "$TEST_CMD" ]; then return 0; fi

  local from=$((i+1)) a1="${W[$((i+1))]:-}" a2="${W[$((i+2))]:-}"
  # review.sh: directly or as `bash <path>`; only context|status
  if [ "$w" = bash ]; then
    case "$a1" in scripts/review.sh|./scripts/review.sh|*/scripts/review.sh) w="$a1"; from=$((from+1)); a1="$a2";; *) block "'bash' may only run review.sh context|status";; esac
  fi
  case "$w" in
    scripts/review.sh|./scripts/review.sh|*/scripts/review.sh)
      case "$a1" in context|status) literal_args "$from"; return 0;; *) block "only 'review.sh context|status' is allowed";; esac;;
    */*) block "commands must be bare names on the allowlist (no paths): $w";;
  esac
  name="$w"
  case "$name" in *[!A-Za-z0-9_.+:\[-]*) block "unexpected characters in command name";; esac

  case "$name" in
    git) check_git "$from"; return 0;;
    openspec) literal_args "$from"; case "$a1" in validate|list|show|status|--version|-v) return 0;; *) block "only 'openspec validate|list|show|status' is allowed";; esac;;
    gh) literal_args "$from"; case "$a1 $a2" in "pr view"|"pr diff"|"pr checks"|"pr list"|"issue view"|"issue list") return 0;; *) block "only read-only 'gh pr|issue view|diff|checks|list' is allowed";; esac;;
    npm|pnpm|yarn)
      case "$nargs:$a1:$a2" in "$((i+2)):test:"|"$((i+2)):t:"|"$((i+3)):run:test"|"$((i+3)):run:lint"|"$((i+3)):run:typecheck"|"$((i+3)):run:check") literal_args "$from"; return 0;; esac
      block "only exactly '$name test' or '$name run test|lint|typecheck|check' is allowed";;
    go) case "$a1" in test|vet) literal_args "$from"; only_paths_or "$((from+1))" -v -short -race; return 0;; *) block "only 'go test|vet [./pkg/...]' is allowed";; esac;;
    cargo) case "$a1" in test|clippy|check) literal_args "$from"; only_paths_or "$((from+1))" --workspace --all; return 0;; *) block "only 'cargo test|clippy|check' is allowed";; esac;;
    make) [ "$nargs" = "$((i+2))" ] || block "only exactly 'make test|check|lint' is allowed"; case "$a1" in test|check|lint) return 0;; *) block "only exactly 'make test|check|lint' is allowed";; esac;;
    pytest) literal_args "$from"; only_paths_or "$from" -q -v -vv -x -s --no-header --tb=short --tb=line --tb=no; return 0;;
    shellcheck) literal_args "$from"; return 0;;
  esac
  case "$READ_CMDS" in *" $name "*) return 0;; esac
  block "'$name' is not on the allowlist"
}

# --- quote-aware tokenizer ----------------------------------------------------------------------
cur=""; curd=0; curg=0; inword=0; q=""; esc=0
nl=$'\n'
flush_word() {
  if [ "$inword" = 1 ]; then W[${#W[@]}]="$cur"; D[${#D[@]}]="$curd"; G[${#G[@]}]="$curg"; fi
  cur=""; curd=0; curg=0; inword=0
}
end_segment() {
  flush_word
  if [ "${#W[@]}" -gt 0 ]; then check_segment; fi
  W=(); D=(); G=()
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
    '*'|'?'|'['|'{') curg=1; inword=1; cur="$cur$c";;
    ';'|'&'|'|'|'('|')'|"$nl") end_segment;;
    '<'|'>') block "redirections and process substitution are not allowed (only 2>&1 and >/dev/null)";;
    ' '|$'\t') flush_word;;
    *) cur="$cur$c"; inword=1;;
  esac
done
[ -z "$q" ] || block "unterminated quote"
end_segment
exit 0
