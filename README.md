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

```
{skill-name}/
├── SKILL.md              # AI instructions
├── README.md             # Human documentation
├── LICENSE-MIT           # Code license (MIT)
├── LICENSE-CC-BY-SA-4.0  # Content license (CC-BY-SA-4.0)
├── composer.json         # PHP distribution
├── references/           # Extended docs
├── scripts/              # Automation
├── assets/               # Templates
└── .github/workflows/    # CI/CD
```

### Three Installation Methods

1. **Marketplace** - `/plugin marketplace add netresearch/claude-code-marketplace`
2. **Release Download** - GitHub Releases (skill files only)
3. **Composer** - `composer require netresearch/agent-{skill-name}`

### Composer Package Requirements

- `"type": "ai-agent-skill"`
- `"require": {"netresearch/composer-agent-skill-plugin": "*"}`
- `"extra": {"ai-agent-skill": "SKILL.md"}`

## Structure

```
skill-repo-skill/
├── SKILL.md                      # AI instructions
├── README.md                     # This file
├── LICENSE-MIT                   # Code license (MIT)
├── LICENSE-CC-BY-SA-4.0          # Content license (CC-BY-SA-4.0)
├── composer.json                 # PHP distribution
├── templates/
│   ├── README.md.template        # README template for skills
│   ├── composer.json.template    # Composer template
│   └── release.yml.template      # Release workflow template
├── references/
│   ├── installation-methods.md   # Detailed install guides
│   ├── composer-setup.md         # Composer integration
│   └── marketplace-integration.md
└── scripts/
    └── validate-skill.sh         # Validation script
```

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
