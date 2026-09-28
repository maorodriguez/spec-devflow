<!-- spec-devflow PR template. Write it in English. Do not add AI attribution footers in human mode. -->
## Summary

<One or two sentences: what changes and why.>

Closes #<issue>
OpenSpec-Change: `<change-id>` — `openspec/changes/<change-id>/` (after archiving: `openspec/changes/archive/<date>-<change-id>/`)

## Spec changes

<Affected capabilities and ADDED / MODIFIED / REMOVED requirements. "None" for a fix that does not change the spec.>

## Implementation

<Key design points and any deviation from design.md.>

## Verification

- [ ] `openspec validate <change-id> --strict` passes
- [ ] All tasks in `tasks.md` are done
- [ ] `/opsx:verify` has no CRITICAL issues (or an equivalent manual review)
- [ ] Tests: `<command>` passes
- [ ] Agent code review: 0 CRITICAL (`review.sh status`)
- [ ] `preflight.sh` OK

<Paste the verify/preflight summary here.>

## Review notes

<Agent review summary (CRITICAL/WARNING/SUGGESTION counts) and a one-line justification for each WARNING not fixed.>

## Before merging

- [ ] Proposal approved by a human
- [ ] PR approved
- [ ] Change archived in this PR (`openspec archive <change-id> --yes`)
- [ ] CI green

<!-- Automated mode only: replace this comment with "This PR was opened by an automated run (<who/what triggered it>)." -->
