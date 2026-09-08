# Installation Methods

## Contents

- Method 1: Netresearch Marketplace (Recommended)
- Method 2: Skills Directory (no marketplace)
- Method 3: Download Release
- Method 4: Composer (PHP Projects)
- Method 5: npm (Node Projects)
- Choosing a Method
- Directory Locations

Five methods for installing Netresearch skills.

## Method 1: Netresearch Marketplace (Recommended)

The marketplace aggregates all Netresearch skills in one place.

### Setup

```bash
/plugin marketplace add netresearch/claude-code-marketplace
```

### Usage

```bash
# Browse available plugins
/plugin

# Install a specific plugin
/plugin install {plugin-name}@netresearch-claude-code-marketplace
```

`{plugin-name}` is the `name` field of the repo's entry in the catalog's
`marketplace.json`, which is **not** always the repo name — `jira-skill` is
`jira-integration`, `matrix-skill` is `matrix-communication`,
`php-ast-edit-skill` is `php-structured-edit`. Read the name from the catalog,
never derive it from the repo slug.

### Do not point `marketplace add` at a skill repo

```bash
# WRONG — fails with: Marketplace file not found at .../marketplace.json
/plugin marketplace add netresearch/{repo-name}
```

`marketplace add` requires the target repo to contain a
`.claude-plugin/marketplace.json` **catalog**. Skill repos ship a
`.claude-plugin/plugin.json` **plugin manifest** instead, so this fails. The
catalog is `netresearch/claude-code-marketplace`; its entries point back at
each skill repo as their source, so installing from it still fetches the code
from this repo.

### Benefits

- Curated collection
- Automatic updates — the only route with `claude plugin update` and a version in `/plugin`
- Easy discovery
- No manual file management

## Method 2: Skills Directory (no marketplace, Claude Code 2.1.157+)

Since Claude Code 2.1.157: *"Plugins in `.claude/skills` directories are now
automatically loaded, no marketplace required."* Any folder under a skills
directory containing `.claude-plugin/plugin.json` loads as
`{plugin-name}@skills-dir` on the next session — discovered in place, not
copied into the plugin cache.

### Installation

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/netresearch/{repo-name}.git \
  ~/.claude/skills/{plugin-name}
```

### What loads

Personal scope (`~/.claude/skills/`) loads the whole plugin — skills, agents,
hooks, commands, `bin/`, `.mcp.json`, `.lsp.json` — with no restrictions.

Project scope (`<cwd>/.claude/skills/`, checked into a repo) loads only after
the workspace trust dialog, and restricts what runs: MCP servers need
per-server approval, LSP servers start only after trust, and background
monitors do not load at all. Project-scope plugins are found only in the
session's primary working directory — they do not walk up to the repo root, so
launch from the repo root or move there with `/cd` (2.1.246+).

### Update and removal

```bash
git -C ~/.claude/skills/{plugin-name} pull   # update
rm -rf ~/.claude/skills/{plugin-name}        # remove
claude plugin disable {plugin-name}@skills-dir  # keep on disk, stop loading
```

There is no uninstall step, because nothing was installed from a marketplace.
`SKILL.md` edits apply immediately; changes to `hooks/`, `.mcp.json`,
`agents/` and output styles need `/reload-plugins` or a restart.

### Trade-off vs. the marketplace

No `claude plugin update`, no version in `/plugin`, no discovery — updating is
whatever `git pull` gives you. Use it for pinning to a branch or working from
a local checkout; prefer the marketplace otherwise.

## Method 3: Download Release

Download packaged skill files from GitHub Releases.

### Steps

1. Go to skill's GitHub repository
2. Navigate to Releases page
3. Download latest `.zip` or `.tar.gz`
4. Extract to `~/.claude/skills/{skill-name}/`

### Package Contents

Release packages contain only skill-relevant files:
- `SKILL.md`
- `LICENSE-MIT`
- `LICENSE-CC-BY-SA-4.0`
- `references/`
- `scripts/`
- `assets/`
- `templates/`

### Excluded from Packages

- `README.md` (human documentation)
- `.github/` (CI/CD)
- `composer.json` (separate distribution)
- Dev configuration files

## Method 4: Composer (PHP Projects)

For PHP projects, install skills as Composer packages.

### Prerequisites

1. PHP 8.2+
2. Composer 2.1+
3. [composer-agent-skill-plugin](https://github.com/netresearch/composer-agent-skill-plugin)

### Installation

```bash
# Install the plugin first (once per project)
composer require netresearch/composer-agent-skill-plugin

# Install skills
composer require netresearch/{repo-name}
```

### How It Works

1. Plugin discovers packages with type `ai-agent-skill`
2. Generates `AGENTS.md` index in project root
3. Skills available via `composer read-skill {name}`

### Benefits

- Version management via Composer
- Dependency resolution
- Project-specific skill sets
- Easy updates with `composer update`

## Method 5: npm (Node Projects)

For Node.js / TypeScript projects, install skills as npm packages discovered by `@netresearch/agent-skill-coordinator`.

### Prerequisites

1. Node.js 18+ and npm 9+ (or pnpm/yarn equivalent)
2. [`@netresearch/agent-skill-coordinator`](https://github.com/netresearch/node-agent-skill-coordinator) — peer dependency that scans `node_modules` and registers skills in `AGENTS.md`

### Installation

```bash
npm install --save-dev \
  @netresearch/agent-skill-coordinator \
  github:netresearch/{repo-name}
```

For pnpm, allowlist the coordinator's `postinstall` so it can write `AGENTS.md`:

```json
{
  "pnpm": {
    "onlyBuiltDependencies": ["@netresearch/agent-skill-coordinator"]
  }
}
```

### How It Works

1. Coordinator's `postinstall` walks `node_modules` for packages declaring `aiAgentSkill: skills/<name>/SKILL.md`
2. Validates frontmatter, then writes a `<skills_system>` block into the project's `AGENTS.md`
3. Skill content is then visible to any agent reading `AGENTS.md`

### What ships in the npm tarball

The `files` allowlist in `package.json` controls what npm packs. The default in `templates/package.json.template` is intentionally **minimal** — the skill payload (`skills/<name>/`), plugin metadata (`.claude-plugin/`), the canonical agent rules entry-point (`AGENTS.md`), licenses, and `README.md`:

```json
{
  "files": [
    "skills/{skill-name}/",
    ".claude-plugin/",
    "AGENTS.md",
    "LICENSE-MIT",
    "LICENSE-CC-BY-SA-4.0",
    "README.md"
  ]
}
```

#### When to add a top-level data dir

Add a top-level dir to `files` **only if your installed skill code reads from it at runtime** (e.g. via `$ROOT/<dir>/...` or `../<dir>/...` from a script under `skills/<name>/scripts/`). Common runtime data dirs:

- `catalog/` — `cli-tools-skill` ships this because its installer scripts read `$ROOT/catalog/*.json`.
- `hooks/` — Claude Code's plugin loader reads `hooks/hooks.json`. Ship it if your skill ships PreToolUse/PostToolUse hooks.
- `commands/` — slash command definitions. Ship if present.
- `outputStyles/` — output style definitions. Ship if present.
- `assets/` — referenced assets (images, configs). Ship if your skill content references them at install paths.

#### When NOT to add a top-level dir

- **Top-level `scripts/`** is typically **repo-maintenance only** (e.g. `verify-harness.sh`, `generate-dashboard.sh`). Keep it out unless your installed skill scripts read from `$ROOT/scripts/` at runtime. Runtime scripts belong under `skills/<name>/scripts/` (already covered by `skills/<name>/`).
  - Example: `context7-skill` does NOT ship top-level `scripts/` because its only file is `verify-harness.sh` (repo-maintenance).
  - Example: `cli-tools-skill` DOES ship `catalog/` because its installer scripts read `$ROOT/catalog/*.json`.
- `Build/` — dev-only build artifacts. Never ship.
- `evals/`, `docs/` — repo-internal. Never ship.
- `.github/`, lint configs (`.markdownlint*`, `.yamllint*`), `.envrc` — repo-internal. Never ship.

Heuristic when looking at a top-level dir:

```text
package-root/
  catalog/   # consumed at runtime  -> MUST be in files
  Build/     # dev-only build artifacts -> DO NOT include
  scripts/   # inspect: runtime or repo-maintenance? include only if runtime
```

#### CI safeguard

`templates/.github/workflows/npm-pack-smoke.yml.template` is a ready-to-copy GitHub Actions workflow that runs `npm pack --dry-run` on every PR and asserts:

1. **No internal leakage** — fails if the tarball contains `.github/`, `evals/`, `docs/`, `Build/`, `verify-harness.sh`, lint configs, etc.
2. **Runtime-referenced dirs are present** — greps `skills/*/scripts/` for `$ROOT/<dir>` and `../<dir>/` references; if a script reads `$ROOT/catalog` but `catalog/` is missing from the tarball, the job fails.

Copy it into `.github/workflows/npm-pack-smoke.yml` in your skill repo. It catches both kinds of `files`-allowlist mistakes (over-inclusion and under-inclusion) before they ship.

### `"private": true` on `0.0.0-source`

Skill repos use the placeholder version `0.0.0-source` and **must** set `"private": true` to guard against accidental `npm publish` of the placeholder. Real publishes (when/if added later) flip `private` to `false` (or remove it) at release time and set a real semver.

### Limitation: SKILL.md content only

The npm path registers only `SKILL.md` content into `AGENTS.md`. **Slash commands** (defined under `commands/`) and **PreToolUse / PostToolUse hooks** (defined under `.claude-plugin/`) are loaded by Claude Code's plugin mechanism — not by the coordinator scanning `node_modules`. Repos that ship those features should document this explicitly in their README (a `> **Limitation:**` callout immediately after the npm install snippet) so consumers know they need the marketplace install for the full skill.

### Benefits

- Lock-file pinning via `package-lock.json` / `pnpm-lock.yaml`
- Renovate / Dependabot can bump skill versions like any other dep
- No PHP / Composer required for Node-only projects

## Choosing a Method

| Scenario | Recommended Method |
|----------|-------------------|
| General Claude Code use | Marketplace |
| Offline/air-gapped | Release download |
| Repo not in the catalog | Skills directory |
| Pinning to a branch, or hacking on the skill | Skills directory |
| PHP project | Composer |
| Node / TypeScript project | npm |
| CI/CD automation | Composer or npm |
| Quick trial | Marketplace |

## Directory Locations

| Method | Location |
|--------|----------|
| Marketplace | Managed by Claude Code |
| Skills directory | `~/.claude/skills/{plugin-name}/` (loaded in place) |
| Release | `~/.claude/skills/{skill-name}/` |
| Composer | `vendor/netresearch/{repo-name}/` |
| npm | `node_modules/@netresearch/{repo-name}/` |
