#!/usr/bin/env bash
#
# bump-version.sh — set the release version on every surface check-version-parity
# validates, and nothing else.
#
# Usage:
#   bump-version.sh 1.2.3                 # dry run: print the diff, write nothing
#   bump-version.sh v1.2.3 --apply        # write the files
#   bump-version.sh --repo DIR 1.2.3      # operate on DIR instead of cwd
#
# Exit codes: 0 = done (or dry run clean), 1 = refused or nothing to write.
#
# Behavior:
#   * Rewrites .claude-plugin/plugin.json .version (required, must exist)
#   * Rewrites EVERY version: line inside the YAML frontmatter of every
#     skills/*/SKILL.md — both the indented metadata.version and a top-level
#     version: key, preserving indentation and quote style.
#   * Refuses when composer.json carries a version field: the release workflow
#     derives that from the git tag, so a bumped composer version would drift.
#   * Verifies the result with check-version-parity.sh when it is present.
#
# What it deliberately does NOT do: commit, tag, or push. The release order is
# bump PR -> merge -> pull -> signed tag -> push (references/release-discipline.md).
# A helper that tags in the same breath is how an unsigned tag reaches the wild
# and how a half-bumped tree gets an immutable release; both have happened.
#
# Why every version: line and not just the first one: SKILL.md frontmatter in
# the fleet carries either form, and some carry both. A bump that rewrites only
# the indented metadata.version leaves a stale top-level version: behind, which
# the tag pipeline then rejects (it-maintenance-skill v1.10.0 died this way).

set -euo pipefail

REPO_DIR=""
VERSION=""
APPLY=0

usage() {
  echo "Usage: bump-version.sh [--repo DIR] <version> [--apply]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_DIR="${2:-}"
      [[ -n "$REPO_DIR" ]] || usage
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "ERROR: unknown option $1" >&2
      usage
      ;;
    *)
      [[ -z "$VERSION" ]] || usage
      VERSION="$1"
      shift
      ;;
  esac
done

[[ -n "$VERSION" ]] || usage
[[ -z "$REPO_DIR" ]] || cd "$REPO_DIR"

VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "ERROR: '$VERSION' is not a semantic version" >&2
  exit 1
fi

PLUGIN_JSON=".claude-plugin/plugin.json"
COMPOSER_JSON="composer.json"

if [[ ! -f "$PLUGIN_JSON" ]]; then
  echo "ERROR: $PLUGIN_JSON not found — run this from the repo root or pass --repo" >&2
  exit 1
fi
if ! jq -e 'has("version")' "$PLUGIN_JSON" > /dev/null 2>&1; then
  echo "ERROR: $PLUGIN_JSON has no .version field" >&2
  exit 1
fi

# Mirror the parity check: composer.json must not carry a version at all, so
# refuse rather than bump it into existence.
if [[ -f "$COMPOSER_JSON" ]] && jq -e 'has("version")' "$COMPOSER_JSON" > /dev/null 2>&1; then
  echo "ERROR: $COMPOSER_JSON has a version field — remove it first" >&2
  echo "       Git tag is the source of truth for composer packages." >&2
  exit 1
fi

OLD_PLUGIN_VERSION=$(jq -r '.version' "$PLUGIN_JSON")
CHANGES=0

report() { # path old new
  printf '  %-46s %s -> %s\n' "$1" "$2" "$3"
}

if [[ "$OLD_PLUGIN_VERSION" != "$VERSION" ]]; then
  report "$PLUGIN_JSON" "$OLD_PLUGIN_VERSION" "$VERSION"
  CHANGES=1
  if (( APPLY )); then
    tmp=$(mktemp)
    # jq already terminates its output with a single newline; adding one here
    # produces a blank line at EOF that the end-of-file hook then strips back.
    jq --arg v "$VERSION" '.version = $v' "$PLUGIN_JSON" > "$tmp"
    mv "$tmp" "$PLUGIN_JSON"
  fi
fi

shopt -s nullglob
SKILL_FILES=(skills/*/SKILL.md)
shopt -u nullglob

if [[ ${#SKILL_FILES[@]} -eq 0 ]]; then
  echo "WARN: no skills/*/SKILL.md files found" >&2
fi

for skill_md in "${SKILL_FILES[@]}"; do
  # Every version: line inside the frontmatter block, both forms, indentation
  # and quote style preserved. Frontmatter only: a version: in the body stays.
  before=$(awk '
    /^---$/ { fm = !fm; next }
    fm && /^[[:space:]]*version:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*version:[[:space:]]*/, "", line)
      gsub(/["\047]/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
    }
  ' "$skill_md" | sort -u | paste -sd, -)

  [[ -n "$before" ]] || continue
  [[ "$before" != "$VERSION" ]] || continue

  report "$skill_md" "$before" "$VERSION"
  CHANGES=1

  if (( APPLY )); then
    tmp=$(mktemp)
    awk -v ver="$VERSION" '
      /^---$/ { fm = !fm; print; next }
      fm && match($0, /^[[:space:]]*version:[[:space:]]*/) {
        indent = substr($0, 1, RLENGTH)
        rest = substr($0, RLENGTH + 1)
        # keep the original quoting: "x", '"'"'x'"'"' or bare
        q = ""
        if (rest ~ /^"/) q = "\""
        else if (rest ~ /^\047/) q = "\047"
        print indent q ver q
        next
      }
      { print }
    ' "$skill_md" > "$tmp"
    mv "$tmp" "$skill_md"
  fi
done

if (( ! CHANGES )); then
  echo "Nothing to do: every version surface is already at $VERSION"
  exit 0
fi

if (( ! APPLY )); then
  echo
  echo "Dry run — nothing written. Re-run with --apply."
  exit 0
fi

PARITY="$(dirname "${BASH_SOURCE[0]}")/check-version-parity.sh"
if [[ -x "$PARITY" ]]; then
  echo
  "$PARITY" "$VERSION"
fi

cat <<EOF

Files written. Nothing was committed, tagged or pushed — on purpose.

Next (references/release-discipline.md):
  1. commit the bump and open a PR
  2. merge it, then pull the default branch
  3. git tag -s -m "v$VERSION" "v$VERSION" && git push origin "v$VERSION"

Tagging before the bump PR is merged releases the old code.
EOF
