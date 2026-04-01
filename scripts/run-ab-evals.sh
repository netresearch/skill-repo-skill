#!/bin/bash
# run-ab-evals.sh - A/B test evals WITHOUT vs WITH skill context
# Usage: ./scripts/run-ab-evals.sh [concurrency]
# Default concurrency: 4 (parallel eval pairs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_FILE="$REPO_DIR/skills/skill-repo/evals/evals.json"
SKILL_FILE="$REPO_DIR/skills/skill-repo/SKILL.md"
RESULTS_DIR="$REPO_DIR/scripts/ab-results"
CONCURRENCY="${1:-4}"

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

# Analyze results
echo ""
echo "=== RESULTS ==="

SUMMARY_FILE="$RESULTS_DIR/summary.md"
cat > "$SUMMARY_FILE" << 'EOF'
| # | Eval | Without | With | Delta |
|---|------|---------|------|-------|
EOF

TOTAL_WITHOUT=0
TOTAL_WITH=0
TOTAL_ASSERTIONS=0

for i in $(seq 0 $((EVAL_COUNT - 1))); do
    name=$(python3 -c "import json; print(json.load(open('$EVALS_FILE'))[$i]['name'])")

    without_file="$RESULTS_DIR/${name}_without.txt"
    with_file="$RESULTS_DIR/${name}_with.txt"

    without_words=$(wc -w < "$without_file" 2>/dev/null || echo 0)
    with_words=$(wc -w < "$with_file" 2>/dev/null || echo 0)

    # Check assertions
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
    TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + total))

    echo "| $((i+1)) | $name | $pass_w/$total | $pass_s/$total | $ds |" >> "$SUMMARY_FILE"
    echo "  $name: without=$pass_w/$total with=$pass_s/$total ($ds)"
done

echo ""
echo "TOTALS: without=$TOTAL_WITHOUT/$TOTAL_ASSERTIONS  with=$TOTAL_WITH/$TOTAL_ASSERTIONS"
echo "| | **TOTAL** | **$TOTAL_WITHOUT/$TOTAL_ASSERTIONS** | **$TOTAL_WITH/$TOTAL_ASSERTIONS** | **+$((TOTAL_WITH - TOTAL_WITHOUT))** |" >> "$SUMMARY_FILE"

cat "$SUMMARY_FILE"
