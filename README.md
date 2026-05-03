# Skill Repository Structure Guide

A Claude Code skill for standardizing Netresearch skill repository layout, distribution channels, and packaging.

## 🔌 Compatibility

This is an **Agent Skill** following the [open standard](https://agentskills.io) originally developed by Anthropic and released for cross-platform use.

**Supported Platforms:**
- ✅ Claude Code (Anthropic)
- ✅ Cursor
- ✅ GitHub Copilot
- ✅ Other skills-compatible AI agents

> Skills are portable packages of procedural knowledge that work across any AI agent supporting the Agent Skills specification.


## Features

- **Repository Structure Standards** - Consistent layout across all Netresearch skills
- **Multi-Channel Distribution** - Marketplace, GitHub releases, Composer
- **README.md Template** - Standardized human documentation
- **Composer Integration** - PHP ecosystem distribution via composer-agent-skill-plugin
- **Release Workflow** - Automated packaging excluding dev files
- **Validation Script** - Verify skill repo compliance

## Installation

### Marketplace (Recommended)

Add the [Netresearch marketplace](https://github.com/netresearch/claude-code-marketplace) once, then browse and install skills:

```bash
# Claude Code
/plugin marketplace add netresearch/claude-code-marketplace
```

### npx ([skills.sh](https://skills.sh))

Install with any [Agent Skills](https://agentskills.io)-compatible agent:

```bash
npx skills add https://github.com/netresearch/skill-repo-skill --skill skill-repo
```

### Download Release

Download the [latest release](https://github.com/netresearch/skill-repo-skill/releases/latest) and extract to your agent's skills directory.

### Git Clone

```bash
git clone https://github.com/netresearch/skill-repo-skill.git
```

### Composer (PHP Projects)

```bash
composer require netresearch/skill-repo-skill
```

Requires [netresearch/composer-agent-skill-plugin](https://github.com/netresearch/composer-agent-skill-plugin).

### npm (Node Projects)

```bash
npm install --save-dev \
  @netresearch/agent-skill-coordinator \
  github:netresearch/skill-repo-skill
```

Requires [@netresearch/agent-skill-coordinator](https://github.com/netresearch/node-agent-skill-coordinator), which discovers the skill in `node_modules` and registers it in `AGENTS.md` via a `postinstall` hook. For pnpm, also allowlist the coordinator's postinstall:

```json
{
  "pnpm": {
    "onlyBuiltDependencies": ["@netresearch/agent-skill-coordinator"]
  }
}
```

## Usage

The skill triggers on keywords like:
- "create skill"
- "skill repository"
- "skill structure"
- "standardize skill"
- "composer.json for skill"
- "release workflow"

### Example Prompts

```
"Help me create a new skill repository"
"Standardize this skill repo structure"
"Add composer.json to this skill"
"Set up release workflow for this skill"
"Validate this skill repository"
```

## What This Skill Provides

### Repository Layout

The standard layout for a Netresearch skill repository (one or more skills per repo):

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

### Installation Methods

1. **Marketplace** - `/plugin marketplace add netresearch/claude-code-marketplace`
2. **npx (skills.sh)** - `npx skills add <repo-url> --skill <name>`
3. **Release Download** - GitHub Releases (skill files only)
4. **Git Clone** - Direct repository clone
5. **Composer** - `composer require netresearch/agent-{skill-name}` (PHP projects)
6. **npm** - `npm install --save-dev @netresearch/agent-skill-coordinator github:<org>/<repo>` (Node projects)

### Composer Package Requirements

- `"type": "ai-agent-skill"`
- `"require": {"netresearch/composer-agent-skill-plugin": "*"}`
- `"extra": {"ai-agent-skill": "skills/{skill-name}/SKILL.md"}` (path to the
  nested `SKILL.md`; for single-skill repos this is `skills/{repo-slug}/SKILL.md`)

## This Repository

`skill-repo-skill` dogfoods the layout above and additionally hosts reusable CI workflows consumed by other Netresearch skill repos:

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
├── .claude-plugin/plugin.json
├── .github/workflows/             # Reusable workflows hosted here:
│                                  #   validate, release, pr-quality,
│                                  #   harness-verify, eval-validate,
│                                  #   validate-agents, dependency-audit,
│                                  #   npm-pack-smoke, ci-python
│                                  # (auto-merge runs via a thin caller that
│                                  #  delegates to netresearch/.github)
├── Build/
│   ├── Scripts/check-plugin-version.sh
│   └── hooks/                     # pre-commit, pre-push
├── docs/
│   ├── ARCHITECTURE.md
│   └── dashboard/                 # Cross-skill metrics dashboard
├── scripts/                       # Repo-level: generate-dashboard,
│                                  #   run-ab-evals, verify-harness
├── tests/                         # Eval fixtures
└── skills/skill-repo/
    ├── SKILL.md
    ├── checkpoints.yaml
    ├── evals/evals.json
    ├── references/                # composer-setup, installation-methods,
    │                              #   marketplace-integration,
    │                              #   release-discipline, review-replies
    ├── scripts/                   # validate-skill, validate-evals,
    │                              #   migrate-licensing, check-version-parity
    └── templates/                 # README, composer.json, package.json,
                                   #   release.yml, pr-quality.yml,
                                   #   licenses, hooks
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for component responsibilities.

## Extends Anthropic's Skill Creator

This skill **extends** (not replaces) Anthropic's skill-creator:

| Aspect | Anthropic's skill-creator | This skill adds |
|--------|---------------------------|-----------------|
| Focus | SKILL.md content | Repository structure |
| Scope | Single file | Full repo layout |
| Distribution | Claude Code native | + Marketplace, Composer |
| Audience | AI instructions | + Human README |

## Contributing

Contributions welcome! Please submit PRs for:
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
