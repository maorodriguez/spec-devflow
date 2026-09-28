# Agent code review

An independent reviewer agent checks the change **before** a human is asked to review it. It complements, never replaces, human review: the report is advisory, it is never posted as an approval, and `merge.sh` still requires a human approval from someone other than the author.

`/opsx:verify` answers "does the code match the spec?". This review answers "is the code good?": correctness, security, robustness, tests and maintainability.

## Independence

- Run it as the `devflow-reviewer` agent (see `models.md`), in a **fresh context**: it doesn't inherit the implementer's reasoning or assumptions.
- It works in a **read-only review worktree** (`wt.sh review <pr>` or `wt.sh review --branch <branch>`), never in the change worktree.
- Prefer the strongest model (default `opus` in Claude Code). In OpenCode you can point `DEVFLOW_OPENCODE_MODEL_REVIEW` to a different provider for a genuine second opinion.

**Known gap: "read-only" was a convention, not an enforced boundary — partially fixed.** Verified in practice (2026-09-28): in OpenCode, a `devflow-reviewer` agent generated with only `permission.edit: deny` still ran `git commit` through its Bash tool, using the orchestrator's real git identity, with no confirmation asked. `permission.edit: deny` blocks the file-edit tool, not arbitrary shell commands — and `review.sh record`'s clean-worktree check does not catch this either, since a commit leaves the tree clean (it only detects *uncommitted* edits, not an unexpected new commit).

Fix (same day): `agents.sh`'s OpenCode reviewer template now also sets `permission.bash`, denying `git add`, `commit`, `push`, `merge`, `rebase`, `reset`, `checkout`, `switch`, `stash`, `cherry-pick`, `revert`, `tag`, `update-ref`, `commit-tree`, `restore`, `clean`, `pull`, `am`, `apply`, `mv` and `rm` (everything else stays `allow`, so read-only git and test/lint commands still work). Each subcommand gets two patterns, `*git X*` and `*git -* X*`, so `cd d && git commit`, `/usr/bin/git commit` and `git -C dir commit` are denied too; glob patterns cannot tell a read-only `git branch` from a mutating one, so `branch`/`worktree` are only covered on the Claude Code side. Re-verified live: the same delegated `@devflow-reviewer` that committed before this fix got its `git commit` denied after it, and no commit was created.

**Claude Code fix (same day):** Claude Code's agent frontmatter has no per-pattern `bash` permission like OpenCode's, but a subagent can declare its own `PreToolUse` hook. `agents.sh`'s Claude reviewer template now adds one, scoped to the `Bash` matcher, running `scripts/reviewer-bash-guard.sh` — it splits the command into segments, finds every `git` invocation (any path, inside `$(...)`, `sh -c '...'`, after `cd x &&`), skips global options (`-C dir`, `-c k=v`, `--git-dir=...`) and exits 2 (blocking the call) when the subcommand is on the denylist (the OpenCode list plus `worktree`, `symbolic-ref`, `gc`, `prune`, and `branch` with anything but read-only flags). `git -c alias.*` is refused, but aliases already in the user's git config are not resolved. It reads the payload with `jq`, or a portable `sed -E` fallback, and fails closed if the payload cannot be parsed. The hook command is quoted for the shell and anchored on `$CLAUDE_PROJECT_DIR`. The guard script itself was tested directly against ~25 sample hook payloads (allowed and denied forms, both the `jq` and fallback paths, BSD `sed`); the end-to-end Agent-tool invocation could not be re-verified live in the same session, for the same reason noted under Limitations in the README (Claude Code only watches a project's `.claude/agents/` directory for files present when the session started) — pending a session restart.

Residual risk: on both runtimes, a bash-permitted agent can still mutate files directly (`sed -i`, shell redirection, `rm`, `mv`, `cp`) without going through the `edit` tool or a `git` command at all — the denylist (OpenCode) and hook (Claude Code) close the specific `git commit` failure observed, not the general case of an uncooperative or buggy model using Bash to write files. Until that's addressed, still compare the review worktree's HEAD before and after the reviewer runs, before trusting `review.sh record`.

## Procedure (orchestrator)

1. Commit and push everything; the review targets a commit, not a dirty tree.
2. Create the review worktree: `wt.sh review <pr>` (draft PRs work) or `wt.sh review --branch <branch>`.
3. Launch the reviewer with a self-contained prompt:
   ```
   Review worktree: <absolute path of the review worktree>. Change: <change-id>. Issue: #<n>.
   Run <skill-dir>/scripts/review.sh context [--since <last-reviewed-sha>] there and review per
   <skill-dir>/references/code-review.md. Return the report in the exact format.
   ```
   - Claude Code: Agent tool with `subagent_type: devflow-reviewer` **and** `model: <DEVFLOW_CLAUDE_MODEL_REVIEW>` passed explicitly.
   - OpenCode: `@devflow-reviewer …` or the task tool with that subagent.
   - Orca: a separate worktree/agent is fine too; the reviewer still needs the review worktree path.
4. Save the returned report **outside** the worktree (e.g. `$TMPDIR/review.md`) and record it: `review.sh record $TMPDIR/review.md`.
5. Triage with the user:
   - **CRITICAL**: fix in the change worktree (`commit.sh`, push), then run an **incremental** review: `wt.sh review …` again to move the review worktree, and pass `--since <previously reviewed sha>`. Repeat until 0 CRITICAL.
   - **WARNING**: fix, or write a one-line justification in the PR body under "Review notes".
   - **SUGGESTION**: optional; list the ones you skip.
6. Optionally, with the user's confirmation, post it on the PR: `review.sh publish <pr>` (dry run) then `review.sh publish <pr> --confirm`. It is a plain comment, never `--approve`.
7. `review.sh status` must report `critical=0` for HEAD; `preflight.sh` and `merge.sh` enforce it. A review of commit X keeps covering later commits only if they touch nothing but `openspec/` (e.g. the archive commit); any code change needs a new (incremental) review.

`DEVFLOW_REQUIRE_AGENT_REVIEW=0` in `.spec-devflow.conf` turns the gate off (not recommended).

## Checklist

Review the diff in the context of the surrounding code, the proposal, design and delta specs.

**Correctness**
- Logic errors, off-by-one, wrong conditions, unhandled null/empty/edge cases.
- Every scenario in the delta specs has matching behavior (and ideally a test).
- Concurrency: races, shared mutable state, missing awaits, ordering assumptions.
- Error handling: failures surfaced or handled deliberately; no swallowed exceptions; resources closed.

**Security**
- Input validation and output encoding (injection: SQL, command, path, XSS, template).
- AuthN/AuthZ checks on every new entry point; no privilege escalation.
- Secrets, tokens or personal data in code, logs, fixtures or error messages.
- Unsafe deserialization, SSRF, open redirects, insecure defaults, new dependencies with known risk.

**Data and compatibility**
- Migrations are reversible or explicitly one-way; no silent data loss.
- Public API / schema / config changes are backward compatible or called out in the proposal.

**Tests**
- New behavior and bug fixes are covered; tests assert behavior, not implementation details.
- Tests are deterministic (no timing, order or network dependence) and actually fail without the change.
- The project's test command passes in the review worktree (run it).

**Design and maintainability**
- Matches `design.md`; deviations are justified.
- Follows existing patterns and conventions of the codebase; no needless abstraction or duplication.
- Names are clear; functions do one thing; dead code and debug leftovers removed.
- Performance: no accidental N+1, unbounded loops or loading everything into memory on hot paths.

**Workflow rules**
- Code, comments, messages and docs are in English.
- No AI attribution in commits or PR body (human mode).
- `tasks.md` reflects what was actually done; `openspec validate <change-id> --strict` passes.

## Report format (exact)

`review.sh record` parses this. Keep headings and the `- [SEVERITY]` prefix exactly as shown; write in English.

```markdown
# Code review
head: <full or short sha of the reviewed commit>
change: <change-id or n/a>
reviewer: devflow-reviewer (<model>)
scope: <base>..<head> [incremental since <sha>]

## Findings
- [CRITICAL] src/export/csv.ts:42 — Unescaped delimiter in cell values. Values containing commas break the row. Quote fields per RFC 4180 and add a test.
- [WARNING] src/export/csv.ts:10 — Whole report loaded into memory. Large reports may exhaust memory; stream rows.
- [SUGGESTION] src/export/index.ts:5 — Name `doIt` is unclear; rename to `exportReportAsCsv`.

## Summary
CRITICAL: 1, WARNING: 1, SUGGESTION: 1
<one or two sentences on overall risk>
```

If there are no findings, write `- None.` under `## Findings` and `CRITICAL: 0, WARNING: 0, SUGGESTION: 0` in the summary.
