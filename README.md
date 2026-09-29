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

- **Verified end to end on a real (temporary, private) GitHub repo:** issue → `wt.sh new` → `commit.sh` → push → draft PR → `link.sh` → `wt.sh review` → the real `devflow-reviewer` run headless in that repo (`claude -p --agent devflow-reviewer`, entering the review worktree under the read-only guard) → `review.sh record` in the detached review worktree → `review.sh publish --confirm` (comment posted) → `gh pr ready` → `preflight.sh --stage ready|merge` → `merge.sh` dry run → squash merge → `wt.sh remove --delete-branch`. This run found and fixed four bugs that the earlier mocked `gh` had hidden (`merge.sh` never read the PR title/body, and a repo without required reviews shifted its fields so `BEHIND`/`DIRTY`/`BLOCKED` were never checked; `link.sh --pr` ignored PRs without an OpenSpec change; `devflow-env.sh` crashed on macOS bash 3.2).
- **Not exercised against real GitHub yet:** `merge.sh --confirm` (it refuses without an approval from someone other than the author, which a single-account test cannot give), `--auto`, `repo-policy.sh --print-ruleset`, an OpenSpec change going through propose → apply → archive, and Orca.
- The reviewer's Bash tool is a read-only **allowlist** (see `references/code-review.md`): read-only git, a few inspection commands, and exact test/lint invocations; `cd`/`git -C` only into registered worktrees. It is protection against accidents and prompt injection, not a security boundary: allowed test runners execute the project's own code and `review.sh` is the copy the reviewed change contains, so review untrusted changes in a sandbox. `tests/reviewer-guard.sh` is its regression suite. The OpenCode side matches raw command text and is weaker.
- Subagent invocation is confirmed on both runtimes. Claude Code only picks up agents from a `.claude/agents/` directory that existed when the session started, so restart the session after `setup.sh`. `opencode run --agent devflow-reviewer` does not work directly (a `mode: subagent` agent cannot be the top-level agent): delegate to `@devflow-reviewer` instead. The reviewer's report format is only as reliable as its model (a weak model returned real findings in the wrong format); `review.sh record` rejects anything that does not match.

## License

MIT — see [LICENSE](LICENSE).
