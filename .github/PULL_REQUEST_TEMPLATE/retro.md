## Summary

<!-- 1-2 sentences describing what this PR changes -->

## Came from

<!-- If this PR comes from /retro, include: session date, finding signal ID, brief description -->
<!-- Otherwise: link to issue, describe motivation -->

## Change

<!-- What concretely changed: files, scope, behavior. Paths are relative to skills/<skill-name>/ in this repo's layout. -->

## Target area

<!-- Tick the primary area. Multi-area is allowed when cohesive (e.g. SKILL.md update + corresponding eval). -->

- [ ] `skills/<name>/SKILL.md` (trigger description or workflow)
- [ ] `skills/<name>/references/` (detailed knowledge)
- [ ] `skills/<name>/scripts/` (mechanical operations)
- [ ] `skills/<name>/templates/` (output formats)
- [ ] `skills/<name>/checkpoints.yaml` (quality gates)
- [ ] `skills/<name>/evals/evals.json` (behavioral tests)
- [ ] Multi-area (justification below)

## Learning source

- [ ] This PR comes from a `/retro` session
- [ ] The change is reusable beyond one project
- [ ] The skill stays within its existing scope
- [ ] An eval (entry in `evals/evals.json`) is included if behavior expectations changed (TDD)

## Test plan

<!-- Bulleted checklist of verification steps -->

- [ ] Lint passes
- [ ] Existing evals pass (`bash skills/<name>/scripts/validate-evals.sh` or the repo's eval runner)
- [ ] New eval (if added) demonstrates the friction before the fix
