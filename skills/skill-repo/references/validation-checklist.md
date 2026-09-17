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
- [ ] It carries **only** the fields of the closed schema — no `skills`, `agents`, … — see [`agent-plugins-compat.md`](agent-plugins-compat.md).
- [ ] Neither manifest carries `support`: it is not a Claude Code field either. `claude plugin validate --strict .` exits **0**.
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

## Which validator catches what

Three checkers run over a skill repository and none of them is a superset of the others. A green run of one is not a release gate for the others.

| Checker | Catches | Does **not** catch |
|---|---|---|
| `validate-skill.sh` | repo structure, required files, root `LICENSE-MIT` + `LICENSE-CC-BY-SA-4.0`, version parity | anything the Claude Code manifest schema defines |
| `claude plugin validate [--strict]` | unknown top-level manifest fields (`--strict` turns the warning into exit 1), malformed manifest | dangling symlinks, markup inside a `SKILL.md` description |
| claude.ai marketplace import | unknown manifest fields, **symlinks whose target is not in the repository**, **XML tags in a `SKILL.md` description** | — |

The gap is not theoretical: on 2026-09-17 three `skills/*/LICENSE` symlinks in `netresearch/matrix-skill` had pointed at a file deleted six months earlier, and a description in `netresearch/orocommerce-skill` carried a literal `<Secret:>` placeholder. Both passed `validate-skill.sh` and `claude plugin validate --strict`; only the marketplace import named them. Run the import, or check symlinks and descriptions by hand, before assuming a repository is clean:

The description check is scoped to the **frontmatter** block: an unscoped `/^description:/` also matches the SKILL.md template inside a body code fence, and this repository's own `skills/skill-repo/SKILL.md` carries `description: "Use when <trigger conditions>"` there — a false positive that reads exactly like a real defect.

```bash
git ls-files -s | awk '$1=="120000" {print $4}' | while read -r l; do [ -e "$l" ] || echo "DANGLING: $l"; done
awk 'FNR==1{fm=0} /^---$/{fm++; next} fm==1 && /^description:/ && /<[A-Za-z\/]/ {print FILENAME ": " $0}' skills/*/SKILL.md
```
