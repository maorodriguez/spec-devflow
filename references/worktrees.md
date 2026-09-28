# Worktrees per runtime

## Where they are created

| Context | Location | Created by |
|---|---|---|
| Inside Orca | Orca's managed directory | `wt.sh new ... --orca` → `orca worktree create` |
| Claude Code (no Orca) | `.claude/worktrees/<name>` | `wt.sh new` |
| OpenCode or other (no Orca) | `.worktrees/<name>` | `wt.sh new` |
| Override | `DEVFLOW_WORKTREE_ROOT` (relative to the main checkout, or absolute) | `wt.sh` |

Why `.claude/worktrees` in Claude Code: it is where `claude --worktree` puts them; `EnterWorktree` enters them without an extra approval, and Claude Code blocks edits, commands and git redirections into the main checkout while the session is isolated.

If a team mixes runtimes and wants a single folder, set `DEVFLOW_WORKTREE_ROOT=.worktrees` for everyone (in Claude Code, entering it with `EnterWorktree` will then ask for approval each time).

`wt.sh` adds the root to `.git/info/exclude` when it isn't ignored. For the team, add it to `.gitignore` too:

```
/.worktrees/
/.claude/worktrees/
```

Runtime detection is heuristic (`CLAUDECODE` for Claude Code; `OPENCODE`/`OPENCODE_CLIENT` for OpenCode). If it reports `unknown`, force it with `DEVFLOW_RUNTIME=claude|opencode`.

## Names

`wt.sh new feat add-dark-mode --issue 42` creates:

- folder `feat-42-add-dark-mode`
- branch `feat/42-add-dark-mode`, from a freshly fetched `origin/<default>`, with no upstream

`wt.sh review 57` creates `review-pr-57`, detached at `refs/devflow/pr/57` (a local ref that is never pushed). Running it again moves it to the PR's current head, as long as it has no edits.

## Ignored files (.env, local config)

A worktree is a clean checkout: no `.env`, no `node_modules`, no caches. `.worktreeinclude` at the repo root is the common mechanism:

- **Claude Code** applies it to the worktrees it creates (`--worktree`, sub-agents, desktop) and accepts `.gitignore`-style patterns.
- **Orca** applies it to its worktrees, but only literal paths (no globs or negations).
- **`wt.sh`** follows Orca's rule: literal paths that exist in the main checkout and are git-ignored.

So keep `.worktreeinclude` to literal paths: it then behaves the same in all three.

```
# .worktreeinclude
.env
.env.local
.vscode/settings.json
```

For large shareable directories (linked, not copied), Orca offers `worktree.sharedDirectories` in `orca.yaml` (see `orca.md`). Outside Orca, install dependencies per worktree (with pnpm the store is shared, so it's cheap).

## Skills and hooks inside worktrees

The skill must be **committed** under `.claude/skills/spec-devflow/` so every worktree has it:

- OpenCode discovers skills walking up from the current directory to the git worktree root, and reads `.claude/skills/`.
- Claude Code loads the worktree's skills; if the worktree has no `.claude/skills/`, it reads the main checkout's.

The optional commit-msg hook lives in the repository's common hooks dir, so one install covers all worktrees.

## Cleanup

`wt.sh remove <name>` refuses when there are uncommitted changes, untracked files or unpushed commits. There is deliberately no `--force`: if work must be discarded, a person decides with `git worktree remove --force`.

Other cases:

- Folder deleted by hand: `git worktree prune`.
- Locked worktree (Claude Code locks sub-agent worktrees while they run): `git worktree unlock <path>` only if no agent is using it.
- Claude Code cleans up temporary sub-agent worktrees with no changes; it does not touch worktrees made with `git worktree add` (including `wt.sh`'s).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `fatal: '<branch>' is already checked out at ...` | A branch can be checked out in one worktree only. Use that one (`wt.sh list`). |
| `git push` tries to go to `main` | The branch tracks `origin/main`. `git branch --unset-upstream && git push -u origin <branch>`. |
| LFS files are pointers (Claude Code) | Claude Code skips filter drivers defined in the local `.git/config`. Run `git lfs pull` in the worktree. |
| Worktrees show as untracked in `git status` | The root isn't ignored (see above). |
| Tests or linters in the main checkout scan `.worktrees/` | Exclude it in the tool's config, or use a root outside the repo (`DEVFLOW_WORKTREE_ROOT=../<repo>-worktrees`). |
