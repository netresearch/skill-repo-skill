# README structure for Netresearch skill repositories

Human-facing documentation for a skill repo. **Marketplace** pages may summarize this content but must not become the only place where these facts exist.

**Boilerplate generator:** [`../templates/README.md.template`](../templates/README.md.template) — align templates with the headings below when updating scaffolding.

---

## First screen (above-the-fold)

Without long scrolling, the reader must see answers to:

1. **What problem does this skill solve?**
2. **When should it be used?**
3. **What does it produce?**
4. **What inputs or project context does it need?**
5. **How do I install it or find it in the marketplace?**

---

## Required Markdown sections (English)

Use **exact** level-2 headings so agents can grep them:

- `## What this skill solves`
- `## Why this is a skill (model delta)` — the claimed value category/categories from the content value rubric ([`skill-quality.md`](skill-quality.md)), **one sentence** on what the model does wrong without the skill, and a pointer to eval evidence (`evals.json` id or dashboard delta) where it exists. Distinct from `## What this skill solves`: that section names the problem; this one justifies why a skill (not the base model) solves it.
- `## Use when`
- `## Expected outputs`
- `## Context requirements`
- `## Example prompts` — **minimum three** fenced or bulleted realistic prompts (distinct scenarios).
- `## Related skills` — slugs/URLs **or** explicit `none (justified: …)`.
- `## Installation` — must include Netresearch marketplace path (`/plugin marketplace add netresearch/claude-code-marketplace`) **or** pointer to org-standard install doc.
- `## Contributing`
- `## License`

**Optional (skills that ship a `commands/` dir):** `## Commands` — a table or
list enumerating **every** slash-command **and each of its modes / sub-commands
/ flags**. When you add or rename a command *or a mode*, update this list in the
**same change** — the implementation, its reference docs, and the README/AGENTS
menus drift apart otherwise (a mode added everywhere except the README menu is a
common, user-visible miss). `validate-skill.sh` warns when a command's `/<name>`
(from `commands/<name>.md`) is not mentioned in the README, but it cannot see
mode-level drift — that part is on the author.

**Optional:** `## German summary` — short paragraph if DACH/TYPO3/Oro/agency audience; technical detail may remain English. The scaffold [`../templates/README.md.template`](../templates/README.md.template) ships this as a **commented block** after `## License` — uncomment when needed.

---

## Voice: present tense, never narrate change

Reference docs (README, `SKILL.md`, reference files, module headers) describe **what the skill is and how to use it, in plain present tense — as if it had always been this way**. They must **not** describe the skill by what it is *not* or how it *changed*.

- **Banned framing:** "no longer", "instead of", "reframed", "previously", "used to", "X derives from Y / downstream … not its source", "it is **not** a router/wrapper/…". This is the *curse of knowledge* as **negative / apophatic documentation** — it only parses for a reader who knew a prior design.
- **Before the first release there is no audience for change.** Nobody ran a prior public version, so any before/after framing is noise and actively misleads (readers hunt for a "router" that never existed). The same holds for unreleased, in-between edits: the diff *is* the commit; the README must not know a change happened.
- **History lives only in `CHANGELOG` / `UPGRADING` / release notes / ADRs / the commit log** — those have a reader (someone upgrading from a version they used) who needs the contrast. The README and `SKILL.md` never do.
- A deprecation notice ("X is deprecated, use Y") is the one legitimate non-history contrast and belongs in the changelog/upgrade doc, not the "what this is" sections.

---

## Cross-checks (machine-friendly)

| Check | PASS criterion |
| --- | --- |
| `Why this is a skill (model delta)` | Names ≥1 rubric value category, states one model-without-skill failure, links eval evidence where it exists. |
| `Use when` | Section exists and contains trigger phrases (ticket prefixes, stacks, commands). |
| `Example prompts` | ≥3 prompts. |
| `Related skills` | ≥1 link/slug **or** justified none. |
| `Installation` | Mentions marketplace **or** documents exclusive alternate with owner approval in README. |
| Present-tense voice | `grep -rin -e 'no longer' -e 'reframed' -e 'previously' -e 'used to' -e 'derive' -e 'downstream' -e 'not its source' -e 'is not a router'` over README/`SKILL.md` returns nothing — change-narration belongs in `CHANGELOG`/`UPGRADING`. |
| `Commands` (if `commands/` exists) | Every `commands/<name>.md`, and each mode/flag it documents, is enumerated in the README. |

---

## Alignment with other files

- **Discovery YAML** (optional): [`skill-discovery-metadata.md`](skill-discovery-metadata.md) — keep summaries consistent with README sections.
- **`agents/openai.yaml`**: short end-user description; must not contradict README summaries.
- **GitHub**: see [`repository-quality-rules.md`](repository-quality-rules.md) for description/topic rules.
