# AGENTS.md

## Repository Purpose

This repository (`netresearch/skill-repo-skill`) defines the standard structure for all Netresearch skill repositories. It provides:

- The **skill-repo skill** itself (how to create and maintain skill repos)
- **Reusable CI workflows** consumed by all 29+ Netresearch skill repos
- **Validation tooling** and **migration scripts**
- **Templates** for bootstrapping new skill repos

## Key Files

| Path | Purpose |
|---|---|
| `skills/skill-repo/SKILL.md` | AI skill instructions -- the skill definition |
| `.claude-plugin/plugin.json` | Plugin metadata (name, version, skills array) |
| `composer.json` | PHP/Composer distribution as `ai-agent-skill` type |
| `.github/workflows/validate.yml` | Reusable validation workflow (called by all skill repos) |
| `.github/workflows/auto-merge-deps.yml` | Reusable auto-merge workflow for Dependabot/Renovate PRs |
| `.github/workflows/release.yml` | Release packaging (zip/tar.gz per skill + full plugin) |
| `.github/workflows/lint.yml` | This repo's own CI (markdown lint, ShellCheck, skill validation) |
| `.github/workflows/auto-merge-deps-caller.yml` | This repo's own caller for auto-merge |
| `skills/skill-repo/scripts/validate-skill.sh` | Validates skill repo structure, licensing, metadata consistency |
| `skills/skill-repo/scripts/migrate-licensing.sh` | Migrates repos from single LICENSE to split licensing |
| `skills/skill-repo/templates/` | Templates for new skill repos (README, licenses, workflows, composer.json) |
| `Build/hooks/` | Git hooks (pre-commit, pre-push) |
| `Build/Scripts/check-plugin-version.sh` | Version validation script |

## Commands

| Task | Command | ~Time |
|------|---------|-------|
| Validate skill structure | `bash skills/skill-repo/scripts/validate-skill.sh` | ~5s |
| Lint (all) | Runs via reusable workflow `.github/workflows/validate.yml` | CI only |
| ShellCheck | `shellcheck scripts/*.sh Build/Scripts/*.sh` | ~3s |

## Conventions

### Licensing (Split Model)

All skill repos use split licensing:

| Content type | License |
|---|---|
| Skill definitions (`skills/**/*.md`), references, docs, README | CC-BY-SA-4.0 |
| Scripts, workflows, configs, code files | MIT |
| Code snippets embedded in `.md` files | Dual (both apply) |

Required files: `LICENSE-MIT` and `LICENSE-CC-BY-SA-4.0` (not a single `LICENSE`).

SPDX expression in `composer.json` and `plugin.json`: `(MIT AND CC-BY-SA-4.0)`

Copyright entity: `Netresearch DTT GmbH`

### SKILL.md Format

- Frontmatter with **only** `name` and `description` fields
- `name`: lowercase, hyphens only, max 64 characters
- `description`: must start with `"Use when"`
- Body: max 500 words (use `references/` for extended content)

### Versioning and Releases

1. Bump version in `.claude-plugin/plugin.json`
2. Commit: `chore: release vX.Y.Z`
3. Create signed tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`
4. Push: `git push origin main vX.Y.Z`

The `release.yml` workflow triggers on `v*` tags, validates that the tag matches the plugin.json version, then packages each skill standalone and the full plugin with checksums.

### Composer Package

- `name` must match the GitHub repo name exactly (`netresearch/{repo-name}`)
- `type` must be `ai-agent-skill`
- Must require `netresearch/composer-agent-skill-plugin`
- `extra.ai-agent-skill` must point to an existing SKILL.md path
- No `composer.lock` in skill repos

## CI Architecture

### Reusable Workflows (consumed by other repos)

**`validate.yml`** -- the main validation pipeline, hosted in this repo. Other skill repos call it with `uses: netresearch/skill-repo-skill/.github/workflows/validate.yml@main`:

- Checks out the calling repo and sparse-checks out validation tools from this repo
- Runs `validate-skill.sh` (structure, frontmatter, licensing, metadata consistency)
- Markdown lint (provides default config if repo has none)
- YAML lint (provides default config if repo has none)
- Validates `plugin.json` version format
- ShellCheck on all `*.sh` files
- Python lint via `ruff` on all `*.py` files
- Validates checkpoint YAML schemas

**auto-merge for dependency PRs** -- lives in the org-level `netresearch/.github` repo, not here. Skill repos call it with `uses: netresearch/.github/.github/workflows/auto-merge-deps.yml@main`:

- Triggers on PRs from `dependabot[bot]` or `renovate[bot]`
- Auto-approves, waits for all CI checks to pass, then merges

### This Repo's Own CI

- `lint.yml` runs markdown lint, ShellCheck, and skill validation on push to main and PRs
- `auto-merge-deps-caller.yml` is this repo's own caller for the org-level auto-merge workflow

### Caller Workflow Pattern

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

## Validation Script Details

`validate-skill.sh` checks:

- SKILL.md exists (root or `skills/*/SKILL.md`), has valid frontmatter, name format, description prefix, word count
- Required files: `README.md`, `LICENSE-MIT`, `LICENSE-CC-BY-SA-4.0`, `.gitignore`
- No stale `LICENSE` file alongside `LICENSE-MIT`
- `release.yml` workflow exists
- No `composer.lock` committed
- `composer.json`: type, license SPDX, name matches repo, skill plugin dependency, skill path exists
- `plugin.json`: name matches SKILL.md, skills is array, paths exist, author URL correct
- `README.md`: Netresearch reference, Installation section
