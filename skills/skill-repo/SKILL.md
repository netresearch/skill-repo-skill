---
name: skill-repo
description: "Use when creating new skill repositories from scratch, standardizing or validating existing skill repo structure, setting up composer/release workflows for skills, configuring split licensing (MIT + CC-BY-SA-4.0), or fixing plugin.json / SKILL.md validation errors."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash 4.3+, python3, jq."
metadata:
  author: Netresearch DTT GmbH
  version: "1.9.0"
  repository: https://github.com/netresearch/skill-repo-skill
allowed-tools: Bash(bash:*) Bash(python3:*) Bash(jq:*) Read Write Glob Grep
---

# Skill Repository Structure Guide

Standards for Netresearch skill repository layout and distribution.

## When to Use

- Creating a new skill repository
- Standardizing an existing skill repo
- Setting up release workflows

## Repository Structure

```
{skill-name}/
├── .claude-plugin/plugin.json  # Plugin metadata (required)
├── SKILL.md              # AI instructions (required)
├── README.md             # Human documentation (required)
├── LICENSE-MIT           # Code license (required)
├── LICENSE-CC-BY-SA-4.0  # Content license (required)
├── composer.json         # PHP distribution
├── references/           # Extended docs
├── scripts/              # Automation
└── .github/workflows/release.yml
```

## Licensing

Skill repos use split licensing:

| Path pattern | License |
|---|---|
| `skills/**/*.md`, `references/**`, `assets/**/*.md`, `README.md`, `docs/**` | CC-BY-SA-4.0 |
| `scripts/**`, `Build/**`, `.github/workflows/**`, `*.sh`, `*.py`, `*.php` | MIT |
| `composer.json`, `plugin.json`, config files | MIT |
| Code snippets embedded in `.md` files | Dual (both apply) |

Composer/plugin metadata uses SPDX compound expression: `(MIT AND CC-BY-SA-4.0)`

## SKILL.md Requirements

```yaml
---
name: skill-name          # lowercase, hyphens, max 64 chars
description: "Use when <trigger conditions>"
---
```

- Under 500 words, use references/ for extended content

## Installation Methods

1. **Marketplace**: `/plugin marketplace add netresearch/claude-code-marketplace`
2. **Release**: Download and extract to `~/.claude/skills/{name}/`
3. **Composer**: `composer require netresearch/{repo-name}`

## Composer Package

Composer name **must match GitHub repo name** exactly.

```json
{
  "name": "netresearch/{repo-name}",
  "type": "ai-agent-skill",
  "require": {"netresearch/composer-agent-skill-plugin": "*"},
  "extra": {"ai-agent-skill": "SKILL.md"}
}
```

## Validation

```bash
scripts/validate-skill.sh
```

## References

- `references/installation-methods.md`
- `references/composer-setup.md`
- `templates/README.md.template`

## Releasing

1. Bump version in `.claude-plugin/plugin.json`
2. Commit: `chore: release vX.Y.Z`
3. Tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`
4. Push: `git push origin main vX.Y.Z`

---

> **Contributing:** https://github.com/netresearch/skill-repo-skill
