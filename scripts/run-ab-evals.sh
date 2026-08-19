#!/bin/bash
# run-ab-evals.sh - A/B test evals WITHOUT vs WITH skill context
# Usage: ./scripts/run-ab-evals.sh [--no-llm] [--require-delta] [concurrency]
# Default concurrency: 4 (parallel eval pairs)
# --no-llm: Skip LLM-based grading of expectations (regex assertions only)
# --require-delta: exit 1 if any eval has no discriminating assertion, i.e. no
#   assertion that the no-skill baseline fails and the with-skill run passes.
#   Such an eval measures boilerplate the model produces either way; it cannot
#   support a claim that the skill changed anything.
#
# A delta is not a property of a skill. It is a function of skill version,
# model, agent harness, eval set and tool environment, so every run records
# that tuple in the provenance block of ab-results.json and prints it at the
# end. Quote a number together with the tuple it was measured under, never on
# its own: a stronger actor may derive the same content unaided, and then the
# skill only costs context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags and positional args
NO_LLM=false
REQUIRE_DELTA=false
CONCURRENCY=4
EVALS_FILE=""
SKILL_FILE=""
for arg in "$@"; do
    case "$arg" in
        --no-llm) NO_LLM=true ;;
        --require-delta) REQUIRE_DELTA=true ;;
        --evals=*) EVALS_FILE="${arg#--evals=}" ;;
        --skill=*) SKILL_FILE="${arg#--skill=}" ;;
        [0-9]*) CONCURRENCY="$arg" ;;
    esac
done

# Defaults if not provided
EVALS_FILE="${EVALS_FILE:-$REPO_DIR/skills/skill-repo/evals/evals.json}"
SKILL_FILE="${SKILL_FILE:-$REPO_DIR/skills/skill-repo/SKILL.md}"
RESULTS_DIR="${REPO_DIR}/scripts/ab-results"

# Models used for the A/B completions and the LLM judge; recorded in the
# provenance block of ab-results.json so published numbers stay reproducible.
EVAL_MODEL="sonnet"
GRADER_MODEL="haiku"

# Appended to the system prompt of BOTH arms. Print mode serves no tool calls,
# and without being told, the model answers an action-shaped prompt by
# announcing a tool call instead of producing the content the assertions grade.
NO_TOOLS_NOTE="You have no tools in this session and cannot read or write files. Answer with the content or explanation itself, in the response text."

# The rest of the actor tuple. The harness is the agent runtime that has to
# discover and apply the skill -- a different one can be worse at that with an
# unchanged skill -- and the skill version says which text was measured. Both
# fall back to "unknown" rather than failing the run, because a missing
# version is a weaker claim, not a broken measurement.
HARNESS_VERSION="claude-code $(claude --version 2>/dev/null | head -1 | tr -d '\r\n' || true)"
[[ "$HARNESS_VERSION" == "claude-code " ]] && HARNESS_VERSION="claude-code unknown"

skill_version_of() {
    # Nearest plugin.json above the SKILL.md, then composer.json; the skill
    # repo convention keeps those in version parity.
    local dir="$1" manifest
    while [[ "$dir" != "/" && -n "$dir" ]]; do
        for manifest in "$dir/.claude-plugin/plugin.json" "$dir/plugin.json" "$dir/composer.json"; do
            if [[ -f "$manifest" ]]; then
                local version
                version=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('version') or '')
except Exception:
    print('')
" "$manifest")
                if [[ -n "$version" ]]; then
                    echo "$version"
                    return
                fi
            fi
        done
        dir="$(dirname "$dir")"
    done
    echo "unknown"
}
SKILL_VERSION=$(skill_version_of "$(cd "$(dirname "$SKILL_FILE")" && pwd)")

mkdir -p "$RESULTS_DIR"

# Normalize: support both top-level array and {evals: [...]} wrapper
EVAL_COUNT=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print(len(evals))
")
echo "Found $EVAL_COUNT evals, concurrency=$CONCURRENCY"
echo "Evals: $EVALS_FILE"
echo "Skill: $SKILL_FILE"

# Helper: get eval name (supports 'name', 'eval_name', or 'id' fallback)
get_eval_name() {
    python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
e = evals[$1]
print(e.get('name') or e.get('eval_name') or f\"eval_{e.get('id', $1)}\")
"
}

# Helper: get eval field
get_eval_field() {
    python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print(evals[$1].get('$2', ''))
"
}

run_single() {
    local idx="$1"
    local mode="$2"
    local name prompt output_file

    name=$(get_eval_name "$idx")
    prompt=$(get_eval_field "$idx" "prompt")
    output_file="$RESULTS_DIR/${name}_${mode}.txt"

    # Two isolation steps, both added after a run showed the arms differing in
    # something other than the skill:
    #
    #   * --tools "" drops the built-in tools but NOT the MCP servers the
    #     operator happens to have configured. On a workstation with
    #     Gmail/Drive servers attached, answers were about which tools existed
    #     rather than about the question -- unequally between the arms.
    #     --strict-mcp-config with an empty --mcp-config removes them.
    #   * With the tools gone the model still expects to have them: an
    #     action-shaped prompt ("create a plugin.json") produced "I'll check the
    #     repo first" and a tool call that print mode cannot serve, i.e. three
    #     output tokens and no content to grade. NO_TOOLS_NOTE says so up
    #     front. It is appended to BOTH arms, so the two still differ only in
    #     the skill.
    local system_prompt
    if [[ "$mode" == "without" ]]; then
        system_prompt="$NO_TOOLS_NOTE"
    else
        system_prompt="$(cat "$SKILL_FILE")

$NO_TOOLS_NOTE"
    fi

    timeout 90 claude -p \
        --no-session-persistence \
        --disable-slash-commands \
        --tools "" \
        --mcp-config '{"mcpServers":{}}' \
        --strict-mcp-config \
        --model "$EVAL_MODEL" \
        --append-system-prompt "$system_prompt" \
        "$prompt" \
        > "$output_file" 2>/dev/null || true
}

run_pair() {
    local idx="$1"
    local name
    name=$(get_eval_name "$idx")
    echo "  Starting eval $idx: $name"
    run_single "$idx" "without" &
    local pid1=$!
    run_single "$idx" "with" &
    local pid2=$!
    wait "$pid1" "$pid2" 2>/dev/null || true
    echo "  Finished eval $idx: $name"
}

# Grade expectations via LLM judge
# Writes results to $RESULTS_DIR/${name}_${mode}_expectations.txt
grade_expectations() {
    local idx="$1"
    local mode="$2"
    local name prompt output_file expectations_count grader_file

    name=$(get_eval_name "$idx")
    prompt=$(get_eval_field "$idx" "prompt")
    output_file="$RESULTS_DIR/${name}_${mode}.txt"
    grader_file="$RESULTS_DIR/${name}_${mode}_expectations.txt"

    # Get expectations as numbered list
    expectations_count=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print(len(evals[$idx].get('expectations', [])))
")

    if [[ "$expectations_count" -eq 0 ]]; then
        return
    fi

    local expectations_list
    expectations_list=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
for i, e in enumerate(evals[$idx].get('expectations', []), 1):
    print(f'{i}. {e}')
")

    local response_content
    response_content=$(cat "$output_file" 2>/dev/null || echo "(empty response)")

    # Build grading prompt
    local grading_prompt
    grading_prompt="You are grading an AI assistant's response against expectations.

PROMPT: $prompt
RESPONSE: $response_content
EXPECTATIONS:
$expectations_list

For each expectation, respond with PASS or FAIL followed by a brief reason.
Format: one line per expectation, e.g.:
1. PASS - correctly explains the risk
2. FAIL - does not mention the alternative"

    timeout 60 claude -p \
        --no-session-persistence \
        --disable-slash-commands \
        --tools "" \
        --mcp-config '{"mcpServers":{}}' \
        --strict-mcp-config \
        --model "$GRADER_MODEL" \
        "$grading_prompt" \
        > "$grader_file" 2>/dev/null || true
}

# A completion that never happened. The CLI writes its refusal into the same
# file an answer would go to -- a session/usage limit, an API error, an empty
# body after a timeout -- and the grader then scores that text as a wrong
# answer, lowering both arms for reasons that have nothing to do with the eval.
# Such a pair is UNKNOWN and is excluded from the totals, never counted as
# evidence-free.
is_non_answer() {
    local file="$1"
    [[ -s "$file" ]] || return 0
    grep -qiE "you'?ve hit your (session|usage) limit|session limit .{0,20}reset|credit balance is too low|^ *API Error|rate limit exceeded|invalid api key|overloaded_error" "$file" && return 0
    return 1
}

# Expectations the with-skill run passes and the baseline does not. Same
# anchor as count_expectation_passes below, so the two cannot disagree about
# what a PASS line looks like.
count_expectation_discriminating() {
    python3 - "$1" "$2" <<'PYEOF'
import re
import sys


def passing(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return set()
    return {int(m.group(1)) for m in re.finditer(r"^(\d+)\.\s*PASS", text, re.M | re.I)}


print(len(passing(sys.argv[2]) - passing(sys.argv[1])))
PYEOF
}

# Count PASS lines in a grader output file
count_expectation_passes() {
    local grader_file="$1"
    if [[ ! -f "$grader_file" ]]; then
        echo 0
        return
    fi
    grep -ciE '^[0-9]+\.\s*PASS' "$grader_file" 2>/dev/null || echo 0
}

# Run evals in batches
for batch_start in $(seq 0 "$CONCURRENCY" $((EVAL_COUNT - 1))); do
    batch_end=$((batch_start + CONCURRENCY - 1))
    [[ $batch_end -ge $EVAL_COUNT ]] && batch_end=$((EVAL_COUNT - 1))

    echo "=== Batch: evals $batch_start-$batch_end ==="
    for i in $(seq "$batch_start" "$batch_end"); do
        run_pair "$i" &
    done
    wait
done

# Run LLM grading for expectations (if not disabled)
if [[ "$NO_LLM" == "false" ]]; then
    # Check which evals have expectations
    HAS_ANY_EXPECTATIONS=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print('yes' if any(e.get('expectations') for e in evals) else 'no')
")
    if [[ "$HAS_ANY_EXPECTATIONS" == "yes" ]]; then
        echo ""
        echo "=== LLM Grading (expectations) ==="
        for batch_start in $(seq 0 "$CONCURRENCY" $((EVAL_COUNT - 1))); do
            batch_end=$((batch_start + CONCURRENCY - 1))
            [[ $batch_end -ge $EVAL_COUNT ]] && batch_end=$((EVAL_COUNT - 1))

            for i in $(seq "$batch_start" "$batch_end"); do
                exp_count=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print(len(evals[$i].get('expectations', [])))
")
                if [[ "$exp_count" -gt 0 ]]; then
                    grade_expectations "$i" "without" &
                    grade_expectations "$i" "with" &
                fi
            done
            wait
        done
        echo "  LLM grading complete"
    fi
fi

# Analyze results
echo ""
echo "=== RESULTS ==="

SUMMARY_FILE="$RESULTS_DIR/summary.md"
cat > "$SUMMARY_FILE" << 'EOF'
| # | Eval | Type | Without | With | Delta |
|---|------|------|---------|------|-------|
EOF

TOTAL_WITHOUT=0
TOTAL_WITH=0
TOTAL_CHECKS=0
TOTAL_EXP_WITHOUT=0
TOTAL_EXP_WITH=0
TOTAL_EXPECTATIONS=0
TOTAL_DISCRIMINATING=0
EVALS_WITHOUT_DELTA=()
EVALS_UNMEASURED=()

for i in $(seq 0 $((EVAL_COUNT - 1))); do
    name=$(get_eval_name "$i")
    eval_disc=0
    eval_graded=0

    if is_non_answer "$RESULTS_DIR/${name}_without.txt" || is_non_answer "$RESULTS_DIR/${name}_with.txt"; then
        EVALS_UNMEASURED+=("$name")
        echo "  $name: NOT MEASURED — an arm carries no answer (limit, API error or empty response)"
        echo "| $((i+1)) | $name | — | not measured | not measured | -- |" >> "$SUMMARY_FILE"
        continue
    fi

    without_file="$RESULTS_DIR/${name}_without.txt"
    with_file="$RESULTS_DIR/${name}_with.txt"

    # Check regex assertions
    assertion_count=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print(len(evals[$i].get('assertions', [])))
")
    if [[ "$assertion_count" -gt 0 ]]; then
        pass_w=0; pass_s=0; total=0; disc=0
        # Each line is "<kind><TAB><pattern>", kind being must_not or positive.
        # The kind is emitted first and is never empty, so IFS cannot collapse
        # it into the pattern field.
        while IFS=$'\t' read -r kind pattern; do
            [[ -z "$pattern" ]] && continue
            # Strip PCRE inline flags (e.g. (?i)) — grep -i already handles case
            pattern="${pattern#'(?i)'}"
            ((total++)) || true
            hit_w=0; hit_s=0
            grep -qiE "$pattern" "$without_file" 2>/dev/null && hit_w=1 || true
            grep -qiE "$pattern" "$with_file" 2>/dev/null && hit_s=1 || true
            # A must_not assertion passes when the pattern is ABSENT. Grading it
            # like a positive one credits the arm that gives the forbidden
            # answer, which is the opposite of what the eval states.
            if [[ "$kind" == "must_not" ]]; then
                ok_w=$((1 - hit_w)); ok_s=$((1 - hit_s))
            else
                ok_w="$hit_w"; ok_s="$hit_s"
            fi
            ((pass_w += ok_w)) || true
            ((pass_s += ok_s)) || true
            # Discriminating: the baseline fails the assertion and the skill run
            # passes it. An assertion both arms pass measures boilerplate, not
            # the skill.
            if [[ "$ok_w" -eq 0 && "$ok_s" -eq 1 ]]; then ((disc++)) || true; fi
        done <<< "$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
for a in evals[$i].get('assertions', []):
    if isinstance(a, dict):
        pattern = a.get('value') or a.get('pattern') or ''
        kind = 'must_not' if 'must_not' in str(a.get('type') or '') else 'positive'
    else:
        pattern, kind = str(a), 'positive'
    print(kind + '\t' + pattern)
")"

        delta=$((pass_s - pass_w))
        [[ $delta -gt 0 ]] && ds="+$delta" || ds="$delta"

        TOTAL_WITHOUT=$((TOTAL_WITHOUT + pass_w))
        TOTAL_WITH=$((TOTAL_WITH + pass_s))
        TOTAL_CHECKS=$((TOTAL_CHECKS + total))

        eval_disc=$((eval_disc + disc))
        eval_graded=$((eval_graded + total))
        TOTAL_DISCRIMINATING=$((TOTAL_DISCRIMINATING + disc))

        echo "| $((i+1)) | $name | regex | $pass_w/$total | $pass_s/$total | $ds |" >> "$SUMMARY_FILE"
        echo "  $name [regex]: without=$pass_w/$total with=$pass_s/$total ($ds) discriminating=$disc/$total"
    fi

    # Check LLM-graded expectations
    exp_count=$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
print(len(evals[$i].get('expectations', [])))
")
    if [[ "$exp_count" -gt 0 ]]; then
        if [[ "$NO_LLM" == "true" ]]; then
            echo "| $((i+1)) | $name | llm | skipped | skipped | -- |" >> "$SUMMARY_FILE"
            echo "  $name [llm]: skipped (--no-llm)"
        else
            exp_pass_w=$(count_expectation_passes "$RESULTS_DIR/${name}_without_expectations.txt")
            exp_pass_s=$(count_expectation_passes "$RESULTS_DIR/${name}_with_expectations.txt")
            exp_disc=$(count_expectation_discriminating \
                "$RESULTS_DIR/${name}_without_expectations.txt" \
                "$RESULTS_DIR/${name}_with_expectations.txt")

            exp_delta=$((exp_pass_s - exp_pass_w))
            [[ $exp_delta -gt 0 ]] && exp_ds="+$exp_delta" || exp_ds="$exp_delta"

            TOTAL_EXP_WITHOUT=$((TOTAL_EXP_WITHOUT + exp_pass_w))
            TOTAL_EXP_WITH=$((TOTAL_EXP_WITH + exp_pass_s))
            TOTAL_EXPECTATIONS=$((TOTAL_EXPECTATIONS + exp_count))
            eval_disc=$((eval_disc + exp_disc))
            eval_graded=$((eval_graded + exp_count))
            TOTAL_DISCRIMINATING=$((TOTAL_DISCRIMINATING + exp_disc))

            echo "| $((i+1)) | $name | llm | $exp_pass_w/$exp_count | $exp_pass_s/$exp_count | $exp_ds |" >> "$SUMMARY_FILE"
            echo "  $name [llm]: without=$exp_pass_w/$exp_count with=$exp_pass_s/$exp_count ($exp_ds) discriminating=$exp_disc/$exp_count"
        fi
    fi

    # An eval nothing graded (only expectations, run with --no-llm) says
    # nothing either way and is not reported as evidence-free.
    if [[ "$eval_graded" -gt 0 && "$eval_disc" -eq 0 ]]; then
        EVALS_WITHOUT_DELTA+=("$name")
    fi
done

echo ""
if [[ "$TOTAL_CHECKS" -gt 0 ]]; then
    echo "REGEX TOTALS: without=$TOTAL_WITHOUT/$TOTAL_CHECKS  with=$TOTAL_WITH/$TOTAL_CHECKS"
    echo "| | **REGEX TOTAL** | | **$TOTAL_WITHOUT/$TOTAL_CHECKS** | **$TOTAL_WITH/$TOTAL_CHECKS** | **+$((TOTAL_WITH - TOTAL_WITHOUT))** |" >> "$SUMMARY_FILE"
fi
if [[ "$TOTAL_EXPECTATIONS" -gt 0 ]]; then
    echo "LLM TOTALS: without=$TOTAL_EXP_WITHOUT/$TOTAL_EXPECTATIONS  with=$TOTAL_EXP_WITH/$TOTAL_EXPECTATIONS"
    echo "| | **LLM TOTAL** | | **$TOTAL_EXP_WITHOUT/$TOTAL_EXPECTATIONS** | **$TOTAL_EXP_WITH/$TOTAL_EXPECTATIONS** | **+$((TOTAL_EXP_WITH - TOTAL_EXP_WITHOUT))** |" >> "$SUMMARY_FILE"
fi

COMBINED_WITHOUT=$((TOTAL_WITHOUT + TOTAL_EXP_WITHOUT))
COMBINED_WITH=$((TOTAL_WITH + TOTAL_EXP_WITH))
COMBINED_TOTAL=$((TOTAL_CHECKS + TOTAL_EXPECTATIONS))
if [[ "$COMBINED_TOTAL" -gt 0 ]]; then
    echo "COMBINED: without=$COMBINED_WITHOUT/$COMBINED_TOTAL  with=$COMBINED_WITH/$COMBINED_TOTAL"
    echo "| | **COMBINED** | | **$COMBINED_WITHOUT/$COMBINED_TOTAL** | **$COMBINED_WITH/$COMBINED_TOTAL** | **+$((COMBINED_WITH - COMBINED_WITHOUT))** |" >> "$SUMMARY_FILE"
fi

cat "$SUMMARY_FILE"

# Emit machine-readable totals with a provenance block
# (consumed by scripts/merge-ab-results.py)
SKILL_REPO_SHA=$(git -C "$(dirname "$SKILL_FILE")" rev-parse HEAD 2>/dev/null || echo "unknown")
RUNNER_REPO_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
RUNNER_SCRIPT_SHA=$(git hash-object "$0" 2>/dev/null || echo "unknown")
# Content id of the eval set: two runs quoting the same delta must be able to
# show they graded the same questions, and a path alone cannot.
EVALS_SHA=$(git hash-object "$EVALS_FILE" 2>/dev/null || echo "unknown")
RUN_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ "$NO_LLM" == "true" ]]; then AB_GRADED_LLM_VALUE=false; else AB_GRADED_LLM_VALUE=true; fi
AB_NO_DELTA_VALUE=$(printf '%s\n' "${EVALS_WITHOUT_DELTA[@]+"${EVALS_WITHOUT_DELTA[@]}"}")
AB_UNMEASURED_VALUE=$(printf '%s\n' "${EVALS_UNMEASURED[@]+"${EVALS_UNMEASURED[@]}"}")

export AB_OUT="$RESULTS_DIR/ab-results.json" \
    AB_RUN_DATE="$RUN_DATE" \
    AB_MODEL="$EVAL_MODEL" \
    AB_GRADER_MODEL="$GRADER_MODEL" \
    AB_HARNESS="$HARNESS_VERSION" \
    AB_SKILL_VERSION="$SKILL_VERSION" \
    AB_SKILL_FILE="$SKILL_FILE" \
    AB_SKILL_REPO_SHA="$SKILL_REPO_SHA" \
    AB_RUNNER_REPO_SHA="$RUNNER_REPO_SHA" \
    AB_RUNNER_SCRIPT_SHA="$RUNNER_SCRIPT_SHA" \
    AB_EVALS_FILE="$EVALS_FILE" \
    AB_EVALS_SHA="$EVALS_SHA" \
    AB_EVAL_COUNT="$EVAL_COUNT" \
    AB_GRADED_LLM="$AB_GRADED_LLM_VALUE" \
    AB_REGEX_WITHOUT="$TOTAL_WITHOUT" AB_REGEX_WITH="$TOTAL_WITH" AB_REGEX_CHECKS="$TOTAL_CHECKS" \
    AB_LLM_WITHOUT="$TOTAL_EXP_WITHOUT" AB_LLM_WITH="$TOTAL_EXP_WITH" AB_LLM_CHECKS="$TOTAL_EXPECTATIONS" \
    AB_COMBINED_WITHOUT="$COMBINED_WITHOUT" AB_COMBINED_WITH="$COMBINED_WITH" AB_COMBINED_CHECKS="$COMBINED_TOTAL" \
    AB_DISCRIMINATING="$TOTAL_DISCRIMINATING" \
    AB_UNMEASURED="$AB_UNMEASURED_VALUE" \
    AB_NO_DELTA="$AB_NO_DELTA_VALUE"

python3 <<'PYEOF'
import json
import os

no_delta = [line for line in os.environ["AB_NO_DELTA"].splitlines() if line]
unmeasured = [line for line in os.environ["AB_UNMEASURED"].splitlines() if line]

with open(os.environ["AB_OUT"], "w") as f:
    json.dump({
        # The actor tuple a delta belongs to. Reporting a number without it
        # states a property of the skill, which is not what was measured.
        "provenance": {
            "run_date": os.environ["AB_RUN_DATE"],
            "model": os.environ["AB_MODEL"],
            "grader_model": os.environ["AB_GRADER_MODEL"],
            "harness": os.environ["AB_HARNESS"],
            "skill_version": os.environ["AB_SKILL_VERSION"],
            "skill_file": os.environ["AB_SKILL_FILE"],
            "skill_repo_commit": os.environ["AB_SKILL_REPO_SHA"],
            "runner_commit": os.environ["AB_RUNNER_REPO_SHA"],
            "runner_script_sha": os.environ["AB_RUNNER_SCRIPT_SHA"],
            "eval_set": {
                "path": os.environ["AB_EVALS_FILE"],
                "sha": os.environ["AB_EVALS_SHA"],
                "count": int(os.environ["AB_EVAL_COUNT"]),
            },
            "llm_grading": os.environ["AB_GRADED_LLM"] == "true",
        },
        "eval_count": int(os.environ["AB_EVAL_COUNT"]),
        "totals": {
            "regex": {
                "without": int(os.environ["AB_REGEX_WITHOUT"]),
                "with": int(os.environ["AB_REGEX_WITH"]),
                "checks": int(os.environ["AB_REGEX_CHECKS"]),
            },
            "llm": {
                "without": int(os.environ["AB_LLM_WITHOUT"]),
                "with": int(os.environ["AB_LLM_WITH"]),
                "checks": int(os.environ["AB_LLM_CHECKS"]),
            },
            "combined": {
                "without": int(os.environ["AB_COMBINED_WITHOUT"]),
                "with": int(os.environ["AB_COMBINED_WITH"]),
                "checks": int(os.environ["AB_COMBINED_CHECKS"]),
            },
        },
        # Checks the baseline fails and the skill run passes. An eval with
        # none of them cannot support a claim that the skill changed anything.
        "discriminating_checks": int(os.environ["AB_DISCRIMINATING"]),
        "evals_without_delta": no_delta,
        # Pairs where at least one arm carried no answer at all. Unknown, not
        # evidence-free: excluded from the totals and from --require-delta.
        "evals_unmeasured": unmeasured,
    }, f, indent=2)
    f.write("\n")
PYEOF

echo ""
echo "Measured: $(basename "$(dirname "$SKILL_FILE")")@${SKILL_VERSION} · ${HARNESS_VERSION} · model ${EVAL_MODEL} (judge ${GRADER_MODEL}) · eval-set $(basename "$EVALS_FILE")@${EVALS_SHA:0:8} (${EVAL_COUNT} evals)"
echo "Discriminating checks (baseline fails, skill passes): $TOTAL_DISCRIMINATING"
echo "Quote the delta with that tuple, not on its own."

if [[ ${#EVALS_UNMEASURED[@]} -gt 0 ]]; then
    echo ""
    echo "${#EVALS_UNMEASURED[@]} eval(s) NOT MEASURED — an arm carried no answer, so they say"
    echo "nothing in either direction and are excluded from the totals above:"
    printf '  - %s\n' "${EVALS_UNMEASURED[@]}"
    echo "Re-run these before quoting the delta as complete."
fi

if [[ ${#EVALS_WITHOUT_DELTA[@]} -gt 0 ]]; then
    echo ""
    echo "${#EVALS_WITHOUT_DELTA[@]} eval(s) with no discriminating check — the baseline"
    echo "answered them as well as the skill run, so they are not evidence for the skill:"
    printf '  - %s\n' "${EVALS_WITHOUT_DELTA[@]}"
fi

echo ""
echo "Results JSON: $RESULTS_DIR/ab-results.json"

if [[ "$REQUIRE_DELTA" == "true" ]]; then
    # A run that measured nothing must not pass the gate: without this floor an
    # entirely limit-blocked run reports zero evidence-free evals and exits 0.
    measured=$((EVAL_COUNT - ${#EVALS_UNMEASURED[@]}))
    if [[ "$measured" -le 0 ]]; then
        echo "::error::--require-delta: nothing was measured — every eval pair carried a non-answer"
        exit 1
    fi
    if [[ ${#EVALS_WITHOUT_DELTA[@]} -gt 0 ]]; then
        echo "::error::--require-delta: ${#EVALS_WITHOUT_DELTA[@]} of ${measured} measured eval(s) have no assertion the no-skill baseline fails"
        exit 1
    fi
fi
