# Changelog

Notable changes to spec-devflow. The version lives in the `SKILL.md` frontmatter.

## 0.7.0

### Added
- Bulk apply (opt-in): apply several approved changes in parallel, one isolated worktree, one `devflow-implementer` and one PR per change. Every worker applies and then verifies before reporting, a consolidated report is produced per change, and the run never pushes, merges, archives or opens PRs without the user's approval. With the proposal gate on, only changes whose proposal is on the default branch are eligible.
- Bulk apply is all or nothing and strict about existing work: duplicate ids and any existing branch (local or on `origin`, any type, with or without an issue number) or worktree are refused before anything is created, and a failure midway removes what was created. `<change>:<issue>` carries the issue number into the branch and the worker prompt. All JSON output is valid for any ref, path or name, and directories that are not valid change ids are skipped with a warning.
- `scripts/bulk.sh` (`list`, `new`, `prompt`) and its regression suite `tests/bulk.sh`; "Bulk apply" section in `SKILL.md` and the report template in `references/agents.md`.
- `SKILL.md`: "What to say when a gate blocks" (reference wording for apply and archive blocks) and a "Red flags" section listing the git-state situations in which the agent must pause and ask.
- `SKILL.md` step 3: ask whether to commit completed artifacts before creating the next one when building them one at a time, in both modes.

## 0.6.1

### Fixed
- Proposal gate: an implementation PR that deletes `tasks.md`, or an archive PR whose base has no `tasks.md`, is now blocked instead of counting as "no pending tasks".
- Proposal gate: when the proposal comparison itself fails (unknown ref, no merge base) the check reports "cannot diff <base>...<head>" instead of claiming the proposal changed.
- `tests/proposal-gate.sh`: the `merge.sh` dry-run test asserts the reason for the block, and new cases cover a deleted `tasks.md`, a base without `tasks.md` and an unknown base ref.

### Known gaps
- No test covers the guard that checks the head ref in the implementation check: removing it would not fail any test.
- The two `git rev-parse --verify --quiet` calls in `pr_scope_check` do not silence stderr, so a ref that points to a non-commit object prints git's raw error before "cannot diff".

## 0.6.0

### Added
- Optional two-PR mode, the proposal gate (`DEVFLOW_PROPOSAL_GATE=main`, default `off`): the proposal merges to the default branch before apply starts, and the archive runs from a fresh worktree in its own PR after the implementation is merged.
- `scripts/proposal-gate.sh <change-id> --stage apply|archive`: blocks apply unless the proposal on the default branch is the one in HEAD (and nothing under the change is uncommitted); blocks archive unless the implementation is merged.
- `preflight.sh` and `merge.sh` classify a PR as proposal, implementation or archive and check that its content fits: a proposal PR touches only `openspec/changes/<id>/`, an implementation PR leaves the approved proposal untouched and has no pending task, an archive PR touches only `openspec/` and requires the implementation to be merged. Renames are compared as deletions plus additions.
- `tests/proposal-gate.sh`: regression suite over the three PRs in linked worktrees, with `openspec` and `gh` stubbed.
- Documentation: "Proposal gate" section in `SKILL.md`, `DEVFLOW_PROPOSAL_GATE` in `references/setup.md`, `references/github.md` and the README.

### Behaviour with the gate off
Unchanged: one PR carries proposal, implementation and archive.

### Known gaps
- Deleting `tasks.md` in an implementation PR, or having it missing on the base for an archive PR, counted as "no pending tasks" (fixed in 0.6.1).
- `merge.sh` with the gate on has only been exercised in dry runs against a stubbed `gh`.
