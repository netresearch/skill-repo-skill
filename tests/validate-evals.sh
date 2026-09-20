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
# The grader greps value-or-pattern from EVERY assertion, whatever its type,
# so a broken pattern under tool_use is graded and must be caught. (The type
# decides the direction of the verdict, not whether it is graded.)
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

# --- every evals.json is validated, not the first one found (#214 class) -----
# A repo shipping several skills ships several evals.json; discovery used to
# stop at the first, so a defect in any later one was invisible. The good file
# sorts FIRST and is padded to pass on its own, so the run can only fail because
# the later, broken one was reached.
MULTI="$WORK/multi"
rm -rf "$MULTI"
mkdir -p "$MULTI/skills/aaa-good/evals" "$MULTI/skills/zzz-broken/evals"
suite "$MULTI/skills/aaa-good/evals/evals.json" <<'EOF'
{ "name": "good", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "(?i)anything"},
                 {"type": "content", "pattern": "(?i)thing"}] }
EOF
suite "$MULTI/skills/zzz-broken/evals/evals.json" <<'EOF'
{ "name": "no-grading", "prompt": "Anything." }
EOF

# The good one alone must pass, or the check below would fail for the wrong reason.
bash "$SCRIPT" "$MULTI/skills/aaa-good/evals/evals.json" >/dev/null 2>&1
check "the padded good fixture passes on its own" 0 "$?"

out="$(cd "$MULTI" && bash "$SCRIPT" 2>&1)"; rc=$?
check "a defect in a later evals.json fails the run" 1 "$rc"
case "$out" in
    *aaa-good*zzz-broken*) check "both files are reported, in order" 0 0 ;;
    *) check "both files are reported, in order" 0 1 ;;
esac

# --- samples on a new or tightened eval (retro-skill#92) ---------------------
# Without a base copy nothing changes; with one, an eval that is new or whose
# assertions changed must carry samples, and everything else must still pass.
# padding-only.json is the base: 12 filler evals, pattern-bearing, no samples.
BASE="$WORK/padding-only.json"

suite "$WORK/new-no-samples.json" <<'EOF'
{ "name": "added_without_samples", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}] }
EOF
out=$(EVALS_BASE_FILE="$BASE" bash "$SCRIPT" "$WORK/new-no-samples.json" 2>&1)
check "a new eval without samples is rejected" 1 "$?"
check "names the new eval in the FAIL line" yes "$(grep -q 'added_without_samples.*is new and carries no samples' <<<"$out" && echo yes || echo no)"
check "leaves the untouched evals alone" no "$(grep -q 'filler_0.*carries no samples' <<<"$out" && echo yes || echo no)"

# The same file with no base copy: the requirement is off, verdict unchanged.
bash "$SCRIPT" "$WORK/new-no-samples.json" >/dev/null 2>&1
check "without EVALS_BASE_FILE the same file still passes" 0 "$?"

suite "$WORK/new-with-samples.json" <<'EOF'
{ "name": "added_with_samples", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}],
  "samples": {"passing": "alpha beta", "failing": ["gamma only"]} }
EOF
EVALS_BASE_FILE="$BASE" bash "$SCRIPT" "$WORK/new-with-samples.json" >/dev/null 2>&1
check "a new eval with samples passes" 0 "$?"

# An unchanged file compared against itself: every eval is known, none is
# demanded samples. This is the direction a validator that rejects everything
# would fail.
EVALS_BASE_FILE="$WORK/new-no-samples.json" bash "$SCRIPT" "$WORK/new-no-samples.json" >/dev/null 2>&1
check "a file compared against itself passes unchanged" 0 "$?"
EVALS_BASE_FILE="$BASE" bash "$SCRIPT" "$BASE" >/dev/null 2>&1
check "the base file compared against itself passes" 0 "$?"

# Tightened: same eval name, a stricter assertion set, no samples.
suite "$WORK/tightened-base.json" <<'EOF'
{ "name": "tightened", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}] }
EOF
suite "$WORK/tightened-head.json" <<'EOF'
{ "name": "tightened", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"},
                 {"type": "must_not", "pattern": "gamma"}] }
EOF
out=$(EVALS_BASE_FILE="$WORK/tightened-base.json" bash "$SCRIPT" "$WORK/tightened-head.json" 2>&1)
check "changed assertions without samples are rejected" 1 "$?"
check "names the tightened eval" yes "$(grep -q 'tightened.*changed assertions' <<<"$out" && echo yes || echo no)"

# Adding samples to an existing eval is not a change to its assertions.
suite "$WORK/samples-added.json" <<'EOF'
{ "name": "tightened", "prompt": "Anything.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}],
  "samples": {"passing": "alpha beta", "failing": ["gamma only"]} }
EOF
EVALS_BASE_FILE="$WORK/tightened-base.json" bash "$SCRIPT" "$WORK/samples-added.json" >/dev/null 2>&1
check "adding samples to an existing eval passes" 0 "$?"

# An edit that leaves the assertions alone is not a tightening: the eval is
# still graded by exactly what it was graded by before.
suite "$WORK/prompt-edited.json" <<'EOF'
{ "name": "tightened", "prompt": "Anything, reworded.",
  "expected_output": "Something.",
  "assertions": [{"type": "content", "pattern": "alpha"},
                 {"type": "content", "pattern": "beta"}] }
EOF
EVALS_BASE_FILE="$WORK/tightened-base.json" bash "$SCRIPT" "$WORK/prompt-edited.json" >/dev/null 2>&1
check "editing the prompt of an existing eval needs no samples" 0 "$?"

# An expectations-only eval has no pattern for a sample to exercise, and this
# validator fails samples no assertion backs - so it is exempt.
suite "$WORK/new-expectations-only.json" <<'EOF'
{ "name": "judged_by_expectations", "prompt": "Anything.",
  "expectations": ["Names the file it changed.", "States the exit code."] }
EOF
EVALS_BASE_FILE="$BASE" bash "$SCRIPT" "$WORK/new-expectations-only.json" >/dev/null 2>&1
check "a new expectations-only eval needs no samples" 0 "$?"

# A base copy that cannot be read is an error, never an empty base: the second
# would silently demand samples from every eval in the file.
out=$(EVALS_BASE_FILE="$WORK/no-such-base.json" bash "$SCRIPT" "$WORK/new-with-samples.json" 2>&1)
check "an unreadable base copy fails the run" 1 "$?"
check "says the base could not be read" yes "$(grep -q 'cannot read base copy' <<<"$out" && echo yes || echo no)"

# An eval identified only by `id` is keyed by that id, and format A requires
# ids to be sequential - so an eval APPENDED to such a file shifts nothing and
# only the appendee is flagged. (An eval INSERTED mid-list renumbers every
# later id and those evals then compare against their neighbours: named evals
# are immune, id-only files are not. Documented in the PR, not silently fixed.)
python3 - "$WORK/id-base.json" "$WORK/id-head.json" <<'PYEOF'
import json, sys
evals = [
    {"id": i + 1, "prompt": f"Filler prompt {i}.",
     "assertions": [{"type": "content", "pattern": "(?i)filler"},
                    {"type": "content", "pattern": r"\d"}]}
    for i in range(12)
]
json.dump(evals, open(sys.argv[1], "w"), indent=2)
appended = dict(evals[0], id=13, prompt="Appended prompt.")
json.dump(evals + [appended], open(sys.argv[2], "w"), indent=2)
PYEOF
out=$(EVALS_BASE_FILE="$WORK/id-base.json" bash "$SCRIPT" "$WORK/id-head.json" 2>&1)
check "an appended id-only eval is rejected" 1 "$?"
check "only the appended id is named" 1 "$(grep -c 'carries no samples' <<<"$out")"

# In discovery mode the run can cover several evals.json, so a base copy that
# names none of them must not be applied to all of them.
DISC="$WORK/discovery"
mkdir -p "$DISC/skills/one/evals"
cp "$WORK/new-no-samples.json" "$DISC/skills/one/evals/evals.json"
out=$(cd "$DISC" && EVALS_BASE_FILE="$BASE" bash "$SCRIPT" 2>&1)
check "a base copy is ignored in discovery mode" 0 "$?"
check "and says so" yes "$(grep -q 'EVALS_BASE_FILE is set but no evals.json was named' <<<"$out" && echo yes || echo no)"

printf 'not json at all' > "$WORK/base-broken.json"
out=$(EVALS_BASE_FILE="$WORK/base-broken.json" bash "$SCRIPT" "$WORK/new-with-samples.json" 2>&1)
check "a malformed base copy fails the run" 1 "$?"
check "says the base is not valid JSON" yes "$(grep -q 'not valid JSON' <<<"$out" && echo yes || echo no)"

echo
if [ "$fail" -eq 0 ]; then
    echo "All validate-evals tests passed"
else
    echo "Some validate-evals tests FAILED"
fi
exit "$fail"
