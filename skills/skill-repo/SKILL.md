---
name: skill-repo
description: "Use when creating skill repositories, standardizing or validating skill repo structure, setting up composer/release workflows, configuring split licensing (MIT + CC-BY-SA-4.0), fixing plugin.json / SKILL.md validation or version-parity errors, or releasing a skill version (version bump, tagging)."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash 4.3+, python3."
metadata:
  author: Netresearch DTT GmbH
  version: "1.28.0"
  repository: https://github.com/netresearch/skill-repo-skill
allowed-tools: Bash(bash:*) Bash(python3:*) Read Write Glob Grep
---

# Skill Repository Structure Guide

Standards for Netresearch skill repository layout and distribution.

## Repository Structure

```
{repo-name}/
├── plugin.json                  # portable manifest (required)
├── .claude-plugin/plugin.json   # generated
├── skills/{name}/SKILL.md       # AI instructions (required)
├── README.md                    # Human docs (required)
├── LICENSE-MIT                  # Code license (required)
├── LICENSE-CC-BY-SA-4.0         # Content license (required)
├── composer.json                # PHP distribution (required)
├── references/                  # Extended docs for >500w content
├── scripts/                     # Automation
└── .github/workflows/
    ├── release.yml              # Tag-triggered release
    ├── validate.yml             # Caller for reusable validation
    └── auto-merge-deps.yml      # Caller for dep auto-merge
```

## Licensing (Split Model)

| Path pattern | License |
|---|---|
| `skills/**/*.md`, `references/**`, `README.md`, `docs/**` | CC-BY-SA-4.0 |
| `scripts/**`, `.github/workflows/**`, `*.sh`, `*.py`, `*.php` | MIT |
| `composer.json`, `plugin.json`, config files | MIT |

SPDX: `(MIT AND CC-BY-SA-4.0)`. Copyright: `Netresearch DTT GmbH`. No bare `LICENSE` — split files only.

## SKILL.md Frontmatter

```yaml
---
name: skill-name          # lowercase, hyphens, max 64 chars
description: "Use when <trigger conditions>"
---
```

Body ≤500 words; description ≤1,536 chars (target 100–300, trigger first). Every `references/*.md` must be reachable from SKILL.md (no orphans). Audit: `scripts/audit-skills.sh`. Put discovery/catalog fields in README or optional YAML, not frontmatter.

## Manifests

Root `plugin.json` ([Agent Plugins 1.0.0](https://agent-plugins.org), closed field set) is the source of truth; `sync-plugin-manifest.sh` generates `.claude-plugin/plugin.json` plus Claude-only keys — [agent-plugins-compat](references/agent-plugins-compat.md).

```json
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
  "name": "skill-name",
  "version": "1.0.0",
  "license": "(MIT AND CC-BY-SA-4.0)",
  "author": {"name": "Netresearch DTT GmbH", "url": "https://www.netresearch.de"}
}
```

## composer.json

Name **must match GitHub repo**. Type `ai-agent-skill`. No `version` field (from git tags). No `composer.lock`.

```json
{
  "name": "netresearch/{repo-name}",
  "type": "ai-agent-skill",
  "license": "(MIT AND CC-BY-SA-4.0)",
  "require": {"netresearch/composer-agent-skill-plugin": "*"},
  "extra": {"ai-agent-skill": "skills/{name}/SKILL.md"}
}
```

## Reusable Workflow Callers

Skill repos MUST delegate CI to skill-repo-skill reusable workflows:

```yaml
# .github/workflows/validate.yml
uses: netresearch/skill-repo-skill/.github/workflows/validate.yml@main
```

Callers: `validate.yml`, `release.yml` (here); `auto-merge-deps.yml` (`netresearch/.github`). Auto-merge/pr-quality use `pull_request_target`. No inline Actions. Domain reusables: `docs/ARCHITECTURE.md`.

## Releasing

Bump root `plugin.json` → sync → PR → merge → pull main → verify parity → signed tag → push → monitor Release. **Tag only after bump PR merges.** Multi-repo (>3) needs dry-run + approval. Never edit installed paths — [release-discipline](references/release-discipline.md).

## Installation

1. **Marketplace**: `/plugin marketplace add netresearch/claude-code-marketplace`
2. **Release**: Download to `~/.claude/skills/{name}/`
3. **Composer**: `composer require netresearch/{repo-name}`
4. **npm**: `npm i -D @netresearch/agent-skill-coordinator github:netresearch/{repo-name}`. Use `templates/package.json.template` (minimal `files` default).

## Validation

`scripts/validate-skill.sh` (layout, manifests). Shell portability: [authoring-ci-gotchas](references/authoring-ci-gotchas.md).

## References (`references/`)

[agent-plugins-compat](references/agent-plugins-compat.md) · [installation-methods](references/installation-methods.md) · [composer-setup](references/composer-setup.md) · [release-discipline](references/release-discipline.md) · [review-replies](references/review-replies.md) · [skill-quality](references/skill-quality.md) · [repository-quality-rules](references/repository-quality-rules.md) · [readme-template](references/readme-template.md) · [skill-discovery-metadata](references/skill-discovery-metadata.md) · [validation-checklist](references/validation-checklist.md) · [marketplace-integration](references/marketplace-integration.md) · [materialization-contract](references/materialization-contract.md) · [authoring-ci-gotchas](references/authoring-ci-gotchas.md) · [skill-retirement](references/skill-retirement.md)

## See Also

[`agent-rules-skill`](https://github.com/netresearch/agent-rules-skill), [`agent-harness-skill`](https://github.com/netresearch/agent-harness-skill), [`retro-skill`](https://github.com/netresearch/retro-skill).

---

> **Contributing:** <https://github.com/netresearch/skill-repo-skill>
