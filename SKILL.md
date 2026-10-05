---
name: spec-devflow
description: 'Spec-driven development flow with OpenSpec + GitHub (issues, branches, commits, PRs) where every change, fix or review happens in an isolated git worktree, compatible with Claude Code, OpenCode and the Orca ADE. Use it ALWAYS when the user wants to build, change or fix anything in a repo that has openspec/, whether the request comes from a GitHub issue ("work on #34"), from OpenSpec (a change id, "do task 2.1 of add-dark-mode", /opsx:propose, /opsx:apply, /opsx:archive) or from a plain prompt ("add a dark mode toggle", "agrega un botón", "corrige el login"); also for reviewing a PR, committing, opening or merging a pull request, or delegating work to parallel agents. Triggers even if the user does not mention worktrees, issues or this skill.'
license: MIT
compatibility: claude-code, opencode; requires git >= 2.32, authenticated gh CLI and @fission-ai/openspec >= 1.x; Orca CLI optional
metadata:
  version: "0.7.0"
  workflow: openspec-github-worktrees
---

# spec-devflow

One change = one issue = one OpenSpec change = one branch = one worktree = one PR. OpenSpec defines *what* gets built, GitHub tracks the *work*, and worktrees guarantee that no agent (and no human) edits the main checkout.

## Ground rules

1. **English for every artifact.** Issues, issue and PR comments, PR titles and bodies, commit messages, branch names, OpenSpec artifacts (proposal, design, specs, tasks), code, code comments, docs and review comments are written in English, even when the user writes to you in another language. Translate the user's intent faithfully; do not leave mixed-language text. Talk to the user in *their* language in the chat.
2. **Authorship belongs to the person doing the work.** Commits are authored with the human's own git identity and PRs are opened with their own `gh` login. Do not add AI attribution (`Co-Authored-By: Claude…`, "Generated with…", `Claude-Session:`) in human mode. Only when the work is automated (no human in the loop) fall back to another identity, with Claude as the last resort. See "Identity" below; always commit through `scripts/commit.sh`, which enforces this.
3. **The main checkout is read-only for agents.** Only reads, `git fetch` and worktree management happen there. Several agents (or Orca) may be working in parallel and the main checkout is everyone's shared base.
4. **One source of truth per artifact.** Requirements live in `openspec/`; work state lives in the GitHub issue/PR. Link them, never duplicate them.
5. **Do not replace OpenSpec.** Use its commands (`/opsx:*` or the `openspec-*` skills) to propose, apply, verify and archive. Never move a folder into `archive/` by hand: `openspec archive` merges the ADDED/MODIFIED/REMOVED deltas into `openspec/specs/` and validates first.
6. **Confirm before anything visible to others**: `git push`, creating/editing issues or PRs, comments, marking ready, merging, deleting remote branches. Show the exact command. One approval covers that action only, unless the user explicitly says otherwise in the session. Every entry point runs the *full* flow, but the confirmations still apply.
7. **Repo conventions win** when they exist (`CONTRIBUTING.md`, `.github/`, commitlint, merge strategy), except for rules 1 and 2, which the user has fixed.

## Step 0 — Orient yourself (always)

```bash
bash <skill-dir>/scripts/devflow-env.sh
bash <skill-dir>/scripts/identity.sh
bash <skill-dir>/scripts/agents.sh status
```

`<skill-dir>` is this skill's folder (usually `.claude/skills/spec-devflow`). The first report gives the runtime (claude / opencode / unknown), Orca availability, whether you are already inside a linked worktree, the default branch, `gh`/`openspec` status and installed OpenSpec commands. The second shows the identity commits will use and where it came from.

- `in_linked_worktree=yes` → you are already isolated (typical when Orca or `claude --worktree` launched you). **Do not nest worktrees**: if the branch matches the task, work here; otherwise say so and ask.
- `identity.sh` reports `mode=human` with `status=missing` → stop and ask the user to set `git config user.name` / `user.email`. Never invent an identity and never use Claude's in human mode.
- `setup_needed=yes` (the skill was just installed, e.g. with `npx skills add`; `openspec/` or the generated agents are missing) → offer once to run `bash <skill-dir>/scripts/setup.sh --hooks` from the repo root, after `gh`/`openspec` are OK and with the user's approval, then show the `git add … && git commit` line it prints and tell the user to restart the session so the new agents load. Setup is a one-time bootstrap, not a change: it does not need a worktree, and it commits nothing by itself.
- `gh` not authenticated or `openspec` missing → stop and tell the user what to install (`references/setup.md`).
- `agents.sh status` shows `missing` → the per-phase agents aren't generated; offer `agents.sh generate` once (see "Models per phase"), or work inline.
- `repo_policy` lists recommendations (e.g. no required PR or approvals on the default branch) → mention them once to the user; don't change repo settings yourself.

## Models per phase

The session running this skill can't switch its own model, so each phase is **delegated to an agent that declares its model**; the main session only orchestrates (user dialogue, scripts, confirmations, commits, GitHub). Details in `references/models.md`.

| Phase | Agent | Claude Code default |
|---|---|---|
| Propose / update (step 3) | `devflow-planner` | `opus` |
| Apply (step 4) and parallel task workers | `devflow-implementer` | `sonnet` (`DEVFLOW_CLAUDE_MODEL_TASK` for workers) |
| Agent code review (step 7) | `devflow-reviewer` (read-only) | `opus` |

- Models are set in `.spec-devflow.conf` (`DEVFLOW_CLAUDE_MODEL_*`, `DEVFLOW_OPENCODE_MODEL_*`); `agents.sh generate` writes `.claude/agents/devflow-*.md` and `.opencode/agents/devflow-*.md`.
- Claude Code: call the Agent tool with `subagent_type: devflow-<agent>` **and** pass `model` explicitly (some versions ignored the frontmatter). OpenCode: `@devflow-<agent>` / task tool; the model lives in the agent file.
- Each delegation prompt is self-contained: absolute worktree path, change id, issue, exact scope, "write everything in English".
- If the agents are missing or the user prefers not to delegate, do the phase inline and say which model it would normally use.

## Entry points (all converge on the same flow)

| The request comes from… | Examples | Start at |
|---|---|---|
| A GitHub issue | "work on #42", an issue URL | **1a** |
| OpenSpec | a change id, "apply add-dark-mode", "do task 2.1 of add-dark-mode", `/opsx:propose …` | **1b** |
| A plain prompt | "add a dark mode toggle", "fix the login race", "agrega exportar a CSV" | **1c** |
| A PR to review | "review PR #57" | "PR review flow" |
| Feedback on an existing PR | "address the comments on #57" | "Addressing PR feedback" |

Before anything else in 1a–1c, check whether the work already exists: `bash <skill-dir>/scripts/link.sh --change <id>` (or `--issue <n>` / `--pr <n>`). It reports the linked issue, branch, worktree, PR and whether the change is active, archived or absent. Reuse what exists; create only what is missing.

### 1a. From a GitHub issue

1. `gh issue view <n> --json number,title,body,labels,state`.
2. Pick the `<change-id>`: the `OpenSpec-Change:` line in the issue body if present; otherwise derive an English kebab-case id from the title and tell the user.
3. Add `OpenSpec-Change: <change-id>` to the issue body if missing (with confirmation).
4. Continue at **2**.

### 1b. From OpenSpec (a change or specific tasks)

1. `openspec list --json` and `openspec show <change-id>` to confirm the change and read it.
2. `link.sh --change <change-id>`. If no issue is linked, draft one in English from `proposal.md` using `assets/issue-template.md` (problem and outcome, not a copy of the spec) and create it with confirmation.
3. If a branch/PR for the change exists, continue in it (see "Addressing PR feedback" for creating the worktree). Otherwise continue at **2**.
4. If the change is already approved (merged on the default branch, or the user says so), skip the proposal step and go to **4. Apply**. If the user named specific tasks, apply only those.

A request for a single task still uses the change's branch, worktree and PR: one PR per change, not per task, unless the user asks otherwise.

### 1c. From a prompt

1. Classify it (table below) and restate the request in English, briefly, to the user.
2. Derive an English kebab-case `<change-id>` / `<slug>` and tell the user (they can rename it).
3. Draft the issue in English with `assets/issue-template.md` and create it with confirmation. The issue captures the *problem and expected outcome*; the proposal will hold the spec.
4. Continue at **2**.

If there is no GitHub remote or the user explicitly declines an issue, continue without one (branch without number, PR without `Closes`), and say so.

### Classifying the task

| The task is… | Type | OpenSpec? | Branch |
|---|---|---|---|
| New behavior or a change to specified behavior | `feat` | Yes, full change | `feat/<issue>-<change-id>` |
| Bug where the spec is wrong, incomplete or missing | `fix` | Yes, small change | `fix/<issue>-<change-id>` |
| Bug where code violates a correct spec | `fix` | No | `fix/<issue>-<slug>` |
| Refactor, tooling, CI, docs with no behavior change | `refactor`/`chore`/`ci`/`docs` | Optional: change with `skip_specs: true` | `<type>/<issue>-<slug>` |

Ids and slugs are English kebab-case (`^[a-z0-9]+(-[a-z0-9]+)*$`), the same format OpenSpec requires for change names. Use the same id in the issue, branch, change folder and PR.

## 2. Worktree

Details in `references/worktrees.md` and `references/orca.md`.

- **With Orca available** (preferred, so the worktree shows up in its UI): `bash <skill-dir>/scripts/wt.sh new <type> <change-id> --issue <n> --orca`, then read path and branch from the JSON.
- **Without Orca**: `bash <skill-dir>/scripts/wt.sh new <type> <change-id> --issue <n>`. It branches from a freshly fetched `origin/<default>` **without tracking** (so a bare `git push` can never target `main`) and copies the files listed in `.worktreeinclude`.

Enter it:

- **Claude Code**: call `EnterWorktree` with the printed path. Inside `.claude/worktrees/` Claude Code blocks edits to the main checkout.
- **OpenCode**: there is no native session directory switch. Use the worktree's absolute paths for every edit and prefix each command with `cd <path> &&`. For long work, suggest opening a new OpenCode session inside the worktree (or via Orca).

Install dependencies if the project needs them (a worktree is a clean checkout).

## 3. Propose (planning)

Inside the worktree:

1. Delegate to `devflow-planner` (plan model) with the worktree path, `<change-id>`, issue number and the issue body as context; it follows OpenSpec's `openspec-propose` skill. Inline fallback: `/opsx:propose <change-id>` in Claude Code, `/opsx-propose <change-id>` in OpenCode. The artifacts must be in English (rule 1; `references/setup.md` shows how to pin this in `openspec/config.yaml`).
2. Make sure `proposal.md` references the issue (`Issue: #<n>`).
3. `openspec validate <change-id> --strict --no-interactive`; fix until it passes.
4. Commit: `bash <skill-dir>/scripts/commit.sh -m "docs(openspec): propose <change-id>" --issue <n> --change <change-id>`.
5. With confirmation: `git push -u origin <branch>` and open a **draft PR** from `assets/pr-template.md` (`gh pr create --draft …`), body with `Closes #<n>`.
6. **Human gate**: ask the user to review the proposal (in the PR or in Orca) before implementing. Changing the spec is cheap now and expensive later.

When the artifacts are built one at a time instead of in one go (`/opsx:continue`), before creating the next artifact ask the user whether to commit the ones already completed, or whether to continue without that checkpoint.

If review asks for changes to the proposal, delegate to `devflow-planner` again (it uses `openspec-update-change`; inline: `/opsx:update`), validate, and commit again.

## 4. Apply (implementation)

0. If the proposal gate is on (`DEVFLOW_PROPOSAL_GATE=main`, see "Proposal gate"), run `bash <skill-dir>/scripts/proposal-gate.sh <change-id> --stage apply` first. If it blocks, do not apply: the proposal must reach the default branch first.
1. Delegate to `devflow-implementer` (apply model) in the change worktree, telling it that it owns `tasks.md`; it follows OpenSpec's `openspec-apply-change` skill. Inline fallback: `/opsx:apply <change-id>` (OpenCode: `/opsx-apply`). If the user asked for specific tasks, pass only those.
2. Commit per logical group of tasks, including the updated `tasks.md`, through `commit.sh` (add `--task 2.1` for each task covered). Format in `references/github.md`.
3. For fixes: write the failing test that reproduces the bug first and commit it with the fix.
4. To parallelize independent tasks, follow `references/agents.md`: one `devflow-implementer` per sub-worktree with the task model (`DEVFLOW_CLAUDE_MODEL_TASK`), none of them touching `tasks.md`.
5. In Orca, leave checkpoints: `orca worktree set --worktree active --comment "<progress, in English>" --json`.

## 5. Verify

1. If the step-0 report shows `opsx_verify=yes`: `/opsx:verify <change-id>`. Otherwise (OpenSpec `core` profile) check completeness, correctness and coherence against `specs/` and `design.md` manually, and suggest enabling it with `openspec config profile` + `openspec update`.
2. `bash <skill-dir>/scripts/preflight.sh <change-id>`: validation, pending tasks, clean tree, branch sync, commit authorship and attribution, English heuristics, and `DEVFLOW_TEST_CMD` when set.

## 6. Archive timing

With the proposal gate on, this section and the archive in step 9 do not apply: the PR never carries the archive (see "Proposal gate").

When the change gets archived depends on the repo, because archiving adds a commit:

```bash
bash <skill-dir>/scripts/repo-policy.sh --get archive_timing   # before-review | after-approval
```

- `DEVFLOW_ARCHIVE_TIMING` in `.spec-devflow.conf` (or the environment) sets it explicitly: `before-review`, `after-approval` or `auto` (default).
- `auto` resolves to **before-review** when the default branch dismisses stale approvals on push (otherwise the archive commit would invalidate the approval), and to **after-approval** otherwise.

**before-review**: archive now, before the agent code review, so both reviews see the final spec diff.

1. `openspec archive <change-id> --yes`; for any *new* capability, replace the `TBD` `## Purpose` in `openspec/specs/<capability>/spec.md` with a real one (≥ 50 characters, English), or strict validation fails.
2. `commit.sh -m "docs(openspec): archive <change-id>" --issue <n> --change <change-id>` (the archive and the spec sync are committed, never left in the tree), push with confirmation.
3. If review later asks for spec changes: `git revert --no-commit <archive-commit>` then `commit.sh -m "revert(openspec): reopen <change-id> for review changes" …`. That restores the change folder and the previous specs; update with `devflow-planner`, validate, and archive again (steps 1–2).

**after-approval**: keep the change active now; archive in step 9.

## 7. Agent code review

An independent `devflow-reviewer` (review model, fresh context, read-only) reviews the code before any human is asked to. Full procedure, checklist and report format: `references/code-review.md`.

1. Push, then create a read-only review worktree: `wt.sh review <pr>` (the draft PR works) or `wt.sh review --branch <branch>`.
2. Delegate to `devflow-reviewer` with the review worktree path, change id and issue. It runs `review.sh context` and returns a report in the exact format.
3. Save the report outside the worktree and record it: `review.sh record <file>`.
4. **CRITICAL** findings: fix in the change worktree, commit, push, move the review worktree (`wt.sh review …` again) and run an incremental review (`review.sh context --since <reviewed-sha>`) until 0 CRITICAL. **WARNING**: fix or justify in the PR body ("Review notes"). **SUGGESTION**: optional.
5. Optionally, with confirmation, post it as a PR comment: `review.sh publish <pr>` (dry run) → `--confirm`. Never as an approval.

`review.sh status` must show `critical=0` for HEAD; `preflight.sh` and `merge.sh` enforce it. A recorded review keeps covering later commits only when they touch nothing but `openspec/` (the archive commit); any code change needs a new review. `DEVFLOW_REQUIRE_AGENT_REVIEW=0` disables the gate (not recommended).

## 8. Ready and human review

1. `preflight.sh <change-id>` (checks archive timing, the agent review and everything else).
2. Update the PR body with verify, preflight and agent review results; with confirmation, `gh pr ready`.
3. A human (other than the author) reviews, ideally also from a read-only worktree ("PR review flow"). Requested changes go **in the change's worktree**; afterwards repeat the incremental agent review (step 7.4) and ask for re-review, since new pushes may dismiss approvals.

## 9. Archive (if pending) and merge

Merging happens only through the PR, after it is published, reviewed by the agent and approved by a human, and green. Never `git merge` into the default branch locally.

1. If timing is `after-approval`: archive now exactly as in step 6.1–6.2 (the agent review still covers it: the commit only touches `openspec/`).
2. `bash <skill-dir>/scripts/preflight.sh <change-id> --stage merge` (for fixes: `--no-change --stage merge`).
3. `bash <skill-dir>/scripts/merge.sh <pr>` — a **dry run**: checks the PR is open and not draft, approved by someone other than the author, no failing checks, the change archived on the PR head, the agent review covering the head with 0 CRITICAL, an English title; prints the exact `gh pr merge` command. It uses `--match-head-commit`, so GitHub refuses the merge if the head moves after the checks.
4. Show the user the result and the command, and **only with their explicit confirmation** run `merge.sh <pr> --confirm`.
   - Strategy: `DEVFLOW_MERGE_STRATEGY` (default `squash`); the squash commit gets subject `<PR title> (#<pr>)` and a body with `Closes #<n>` and `OpenSpec-Change`, regardless of the repo's squash message setting.
   - Auto-merge: `--auto` (or `DEVFLOW_AUTO_MERGE=1`) lets GitHub merge when approvals and checks are satisfied, or queues it when the branch uses a merge queue. Requires "Allow auto-merge" in the repo; it is still enabled by, and attributed to, the person who confirmed it.
5. The squash/merge commit on the default branch is attributed to the account running `gh`, i.e. the person who confirmed (rule 2).

`repo-policy.sh` (also shown in `devflow-env.sh`) reports how the default branch is protected and lists recommendations (required PR, approvals, required checks, up-to-date branches, squash message, auto-merge, branch deletion). `repo-policy.sh --print-ruleset` prints a ready-made ruleset; applying it is a repo admin's decision, never the agent's.

## 10. Clean up

`bash <skill-dir>/scripts/wt.sh remove <name-or-path>` for the change worktree and every review worktree. It refuses when there are uncommitted changes or unpushed commits. `--delete-branch` uses `git branch -d` (safe); with squash merges git won't consider the branch merged: confirm with `gh pr view <n> --json state` and let the user delete it with `-D`. Auto-merge doesn't delete the remote branch; the repo setting "Automatically delete head branches" does. In Orca you can also archive/delete from the UI; Orca notices worktrees removed by git.

## Proposal gate (optional two-PR mode)

Off by default: one PR carries proposal, implementation and archive. Set `DEVFLOW_PROPOSAL_GATE=main` (in `.spec-devflow.conf` or the environment) when the spec must be reviewed and merged on its own, so that every OpenSpec state change crosses the default branch before the next phase depends on it.

| Phase | PR | Gate |
|---|---|---|
| Propose | PR 1: proposal artifacts only (steps 2–3) | The human reviews it; it is merged through `merge.sh` like any PR |
| Apply | PR 2: implementation, `tasks.md` fully ticked, change still active | `proposal-gate.sh <id> --stage apply` blocks unless the proposal is on the default branch, HEAD carries that same proposal (`tasks.md` aside) and no proposal file is uncommitted |
| Archive | PR 3: only `openspec archive`, from a fresh worktree on the updated default branch | `proposal-gate.sh <id> --stage archive` blocks unless the implementation is merged (all tasks done on the default branch), the change is still active there and HEAD contains its tip |

- `preflight.sh` and `merge.sh` classify the PR from where the change stands on the default branch (proposal not there yet → proposal PR; active there → implementation PR; archived on the head but active there → archive PR) and check that its content fits: a proposal PR touches only `openspec/changes/<id>/`, an implementation PR leaves the approved proposal untouched and has no pending task, an archive PR touches only `openspec/` and requires the implementation to be merged already (no pending task on the default branch). Renamed files are compared as deletions plus additions, so moving a file into the allowed area does not hide it. A PR that mixes phases is blocked.
- Every PR still needs a recorded agent code review covering its head (step 7), including the proposal and archive PRs; `DEVFLOW_REQUIRE_AGENT_REVIEW=0` disables that gate for the repo.
- Branch names: `feat/<issue>-<change-id>` for PR 1 and PR 2 (a new worktree each, built from the updated default branch) and `chore/<issue>-archive-<change-id>` for PR 3; only PR 2 says `Closes #<n>`, the others say `Refs #<n>`.
- If a gate blocks, say so with the script's message and ask the user to fix the git state; never work around it, and never treat worktree visibility as proof the proposal reached the default branch.
- Archive in a worktree because the main checkout stays read-only for agents (rule 3).
- Commits made through `commit.sh` inside the flow are covered by the user starting it; creating branches or merging outside the flow, or a commit the user did not ask for, still needs their explicit say-so.

### What to say when a gate blocks

Stop, say it in the user's language, and ask them to make the git state explicit. The English wording below is the reference:

- **Apply before the proposal reached the default branch**: "I should not apply this yet because the proposal change has not reached the default branch. A proposal can be drafted on a branch, but apply must start only after that proposal state is available there. Please merge the proposal PR first; then I can apply from a branch or a worktree."
- **Archive before the implementation is merged**: "I should not archive this yet because the archive must start from the updated default branch after the implementation is merged. Verify makes a change eligible to merge; it does not replace the merge."

## Red flags

Whatever the mode, these mean: pause, explain the boundary, and ask the user to decide.

- Applying a proposal that exists only on the current branch or worktree (gate on).
- Treating worktree visibility as proof that the proposal reached the default branch.
- Creating the next artifact in `/opsx:continue` without asking about committing the previous one.
- Archiving before the implementation is merged, or from a branch that is not built on the updated default branch (gate on); archiving before the PR is approved (gate off).
- Working on a proposal or archive from the main checkout instead of a worktree.
- Committing, branching, pushing or merging outside this flow, or auto-merging, without the user's explicit say-so.
- Leaving the archive and spec-sync changes uncommitted at the end of the flow.
- Using bulk apply for a single change, or letting a bulk worker push, open a PR, merge or archive.

## Bulk apply (optional, several changes in parallel)

When two or more approved changes are waiting and the user did not name one, apply them concurrently: one isolated worktree, one `devflow-implementer` and one PR per change. Never use it for a single change or when the user names one; that is the normal flow.

1. **Pick the changes.** `bash <skill-dir>/scripts/bulk.sh list` reads `openspec/changes/*` from the default branch (git, not the working tree) and reports pending tasks, `eligible` and the reason. With the proposal gate on, a change is eligible only once its proposal is on the default branch. With the gate off the helper cannot know whether a change is approved: ask the user to confirm each one (`needs_confirmation`). Choose changes that do not touch the same files.
2. **Create the worktrees.** `bulk.sh new <change> <change>…` creates one worktree and branch per change through `wt.sh` and prints them as JSON. It refuses fewer than two changes, any ineligible change and any change that already has a worktree or branch, and creates nothing in those cases.
3. **Delegate.** For each change, `bulk.sh prompt <change> --worktree <path>` prints the self-contained English prompt; pass it to a `devflow-implementer` (model per `references/models.md`, one agent per worktree, in parallel). Each worker applies its change **and then verifies it** (`/opsx:verify`, or the manual check of step 5) before reporting, owns the `tasks.md` of its own change and commits through `commit.sh`.
4. **Consolidate.** Collect one report per change (template in `references/agents.md`): status, verification, files changed, commits, tests, blockers. A worker that did not verify is not ready for review. Show the user all reports together, blocked ones included.
5. **Stop there.** The run performs no push, PR, merge or archive, and the final message says so and asks for explicit approval before any of them. Each change then continues alone through steps 4–10 (push and draft PR with confirmation, agent review, ready, merge, clean up with `wt.sh remove`).

The orchestrator never edits inside a worker's worktree. `bulk.sh` has no push, merge, archive or PR code, and `tests/bulk.sh` checks that.

## Identity

`scripts/identity.sh` decides who authors commits; `scripts/commit.sh` applies it. Details and setup in `references/identity.md`.

| Mode | When | Author / committer | AI attribution |
|---|---|---|---|
| `human` (default) | A person is driving the session | Their `git config user.name/email`, unchanged | None |
| `automated` | `DEVFLOW_AUTOMATED=1` or CI (`CI=true`, `GITHUB_ACTIONS`) | 1) `DEVFLOW_ACTOR_NAME/EMAIL` (the person who launched it) → 2) `DEVFLOW_BOT_NAME/EMAIL` → 3) last resort `Claude <noreply@anthropic.com>` | Allowed; the PR body must say it was automated |

- Never change `git config` (global or local) to switch identity; `commit.sh` sets `GIT_AUTHOR_*`/`GIT_COMMITTER_*` per commit only in automated mode.
- PRs, comments and merges are published as whoever `gh` is authenticated as. In human mode that must be the person; if `identity.sh` shows a `gh_login` that clearly isn't them, stop and tell the user.
- If Claude Code still adds attribution despite the settings, the optional `commit-msg` hook (`scripts/install-hooks.sh`) strips it in human mode. Remove any such footer from PR bodies yourself.

## PR review flow

1. `bash <skill-dir>/scripts/wt.sh review <pr>` → detached worktree `review-pr-<pr>` at the PR head (via `refs/devflow/pr/<pr>`, no local branch).
2. Read the linked change (`openspec show <change-id>`), run tests and `openspec validate <change-id> --strict --no-interactive` there.
3. Don't edit or commit in the review worktree. Write findings in English and, with confirmation, post them: `gh pr review <pr> --comment|--request-changes|--approve --body-file …`. Don't approve PRs the agent authored unless the user explicitly asks.
4. If the PR is updated, re-run `wt.sh review <pr>` to move the worktree to the new head.
5. When done: `wt.sh remove review-pr-<pr>`.

## Fix without OpenSpec

Same flow, skipping steps 3, 5.1 and the archive parts of 6 and 9: issue → `wt.sh new fix <slug> --issue <n>` → failing test → fix → `commit.sh` → `preflight.sh --no-change` → PR with `Closes #<n>` → agent code review (step 7) → human review → `merge.sh <pr> --no-change`. If the fix reveals an ambiguous or wrong spec, stop and turn it into an OpenSpec change.

## Addressing PR feedback

If the change's worktree exists, work there. Otherwise (another machine or agent): `wt.sh new <type> <slug> --from-branch <pr-branch>`. Read comments with `gh pr view <n> --comments`, implement, commit with `commit.sh`, confirm, push. Reply to review comments in English.

## Reference files

- `references/identity.md` — authorship modes, environment variables, attribution settings and the commit-msg hook. Read before the first commit of a session if `identity.sh` reports anything other than a clean human identity.
- `references/github.md` — commit format, trailers, branch names, `gh` commands, issue ↔ change ↔ PR linking, merge policy and recommended branch protection. Read before the first commit, PR or merge of a session.
- `references/worktrees.md` — worktree location per runtime, `.worktreeinclude`, dependencies, cleanup, troubleshooting.
- `references/orca.md` — Orca CLI, detection, checkpoints, `orca.yaml`, dispatching agents. Read if `orca_available=yes`.
- `scripts/bulk.sh` — helper for bulk apply (`list`, `new`, `prompt`); `tests/bulk.sh` is its regression suite.
- `scripts/proposal-gate.sh` — the two-PR gate checks (`--stage apply|archive`); `tests/proposal-gate.sh` is its regression suite.
- `references/models.md` — models per phase, `.spec-devflow.conf` keys, generating and invoking the phase agents.
- `references/code-review.md` — agent code review procedure, checklist, severities and exact report format. Read before step 7.
- `references/agents.md` — delegating to sub-agents with one worktree per agent in Claude Code, OpenCode and Orca.
- `references/setup.md` — installing the skill and repo prerequisites.
- `assets/issue-template.md`, `assets/pr-template.md` — templates (English).
