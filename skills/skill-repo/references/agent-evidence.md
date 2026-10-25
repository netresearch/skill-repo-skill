<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Evidence for skill selection and task outcomes

## Contents

- Choose the instrument
- Record a real run
- Compare changes
- Portable review guidance
- Sources and limits

## Choose the instrument

| Evidence | What it establishes | What it cannot establish |
|---|---|---|
| `validate-evals.sh` and passing/failing samples | The eval file and its patterns are well formed | Model behavior or task correctness |
| `run-ab-evals.sh` | Answer differences when a skill body is supplied without tools | Normal skill selection or executed tools |
| Captured agent trajectory | Recorded skill invocation, reads and tool calls/results | Correctness of the final environment by itself |
| Independent outcome verifier | The specified property of the resulting environment | Every possible bug or general skill usefulness |

Use `agent-system-evals` for end-to-end execution with normally installed skills,
tools enabled and verifier-only expectations. Do not copy that benchmark's case
prompts, identifiers or findings into the skill fleet. Independent small cases
may be recorded in the same ATIF format or as Claude CLI stream-json.

## Record a real run

`validate-agent-evidence.py` checks a collector-written run record with the
following shape. Each artifact is a UTF-8 file inside the run directory, bound
by its SHA-256. Capture artifacts outside the agent's writable evaluation input.

```json
{
  "schema_version": 1,
  "evaluation": "task",
  "run_id": "unique-trial",
  "case_id": "independent-case",
  "arm": "after",
  "split": "validation",
  "status": "completed",
  "provenance": {
    "model": "resolved-model-version",
    "harness": "harness-version",
    "tool_environment": "environment-digest",
    "skill_revision": "skill-content-hash",
    "task_revision": "fixture-and-expectations-hash",
    "target_revision": "resulting-artifact-hash",
    "effort": "configured-effort"
  },
  "expected": {
    "skill": "skill-name",
    "should_trigger": true,
    "tool_calls": [{"name": "Bash", "arguments_contains": "run-check"}]
  },
  "trajectory": {"path": "trace.jsonl", "sha256": "actual-sha256"},
  "outcome": {"path": "outcome.json", "sha256": "actual-sha256"}
}
```

Change into the run directory, then run
`uv run /absolute/path/to/skill/scripts/validate-agent-evidence.py run.json`.
The run record must resolve inside the working directory, including through
symlinks; its artifacts must resolve beside it or in its subdirectories.
The script emits JSON and exits 0 for a measured pass, 1 for a measured failure,
or 2 for incomplete/invalid evidence. A task outcome artifact
contains boolean `passed`, an independent `verifier` identifier/version, and
`target_revision` matching the run. Record the verifier's checks and outputs in
that artifact too; a boolean supplied by the working agent is not an oracle.

Use `evaluation: selection` for a selection-only trial; no outcome is then
measured. `Skill`/`InvokeSkill` calls must name the exact skill. On a Read-based
host, set `expected.skill_path` to its exact installed SKILL.md path. Required
tools need a structured call and a returned, non-error observation;
`arguments_contains` is a literal in the JSON-serialized call arguments with
Unicode characters preserved. Quotes and backslashes remain JSON-escaped;
write literals against that serialized form. This proves
an observed invocation/return, not that a shell command succeeded semantically.
The independent outcome verifier decides that. Prose and reasoning are ignored.

`error`, `timeout` and `blocked` remain incomplete even for expected non-use.
Never count them as correct negatives or silently remove them from totals.
For Claude stream-json, retain the terminal result (`subtype: success` and
`is_error: false`) and complete messages;
partial stream deltas alone do not establish a completed run. The last
conversation event must be that result, so an earlier result cannot certify a
later unfinished turn.

Every recorded call must have a returned observation; open calls remain
incomplete. Selection-only trials with any failed return remain incomplete,
including expected non-use. In task mode, a recovered tool failure may coexist
with a verified successful outcome: routing and required-tool checks count only
successful returned calls, and `failed_tool_calls` preserves failed IDs. A failed
required tool without a successful retry fails the tool check even if the
outcome passes. ATIF collectors may normalize a failure as
`extra.is_error: true` (or top-level `is_error`); no failure is inferred from
prose. A `continued_trajectory_ref` means the single supplied segment is
incomplete. ATIF has no required terminal marker, so a text-only ATIF trajectory
still relies on the trusted collector's completion status; this validator
cannot distinguish an abandoned thought from a final answer by its wording.

## Compare changes

Compare `before` and `after` on identical fixture/expectation revisions, model,
effort, tool environment and permissions in fresh sessions and workspaces.
Use `without` additionally for a capability claim; team preferences must be
judged against the same user contract rather than raw model capability alone.
Retain failures, timeouts, traces, outcome artifacts, tokens, duration and rounds.
Measure known missed bugs and harmful false positives as well as successes.

Separate training, reused validation and an untouched final `holdout` set.
Selecting an iteration on a test score makes that set validation data, even if
the optimizer never sees its labels. A `split` label does not prove isolation:
record the split inventory/revision, keep final cases out of optimization, and
run that final comparison once the candidate is fixed. Repeated trials and
an explicit tie/uncertain outcome are preferable to a lucky winner. Reevaluate
after a model/harness change; remove instructions that no longer improve work.

## Portable review guidance

When a managed reviewer only imports SKILL.md text, provide self-contained
review criteria: scope, invariants, concrete evidence and finding severity.
Keep script execution, tool permissions and authoring actions in the executable
skill. Test which rules arrive at the target host. A text import is not a
successful skill run. Keep exclusions and Nit limits in REVIEW.md or its
supported adjacent includes, as the current service requires.

## Sources and limits

- [Agent eval methodology](https://www.anthropic.com/research/demystifying-evals-for-ai-agents)
- [Managed review includes](https://code.claude.com/docs/en/code-review-customize)
- [Trigger runner](https://github.com/anthropics/skills/blob/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/skill-creator/scripts/run_eval.py)
- [Iteration selection](https://github.com/anthropics/skills/blob/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/skill-creator/scripts/run_loop.py)

The local validator checks consistency and captured events, not their authorship
or truth. The collector, execution isolation and independent verifier remain
trust boundaries. It does not run a model or replace Harbor's evaluation.
