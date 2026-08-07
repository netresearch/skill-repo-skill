# Agent Plugins 1.0.0 compatibility

Netresearch skill repos ship **two** manifests. This page says what each one is
for, which is authoritative, and how to migrate a repo that has only the
Claude Code one.

Spec: <https://agent-plugins.org/specification> ·
Schema: <https://agent-plugins.org/schemas/1.0.0/plugin.schema.json> ·
Skill format: <https://agentskills.io/specification>

## Why two files

| File | Read by | Role |
|---|---|---|
| `./plugin.json` | every Agent Plugins client (Cursor, Copilot, …) | **source of truth** for shared metadata |
| `./.claude-plugin/plugin.json` | Claude Code only | generated projection + Claude-only keys |

Claude Code reads its manifest from `.claude-plugin/plugin.json` and nowhere
else; Agent Plugins clients read `plugin.json` at the package root and nowhere
else. One file cannot serve both: the portable schema is **closed**
(`additionalProperties: false`), so `skills`, `agents`, `commands`,
`outputStyles`, `hooks`, `mcpServers`, `metadata` and `support` are schema
violations there. Conversely Claude Code ignores fields it does not know, which
is why the projection into `.claude-plugin/plugin.json` is safe.

Skills need no change: `skills/<name>/SKILL.md` is what both specs discover.

## The portable manifest

```json
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
  "name": "skill-repo",
  "version": "1.27.0",
  "description": "Guide for structuring Netresearch skill repositories",
  "author": {
    "name": "Netresearch DTT GmbH",
    "url": "https://www.netresearch.de"
  },
  "repository": "https://github.com/netresearch/skill-repo-skill",
  "license": "(MIT AND CC-BY-SA-4.0)"
}
```

Allowed top-level fields — nothing else:

| Field | Required | Notes |
|---|---|---|
| `$schema` | yes | exactly the 1.0.0 URL above |
| `name` | yes | 1–64 chars, `a-z0-9` plus `-` and `.`, starts and ends alphanumeric, no `--` or `..`. Matches the Claude manifest name (and, for single-skill repos, the SKILL.md `name`) |
| `version` | no | SemVer; same value as `.claude-plugin/plugin.json` and SKILL.md `metadata.version` |
| `description` | no | short purpose statement |
| `author` | no | object with `name`, `email`, `url` only — `"author": "Name"` is invalid |
| `homepage`, `repository`, `license` | no | strings; license stays the SPDX expression `(MIT AND CC-BY-SA-4.0)` |
| `keywords` | no | array of strings |
| `extensions` | no | object keyed by **reverse-domain namespaces owned by the client vendor**. We do not invent namespaces for clients — Claude-specific data lives in `.claude-plugin/`, not here |

## Generating the Claude manifest

```bash
bash skills/skill-repo/scripts/sync-plugin-manifest.sh            # write
bash skills/skill-repo/scripts/sync-plugin-manifest.sh --check    # CI gate
bash skills/skill-repo/scripts/sync-plugin-manifest.sh --repo DIR # fleet driver
```

The script copies `name`, `version`, `description`, `author`, `homepage`,
`repository`, `license` and `keywords` into `.claude-plugin/plugin.json`,
preserves every Claude-only key already there, and never copies `$schema` or
`extensions`. `--check` compares those shared values in both directions — key
order and formatting in the Claude manifest are not enforced. Without a root
`plugin.json` it is a no-op, so it is safe to run across repos that have not
migrated yet.

## Migrating a repo

1. Create `./plugin.json` with the fields above, copying the current values out
   of `.claude-plugin/plugin.json`. Drop `skills`/`agents`/`support` — they stay
   in the Claude manifest.
2. Run `sync-plugin-manifest.sh` and confirm the diff is only a key reorder.
3. If the repo ships a root `SKILL.md` instead of `skills/<name>/SKILL.md`, move
   it: Agent Plugins clients do not discover a root `SKILL.md`. Claude Code
   loads either layout, so the move is safe there — but the plugin's skill name
   then comes from the directory, so keep the directory name equal to the
   frontmatter `name`.
4. `bash skills/skill-repo/scripts/validate-skill.sh .` — 0 errors.

## What validation enforces

`validate-skill.sh` checks, when `./plugin.json` exists: the `$schema` constant,
the `name` pattern, that no field outside the closed schema is present, the
`author`/`keywords`/`extensions` shapes, that the shared fields match
`.claude-plugin/plugin.json`, and that at least one `skills/<name>/SKILL.md`
exists. A **missing** `./plugin.json` is a warning, not an error — the validator
runs fleet-wide from `main` while repos adopt the manifest one PR at a time.

`check-version-parity.sh` treats the root `plugin.json` version as
authoritative and fails when `.claude-plugin/plugin.json` disagrees.

## Out of scope

Agent Plugins defines packaging only. Distribution, installation, marketplaces
and permissions stay client-specific, so `claude-code-marketplace` entries and
the composer/npm channels are unaffected by this standard.

An `mcp.json` at the package root is the portable way to ship MCP servers. No
Netresearch skill repo ships one today; add it only alongside a real server, and
keep its `$schema` version equal to the one in `plugin.json`.
