# Identity and authorship

Rule: changes are published in the name of the person doing them. Only automated work, with no person in the loop, uses another identity, and Claude is the last resort.

## Modes

`scripts/identity.sh` reports the mode; `scripts/commit.sh` applies it on every commit.

**human** (default). Author and committer are the person's own `git config user.name` / `user.email`, exactly as configured (global, per-repo or via `includeIf`). The skill never changes git config. If no identity is configured, stop and ask the user to set it. Commit messages and PR bodies carry no AI attribution.

**automated**. Enabled by `DEVFLOW_AUTOMATED=1`, or detected from CI (`CI=true|1`, `GITHUB_ACTIONS`). Identity resolution order:

1. `DEVFLOW_ACTOR_NAME` + `DEVFLOW_ACTOR_EMAIL` — the person who launched or owns the run (e.g. set in an Orca automation or CI job from the triggering user).
2. `DEVFLOW_BOT_NAME` + `DEVFLOW_BOT_EMAIL` — a team bot account.
3. `Claude <noreply@anthropic.com>` — last resort.

`commit.sh` applies it with `GIT_AUTHOR_*` / `GIT_COMMITTER_*` for that single commit. In automated mode the PR body must state that the run was automated and what triggered it (see the last comment in `assets/pr-template.md`).

Set `DEVFLOW_AUTOMATED=1` yourself for unattended runs that CI detection won't catch (Orca scheduled automations, cron, headless `claude -p` / `opencode run`).

## GitHub side

PRs, comments, reviews and merges are published as whoever `gh` is authenticated as; git author settings do not change that. `identity.sh` prints `gh_login`.

- Human mode: `gh` must be logged in as the person. If it clearly isn't them, stop and tell the user.
- Automated mode: use the token of the actor or bot for that environment (e.g. a GitHub App or a bot account in CI). The skill cannot make a PR appear as "Claude" on GitHub; it only controls git authorship.
- With squash merges the resulting commit on the default branch is attributed to whoever merges; merges are always done with explicit confirmation by the person.

## Removing AI attribution (human mode)

Three layers, from preferred to backstop:

1. **`commit.sh`** builds the message itself and strips attribution lines before committing.
2. **Claude Code settings** (in `.claude/settings.json` for the team or `.claude/settings.local.json` / `~/.claude/settings.json` for one person):

   ```json
   { "attribution": { "commit": "", "pr": "" } }
   ```

   `attribution` replaced the deprecated `includeCoAuthoredBy`. There are open reports of Claude Code still adding a trailer or a `Claude-Session:` line in some paths, hence layer 3.
3. **commit-msg hook**: `bash <skill-dir>/scripts/install-hooks.sh` installs a hook in the repository's common hooks dir (shared by every worktree) that removes `Co-Authored-By: Claude…`, `Generated with Claude Code/opencode` and `Claude-Session:` lines in human mode and does nothing in automated mode. It refuses to overwrite an existing hook or to run under `core.hooksPath` (husky, lefthook); in that case, copy the logic from `assets/commit-msg-hook.sh` into your hook manager.

OpenCode does not add commit attribution by default as far as the docs show; layers 1 and 3 cover it anyway.

For PR bodies there is no hook: write them from `assets/pr-template.md` and remove any footer a tool adds. `preflight.sh` fails if the PR body has a "Generated with…" footer in human mode.

If an organization requires disclosing AI assistance, that policy overrides this default; ask the user.

## Checks

`preflight.sh` verifies, for the commits on the branch:

- in human mode, every commit is authored by the resolved email;
- no AI attribution lines in human mode;
- commit messages look English (heuristic: accented letters and `¿`/`¡`).
