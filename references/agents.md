# Delegating to sub-agents: one worktree per agent

Goal: every agent that edits files has its own worktree, and read-only agents (exploration, review) don't edit. Two agents never touch the same files and each one's work is a reviewable diff.

## When to parallelize

Only **independent** tasks from `tasks.md` (they don't touch the same files or depend on each other's results). Do sequential or coupled work yourself in the change's worktree. When in doubt, don't parallelize: resolving conflicts usually costs more than it saves.

## Common pattern (any runtime)

```
change worktree   feat/42-add-dark-mode
   ├── sub-worktree   feat/42-add-dark-mode-task-2-1   (agent A)
   └── sub-worktree   feat/42-add-dark-mode-task-3-1   (agent B)
```

1. Create each sub-worktree from the change branch (not from `main`), after committing everything you have:
   ```bash
   bash <skill-dir>/scripts/wt.sh new feat add-dark-mode-task-2-1 --issue 42 --no-fetch \
     --base feat/42-add-dark-mode
   ```
2. Give a `devflow-implementer` sub-agent a self-contained prompt (template below). In Claude Code pass `model: <DEVFLOW_CLAUDE_MODEL_TASK>` explicitly; in OpenCode the model comes from the agent file (see `models.md`).
3. When it finishes, integrate each branch in the change's worktree (`git merge --no-ff <sub-branch>` or `cherry-pick`), tick the tasks in `tasks.md`, run the tests, and commit with `commit.sh`.
4. Remove the sub-worktrees with `wt.sh remove ... --delete-branch` (sub-branches are never pushed).

Sub-agent commits go through `commit.sh` too, so they carry the same identity as the session (the person's in human mode). Sub-agents never push, open PRs or comment on GitHub; only the orchestrator does, with confirmation.

Prompt template (always in English):

```
Work ONLY in the worktree <absolute-path> (branch <branch>). Do not edit anything outside that path.
OpenSpec change: <change-id>. Read openspec/changes/<change-id>/{proposal,design,tasks}.md and the delta specs.
Implement only these tasks: <2.1, 2.2>. Expected files: <list>.
Run: <test command>. Commit with <skill-dir>/scripts/commit.sh using Conventional Commits and
--issue <n> --change <change-id> --task <id>. Write code, comments and commit messages in English.
Do not tick tasks.md, do not push, do not open PRs.
When done, reply with: commits created, tests run and their result, open questions.
```

(The orchestrator ticks the boxes when integrating, so `tasks.md` has a single owner.)

## Bulk apply: one worktree and one agent per change

The pattern above splits the tasks of one change. To apply several independent, approved changes at once, use one worktree and one `devflow-implementer` per **change** (SKILL.md, "Bulk apply"): `scripts/bulk.sh list` to see what is eligible, `bulk.sh new <change>…` for the worktrees and `bulk.sh prompt <change> --worktree <path>` for each worker's prompt. Differences with task-level parallelism:

- Each worker owns the `tasks.md` of its own change (nobody else touches that worktree) and keeps its own branch and PR.
- Each worker applies and then verifies before it reports; the prompt requires it.
- Nothing is pushed, merged or archived; the orchestrator asks the user first.

Report every worker must return, and the orchestrator shows consolidated, one block per change:

```
- Change: <change-id>
- Status: ready-for-review | blocked | partial
- Verification: <what was run and the result>
- Files changed: <list>
- Commits: <hashes and subjects>
- Tests run: <commands and results>
- Blockers / open questions: <list or none>
- Not done: no push, no PR, no merge, no archive.
```

Closing line of the orchestrator: "No merge, archive or push was done. Tell me which changes you approve to continue with push and PR."

## Claude Code

- **Sub-agents with native isolation**: a sub-agent in `.claude/agents/` with `isolation: worktree` in its frontmatter always runs in its own temporary worktree and inherits the isolation checks. By default those worktrees start from the default branch; to start from the change branch, set in `.claude/settings.json`:
  ```json
  { "worktree": { "baseRef": "head" } }
  ```
  With `"head"`, inside a worktree it resolves to that worktree's HEAD, i.e. the change branch. Decide whether this global setting suits your team before committing it.
- Temporary sub-agent worktrees without changes are removed automatically; those with changes remain until the periodic sweep. Integrate their commits before then.
- Explicit alternative (more control, same naming): create the sub-worktree with `wt.sh` and pass the path in the sub-agent prompt.
- Read-only agents (explore, review) don't need their own worktree; tell them not to edit.

`scripts/agents.sh generate` creates the `devflow-planner`, `devflow-implementer` and `devflow-reviewer` agents for both runtimes from `.spec-devflow.conf` (see `models.md`). A hand-written equivalent looks like:

```markdown
---
name: devflow-implementer
description: Implements independent tasks of an OpenSpec change in an isolated worktree
isolation: worktree
---
Follow the spec-devflow skill. Implement only the tasks you are given. Write code, comments and
commit messages in English and commit through scripts/commit.sh with the Refs/OpenSpec-Change/
OpenSpec-Task trailers. Do not push and do not tick tasks.md.
```

## OpenCode

- As far as current docs show, OpenCode has no stable native per-sub-agent worktree isolation; community plugins exist but aren't assumed here.
- Use the common pattern: create the sub-worktree with `wt.sh` and give the sub-agent the **absolute path**. Tell it to prefix every command with `cd <path> &&` and to use absolute paths when editing.
- You can restrict tools per agent in `opencode.json` / agent frontmatter (e.g. a reviewer without `edit`/`write`). See https://opencode.ai/docs/agents/ and https://opencode.ai/docs/permissions/ for your version's syntax.
- For long parallel work, one OpenCode session per worktree (or letting Orca do it) is more robust than chaining sub-agents in one session.

## Orca

Orca is the natural orchestrator for several agents: each in its worktree, with terminal, diff and notifications. Use `orca worktree create --parent-worktree active --agent <claude|opencode> --prompt "..."` (see `orca.md`) and Orca's documented orchestration for tracked dispatches. Keep the same prompt template and the same integration step in the change's worktree.

## Review by another agent

A reviewer agent works in `wt.sh review <pr>` (detached), without edit permissions if the runtime allows, and returns findings as English text. The orchestrator decides what to post on the PR (with the user's confirmation) and changes are implemented in the change's worktree.
