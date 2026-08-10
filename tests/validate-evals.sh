#!/usr/bin/env bash
# tests/validate-evals.sh — exercises scripts/validate-evals.sh against the
# three eval formats it claims to support.
#
# The fixtures next to this file (evals-unified.json, evals-legacy-regex.json,
# evals-expectations-only.json) existed with nothing running them: the script
# is called by the eval-validate reusable in every consumer repo, yet no test
# in this repo ever invoked it. A format regression would have surfaced first
# in a foreign repo's CI.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/skills/skill-repo/scripts/validate-evals.sh"
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

echo "validate-evals.sh"

for fixture in evals-unified.json evals-legacy-regex.json evals-expectations-only.json; do
    [ -f "$HERE/$fixture" ] || { echo "  FAIL fixture missing: $fixture"; fail=1; continue; }
    bash "$SCRIPT" "$HERE/$fixture" >/dev/null 2>&1
    check "accepts $fixture" 0 "$?"
done

# --- a malformed file must fail, or the validator is decorative -------------
printf '{ this is not json ' > "$WORK/broken.json"
bash "$SCRIPT" "$WORK/broken.json" >/dev/null 2>&1
check "rejects malformed JSON" 1 "$?"

# --- an eval with no grading mechanism must fail ----------------------------
cat > "$WORK/ungraded.json" <<'EOF'
[
  { "name": "no_grading", "prompt": "Does this eval grade anything?" },
  { "name": "also_none", "prompt": "Neither does this one." }
]
EOF
out=$(bash "$SCRIPT" "$WORK/ungraded.json" 2>&1)
check "rejects an eval with neither assertions nor expectations" 1 "$?"
check "names the ungraded eval" yes "$(grep -q 'no_grading' <<<"$out" && echo yes || echo no)"

# --- a missing file is an error, not a silent pass ---------------------------
bash "$SCRIPT" "$WORK/does-not-exist.json" >/dev/null 2>&1
check "rejects a missing file" 1 "$?"

echo
if [ "$fail" -eq 0 ]; then
    echo "All validate-evals tests passed"
else
    echo "Some validate-evals tests FAILED"
fi
exit "$fail"
