---
name: skill-repo
description: "Use when creating skill repositories, standardizing or validating skill repo structure, setting up composer/release workflows, configuring split licensing (MIT + CC-BY-SA-4.0), fixing plugin.json / SKILL.md validation or version-parity errors, or releasing a skill version (version bump, tagging)."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash 4.3+, python3."
metadata:
  author: Netresearch DTT GmbH
  version: "1.26.0"
  repository: https://github.com/netresearch/skill-repo-skill
allowed-tools: Bash(bash:*) Bash(python3:*) Read Write Glob Grep
---

# Skill Repository Structure Guide

Standards for Netresearch skill repository layout and distribution.

## Repository Structure

```
{repo-name}/
├── .claude-plugin/plugin.json   # Plugin metadata (required)
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

Body ≤500 words; description ≤1,536 chars (target 100–300, trigger first). Every `references/*.md` must be reachable from SKILL.md (no orphans). Audit: `scripts/audit-skills.sh`. See [`references/skill-quality.md`](references/skill-quality.md). Put discovery/catalog fields in README or optional YAML, not frontmatter — [`references/skill-discovery-metadata.md`](references/skill-discovery-metadata.md).

## plugin.json (`.claude-plugin/plugin.json`)

```json
{
  "name": "skill-name",
  "version": "1.0.0",
  "skills": ["./skills/skill-name"],
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

Bump PR → merge → pull main → verify parity → signed tag → push → monitor Release. **Tag only after bump PR merges.** Never edit installed paths (`~/.claude/skills/**`, `~/.claude/plugins/**`); always the worktree. Multi-repo (>3) needs dry-run + approval. See `references/release-discipline.md`.

## Installation

1. **Marketplace**: `/plugin marketplace add netresearch/claude-code-marketplace`
2. **Release**: Download to `~/.claude/skills/{name}/`
3. **Composer**: `composer require netresearch/{repo-name}`
4. **npm**: `npm i -D @netresearch/agent-skill-coordinator github:netresearch/{repo-name}`. Use `templates/package.json.template` (minimal `files` default; see `references/installation-methods.md`).

## Validation

```bash
scripts/validate-skill.sh
```

## Cross-platform Compatibility

`grep -E` (not `-P`); `bash` shebangs (zsh on macOS); `[[ ]]` for conditionals.

## References (`references/`)

**Distribution:** [installation-methods](references/installation-methods.md), [composer-setup](references/composer-setup.md), [release-discipline](references/release-discipline.md), [review-replies](references/review-replies.md) · **SKILL text:** [skill-quality](references/skill-quality.md) · **Repo/README:** [repository-quality-rules](references/repository-quality-rules.md), [readme-template](references/readme-template.md) · **Discovery:** [skill-discovery-metadata](references/skill-discovery-metadata.md) · **Done:** [validation-checklist](references/validation-checklist.md) · **Sync:** [marketplace-integration](references/marketplace-integration.md) · **Retro:** [materialization-contract](references/materialization-contract.md) · **Gotchas:** [authoring-ci-gotchas](references/authoring-ci-gotchas.md) · **Retirement:** [skill-retirement](references/skill-retirement.md)

## See Also

[`agent-rules-skill`](https://github.com/netresearch/agent-rules-skill), [`agent-harness-skill`](https://github.com/netresearch/agent-harness-skill), [`retro-skill`](https://github.com/netresearch/retro-skill).

---

> **Contributing:** <https://github.com/netresearch/skill-repo-skill>
