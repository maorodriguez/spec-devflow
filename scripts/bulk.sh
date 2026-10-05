#!/usr/bin/env bash
# bulk.sh — helper for bulk apply: several approved OpenSpec changes applied in parallel, one isolated
# worktree and one devflow-implementer per change (SKILL.md, "Bulk apply").
#
#   bulk.sh list   [<change>...] [--ref REF] [--no-fetch]
#   bulk.sh new    <change> <change>... [--ref REF] [--type TYPE] [--no-fetch]
#   bulk.sh prompt <change> --worktree PATH
#
# list:   JSON with one entry per change found under openspec/changes/ at the reference (or per named
#         change): pending/done tasks, eligible, needs_confirmation, reason. Reads git, not the working tree.
# new:    creates one worktree and branch per change through wt.sh; refuses fewer than two changes, any
#         ineligible change and any change that already has a worktree or branch. All or nothing.
# prompt: prints the self-contained English delegation prompt for one change and its worktree.
# The reference is the default branch. With DEVFLOW_PROPOSAL_GATE=main it can only be the default branch and a
# change is eligible once its proposal is there; with the gate off --ref may name an integration branch and the
# user's confirmation that the change is approved is still required (needs_confirmation).
# This script never pushes, merges, archives, comments or opens pull requests.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
PENDING_RE='^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]'
DONE_RE='^[[:space:]]*[-*][[:space:]]+\[[xX]\]'

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Sets REF: the reference every change is read from.
resolve_ref() { # $1 = requested ref (may be empty), $2 = 1 to skip the fetch
  local want="$1" nofetch="$2" def dref; def="$(default_branch)"
  if [ "$nofetch" != 1 ] && has_remote; then git fetch --quiet origin "$def" 2>/dev/null || warn "could not fetch origin/$def; using the local ref"; fi
  dref="$(default_ref)"
  if proposal_gate_on; then
    if [ -n "$want" ] && [ "$want" != "$dref" ] && [ "$want" != "$def" ]; then die "with the proposal gate on, --ref must be the default branch ($dref)"; fi
    REF="$dref"
  else
    REF="${want:-$dref}"
  fi
  git rev-parse --verify --quiet "$REF^{commit}" >/dev/null || die "unknown reference: $REF"
}

# Active change ids at REF (directories under openspec/changes/, archive excluded).
changes_at_ref() {
  git ls-tree --full-tree -d --name-only "$REF" "openspec/changes/" 2>/dev/null \
    | sed 's#^openspec/changes/##' | grep -v '^archive$' | grep -v '^$' || true
}

# Sets C_PENDING, C_DONE, C_ELIGIBLE (true|false), C_REASON for one change at REF.
assess() {
  local change="$1" tasks
  C_PENDING=0 C_DONE=0 C_ELIGIBLE=false C_REASON=""
  if ! change_active_on "$REF" "$change"; then
    if change_archived_on "$REF" "$change"; then C_REASON="already archived on $REF"
    elif proposal_gate_on; then C_REASON="proposal has not reached $REF"
    else C_REASON="not on $REF"; fi
    return
  fi
  if ! tasks="$(git show "$REF:openspec/changes/$change/tasks.md" 2>/dev/null)"; then C_REASON="no tasks.md on $REF"; return; fi
  C_PENDING="$(printf '%s\n' "$tasks" | grep -Ec "$PENDING_RE" || true)"
  C_DONE="$(printf '%s\n' "$tasks" | grep -Ec "$DONE_RE" || true)"
  if [ "${C_PENDING:-0}" = 0 ]; then C_REASON="no pending tasks"; return; fi
  C_ELIGIBLE=true
}

confirm_flag() { if [ "$C_ELIGIBLE" = true ] && ! proposal_gate_on; then echo true; else echo false; fi; }

cmd_list() {
  local names=() ref="" nofetch=0 c first=1 found
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) ref="${2:?}"; shift 2;;
      --no-fetch) nofetch=1; shift;;
      -*) die "unknown option: $1";;
      *) is_kebab "$1" || die "invalid change id: $1"; names+=("$1"); shift;;
    esac
  done
  resolve_ref "$ref" "$nofetch"
  if [ ${#names[@]} -eq 0 ]; then
    found="$(changes_at_ref)"
    while IFS= read -r c; do [ -z "$c" ] || names+=("$c"); done <<< "$found"
  fi
  [ ${#names[@]} -gt 0 ] || warn "no OpenSpec changes found at $REF (bulk apply reads committed state)"
  echo "["
  for c in ${names[@]+"${names[@]}"}; do
    assess "$c"
    [ "$first" = 1 ] || echo ","
    first=0
    printf '  {"change":"%s","ref":"%s","pending":%s,"done":%s,"eligible":%s,"needs_confirmation":%s,"reason":"%s"}' \
      "$c" "$REF" "$C_PENDING" "$C_DONE" "$C_ELIGIBLE" "$(confirm_flag)" "$C_REASON"
  done
  [ "$first" = 1 ] || echo
  echo "]"
}

cmd_new() {
  local names=() ref="" type=feat nofetch=0 c bad="" exists="" out path branch first=1 root
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) ref="${2:?}"; shift 2;;
      --type) type="${2:?}"; shift 2;;
      --no-fetch) nofetch=1; shift;;
      -*) die "unknown option: $1";;
      *) is_kebab "$1" || die "invalid change id: $1"; names+=("$1"); shift;;
    esac
  done
  resolve_ref "$ref" "$nofetch"
  [ ${#names[@]} -ge 2 ] || die "bulk apply needs at least two changes (got ${#names[@]}); for a single change use the normal flow (SKILL.md step 2)"
  root="$(worktree_root)"
  for c in "${names[@]}"; do
    assess "$c"
    [ "$C_ELIGIBLE" = true ] || bad="$bad $c($C_REASON)"
    if git show-ref --verify --quiet "refs/heads/$type/$c" || [ -e "$root/$type-$c" ]; then exists="$exists $c"; fi
  done
  [ -z "$bad" ] || die "not eligible:$bad"
  [ -z "$exists" ] || die "already has a worktree or branch:$exists; use or remove it first (wt.sh list, wt.sh remove)"
  echo "["
  for c in "${names[@]}"; do
    out="$(bash "$SCRIPT_DIR/wt.sh" new "$type" "$c" --base "$REF" --no-fetch)" || { echo "]"; die "wt.sh new failed for $c; worktrees created before it remain (wt.sh list)"; }
    path="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"
    branch="$(printf '%s\n' "$out" | sed -n 's/^branch=//p')"
    [ "$first" = 1 ] || echo ","
    first=0
    printf '  {"change":"%s","worktree":"%s","branch":"%s","base":"%s"}' "$c" "$path" "$branch" "$REF"
  done
  echo
  echo "]"
}

cmd_prompt() {
  local change="" wt="" tasks_file branch pending
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) wt="${2:?}"; shift 2;;
      -*) die "unknown option: $1";;
      *) [ -z "$change" ] || die "one change per prompt"; is_kebab "$1" || die "invalid change id: $1"; change="$1"; shift;;
    esac
  done
  [ -n "$change" ] && [ -n "$wt" ] || die "usage: bulk.sh prompt <change> --worktree PATH"
  [ -d "$wt" ] || die "worktree not found: $wt"
  wt="$(cd "$wt" && pwd -P)"
  tasks_file="$wt/openspec/changes/$change/tasks.md"
  [ -f "$tasks_file" ] || die "no tasks.md for '$change' in $wt"
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || die "$wt is on a detached HEAD"
  pending="$(grep -E "$PENDING_RE" "$tasks_file" | sed 's/^[[:space:]]*[-*][[:space:]]*\[[[:space:]]\][[:space:]]*/  - /')"
  cat <<EOP
Work ONLY in the worktree $wt (branch $branch). Do not edit anything outside that path and never touch another worktree.
OpenSpec change: $change. Read openspec/changes/$change/{proposal,design,tasks}.md and the delta specs under it.
You own tasks.md of this change: tick each task when it is fully done.
Pending tasks:
$pending

Do, in this order:
1. Apply the change: implement the pending tasks (OpenSpec apply workflow: /opsx:apply $change, or follow tasks.md directly).
2. Verify it before reporting: run /opsx:verify $change if it is available; otherwise check completeness, correctness and coherence against the specs and design.md by hand (SKILL.md step 5) and run the project's tests.
Commit through $SCRIPT_DIR/commit.sh using Conventional Commits and --change $change --task <id>. Write code, comments and commit messages in English.
Do NOT push, open or comment on pull requests, merge, archive the change or edit outside the worktree. None of those is allowed without the user's explicit approval, which only the orchestrator can ask for.

When done, reply with exactly this report (a change you did not verify is not ready for review):
- Change: $change
- Status: ready-for-review | blocked | partial
- Verification: <what you ran for step 2 and its result>
- Files changed: <list>
- Commits: <hashes and subjects>
- Tests run: <commands and results>
- Blockers / open questions: <list or none>
- Not done: no push, no PR, no merge, no archive.
EOP
}

[ $# -ge 1 ] || usage 1
sub="$1"; shift
case "$sub" in
  list) cmd_list "$@";;
  new) cmd_new "$@";;
  prompt) cmd_prompt "$@";;
  -h|--help|help) usage 0;;
  *) usage 1;;
esac
