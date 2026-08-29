---
name: skill-repo
description: "Use when creating skill repositories, standardizing or validating skill repo structure, setting up composer/release workflows, configuring split licensing (MIT + CC-BY-SA-4.0), fixing plugin.json / SKILL.md validation or version-parity errors, or releasing a skill version (version bump, tagging)."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash 4.3+, python3."
metadata:
  author: Netresearch DTT GmbH
  version: "1.37.0"
  repository: https://github.com/netresearch/skill-repo-skill
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*) Bash(skills/skill-repo/scripts/*) Bash(bash skills/skill-repo/scripts/*) Read Write Glob Grep
---

# Skill Repository Structure Guide

## Repository Structure

```
{repo-name}/
├── plugin.json                  # portable manifest
├── .claude-plugin/plugin.json   # generated
├── skills/{name}/SKILL.md       # the control plane
├── README.md                    # human docs
├── LICENSE-MIT                  # code
├── LICENSE-CC-BY-SA-4.0         # content
├── composer.json                # PHP distribution
├── references/                  # detail, loaded on demand
├── scripts/                     # executables, never loaded
└── .github/workflows/
    ├── release.yml              # tag-triggered
    ├── validate.yml             # validation caller
    └── auto-merge-deps.yml      # dep auto-merge caller
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
name: skill-name
description: "Use when <trigger conditions>"
---
```

**Budgets** (spec): `name` ≤64, no doubled/edge hyphen, matches its directory. `description` ≤1024, warn past 500 — a router, not documentation. Body ≤500 lines, warn at 300. `compatibility` ≤500, usually omit.

**Flat discovery**: references one level deep; SKILL.md names every `references/*.md` and every `scripts/` executable; `## Contents` past 100 lines. Rationale and trigger evals: [skill-architecture](references/skill-architecture.md). Audit: `audit-skills.sh` in the repository's top-level `scripts/` (not shipped with the skill).

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

Marketplace, release download, Composer, npm — commands and the npm `files` default in [installation-methods](references/installation-methods.md).

## Validation

`scripts/validate-skill.sh` (layout, manifests, budgets, flat discovery). Shell portability: [authoring-ci-gotchas](references/authoring-ci-gotchas.md).

Named here so they are findable: `bump-version.sh`, `check-version-parity.sh`, `sync-plugin-manifest.sh`, `roll-changelog.py`, `fleet-release-github.sh`, `migrate-licensing.sh`, `validate-evals.sh` — each with `--help`.

## References (`references/`)

[agent-plugins-compat](references/agent-plugins-compat.md) · [installation-methods](references/installation-methods.md) · [composer-setup](references/composer-setup.md) · [release-discipline](references/release-discipline.md) · [review-replies](references/review-replies.md) · [skill-quality](references/skill-quality.md) · [repository-quality-rules](references/repository-quality-rules.md) · [readme-template](references/readme-template.md) · [skill-discovery-metadata](references/skill-discovery-metadata.md) · [validation-checklist](references/validation-checklist.md) · [marketplace-integration](references/marketplace-integration.md) · [materialization-contract](references/materialization-contract.md) · [authoring-ci-gotchas](references/authoring-ci-gotchas.md) · [skill-retirement](references/skill-retirement.md)


---

> **Contributing:** <https://github.com/netresearch/skill-repo-skill>
