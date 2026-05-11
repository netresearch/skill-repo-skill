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
- `## Use when`
- `## Expected outputs`
- `## Context requirements`
- `## Example prompts` — **minimum three** fenced or bulleted realistic prompts (distinct scenarios).
- `## Related skills` — slugs/URLs **or** explicit `none (justified: …)`.
- `## Installation` — must include Netresearch marketplace path (`/plugin marketplace add netresearch/claude-code-marketplace`) **or** pointer to org-standard install doc.
- `## Contributing`
- `## License`

**Optional:** `## German summary` — short paragraph if DACH/TYPO3/Oro/agency audience; technical detail may remain English. The scaffold [`../templates/README.md.template`](../templates/README.md.template) ships this as a **commented block** after `## License` — uncomment when needed.

---

## Cross-checks (machine-friendly)

| Check | PASS criterion |
| --- | --- |
| `Use when` | Section exists and contains trigger phrases (ticket prefixes, stacks, commands). |
| `Example prompts` | ≥3 prompts. |
| `Related skills` | ≥1 link/slug **or** justified none. |
| `Installation` | Mentions marketplace **or** documents exclusive alternate with owner approval in README. |

---

## Alignment with other files

- **Discovery YAML** (optional): [`skill-discovery-metadata.md`](skill-discovery-metadata.md) — keep summaries consistent with README sections.
- **`agents/openai.yaml`**: short end-user description; must not contradict README summaries.
- **GitHub**: see [`repository-quality-rules.md`](repository-quality-rules.md) for description/topic rules.
