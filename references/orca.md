# Orca integration

Orca is an ADE that gives every task its own real git worktree, with an agent terminal (Claude Code, OpenCode and others), diff, review and PR shipping. This skill doesn't compete with it: when Orca is present, **let Orca create and track the worktrees** and apply the OpenSpec + GitHub conventions on top.

Official reference: https://www.onorca.dev/docs (CLI: `/docs/cli/reference`, worktrees: `/docs/model/worktrees`). Orca moves fast; if a flag fails, check `orca --help` or `orca skills get orca-cli`, the guide matching the installed version.

## Detection

```bash
command -v orca && orca status --json
```

The CLI is registered in Orca under Settings → Experimental → CLI. `devflow-env.sh` reports `orca_available=yes|no|cli_only_runtime_down`.

If the agent was launched by Orca it is usually already in a linked worktree (`in_linked_worktree=yes`). Don't create another one; `orca worktree current --json` tells you which one it is.

## Creating a change's worktree

```bash
bash <skill-dir>/scripts/wt.sh new feat add-dark-mode --issue 42 --orca
# equivalent to:
orca worktree create --name feat-42-add-dark-mode --setup inherit --no-parent --json
```

- `--setup inherit` follows the repo's setup-script policy (see `orca.yaml` below).
- When run from another Orca worktree, `wt.sh` passes `--parent-worktree active` so Orca nests it.
- Orca derives the branch name from the workspace name. The documented CLI has no branch flag, so check the real branch in the JSON (or `git -C <path> branch --show-current`). If it isn't `feat/42-add-dark-mode` and hasn't been pushed, rename it: `git -C <path> branch -m feat/42-add-dark-mode`. Orca keeps names it generated in sync with the branch.
- Alternative from the UI: create the workspace linked to the GitHub issue; Orca shows it on the worktree card. Then apply the branch convention as above.

## While working

- Visible progress on the worktree card (in English):
  `orca worktree set --worktree active --comment "proposal validated; waiting for review" --json`
- Human diff review: Orca's diff viewer and annotations sent back to the agent. Use it as the human gate for the proposal and for review.
- Commit/push/PR can also be done from Orca's UI. Those commits use the person's git identity (good: human mode). Afterwards check that titles, bodies and trailers follow `github.md` and are in English; `preflight.sh` flags what's off.

## Orca automations

Scheduled or unattended Orca automations are *automated* mode. Set in the automation's environment or prompt:

```bash
export DEVFLOW_AUTOMATED=1
export DEVFLOW_ACTOR_NAME="Jane Doe" DEVFLOW_ACTOR_EMAIL="jane@example.com"   # who owns the automation
```

Without an actor or bot identity, commits fall back to Claude (see `identity.md`).

## Reviewing a PR in Orca

Orca can open a worktree from a PR. If you do it through this skill's CLI (`wt.sh review <n>`), the worktree lives outside Orca's directory and shows up as a "Non-Orca worktree"; the user can show it from that dialog. Either path is fine; what matters is that review doesn't edit.

## Dispatching agents in parallel

For independent tasks of one change (see `agents.md`), Orca can create a child worktree and launch an agent with an initial prompt:

```bash
orca worktree create --name feat-42-add-dark-mode-task-2-1 \
  --parent-worktree active --agent opencode \
  --prompt "Implement task 2.1 of OpenSpec change add-dark-mode. Follow the spec-devflow skill. Write everything in English." \
  --setup inherit --json
```

Follow its terminal with `orca terminal list/read --worktree <selector> --json`. For tracked multi-agent dispatches, Orca documents its own orchestration flow (`/docs/cli/orchestration`); prefer it over ad hoc prompts.

Note: the child worktree starts from the repo's base ref unless your CLI version allows another start point. If it must start from the change branch, check `orca worktree create --help`; if there's no option, create it with `wt.sh new ... --base <change-branch>` and open it in Orca.

## Shared repo configuration (`orca.yaml`)

```yaml
# orca.yaml (repo root, committed)
worktree:
  sharedDirectories:   # ignored directories linked (not copied) into each worktree
    - node_modules
    - .cache
```

- There are also per-repo setup/archive scripts (in `orca.yaml` or Settings → Repository → Worktree Hooks): the place for `pnpm install`, copying `.env`, etc.
- `.worktreeinclude` (literal paths only) is applied by Orca, Claude Code and `wt.sh`.
- There's no complete `orca.yaml` reference page yet; confirm new keys against the installed version before committing them.

## Cleanup

Orca deletes worktree and branch in one click (with confirmation) and warns when git keeps unmerged branches. If you remove with `wt.sh remove` or `git worktree remove`, Orca notices on the next refresh. CLI equivalent: `orca worktree rm --worktree path:<path> --json` (avoid `--force` unless the user decides).
