#!/usr/bin/env bash
# bulk.sh — helper for bulk apply: several approved OpenSpec changes applied in parallel, one isolated
# worktree and one devflow-implementer per change (SKILL.md, "Bulk apply").
#
#   bulk.sh list   [<change>...] [--ref REF] [--no-fetch]
#   bulk.sh new    <change>[:<issue>] <change>[:<issue>]... [--ref REF] [--type TYPE] [--no-fetch]
#   bulk.sh prompt <change> --worktree PATH [--issue N]
#
# list:   JSON with one entry per change found under openspec/changes/ at the reference (or per named
#         change): pending/done tasks, eligible, needs_confirmation, reason. Reads git, not the working tree.
# new:    creates one worktree and branch per change through wt.sh (an optional :<issue> goes to wt.sh --issue).
#         Refuses duplicates, fewer than two changes, any ineligible change and any change that already has
#         a branch (local or origin, any type, with or without an issue number) or a worktree; nothing is
#         created then. If a creation fails midway, what this run created is removed and nothing is printed.
# prompt: prints the self-contained English delegation prompt for one change and its worktree; refuses a
#         change with no pending tasks and a detached worktree.
# The reference is the default branch. With DEVFLOW_PROPOSAL_GATE=main it can only be the default branch and a
# change is eligible once its proposal is there; with the gate off --ref may name an integration branch and the
# user's confirmation that the change is approved is still required (needs_confirmation).
# DEVFLOW_WT_SH overrides the wt.sh used by `new` (a test hook for failure injection).
# This script never pushes, merges, archives, comments or opens pull requests.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
WT_SH="${DEVFLOW_WT_SH:-$SCRIPT_DIR/wt.sh}"
PENDING_RE='^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]'
DONE_RE='^[[:space:]]*[-*][[:space:]]+\[[xX]\]'

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }

# JSON string escaping: backslash, double quote and every control character below U+0020.
jstr() {
  local s="$1" out="" ch code i
  case "$s" in *[\\\"[:cntrl:]]*) ;; *) printf '%s' "$s"; return;; esac
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      '\') out="$out\\\\";;
      '"') out="$out\\\"";;
      *)
        printf -v code '%d' "'$ch" 2>/dev/null || code=255   # bytes >= 0x80 may read as negative: they pass through
        if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then
          case "$code" in
            9) out="$out\\t";;
            10) out="$out\\n";;
            13) out="$out\\r";;
            *) out="$out$(printf '\\u%04x' "$code")";;
          esac
        else
          out="$out$ch"
        fi;;
    esac
  done
  printf '%s' "$out"
}

# True when the argument is a non-empty string of digits only (newlines and anything else are rejected).
is_digits() { case "$1" in ''|*[!0-9]*) return 1;; esac; return 0; }

# Resolved (symlink-free) form of a path that may not exist yet: git prints resolved paths, so comparisons need it.
real_path() {
  local p="$1" d
  if [ -d "$p" ]; then (cd "$p" && pwd -P); return; fi
  d="$(dirname "$p")"
  if [ -d "$d" ]; then printf '%s/%s\n' "$(cd "$d" && pwd -P)" "$(basename "$p")"; else printf '%s\n' "$p"; fi
}

# Prints what already exists for a change the way the normal flow would find it: branches (local or origin,
# any type, optional issue number) and worktrees on such branches in any folder, or a worktree at the
# conventional path of this run.
existing_work() { # $1 = change, $2 = type, $3 = worktree root, $4 = issue (optional)
  local c="$1" type="$2" root="$3" re found=""
  re="(^|/)([0-9]+-)?$c\$"
  found="$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin | grep -E "$re" | paste -sd' ' - || true)"
  [ -z "$found" ] || printf 'branch %s; ' "$found"
  git worktree list --porcelain | grep -E "^branch refs/heads/(.*/)?([0-9]+-)?$c\$" >/dev/null && printf 'worktree on a matching branch; '
  [ ! -e "$root/$type-$c" ] || printf 'path %s; ' "$root/$type-$c"
  [ -z "${4:-}" ] || [ ! -e "$root/$type-$4-$c" ] || printf 'path %s; ' "$root/$type-$4-$c"
  return 0
}

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

# Active change ids at REF (directories under openspec/changes/, archive excluded; names that are not valid
# change ids are skipped with a warning).
changes_at_ref() {
  local name
  while IFS= read -r -d '' name; do
    name="${name#openspec/changes/}"
    [ "$name" != archive ] || continue
    if is_kebab "$name"; then printf '%s\n' "$name"; else warn "skipping openspec/changes/$name: not a valid change id"; fi
  done < <(git ls-tree --full-tree -d --name-only -z "$REF" "openspec/changes/" 2>/dev/null)
}

# Sets C_PENDING, C_DONE, C_ELIGIBLE (true|false), C_REASON for one change at REF.
assess() {
  local change="$1" tasks
  C_PENDING=0 C_DONE=0 C_ELIGIBLE=false C_REASON=""
  if ! change_active_on "$REF" "$change"; then
    if change_archived_on "$REF" "$change"; then C_REASON="already archived on $REF"
    elif git cat-file -e "$REF:openspec/changes/$change" 2>/dev/null; then C_REASON="no proposal.md on $REF"
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
      "$(jstr "$c")" "$(jstr "$REF")" "$C_PENDING" "$C_DONE" "$C_ELIGIBLE" "$(confirm_flag)" "$(jstr "$C_REASON")"
  done
  [ "$first" = 1 ] || echo
  echo "]"
}

cmd_new() {
  local specs=() names=() issues=() ref="" type=feat nofetch=0 spec c i n bad="" exists="" w root base_commit
  local out path branch created_paths=() created_branches=() entries=() leftover="" j
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) ref="${2:?}"; shift 2;;
      --type) type="${2:?}"; shift 2;;
      --no-fetch) nofetch=1; shift;;
      -*) die "unknown option: $1";;
      *) specs+=("$1"); shift;;
    esac
  done
  # <change> or <change>:<issue>; duplicates and fewer than two changes are refused before anything else.
  for spec in ${specs[@]+"${specs[@]}"}; do
    c="${spec%%:*}"; i=""
    case "$spec" in *:*) i="${spec#*:}"; is_digits "$i" || die "invalid issue number in '$spec' (use <change>:<number>)";; esac
    is_kebab "$c" || die "invalid change id: $c"
    for n in ${names[@]+"${names[@]}"}; do [ "$n" != "$c" ] || die "change '$c' is given more than once"; done
    names+=("$c"); issues+=("$i")
  done
  [ ${#names[@]} -ge 2 ] || die "bulk apply needs at least two changes (got ${#names[@]}); for a single change use the normal flow (SKILL.md step 2)"
  resolve_ref "$ref" "$nofetch"
  base_commit="$(git rev-parse --verify "$REF^{commit}")"
  root="$(worktree_root)"
  j=0
  for c in "${names[@]}"; do
    assess "$c"
    [ "$C_ELIGIBLE" = true ] || bad="$bad $c($C_REASON)"
    w="$(existing_work "$c" "$type" "$root" "${issues[$j]}")"
    j=$((j + 1))
    [ -z "$w" ] || exists="$exists $c($w)"
  done
  [ -z "$bad" ] || die "not eligible:$bad"
  [ -z "$exists" ] || die "already has a worktree or branch:$exists; use or remove it first (wt.sh list, wt.sh remove)"
  j=0
  for c in "${names[@]}"; do
    i="${issues[$j]}"; j=$((j + 1))
    if out="$(bash "$WT_SH" new "$type" "$c" ${i:+--issue "$i"} --base "$REF" --no-fetch)"; then
      path="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"
      branch="$(printf '%s\n' "$out" | sed -n 's/^branch=//p')"
      created_paths+=("$path"); created_branches+=("$branch")
      entries+=("$(printf '  {"change":"%s","issue":%s,"worktree":"%s","branch":"%s","base":"%s"}' "$(jstr "$c")" "${i:-null}" "$(jstr "$path")" "$(jstr "$branch")" "$(jstr "$REF")")")
    else
      # The failing creation may have left its own worktree and/or branch behind: include them in the rollback.
      # existing_work proved the branch did not exist before this run, so it is ours to clean up.
      path="$(real_path "$root/$type-${i:+$i-}$c")"; branch="$type/${i:+$i-}$c"
      if git worktree list --porcelain | grep -Fqx "worktree $path"; then
        created_paths+=("$path"); created_branches+=("$branch")
      elif git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        created_paths+=(""); created_branches+=("$branch")
      fi
      # Roll back what this run created. wt.sh remove is not used: it refuses a branch whose commits are not on a
      # remote, which every fresh branch is when the base is local. Instead each worktree is removed only while it
      # is clean and still at the base commit, and its branch only while its tip is the base commit, so nothing a
      # worker committed can be lost. Whatever cannot be proven untouched stays and is reported.
      n=$(( ${#created_paths[@]} - 1 ))
      while [ "$n" -ge 0 ]; do
        path="${created_paths[$n]}"; branch="${created_branches[$n]}"
        if [ -z "$path" ] || { [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] && [ "$(git -C "$path" rev-parse HEAD 2>/dev/null)" = "$base_commit" ]; }; then
          [ -z "$path" ] || git worktree remove "$path" >/dev/null 2>&1 || true
          if [ "$(git rev-parse --verify --quiet "refs/heads/$branch" || true)" = "$base_commit" ]; then git branch -D "$branch" >/dev/null 2>&1 || true; fi
        fi
        n=$((n - 1))
      done
      # Report only what verifiably remains; never claim success on the strength of exit codes.
      n=0
      while [ "$n" -lt "${#created_paths[@]}" ]; do
        if { [ -n "${created_paths[$n]}" ] && [ -e "${created_paths[$n]}" ]; } || git rev-parse --verify --quiet "refs/heads/${created_branches[$n]}" >/dev/null; then
          leftover="$leftover ${created_paths[$n]:-(no worktree)}(${created_branches[$n]})"
        fi
        n=$((n + 1))
      done
      if [ -n "$leftover" ]; then die "creating the worktree of '$c' failed; could not remove:$leftover; inspect them, then git worktree remove <path> and git branch -D <branch>"; fi
      die "creating the worktree of '$c' failed; everything created before it was removed"
    fi
  done
  echo "["
  n=0
  for out in "${entries[@]}"; do
    [ "$n" = 0 ] || echo ","
    printf '%s' "$out"; n=$((n + 1))
  done
  echo
  echo "]"
}

cmd_prompt() {
  local change="" wt="" issue="" tasks_file branch pending testcmd commitflags
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) wt="${2:?}"; shift 2;;
      --issue) issue="${2:?}"; shift 2;;
      -*) die "unknown option: $1";;
      *) [ -z "$change" ] || die "one change per prompt"; is_kebab "$1" || die "invalid change id: $1"; change="$1"; shift;;
    esac
  done
  [ -n "$change" ] && [ -n "$wt" ] || die "usage: bulk.sh prompt <change> --worktree PATH [--issue N]"
  [ -z "$issue" ] || is_digits "$issue" || die "--issue must be a number"
  [ -d "$wt" ] || die "worktree not found: $wt"
  wt="$(cd "$wt" && pwd -P)"
  tasks_file="$wt/openspec/changes/$change/tasks.md"
  [ -f "$tasks_file" ] || die "no tasks.md for '$change' in $wt"
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || die "$wt is on a detached HEAD; check out the change branch first"
  pending="$(grep -E "$PENDING_RE" "$tasks_file" | sed 's/^[[:space:]]*[-*][[:space:]]*\[[[:space:]]\][[:space:]]*/  - /' || true)"
  [ -n "$pending" ] || die "'$change' has no pending tasks in $wt; there is nothing to apply"
  if [ -z "$issue" ]; then issue="$(printf '%s' "$branch" | sed -n "s#^.*/\([0-9][0-9]*\)-$change\$#\1#p")"; fi
  commitflags="--change $change --task <id>"
  [ -z "$issue" ] || commitflags="--issue $issue $commitflags"
  testcmd="${DEVFLOW_TEST_CMD:-}"
  [ -n "$testcmd" ] || testcmd="the project's tests"
  cat <<EOP
Work ONLY in the worktree $wt (branch $branch). Do not edit anything outside that path and never touch another worktree.
OpenSpec change: $change. Read openspec/changes/$change/{proposal,design,tasks}.md and the delta specs under it.
You own tasks.md of this change: tick each task when it is fully done.
Pending tasks:
$pending

Do, in this order:
1. Apply the change: implement the pending tasks (OpenSpec apply workflow: /opsx:apply $change, or follow tasks.md directly).
2. Verify it before reporting. Run /opsx:verify $change if it is available; otherwise check by hand: (a) completeness: every task in tasks.md is done and nothing the delta specs require is missing; (b) correctness: the code does what each scenario of the delta specs says; (c) coherence: it follows design.md. Then run $testcmd.
Commit through $SCRIPT_DIR/commit.sh using Conventional Commits and $commitflags. Write code, comments and commit messages in English.
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
