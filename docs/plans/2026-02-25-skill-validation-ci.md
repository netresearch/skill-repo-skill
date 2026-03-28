# Skill Validation CI Implementation Plan

> Implementation note: This plan is intended to be executed step by step as written.

**Goal:** Automate detection of all skill repo issues we fixed manually (frontmatter, composer.json, plugin.json, file presence) via CI and pre-commit hook.

**Architecture:** Enhanced `validate-skill.sh` in skill-repo-skill performs all checks. A reusable GitHub workflow (`validate.yml`) in skill-repo-skill calls this script. Each of the 26 skill repos adds one line to their `lint.yml` to call the reusable workflow. A pre-commit hook runs the same script locally.

**Tech Stack:** Bash (validate-skill.sh), GitHub Actions (reusable workflow), Python3 (JSON parsing in script), Git hooks

---

### Task 1: Write Enhanced validate-skill.sh

**Files:**
- Modify: `skills/skill-repo/scripts/validate-skill.sh`

**Step 1: Read the current script to understand the baseline**

The current script (158 lines) checks: SKILL.md exists, frontmatter delimiter, name pattern, description exists, line count, README.md, LICENSE, composer.lock absence, composer.json type/plugin/extra, directory existence.

Missing checks that must be added:
- SKILL.md: only `name` + `description` allowed in frontmatter
- SKILL.md: word count < 500
- SKILL.md: description starts with "Use when"
- composer.json: `extra.ai-agent-skill` path exists as file
- composer.json: name follows `netresearch/agent-*` pattern
- plugin.json: exists at `.claude-plugin/plugin.json`
- plugin.json: name matches SKILL.md name
- plugin.json: `skills` is array
- plugin.json: skill paths point to existing directories
- plugin.json: `author.url` is `https://www.netresearch.de`
- .gitignore exists
- .github/workflows/release.yml exists

**Step 2: Write the enhanced script**

Replace the entire validate-skill.sh with the enhanced version below. The script validates at the **repo root** (not a subdirectory), because it needs cross-file checks (composer.json ↔ plugin.json ↔ SKILL.md).

Key design decisions:
- The script auto-discovers SKILL.md location (root or `skills/*/SKILL.md`)
- Uses Python3 for JSON parsing (available on ubuntu-latest and most dev machines)
- Exit code 0 = pass, 1 = errors found
- Warnings don't cause failure (e.g., missing Installation section in README)
- All checks from the session are errors (not warnings) to enforce compliance

```bash
#!/bin/bash
# validate-skill.sh - Validate Netresearch skill repository structure
# Usage: ./validate-skill.sh [repo-root-path]
# Checks: SKILL.md frontmatter, composer.json, plugin.json, file presence
# Exit: 0 = valid, 1 = errors found

set -euo pipefail

REPO_DIR="${1:-.}"
ERRORS=0
WARNINGS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1"; ((ERRORS++)); }
warning() { echo -e "${YELLOW}WARNING:${NC} $1"; ((WARNINGS++)); }
success() { echo -e "${GREEN}OK:${NC} $1"; }

echo "Validating skill repository: $REPO_DIR"
echo "========================================"

# --- Discover SKILL.md ---
SKILL_FILE=""
if [[ -f "$REPO_DIR/SKILL.md" ]]; then
    SKILL_FILE="$REPO_DIR/SKILL.md"
else
    # Look in skills/*/ subdirectories
    for f in "$REPO_DIR"/skills/*/SKILL.md; do
        if [[ -f "$f" ]]; then
            SKILL_FILE="$f"
            break
        fi
    done
fi

# --- SKILL.md checks ---
if [[ -n "$SKILL_FILE" ]]; then
    success "SKILL.md found: $SKILL_FILE"

    # Frontmatter delimiter
    if head -1 "$SKILL_FILE" | grep -q "^---$"; then
        success "SKILL.md has frontmatter"

        # Extract frontmatter (between first two --- lines)
        FRONTMATTER=$(sed -n '2,/^---$/p' "$SKILL_FILE" | head -n -1)

        # Check only name + description allowed
        EXTRA_FIELDS=$(echo "$FRONTMATTER" | grep -E "^[a-z_-]+:" | grep -vE "^(name|description):" || true)
        if [[ -z "$EXTRA_FIELDS" ]]; then
            success "Frontmatter has only name + description"
        else
            error "Frontmatter has disallowed fields: $(echo "$EXTRA_FIELDS" | sed 's/:.*//' | tr '\n' ', ' | sed 's/,$//')"
        fi

        # Check name field
        if grep -q "^name:" "$SKILL_FILE"; then
            NAME=$(grep "^name:" "$SKILL_FILE" | head -1 | sed 's/name: *//' | tr -d '"')
            if [[ "$NAME" =~ ^[a-z0-9-]{1,64}$ ]]; then
                success "SKILL.md name valid: $NAME"
            else
                error "SKILL.md name invalid (lowercase, hyphens, max 64): $NAME"
            fi
        else
            error "SKILL.md missing 'name' field"
        fi

        # Check description field
        if grep -q "^description:" "$SKILL_FILE"; then
            DESC=$(grep "^description:" "$SKILL_FILE" | head -1 | sed 's/description: *//' | sed 's/^"//' | sed 's/"$//')
            if [[ "$DESC" == Use\ when* ]] || [[ "$DESC" == \"Use\ when* ]]; then
                success "Description starts with 'Use when'"
            else
                error "Description must start with 'Use when': $DESC"
            fi
        else
            error "SKILL.md missing 'description' field"
        fi
    else
        error "SKILL.md missing frontmatter (must start with ---)"
    fi

    # Word count
    WORDS=$(wc -w < "$SKILL_FILE")
    if [[ $WORDS -le 500 ]]; then
        success "SKILL.md is $WORDS words (under 500 limit)"
    else
        error "SKILL.md is $WORDS words (max 500)"
    fi
else
    error "SKILL.md not found (checked root and skills/*/)"
fi

# --- Required files ---
for file in README.md LICENSE .gitignore; do
    if [[ -f "$REPO_DIR/$file" ]]; then
        success "$file exists"
    else
        error "$file not found"
    fi
done

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

    # Name pattern
    COMP_NAME=$(python3 -c "import json; print(json.load(open('$REPO_DIR/composer.json')).get('name',''))" 2>/dev/null || echo "")
    if [[ "$COMP_NAME" == netresearch/agent-* ]]; then
        success "composer.json name follows netresearch/agent-* pattern: $COMP_NAME"
    else
        error "composer.json name must match netresearch/agent-*: $COMP_NAME"
    fi

    # Plugin dependency
    if grep -q "composer-agent-skill-plugin" "$REPO_DIR/composer.json"; then
        success "composer.json requires skill plugin"
    else
        warning "composer.json should require netresearch/composer-agent-skill-plugin"
    fi

    # ai-agent-skill extra path exists
    SKILL_PATH=$(python3 -c "import json; print(json.load(open('$REPO_DIR/composer.json')).get('extra',{}).get('ai-agent-skill',''))" 2>/dev/null || echo "")
    if [[ -n "$SKILL_PATH" ]]; then
        if [[ -f "$REPO_DIR/$SKILL_PATH" ]]; then
            success "composer.json extra.ai-agent-skill path exists: $SKILL_PATH"
        else
            error "composer.json extra.ai-agent-skill points to missing file: $SKILL_PATH"
        fi
    else
        error "composer.json missing extra.ai-agent-skill"
    fi
else
    error "composer.json not found"
fi

# --- plugin.json checks ---
PLUGIN_FILE="$REPO_DIR/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_FILE" ]]; then
    success "plugin.json exists"

    # Name matches SKILL.md name
    PLUGIN_NAME=$(python3 -c "import json; print(json.load(open('$PLUGIN_FILE')).get('name',''))" 2>/dev/null || echo "")
    if [[ -n "$NAME" ]] && [[ "$PLUGIN_NAME" == "$NAME" ]]; then
        success "plugin.json name matches SKILL.md: $PLUGIN_NAME"
    elif [[ -n "$NAME" ]]; then
        error "plugin.json name '$PLUGIN_NAME' does not match SKILL.md name '$NAME'"
    fi

    # Skills is array
    SKILLS_TYPE=$(python3 -c "import json; s=json.load(open('$PLUGIN_FILE')).get('skills'); print('array' if isinstance(s, list) else type(s).__name__)" 2>/dev/null || echo "unknown")
    if [[ "$SKILLS_TYPE" == "array" ]]; then
        success "plugin.json skills is array"

        # Check each skill path exists
        python3 -c "
import json, sys, os
data = json.load(open('$PLUGIN_FILE'))
for path in data.get('skills', []):
    full = os.path.join('$REPO_DIR', path)
    if os.path.isdir(full):
        print(f'OK:{path}')
    else:
        print(f'MISSING:{path}')
" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                OK:*) success "Skill path exists: ${line#OK:}" ;;
                MISSING:*) error "Skill path missing: ${line#MISSING:}" ;;
            esac
        done
    else
        error "plugin.json skills must be an array (got: $SKILLS_TYPE)"
    fi

    # Author URL
    AUTHOR_URL=$(python3 -c "import json; print(json.load(open('$PLUGIN_FILE')).get('author',{}).get('url',''))" 2>/dev/null || echo "")
    if [[ -n "$AUTHOR_URL" ]]; then
        if [[ "$AUTHOR_URL" == "https://www.netresearch.de" ]]; then
            success "plugin.json author.url is correct"
        else
            error "plugin.json author.url must be https://www.netresearch.de (got: $AUTHOR_URL)"
        fi
    fi
else
    error ".claude-plugin/plugin.json not found"
fi

# --- README.md quality checks ---
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
```

**Step 3: Run the script against skill-repo-skill itself**

Run: `bash skills/skill-repo/scripts/validate-skill.sh .`
Expected: PASS (0 errors) since skill-repo-skill was already fixed in the session.

**Step 4: Commit**

```bash
git add skills/skill-repo/scripts/validate-skill.sh
git commit -S --signoff -m "feat: enhance validate-skill.sh with comprehensive checks

Add checks for: frontmatter-only fields, word count, description prefix,
composer.json path validation, plugin.json structure, cross-file consistency,
.gitignore and release.yml presence."
```

---

### Task 2: Create Reusable GitHub Workflow

**Files:**
- Create: `.github/workflows/validate.yml`

**Step 1: Write the reusable workflow**

This workflow is called by other repos via `uses: netresearch/skill-repo-skill/.github/workflows/validate.yml@main`. It checks out both the calling repo and the skill-repo-skill (for the script), then runs validation.

```yaml
name: Validate Skill

on:
  workflow_call:

permissions:
  contents: read

jobs:
  validate:
    name: Skill Validation
    runs-on: ubuntu-latest
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@<LATEST_SHA> # v2.15.0
        with:
          egress-policy: audit

      - name: Checkout repository
        uses: actions/checkout@<LATEST_SHA> # v6.0.2

      - name: Checkout validation script
        uses: actions/checkout@<LATEST_SHA> # v6.0.2
        with:
          repository: netresearch/skill-repo-skill
          path: .validate-skill
          sparse-checkout: skills/skill-repo/scripts/validate-skill.sh
          sparse-checkout-cone-mode: false

      - name: Run skill validation
        run: bash .validate-skill/skills/skill-repo/scripts/validate-skill.sh .
```

Use the same pinned SHAs already present in the repo's other workflows.

**Step 2: Commit**

```bash
git add .github/workflows/validate.yml
git commit -S --signoff -m "feat: add reusable validate.yml workflow

Other skill repos can call this with:
  uses: netresearch/skill-repo-skill/.github/workflows/validate.yml@main"
```

---

### Task 3: Create Pre-Commit Hook

**Files:**
- Create: `Build/hooks/pre-commit`
- Modify: `skills/skill-repo/templates/pre-commit.template`

**Step 1: Write pre-commit hook**

The hook runs validate-skill.sh locally before each commit. It tries two locations for the script:
1. The repo's own copy (if it has one)
2. A globally installed copy (from skill-repo-skill)

```bash
#!/bin/bash
# pre-commit hook: validate skill repo structure
# Install: cp Build/hooks/pre-commit .git/hooks/pre-commit

SCRIPT=""
# Try local copy first
for f in scripts/validate-skill.sh skills/*/scripts/validate-skill.sh; do
    [[ -f "$f" ]] && SCRIPT="$f" && break
done

# Try fetching from skill-repo-skill if no local copy
if [[ -z "$SCRIPT" ]]; then
    echo "No local validate-skill.sh found, skipping validation"
    exit 0
fi

bash "$SCRIPT" .
```

**Step 2: Create pre-commit template for other repos**

Copy the hook to `skills/skill-repo/templates/pre-commit.template` so other repos can use it.

**Step 3: Update .envrc to install pre-commit hook too**

Read the current `.envrc` and add the pre-commit hook installation alongside the pre-push hook.

**Step 4: Commit**

```bash
git add Build/hooks/pre-commit skills/skill-repo/templates/pre-commit.template
git commit -S --signoff -m "feat: add pre-commit hook for local validation"
```

---

### Task 4: Update skill-repo-skill's Own lint.yml

**Files:**
- Modify: `.github/workflows/lint.yml`

**Step 1: Add validate job to lint.yml**

Since skill-repo-skill IS the source of the reusable workflow, it runs the script directly instead of calling itself recursively.

Add a `validate` job to the existing lint.yml:

```yaml
  validate:
    name: Skill Validation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<SHA> # v6.0.2
      - run: bash skills/skill-repo/scripts/validate-skill.sh .
```

**Step 2: Commit**

```bash
git add .github/workflows/lint.yml
git commit -S --signoff -m "feat: add skill validation job to lint.yml"
```

---

### Task 5: Test on skill-repo-skill

**Step 1: Run the script locally**

Run: `cd /home/cybot/projects/skill-repo-skill/main && bash skills/skill-repo/scripts/validate-skill.sh .`
Expected: All checks pass (0 errors).

**Step 2: Push and verify CI passes**

Push the branch, create PR, verify the new validate job passes in CI.

**Step 3: Merge the PR**

Wait for Copilot review, resolve any threads, merge.

---

### Task 6: Deploy to All 26 Skill Repos

**Files per repo:**
- Modify: `<repo>/.github/workflows/lint.yml` (add validate job)

**Step 1: For each of the 26 repos, add the validate job to lint.yml**

Add this job to each repo's `lint.yml`:

```yaml
  validate:
    name: Skill Validation
    uses: netresearch/skill-repo-skill/.github/workflows/validate.yml@main
```

This is a one-line addition per repo.

**List of all 26 repos:**
1. agents-skill
2. cli-tools-skill
3. concourse-ci-skill
4. context7-skill
5. data-tools-skill
6. docker-development-skill
7. enterprise-readiness-skill
8. extension-assessment-skill
9. file-search-skill
10. git-workflow-skill
11. github-project-skill
12. go-development-skill
13. jira-skill
14. matrix-skill
15. netresearch-branding-skill
16. pagerangers-skill
17. php-modernization-skill
18. security-audit-skill
19. skill-repo-skill (already done in Task 4)
20. typo3-ckeditor5-skill
21. typo3-conformance-skill
22. typo3-core-contributions-skill
23. typo3-ddev-skill
24. typo3-docs-skill
25. typo3-extension-upgrade-skill
26. typo3-testing-skill

**Step 2: Create PRs in parallel batches**

Dispatch parallel agents, each handling 5-6 repos:
- Batch 1: repos 1-5
- Batch 2: repos 6-10
- Batch 3: repos 11-15
- Batch 4: repos 16-20
- Batch 5: repos 21-25 (skip skill-repo-skill)

Each agent: creates branch, modifies lint.yml, commits, pushes, creates PR.

**Step 3: Request reviews, resolve threads, merge**

After all 25 PRs are created, wait for CI + reviews, then merge all.
