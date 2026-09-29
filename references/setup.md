# Installation and prerequisites

## Requirements

| Tool | Version | Used for |
|---|---|---|
| git | ≥ 2.32 (`git commit --trailer`) | worktrees, commits |
| gh (GitHub CLI) | authenticated **as the person**: `gh auth login` | issues, PRs, reviews |
| OpenSpec | `npm install -g @fission-ai/openspec@latest` (Node ≥ 20.19) | specs and changes |
| Orca | optional; CLI registered under Settings → Experimental → CLI | parallel worktrees and agents |

Each person also needs their git identity set (`git config user.name` / `user.email`); the skill never sets it for them.

## Install the skill in the repo (recommended)

Commit it so it exists in **every worktree** and both Claude Code and OpenCode share it. The skill folder must be named `spec-devflow`:

```bash
npx skills add maorodriguez/spec-devflow -a claude-code --copy   # installs into .claude/skills/spec-devflow
bash .claude/skills/spec-devflow/scripts/setup.sh --hooks   # openspec init + agents (+ commit-msg hook)
git add .claude/agents/devflow-* .claude/skills/spec-devflow .claude/skills/openspec-* .claude/commands/opsx \
        .opencode/agents/devflow-* .opencode/commands/opsx-* .opencode/skills/openspec-* openspec skills-lock.json   # or the exact line setup.sh prints
git commit -m "chore: add spec-devflow"
```

Use `-a claude-code --copy`: the skills CLI otherwise installs into a canonical `.agents/skills/` and symlinks it into each agent's directory, which breaks committing the skill into every worktree and makes OpenCode see it twice. The `setup.sh` step can be skipped: `devflow-env.sh` reports `setup_needed=yes` when `openspec/` or the agents are missing, and the skill then offers to run it (with the user's approval) on first use. Without the CLI, `git clone --depth 1 https://github.com/maorodriguez/spec-devflow .claude/skills/spec-devflow && rm -rf .claude/skills/spec-devflow/.git` is equivalent.

`setup.sh` covers the next section's `openspec init` and the agent generation, so only the English pin and optional config below remain manual.

- Claude Code loads `.claude/skills/<name>/SKILL.md`.
- OpenCode also reads `.claude/skills/<name>/SKILL.md` (besides `.opencode/skills/` and `.agents/skills/`). Don't copy it into several locations: OpenCode requires unique names across all of them.
- The frontmatter only uses fields both understand (`name`, `description`, `license`, `compatibility`, `metadata`).
- Global alternative: `~/.claude/skills/spec-devflow/` (read by both), but then it doesn't travel with the repo.

## Prepare the repo

```bash
openspec init --tools claude,opencode     # or just the tools you use
```

- In Claude Code the commands are `/opsx:<id>`; in OpenCode, `/opsx-<id>`. OpenSpec also generates `openspec-*` skills.
- Initializing for both tools writes `openspec-*` into `.claude/skills/` **and** `.opencode/skills/` (verified with OpenSpec 1.13.2: 6 duplicated skills), and OpenCode sees both copies. `devflow-env.sh` reports it as `duplicate_openspec_skills`. Check how your OpenCode version handles it; if it causes trouble, one option is to initialize only `claude` (OpenCode then uses the `openspec-*` skills from `.claude/skills/`, without the `/opsx-*` commands).
- For `/opsx:verify`: `openspec config profile` (choose the expanded workflow) and `openspec update`.
- OpenSpec telemetry can be disabled with `openspec config set telemetry.enabled false` or `OPENSPEC_TELEMETRY=0`.

### Pin OpenSpec artifacts to English

Add to the `context` field of `openspec/config.yaml` (keep any existing context):

```yaml
context: |
  Language: English
  All artifacts (proposal, design, specs, tasks) must be written in English,
  even when the request is written in another language.
```

`devflow-env.sh` reports `openspec_language=english` once it's set.

### Remove AI attribution (human mode)

See `identity.md`. In short:

```json
// .claude/settings.json (team) — Claude Code
{ "attribution": { "commit": "", "pr": "" } }
```

```bash
bash .claude/skills/spec-devflow/scripts/install-hooks.sh   # each clone, optional backstop
```

### Recommended root files

```gitignore
# .gitignore
/.worktrees/
/.claude/worktrees/
```

```text
# .worktreeinclude — literal paths only (works with Orca, Claude Code and wt.sh)
.env
.env.local
```

GitHub label (once): `gh label create openspec --description "Has an OpenSpec change"`.

Optional: copy `assets/pr-template.md` to `.github/pull_request_template.md` so humans use it too.

## Repo configuration file (optional, committed)

`.spec-devflow.conf` at the repo root holds team-wide defaults as `KEY=value` lines. It is parsed, never executed, and only these keys are read; environment variables override it.

```ini
# .spec-devflow.conf
DEVFLOW_ARCHIVE_TIMING=auto        # auto | before-review | after-approval
DEVFLOW_MERGE_STRATEGY=squash      # squash | merge | rebase
DEVFLOW_AUTO_MERGE=0               # 1 = merge.sh uses --auto by default
DEVFLOW_TEST_CMD=pnpm test
DEVFLOW_REQUIRE_AGENT_REVIEW=1     # agent code review gate (step 7)
DEVFLOW_CLAUDE_MODEL_PLAN=opus     # models per phase, see models.md
DEVFLOW_CLAUDE_MODEL_APPLY=sonnet
DEVFLOW_CLAUDE_MODEL_TASK=sonnet
DEVFLOW_CLAUDE_MODEL_REVIEW=opus
# DEVFLOW_OPENCODE_MODEL_PLAN=anthropic/<model-id>   (and _APPLY, _TASK, _REVIEW)
# DEVFLOW_WORKTREE_ROOT=.worktrees
# DEVFLOW_DEFAULT_BRANCH=main
```

## Environment variables

| Variable | Effect |
|---|---|
| `DEVFLOW_RUNTIME` | Force `claude` or `opencode` if detection fails |
| `DEVFLOW_WORKTREE_ROOT` | Worktree folder (relative to the main checkout, or absolute) |
| `DEVFLOW_DEFAULT_BRANCH` | Default branch when `origin/HEAD` isn't set |
| `DEVFLOW_TEST_CMD` | Test command run by `preflight.sh` |
| `DEVFLOW_ARCHIVE_TIMING` | `auto` (default), `before-review` or `after-approval` |
| `DEVFLOW_MERGE_STRATEGY` | `squash` (default), `merge` or `rebase` |
| `DEVFLOW_AUTO_MERGE` | `1` to make `merge.sh` enable auto-merge by default |
| `DEVFLOW_REQUIRE_AGENT_REVIEW` | `0` disables the agent code review gate (default `1`) |
| `DEVFLOW_CLAUDE_MODEL_{PLAN,APPLY,TASK,REVIEW}` | Claude Code model per phase (defaults opus/sonnet/sonnet/opus) |
| `DEVFLOW_OPENCODE_MODEL_{PLAN,APPLY,TASK,REVIEW}` | OpenCode `provider/model` per phase (default: inherit) |
| `DEVFLOW_AUTOMATED` | `1` for unattended runs (automated identity mode) |
| `DEVFLOW_ACTOR_NAME` / `DEVFLOW_ACTOR_EMAIL` | Person who owns an automated run (first choice) |
| `DEVFLOW_BOT_NAME` / `DEVFLOW_BOT_EMAIL` | Team bot identity (second choice; Claude is the last resort) |

## Phase agents

```bash
bash .claude/skills/spec-devflow/scripts/agents.sh generate     # writes .claude/agents and .opencode/agents
git add .claude/agents .opencode/agents && git commit -m "chore: add spec-devflow phase agents"
```

With OpenCode, check the generated agents load as expected in your version (`opencode debug agent devflow-reviewer` shows the effective permissions); OpenCode v2 introduced a new permission syntax.

## Branch protection and merge settings

Run `bash .claude/skills/spec-devflow/scripts/repo-policy.sh` and review its recommendations with the repo admin. `--print-ruleset` prints a ready-made ruleset (require PR, 1 approval, last-push approval, dismiss stale approvals, conversation resolution, squash only, required checks) plus the repo merge settings to pair with it. See `github.md` → "Recommended protection".

## Suggested CI

```yaml
# step in your PR workflow
- run: npm install -g @fission-ai/openspec@latest
- run: openspec validate --all --strict --no-interactive
- run: openspec validate --archived     # fails if a change was archived with unchecked tasks
```

## Quick check

```bash
bash .claude/skills/spec-devflow/scripts/devflow-env.sh
bash .claude/skills/spec-devflow/scripts/identity.sh
```

Expect `gh=authenticated`, `openspec_version=<version>`, `openspec_dir=yes`, `openspec_language=english`, and `mode=human status=ok` with your own name, email and `gh_login`.
