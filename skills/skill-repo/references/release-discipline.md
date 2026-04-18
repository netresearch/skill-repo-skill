# Release Discipline

Every step that caused the "30 failed plugin releases" incident, codified as rules.

## Canonical Order: Bump PR Merged → Tag Pushed

**Tag a version only after the version-bump PR is merged to the default branch.** Tagging first causes the Release workflow to run against the old code, fail CI, and produce an immutable GitHub release locked to a bad tag.

```
WRONG: git tag -s v1.2.4 → git push → open bump PR
RIGHT: open bump PR → merge → pull main → git tag -s v1.2.4 → git push
```

## Pre-Release Version-Parity Check

Before pushing any tag, all version identifiers must match. This is the single check that would have prevented the 30-repo release failure.

```bash
#!/bin/bash
# scripts/check-version-parity.sh
set -euo pipefail

PLUGIN_VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
TAG_VERSION="${1:-}"  # e.g. v1.2.4 → strip the v → 1.2.4
TAG_VERSION="${TAG_VERSION#v}"

# composer.json MUST NOT have a version field (derived from git tag)
if jq -e '.version' composer.json >/dev/null 2>&1; then
  echo "ERROR: composer.json has a version field — remove it (git tag is source of truth)"
  exit 1
fi

# plugin.json version MUST match the tag
if [[ -n "$TAG_VERSION" && "$PLUGIN_VERSION" != "$TAG_VERSION" ]]; then
  echo "ERROR: plugin.json=$PLUGIN_VERSION tag=$TAG_VERSION — mismatch"
  exit 1
fi

# If SKILL.md frontmatter has metadata.version, it must match too
for skill_md in skills/*/SKILL.md; do
  SKILL_VERSION=$(awk '/^  version:/ {gsub(/"/,"",$2); print $2; exit}' "$skill_md")
  if [[ -n "$SKILL_VERSION" && "$SKILL_VERSION" != "$PLUGIN_VERSION" ]]; then
    echo "ERROR: $skill_md version=$SKILL_VERSION plugin.json=$PLUGIN_VERSION — mismatch"
    exit 1
  fi
done

echo "OK: version parity confirmed at $PLUGIN_VERSION"
```

Run before every `git push origin vX.Y.Z`.

## Cache Safety: Never Edit the Installed Copy

Installed skills and plugins live under `~/.claude/` (or wherever the marketplace resolves them). Editing these paths directly is always wrong — the next `/plugin update` or marketplace sync will silently overwrite your changes, taking any local fixes with it.

### Paths that are off-limits for edits

- `~/.claude/skills/**`
- `~/.claude/plugins/cache/**`
- `~/.claude/plugins/marketplaces/**`
- Anything inside a `.bare/` directory (git bare clone; worktree source)

### Pre-edit check

Before every Write or Edit in skill-repo workflows:

```bash
pwd_real=$(realpath .)
case "$pwd_real" in
  */.claude/skills/*|*/.claude/plugins/*|*/.bare/*)
    echo "REFUSING to edit installed/cache path: $pwd_real"
    echo "Navigate to the source worktree first."
    exit 1
    ;;
esac
```

### Recovery when edits landed in the wrong place

1. Stop. Do not run `/plugin update` or `composer update` — they may wipe your edits.
2. `diff -r ~/.claude/skills/<name>/ ~/projects/<name>-skill/main/skills/<name>/` to see what drifted.
3. Copy the legitimate changes into the source worktree.
4. Commit from the worktree; never from the cache.

## Multi-Skill-Repo Release Dry-Run

When releasing >3 skill repos in one sweep, produce this manifest and wait for user approval before executing:

```
Skill-Repo Release Plan (2026-04-18)

| Repo                        | Current | Target  | Change type | Notes                  |
|-----------------------------|---------|---------|-------------|------------------------|
| netresearch/git-workflow    | 1.9.0   | 1.10.0  | minor       | adds critical-rules    |
| netresearch/github-project  | 2.10.0  | 2.11.0  | minor       | multi-repo-operations  |
| netresearch/skill-repo      | 1.18.0  | 1.19.0  | minor       | release-discipline ref |

Preconditions (verified per repo):
  [✓] default branch CI green
  [✓] no pending version-bump PR
  [✓] version-parity check passes
  [✓] working tree clean

Execution order per repo:
  1. Create version-bump PR on feat/release-vX.Y.Z branch
  2. Wait for CI green and approval
  3. Merge via merge-commit (respects atomic-commit policy)
  4. Pull main; run check-version-parity.sh vX.Y.Z
  5. Create signed tag vX.Y.Z
  6. Push tag
  7. Monitor Release workflow to green
  8. Halt all further releases if this one fails — produce rollback

Reply "go" to proceed, or name repos to skip.
```

## Immutable-Release Caveat

Deleted GitHub releases do NOT free the tag for reuse. Once a release is published and deleted, that tag string is permanently locked as a deleted release — a new release with the same tag will fail. See `git-workflow-skill` → `references/github-releases.md`. Therefore: get it right the first time. The version-parity check above is what "right the first time" means in practice.

## Tag Signing (Mandatory)

```bash
git tag -s vX.Y.Z -m "vX.Y.Z"         # -s: sign with GPG/SSH
git push origin vX.Y.Z                # signed tag reaches the remote
```

Never `git tag vX.Y.Z` (unsigned). Repos with protected tag rulesets will reject unsigned tags.

## No `--latest` Drift for Non-Default Branches

When releasing from a non-default branch (e.g. a v1.x maintenance line while v2.x is default), pass `--latest=false` to avoid stealing the "Latest" badge by timestamp:

```bash
gh release create v1.5.12 --latest=false --title "v1.5.12" --notes-file CHANGELOG-v1.5.12.md
```

GitHub marks releases "Latest" by creation timestamp, not semver. A v1.5.12 created after v2.0.0 will become "Latest" without this flag — wrong, misleading, and often noticed only by downstream consumers.
