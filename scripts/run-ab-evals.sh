#!/bin/bash
# run-ab-evals.sh - A/B test evals WITHOUT vs WITH skill context
# Usage: ./scripts/run-ab-evals.sh [--no-llm] [concurrency]
# Default concurrency: 4 (parallel eval pairs)
# --no-llm: Skip LLM-based grading of expectations (regex assertions only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_FILE="$REPO_DIR/skills/skill-repo/evals/evals.json"
SKILL_FILE="$REPO_DIR/skills/skill-repo/SKILL.md"
RESULTS_DIR="$REPO_DIR/scripts/ab-results"

# Parse flags
NO_LLM=false
CONCURRENCY=4
for arg in "$@"; do
    case "$arg" in
        --no-llm) NO_LLM=true ;;
        [0-9]*) CONCURRENCY="$arg" ;;
    esac
done

mkdir -p "$RESULTS_DIR"

EVAL_COUNT=$(python3 -c "import json; print(len(json.load(open('$EVALS_FILE'))))")
echo "Found $EVAL_COUNT evals, concurrency=$CONCURRENCY"

run_single() {
    local idx="$1"
    local mode="$2"
    local name prompt output_file

    name=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$idx]['name'])")
    prompt=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$idx]['prompt'])")
    output_file="$RESULTS_DIR/${name}_${mode}.txt"

    if [[ "$mode" == "without" ]]; then
        timeout 90 claude -p \
            --no-session-persistence \
            --disable-slash-commands \
            --tools "" \
            --model sonnet \
            "$prompt" \
            > "$output_file" 2>/dev/null || true
    else
        timeout 90 claude -p \
            --no-session-persistence \
            --disable-slash-commands \
            --tools "" \
            --model sonnet \
            --append-system-prompt "$(cat "$SKILL_FILE")" \
            "$prompt" \
            > "$output_file" 2>/dev/null || true
    fi
}

run_pair() {
    local idx="$1"
    local name
    name=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$idx]['name'])")
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

    name=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$idx]['name'])")
    prompt=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$idx]['prompt'])")
    output_file="$RESULTS_DIR/${name}_${mode}.txt"
    grader_file="$RESULTS_DIR/${name}_${mode}_expectations.txt"

    # Get expectations as numbered list
    expectations_count=$(python3 -c "
import json
exps = json.load(open('$EVALS_FILE'))[$idx].get('expectations', [])
print(len(exps))
")

    if [[ "$expectations_count" -eq 0 ]]; then
        return
    fi

    local expectations_list
    expectations_list=$(python3 -c "
import json
exps = json.load(open('$EVALS_FILE'))[$idx].get('expectations', [])
for i, e in enumerate(exps, 1):
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
        --model haiku \
        "$grading_prompt" \
        > "$grader_file" 2>/dev/null || true
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
evals = json.load(open('$EVALS_FILE'))
print('yes' if any(e.get('expectations') for e in evals) else 'no')
")
    if [[ "$HAS_ANY_EXPECTATIONS" == "yes" ]]; then
        echo ""
        echo "=== LLM Grading (expectations) ==="
        for batch_start in $(seq 0 "$CONCURRENCY" $((EVAL_COUNT - 1))); do
            batch_end=$((batch_start + CONCURRENCY - 1))
            [[ $batch_end -ge $EVAL_COUNT ]] && batch_end=$((EVAL_COUNT - 1))

            for i in $(seq "$batch_start" "$batch_end"); do
                exp_count=$(python3 -c "import json; print(len(json.load(open('$EVALS_FILE'))[$i].get('expectations', [])))")
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

for i in $(seq 0 $((EVAL_COUNT - 1))); do
    name=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$i]['name'])")

    without_file="$RESULTS_DIR/${name}_without.txt"
    with_file="$RESULTS_DIR/${name}_with.txt"

    # Check regex assertions
    assertion_count=$(python3 -c "import json; print(len(json.load(open('$EVALS_FILE'))[$i].get('assertions', [])))")
    if [[ "$assertion_count" -gt 0 ]]; then
        pass_w=0; pass_s=0; total=0
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            ((total++)) || true
            grep -qiE "$pattern" "$without_file" 2>/dev/null && ((pass_w++)) || true
            grep -qiE "$pattern" "$with_file" 2>/dev/null && ((pass_s++)) || true
        done <<< "$(python3 -c "
import json
evals = json.load(open('$EVALS_FILE'))
for a in evals[$i].get('assertions', []):
    print(a.get('pattern', ''))
")"

        delta=$((pass_s - pass_w))
        [[ $delta -gt 0 ]] && ds="+$delta" || ds="$delta"

        TOTAL_WITHOUT=$((TOTAL_WITHOUT + pass_w))
        TOTAL_WITH=$((TOTAL_WITH + pass_s))
        TOTAL_CHECKS=$((TOTAL_CHECKS + total))

        echo "| $((i+1)) | $name | regex | $pass_w/$total | $pass_s/$total | $ds |" >> "$SUMMARY_FILE"
        echo "  $name [regex]: without=$pass_w/$total with=$pass_s/$total ($ds)"
    fi

    # Check LLM-graded expectations
    exp_count=$(python3 -c "import json; print(len(json.load(open('$EVALS_FILE'))[$i].get('expectations', [])))")
    if [[ "$exp_count" -gt 0 ]]; then
        if [[ "$NO_LLM" == "true" ]]; then
            echo "| $((i+1)) | $name | llm | skipped | skipped | -- |" >> "$SUMMARY_FILE"
            echo "  $name [llm]: skipped (--no-llm)"
        else
            exp_pass_w=$(count_expectation_passes "$RESULTS_DIR/${name}_without_expectations.txt")
            exp_pass_s=$(count_expectation_passes "$RESULTS_DIR/${name}_with_expectations.txt")

            exp_delta=$((exp_pass_s - exp_pass_w))
            [[ $exp_delta -gt 0 ]] && exp_ds="+$exp_delta" || exp_ds="$exp_delta"

            TOTAL_EXP_WITHOUT=$((TOTAL_EXP_WITHOUT + exp_pass_w))
            TOTAL_EXP_WITH=$((TOTAL_EXP_WITH + exp_pass_s))
            TOTAL_EXPECTATIONS=$((TOTAL_EXPECTATIONS + exp_count))

            echo "| $((i+1)) | $name | llm | $exp_pass_w/$exp_count | $exp_pass_s/$exp_count | $exp_ds |" >> "$SUMMARY_FILE"
            echo "  $name [llm]: without=$exp_pass_w/$exp_count with=$exp_pass_s/$exp_count ($exp_ds)"
        fi
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
