# Architecture

## Overview

skill-repo-skill defines the standard structure for all Netresearch skill repositories. It provides reusable CI workflows, validation tooling, migration scripts, and templates consumed by 29+ skill repos.

## Components

### Skill Definition

`skills/skill-repo/SKILL.md` contains the AI skill instructions for creating and maintaining skill repositories.

### Reusable CI Workflows

Located in `.github/workflows/`, these are called by other skill repos via `uses: netresearch/skill-repo-skill/.github/workflows/<name>.yml@main`:

- **`validate.yml`** -- Main validation pipeline. Runs structure checks, frontmatter validation, licensing, metadata consistency, markdown/YAML lint, ShellCheck, Python lint, and checkpoint schema validation.
- **`release.yml`** -- Triggered on `v*` tags. Validates tag matches `plugin.json` version, packages each skill standalone and full plugin with checksums.
- **`pr-quality.yml`** -- PR quality gates (auto-approve coordination, etc.).
- **`harness-verify.yml`** -- Verifies AGENTS.md / harness consistency.
- **`eval-validate.yml`** -- Validates skill evaluation files.
- **`validate-agents.yml`** -- Validates `AGENTS.md` content.
- **`dependency-audit.yml`** -- Composer audit, SAST, dependency review.
- **`npm-pack-smoke.yml`** -- Verifies the npm tarball ships the right files.
- **`ci-python.yml`** -- Reusable Python lint/test pipeline.
- **`tests.yml`** -- Runs a skill repo's own suite under `tests/`: shell, Python, and PHP (PHP toolchain and `composer install` only when the PHP glob matches). Reports whether a repo shipping `skills/*/scripts/` ran any test at all; fatal only when the caller sets `require_tests`.

Auto-merge for Dependabot/Renovate PRs is delegated to `netresearch/.github/.github/workflows/auto-merge-deps.yml@main` via the local caller `auto-merge-deps-caller.yml`; it is **not** hosted in this repo.

### Validation Scripts

- `skills/skill-repo/scripts/validate-skill.sh` -- Core validation: SKILL.md structure, frontmatter, licensing (split model), composer.json/plugin.json metadata consistency.
- `skills/skill-repo/scripts/migrate-licensing.sh` -- Migrates repos from single LICENSE to split licensing (LICENSE-MIT + LICENSE-CC-BY-SA-4.0).
- `Build/Scripts/check-plugin-version.sh` -- Validates plugin.json version format.

### Release Tooling

- `skills/skill-repo/scripts/bump-version.sh` / `check-version-parity.sh` / `sync-plugin-manifest.sh` -- Single-repo version surfaces: bump, parity check, manifest projection.
- `skills/skill-repo/scripts/roll-changelog.py` -- Shape-aware CHANGELOG rollover (all five fleet heading shapes, fence-aware, fails on a no-op roll).
- `skills/skill-repo/scripts/fleet-release-github.sh` -- Fleet release driver for the public GitHub org; shared host-neutral engine in `fleet-release-common.sh` (private-host fleets vendor the engine and ship their own driver in their own infrastructure), default repo list in `fleet-repos-github.txt`. Flow and guarantees: `skills/skill-repo/references/release-discipline.md`.

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
