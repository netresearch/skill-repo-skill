<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

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

Add the [Netresearch marketplace](https://github.com/netresearch/claude-code-marketplace) once, then install this plugin from it:

```bash
/plugin marketplace add netresearch/claude-code-marketplace
/plugin install skill-repo@netresearch-claude-code-marketplace
```

> **Do not** run `/plugin marketplace add netresearch/skill-repo-skill`. `marketplace add` needs a `.claude-plugin/marketplace.json` catalog; this repo ships a `.claude-plugin/plugin.json` plugin manifest, so that fails with `Marketplace file not found`.

### Without a marketplace: skills directory (Claude Code 2.1.157+)

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/netresearch/skill-repo-skill.git \
  ~/.claude/skills/skill-repo
```

Loads as `skill-repo@skills-dir` on the next session. Update with `git -C ~/.claude/skills/skill-repo pull` and start a new session; remove by deleting the directory.

### npx ([skills.sh](https://skills.sh))

Install with any [Agent Skills](https://agentskills.io)-compatible agent:

```bash
npx skills add https://github.com/netresearch/skill-repo-skill --skill skill-repo
```

> **Limitation:** `npx skills` installs `SKILL.md`-based skills only. It reads `.claude-plugin/plugin.json` to *locate* skills, not to register a plugin, so `hooks/`, `agents/`, `commands/`, `bin/` and `.mcp.json` are left out. Use the marketplace or the skills directory when a repo ships any of those.

### Download release

Download the [latest release](https://github.com/netresearch/skill-repo-skill/releases/latest) and extract to your agent’s skills directory.

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

1. **Marketplace** (recommended) — `/plugin marketplace add netresearch/claude-code-marketplace`, then `/plugin install <plugin-name>@netresearch-claude-code-marketplace`
2. **Skills directory** — clone into `~/.claude/skills/<plugin-name>/`; loads as `<plugin-name>@skills-dir`, no marketplace (Claude Code 2.1.157+)
3. **npx (skills.sh)** — `npx skills add <repo-url> --skill <name>` (skills only: drops hooks, agents, commands, `bin/`)
4. **Release download** — GitHub Releases (skill files only)
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
│   ├── SECURITY-ASSURANCE.md
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

### Tests

The suite lives in `tests/`: one Bash script per area plus `tests/renovate-custom-manager.py`. It needs Bash 4.3+, Python 3 (standard library), Git and `jq`. `tests/validate-skill.sh` also runs the PyYAML path of the validator when `python3` can import `yaml` or `uv` is installed, and skips it with a notice otherwise; `tests/fleet-release.sh` skips its manifest cases without `gh`. No test calls a model: `tests/run-ab-evals.sh` puts a stub `claude` on `PATH`. The only download is PyYAML through `uv`, for that optional path. Run everything the way CI does:

```bash
for t in tests/*.sh; do bash "$t" || echo "FAILED: $t"; done
for t in tests/*.py; do python3 "$t" || echo "FAILED: $t"; done
```

- `validate-skill.sh`, `validate-skill-architecture.sh`, `portable-manifest.sh`, `mechanical-coverage.sh`: the validator's verdicts (frontmatter parsing on both parser paths, multi-skill discovery, size budgets, dangling paths, `allowed-tools`, README install lines, release path, script-test lookup, `plugin.json`) and `sync-plugin-manifest.sh`, `bump-version.sh`, `check-version-parity.sh`.
- `validate-evals.sh`, `run-ab-evals.sh`: the eval validator on the three eval formats, and the A/B runner's provenance, sampling, gates and argument handling.
- `fleet-release.sh`, `roll-changelog.sh`, `migrate-licensing.sh`, `release-archive-layout.sh`: the fleet release driver offline, the changelog roll, the licensing migration on throwaway repositories, and the archive layout `release.yml` builds.
- `usage-text.sh`, `audit-skills.sh`, `renovate-custom-manager.py`: `--help` output of the shipped scripts, `scripts/audit-skills.sh`, and the Renovate regex manager in `renovate.json`.

Each file prints a `FAIL` line naming each check that did not hold, ends with a summary line, and exits non-zero on any failure. Some files also print a line for each passing check (`ok`, `PASS` or `[OK]`).

In CI, every push to `main` and every pull request runs Skill Tests (`tests-caller.yml` calls the local `tests.yml`, which runs `tests/**/*.sh` and `tests/**/*.py`, each in its own log group) and Self-test (`self-test.yml`: the validator and manifest tests, this repository validated with the validator from the pull request, version parity, and the full Skill Validation job at ShellCheck severity `style`).

**Test policy:** a pull request that adds or changes behaviour of a script under `skills/skill-repo/scripts/` or `scripts/`, or of a check in a reusable workflow, adds or updates a test in `tests/` that fails without the change. Passing the existing suite is not enough for new functionality.

### Dependencies

- **Shipped package:** `composer.json` requires `netresearch/composer-agent-skill-plugin`, which registers the skill in a PHP project; `package.json` declares `@netresearch/agent-skill-coordinator` as a peer dependency for the same job in Node projects. Neither has a lock file: a skill package pins nothing for its consumers (see [AGENTS.md](AGENTS.md)).
- **Scripts:** Bash, Python 3 standard library, Git and `jq`; PyYAML is optional for `validate-skill.sh`; the fleet driver needs `gh`; `scripts/run-ab-evals.sh` needs the `claude` CLI. None is installed by this repository.
- **CI tools:** third-party GitHub Actions are pinned to commit SHAs. `validate.yml` downloads ShellCheck 0.11.0 and checks its SHA-256, and runs `ruff` 0.16.9 and `pyyaml` 6.0.3 through `uv`. bandit and pip-audit are installed with `--require-hashes` from `.github/requirements/*.txt`, generated with `uv pip compile --generate-hashes`. Pre-commit hooks are pinned by `rev:` in `.pre-commit-config.yaml`. `ab-evals-schedule.yml` installs `@anthropic-ai/claude-code` at a fixed version.
- **Tracking and updates:** Renovate (`renovate.json`: `config:recommended`, pre-commit hooks enabled, and a regex manager for the `uvx …@version` and `uv run --with …==version` pins in workflows, tested by `tests/renovate-custom-manager.py`) opens update pull requests; `auto-merge-deps-caller.yml` hands them to the organisation's auto-merge workflow, which merges them after their checks pass. The ShellCheck version and checksum, the `pyyaml` and `claude-code` pins and the files in `.github/requirements/` have no Renovate rule and are updated by hand.
- **Selection:** a new dependency is added in a pull request that changes the manifest or workflow that uses it, and is reviewed there, including its licence against the organisation policy below. Dependency review and Composer Audit run on that pull request (see below).

### Governance and policies

This repository follows the Netresearch organisation policies:

- [Governance](https://github.com/netresearch/.github/blob/main/GOVERNANCE.md): ownership, roles, how decisions are made and disputes resolved, and continuity.
- [Roadmap](https://github.com/netresearch/.github/blob/main/ROADMAP.md): planned and explicitly excluded work for the coming year.
- [Handling of dependency and code analysis findings](https://github.com/netresearch/.github/blob/main/SECURITY.md#handling-of-dependency-and-code-analysis-findings): thresholds, deadlines and the exception process for dependency (SCA) and static analysis (SAST) findings.
- [Secret management](https://github.com/netresearch/.github/blob/main/SECURITY.md#secret-management): how CI and release credentials are stored, accessed and rotated.
- [Access roster](https://github.com/netresearch/.github/blob/main/docs/access-roster.md): who holds administrative access to this repository and the organisation.

The security assurance case for this repository (threat model, trust boundaries, countermeasures and limits) is in [docs/SECURITY-ASSURANCE.md](docs/SECURITY-ASSURANCE.md).

Checks that run on every pull request in this repository: Skill Validation (`lint.yml`, the reusable `validate.yml` from `main`: skill structure, plugin manifest sync, markdownlint, yamllint, actionlint, JSON syntax, ShellCheck, ruff, checkpoint schemas), Self-test, Skill Tests, Eval Validation, npm Pack Smoke, the template drift check, and Security (`security.yml`, for pull requests against `main`): Betterleaks secret scanning, zizmor on the workflows, dependency review, and Composer Audit with an Opengrep SAST scan. CodeQL default setup, SonarCloud and the DCO check also report on pull requests; they are configured in the repository settings, not in this repository.

## License

This project uses split licensing:

- **Code** (scripts, workflows, configs): [MIT](LICENSE-MIT)
- **Content** (skill definitions, documentation, references): [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0)

See the individual license files for full terms.

## Credits

Developed and maintained by [Netresearch DTT GmbH](https://www.netresearch.de/).

---

**Made with ❤️ for Open Source by [Netresearch](https://www.netresearch.de/)**
