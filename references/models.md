# Models per phase

A skill can't switch the model of the session that is running it. Per-phase models therefore come from **delegating each phase to an agent that declares its own model**. The main session stays the orchestrator: it talks to the user, runs the scripts, handles confirmations, commits and GitHub.

## Default split

| Phase | Agent | Claude Code default | Why |
|---|---|---|---|
| Explore / propose / update | `devflow-planner` | `opus` | Spec mistakes are the most expensive; OpenSpec recommends high-reasoning models for planning |
| Apply (whole change, one implementer) | `devflow-implementer` | `sonnet` | Well-scoped implementation driven by `tasks.md` |
| Parallel task workers | `devflow-implementer` with `model` override | `sonnet` (set `haiku` for mechanical tasks) | Bounded work; cost matters when fanning out |
| Code review | `devflow-reviewer` | `opus` | Independent, fresh context; catching subtle bugs pays off |
| Orchestration | main session | whatever the user picked | Coordination, confirmations, scripts |

OpenCode has no defaults because model ids depend on the providers each person has configured (`provider/model`, e.g. `anthropic/claude-sonnet-4-5`). Empty means the agent inherits the session model.

## Configuration

In `.spec-devflow.conf` (committed) or the environment:

```ini
DEVFLOW_CLAUDE_MODEL_PLAN=opus
DEVFLOW_CLAUDE_MODEL_APPLY=sonnet
DEVFLOW_CLAUDE_MODEL_TASK=sonnet
DEVFLOW_CLAUDE_MODEL_REVIEW=opus
# DEVFLOW_OPENCODE_MODEL_PLAN=anthropic/<model-id>
# DEVFLOW_OPENCODE_MODEL_APPLY=anthropic/<model-id>
# DEVFLOW_OPENCODE_MODEL_TASK=anthropic/<model-id>
# DEVFLOW_OPENCODE_MODEL_REVIEW=openai/<model-id>     # a different provider = real second opinion
```

Claude Code accepts aliases (`opus`, `sonnet`, `haiku`, `fable`), full model ids, or `inherit`. Then generate the agents and commit them:

```bash
bash <skill-dir>/scripts/agents.sh generate          # --runtime claude|opencode|both, --dry-run
bash <skill-dir>/scripts/agents.sh status            # present / missing, declared vs expected model
git add .claude/agents .opencode/agents
```

Re-run `generate` after changing the config; it only overwrites files it manages (marker comment) and never your own agents unless `--force`.

## Delegating (orchestrator)

**Claude Code** — use the Agent tool with `subagent_type: devflow-<agent>` and **also pass `model` explicitly** with the configured value (`agents.sh status` shows it). Some Claude Code versions had bugs where the frontmatter `model` was ignored or overridden by `CLAUDE_CODE_SUBAGENT_MODEL`; the per-call parameter takes precedence in the documented resolution order. If the user reports unexpected costs, check the sub-agent transcript for the model that actually ran.

**OpenCode** — invoke the subagent (`@devflow-planner …` or the task tool). The task tool doesn't take a per-call model, so the model must be in the agent file; for a one-off different model, run a separate session with `opencode run -m <provider/model>`.

**Orca** — each worktree runs the agent CLI chosen with `--agent`; its model is whatever that CLI is configured to use (or the generated agents inside it).

Every delegation prompt must be self-contained: absolute worktree path, change id, issue number, exact scope, and the reminder that everything is written in English. The agents' own instructions already forbid pushing, GitHub actions and editing outside the worktree.

## Fallback

If the agents are missing (`agents.sh status` reports `missing`) or the user prefers not to delegate, do the phase in the main session and tell the user once which model the phase would normally use, so they can switch (`/model` in Claude Code, model picker or `-m` in OpenCode).
