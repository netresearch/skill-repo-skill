#!/usr/bin/env bash
#
# sync-plugin-manifest.sh — project the portable Agent Plugins manifest
# (./plugin.json) into the Claude Code manifest (.claude-plugin/plugin.json).
#
# Usage:
#   sync-plugin-manifest.sh                 # write .claude-plugin/plugin.json
#   sync-plugin-manifest.sh --check         # verify it is in sync, write nothing
#   sync-plugin-manifest.sh --repo DIR ...  # operate on DIR instead of cwd
#
# Root ./plugin.json is the source of truth for the shared metadata: name,
# version, description, author, homepage, repository, license, keywords.
# .claude-plugin/plugin.json is generated from it and keeps its Claude-only
# keys (skills, agents, commands, outputStyles, hooks, mcpServers, metadata,
# support, …) untouched — those fields have no place in the portable manifest,
# whose schema is closed.
#
# Exit codes: 0 = written / in sync (or no portable manifest to sync from),
#             1 = out of sync (--check) or invalid input.

set -euo pipefail

REPO_DIR="."
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --repo)
      REPO_DIR="${2:-}"
      [[ -n "$REPO_DIR" ]] || { echo "ERROR: --repo needs a directory" >&2; exit 1; }
      shift 2
      ;;
    --repo=*) REPO_DIR="${1#--repo=}"; shift ;;
    -h|--help)
      grep -E '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

PORTABLE="$REPO_DIR/plugin.json"
CLAUDE="$REPO_DIR/.claude-plugin/plugin.json"

if [[ ! -f "$PORTABLE" ]]; then
  echo "SKIP: $PORTABLE not found — nothing to sync from"
  exit 0
fi

CHECK="$CHECK" PORTABLE="$PORTABLE" CLAUDE="$CLAUDE" python3 <<'PYEOF'
import json
import os
import sys

check = os.environ["CHECK"] == "1"
portable_path = os.environ["PORTABLE"]
claude_path = os.environ["CLAUDE"]

# Shared metadata, in the order the generated manifest lists it.
SHARED = ["name", "version", "description", "author",
          "homepage", "repository", "license", "keywords"]

try:
    with open(portable_path, encoding="utf-8") as fh:
        portable = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"ERROR: cannot read {portable_path}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(portable, dict):
    print(f"ERROR: {portable_path} must contain a JSON object", file=sys.stderr)
    sys.exit(1)

current = {}
if os.path.isfile(claude_path):
    try:
        with open(claude_path, encoding="utf-8") as fh:
            current = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"ERROR: cannot read {claude_path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(current, dict):
        print(f"ERROR: {claude_path} must contain a JSON object", file=sys.stderr)
        sys.exit(1)

generated = {}
for key in SHARED:
    if key in portable:
        generated[key] = portable[key]

# Claude-only keys survive: everything the portable manifest does not own.
# `$schema` and `extensions` are portable-manifest concerns and never copied.
for key, value in current.items():
    if key in SHARED or key in ("$schema", "extensions"):
        continue
    generated[key] = value

rendered = json.dumps(generated, indent=2, ensure_ascii=False) + "\n"

if check:
    # Value parity, not byte identity: key order and formatting in the Claude
    # manifest are nobody's business, drift in the shared metadata is.
    drift = [k for k in SHARED if portable.get(k) != current.get(k)]
    if not drift:
        print(f"OK: {claude_path} is in sync with {portable_path}")
        sys.exit(0)
    print(f"ERROR: {claude_path} is out of sync with {portable_path}", file=sys.stderr)
    print("       Run: bash skills/skill-repo/scripts/sync-plugin-manifest.sh", file=sys.stderr)
    for key in drift:
        print(f"       {key}: portable={portable.get(key)!r} claude={current.get(key)!r}",
              file=sys.stderr)
    sys.exit(1)

try:
    with open(claude_path, encoding="utf-8") as fh:
        on_disk = fh.read()
except OSError:
    on_disk = None

if on_disk == rendered:
    print(f"OK: {claude_path} is in sync with {portable_path}")
    sys.exit(0)

os.makedirs(os.path.dirname(claude_path) or ".", exist_ok=True)
with open(claude_path, "w", encoding="utf-8") as fh:
    fh.write(rendered)
print(f"WROTE: {claude_path}")
PYEOF
