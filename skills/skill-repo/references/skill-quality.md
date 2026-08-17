# SKILL.md Quality Rules — Detail and Examples

Detailed guidance backing the summary in [`SKILL.md`](../SKILL.md) (§ SKILL.md Quality Rules).

## Why these rules exist

Claude Code skills have two distinct context costs:

- **Listing cost (per turn):** Only `name`, `description`, and optional `when_to_use` from each skill's frontmatter enter context on every assistant turn — whether the skill is invoked or not. Per-skill cap: 1,536 chars (`skillListingMaxDescChars`). Total listing cap: `skillListingBudgetFraction × context_window` (default `0.01`).
- **Body cost (per invocation):** The full SKILL.md body loads when the skill is invoked, and persists for the rest of the session. Reference files (`references/*.md`) are **not** auto-loaded — the model only reads files it sees referenced.

Description bytes are the always-on tax; body bytes are the on-demand tax. References are free unless the model knows they exist and decides to read them.

## Content value rubric

Size rules bound how MUCH a skill costs; this rubric bounds WHAT KIND of content earns that cost. Every passage in a SKILL.md body or reference file must provide at least one of six value categories:

1. **Org/project-specific knowledge** — Netresearch conventions, internal tooling, URLs, field IDs, policy decisions. (`jira` custom-field IDs; the split-licensing model.)
2. **Version/ecosystem facts models get wrong** — post-training-cutoff changes, version-specific breaking changes, niche tool flags. (TYPO3 v14 `#108055` asset-concat removal; golangci-lint v2 config.)
3. **Retro-born failure patterns** — symptom → cause → required behavior → verification, encoded from a real incident. (`github-project`: the auto-approve/Copilot race.)
4. **Executable scripts/validators** — deterministic work shipped in `scripts/` or `checkpoints.yaml` instead of prose the model re-derives.
5. **Inference suppression** — "read file X, never guess Y" rules that shut down a known guessing pattern and its retry cost. (`typo3-ddev`: never guess backend URLs — read `.ddev/config.yaml`.)
6. **Anti-rationalization guards** — rules that stop the model from skipping steps or over-claiming. ("No 'tested' claim without pasted command output.")

**Generic bloat** is content that provides none of these: restated public best practice a one-line prompt regenerates ("write tests first", "use parameterized SQL", tutorials paraphrased from public docs). The test, from Den Odell's essay (see Sources): *if you can generate the passage with a prompt, the skill doesn't need to carry it.*

Two protections when applying the rubric:

- Categories 3 and 5 are **first-class even when they read as prose**. Reducing wrong or unnecessary inference counts as value although the model "knows" the underlying facts — a skill that surfaces the right rule at the right moment saves the retry tokens the guess would have cost. Do not cut a failure pattern or a never-guess rule because it "looks like advice".
- A claimed activation/recall benefit ("the model knows this but forgets") is an eval claim: back it with an A/B delta (repo-root `scripts/run-ab-evals.sh`) rather than asserting it. See "Eval evidence" below for what that delta does and does not say.

## Eval evidence

Whether an eval can carry evidence at all — every eval needs at least one
assertion a no-skill baseline fails — is specified in
[`materialization-contract.md`](materialization-contract.md) ("Quality rule:
every eval needs a delta-discriminating assertion"), together with the
`samples` self-check. What follows is the other half: how to report a number
once you have one.

### A delta belongs to an actor, not to a skill

```text
delta = f(skill version, model, agent harness, task, tool environment)
```

So `docker-development has +23%` is not a statement anyone can check. The
reportable form names the tuple:

```text
docker-development@2.4.0 · claude-code 2.0.31 · model sonnet
· eval-set evals.json@09cc52ef (24 evals) → +23% over the no-skill baseline
```

Every run prints that line and stores the same fields under `provenance` in
`ab-results.json`, so a published number can be traced to the text, the actor
and the questions that produced it. Quote them together — in a PR that
justifies skill content, in the dashboard, in a release note.

Two consequences worth stating, because they cut in opposite directions:

- **A stronger actor can erase a delta.** If a later model derives the same
  content unaided, the skill stops buying behaviour and only costs context.
  That is a reason to re-measure on the current actor before defending a
  passage, not a reason to keep the old number.
- **A weaker delta is not always a weaker skill.** A harness that is bad at
  skill discovery scores the skill poorly although the skill is fine. The
  per-skill A/B eval assumes the skill is already loaded, so it cannot see
  that failure at all — that is what the system-level evals in
  [`netresearch/agent-system-evals`](https://github.com/netresearch/agent-system-evals)
  measure, by giving the agent a realistic underspecified request that names
  no skill, tool or method.

### Fact and trigger ownership

Each fact and each trigger phrase has ONE canonical owning skill in the catalog; every other skill cross-references instead of restating. Duplicated facts drift apart at the next release, and duplicated trigger phrases compete for the model's skill selection. (Example: TYPO3 v14 breaking-change facts are owned by `typo3-conformance`; upgrade-execution phrasing by `typo3-extension-upgrade`; siblings link, they do not repeat.) This is the content-level twin of the discovery-level Mirroring rule in [`repository-quality-rules.md`](repository-quality-rules.md) — one canonical surface per fact, links from everywhere else.

## Description rules

### Caps

- **Hard cap: 1,536 chars** — Claude Code truncates above this regardless of budget.
- **Target: 100–300 chars** — fits comfortably in the listing, leaves headroom for other skills.
- **Justify above ~500 chars** — long descriptions are reasonable when they enumerate triggers (e.g., ticket-key prefixes, file-extension lists). Keep the structure tight.

### Position matters

Truncation is position-based. Put your primary trigger first. The convention is `Use when <trigger>` as the opener.

### Anti-patterns

| Anti-pattern | Example |
|---|---|
| Marketing language | "blazingly fast", "powerful", "comprehensive" |
| Vagueness | "a tool to help with X", "general-purpose helper" |
| Restating the skill name | `description: "The frobnicator skill frobnicates."` |
| Redundancy with body | duplicating the skill's intro paragraph in both fields |

### Examples

**Good:**

```yaml
description: "Use when reviewing your diff, writing a commit message, or asking what changed. Summarizes uncommitted changes and flags risky patterns."
```

**Bad:**

```yaml
description: "A comprehensive solution for managing your repository state with advanced semantic understanding"
```

## Body rules

### Size

Body loads on invocation and persists for the rest of the session. The threshold goal is **per-invocation token cost** — every additional word in the body is paid every time the skill is invoked. Move what isn't strictly needed at decision time into `references/` (lazy-loaded when SKILL.md instructs).

Word count translates to tokens at roughly 1.4× (English prose; code fences run higher). `audit-skills.sh` reports three tiers:

- **INFO above 500 words** (~700 tokens) — modest cost; skim for split candidates.
- **WARN above 1,000 words** (~1,400 tokens) — almost any body at this size has lookup content that could move to references.
- **FAIL above 2,000 words** (~2,800 tokens) — body is acting as a manual; split required.

These tiers are advisory across the wider skill ecosystem. **This repo enforces a stricter 500-word hard cap on its own SKILL.md** (via `skills/skill-repo/scripts/validate-skill.sh`) — that is the per-skill house rule, not a universal claim. Treat the audit tiers as triage levels for any skill repo; treat the 500-word cap as policy for the canonical skill-repo template. Several Netresearch skill repos (git-workflow, github-project, github-release, jira, …) ship the same `validate-skill.sh` hard cap, so treat any body ≥ ~490 words as hard-capped, not soft.

**Adding to a body already near the cap:** measure first (`wc -w` / `scripts/audit-skills.sh`), then land the addition in a single budgeted pass — put the detail in `references/` and add only a minimal pointer (one Critical Rule line or one reference-table row) to the body, and trim an equal number of words from the fattest existing lines (verbose reference-table descriptions are the usual give) in the same edit. Iterating one or two words at a time across repeated re-validations wastes cycles. Gotcha: `wc -w` counts a spaced slash (`a / b`) as three tokens, so slash-separating during a trim can *raise* the count — use commas (`a, b`).

Empirical anchor: the Netresearch skill corpus (n=52) has p95 ≈ 994 words. WARN at 1,000 catches the actual outliers in our own work. Anthropic's longer skills (e.g., `writing-skills` at 3,193 words) FAIL under this rule — that's the honest signal: even shipped skills can have content moved out. We can't fix theirs; we hold ourselves to the rule.

- **Bloat signals**: body >3 KB, body >150 lines, single fenced code block >25 lines (long code examples are the primary lazy-load target).

### When to split to `references/`

Move to `references/<topic>.md` when content is:

- Long examples (>20 lines)
- Configuration templates
- API/syntax tables
- Migration matrices
- Detailed checklists
- Repository directory trees (often the worst offenders)

Keep in SKILL.md body:

- High-level workflow
- The "what does this skill do" summary
- A reference catalog (see Pattern 2 below) when there are many topic-files
- One canonical quick example

## Reference patterns

Every `.md` file in `references/` must be discoverable to the model **from SKILL.md**. Three acceptable patterns:

### Pattern 1: Direct cite

```markdown
For form validation, see [`references/forms.md`](references/forms.md).
For multi-profile auth, see [`references/multi-profile.md`](references/multi-profile.md).
```

Best for **≤10 reference files**. Each gets a one-line cite with the path. The model sees the path on invocation and reads on demand.

### Pattern 2: Catalog-with-convention

```markdown
## Reference Files (in `references/`, `.md` implied)

- **Frameworks** (`*-security`): react, vue, angular, nextjs, nuxt
- **Languages** (`*-security-features`): php, python, go, rust, javascript-typescript
- **Cloud** (`*-security`): aws, azure, gcp
```

Best for **10+ topic-grouped files**. The model sees:

- The directory (`references/`)
- The filename suffix convention (`-security`, `-security-features`)
- The list of stems

It can resolve any combination on demand. The `security-audit` skill uses this pattern for ~60 reference files in ~12 lines of body content.

### Pattern 3: List-and-pick

```markdown
For language-specific guidance, list `references/` and read the file matching your stack.
```

Use sparingly — burns a tool call (the model has to enumerate the directory). Useful when there's no naming convention but the directory is small.

### Anti-pattern: Hub-and-spoke

```markdown
# DON'T DO THIS

In SKILL.md:
> See [references/index.md](references/index.md) for the catalog of references.

In references/index.md:
> - [forms.md](forms.md)
> - [auth.md](auth.md)
```

Multi-hop traversal isn't reliable. Anthropic's docs phrase the rule as "Reference supporting files from SKILL.md so Claude knows what each file contains" — direct visibility from SKILL.md is the model. The hub gets read but its leaves aren't deeply traversed. Anthropic's published skills use flat / catalog patterns, never hub-and-spoke.

### Anti-pattern: Orphan refs

Files in `references/` with no path to discovery from SKILL.md (no direct cite, no catalog mention, no list-and-pick instruction). The model never reads them. Either cite them or delete them — they consume disk and signal "stale" to readers without contributing to the skill's behavior.

## Auditing

Run `scripts/audit-skills.sh` from the repo root. It scans SKILL.md files for:

- Description length violations (warn >500 chars, fail >1,536)
- Body length tiers (info >500 words, warn >1,000, fail >2,000)
- Long code fences (info >25 lines — primary lazy-load candidate)
- Orphan refs (files in `references/` not reachable by any pattern)

Pattern 2 detection is heuristic: a reference file counts as P2 when its stem matches a convention stated in SKILL.md (filename suffix or topic-list pattern). Files outside any P1/P2/P3 path are reported as ORPHAN.

## Sources

- Anthropic Claude Code docs on skills: <https://code.claude.com/docs/en/skills>
- Anthropic published skills: <https://github.com/anthropics/skills>
- Settings schema: `skillListingBudgetFraction`, `skillListingMaxDescChars` (Claude Code settings.json)
- Den Odell, "The Great Agent Skills Land Grab": <https://denodell.com/blog/the-great-agent-skills-land-grab> — the generate-it-with-a-prompt test and the eval-evidence bar for activation/recall claims
- Xiong et al., "How Memory Management Impacts LLM Agents: An Empirical Study of Experience-Following Behavior", ACL 2026: <https://aclanthology.org/2026.acl-long.27/> — inaccurate past experience compounds into later runs, and executions that look correct can still be misleading as experience; the paper's proposal is to use later task outcomes as quality labels, which is what `/retro outcome` does
