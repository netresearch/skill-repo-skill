<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

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
- **`eval-validate.yml`** -- Validates skill evaluation files. On a pull request it also resolves the base branch's copy of the `evals.json` and requires `samples` on every eval that is new or whose assertions changed (retro-skill#92); untouched evals and push builds are unaffected.
- **`validate-agents.yml`** -- Validates `AGENTS.md` content.
- **`dependency-audit.yml`** -- Composer audit, SAST, dependency review.
- **`npm-pack-smoke.yml`** -- Verifies the npm tarball ships the right files.
- **`ci-python.yml`** -- Reusable Python lint/test pipeline.
- **`tests.yml`** -- Runs a skill repo's own suite under `tests/` and `skills/*/scripts/tests/`: shell, Python, and PHP (PHP toolchain and `composer install` only when the PHP glob matches). Reports whether a repo shipping scripts (`skills/*/scripts/`, a root `scripts/`, `skills/*/checker/`) ran any test at all; fatal only when the caller sets `require_tests`.

Auto-merge for Dependabot/Renovate PRs is delegated to `netresearch/.github/.github/workflows/auto-merge-deps.yml@main` via the local caller `auto-merge-deps-caller.yml`; it is **not** hosted in this repo.

#### Caller workflow pattern

Each consuming skill repo needs a thin caller workflow. Example for validation:

```yaml
# .github/workflows/validate.yml
name: Validate
on:
  push:
    branches: [main]
  pull_request:
jobs:
  validate:
    uses: netresearch/skill-repo-skill/.github/workflows/validate.yml@main
```

Example for auto-merge:

```yaml
# .github/workflows/auto-merge-deps.yml
name: Auto-merge dependency PRs
on:
  pull_request_target:
permissions: {}
jobs:
  auto-merge:
    uses: netresearch/.github/.github/workflows/auto-merge-deps.yml@main
    permissions:
      contents: write
      pull-requests: write
```

### Validation Scripts

- `skills/skill-repo/scripts/validate-skill.sh` -- Core validation: SKILL.md structure, frontmatter, licensing (split model), composer.json/plugin.json metadata consistency.
- `skills/skill-repo/scripts/migrate-licensing.sh` -- Migrates repos from single LICENSE to split licensing (LICENSE-MIT + LICENSE-CC-BY-SA-4.0).
- `Build/Scripts/check-plugin-version.sh` -- Validates plugin.json version format.

#### What `validate-skill.sh` checks

`validate-skill.sh` checks:

- SKILL.md exists (root or `skills/*/SKILL.md`), has valid frontmatter, name format, description prefix, body line count (error above 500 lines, warning above 300)
- Required files: `README.md`, `LICENSE-MIT`, `LICENSE-CC-BY-SA-4.0`, `.gitignore`
- No stale `LICENSE` file alongside `LICENSE-MIT`
- A release path: `.github/workflows/release.yml` on GitHub; on GitLab, a `.gitlab-ci.yml` that includes the `claude-code-skill` CI component (which creates the Release from the tag pipeline — no `release.yml` there)
- No `composer.lock` committed
- `composer.json`: type, license SPDX, name matches repo, skill plugin dependency, skill path exists
- `plugin.json`: name matches SKILL.md, skills is array, paths exist, author URL correct
- `README.md`: Netresearch reference; **warnings** (errors with `STRICT_README=1`, or `true`/`yes`) if required level-2 sections from `skills/skill-repo/references/readme-template.md` are missing (`What this skill solves`, `Why this is a skill (model delta)`, `Use when`, `Expected outputs`, `Context requirements`, `Example prompts`, `Related skills`, `Installation`, `Contributing`, `License`); a **warning** for a static `img.shields.io/badge/version-` badge, which no release step updates (the live form is `img.shields.io/github/v/release/netresearch/<repo>?sort=semver`)
- `checkpoints.yaml` presence in the skill directory — **warning** only, never fails; suppress by adding a line `Checkpoints: none (justified — <reason>)` to `SKILL.md` or `README.md` for skills that are not suitable per the add-checkpoints skill's suitability criteria (e.g. purely conceptual skills)

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
