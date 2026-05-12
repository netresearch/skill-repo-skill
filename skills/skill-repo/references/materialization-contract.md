# Materialization Contract

How external tools (notably `retro-skill`) materialize **skill improvements** or **new skills** by submitting PRs to skill repositories. This document is the contract: any tool that wants to write to a skill repo follows these rules.

## Scope

This contract covers two destinations from `retro-skill/references/destination-taxonomy.md`:

- **`skill-update`** — PR against an existing skill repo
- **`new-skill`** — Scaffolding of a new skill repo

## Rule 1: Patches target source repos, never local cache

Local skill cache (`~/.claude/plugins/cache/`) is overwritten on plugin update. Edits there are lost. **Always** locate the source repository before patching.

Resolution order:
1. `<skill-root>/.claude-plugin/plugin.json` → `repository` field
2. `<skill-root>/composer.json` → `support.source` or `homepage`
3. `<skill-root>/.git/config` → `remote.origin.url`
4. Walk up parent directories from resolved-symlink path looking for any of the above
5. Last resort: ask the user

If unresolvable: do NOT patch local cache. Either ask user or refuse.

## Rule 2: Workspace preference order

For each skill-update target, select working directory in this order:

1. **Existing worktree:** `~/p/<skill-name>/main/` exists AND is a clean git worktree → use it
2. **Existing flat checkout:** `~/p/<skill-name>/` exists AND is clean AND on main → use it
3. **Fresh clone:** `/tmp/retro-workspace/<skill-name>/` → clone here

Dirty checkouts: do NOT use. Fall back to /tmp. Always tell the user why.

## Rule 3: Branch convention

```
feat/retro-<short-slug>
```

`<short-slug>` is kebab-case, derived from the friction title, max 40 chars.

Examples:
- `feat/retro-add-bun-trigger-keywords`
- `feat/retro-fix-yaml-tool-choice`

For `new-skill`: the new repo's first branch is `main` (initial scaffolding commit).

## Rule 4: Commit conventions

- **Format:** Conventional Commits (`<type>(<scope>): <summary>`)
  - Types: `feat`, `fix`, `docs`, `refactor`, `chore`
- **No bot attribution.** Never append "Generated with Claude Code" or "Co-Authored-By: Claude"
- **Preserve signing.** Never pass `--no-gpg-sign` or `-c commit.gpgsign=false`
- **Preserve hooks.** Never pass `--no-verify`
- **Atomic.** One logical change per commit

Commit message body should reference the friction:

```
feat(triggers): include bun in skill description keywords

Found via /retro session 2026-05-11: the assistant suggested npm
in 4 turns despite the project clearly using bun. SKILL.md description
didn't include 'bun' as a trigger.
```

## Rule 5: PR body schema

```markdown
## Summary

<1-2 sentences>

## Came from

`/retro` session on <date>: <session-id>
Finding: <friction signal id> — <one-line description>

## Change

<what was changed>

## Test plan

- [ ] <verification step>
- [ ] <verification step>
```

## Rule 6: Target area mapping

Each `skill-update` PR should touch exactly one of:

| Target | When |
|---|---|
| `SKILL.md` | Trigger description, workflow guidance, key principles |
| `references/*.md` | Detailed knowledge, examples, schemas |
| `scripts/*` | Mechanical operations |
| `templates/*` | Output formats |
| `checkpoints.yaml` | Quality gates (mechanical or LLM checks) |
| `evals/*` | Behavioral regression tests |

Multi-area PRs are allowed but should be cohesive (e.g. SKILL.md update + corresponding eval). Split unrelated concerns into separate PRs.

## Rule 7: Eval stub for behavior changes

When a `skill-update` changes behavior expectations (not just docs), include an eval stub alongside the fix:

```markdown
---
scenario: <name-matching-friction>
trigger: <user input that should activate the new behavior>
expected: <expected response after fix>
---
```

This is TDD style: eval that would have caught the friction goes in with the fix. See `retro-skill/references/eval-integration.md`.

## Rule 8: Per-private-repo confirmation

Before pushing to a private host (`git.netresearch.de`, `gitlab.com/<private-org>`, etc.), prompt the user. Decision is remembered per (session, repo URL).

## Rule 9: New-skill scaffolding

For `new-skill` destination, scaffold using `skill-repo-skill` templates:

- `composer.json` with `type: ai-agent-skill`
- `.claude-plugin/plugin.json` with marketplace metadata
- `skills/<name>/SKILL.md` with initial trigger description
- `LICENSE-MIT` and `LICENSE-CC-BY-SA-4.0`
- `README.md` describing the skill
- `AGENTS.md` index
- One initial `references/*.md` covering the friction pattern that triggered the new skill
- One initial `evals/*.md` covering the friction (TDD)
- `.gitignore`, `renovate.json`, optional GitHub workflows

Marketplace listing is a separate manual step (out of scope for this contract).

## See also

- `retro-skill/references/destination-taxonomy.md` — Six destinations
- `retro-skill/references/patch-workflow.md` — Workflow on the retro-skill side
- `templates/` — Skill scaffolding templates
- User memory: `feedback_preserve-commit-signing`, `feedback_merge-strategy`, `feedback_no-version-bumps-in-feature-prs`
