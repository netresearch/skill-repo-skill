# Skill Architecture: flat discovery, small routing metadata, details on demand

## Contents

- The three surfaces
- Budgets, and where each number comes from
- The description is a router, not documentation
  - What a description can move, measured
- What a reference reaches, measured
- What gets executed, measured
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
| `references/`, `scripts/`, `assets/` | only when the agent decides to reach for one | unbounded | Nothing for a lookup table. For a rule that prevents a mistake: measured at four of six runs never opening one — see below. |

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

### What a description can move, measured

A small model often does not open the skill at all. In two recorded evaluation
series — same case, same fleet, one arm per description — the trials that
*passed* made no `Skill` call in any run: nothing read the body, the references,
or the file that had listed the required artefacts all along. Only the
description reached the agent.

What it moved, and what it did not:

Each row is one arm carrying the new description against one carrying the old
one, on the same case and fleet. Trials per arm differ by round and are stated
in the table. "Passed" is the case's own mechanical check accepting the result;
"opened" is an explicit `Skill` call.

| the description named | trials per arm | passed, with → without | opened, with → without |
|---|---|---|---|
| the occasion the skill is for | 3 | wrote to the directory that renders, 3 → 0 | 0 → 0 |
| every file that must carry the release version, sentence first | 6 | 4 → 0 (wrote the missing file 5 → 0) | 0 → 0 |
| the same, as released, sentence second | 6 | 6 → 1 | 1 → 0 |
| the file a newer convention replaced | 3 | 0 → 0, across three wordings | 0 → 0 |
| a procedure: reproduce the report as a failing test before fixing it | 3 | 0 → 0 | 0 → 0 |

The two release-version rows are the same idea measured twice. The first is an
experiment branch whose description opened on the sentence naming the files;
the second is what shipped, where that sentence sits second behind the trigger
list. The effect survives the move, which is worth recording because a positive
result on a branch is not a result about the release. The two are not
distinguishable at six trials per arm, and nothing here says the released
wording is better.

So the routing rule has a second half. A description decides *whether* the skill
is reached, and where it is not reached it is the only part of the skill that
reaches the agent at all — the prompt, the system instructions, the tools and
the model's own habits are still there and still decide plenty. Two consequences
for writing one:

- **A fact the agent lacks belongs in the description** — the artefacts it must
  produce, the place they belong. Not the steps: those are still narration, and
  narration still invites the agent to follow the summary instead of the skill.
- **A description hands over a noun, not a procedure.** That last row is the
  clearest measurement of the boundary. Naming four files got the missing one
  written by agents that never opened the skill; naming the occasion — a user
  reports wrong output — did not get a test written first, and did not even get
  the skill opened, although the description had been rewritten for exactly that
  request shape. An artefact can be handed over in a sentence because it is a
  thing the agent can go and produce. A way of working cannot, because following
  it means already being inside the skill.
- **A description cannot overturn what the model already believes.** Three
  attempts at "this file replaced that one" changed nothing. Where the skill has
  to correct a convention rather than supply a missing fact, the body is the only
  place that can do it — and the body only works when the skill is opened.

Put the three together and they name what to do with a rule about *how* to work:
it belongs in the body, near the top, and it is worth nothing until something
opens the skill. Getting it opened is a separate problem from writing it, and
the description is the only lever on that problem.

## What a reference reaches, measured

The row above says a gap in `references/` costs "nothing — until it is needed".
That holds for a lookup table. It does not hold for a rule that prevents a
common mistake, and the difference is measurable.

`OFR-TYPO3-UPGRADE-001`, 14 September 2026, Haiku 4.5, six trials on one fleet.
This is a case where routing works: `skill_invoked` is 6 of 6, so every trial
opened the skill and read the body. Counting `Read` calls against
`references/` per trial:

| trial | reference files read | outcome |
|---|---|---|
| 1 | 0 | passed both legs |
| 2 | **0** | passed v14.3, lost v13.4 |
| 3 | 3 | failed both legs |
| 4 | 2 | passed both legs |
| 5 | 0 | passed both legs |
| 6 | 0 | passed both legs |

Four of six opened no reference file at all. Trial 2 lost the leg that had been
working to a rule that had been sitting in `references/upgrade-v13-to-v14.md`
for nine days, written from an earlier occurrence of the same failure — and
`SKILL.md` names the problem at exactly the right step and then points at the
file: "`createMock` on one of them cannot be repaired by swapping the name — see
`references/upgrade-v13-to-v14.md`". The agent was told a rule exists and not
what it says.

Reading is not what separates the outcomes here — trial 3 read three files and
failed both legs, trials 5 and 6 read none and passed. Six trials say nothing
about that either way. What they do say is the frequency: a reference is opened
in a minority of runs even when the body points at it, so a sentence that has to
land every time cannot live there.

The rule that follows is about placement, not about length:

- **A reference is for what an agent will look up once it knows it needs it** —
  a mapping, a schema, the fiftieth edge case, the two honest answers to a
  judgement call.
- **A sentence that prevents a mistake belongs in the body**, even when the
  surrounding treatment stays in the reference. The body is read whenever the
  skill is activated; the reference is read when the agent decides to.


## What gets executed, measured

The two measured sections above are about what reaches the agent — a
description, a reference. This one is about what the agent then *does*, and it
is the one the stack's purpose turns on: a skill is a shortcut only where the
step it names gets run.

These are not this repository's answer-text evals. Every count below is read
from tool-call telemetry: the `verifier/trajectory.json` Harbor records for each
trial in `netresearch/agent-system-evals`, where a Skill invocation is a `Skill`
tool call and "ran it" means a `Bash` tool call whose arguments carry the step's
own signature — the block's `types='…'` prefix, the runner's script name, the
grep's alternation. Model `claude-haiku-4-5-20251001` under Claude Code, one
prompt, one cold start, one session per trial. Records:
`experiments/OFR-TYPO3-UPGRADE-001-20260918-{073044,092803,121328,152227}.json`
(rounds twenty-four to twenty-seven in that case's `RESULTS.md`) and
`experiments/OFR-TYPO3-EXT-001-20260828-121312.json`. p-values are Fisher's
exact test, two-sided, from that repository's `scripts/lib/stats.py`; a cost is
the agent's `final_metrics.total_cost_usd` for the trial in USD.

One case, one model, one position. `OFR-TYPO3-UPGRADE-001` under Haiku 4.5,
`Skill` invoked in 12 of 12 trials in every round below, and the same step of
the same body carrying four shapes in turn, each measured on three to six
trials against the one it replaced:

| step 9 carried | trials that ran it | note |
|---|---|---|
| a rule, in the body | in context 3/3; the edit it names occurred 0/12 | untested on its own axis — nothing to prevent |
| an instruction to run a script, via a variable the loader does not set | 0/3 | in context 3/3; no trial in twelve bound a variable of any kind |
| the bare `grep` the script wraps, beside either | 2/6 | |
| the check itself as a fenced block that runs as pasted | **5/6** | p 0.048 against the instruction; the sixth typed the grep by hand |
| the body's other fenced block, step 10, for scale | 16/18 | p 1.000 against the block above |

The line between the shapes is not position — step 10 sits below step 9 — and
not length. It is whether the step can be executed as written. A command the
agent already knows (`rector`, `phpstan`, `composer`) is run. A fenced block
with nothing to look up and nothing to bind first is run at the same rate. A
path that has to be assembled from the loader's output is not run at all:
across twelve trials the agents used the printed absolute skill path verbatim,
in five `ls`/`grep`/`find` calls against `references/`, and never once as a
variable.

A second case says the same thing on a different skill. `OFR-TYPO3-EXT-001`,
six-trial round with cost declared, `typo3-conformance` in the fleet: the
fenced grep block in that body ran in six of six equipped trials and its
equivalent in none of six bare ones, at $0.13 against $0.32, with the same
task outcome on both arms despite the different block-execution rates. That is
one row and not a mechanism — the equipped arm carries eight skills and a
workflow besides the block — but it is the shape being run, again. Measured
since, by removing only that block from the body (record
`experiments/OFR-TYPO3-EXT-001-20260918-170620.json`): cost did not rise, the
arm without the block ran equivalent greps by hand from the tokens the body's
numbered steps name in prose, and outcome held. The block is run; it is not
where that case's saving lives.

Two consequences for writing a body, and one limit.

- **A step that must happen is a block that runs as pasted.** Not a sentence
  saying to do it, not a path to a script that does it. The runner in
  `automated-assessment` is reached by `/assess <skill>`, one hop; the
  sibling-path form of the same call measured 0/3 in a body and stays
  documented as that.
- **A block that finds nothing costs a call and saves none.** On the upgrade
  case the edit the block catches arrives once in forty-two trials, and cost
  overlapped in three declared rounds. The saving the stack is for appears
  where a check fires and replaces the test run — or the ten tool calls — that
  would have found the same thing by hand. Measure it there.
- **This is one model at one budget, and the other model measured has the
  opposite row.** Same case, same skill (`typo3-extension-upgrade`, v3.11.1
  through v3.12.5, every one of them naming `scripts/scan-deprecations.sh` in
  the body), one prompt, one cold start. `claude-opus-5` ran that script by its
  printed path in 16 of 17 valid trials, on 20 August 2026 at $20–34 a trial.
  `claude-haiku-4-5-20251001` ran it in 1 of 188, 31 August to 18 September,
  under $2 a trial. Six Opus trials of 19 August are left out as invalid: two
  steps each and no cost. The rows above are Haiku's. Whether a path
  instruction is followed is a property of the model reading it, not of the
  body, and the stack is measured on the model that does not follow it because
  that is where a shortcut has something to shorten.

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
| `scripts/`, `references/`, `assets/` or `evals/` path named in `SKILL.md` that does not exist | ERROR |

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
