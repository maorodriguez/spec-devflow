# spec-devflow

Agent skill for Claude Code and OpenCode (Orca-compatible) that runs a spec-driven workflow:

**one change = one GitHub issue = one OpenSpec change = one branch = one git worktree = one PR.**

## Requirements

git ≥ 2.32 · [gh](https://cli.github.com) authenticated as yourself · [OpenSpec](https://github.com/Fission-AI/OpenSpec) ≥ 1.x · Orca CLI (optional)

## Install

From the root of the project you want to use it in (a git repository):

```bash
npx skills add maorodriguez/spec-devflow -a claude-code --copy
```

That copies the skill into `.claude/skills/spec-devflow` (read by both Claude Code and OpenCode). `--copy` matters: the skill must be committed inside the repo so every worktree has it, and a symlink into `.agents/skills/` would also make OpenCode see it twice. Then restart your agent and ask for anything (e.g. "work on #42"): on first use the skill notices that `openspec/` and the agents are missing (`setup_needed=yes`) and offers to run `setup.sh` for you. Or run it yourself:

```bash
bash .claude/skills/spec-devflow/scripts/setup.sh --hooks
git add .claude/agents/devflow-* .claude/skills/spec-devflow .claude/skills/openspec-* .claude/commands/opsx \
        .opencode/agents/devflow-* .opencode/commands/opsx-* .opencode/skills/openspec-* openspec skills-lock.json   # or the exact line setup.sh prints
git commit -m "chore: add spec-devflow"
```

`setup.sh` runs `openspec init` (if `openspec/` is missing) and generates the planner / implementer / reviewer agents; `--hooks` also installs the commit-msg hook that strips AI attribution (optional). Restart your Claude Code session afterwards so it picks up the new agents. Without the CLI, `git clone --depth 1 https://github.com/maorodriguez/spec-devflow .claude/skills/spec-devflow && rm -rf .claude/skills/spec-devflow/.git` is equivalent.

To update, rerun the `npx skills add` command (or replace `.claude/skills/spec-devflow` with a fresh clone), then rerun `setup.sh`.

Optional team config in `.spec-devflow.conf` (models per phase, archive timing, merge strategy, test command). See `references/setup.md`.

## Use

Just ask your agent. Any of these starts the full flow:

- **From an issue:** "work on #42"
- **From OpenSpec:** "apply add-dark-mode", "do task 2.1 of add-dark-mode"
- **From a prompt:** "add CSV export to reports"
- **Review:** "review PR #57"

The flow: issue → isolated worktree → OpenSpec proposal (draft PR, human approval) → implementation → verify → agent code review → ready for review → human approval → archive → merge.

## Guarantees

- The main checkout is never edited; every change, fix and review runs in its own worktree.
- Everything written to the repo and GitHub is in English.
- Commits and PRs are authored by you; Claude is only the last-resort identity for unattended runs.
- Nothing is pushed, commented, or merged without your confirmation; merges require a human approval, a clean agent review, and green CI.

## Useful scripts

| Script | Purpose |
|---|---|
| `devflow-env.sh` | Environment, identity and repo-policy report |
| `wt.sh new / review / list / remove` | Worktree lifecycle |
| `commit.sh` | Commits with the right identity, trailers and checks |
| `review.sh` | Agent code review context, record, status, publish |
| `preflight.sh` | Pre-ready / pre-merge checks |
| `merge.sh` | Guarded merge (dry run unless `--confirm`) |
| `repo-policy.sh` | Branch protection report and recommended ruleset |

## Limitations

- Subagent invocation, Claude Code side, is confirmed working after a session restart: `scripts/agents.sh generate` writes `.claude/agents/devflow-*.md`, and the Agent tool with `subagent_type: devflow-reviewer` returned a report in the exact `# Code review` / `## Findings` / `- [SEVERITY]` format. Note that Claude Code only watches a project's `.claude/agents/` directory for new files if that directory already existed when the session started, so agents generated mid-session (or into a fresh `.claude/agents/`) aren't picked up until the session restarts (a same-session attempt failed with "Agent type not found"). That report has not yet been piped through `review.sh record`.
- Subagent invocation, OpenCode side, is confirmed working end-to-end: `opencode run` with a prompt that delegates to `@devflow-reviewer` (the documented invocation, per `references/code-review.md`) does invoke the generated subagent via its task tool. Note `opencode run --agent devflow-reviewer` does *not* work directly — it falls back to the primary agent, since a `mode: subagent` agent can't be run as the top-level agent. Also note the reviewer's report format is only as reliable as the model behind it: a smoke test with a weak model (`gpt-4o-mini`) returned real findings but did not follow the exact `# Code review` / `## Findings` / `- [SEVERITY]` format `review.sh record` requires, so it would have been rejected — this is expected to be more reliable with the stronger models the workflow recommends (`opus`/equivalent), but `review.sh record`'s format check is the actual safety net either way.
- The GitHub-touching scripts (`merge.sh`, `preflight.sh`, `repo-policy.sh`, `link.sh`, `review.sh publish`) were exercised against a simulated/mocked `gh` CLI, not a real GitHub repo and PR.

## License

MIT — see [LICENSE](LICENSE).
