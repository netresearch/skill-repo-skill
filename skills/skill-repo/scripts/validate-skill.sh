#!/bin/bash
# validate-skill.sh - Validate Netresearch skill repository structure
# Usage: ./validate-skill.sh [repo-root-path]
#
# Checks: SKILL.md frontmatter, word count, composer.json, plugin.json,
#          cross-file consistency, required files
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
            DESC=$(echo "$FRONTMATTER" | grep "^description:" | head -1 | sed 's/description: *//' | sed 's/^"//' | sed 's/"$//')
            if [[ "$DESC" == Use\ when* ]]; then
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

# --- README.md quality checks (warnings only) ---
if [[ -f "$REPO_DIR/README.md" ]]; then
    if grep -q "Netresearch" "$REPO_DIR/README.md"; then
        success "README.md contains Netresearch reference"
    else
        warning "README.md should contain Netresearch credits"
    fi
    if grep -qi "## Installation" "$REPO_DIR/README.md"; then
        success "README.md has Installation section"
    else
        warning "README.md should have Installation section"
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
