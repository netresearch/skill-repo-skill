# Reviewer-Reply Boilerplate

Canonical responses to recurring reviewer comments on Netresearch skill PRs (Copilot, Gemini Code Assist, peer review). Lift the fenced block verbatim or paraphrase to context. Each entry includes the criteria for whether to accept or decline.

These were extracted from review patterns across 14+ skill PRs. Use them to keep responses consistent and to avoid re-litigating settled architectural decisions on every new PR.

## 1. "Set `private: true`"

**Verdict:** Accept — already the template default.

**Criteria:** Skill packages distributed via `github:org/repo` (not the npm registry) **must** set `"private": true` to guard against accidental `npm publish` of the placeholder `0.0.0-source` version. The current `package.json.template` bakes this in. If a reviewer flags it on a fresh PR, the package was scaffolded from an outdated template — accept the suggestion and add it.

```markdown
Accepted. Adding `"private": true` — current scaffolding template (`skills/skill-repo/templates/package.json.template` in `netresearch/skill-repo-skill`) bakes this in to guard against accidental publish of the `0.0.0-source` placeholder. This PR was scaffolded before the template was updated.
```

## 2. "Pin `github:org/repo#vX.Y.Z` in install instructions"

**Verdict:** Decline as primary advice. Document `#vX.Y.Z` as an opt-in for users who want reproducibility.

**Criteria:** These skills are markdown content (procedural knowledge), not executable code where pinning protects against breakage. Consumers want skill-content updates by default. Pinning is an advanced opt-in.

```markdown
Declined as primary advice. The default `github:netresearch/{repo-name}` form intentionally tracks the default branch so consumers receive skill-content updates — these skills are markdown content (procedural knowledge), not executable code where breakage matters. Pinning is an advanced use-case, not a default. Consumers can append `#vX.Y.Z` themselves for reproducibility (`github:netresearch/{repo-name}#v1.2.3`); we don't surface that in the README to keep the install path simple.
```

(Reference: this is the response we used on [skill-repo-skill PR #82](https://github.com/netresearch/skill-repo-skill/pull/82).)

## 3. "Drop `.claude-plugin/` (or `commands/`, `outputStyles/`, `AGENTS.md`) from `files`"

**Verdict:** Decline (won't-fix). This is the dual-distribution invariant.

**Criteria:** Netresearch skill packages are *dual-distributed* — the same package serves both the Claude Code marketplace install path AND the npm install path. Plugin metadata, slash commands, output styles, and `AGENTS.md` are part of the skill's installable surface, not internal repo configuration. Excluding them from the npm tarball delivers a partial skill to npm consumers.

```markdown
Declining. Netresearch skill packages are *dual-distributed* — the same tarball feeds both the Claude Code marketplace install path AND the npm install path. Plugin metadata (`.claude-plugin/plugin.json`), slash commands (`commands/`), output styles (`outputStyles/`), and the canonical `AGENTS.md` rules file are part of the skill's installable surface, not internal repo configuration.

Excluding them from the npm tarball would deliver a partial skill to npm consumers — the same partial-install problem documented in [github-release-skill PR #19](https://github.com/netresearch/github-release-skill/pull/19)'s `> **Limitation:**` callout. The current `@netresearch/agent-skill-coordinator` (v0.1.x) `node_modules` scanner can't load plugin-mechanism features; those need Claude Code's plugin loader. Shipping these directories preserves the option to switch install methods without re-installing.
```

(Reference: lifted from [skill-repo-skill PR #83](https://github.com/netresearch/skill-repo-skill/pull/83).)

## 4. "Top-level `scripts/` shouldn't ship"

**Verdict:** **Accept** if `scripts/` is repo-maintenance only. **Decline** if installed code reads from `$ROOT/scripts/` at runtime.

**Criteria:** This is the *opposite* call from #3. Top-level `scripts/` is **not** part of the dual-distribution surface unless the skill's runtime explicitly reads from it. To tell them apart:

- **Repo-maintenance** (DO accept the suggestion, remove from `files`): scripts that only run in CI or by repo maintainers — `verify-harness.sh`, `generate-dashboard.sh`, `run-ab-evals.sh`, lint runners, release helpers. Look for invocation only in `.github/workflows/` or `Makefile` / `package.json scripts`.
- **Runtime** (DO decline the suggestion, keep in `files`): scripts the *installed* skill executes, typically referenced from `skills/<name>/SKILL.md` or `skills/<name>/scripts/*.sh` via `$ROOT/scripts/...` or `../scripts/...`.

Quick check: `grep -r '\$ROOT/scripts\|\.\./scripts' skills/`. If empty, it's repo-maintenance.

```markdown
Accepted. `scripts/` at the repo root only contains `verify-harness.sh` (repo-maintenance, run via `.github/workflows/`). The installed skill code does not read from `$ROOT/scripts/` at runtime — runtime scripts live under `skills/<name>/scripts/` (already covered by the `skills/<name>/` entry). Removed from `files`. The npm-pack-smoke CI job will keep this honest going forward.
```

If declining (runtime usage):

```markdown
Declining. Top-level `scripts/` is consumed at runtime — `skills/<name>/SKILL.md` references `$ROOT/scripts/<file>.sh` for [specific feature]. Removing it from `files` would break npm consumers. The npm-pack-smoke CI job asserts this dir is present.
```

## 5. "`AGENTS.md` shouldn't ship"

**Verdict:** Decline (won't-fix). Same dual-distribution invariant as #3.

**Criteria:** `AGENTS.md` is the canonical agent rules entry point for the skill repo. npm consumers expect the same rules file marketplace consumers see — without it, agents reading the package don't get the harness contract.

```markdown
Declining. `AGENTS.md` is the canonical agent rules entry point for the skill — npm consumers must receive the same rules file that marketplace consumers do, otherwise agents reading the installed package miss the harness contract documented there. This is part of the dual-distribution surface (see [skill-repo-skill PR #83](https://github.com/netresearch/skill-repo-skill/pull/83)).
```

## See Also

- `installation-methods.md` — Method 4 (npm) for the full `files`-allowlist rationale.
- `release-discipline.md` — version-parity check, multi-repo dry-run.
- [skill-repo-skill PR #83](https://github.com/netresearch/skill-repo-skill/pull/83) — original dual-distribution decision record.
