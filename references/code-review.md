# Agent code review

An independent reviewer agent checks the change **before** a human is asked to review it. It complements, never replaces, human review: the report is advisory, it is never posted as an approval, and `merge.sh` still requires a human approval from someone other than the author.

`/opsx:verify` answers "does the code match the spec?". This review answers "is the code good?": correctness, security, robustness, tests and maintainability.

## Independence

- Run it as the `devflow-reviewer` agent (see `models.md`), in a **fresh context**: it doesn't inherit the implementer's reasoning or assumptions.
- It works in a **read-only review worktree** (`wt.sh review <pr>` or `wt.sh review --branch <branch>`), never in the change worktree.
- Prefer the strongest model (default `opus` in Claude Code). In OpenCode you can point `DEVFLOW_OPENCODE_MODEL_REVIEW` to a different provider for a genuine second opinion.

**Read-only is enforced by an allowlist, on both runtimes.** History: on 2026-09-28 an OpenCode `devflow-reviewer` generated with only `permission.edit: deny` still ran `git commit` through its Bash tool (`edit: deny` blocks the file-edit tool, not shell commands), and `review.sh record`'s clean-worktree check cannot catch it because a commit leaves the tree clean. A denylist of git subcommands was tried first, but three review rounds kept finding bypasses (`git -C dir commit`, quoting tricks, aliases via `-c`/`include.path`/`GIT_CONFIG_*`, command substitution inside git's arguments, `--attr-source`, attached redirections), so both runtimes now deny everything except a short list of read-only commands.

- **Claude Code:** the subagent declares a `PreToolUse` hook on `Bash` running `scripts/reviewer-bash-guard.sh` (Claude Code's agent frontmatter has no per-pattern bash permission). The guard tokenizes the command quote-aware, splits it at `; & | ( )` and newlines, and requires every segment's command to be a bare name on a short allowlist. Allowed: read-only `git` subcommands (`status log diff show rev-parse rev-list ls-files ls-tree cat-file blame ...`, `branch` with list flags, `worktree list`, `stash list|show`), `ls cat head tail wc cut tr nl tac column diff cmp jq grep stat echo printf ...`, `gh pr|issue view|diff|checks|list`, `openspec validate|list|show|status`, `review.sh context|status`, and exact test/lint invocations (`npm test`, `npm run test|lint|typecheck|check`, `go test|vet [./pkg/...]`, `cargo test|clippy|check`, `make test|check|lint`, `pytest` with a few flags, `shellcheck`, plus the exact `DEVFLOW_TEST_CMD`). Commands with write or exec options (`find`, `sed`, `sort`, `rg`, `date`, `file`, `bash -n`, ...) are deliberately not on the list: three review rounds kept finding new option-level bypasses (`find {-delete,}`, `sort --compress-program`, `sed -nibak`, `bash -n +n -c`), and a per-flag filter is never exhaustive. For git, gh, openspec, the runners and review.sh every argument must be a literal word (no `$var`, unquoted `*?[` or `{`), so an option cannot be smuggled in through an expansion, and git options that write files or run programs are refused including their unique-prefix abbreviations (`--open`, `--out`, `--ext`). It blocks command and process substitution, redirections other than `2>&1` and `>/dev/null` (each must be a whole token: `>&1foo` is a file), environment assignments before a command, and paths as command names. Unknown git subcommands are denied, so git aliases from a user's config cannot be used. It reads the payload with `jq`, or a fallback that decodes JSON escapes, and fails closed if the payload cannot be parsed. `DEVFLOW_TEST_CMD` is read from the **main** worktree's `.spec-devflow.conf`, never from the worktree under review, and must match exactly. Tested against 180 hook payloads (45 allowed, 135 blocked), with and without `jq`, on BSD `sed`/bash 3.2.
- **OpenCode:** `agents.sh` generates `permission.bash` with `"*": deny`, `cmd`/`cmd *` allow pairs for the same read-only commands and read-only git subcommands, exact-match allows for the test runners (`npm test`, `make test`, `go test ./...`, ...), `review.sh` only through the skill's own path, and trailing deny patterns (last match wins) for `*>*` and, on git, `-O`, `--op*`, `--ou*`, `--ext*`, `$`, `{` and empty-quote splices. Verified live on OpenCode 1.18 (Haiku 4.5): `ls && git commit`, `ls; git commit`, `git status | git commit`, ``ls `git commit` `` and `ls $(git commit)` are all denied even though `ls *` is allowed (OpenCode splits compound commands), but `ls > out.txt` was allowed, hence the `*>*` deny. **This side is weaker than the Claude Code guard:** patterns match the raw command text, so quoting or escaping that changes how the shell reads an option can still evade a deny pattern on `gh`, `openspec` and `shellcheck` arguments, and there is no token-level parsing. Prefer Claude Code for the reviewer when the change is untrusted.

Residual risk: allowed test/lint runners execute the project's own code, and the committed `scripts/review.sh` is whatever copy the change under review contains, so a malicious change can still run code when the reviewer runs tests or review.sh; review untrusted changes in a sandbox. Also compare the review worktree's HEAD before and after the reviewer runs before trusting `review.sh record` (`record` already requires `head:` to equal a detached review worktree's HEAD).

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
