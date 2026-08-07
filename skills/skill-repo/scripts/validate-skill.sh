#!/usr/bin/env bash
# validate-skill.sh - Validate Netresearch skill repository structure
# Usage: ./validate-skill.sh [repo-root-path]
#
# Checks: SKILL.md frontmatter, word count, composer.json, plugin.json,
#          cross-file consistency, required files
# Env:    STRICT_README=1 (also true/yes, case-insensitive) promotes README heading misses from warnings to errors
# Exit: 0 = valid, 1 = errors found

set -euo pipefail

REPO_DIR="${1:-.}"
ERRORS=0
WARNINGS=0
NAME=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1"; ((ERRORS++)) || true; }
warning() { echo -e "${YELLOW}WARNING:${NC} $1"; ((WARNINGS++)) || true; }
success() { echo -e "${GREEN}OK:${NC} $1"; }

# Check python3 availability (required for JSON parsing)
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}ERROR:${NC} python3 is required for JSON parsing but not found in PATH"
    exit 1
fi

echo "Validating skill repository: $REPO_DIR"
echo "========================================"

# --- Discover SKILL.md ---
SKILL_FILE=""
if [[ -f "$REPO_DIR/SKILL.md" ]]; then
    SKILL_FILE="$REPO_DIR/SKILL.md"
else
    for f in "$REPO_DIR"/skills/*/SKILL.md; do
        if [[ -f "$f" ]]; then
            SKILL_FILE="$f"
            break
        fi
    done
fi

# --- SKILL.md checks ---
if [[ -n "$SKILL_FILE" ]]; then
    success "SKILL.md found: ${SKILL_FILE#"$REPO_DIR"/}"

    # Frontmatter delimiter
    if head -1 "$SKILL_FILE" | grep -q "^---$"; then
        # Verify closing --- delimiter exists (within first 30 lines)
        CLOSING_LINE=$(sed -n '2,30{/^---$/=}' "$SKILL_FILE" | head -1)
        if [[ -z "$CLOSING_LINE" ]]; then
            error "SKILL.md frontmatter has opening --- but no closing --- delimiter"
        else
            success "SKILL.md has frontmatter"
        fi

        # Extract frontmatter fields (between first two --- lines)
        FRONTMATTER=$(sed -n '2,/^---$/{ /^---$/d; p; }' "$SKILL_FILE")

        # Check frontmatter fields match Agent Skills spec
        # Allowed: name, description, license, compatibility, metadata, allowed-tools
        EXTRA_FIELDS=$(echo "$FRONTMATTER" | grep -E "^[a-z_-]+:" | grep -vE "^(name|description|license|compatibility|metadata|allowed-tools):" || true)
        if [[ -z "$EXTRA_FIELDS" ]]; then
            success "Frontmatter fields are valid per Agent Skills spec"
        else
            FIELD_NAMES=$(echo "$EXTRA_FIELDS" | sed 's/:.*//' | tr '\n' ', ' | sed 's/,$//')
            error "Frontmatter has non-spec fields: $FIELD_NAMES (allowed: name, description, license, compatibility, metadata, allowed-tools)"
        fi

        # Check name field
        if echo "$FRONTMATTER" | grep -q "^name:"; then
            NAME=$(echo "$FRONTMATTER" | grep "^name:" | head -1 | sed 's/name: *//' | tr -d '"')
            if [[ "$NAME" =~ ^[a-z0-9-]{1,64}$ ]]; then
                success "SKILL.md name valid: $NAME"
            else
                error "SKILL.md name invalid (lowercase, hyphens, max 64): $NAME"
            fi
        else
            error "SKILL.md missing 'name' field"
        fi

        # Check description field and prefix
        if echo "$FRONTMATTER" | grep -q "^description:"; then
            # Parse the *YAML value* of description so every valid scalar style
            # (plain, single/double-quoted, block) is accepted as long as the
            # parsed value starts with "Use when". Uses PyYAML when available,
            # otherwise a stdlib-only fallback covering the common scalar styles,
            # so the script keeps running with just python3 (no yq/PyYAML needed).
            # When PyYAML is present it is authoritative: invalid YAML is
            # reported (sentinel __PARSE_ERROR__), not silently re-parsed by the
            # fallback. The stdlib-only fallback runs solely when PyYAML is
            # absent, so the script still works with just python3.
            DESC=$(FRONTMATTER="$FRONTMATTER" python3 <<'PYEOF' 2>/dev/null || echo "__PARSE_ERROR__"
import os, re, sys

fm = os.environ["FRONTMATTER"]

try:
    import yaml
except Exception:
    yaml = None

if yaml is not None:
    # PyYAML available: trust it fully so semantics match CI exactly.
    try:
        data = yaml.safe_load(fm)
    except Exception:
        print("__PARSE_ERROR__")
        sys.exit(0)
    desc = data.get("description") if isinstance(data, dict) else None
    print(desc if desc is not None else "")
    sys.exit(0)

# Fallback without PyYAML: best-effort for the common scalar styles
# (plain, single/double-quoted, block). description: is a column-0 key.
desc = None
lines = fm.splitlines()
for i, line in enumerate(lines):
    m = re.match(r"description:[ \t]*(.*)$", line)
    if not m:
        continue
    val = m.group(1).strip()
    if val[:1] in ("|", ">"):
        # Block scalar: first non-blank line that is indented into the block.
        # A column-0 (non-indented) line is the next sibling key -> empty body.
        for nxt in lines[i + 1:]:
            if not nxt.strip():
                continue
            if not nxt[:1].isspace():
                break
            desc = nxt.strip()
            break
    else:
        dq = re.match(r'"((?:[^"\\]|\\.)*)"[ \t]*(?:#.*)?$', val)
        sq = re.match(r"'((?:[^']|'')*)'[ \t]*(?:#.*)?$", val)
        if dq:
            desc = dq.group(1)
        elif sq:
            desc = sq.group(1).replace("''", "'")
        else:
            # Plain scalar: strip a trailing ' #' comment (YAML needs the space).
            desc = re.sub(r"[ \t]+#.*$", "", val)
    break

print(desc if desc is not None else "")
PYEOF
)
            if [[ "$DESC" == "__PARSE_ERROR__" ]]; then
                error "SKILL.md frontmatter is not valid YAML (could not parse 'description')"
            elif [[ "$DESC" == Use\ when* ]]; then
                success "Description starts with 'Use when'"
            else
                error "Description must start with 'Use when': ${DESC:0:60}..."
            fi
        else
            error "SKILL.md missing 'description' field"
        fi
    else
        error "SKILL.md missing frontmatter (must start with ---)"
    fi

    # Word count check (max 500)
    WORDS=$(wc -w < "$SKILL_FILE")
    if [[ $WORDS -le 500 ]]; then
        success "SKILL.md is $WORDS words (under 500 limit)"
    else
        error "SKILL.md is $WORDS words (max 500)"
    fi
    # Check for relative script paths that should use ${CLAUDE_SKILL_DIR}
    # Matches: uv run scripts/, python3 scripts/, python scripts/, bash scripts/, ./scripts/, sh scripts/
    # But ignores lines already using ${CLAUDE_SKILL_DIR}
    RELATIVE_PATHS=$(grep -nE '(uv run|python3?|bash|sh|\./)([ ]+)scripts/' "$SKILL_FILE" | grep -v 'CLAUDE_SKILL_DIR' || true)
    if [[ -n "$RELATIVE_PATHS" ]]; then
        COUNT=$(echo "$RELATIVE_PATHS" | wc -l)
        warning "SKILL.md has $COUNT script reference(s) using relative paths instead of \${CLAUDE_SKILL_DIR}/scripts/"
    fi

    # checkpoints.yaml presence (warning only — many skills legitimately lack
    # one; a documented justification marker suppresses the warning per
    # add-checkpoints' suitability criteria, e.g. purely conceptual skills)
    SKILL_DIR="$(dirname "$SKILL_FILE")"
    SKILL_DIR_REL="${SKILL_DIR#"$REPO_DIR"}"
    SKILL_DIR_REL="${SKILL_DIR_REL#/}"
    SKILL_DIR_REL="${SKILL_DIR_REL:-.}"
    CHECKPOINTS_JUSTIFIED=0
    for f in "$SKILL_FILE" "$REPO_DIR/README.md"; do
        if [[ -f "$f" ]] && grep -qiE "^[[:space:]]*([*-][[:space:]]+)?checkpoints:[[:space:]]*none[[:space:]]*\(justified" "$f"; then
            CHECKPOINTS_JUSTIFIED=1
            break
        fi
    done
    if [[ -f "$SKILL_DIR/checkpoints.yaml" ]]; then
        success "checkpoints.yaml exists"
    elif [[ $CHECKPOINTS_JUSTIFIED -eq 1 ]]; then
        success "checkpoints.yaml absence is justified"
    else
        warning "checkpoints.yaml not found in ${SKILL_DIR_REL} — add checkpoints (see add-checkpoints skill) or document opt-out with 'Checkpoints: none (justified — <reason>)' in SKILL.md or README.md"
    fi
else
    error "SKILL.md not found (checked root and skills/*/)"
fi

# --- Required files ---
for file in README.md LICENSE-MIT LICENSE-CC-BY-SA-4.0 .gitignore; do
    if [[ -f "$REPO_DIR/$file" ]]; then
        success "$file exists"
    else
        error "$file not found"
    fi
done

# Warn about old single LICENSE file
if [[ -f "$REPO_DIR/LICENSE" ]] && [[ -f "$REPO_DIR/LICENSE-MIT" ]]; then
    warning "Old LICENSE file still exists alongside LICENSE-MIT — remove it"
elif [[ -f "$REPO_DIR/LICENSE" ]] && [[ ! -f "$REPO_DIR/LICENSE-MIT" ]]; then
    warning "Single LICENSE file found — migrate to LICENSE-MIT + LICENSE-CC-BY-SA-4.0"
fi

# Release workflow
if [[ -f "$REPO_DIR/.github/workflows/release.yml" ]]; then
    success "release.yml exists"
else
    error ".github/workflows/release.yml not found"
fi

# No composer.lock
if [[ -f "$REPO_DIR/composer.lock" ]]; then
    error "composer.lock must not exist in skill repos"
else
    success "No composer.lock"
fi

# --- composer.json checks ---
if [[ -f "$REPO_DIR/composer.json" ]]; then
    success "composer.json exists"

    # Type
    if grep -q '"type".*"ai-agent-skill"' "$REPO_DIR/composer.json"; then
        success "composer.json type is ai-agent-skill"
    else
        error "composer.json type must be 'ai-agent-skill'"
    fi

    # License SPDX expression
    COMP_LICENSE=$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(f'{sys.argv[1]}/composer.json', 'r') as f:
    print(json.load(f).get('license', ''))
PYEOF
)
    if [[ "$COMP_LICENSE" == "(MIT AND CC-BY-SA-4.0)" ]]; then
        success "composer.json license is correct SPDX expression"
    else
        warning "composer.json license should be '(MIT AND CC-BY-SA-4.0)', got: $COMP_LICENSE"
    fi

    # Name must match GitHub repo name (netresearch/{repo-name})
    COMP_NAME=$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(f'{sys.argv[1]}/composer.json', 'r') as f:
    print(json.load(f).get('name', ''))
PYEOF
)
    REPO_NAME=""
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        REPO_NAME="${GITHUB_REPOSITORY#*/}"
    elif git -C "$REPO_DIR" remote get-url origin &>/dev/null; then
        REMOTE_URL=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)
        REPO_NAME=$(basename "$REMOTE_URL" .git)
    fi
    if [[ -n "$REPO_NAME" ]]; then
        EXPECTED_NAME="netresearch/$REPO_NAME"
        if [[ "$COMP_NAME" == "$EXPECTED_NAME" ]]; then
            success "composer.json name matches repo: $COMP_NAME"
        else
            error "composer.json name must match repo name: expected '$EXPECTED_NAME', got '$COMP_NAME'"
        fi
    elif [[ "$COMP_NAME" =~ ^netresearch/.*-skill$ ]]; then
        success "composer.json name: $COMP_NAME (repo name check skipped - no git remote)"
    else
        error "composer.json name must match netresearch/{repo-name}: $COMP_NAME"
    fi

    # Plugin dependency
    if grep -q "composer-agent-skill-plugin" "$REPO_DIR/composer.json"; then
        success "composer.json requires skill plugin"
    else
        warning "composer.json should require netresearch/composer-agent-skill-plugin"
    fi

    # ai-agent-skill extra path(s) exist (supports both string and array values)
    SKILL_PATH_ERRORS=$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null || echo "ERROR"
import json, os, sys
repo_dir = sys.argv[1]
data = json.load(open(os.path.join(repo_dir, 'composer.json')))
val = data.get('extra', {}).get('ai-agent-skill', '')
paths = val if isinstance(val, list) else [val] if val else []
if not paths:
    print('MISSING')
else:
    for p in paths:
        if not os.path.isfile(os.path.join(repo_dir, p)):
            print('NOTFOUND:' + p)
        else:
            print('OK:' + p)
PYEOF
)
    if [[ "$SKILL_PATH_ERRORS" == "MISSING" ]]; then
        error "composer.json missing extra.ai-agent-skill"
    elif [[ "$SKILL_PATH_ERRORS" == "ERROR" ]]; then
        error "composer.json extra.ai-agent-skill could not be parsed"
    else
        while IFS= read -r line; do
            case "$line" in
                OK:*) success "composer.json skill path exists: ${line#OK:}" ;;
                NOTFOUND:*) error "composer.json skill path missing: ${line#NOTFOUND:}" ;;
            esac
        done <<< "$SKILL_PATH_ERRORS"
    fi
else
    error "composer.json not found"
fi

# --- plugin.json checks ---
PLUGIN_FILE="$REPO_DIR/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_FILE" ]]; then
    success "plugin.json exists"

    # Name matches SKILL.md name (only for single-skill repos)
    PLUGIN_NAME=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(sys.argv[1], 'r') as f:
    print(json.load(f).get('name', ''))
PYEOF
)
    SKILL_COUNT=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo "1"
import json, sys
with open(sys.argv[1], 'r') as f:
    print(len(json.load(f).get('skills', [])))
PYEOF
)
    if [[ "$SKILL_COUNT" -le 1 ]]; then
        if [[ -n "$NAME" ]] && [[ "$PLUGIN_NAME" == "$NAME" ]]; then
            success "plugin.json name matches SKILL.md: $PLUGIN_NAME"
        elif [[ -n "$NAME" ]]; then
            error "plugin.json name '$PLUGIN_NAME' does not match SKILL.md name '$NAME'"
        fi
    else
        success "plugin.json is multi-skill ($SKILL_COUNT skills), name check skipped"
    fi

    # Skills is array
    SKILLS_TYPE=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo "unknown"
import json, sys
with open(sys.argv[1], 'r') as f:
    s = json.load(f).get('skills')
print('array' if isinstance(s, list) else type(s).__name__)
PYEOF
)
    if [[ "$SKILLS_TYPE" == "array" ]]; then
        success "plugin.json skills is array"

        # Check each skill path exists as directory
        MISSING_PATHS=$(python3 - "$PLUGIN_FILE" "$REPO_DIR" <<'PYEOF' 2>/dev/null || true
import json, os, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
for path in data.get('skills', []):
    full = os.path.join(sys.argv[2], path)
    if not os.path.isdir(full):
        print(path)
PYEOF
)
        if [[ -z "$MISSING_PATHS" ]]; then
            success "All plugin.json skill paths exist"
        else
            while IFS= read -r p; do
                error "plugin.json skill path missing: $p"
            done <<< "$MISSING_PATHS"
        fi
    else
        error "plugin.json skills must be an array (got: $SKILLS_TYPE)"
    fi

    # Author URL
    AUTHOR_URL=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(sys.argv[1], 'r') as f:
    print(json.load(f).get('author', {}).get('url', ''))
PYEOF
)
    if [[ -z "$AUTHOR_URL" ]]; then
        error "plugin.json author.url is missing or empty; it must be https://www.netresearch.de"
    else
        AUTHOR_URL_CLEAN="${AUTHOR_URL%/}"
        if [[ "$AUTHOR_URL_CLEAN" == "https://www.netresearch.de" ]]; then
            success "plugin.json author.url is correct"
        else
            error "plugin.json author.url must be https://www.netresearch.de (got: $AUTHOR_URL)"
        fi
    fi
else
    error ".claude-plugin/plugin.json not found"
fi

# --- Portable manifest checks (Agent Plugins 1.0.0) ---
# Root ./plugin.json is the portable manifest every Agent Plugins client reads.
# It is the source of truth for shared metadata; .claude-plugin/plugin.json is
# generated from it by sync-plugin-manifest.sh. Its absence is an error: the
# fleet finished adopting it on 2026-08-07, so a repo without one is a new gap,
# not a repo still waiting its turn.
PORTABLE_FILE="$REPO_DIR/plugin.json"
if [[ -f "$PORTABLE_FILE" ]]; then
    PORTABLE_REPORT=$(python3 - "$PORTABLE_FILE" "$PLUGIN_FILE" "$REPO_DIR" <<'PYEOF' 2>&1 || true
import json
import os
import re
import sys

portable_path, claude_path, repo_dir = sys.argv[1], sys.argv[2], sys.argv[3]

SCHEMA_URL = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
# Closed schema: agent-plugins.org/schemas/1.0.0/plugin.schema.json
ALLOWED = ["$schema", "name", "version", "description", "author",
           "homepage", "repository", "license", "keywords", "extensions"]
SHARED = ["name", "version", "description", "author",
          "homepage", "repository", "license", "keywords"]
NAME_RE = re.compile(r"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")

out = []


def err(msg):
    out.append("ERROR:" + msg)


def ok(msg):
    out.append("OK:" + msg)


try:
    with open(portable_path, encoding="utf-8") as fh:
        data = json.load(fh)
except ValueError as exc:
    err(f"plugin.json is not valid JSON: {exc}")
    data = None
except OSError as exc:
    err(f"plugin.json could not be read: {exc}")
    data = None

if isinstance(data, dict):
    ok("plugin.json (portable Agent Plugins manifest) exists")

    if data.get("$schema") != SCHEMA_URL:
        err(f'plugin.json $schema must be "{SCHEMA_URL}" (got: {data.get("$schema")!r})')
    else:
        ok("plugin.json targets Agent Plugins 1.0.0")

    name = data.get("name")
    if not isinstance(name, str) or not name:
        err("plugin.json is missing the required 'name' field")
    elif len(name) > 64 or not NAME_RE.match(name):
        err(f"plugin.json name is invalid: {name!r} "
            "(1-64 chars, lowercase a-z0-9 . -, must start and end alphanumeric, no -- or ..)")
    else:
        ok(f"plugin.json name valid: {name}")

    unknown = [k for k in data if k not in ALLOWED]
    if unknown:
        err("plugin.json has fields outside the Agent Plugins schema: "
            + ", ".join(sorted(unknown))
            + " (client-specific data belongs in 'extensions' or in .claude-plugin/plugin.json)")
    else:
        ok("plugin.json has no fields outside the Agent Plugins schema")

    for key in ("version", "description", "homepage", "repository", "license"):
        if key in data and not isinstance(data[key], str):
            err(f"plugin.json {key} must be a string")
    if "keywords" in data and (not isinstance(data["keywords"], list)
                               or not all(isinstance(k, str) for k in data["keywords"])):
        err("plugin.json keywords must be an array of strings")
    if "author" in data:
        author = data["author"]
        if not isinstance(author, dict):
            err("plugin.json author must be an object with name/email/url")
        else:
            extra = [k for k in author if k not in ("name", "email", "url")]
            if extra:
                err("plugin.json author allows only name, email, url — got: "
                    + ", ".join(sorted(extra)))
            for k, v in author.items():
                if not isinstance(v, str):
                    err(f"plugin.json author.{k} must be a string")
    if "extensions" in data:
        ext = data["extensions"]
        if not isinstance(ext, dict) or not all(isinstance(v, dict) for v in ext.values()):
            err("plugin.json extensions must be an object of reverse-domain "
                "namespace keys mapping to objects")

    # Parity with the generated Claude Code manifest.
    if os.path.isfile(claude_path):
        try:
            with open(claude_path, encoding="utf-8") as fh:
                claude = json.load(fh)
        except (OSError, ValueError):
            claude = None
        if isinstance(claude, dict):
            drift = [k for k in SHARED if k in data and claude.get(k) != data[k]]
            if drift:
                err(".claude-plugin/plugin.json is out of sync with plugin.json on: "
                    + ", ".join(drift)
                    + " — run skills/skill-repo/scripts/sync-plugin-manifest.sh")
            else:
                ok(".claude-plugin/plugin.json is in sync with plugin.json")

    # Agent Plugins clients discover skills only under skills/<name>/SKILL.md.
    skills_dir = os.path.join(repo_dir, "skills")
    found = []
    if os.path.isdir(skills_dir):
        found = sorted(d for d in os.listdir(skills_dir)
                       if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md")))
    if found:
        ok(f"skills/ holds {len(found)} portable skill(s): " + ", ".join(found))
    else:
        err("no skills/<name>/SKILL.md found — Agent Plugins clients do not "
            "discover a SKILL.md at the repository root")

print("\n".join(out))
PYEOF
)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            OK:*) success "${line#OK:}" ;;
            ERROR:*) error "${line#ERROR:}" ;;
            *) error "portable manifest check produced unexpected output: $line" ;;
        esac
    done <<< "$PORTABLE_REPORT"
else
    error "plugin.json (portable Agent Plugins 1.0.0 manifest) not found at repo root — Agent Plugins clients (Cursor, Copilot, …) cannot load this plugin; see skill-repo skills/skill-repo/references/agent-plugins-compat.md"
fi

# --- README.md quality checks (warnings by default) ---
# Heading misses are warnings unless STRICT_README=1 promotes them to errors.
# The default must stay warnings-only: consumer repos run this script from
# main via the reusable validate.yml, so flipping the default would break
# their CI. Opt in per repo (or org-wide, later) by exporting STRICT_README=1.
readme_heading_miss() { case "${STRICT_README:-0}" in 1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) error "$1" ;; *) warning "$1" ;; esac; }

# Required level-2 headings (whole-line match) per skills/skill-repo/references/readme-template.md
README_REQUIRED_HEADINGS=(
    "What this skill solves"
    "Why this is a skill (model delta)"
    "Use when"
    "Expected outputs"
    "Context requirements"
    "Example prompts"
    "Related skills"
    "Installation"
    "Contributing"
    "License"
)

if [[ -f "$REPO_DIR/README.md" ]]; then
    if grep -q "Netresearch" "$REPO_DIR/README.md"; then
        success "README.md contains Netresearch reference"
    else
        warning "README.md should contain Netresearch credits"
    fi

    for heading in "${README_REQUIRED_HEADINGS[@]}"; do
        # Whole-line match only (avoids substring hits inside ### headings or prose)
        if grep -Fxq "## ${heading}" "$REPO_DIR/README.md"; then
            success "README.md has ## ${heading}"
        else
            readme_heading_miss "README.md missing section (exact line ## ${heading}) — see skill-repo-skill skills/skill-repo/references/readme-template.md"
        fi
    done

    # Every documented slash-command should be enumerated in the README so the
    # command (and mode) list does not silently drift when one is added. Warning
    # only: the name match is heuristic and a skill may intentionally omit one.
    if [[ -d "$REPO_DIR/commands" ]]; then
        for cmd_file in "$REPO_DIR"/commands/*.md; do
            [[ -e "$cmd_file" ]] || continue
            cmd_name="$(basename "$cmd_file" .md)"
            # -F: match the command name literally (a filename with regex
            # metacharacters can't break or mis-match). -w: require word
            # boundaries, so `/work-update` does not match inside
            # `commands/work-update.md` or a URL like `netresearch/work-update`.
            if grep -qFw -- "/${cmd_name}" "$REPO_DIR/README.md"; then
                success "README.md references /${cmd_name}"
            else
                warning "README.md does not mention command /${cmd_name} (commands/${cmd_name}.md) — keep the README command/mode list in sync when adding commands or modes"
            fi
        done
    fi
fi

# --- Summary ---
echo ""
echo "========================================"
echo "Validation Summary"
echo "========================================"
echo -e "Errors:   ${RED}$ERRORS${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}Skill repository is valid!${NC}"
    exit 0
else
    echo -e "${RED}Skill repository has $ERRORS error(s) that must be fixed.${NC}"
    exit 1
fi
