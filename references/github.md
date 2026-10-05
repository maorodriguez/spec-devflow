# GitHub: issues, branches, commits and PRs

Default conventions. If the repo has its own (CONTRIBUTING.md, commitlint, templates in `.github/`), those win, except that everything is written in English and authored by the person doing the work.

## Language

Every artifact below is English: issue titles and bodies, comments, branch names, commit messages, PR titles and bodies, review comments. When the user asks in another language, translate the intent, don't transliterate it. Proper names and quoted user-facing strings that must stay in another language are the only exception (`commit.sh --allow-non-english` exists for that case).

## Traceability

```
Issue #42  ──  OpenSpec-Change: add-dark-mode
   │
Branch feat/42-add-dark-mode   (worktree .../feat-42-add-dark-mode)
   │
Commits  feat(ui): ...   + trailers Refs: #42 / OpenSpec-Change: add-dark-mode / OpenSpec-Task: 1.2
   │
PR  "feat: add dark mode (#42)"  ──  Closes #42
   │
openspec/changes/archive/YYYY-MM-DD-add-dark-mode/   (archived inside the PR; with the proposal gate, in its own PR after the merge)
```

The `change-id` is the shared key: issue, branch, change folder, trailers and PR all carry it, so any agent can rebuild the context with `scripts/link.sh`, `git log --grep` or `openspec show`.

The same chain is built whatever the entry point was:

| Entry point | What already exists | What the flow creates |
|---|---|---|
| Issue | issue | `OpenSpec-Change` line (if missing), change, branch, worktree, PR |
| OpenSpec change / task | change | issue (from `proposal.md`), branch, worktree, PR — or reuses them if `link.sh` finds them |
| Prompt | nothing | issue (from the prompt), change, branch, worktree, PR |

## Issues

```bash
gh issue view 42 --json number,title,body,labels,state
gh issue create --title "Add dark mode" --body-file /tmp/issue.md --label openspec
gh issue edit 42 --body-file /tmp/issue.md          # to add OpenSpec-Change
gh issue comment 42 --body "Proposal ready for review: <PR url>"
gh issue list --state all --search '"OpenSpec-Change: add-dark-mode" in:body' --json number,title
```

If the `openspec` label doesn't exist, `gh issue create` fails: propose creating it (`gh label create openspec --description "Has an OpenSpec change"`) and ask for confirmation.

For issues created from a prompt or from an OpenSpec change, write a short problem statement and expected outcome (`assets/issue-template.md`); link the change instead of pasting the spec.

## Branches

`<type>/<issue>-<slug>`; without an issue: `<type>/<slug>`. Types: `feat fix chore docs refactor test perf ci build`. The slug is the `change-id` when there is a change. English, kebab-case.

First push is always `git push -u origin <branch>`: `wt.sh` creates branches with `--no-track` so the upstream becomes the branch itself and never `main`.

## Commits

Always through `scripts/commit.sh` (identity, trailers, English check, isolation guards). Stage explicitly first; never `git add -A` blindly.

```bash
git add src/theme/ openspec/changes/add-dark-mode/tasks.md
bash <skill-dir>/scripts/commit.sh -m "feat(ui): add theme context provider" \
  --issue 42 --change add-dark-mode --task 1.1
```

Resulting message ([Conventional Commits](https://www.conventionalcommits.org/)):

```
feat(ui): add theme context provider

Refs: #42
OpenSpec-Change: add-dark-mode
OpenSpec-Task: 1.1
```

Add a body with a second `-m` when the *why* isn't obvious. Subject in imperative mood, ≤ 72 characters; scope = OpenSpec capability or code area.

Typical commits in the cycle:

| Moment | Message |
|---|---|
| Proposal | `docs(openspec): propose add-dark-mode` |
| Proposal updates | `docs(openspec): update add-dark-mode design` |
| Implementation | `feat(ui): ...`, `fix(auth): ...`, `test(ui): ...` (includes the updated `tasks.md`) |
| Archive | `docs(openspec): archive add-dark-mode` (with the proposal gate: the only commit of the archive PR, branch `chore/<issue>-archive-add-dark-mode`) |

Never rewrite published history without asking (`push --force-with-lease` only with confirmation).

## Pull requests

```bash
gh pr create --draft --base main --head feat/42-add-dark-mode \
  --title "feat: add dark mode (#42)" --body-file /tmp/pr.md
gh pr edit 57 --body-file /tmp/pr.md
gh pr ready 57
gh pr checks 57 --watch
gh pr view 57 --comments
gh pr review 57 --comment --body-file /tmp/review.md      # or --request-changes / --approve
```

- Open the PR as **draft** right after the proposal: spec review happens in the same place as code review.
- Body from `assets/pr-template.md`, in English, with `Closes #42` (closes the issue when merged into the default branch). No "Generated with…" footer in human mode.
- `gh` publishes as the logged-in account; check `identity.sh` (`gh_login`) before the first PR of a session.
- Don't approve or merge PRs the agent authored unless the user asks.

## Merging

Order: PR published → ready for review → approved by someone other than the author → change archived (timing in SKILL.md step 6) → CI green and branch up to date → merge through GitHub. Never merge locally into the default branch and push.

With `DEVFLOW_PROPOSAL_GATE=main` (two-PR mode, SKILL.md "Proposal gate") the change travels in three PRs, each merged through `merge.sh`: proposal, implementation (`Closes #<n>`) and archive. The archive step moves out of the implementation PR, and `merge.sh` classifies each PR and checks that its content fits. Every one of them needs its own recorded agent code review.

Use `scripts/merge.sh`, never a bare `gh pr merge`:

```bash
bash <skill-dir>/scripts/merge.sh 57                 # dry run: checks + exact command
bash <skill-dir>/scripts/merge.sh 57 --confirm       # only after the user says yes
bash <skill-dir>/scripts/merge.sh 57 --auto --confirm  # let GitHub merge once requirements are met
```

What it runs, for squash (the default, `DEVFLOW_MERGE_STRATEGY`):

```bash
gh pr merge 57 --squash --match-head-commit <reviewed-head-sha> \
  --subject "feat: add dark mode (#57)" --body $'Closes #42\nOpenSpec-Change: add-dark-mode'
```

Why squash by default: one commit per change on the default branch, easy to revert, while the per-task history stays in the PR. Explicit `--subject/--body` keep `Closes` and `OpenSpec-Change` on the default branch even if the repo's squash message setting is "commit messages". Use `merge` if the team wants per-task commits on the default branch; `rebase` ignores subject/body.

Auto-merge (`--auto`, or `DEVFLOW_AUTO_MERGE=1`): GitHub merges when approvals and required checks are satisfied; on branches with a merge queue it enqueues the PR instead. The repo must allow auto-merge; GitHub may refuse to enable it while requirements are unmet. It doesn't delete the head branch; enable "Automatically delete head branches" in the repo.

## Recommended protection for the default branch

`scripts/repo-policy.sh` reports the current state (rulesets are readable with read access; classic branch protection needs admin). Recommended, in rulesets or classic protection:

| Setting | Why |
|---|---|
| Require a pull request (no direct pushes, no force pushes, no deletion) | Everything reaches the default branch through review |
| ≥ 1 approving review; approval of the most recent push by someone other than its author | The author (or their agent) can't approve their own work |
| Dismiss stale approvals on push | Reviewed code = merged code; pairs with archive timing `before-review` |
| Required status checks, including `openspec validate --all --strict` | Specs stay valid on the default branch |
| Require branches to be up to date (or a merge queue for busy repos) | CI ran against what will actually be merged |
| Require conversation resolution (optional) | No review comment gets lost |
| Repo: allow squash; squash message = "Pull request title and description"; allow auto-merge; delete head branches automatically | Matches `merge.sh` defaults |

`repo-policy.sh --print-ruleset` prints a ruleset JSON and the `gh api` commands to apply it. Changing repository settings is a repo admin's decision: show it to the user, never apply it yourself.

## If a GitHub MCP server is available

In Claude Code there may be a GitHub MCP server besides `gh`. Either works; `gh` is the common denominator so the flow is identical in OpenCode. If you use the MCP server, keep the same titles, bodies, language and confirmations, and remember it also publishes as the account it is authenticated with.
