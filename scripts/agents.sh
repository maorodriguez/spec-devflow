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

# Subcommands the reviewer must not run; keep in sync with scripts/reviewer-bash-guard.sh (DENY_SUBS).
REVIEWER_DENY_GIT="add commit push merge rebase reset checkout switch stash cherry-pick revert tag update-ref commit-tree restore clean pull am apply mv rm"

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
      printf 'temperature: 0.1\npermission:\n  edit: deny\n  bash:\n    "*": allow\n'
      # "*git X*" also matches `cd d && git X` and `/usr/bin/git X`; "*git -* X*" matches `git -C dir X` / `git -c k=v X`.
      for sub in $REVIEWER_DENY_GIT; do printf '    "*git %s*": deny\n    "*git -* %s*": deny\n' "$sub" "$sub"; done;;
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
