# Installation Methods

Four methods for installing Netresearch skills.

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

# Install specific skill
/plugin install {skill-name}
```

### Benefits

- Curated collection
- Automatic updates via sync
- Easy discovery
- No manual file management

## Method 2: Download Release

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

## Method 3: Composer (PHP Projects)

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

## Method 4: npm (Node Projects)

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
| PHP project | Composer |
| Node / TypeScript project | npm |
| CI/CD automation | Composer or npm |
| Quick trial | Marketplace |

## Directory Locations

| Method | Location |
|--------|----------|
| Marketplace | Managed by Claude Code |
| Release | `~/.claude/skills/{skill-name}/` |
| Composer | `vendor/netresearch/{repo-name}/` |
| npm | `node_modules/@netresearch/{repo-name}/` |
