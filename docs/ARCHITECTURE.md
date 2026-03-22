# Architecture

## Overview

skill-repo-skill defines the standard structure for all Netresearch skill repositories. It provides reusable CI workflows, validation tooling, migration scripts, and templates consumed by 29+ skill repos.

## Components

### Skill Definition

`skills/skill-repo/SKILL.md` contains the AI skill instructions for creating and maintaining skill repositories.

### Reusable CI Workflows

Located in `.github/workflows/`, these are called by other skill repos via `uses: netresearch/skill-repo-skill/.github/workflows/<name>.yml@main`:

- **`validate.yml`** -- Main validation pipeline. Runs structure checks, frontmatter validation, licensing, metadata consistency, markdown/YAML lint, ShellCheck, Python lint, and checkpoint schema validation.
- **`auto-merge-deps.yml`** -- Auto-merges Dependabot/Renovate PRs after CI passes.
- **`release.yml`** -- Triggered on `v*` tags. Validates tag matches `plugin.json` version, packages each skill standalone and full plugin with checksums.

### Validation Scripts

- `skills/skill-repo/scripts/validate-skill.sh` -- Core validation: SKILL.md structure, frontmatter, licensing (split model), composer.json/plugin.json metadata consistency.
- `skills/skill-repo/scripts/migrate-licensing.sh` -- Migrates repos from single LICENSE to split licensing (LICENSE-MIT + LICENSE-CC-BY-SA-4.0).
- `Build/Scripts/check-plugin-version.sh` -- Validates plugin.json version format.

### Templates

`skills/skill-repo/templates/` provides starter files for bootstrapping new skill repos (README, licenses, workflows, composer.json).

### Git Hooks

`Build/hooks/` contains pre-commit and pre-push hooks for local development.

## Data Flow

```
Consuming skill repo
  -> calls validate.yml (reusable workflow)
    -> sparse-checks out validation tools from this repo
    -> runs validate-skill.sh against the calling repo
    -> runs markdown lint, YAML lint, ShellCheck, ruff
    -> reports results as CI annotations
```

## Licensing Model

All skill repos use split licensing:
- Code (scripts, workflows, configs) -> MIT
- Content (skill definitions, docs, references) -> CC-BY-SA-4.0
- SPDX expression: `(MIT AND CC-BY-SA-4.0)`
