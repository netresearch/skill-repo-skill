#!/usr/bin/env bash
#
# check-version-parity.sh — verify plugin.json, composer.json, and SKILL.md
# versions are consistent before a release.
#
# Usage:
#   check-version-parity.sh               # compare plugin.json vs SKILL.md
#   check-version-parity.sh v1.2.3        # also require plugin.json == 1.2.3
#   check-version-parity.sh 1.2.3         # same, leading v optional
#   check-version-parity.sh --repo DIR v1.2.3   # check DIR instead of cwd
#
# All paths are resolved relative to the repo root. Without --repo that root
# is the current directory, so a fleet driver iterating over many checkouts
# must pass --repo per repo rather than a bare path argument.
#
# Exit codes: 0 = parity OK, 1 = mismatch or missing version.
#
# Behavior:
#   * Reads .claude-plugin/plugin.json version (required)
#   * If SKILL.md frontmatter declares a version — metadata.version or a
#     top-level version: key — requires it matches
#   * composer.json MUST NOT have a version field (version is derived from
#     git tags by the release workflow). Composer-shipped version would
#     drift from the tag.
#   * If a tag argument is provided, requires plugin.json version == tag
#     with 'v' prefix stripped.

set -euo pipefail

REPO_DIR=""
TAG_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_DIR="${2:-}"
      [[ -n "$REPO_DIR" ]] || { echo "ERROR: --repo needs a directory" >&2; exit 1; }
      shift 2
      ;;
    --repo=*)
      REPO_DIR="${1#--repo=}"
      shift
      ;;
    -h|--help)
      sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      TAG_ARG="$1"
      shift
      ;;
  esac
done

if [[ -n "$REPO_DIR" ]]; then
  cd "$REPO_DIR" || { echo "ERROR: cannot enter $REPO_DIR" >&2; exit 1; }
fi

TAG_VERSION="${TAG_ARG#v}"  # strip leading v if present (empty stays empty)

PLUGIN_JSON=".claude-plugin/plugin.json"
PORTABLE_JSON="plugin.json"
COMPOSER_JSON="composer.json"

if [[ ! -f "$PLUGIN_JSON" ]]; then
  echo "ERROR: $PLUGIN_JSON not found in $(pwd)" >&2
  echo "       Run from the skill repo root, or pass --repo <dir>." >&2
  exit 1
fi

PLUGIN_VERSION=$(jq -r '.version // empty' "$PLUGIN_JSON")
if [[ -z "$PLUGIN_VERSION" ]]; then
  echo "ERROR: $PLUGIN_JSON has no .version field" >&2
  exit 1
fi

# Root plugin.json (Agent Plugins 1.0.0) is the source of truth for the version
# once a repo has adopted it; .claude-plugin/plugin.json is generated from it.
if [[ -f "$PORTABLE_JSON" ]]; then
  PORTABLE_VERSION=$(jq -r '.version // empty' "$PORTABLE_JSON")
  if [[ -z "$PORTABLE_VERSION" ]]; then
    echo "ERROR: $PORTABLE_JSON has no .version field" >&2
    exit 1
  fi
  if [[ "$PORTABLE_VERSION" != "$PLUGIN_VERSION" ]]; then
    echo "ERROR: $PORTABLE_JSON=$PORTABLE_VERSION does not match $PLUGIN_JSON=$PLUGIN_VERSION" >&2
    echo "       Bump the root plugin.json, then run sync-plugin-manifest.sh." >&2
    exit 1
  fi
fi

# composer.json MUST NOT have a version field
if [[ -f "$COMPOSER_JSON" ]] && jq -e 'has("version")' "$COMPOSER_JSON" > /dev/null 2>&1; then
  CJ_VERSION=$(jq -r '.version // empty' "$COMPOSER_JSON")
  echo "ERROR: $COMPOSER_JSON has a version field ($CJ_VERSION) — remove it" >&2
  echo "       Git tag is the source of truth for composer packages." >&2
  exit 1
fi

# Tag argument must match plugin.json
if [[ -n "$TAG_VERSION" && "$PLUGIN_VERSION" != "$TAG_VERSION" ]]; then
  echo "ERROR: plugin.json=$PLUGIN_VERSION does not match tag $TAG_ARG" >&2
  exit 1
fi

# SKILL.md metadata.version (if present) must match plugin.json
MISMATCH=0
shopt -s nullglob
SKILL_FILES=(skills/*/SKILL.md)
shopt -u nullglob

if [[ ${#SKILL_FILES[@]} -eq 0 ]]; then
  echo "WARN: no skills/*/SKILL.md files found" >&2
fi

for skill_md in "${SKILL_FILES[@]}"; do
  # Extract the version from YAML frontmatter: metadata.version (indented)
  # or a top-level version: key — both forms exist in the fleet.
  # Tolerate quoted or unquoted values; return empty if absent.
  SKILL_VERSION=$(awk '
    /^---$/ { fm = !fm; next }
    fm && /^[[:space:]]*version:[[:space:]]*/ {
      gsub(/^[[:space:]]*version:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$skill_md")

  if [[ -n "$SKILL_VERSION" && "$SKILL_VERSION" != "$PLUGIN_VERSION" ]]; then
    echo "ERROR: $skill_md metadata.version=$SKILL_VERSION does not match plugin.json=$PLUGIN_VERSION" >&2
    MISMATCH=1
  fi
done

if (( MISMATCH )); then
  exit 1
fi

if [[ -n "$TAG_VERSION" ]]; then
  echo "OK: plugin.json and tag match at $PLUGIN_VERSION"
else
  echo "OK: plugin.json and SKILL.md versions match at $PLUGIN_VERSION"
  echo "    (pass a tag argument like v$PLUGIN_VERSION to verify tag parity)"
fi
