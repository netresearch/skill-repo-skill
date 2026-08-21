# Skill Architecture: flat discovery, small routing metadata, details on demand

## Contents

- The three surfaces
- Budgets, and where each number comes from
- The description is a router, not documentation
- Flat discovery: one level, always
- What belongs in SKILL.md and what does not
- Long references need a Contents section
- What the validator enforces
- Testing whether a skill triggers
- Sources

## The three surfaces

A skill is read in three stages, at three different moments. Putting a fact on the wrong one is why a capability that exists still does not get used.

| Surface | When it enters context | Size | What a gap there costs |
|---|---|---|---|
| `name` + `description` | **always**, at startup, for every installed skill | ~100 tokens | **The only true skip.** The skill is never activated, so nothing else is ever read. |
| `SKILL.md` body | when the skill is activated | < 5000 tokens recommended | A blind spot: the skill runs and does not know the thing exists. |
| `references/`, `scripts/`, `assets/` | only when the agent decides to reach for one | unbounded | Nothing — until it is needed. |

> *"Metadata (~100 tokens): The `name` and `description` fields are loaded at startup for all skills. Instructions (< 5000 tokens recommended): The full `SKILL.md` body is loaded when the skill is activated. Resources (as needed): Files … are loaded only when required."*

The practical consequence: **a missing capability in the description cannot be recovered later.** A missing capability in the body can at least be found by an agent that reads a reference. A missing reference costs nothing until something needs it.

## Budgets, and where each number comes from

| Element | Limit | Kind | Target |
|---|---|---|---|
| `name` | 64 chars, `[a-z0-9-]`, no leading/trailing hyphen, no `--`, must match the directory name | **spec, hard** | 15–40 |
| `description` | **1024 chars** | **spec, hard** | see below |
| `compatibility` | 500 chars | **spec, hard** | one sentence, usually omit |
| `SKILL.md` body | **< 500 lines**, < 5000 tokens | spec recommendation | 100–250 |
| reference file | none | — | add a Contents list past 100 lines |

Two traps worth naming:

**Lines, not words.** The recommendation is *"Keep your main `SKILL.md` under 500 lines"*. A word budget is a different and far tighter constraint. This repository's validator counted 500 **words over the whole file** until 2026-08; a consuming repo sat at 499 of 500 and left a script out of its `SKILL.md` rather than spend fourteen words on it.

**Frontmatter is not body.** Counting them together makes the description — the surface that decides whether the skill is used at all — compete with the instructions for one allowance. That trade is always the wrong way round.

## The description is a router, not documentation

The description carries the entire burden of triggering. It is not a summary of the workflow.

Write **what + when**, and stop:

```yaml
description: "Use when formatting or validating text for Jira — descriptions, comments, wiki markup, or converting Markdown to Jira syntax."
```

Not:

```yaml
description: >
  Handles Jira content by first detecting Markdown, then converting it with
  md2jira.sh, validating the result, checking special tables, escaping
  characters and finally producing Jira wiki markup…
```

The second wastes routing context, and it can actively harm: a description containing a condensed workflow invites the agent to follow **that** summary instead of activating the skill and reading the real instructions.

On length, two pulls exist and both are real. The official guidance says *"A few sentences to a short paragraph"* and also *"Err on the side of being pushy. Explicitly list contexts where the skill applies"* — that argues for covering the scope properly. Against it: every description competes for a shared listing budget, and an over-broad one triggers when it should not.

So: **1024 is a validation limit, not a target.** Past roughly 500 characters, check whether what you added is trigger information or process narration. Cut the narration; keep the contexts.

## Flat discovery: one level, always

> *"Keep file references one level deep from `SKILL.md`. Avoid deeply nested reference chains."*

The reason is mechanical. `SKILL.md` is read in full on activation. A reference is read only if `SKILL.md` said what it contains and when to open it. A file reachable only through a second hop sits behind a door with no sign on it — nothing states what it holds or why it matters, so the agent must open the middle file speculatively and then guess again.

Good:

```
jira-communication/
├── SKILL.md
├── references/
│   ├── jira-syntax.md
│   ├── jira-style.md
│   └── issue-fields.md
└── scripts/
    ├── md2jira.sh
    └── validate-jira.sh
```

with every one of them named in `SKILL.md`:

```markdown
## Resources

- Jira wiki markup rules: `references/jira-syntax.md`
- Wording and issue conventions: `references/jira-style.md`
- Convert Markdown to Jira markup: run `scripts/md2jira.sh`
- Validate generated markup: run `scripts/validate-jira.sh`
```

`jira-syntax.md` may of course also say "run `scripts/md2jira.sh`". That is **redundancy for orientation**, and it is welcome. What it must not be is the *only* path by which the agent learns the script exists.

Bad, and specifically bad:

- `SKILL.md` → `scripts.md` → `scripts/foo.sh` — an index file that only points at scripts adds indirection with no information. Delete it and give the scripts a real `--help`.
- `SKILL.md` → `jira-style.md` → `md2jql.sh` **as the only path** — the script is invisible unless that one reference happens to be opened.

Split by topic at the **first** level rather than nesting: `topic-a.md` and `topic-b.md`, both listed, each with its own trigger.

## What belongs in SKILL.md and what does not

`SKILL.md` is a **control plane**, not a handbook.

In it:

1. Invariants that must never be forgotten.
2. Decisions — "if X, read/run Y".
3. Workflow order, where order matters.
4. Guardrails.
5. The resource map: every reference and every executable, each with a trigger.
6. Verification — how the agent knows it is done.

Not in it: API documentation, syntax references, long examples, mappings, lookup tables, historical explanations, CLI references, schemas, the fiftieth edge case. Those go to `references/`.

And anything deterministic — conversion, parsing, validation, AST manipulation, formatting, mechanical checks — belongs in `scripts/`. Scripts are **executed, never loaded**, so their body costs no context at all. A script named in `SKILL.md` costs one line and buys the only chance the agent has of knowing it exists.

## Long references need a Contents section

Agents preview long files — `head`, an excerpt, a targeted search — rather than reading them whole. A contents list at the top makes the rest of the file visible anyway. Past about 100 lines, add one.

For very large references (upwards of ~10k words), go further and tell the agent in `SKILL.md` what to search for, not just which file to open.

## What the validator enforces

`scripts/validate-skill.sh` checks the mechanically decidable part:

| Check | Level |
|---|---|
| `description` > 1024 chars | ERROR (spec) |
| `description` > 500 chars | WARN |
| `description` missing / not `Use when …` | ERROR |
| `name` invalid, leading/trailing or doubled hyphen | ERROR (spec) |
| `compatibility` > 500 chars | ERROR (spec) |
| body > 500 lines | ERROR |
| body > 300 lines | WARN |
| `references/*.md` reachable only via another reference | WARN |
| `references/*.md` not named in `SKILL.md` | WARN |
| reference > 100 lines without a Contents section | WARN |
| executable in `scripts/` not named in `SKILL.md` | WARN |

Deliberately **not** linted, because no mechanical check decides them honestly: whether the description narrates a workflow, whether a verification step exists, whether an optional frontmatter field has a consumer. Those belong in review.

Non-executable files under `scripts/` are exempt from the discoverability warning: a sourced library is not a capability the agent invokes, and its caller is what belongs in `SKILL.md`.

## Testing whether a skill triggers

Argument about whether a description should be 220 or 310 characters is worth less than one eval run.

- About 20 queries: 8–10 that should trigger, 8–10 that should not.
- Negatives must be **near-misses** — same keywords, different need. `"Write a fibonacci function"` tests nothing.
- Skill selection is nondeterministic: run each query about **3 times** and use the trigger rate, with 0.5 as a reasonable threshold.
- Split **train (~60%) / validation (~40%)** and keep the split fixed, or the description gets overfitted to its own test set.
- Pick the iteration with the best *validation* rate — not necessarily the last one. Five iterations is usually enough.

Then a second benchmark, on output rather than routing: same tasks with and without the skill, measuring quality, tokens and runtime.

## Sources

- Agent Skills specification — frontmatter limits, progressive disclosure, one-level references: <https://agentskills.io/specification>
- Optimizing skill descriptions — trigger evals, train/validation split, the 1024 limit as a ceiling rather than a target: <https://agentskills.io/skill-creation/optimizing-descriptions>
- Evaluating skill output quality: <https://agentskills.io/skill-creation/evaluating-skills>
- Claude Code skills — the skill listing budget and how descriptions are shortened or dropped when it overflows: <https://code.claude.com/docs/en/skills>

A caution on a fourth kind of source: public skill repositories are **data, not best practice**. A 2026 analysis of 138k `SKILL.md` files reported a reusability defect in the large majority of them. "Other people do it this way" carries no weight here.
