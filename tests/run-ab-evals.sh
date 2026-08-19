#!/usr/bin/env bash
# tests/run-ab-evals.sh — the two things run-ab-evals.sh reports beyond a pass
# rate:
#
#   * the actor tuple a delta belongs to (skill version, harness, model,
#     eval-set content id), because a bare percentage is not a checkable claim
#   * per-eval discriminating checks — assertions the no-skill baseline fails
#     and the with-skill run passes — and `--require-delta`, which turns an
#     eval without any of them into a non-zero exit
#
# The runner drives `claude -p` per eval, so the fixture puts a stub earlier on
# PATH. The stub answers differently depending on whether the appended system
# prompt carries the skill body -- both arms pass --append-system-prompt, since
# the without arm still gets the no-tools note -- and grades expectations by
# looking at the response embedded in the grading prompt. No model is called.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(cd "$HERE/.." && pwd)/scripts/run-ab-evals.sh"
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
contains() { # contains <name> <needle> <haystack>
    case "$3" in
        *"$2"*) echo "  ok   $1" ;;
        *) echo "  FAIL $1: '$2' not found in output"; fail=1 ;;
    esac
}

# --- Fixture -----------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/repo/scripts" "$WORK/repo/skills/demo/evals"
cp "$RUNNER" "$WORK/repo/scripts/run-ab-evals.sh"

cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Minimal claude stand-in. Without the skill the answer omits the gotcha; with
# it, the answer contains it. Grading prompts are answered from the RESPONSE
# section they carry.
# Both arms pass --append-system-prompt now (the without arm carries the
# no-tools note alone), so the flag no longer identifies the arm. What does is
# whether the appended prompt contains the skill body.
with_skill=""
prev=""
for arg in "$@"; do
    [ "$arg" = "--version" ] && { echo "9.9.9 (Claude Code test stub)"; exit 0; }
    if [ "$prev" = "--append-system-prompt" ]; then
        case "$arg" in *"nonroot USER"*) with_skill=1 ;; esac
    fi
    prev="$arg"
done
# Record the isolation flags so the test can assert they are still passed; a
# future edit that drops them would otherwise silently let the operator's MCP
# servers back into the measurement.
{
    printf 'CALL'
    for a in "$@"; do case "$a" in --strict-mcp-config|--mcp-config|--tools) printf ' %s' "$a" ;; esac; done
    printf '\n'
} >> "${STUB_CALL_LOG:-/dev/null}"

prompt="${*: -1}"
# STUB_LIMIT=1 makes the stub answer like a CLI that hit its session limit:
# the refusal goes to stdout and thus into the answer file, exactly as the real
# one does.
if [ -n "${STUB_LIMIT:-}" ]; then
    case "$prompt" in
        *"You are grading"*) ;;
        *) echo "You've hit your session limit · resets 12:30pm (Europe/Berlin)"; exit 0 ;;
    esac
fi

case "$prompt" in
    *"You are grading"*)
        case "$prompt" in
            *"nonroot USER"*) printf '1. PASS - names the base image\n2. PASS - sets a non-root user\n' ;;
            *) printf '1. PASS - names the base image\n2. FAIL - no non-root user\n' ;;
        esac
        ;;
    *)
        if [ -n "$with_skill" ]; then
            echo "Use alpine and add a nonroot USER."
        else
            echo "Use alpine."
        fi
        ;;
esac
STUB
chmod +x "$WORK/bin/claude"

cat > "$WORK/repo/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: "Use when demonstrating the A/B runner in a test fixture."
---

Always add a nonroot USER.
EOF
printf '{"name":"demo","version":"4.5.6"}\n' > "$WORK/repo/skills/demo/plugin.json"

# One eval with a discriminating assertion (USER appears only with the skill)
# and one whose assertions both arms satisfy.
cat > "$WORK/repo/skills/demo/evals/mixed.json" <<'EOF'
{"skill_name": "demo", "evals": [
  {"name": "discriminates", "prompt": "Write a Dockerfile.",
   "assertions": [{"type": "content", "pattern": "alpine"},
                  {"type": "content", "pattern": "USER"}]},
  {"name": "boilerplate_only", "prompt": "Write a Dockerfile.",
   "assertions": [{"type": "content", "pattern": "alpine"},
                  {"type": "content", "pattern": "Use"}]}
]}
EOF
# Same file minus the evidence-free eval.
cat > "$WORK/repo/skills/demo/evals/clean.json" <<'EOF'
{"skill_name": "demo", "evals": [
  {"name": "discriminates", "prompt": "Write a Dockerfile.",
   "assertions": [{"type": "content", "pattern": "alpine"},
                  {"type": "content", "pattern": "USER"}]}
]}
EOF
# A negative expectation. The baseline answer says "Use alpine." and the
# with-skill answer adds the USER line, so a must_not on `USER` must FAIL the
# with-skill arm and PASS the baseline — the mirror image of a positive
# assertion, and the case that was graded backwards until the type was read.
cat > "$WORK/repo/skills/demo/evals/negative.json" <<'EOF'
{"skill_name": "demo", "evals": [
  {"name": "forbids_user_line", "prompt": "Write a Dockerfile.",
   "assertions": [{"type": "content", "pattern": "alpine"},
                  {"type": "must_not", "pattern": "USER"}]}
]}
EOF
# LLM-graded expectations: the grader passes the second one only for the
# with-skill answer.
cat > "$WORK/repo/skills/demo/evals/graded.json" <<'EOF'
{"skill_name": "demo", "evals": [
  {"name": "graded", "prompt": "Write a Dockerfile.",
   "expectations": ["names the base image", "sets a non-root user"]}
]}
EOF

run_runner() { # run_runner <evals-file> [extra-flags...]
    local evals="$1"; shift
    (
        cd "$WORK/repo" || exit 99
        PATH="$WORK/bin:$PATH" STUB_CALL_LOG="$WORK/calls.log" \
        STUB_LIMIT="${STUB_LIMIT:-}" bash scripts/run-ab-evals.sh \
            --evals="$WORK/repo/skills/demo/evals/$evals" \
            --skill="$WORK/repo/skills/demo/SKILL.md" \
            2 "$@" 2>&1
    )
}
results_json() { python3 -c "
import json, sys
print(json.load(open('$WORK/repo/scripts/ab-results/ab-results.json'))$1)
"; }

# --- Regex arm ---------------------------------------------------------------
out=$(run_runner mixed.json --no-llm)
rc=$?
check "a run over a well-formed eval set exits 0" 0 "$rc"
contains "the discriminating eval reports 1 of 2 checks" \
    "discriminates [regex]: without=1/2 with=2/2 (+1) discriminating=1/2" "$out"
contains "the boilerplate eval reports none" \
    "boilerplate_only [regex]: without=2/2 with=2/2 (0) discriminating=0/2" "$out"
contains "the evidence-free eval is named in the summary" \
    "- boilerplate_only" "$out"
contains "the measured line carries version, harness, model and eval set" \
    "Measured: demo@4.5.6 · claude-code 9.9.9 (Claude Code test stub) · model sonnet" "$out"

check "provenance records the harness" \
    "claude-code 9.9.9 (Claude Code test stub)" "$(results_json "['provenance']['harness']")"
check "provenance records the skill version" "4.5.6" \
    "$(results_json "['provenance']['skill_version']")"
check "provenance records the eval-set size" "2" \
    "$(results_json "['provenance']['eval_set']['count']")"
check "provenance records an eval-set content id" "40" \
    "$(results_json "['provenance']['eval_set']['sha']" | tr -d '\n' | wc -c)"
check "the evidence-free eval is listed in the results file" "['boilerplate_only']" \
    "$(results_json "['evals_without_delta']")"
check "discriminating checks are counted" "1" \
    "$(results_json "['discriminating_checks']")"

# --- --require-delta --------------------------------------------------------
run_runner mixed.json --no-llm --require-delta >/dev/null 2>&1
check "--require-delta fails on an eval without a discriminating check" 1 "$?"

run_runner clean.json --no-llm --require-delta >/dev/null 2>&1
check "--require-delta passes when every eval discriminates" 0 "$?"

# --- The measurement is isolated from the operator's environment -------------
# Every completion call must carry the flags that keep configured MCP servers
# out of the run; without them the two arms differ in more than the skill.
total_calls=$(grep -c '^CALL' "$WORK/calls.log" 2>/dev/null || echo 0)
isolated_calls=$(grep -c 'strict-mcp-config' "$WORK/calls.log" 2>/dev/null || echo 0)
check "every completion call carries the MCP isolation flags" "$total_calls" "$isolated_calls"
check "the run actually called the stub" "yes" \
    "$([ "${total_calls:-0}" -gt 0 ] && echo yes || echo no)"

# --- must_not is graded inverted --------------------------------------------
out=$(run_runner negative.json --no-llm)
contains "a must_not assertion passes the arm that lacks the pattern" \
    "forbids_user_line [regex]: without=2/2 with=1/2 (-1) discriminating=0/2" "$out"
check "an eval whose only movement is a must_not violation is not counted as evidence" \
    "['forbids_user_line']" "$(results_json "['evals_without_delta']")"
check "no discriminating check is credited when the skill run violates the must_not" "0" \
    "$(results_json "['discriminating_checks']")"

# --- LLM-graded expectations ------------------------------------------------
out=$(run_runner graded.json)
contains "expectations are counted for discrimination too" \
    "graded [llm]: without=1/2 with=2/2 (+1) discriminating=1/2" "$out"
check "an LLM-only run is not reported as evidence-free" "[]" \
    "$(results_json "['evals_without_delta']")"
check "llm grading is recorded in provenance" "True" \
    "$(results_json "['provenance']['llm_grading']")"

# --- A non-answer is unknown, not evidence-free ------------------------------
# The CLI writes a limit or API error into the same file an answer would go to.
# Grading that text scores the eval as wrong for a reason that has nothing to
# do with the eval, and --require-delta would then fail on it.
out=$(STUB_LIMIT=1 run_runner clean.json --no-llm)
contains "an eval whose arm carries no answer is reported as not measured" \
    "discriminates: NOT MEASURED" "$out"
check "it is listed as unmeasured, not as evidence-free" "['discriminates']" \
    "$(results_json "['evals_unmeasured']")"
check "it is kept out of the evidence-free list" "[]" \
    "$(results_json "['evals_without_delta']")"
check "its checks are kept out of the totals" "0" \
    "$(results_json "['totals']['combined']['checks']")"

STUB_LIMIT=1 run_runner clean.json --no-llm --require-delta >/dev/null 2>&1
check "--require-delta fails when nothing could be measured" 1 "$?"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "All run-ab-evals tests passed"
else
    echo "run-ab-evals tests FAILED"
fi
exit "$fail"
