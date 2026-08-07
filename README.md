# Skill Repository Structure Guide

A Claude Code skill for standardizing Netresearch skill repository layout, distribution channels, packaging, and validation.

## What this skill solves

Netresearch maintains many agent skills; without a shared layout, packaging and CI drift across repositories. This skill defines **one standard repo shape**, reusable workflows, split licensing, and validation scripts so new and existing skills stay consistent and shippable via marketplace, Composer, npm, and releases.

It extends Anthropic-style single-file skills with **repository-level** conventions (not a replacement for Anthropic’s skill-creator — see comparison below).

## Why this is a skill (model delta)

- **Value categories:** org/project-specific knowledge (Netresearch repo shape, split licensing, composer type `ai-agent-skill`) and executable scripts/validators (`validate-skill.sh`, `checkpoints.yaml`).
- **Without the skill:** the model invents a plausible generic repo layout — single `LICENSE`, no `plugin.json`, `composer.json` without the `ai-agent-skill` type — that fails `validate-skill.sh` and org CI.
- **Eval evidence:** `validate_skill_repo_structure` and `readme_requirements` in [`skills/skill-repo/evals/evals.json`](skills/skill-repo/evals/evals.json).

## Compatibility

This is an **Agent Skill** following the [open standard](https://agentskills.io) originally developed by Anthropic and released for cross-platform use. The repository is also packaged as an [Agent Plugins 1.0.0](https://agent-plugins.org) plugin: the root `plugin.json` plus `skills/` layout is what any conformant client loads.

**Supported platforms:**

- Claude Code (Anthropic)
- Cursor
- GitHub Copilot
- Other skills-compatible AI agents

> Skills are portable packages of procedural knowledge that work across any AI agent supporting the Agent Skills specification.

## Use when

- Creating or bootstrapping a **Netresearch-style skill repository**
- Standardizing layout, `composer.json`, `plugin.json` / `.claude-plugin/plugin.json`, or release workflows
- Wiring **reusable CI** from `netresearch/skill-repo-skill`
- Fixing **validation errors** from `validate-skill.sh` or marketplace packaging
- Migrating to **split licensing** (`LICENSE-MIT` + `LICENSE-CC-BY-SA-4.0`)

## Expected outputs

- A documented **directory layout** and templates for new repos
- **Validation**: structural checks for `SKILL.md`, licenses, `composer.json`, `plugin.json`
- **Release discipline**: tag-driven packaging aligned with plugin version
- **References** for installation paths, marketplace sync, and release safety

## Context requirements

- **Validation script**: `bash` 4.3+ and `python3` on PATH when running `validate-skill.sh` (JSON checks use Python, not `jq`)
- **Target repos**: GitHub-hosted Netresearch skill repos using split licensing and Composer type `ai-agent-skill`
- **CI**: consuming repos call reusable workflows from this repository (`validate.yml`, `release.yml`, …)

## Example prompts

```
"Scaffold a new Netresearch skill repository from the templates in skill-repo-skill."
"Why does validate-skill.sh fail on my SKILL.md frontmatter?"
"Add composer.json and plugin.json for our new skill repo matching netresearch conventions."
"Wire our repo to use netresearch/skill-repo-skill validate.yml on every PR."
"Migrate this repo from a single LICENSE file to LICENSE-MIT and LICENSE-CC-BY-SA-4.0."
```

## Related skills

- [`agent-rules-skill`](https://github.com/netresearch/agent-rules-skill) — AGENTS.md and agent onboarding patterns
- [`agent-harness-skill`](https://github.com/netresearch/agent-harness-skill) — harness verification and docs layout

## Installation

### Marketplace (recommended)

Add the [Netresearch marketplace](https://github.com/netresearch/claude-code-marketplace) once, then browse and install skills:

```bash
/plugin marketplace add netresearch/claude-code-marketplace
```

### npx ([skills.sh](https://skills.sh))

Install with any [Agent Skills](https://agentskills.io)-compatible agent:

```bash
npx skills add https://github.com/netresearch/skill-repo-skill --skill skill-repo
```

### Download release

Download the [latest release](https://github.com/netresearch/skill-repo-skill/releases/latest) and extract to your agent’s skills directory.

### Git clone

```bash
git clone https://github.com/netresearch/skill-repo-skill.git
```

### Composer (PHP projects)

```bash
composer require netresearch/skill-repo-skill
```

Requires [netresearch/composer-agent-skill-plugin](https://github.com/netresearch/composer-agent-skill-plugin).

### npm (Node projects)

```bash
npm install --save-dev \
  @netresearch/agent-skill-coordinator \
  github:netresearch/skill-repo-skill
```

Requires [@netresearch/agent-skill-coordinator](https://github.com/netresearch/node-agent-skill-coordinator), which discovers the skill in `node_modules` and registers it in `AGENTS.md` via a `postinstall` hook. For pnpm, allowlist the coordinator’s postinstall:

```json
{
  "pnpm": {
    "onlyBuiltDependencies": ["@netresearch/agent-skill-coordinator"]
  }
}
```

## Repository layout

### Standard skill repository (concept)

The layout for a Netresearch skill repository (one or more skills per repo):

```
{name}-skill/
├── AGENTS.md                        # Agent rules / harness index
├── README.md                        # Human documentation
├── LICENSE-MIT                      # Code license (MIT)
├── LICENSE-CC-BY-SA-4.0             # Content license (CC-BY-SA-4.0)
├── composer.json                    # PHP distribution
├── package.json                     # Node distribution (optional)
├── renovate.json                    # Dependency automation
├── .claude-plugin/
│   └── plugin.json                  # Marketplace metadata
├── .github/workflows/               # CI (typically calls reusable workflows)
├── Build/                           # Build scripts and git hooks
├── docs/                            # Architecture, ADRs, dashboards
├── scripts/                         # Repo-level automation
└── skills/
    └── {skill-name}/
        ├── SKILL.md                 # AI instructions
        ├── checkpoints.yaml         # Assessment checkpoints (optional)
        ├── evals/                   # Skill evaluations
        ├── references/              # Extended docs
        ├── scripts/                 # Skill automation
        └── templates/               # Bootstrap templates
```

### Installation methods (summary)

1. **Marketplace** — `/plugin marketplace add netresearch/claude-code-marketplace`
2. **npx (skills.sh)** — `npx skills add <repo-url> --skill <name>`
3. **Release download** — GitHub Releases (skill files only)
4. **Git clone** — direct clone
5. **Composer** — `composer require netresearch/<repo-name>` (PHP projects)
6. **npm** — coordinator + `github:<org>/<repo>` (Node projects)

### Composer package requirements

- `"type": "ai-agent-skill"`
- `"require": {"netresearch/composer-agent-skill-plugin": "*"}`
- `"extra": {"ai-agent-skill": "skills/{skill-name}/SKILL.md"}`

### This repository (`skill-repo-skill`)

This repo **dogfoods** the layout and hosts reusable CI workflows for other Netresearch skill repos:

```
skill-repo-skill/
├── AGENTS.md
├── README.md
├── LICENSE-MIT
├── LICENSE-CC-BY-SA-4.0
├── SECURITY-AUDIT.md
├── composer.json
├── package.json
├── renovate.json
├── plugin.json                    # Agent Plugins 1.0.0 manifest (source of truth)
├── .claude-plugin/plugin.json     # Claude Code manifest (generated)
├── .github/workflows/             # validate, release, pr-quality,
│                                  # harness-verify, eval-validate,
│                                  # validate-agents, dependency-audit,
│                                  # npm-pack-smoke, ci-python
│                                  # (auto-merge delegates to netresearch/.github)
├── Build/
│   ├── Scripts/check-plugin-version.sh
│   └── hooks/
├── docs/
│   ├── ARCHITECTURE.md
│   └── dashboard/
├── scripts/
├── tests/
└── skills/skill-repo/
    ├── SKILL.md
    ├── checkpoints.yaml
    ├── evals/evals.json
    ├── references/
    ├── scripts/
    └── templates/
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for component responsibilities.

## Extends Anthropic's Skill Creator

This skill **extends** (not replaces) Anthropic’s skill-creator:

| Aspect | Anthropic's skill-creator | This skill adds |
| --- | --- | --- |
| Focus | SKILL.md content | Repository structure |
| Scope | Single file | Full repo layout |
| Distribution | Claude Code native | + Marketplace, Composer |
| Audience | AI instructions | + Human README |

## Contributing

Contributions welcome. Please open PRs for:

- Template improvements
- Additional validation checks
- Documentation updates

## License

This project uses split licensing:

- **Code** (scripts, workflows, configs): [MIT](LICENSE-MIT)
- **Content** (skill definitions, documentation, references): [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0)

See the individual license files for full terms.

## Credits

Developed and maintained by [Netresearch DTT GmbH](https://www.netresearch.de/).

---

**Made with ❤️ for Open Source by [Netresearch](https://www.netresearch.de/)**
