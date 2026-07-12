#!/bin/bash
# run-ab-evals.sh - A/B test evals WITHOUT vs WITH skill context
# Usage: ./scripts/run-ab-evals.sh [--no-llm] [concurrency]
# Default concurrency: 4 (parallel eval pairs)
# --no-llm: Skip LLM-based grading of expectations (regex assertions only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags and positional args
NO_LLM=false
CONCURRENCY=4
EVALS_FILE=""
SKILL_FILE=""
for arg in "$@"; do
    case "$arg" in
        --no-llm) NO_LLM=true ;;
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

    if [[ "$mode" == "without" ]]; then
        timeout 90 claude -p \
            --no-session-persistence \
            --disable-slash-commands \
            --tools "" \
            --model "$EVAL_MODEL" \
            "$prompt" \
            > "$output_file" 2>/dev/null || true
    else
        timeout 90 claude -p \
            --no-session-persistence \
            --disable-slash-commands \
            --tools "" \
            --model "$EVAL_MODEL" \
            --append-system-prompt "$(cat "$SKILL_FILE")" \
            "$prompt" \
            > "$output_file" 2>/dev/null || true
    fi
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
        --model "$GRADER_MODEL" \
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

for i in $(seq 0 $((EVAL_COUNT - 1))); do
    name=$(get_eval_name "$i")

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
        pass_w=0; pass_s=0; total=0
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            # Strip PCRE inline flags (e.g. (?i)) — grep -i already handles case
            pattern="${pattern#'(?i)'}"
            ((total++)) || true
            grep -qiE "$pattern" "$without_file" 2>/dev/null && ((pass_w++)) || true
            grep -qiE "$pattern" "$with_file" 2>/dev/null && ((pass_s++)) || true
        done <<< "$(python3 -c "
import json
raw = json.load(open('$EVALS_FILE'))
evals = raw['evals'] if isinstance(raw, dict) and 'evals' in raw else raw
for a in evals[$i].get('assertions', []):
    print(a.get('value') or a.get('pattern') or '')
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

# Emit machine-readable totals with a provenance block
# (consumed by scripts/merge-ab-results.py)
SKILL_REPO_SHA=$(git -C "$(dirname "$SKILL_FILE")" rev-parse HEAD 2>/dev/null || echo "unknown")
RUNNER_REPO_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
RUNNER_SCRIPT_SHA=$(git hash-object "$0" 2>/dev/null || echo "unknown")
RUN_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - "$RESULTS_DIR/ab-results.json" \
    "$RUN_DATE" \
    "$EVAL_MODEL" \
    "$GRADER_MODEL" \
    "$SKILL_REPO_SHA" \
    "$RUNNER_REPO_SHA" \
    "$RUNNER_SCRIPT_SHA" \
    "$EVAL_COUNT" \
    "$TOTAL_WITHOUT" "$TOTAL_WITH" "$TOTAL_CHECKS" \
    "$TOTAL_EXP_WITHOUT" "$TOTAL_EXP_WITH" "$TOTAL_EXPECTATIONS" \
    "$COMBINED_WITHOUT" "$COMBINED_WITH" "$COMBINED_TOTAL" <<'PYEOF'
import json, sys

with open(sys.argv[1], "w") as f:
    json.dump({
        "provenance": {
            "run_date": sys.argv[2],
            "model": sys.argv[3],
            "grader_model": sys.argv[4],
            "skill_repo_commit": sys.argv[5],
            "runner_commit": sys.argv[6],
            "runner_script_sha": sys.argv[7],
        },
        "eval_count": int(sys.argv[8]),
        "totals": {
            "regex": {"without": int(sys.argv[9]), "with": int(sys.argv[10]), "checks": int(sys.argv[11])},
            "llm": {"without": int(sys.argv[12]), "with": int(sys.argv[13]), "checks": int(sys.argv[14])},
            "combined": {"without": int(sys.argv[15]), "with": int(sys.argv[16]), "checks": int(sys.argv[17])},
        },
    }, f, indent=2)
    f.write("\n")
PYEOF
echo ""
echo "Results JSON: $RESULTS_DIR/ab-results.json"
