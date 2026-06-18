# Materialization Contract

How external tools (notably `retro-skill`) materialize **skill improvements** or **new skills** by submitting PRs to skill repositories that follow `skill-repo-skill` conventions.

## Scope

This contract covers two destinations from [retro-skill](https://github.com/netresearch/retro-skill)'s destination taxonomy:

- **`skill-update`** — PR against an existing skill repo
- **`new-skill`** — Scaffolding of a new skill repo

For the full destination taxonomy and routing heuristics, see [retro-skill/references/destination-taxonomy.md](https://github.com/netresearch/retro-skill/blob/main/references/destination-taxonomy.md).

## Rule 1: Patches target source repos, never local cache

Local skill cache (`~/.claude/plugins/cache/`) is overwritten on plugin update. Edits there are lost. **Always** locate the source repository before patching.

Resolution order:

1. `<skill-root>/.claude-plugin/plugin.json` → `repository` field
2. `<skill-root>/composer.json` → `support.source` or `homepage`
3. `<skill-root>/.git/config` → `remote.origin.url`
4. Walk up parent directories from the resolved-symlink path looking for any of the above
5. Last resort: ask the user

If unresolvable: do NOT patch local cache. Either ask user or refuse.

## Rule 2: Workspace preference order

For each skill-update target, select working directory in this order:

1. **Existing worktree:** `~/p/<repo-name>/main/` exists AND is a clean git worktree → use it. `<repo-name>` is the full GitHub repo name (e.g. `skill-repo-skill`, not `skill-repo`).
2. **Existing flat checkout:** `~/p/<repo-name>/` exists AND is a clean flat git checkout on `main` → use it.
3. **Fresh clone:** Otherwise clone into `/tmp/retro-workspace/<repo-name>/`.

Dirty checkouts: do NOT use. Fall back to /tmp. Always tell the user why.

## Rule 3: Branch convention

```
feat/retro-<short-slug>
```

`<short-slug>` is kebab-case, derived from the friction title. **Maximum 60 characters** for the slug part (full branch ≤ 71 chars including `feat/retro-` prefix; comfortable on most terminals).

Examples:

- `feat/retro-add-bun-trigger-keywords`
- `feat/retro-fix-yaml-tool-choice-for-data-tools`

For `new-skill`: the new repo's first branch is `main` (initial scaffolding commit).

## Rule 4: Commit conventions

- **Format:** Conventional Commits (`<type>(<scope>): <summary>`)
  - Types: `feat`, `fix`, `docs`, `refactor`, `chore`
- **No bot attribution.** Never append "Generated with Claude Code" or "Co-Authored-By: Claude"
- **Preserve signing.** Never pass `--no-gpg-sign` or `-c commit.gpgsign=false`
- **Preserve hooks.** Never pass `--no-verify`
- **DCO sign-off.** All commits include `Signed-off-by: <name> <email>` trailer (use `git commit -s` or `git rebase --signoff`)
- **Atomic.** One logical change per commit

Commit message body should reference the friction:

```
feat(triggers): include bun in skill description keywords

Found via /retro session 2026-05-11: the assistant suggested npm
in 4 turns despite the project clearly using bun. SKILL.md description
didn't include 'bun' as a trigger.

Signed-off-by: Sebastian Mendel <github@sebastianmendel.de>
```

## Rule 5: PR template

PRs created by retro-skill should use the named template `retro.md`:

```bash
gh pr create --template retro.md ...
# or via URL query when opening manually:
# https://github.com/<org>/<repo>/compare/main...<branch>?template=retro.md
```

This invokes `.github/PULL_REQUEST_TEMPLATE/retro.md` (not the repo's default template, if any). The retro template has:

- `## Summary`
- `## Came from` (session date, finding signal ID)
- `## Change` (concrete diff scope)
- `## Target area` (`skills/<name>/SKILL.md` / `references/` / `scripts/` / `templates/` / `checkpoints.yaml` / `evals/evals.json`)
- `## Learning source` (checkboxes: from /retro, reusable, scoped, eval included)
- `## Test plan` (verification steps)

## Rule 6: Target area mapping

Paths are relative to the **skill's own subdirectory** in the repo (this repo's convention: `skills/<skill-name>/...`, not repo-root).

Each `skill-update` PR should touch **one primary area**; multi-area is allowed when cohesive (e.g. SKILL.md update + corresponding eval).

| Target | When |
|---|---|
| `skills/<name>/SKILL.md` | Trigger description, workflow guidance, key principles |
| `skills/<name>/references/*.md` | Detailed knowledge, examples, schemas |
| `skills/<name>/scripts/*` | Mechanical operations |
| `skills/<name>/templates/*` | Output formats |
| `skills/<name>/checkpoints.yaml` | Quality gates (mechanical or LLM checks) |
| `skills/<name>/evals/evals.json` | Behavioral regression tests |

Multi-area PRs split unrelated concerns into separate PRs.

## Rule 7: Eval format (skill-repo convention)

This repo's eval format is **a single `evals/evals.json` file** containing an array of objects. Each object has at minimum:

```json
{
  "name": "<scenario-name>",
  "prompt": "<what to ask the agent>",
  "assertions": [
    { "type": "content", "pattern": "<regex>" },
    { "type": "tool_use", "tool": "<ToolName>", "pattern": "<regex>" }
  ]
}
```

Validation: `bash skills/skill-repo/scripts/validate-evals.sh`.

When a `skill-update` PR changes behavior expectations, **append a new eval object to the existing `evals/evals.json` array** in the target skill's directory. Do NOT emit `evals/*.md` files — they will be rejected by the validator.

Other skill repos may use different eval conventions; consult each target's `evals/` directory before submitting.

## Rule 8: Per-private-repo confirmation

Before pushing to a private host (`git.netresearch.de`, `gitlab.com/<private-org>`, etc.), prompt the user. Decision is remembered per `(session, repo-url)` for the duration of the active retro-skill session; not persisted across sessions.

## Rule 9: New-skill scaffolding

For `new-skill` destination, use the templates in `skills/skill-repo/templates/`:

- `composer.json.template` (with `type: ai-agent-skill`, split licensing in SPDX)
- `package.json.template` (for npm-distributable variants)
- `LICENSE-MIT.template`, `LICENSE-CC-BY-SA-4.0.template`
- `README.md.template`
- `release.yml.template` (GitHub Actions release workflow)
- `validate.yml.template` (CI caller for the reusable skill-validation workflow — without it the SKILL.md word cap, plugin.json schema, and markdown/yaml/action lints run only in local pre-commit, never in CI)
- `pr-quality.yml.template` (PR validation)
- `auto-merge-deps.yml.template` (Dependabot/Renovate auto-merge)
- `pre-commit.template`

Required files in the new repo:

- `.claude-plugin/plugin.json` (Claude marketplace manifest)
- `composer.json` (from template)
- `skills/<name>/SKILL.md` (skill definition)
- `LICENSE-MIT`, `LICENSE-CC-BY-SA-4.0` (from templates)
- `README.md` (from template)
- `AGENTS.md` (agent-harness convention)
- `.gitignore`
- One initial `skills/<name>/references/*.md` covering the friction pattern
- One initial entry in `skills/<name>/evals/evals.json` covering the friction (TDD)
- Optionally `skills/<name>/checkpoints.yaml` (start with structural checkpoints)
- `.github/workflows/release.yml` (from template)
- `.github/workflows/validate.yml` (from template — required so skill validation runs in CI, not just pre-commit)

Run `bash skills/skill-repo/scripts/validate-skill.sh <new-repo-path>` to confirm the scaffold passes structural validation.

Marketplace listing is a separate manual step (out of scope for this contract).

## See also

- [retro-skill destination-taxonomy](https://github.com/netresearch/retro-skill/blob/main/references/destination-taxonomy.md) — Six destinations
- [retro-skill patch-workflow](https://github.com/netresearch/retro-skill/blob/main/references/patch-workflow.md) — Workflow on the retro-skill side
- [retro-skill eval-integration](https://github.com/netresearch/retro-skill/blob/main/references/eval-integration.md) — How retro reads evals when proposing skill-update
- `skills/skill-repo/templates/` — Scaffolding templates
- `skills/skill-repo/scripts/validate-evals.sh` — Eval validator
- `skills/skill-repo/scripts/validate-skill.sh` — Structure validator
- User memory: `feedback_preserve-commit-signing`, `feedback_merge-strategy`, `feedback_no-version-bumps-in-feature-prs`
