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

# The validator also enforces a minimum eval count and a minimum number of
# assertions per eval. A fixture holding only the eval under test therefore
# fails for those reasons instead, and every "must fail" assertion below would
# pass without ever exercising the check it names. suite() pads the file with
# valid evals so the eval under test is the only thing that can fail.
suite() { # suite <target-file> <<< <json of the eval under test>
    # The subject travels through the environment: python's own heredoc owns
    # stdin here, so sys.stdin would hand back this script instead.
    local subject
    subject="$(cat)"
    SUBJECT="$subject" python3 - "$1" <<'PYEOF'
import json, os, sys
subject = json.loads(os.environ["SUBJECT"])
evals = [
    {"name": f"filler_{i}", "prompt": f"Filler prompt {i}.",
     "assertions": [{"type": "content", "pattern": "(?i)filler"},
                    {"type": "content", "pattern": r"\d"}]}
    for i in range(12)
]
json.dump(evals + [subject], open(sys.argv[1], "w"), indent=2)
PYEOF
}

# The padding itself must validate, or every case below is measuring the padding.
suite "$WORK/padding-only.json" <<'EOF'
{ "name": "subject_ok", "prompt": "A prompt.",
  "assertions": [{"type": "content", "pattern": "(?i)alpha"},
                 {"type": "content", "pattern": "(?i)beta"}] }
EOF
bash "$SCRIPT" "$WORK/padding-only.json" >/dev/null 2>&1
check "the padded fixture validates on its own" 0 "$?"

# --- a pattern that is not a regex must fail ---------------------------------
# Until now a pattern only had to be a non-empty string, so an unbalanced group
# shipped and first misbehaved wherever the eval was actually graded.
suite "$WORK/uncompilable.json" <<'EOF'
{ "name": "broken_pattern", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "(unclosed group"},
                 {"type": "content", "pattern": "(?i)fine"}] }
EOF
out=$(bash "$SCRIPT" "$WORK/uncompilable.json" 2>&1)
check "rejects an assertion pattern that does not compile" 1 "$?"
# The eval name appears in the ordinary PASS output too, so asserting on the
# name alone is green against an implementation that never checks anything.
check "names the uncompilable eval in the FAIL line" yes \
    "$(grep -qE 'FAIL.*broken_pattern.*(valid|ERE|regex)' <<<"$out" && echo yes || echo no)"

# --- samples: the self-check that tells a discriminating eval from a vacuous one
suite "$WORK/samples-good.json" <<'EOF'
{ "name": "discriminating",
  "prompt": "How do you clean up a merged worktree that is the primary directory?",
  "assertions": [
    {"type": "content", "pattern": "(?i)\\bswitch\\b[^\\n]{0,30}\\b(main|master)"},
    {"type": "content", "pattern": "(?i)primary|instead"}
  ],
  "samples": {
    "passing": "Do not remove the primary one. Run git -C project/main switch main instead.",
    "failing": ["Remove every merged worktree, including project/main."]
  } }
EOF
bash "$SCRIPT" "$WORK/samples-good.json" >/dev/null 2>&1
check "accepts samples whose assertions discriminate" 0 "$?"

# --- an assertion that misses its own passing sample is inverted -------------
# The case that motivated this check: an assertion demanded the literal word
# "remove", while the answer it was written for says "never-removable".
suite "$WORK/samples-inverted.json" <<'EOF'
{ "name": "misses_its_own_answer",
  "prompt": "How do you clean up a merged worktree that is the primary directory?",
  "assertions": [
    {"type": "content", "pattern": "(not|never) .{0,40}(remove|delete)"},
    {"type": "content", "pattern": "(?i)worktree"}
  ],
  "samples": {
    "passing": "Treat the primary worktree as never-removable; switch it back instead.",
    "failing": ["Delete every merged worktree, do not keep any."]
  } }
EOF
out=$(bash "$SCRIPT" "$WORK/samples-inverted.json" 2>&1)
check "rejects an assertion that misses its own passing sample" 1 "$?"
check "names the assertion index" yes "$(grep -q 'assertion\[0\]' <<<"$out" && echo yes || echo no)"

# --- a failing sample that satisfies every assertion proves nothing ----------
suite "$WORK/samples-vacuous.json" <<'EOF'
{ "name": "accepts_the_wrong_answer",
  "prompt": "How do you clean up a merged worktree that is the primary directory?",
  "assertions": [
    {"type": "content", "pattern": "(?i)worktree"},
    {"type": "content", "pattern": "(?i)merged"}
  ],
  "samples": {
    "passing": "Switch the primary worktree back to main; the merged ones can go.",
    "failing": ["Remove every merged worktree, including the primary one."]
  } }
EOF
out=$(bash "$SCRIPT" "$WORK/samples-vacuous.json" 2>&1)
check "rejects a failing sample that no assertion rejects" 1 "$?"

# --- the self-check must match the way the grader matches --------------------
# run-ab-evals.sh grades with `grep -qiE`. Validating with a case-sensitive
# engine rejects evals the grader accepts, and accepts vacuous ones it would
# have caught.
suite "$WORK/samples-case.json" <<'EOF'
{ "name": "case_differs_from_the_sample",
  "prompt": "Which licence file?",
  "assertions": [
    {"type": "content", "pattern": "Netresearch DTT GmbH"},
    {"type": "content", "pattern": "LICENSE-MIT"}
  ],
  "samples": {
    "passing": "Add license-mit and set the holder to netresearch dtt gmbh.",
    "failing": ["Leave the licence alone."]
  } }
EOF
bash "$SCRIPT" "$WORK/samples-case.json" >/dev/null 2>&1
check "case-insensitive like the grader" 0 "$?"

# --- every graded assertion is validated, whatever its type is ---------------
# The grader takes value-or-pattern from EVERY assertion with no type filter,
# so a broken pattern under tool_use is graded and must be caught.
suite "$WORK/tooluse-pattern.json" <<'EOF'
{ "name": "broken_pattern_under_tool_use", "prompt": "Anything.",
  "assertions": [{"type": "tool_use", "tool": "Bash", "pattern": "(unclosed group"},
                 {"type": "content", "pattern": "fine"}] }
EOF
bash "$SCRIPT" "$WORK/tooluse-pattern.json" >/dev/null 2>&1
check "an unparseable tool_use pattern is rejected too" 1 "$?"

# --- a misconfigured samples block must not be a silent no-op ---------------
suite "$WORK/samples-typo.json" <<'EOF'
{ "name": "typo_in_the_samples_key", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}],
  "samples": {"passes": "alpha beta", "failing": ["nothing here"]} }
EOF
out=$(bash "$SCRIPT" "$WORK/samples-typo.json" 2>&1)
check "an unknown samples key is an error, not a no-op" 1 "$?"
check "names the unknown key" yes "$(grep -q 'passes' <<<"$out" && echo yes || echo no)"

suite "$WORK/samples-shape.json" <<'EOF'
{ "name": "failing_is_a_number", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}],
  "samples": {"passing": "alpha beta", "failing": 42} }
EOF
bash "$SCRIPT" "$WORK/samples-shape.json" >/dev/null 2>&1
check "a non-list failing value is rejected, not a traceback" 1 "$?"

# --- evals without samples keep validating exactly as before -----------------
suite "$WORK/no-samples.json" <<'EOF'
{ "name": "unchanged", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "(?i)anything"},
                 {"type": "content", "pattern": "(?i)thing"}] }
EOF
bash "$SCRIPT" "$WORK/no-samples.json" >/dev/null 2>&1
check "an eval without samples still passes" 0 "$?"

echo
if [ "$fail" -eq 0 ]; then
    echo "All validate-evals tests passed"
else
    echo "Some validate-evals tests FAILED"
fi
exit "$fail"
