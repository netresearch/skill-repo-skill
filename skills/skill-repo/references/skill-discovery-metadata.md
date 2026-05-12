# Skill Discovery Metadata (repository scope)

Defines **skill-repo-local** discovery and classification data.  
**Does not** replace the marketplace catalog — the marketplace aggregates and may normalize display. Governance for marketplace listings is in **`netresearch/claude-code-marketplace`/`AGENTS.md`**.

---

## Where metadata lives

| Kind | Allowed location | Forbidden |
| --- | --- | --- |
| Runtime triggers, workflow | `SKILL.md` body + `references/` | — |
| Minimal listing | `SKILL.md` frontmatter: **`name`**, **`description`** only (plus optional technical keys allowed by [`validate-skill.sh`](../scripts/validate-skill.sh): `license`, `compatibility`, `metadata`, `allowed-tools`) | Discovery-only keys (`slug`, `category`, `tags`, …) in frontmatter |
| Discovery / SEO / partner fields | `README.md` (sections), optional `metadata/discovery.yaml` or equivalent **outside** `SKILL.md`, `agents/openai.yaml`, GitHub repo settings | Duplicating full `SKILL.md` body into README |

**Rule:** `SKILL.md` describes **how the agent behaves**. Marketplace-oriented fields belong in README or a separate metadata file consumed by humans/tools — **not** stuffed into frontmatter beyond `name`/`description` (and optional technical keys above).

---

## Recommended discovery YAML (optional file)

Place at repo root or under `metadata/` — **not** inside `SKILL.md`. Example schema:

```yaml
slug: typo3-vite
display_name: TYPO3 Vite Frontend Pipeline
summary:
  en: >
    Configures Vite for TYPO3 v13+ with vite-asset-collector, SCSS entrypoints, and CSP-safe asset URLs.
  de: >
    Richtet Vite für TYPO3 v13+ mit vite-asset-collector, SCSS-Entrypoints und CSP-tauglichen Asset-URLs ein.
category: typo3-frontend
tags:
  - vite
  - typo3
  - scss
  - frontend
use_cases:
  - Bootstrap a Vite pipeline for a TYPO3 sitepackage.
  - Split CSS/JS entrypoints per content element.
expected_outputs:
  - Vite config and npm scripts aligned with vite-asset-collector.
  - Documented build and deployment steps for frontend assets.
context_requirements:
  - TYPO3 v13+ sitepackage or extension with asset collector available.
  - Node.js LTS matching project policy.
action_level: modifies_files
risk_level: medium
related_skills:
  - typo3-frontend-patterns
  - dxp-frontend
example_prompts:
  - "Add Vite 7 to our TYPO3 13 sitepackage with SCSS partials per content element."
  - "Wire vite-asset-collector entrypoints for tt_content templates."
primary_keywords:
  - vite
  - typo3
  - sitepackage
```

Fields:

- **`slug`**: stable id; usually matches plugin/skill name.
- **`display_name`**: public title (may differ from `name` in `SKILL.md`).
- **`summary.en` / `summary.de`**: one short paragraph each; `de` optional unless DACH/TYPO3/Oro focus. **`summary.en` should be ≤ 300 chars** (snippet-friendly target; the marketplace enforces a hard cap of 500).
- **`category`**: **one of** the canonical marketplace categories — `development`, `devops`, `security`, `design`, `workflow`, `productivity`. Keep this in sync with the marketplace `AGENTS.md` canonical list; do not invent ad-hoc values.
- **`tags` / `use_cases`**: for README tables and marketplace sync.
- **`expected_outputs` / `context_requirements`**: must mirror README sections (single source: generate README from this file or maintain parity explicitly).
- **`related_skills`**: slugs or full GitHub URLs; see [`repository-quality-rules.md`](repository-quality-rules.md). Entries that don't yet exist in the catalog can be tagged `(planned)` or `(external)` — never invent fake links for SEO.
- **`example_prompts`**: align with README **Example prompts** (≥3 in README per checklist).
- **`primary_keywords`**: align with GitHub Topics + first sentence of summaries.

---

## Action level

| Value | Definition |
| --- | --- |
| `read_only` | Reads/analyses repo or docs only; no writes. |
| `suggests_changes` | Proposes patches/text but does not apply them. |
| `modifies_files` | Writes or edits files in the working tree. |
| `runs_commands` | Executes local shell/commands (build, tests, linters). |
| `external_write` | Creates/updates data in external systems (GitHub API, Jira, Matrix, email, deployment APIs, …). |

## Risk level

| Value | Definition |
| --- | --- |
| `low` | No durable impact or easily reversible edits. |
| `medium` | Local file changes and/or command execution with repo impact. |
| `high` | External writes, destructive operations, releases/deployments, security-sensitive changes. |

**PASS rule:** every skill repo **should** state `action_level` and `risk_level` in discovery YAML **or** in README table „Classification“ with the same labels.

---

## Sync with marketplace

When this metadata changes, open or update the corresponding marketplace entry per [`marketplace-integration.md`](marketplace-integration.md). **Do not** silently diverge.
