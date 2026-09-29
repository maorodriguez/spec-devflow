#!/usr/bin/env bash
# agents.sh — generate and inspect the per-phase agents (planner, implementer, reviewer).
#
#   agents.sh status                          which agent files exist and which model each declares
#   agents.sh generate [--runtime claude|opencode|both] [--dry-run] [--force]
#
# Generated files (commit them so every worktree and teammate gets them):
#   Claude Code: .claude/agents/devflow-{planner,implementer,reviewer}.md
#   OpenCode:    .opencode/agents/devflow-{planner,implementer,reviewer}.md
# Models come from .spec-devflow.conf / environment (DEVFLOW_<RUNTIME>_MODEL_<PHASE>).
# Only files carrying the spec-devflow marker are overwritten; --force is needed for anything else.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
TOP="$(git rev-parse --show-toplevel)"
SKILL_ABS="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TOP_REAL="$(cd "$TOP" && pwd -P)"
case "$SKILL_ABS/" in "$TOP_REAL"/*) SKILL_REL="${SKILL_ABS#"$TOP_REAL"/}";; *) SKILL_REL="$SKILL_ABS";; esac
MARKER="<!-- managed by spec-devflow agents.sh; edit .spec-devflow.conf and regenerate -->"
AGENTS="planner implementer reviewer"

phase_of() { case "$1" in planner) echo plan;; implementer) echo apply;; reviewer) echo review;; esac; }
desc_of() {
  case "$1" in
    planner) echo "Writes and revises OpenSpec planning artifacts (proposal, design, specs, tasks) in English for a spec-devflow change. Use for the propose/update phase; never implements code.";;
    implementer) echo "Implements tasks of an approved OpenSpec change inside its worktree, committing through spec-devflow's commit.sh. Use for the apply phase and for parallel task workers.";;
    reviewer) echo "Independent, read-only code reviewer for spec-devflow changes. Use after verify and before asking for human review; returns findings in the code-review report format.";;
  esac
}

# OpenCode reviewer allowlist (permission.bash: last matching rule wins, "*" is denied first).
# Verified with OpenCode 1.18: `ls && git commit`, `ls; git commit`, `ls | git commit`, `ls $(git commit)`
# and backtick substitution are each split and denied even though `ls *` is allowed; a redirection
# (`ls > f`) is NOT split, hence the trailing "*>*" deny. Patterns match the raw command text, so quoting
# tricks are only partly covered (see the deny lists below and references/code-review.md).
# Keep in sync with scripts/reviewer-bash-guard.sh (the Claude Code side is stricter).
REVIEWER_ALLOW_CMDS="ls cat head tail wc cut tr nl tac column diff cmp jq grep egrep fgrep stat pwd echo basename dirname realpath readlink"
REVIEWER_ALLOW_GIT="status log diff show rev-parse rev-list ls-files ls-tree cat-file blame shortlog describe merge-base name-rev grep diff-tree diff-index for-each-ref show-ref count-objects check-ignore whatchanged range-diff show-branch var version cherry"
# cmd and "cmd *" (arguments allowed)
REVIEWER_ALLOW_ARGS="openspec validate|openspec list|openspec show|openspec status|gh pr view|gh pr diff|gh pr checks|gh pr list|gh issue view|gh issue list|git branch --list|git stash list|git stash show|git worktree list|shellcheck"
# exactly this command, no arguments
REVIEWER_ALLOW_EXACT="npm test|npm run test|npm run lint|npm run typecheck|npm run check|make test|make check|make lint|go test ./...|go vet ./...|cargo test|cargo clippy|cargo check|pytest|git branch|git branch -a|git branch -r|git branch -v|git branch -vv|git branch --show-current"
# Denied whatever the command: redirections, and git options that write or run programs (incl. git's
# unique-prefix abbreviations: --open=..., --out=..., --ext=...), git with expansions/braces/empty-quote splices.
REVIEWER_DENY_ARGS='*>*|gh *--web*|gh * -w*|gh * -?w*|gh * -??w*|git *-O*|git grep *-?O*|git grep *-??O*|git grep *-???O*|git *--op*|git *--ou*|git *--ext*|git *$*|git *{*|git *""*|git *'"''"'*'

# One "cmd" rule and one "cmd *" rule (a bare glob "cmd*" would also match "cmdevil").
allow_pair() { printf '    %s: allow\n    %s: allow\n' "$(yq_str "$1")" "$(yq_str "$1 *")"; }
allow_exact() { printf '    %s: allow\n' "$(yq_str "$1")"; }
deny_one() { printf '    %s: deny\n' "$(yq_str "$1")"; }
# YAML single-quoted scalar (patterns may contain " and $).
yq_str() { local sq="'"; printf "'%s'" "${1//$sq/$sq$sq}"; }
# Calls "$1" for each item of the |-separated list "$2" (globs such as * must not expand here).
each_item() { local fn="$1" item; local IFS='|'; set -f; for item in $2; do "$fn" "$item"; done; }
# review.sh only through the skill's own path (relative and absolute), never a bare `*scripts/review.sh` glob.
review_allow() {
  local p sub
  for p in "$SKILL_REL/scripts/review.sh" "$SKILL_ABS/scripts/review.sh"; do
    for sub in context status; do allow_pair "$p $sub"; allow_pair "bash $p $sub"; done
  done
}

body_of() {
  local esc; esc="$(printf '%s' "$SKILL_REL" | sed 's/[\\&#]/\\&/g')"
  sed "s#<skill-dir>#$esc#g" "$SKILL_ABS/assets/agents/$1.md"
}

# Shell command that runs the reviewer guard. Inside the project it is anchored on
# $CLAUDE_PROJECT_DIR (falling back to the cwd); it is quoted for the shell, then for YAML.
guard_command() {
  local c
  case "$SKILL_REL" in
    /*) c="\"$SKILL_REL/scripts/reviewer-bash-guard.sh\"";;
    *) c="\"\${CLAUDE_PROJECT_DIR:-.}/$SKILL_REL/scripts/reviewer-bash-guard.sh\"";;
  esac
  printf "'%s'" "${c//\'/\'\'}"
}

render_claude() {
  local a="$1" model tools
  model="$(phase_model claude "$(phase_of "$a")")"
  case "$a" in reviewer) tools="Read, Grep, Glob, Bash";; *) tools="Read, Grep, Glob, Bash, Edit, Write";; esac
  printf -- '---\nname: devflow-%s\ndescription: "%s"\n' "$a" "$(desc_of "$a")"
  [ -z "$model" ] || printf 'model: %s\n' "$model"
  printf 'tools: %s\n' "$tools"
  if [ "$a" = reviewer ]; then
    # Claude Code has no per-command Bash permission (unlike OpenCode's permission.bash),
    # so read-only is enforced with a PreToolUse hook instead of a tools-list restriction.
    printf 'hooks:\n  PreToolUse:\n    - matcher: Bash\n      hooks:\n        - type: command\n          command: %s\n' "$(guard_command)"
  fi
  printf -- '---\n%s\n\n' "$MARKER"
  body_of "$a"
}

render_opencode() {
  local a="$1" model
  model="$(phase_model opencode "$(phase_of "$a")")"
  printf -- '---\ndescription: "%s"\nmode: subagent\n' "$(desc_of "$a")"
  [ -z "$model" ] || printf 'model: %s\n' "$model"
  case "$a" in
    reviewer)
      printf 'temperature: 0.1\npermission:\n  edit: deny\n  bash:\n    "*": deny\n'
      local c sub
      for c in $REVIEWER_ALLOW_CMDS; do allow_pair "$c"; done
      for sub in $REVIEWER_ALLOW_GIT; do allow_pair "git $sub"; done
      each_item allow_pair "$REVIEWER_ALLOW_ARGS"
      each_item allow_exact "$REVIEWER_ALLOW_EXACT"
      review_allow
      # The exact test command from the trusted (main worktree) config.
      case "${DEVFLOW_TEST_CMD:-}" in ''|*[\*\?\[]*) ;; *) allow_exact "$DEVFLOW_TEST_CMD";; esac   # glob characters would act as wildcards
      each_item deny_one "$REVIEWER_DENY_ARGS";;
    planner) printf 'temperature: 0.2\n';;
  esac
  printf -- '---\n%s\n\n' "$MARKER"
  body_of "$a"
}

path_of() { case "$1" in claude) echo "$TOP/.claude/agents/devflow-$2.md";; opencode) echo "$TOP/.opencode/agents/devflow-$2.md";; esac; }

cmd_status() {
  local rt a f m exp managed
  for rt in claude opencode; do
    for a in $AGENTS; do
      f="$(path_of "$rt" "$a")"
      if [ -f "$f" ]; then
        m="$(sed -n '2,12{s/^model:[[:space:]]*//p;}' "$f" | head -n1)"
        grep -qF "$MARKER" "$f" && managed=managed || managed=custom
        exp="$(phase_model "$rt" "$(phase_of "$a")")"
        printf '%s/devflow-%s\tpresent\t%s\tmodel=%s\texpected=%s\n' "$rt" "$a" "$managed" "${m:-inherit}" "${exp:-inherit}"
      else
        printf '%s/devflow-%s\tmissing\n' "$rt" "$a"
      fi
    done
  done
}

cmd_generate() {
  local runtime=both dry=0 force=0 rt a f tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --runtime) runtime="${2:?}"; shift 2;;
      --dry-run) dry=1; shift;;
      --force) force=1; shift;;
      *) die "unknown option: $1";;
    esac
  done
  case "$runtime" in claude|opencode|both) ;; *) die "invalid runtime: $runtime";; esac
  case "$SKILL_REL" in /*) warn "the skill lives outside this project ($SKILL_REL); generated agent files embed that machine-specific path. Install it under .claude/skills/spec-devflow before committing them.";; esac
  for rt in claude opencode; do
    [ "$runtime" = both ] || [ "$runtime" = "$rt" ] || continue
    for a in $AGENTS; do
      f="$(path_of "$rt" "$a")"
      tmp="$(mktemp)"
      "render_$rt" "$a" > "$tmp"
      if [ "$dry" = 1 ]; then echo "===== $f"; cat "$tmp"; rm -f "$tmp"; continue; fi
      if [ -f "$f" ] && ! grep -qF "$MARKER" "$f" && [ "$force" != 1 ]; then
        warn "$f exists and is not managed by spec-devflow; skipped (use --force to replace it)"; rm -f "$tmp"; continue
      fi
      mkdir -p "$(dirname "$f")"
      if [ -f "$f" ] && cmp -s "$tmp" "$f"; then echo "unchanged: ${f#"$TOP"/}"; rm -f "$tmp"
      else mv "$tmp" "$f"; echo "written: ${f#"$TOP"/}"; fi
    done
  done
  [ "$dry" = 1 ] || echo "Review the files and commit them (git add .claude/agents .opencode/agents)."
}

[ $# -ge 1 ] || die "usage: agents.sh status | generate [--runtime claude|opencode|both] [--dry-run] [--force]"
sub="$1"; shift
case "$sub" in
  status) cmd_status;;
  generate) cmd_generate "$@";;
  *) die "unknown subcommand: $sub";;
esac
