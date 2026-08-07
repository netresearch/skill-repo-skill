# Validation checklist — skill repository changes

Agents **must** walk through this list before declaring a skill-repo task complete.
Marketplace-only checks live in **`netresearch/claude-code-marketplace`/`AGENTS.md`** — do not merge those steps here.

## README

- [ ] `README.md` contains **all** required sections listed in [`readme-template.md`](readme-template.md).
- [ ] **Example prompts:** ≥ **3** realistic prompts in `## Example prompts`.
- [ ] **Related skills:** declared **or** `none (justified: …)`.
- [ ] First screen answers: problem, when, outputs, context, installation — verifiable without scrolling past ~1 screen (approx. first 40 lines).

## SKILL.md

- [ ] Frontmatter includes **`name`** and **`description`**; **no** discovery-only keys (`slug`, `tags`, `category`, `keywords`, …).
- [ ] Optional keys only if needed: `license`, `compatibility`, `metadata`, `allowed-tools` (per validator).
- [ ] `description` starts with `Use when`.
- [ ] Body describes triggers and use cases without duplicating full README marketing copy.

## Manifests

- [ ] Root **`plugin.json`** exists and targets `https://agent-plugins.org/schemas/1.0.0/plugin.schema.json`.
- [ ] It carries **only** the fields of the closed schema — no `skills`, `agents`, `support`, … — see [`agent-plugins-compat.md`](agent-plugins-compat.md).
- [ ] `.claude-plugin/plugin.json` regenerated: `bash skills/skill-repo/scripts/sync-plugin-manifest.sh` leaves the tree clean (`--check` exits 0).
- [ ] Version bumped in the **root** `plugin.json` (source of truth), then synced; `check-version-parity.sh` exits 0.
- [ ] Every skill lives at `skills/<name>/SKILL.md` — a root `SKILL.md` is invisible to Agent Plugins clients.

## Agents / OpenAI

- [ ] `agents/openai.yaml` exists **or** README documents exception.
- [ ] File contains a **short, user-understandable** description of the skill (what/when).

## Discovery metadata

- [ ] Optional `metadata/discovery.yaml` (or documented equivalent) matches README if used — see [`skill-discovery-metadata.md`](skill-discovery-metadata.md).
- [ ] **`action_level`** and **`risk_level`** present in discovery YAML **or** README classification table.

## GitHub repository SEO

- [ ] Repository **Description** ≤ **160** characters, names concrete tech or use case — not generic “AI assistant”.
- [ ] **Topics** include `agent-skill` plus relevant tech/domain tags; no irrelevant stuffing.

## GitHub Pages

- [ ] `gh api repos/netresearch/<repo>/pages` returns **HTTP 404** (Pages disabled — the default).
- [ ] **If Pages is enabled:** the PR description names which `repository-quality-rules.md` Pages criterion is satisfied, and the README contains the mandatory artefacts (justification, canonical URL, source path, build/deploy commands, link-checking, content-split note).

## Related skills

- [ ] Related skills list is **honest** (exists, planned, or external) — see [`repository-quality-rules.md`](repository-quality-rules.md).

## Marketplace sync expectations

- [ ] README contains note or checkbox: when discovery fields change, marketplace entry must be updated **or** override documented (see [`marketplace-integration.md`](marketplace-integration.md)).

## Links and automation

- [ ] All links in touched docs resolve (internal paths and GitHub URLs).
- [ ] `bash skills/skill-repo/scripts/validate-skill.sh` exits **0** from repo root.
- [ ] If repo has CI calling `netresearch/skill-repo-skill/.github/workflows/validate.yml`, PR checks are green.

## Optional extended validation

- [ ] `scripts/audit-skills.sh` (if present in repo) reports no new orphan `references/` files.
