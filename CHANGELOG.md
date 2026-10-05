# Changelog

Notable changes to spec-devflow. The version lives in the `SKILL.md` frontmatter.

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
- Deleting `tasks.md` in an implementation PR, or having it missing on the base for an archive PR, still counts as "no pending tasks" (found in the last agent review, not fixed yet).
- `merge.sh` with the gate on has only been exercised in dry runs against a stubbed `gh`.
