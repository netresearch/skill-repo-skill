#!/usr/bin/env bash
# tests/mechanical-coverage.sh — the two checks that make a skill's executable
# surface visible to CI:
#
#   * a script under skills/<name>/scripts/ that no test references
#   * an llm_reviews checkpoint whose prompt opens a line with a runnable
#     command, i.e. a mechanical check written as prose
#
# Both were absent, and the fleet showed why: 27 of 33 repos shipping scripts
# had no test file at all, and a whole shell pipeline sat inside an llm_review
# in git-workflow (GW-21) where nothing could execute or regress it.
#
# Fixtures are minimal on purpose — the validator also reports missing
# composer.json/README.md, so every assertion matches a specific verdict line
# rather than the overall exit code.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$(cd "$HERE/.." && pwd)/skills/skill-repo/scripts/validate-skill.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# new_repo <name> — a minimal skill repo with one script
new_repo() {
    local d="$WORK/$1"
    mkdir -p "$d/skills/demo/scripts" "$d/tests"
    cat > "$d/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: "Use when demonstrating the validator checks in a test fixture."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
metadata:
  author: Netresearch DTT GmbH
  version: "1.0.0"
---

# Demo
EOF
    printf '#!/usr/bin/env bash\necho demo\n' > "$d/skills/demo/scripts/demo-tool.sh"
    echo "$d"
}

# checkpoints <dir> <marker-placement>
#   none    — llm_review with a runnable command, no marker
#   above   — marker comment above the entry
#   inside  — marker comment inside the entry block
checkpoints() {
    local d="$1" placement="$2" above="" inside=""
    [ "$placement" = "above" ]  && above='  # mechanical-counterpart: DM-01'
    [ "$placement" = "inside" ] && inside='    # mechanical-counterpart: DM-01'
    cat > "$d/skills/demo/checkpoints.yaml" <<EOF
version: 1
skill_id: demo

mechanical:
  - id: DM-01
    type: command
    pattern: 'test -f README.md'
    severity: info
    desc: "A mechanical check"

llm_reviews:
$above
  - id: DM-20
    domain: demo
$inside
    prompt: |
      Check whether the repo is tidy.

      git log -5 --format=%H | while read -r c; do echo "\$c"; done

      Report: how many commits look tidy?
    severity: info
    desc: "Commits should look tidy"
EOF
}

verdicts() { bash "$VALIDATOR" "$1" 2>&1; }

echo "validate-skill.sh: mechanical coverage"

# --- 1. a script with no test anywhere -------------------------------------
repo=$(new_repo untested)
out=$(verdicts "$repo")
check "an untested script is reported as a warning" 1 "$(grep -c 'WARNING:.*no test references these script(s): demo-tool.sh' <<<"$out")"

# --- 2. a test that names the script clears it ------------------------------
repo=$(new_repo tested)
printf '#!/usr/bin/env bash\n# exercises demo-tool.sh\n' > "$repo/tests/demo.sh"
out=$(verdicts "$repo")
check "a referencing test clears the script" 1 \
    "$(grep -c 'OK:.*every script under skills/demo/scripts is referenced by a test' <<<"$out")"
check "no untested-script warning remains" 0 "$(grep -c 'no test references' <<<"$out")"

# --- 3. a runnable command inside an llm_review ----------------------------
repo=$(new_repo misclassified)
printf '#!/usr/bin/env bash\n# exercises demo-tool.sh\n' > "$repo/tests/demo.sh"
checkpoints "$repo" none
out=$(verdicts "$repo")
check "a command in an llm_review is reported" 1 \
    "$(grep -c 'WARNING:.*llm_reviews checkpoint(s) contain a runnable command: DM-20' <<<"$out")"

# --- 4. the opt-out marker, above and inside the entry ----------------------
for placement in above inside; do
    repo=$(new_repo "exempt-$placement")
    printf '#!/usr/bin/env bash\n# exercises demo-tool.sh\n' > "$repo/tests/demo.sh"
    checkpoints "$repo" "$placement"
    out=$(verdicts "$repo")
    check "a marker $placement the entry exempts it" 0 \
        "$(grep -c 'contain a runnable command' <<<"$out")"
done

# --- 5. prose that merely mentions a command is not a hit -------------------
repo=$(new_repo prose)
printf '#!/usr/bin/env bash\n# exercises demo-tool.sh\n' > "$repo/tests/demo.sh"
cat > "$repo/skills/demo/checkpoints.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical: []

llm_reviews:
  - id: DM-21
    domain: demo
    prompt: |
      Use `git log --oneline -20` to analyze commit message quality.

      Report: are the messages descriptive?
    severity: info
    desc: "Commit messages should be descriptive"
EOF
out=$(verdicts "$repo")
check "an inline command mention is not flagged" 0 "$(grep -c 'contain a runnable command' <<<"$out")"

echo
if [ "$fail" -eq 0 ]; then
    echo "All mechanical-coverage tests passed"
else
    echo "Some mechanical-coverage tests FAILED"
fi
exit "$fail"
