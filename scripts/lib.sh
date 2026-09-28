# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file
# lib.sh — shared helpers for spec-devflow. Source it with `.`; do not execute it directly.
# Works with bash 3.2+ (macOS) and Linux.

die() { echo "devflow: $*" >&2; exit 1; }
warn() { echo "devflow: warning: $*" >&2; }

# Shared check-report convention for scripts that run a list of pass/fail checks
# (preflight.sh, merge.sh). Each script must set its own `fail=0` before use.
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fail=1; }
note() { echo "  info  $*"; }

# Agent runtime. Heuristic based on environment variables; override with DEVFLOW_RUNTIME.
detect_runtime() {
  if [ -n "${DEVFLOW_RUNTIME:-}" ]; then echo "$DEVFLOW_RUNTIME"; return; fi
  if [ -n "${CLAUDECODE:-}" ]; then echo claude; return; fi
  if [ -n "${OPENCODE:-}${OPENCODE_CLIENT:-}" ]; then echo opencode; return; fi
  echo unknown
}

# First entry of `git worktree list` is the main checkout.
main_worktree() {
  git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print; exit}'
}

# Are we inside a linked worktree (not the main checkout)?
in_linked_worktree() {
  local gd cd
  gd="$(cd "$(git rev-parse --git-dir)" && pwd -P)"
  cd="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  [ "$gd" != "$cd" ]
}

has_remote() { git remote get-url origin >/dev/null 2>&1; }

default_branch() {
  local ref
  if [ -n "${DEVFLOW_DEFAULT_BRANCH:-}" ]; then echo "$DEVFLOW_DEFAULT_BRANCH"; return; fi
  ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "${ref#origin/}"; return; }
  for b in main master trunk; do
    if git show-ref --verify --quiet "refs/remotes/origin/$b" || git show-ref --verify --quiet "refs/heads/$b"; then
      echo "$b"; return
    fi
  done
  echo main
}

# Folder where worktrees are created.
#  - DEVFLOW_WORKTREE_ROOT (relative to the main checkout, or absolute) wins.
#  - Claude Code: .claude/worktrees (EnterWorktree needs no extra approval there and enforces isolation).
#  - Anything else: .worktrees
worktree_root() {
  local main root
  main="$(main_worktree)"
  if [ -n "${DEVFLOW_WORKTREE_ROOT:-}" ]; then
    root="$DEVFLOW_WORKTREE_ROOT"
  elif [ "$(detect_runtime)" = claude ]; then
    root=".claude/worktrees"
  else
    root=".worktrees"
  fi
  case "$root" in /*) echo "$root";; *) echo "$main/$root";; esac
}

is_kebab() { printf '%s' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; }

# ---------- identity ----------
# human mode: the person's own git identity. automated mode: actor -> bot -> Claude (last resort).
CLAUDE_NAME="Claude"
CLAUDE_EMAIL="noreply@anthropic.com"

is_automated() {
  [ "${DEVFLOW_AUTOMATED:-0}" = 1 ] && return 0
  case "${CI:-}" in true|1) return 0;; esac
  [ -n "${GITHUB_ACTIONS:-}" ] && return 0
  return 1
}

# Sets ID_MODE, ID_NAME, ID_EMAIL, ID_SOURCE, ID_STATUS (ok|missing).
resolve_identity() {
  ID_STATUS=ok
  if is_automated; then
    ID_MODE=automated
    if [ -n "${DEVFLOW_ACTOR_NAME:-}" ] && [ -n "${DEVFLOW_ACTOR_EMAIL:-}" ]; then
      ID_NAME="$DEVFLOW_ACTOR_NAME"; ID_EMAIL="$DEVFLOW_ACTOR_EMAIL"; ID_SOURCE=actor
    elif [ -n "${DEVFLOW_BOT_NAME:-}" ] && [ -n "${DEVFLOW_BOT_EMAIL:-}" ]; then
      ID_NAME="$DEVFLOW_BOT_NAME"; ID_EMAIL="$DEVFLOW_BOT_EMAIL"; ID_SOURCE=bot
    else
      ID_NAME="$CLAUDE_NAME"; ID_EMAIL="$CLAUDE_EMAIL"; ID_SOURCE=claude-fallback
    fi
  else
    ID_MODE=human
    ID_NAME="$(git config --get user.name 2>/dev/null || true)"
    ID_EMAIL="$(git config --get user.email 2>/dev/null || true)"
    ID_SOURCE=git-config
    if [ -z "$ID_NAME" ] || [ -z "$ID_EMAIL" ]; then ID_STATUS=missing; fi
  fi
}

# Lines that attribute authorship to an AI tool; stripped in human mode.
AI_ATTRIBUTION_RE='^(Co-[Aa]uthored-[Bb]y:.*(Claude|anthropic\.com|[Oo]pen[Cc]ode)|.*Generated with \[?(Claude Code|opencode|OpenCode)|Claude-Session:)'

# Rough non-English detector: accented Latin letters and Spanish punctuation.
# Alternation of whole characters (not a bracket class) so it also works byte-wise in the C locale.
NON_ENGLISH_RE='(á|é|í|ó|ú|Á|É|Í|Ó|Ú|ñ|Ñ|ü|Ü|¿|¡|à|è|ì|ò|ù|ç|ã|õ|â|ê|ô|À|È|Ì|Ò|Ù|Ç|Ã|Õ|Â|Ê|Ô)'

# ---------- repo configuration ----------
# Optional committed file at the repo root: .spec-devflow.conf (KEY=value lines, no shell evaluation).
# Environment variables override it. Only whitelisted keys are read.
DEVFLOW_CONF_KEYS="DEVFLOW_ARCHIVE_TIMING DEVFLOW_MERGE_STRATEGY DEVFLOW_AUTO_MERGE DEVFLOW_TEST_CMD DEVFLOW_WORKTREE_ROOT DEVFLOW_DEFAULT_BRANCH
 DEVFLOW_REQUIRE_AGENT_REVIEW
 DEVFLOW_CLAUDE_MODEL_PLAN DEVFLOW_CLAUDE_MODEL_APPLY DEVFLOW_CLAUDE_MODEL_TASK DEVFLOW_CLAUDE_MODEL_REVIEW
 DEVFLOW_OPENCODE_MODEL_PLAN DEVFLOW_OPENCODE_MODEL_APPLY DEVFLOW_OPENCODE_MODEL_TASK DEVFLOW_OPENCODE_MODEL_REVIEW"
load_config() {
  local top f key line val
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  f="$top/.spec-devflow.conf"
  [ -f "$f" ] || f="$(main_worktree)/.spec-devflow.conf"
  [ -f "$f" ] || return 0
  for key in $DEVFLOW_CONF_KEYS; do
    [ -n "$(eval "printf '%s' \"\${$key:-}\"")" ] && continue          # env wins
    line="$(grep -E "^[[:space:]]*$key=" "$f" | tail -n1)" || true
    [ -n "$line" ] || continue
    val="${line#*=}"; val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  done
}
load_config

# ---------- models per phase ----------
# phase: plan | apply | task | review ; runtime: claude | opencode
# Claude Code defaults follow the recommended split; OpenCode has no default (empty = inherit the session model),
# because provider/model ids differ per setup.
phase_model() {
  local runtime="$1" phase="$2" var def=""
  case "$runtime" in
    claude)
      var="DEVFLOW_CLAUDE_MODEL_$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
      case "$phase" in plan) def=opus;; apply) def=sonnet;; task) def=sonnet;; review) def=opus;; esac;;
    opencode)
      var="DEVFLOW_OPENCODE_MODEL_$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')";;
    *) echo ""; return;;
  esac
  eval "printf '%s' \"\${$var:-$def}\""
}

# Where shared review records live (visible from every worktree of the repo).
review_dir() { printf '%s/devflow/reviews' "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"; }
