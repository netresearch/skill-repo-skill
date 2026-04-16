#!/bin/bash
# validate-evals.sh - Structural validation of evals.json files
# Supports three formats:
#   Unified (recommended): {"skill_name": "...", "evals": [{id, eval_name, prompt,
#       expected_output?, expectations?: ["..."], assertions?: [{type, pattern}]}]}
#     - Evals may use expectations (string[], LLM-as-judge), assertions (object[],
#       regex matching), or both. At least one grading mechanism is required.
#   Legacy A: {"skill_name": "...", "evals": [{id, eval_name, prompt, assertions: [...]}]}
#   Legacy B: [{name, prompt, assertions: [{type, value/pattern, description?}]}]
#
# Usage: bash validate-evals.sh [path-to-evals.json]
#   If no path given, searches skills/*/evals/evals.json then evals/evals.json

set -euo pipefail

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
warn() { WARN=$((WARN + 1)); echo "  WARN: $1"; }

# --- Locate evals.json ---
EVALS_FILE="${1:-}"
if [[ -z "$EVALS_FILE" ]]; then
  for candidate in skills/*/evals/evals.json evals/evals.json; do
    if [[ -f "$candidate" ]]; then
      EVALS_FILE="$candidate"
      break
    fi
  done
fi

if [[ -z "$EVALS_FILE" ]] || [[ ! -f "$EVALS_FILE" ]]; then
  echo "ERROR: No evals.json found"
  echo "Searched: skills/*/evals/evals.json, evals/evals.json"
  exit 1
fi

echo "Validating: $EVALS_FILE"
echo "---"

# --- Valid JSON ---
if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$EVALS_FILE" 2>/dev/null; then
  fail "Invalid JSON"
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
  exit 1
fi
pass "Valid JSON"

# --- Run all structural checks via Python ---
RESULT=$(python3 - "$EVALS_FILE" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    raw = json.load(f)

# Detect format and normalize to list of evals
if isinstance(raw, dict) and "evals" in raw:
    # Format A: {skill_name, evals: [...]}
    evals = raw["evals"]
    fmt = "A"
elif isinstance(raw, list):
    # Format B: [...]
    evals = raw
    fmt = "B"
else:
    print("FAIL|Top-level structure must be an array or object with 'evals' key")
    sys.exit(0)

print(f"INFO|Detected format {'A (object with evals key)' if fmt == 'A' else 'B (top-level array)'}")
print(f"INFO|Total evals: {len(evals)}")

if not isinstance(evals, list):
    print("FAIL|'evals' must be an array")
    sys.exit(0)

if len(evals) == 0:
    print("FAIL|No evals found")
    sys.exit(0)

# Check eval count thresholds
if len(evals) < 10:
    print(f"FAIL|Eval count {len(evals)} < 10 minimum")
elif len(evals) < 15:
    print(f"WARN|Eval count {len(evals)} < 15 recommended")
else:
    print(f"PASS|Eval count {len(evals)} >= 15")

# Track names for duplicate check
names = []
ids_found = []
has_ids = False

for i, ev in enumerate(evals):
    label = f"eval[{i}]"

    if not isinstance(ev, dict):
        print(f"FAIL|{label}: not an object")
        continue

    # Name/ID check: accept 'name', 'eval_name', or 'id' (integer) as identifier
    name = str(ev.get("name") or ev.get("eval_name") or "").strip()
    if not name:
        # Fall back to id as identifier for Anthropic format
        eid = ev.get("id")
        if isinstance(eid, int):
            name = f"id={eid}"
        else:
            print(f"FAIL|{label}: missing or empty name/eval_name/id")
    if name:
        names.append(name)

    # Prompt check (accept 'prompt' or legacy 'input')
    prompt = ev.get("prompt") or ev.get("input") or ""
    if not prompt or not str(prompt).strip():
        print(f"FAIL|{label} ({name}): missing or empty prompt/input")
    else:
        print(f"PASS|{label} ({name}): has prompt")

    # ID check (optional but validated if present; must be integer)
    if "id" in ev:
        if not isinstance(ev["id"], int):
            print(f"FAIL|{label} ({name}): id must be an integer")
        else:
            has_ids = True
            ids_found.append(ev["id"])

    # expected_output check (recommended for unified format, skip for legacy)
    is_unified = any(key in ev for key in ("eval_name", "id", "expectations", "expected_output"))
    if is_unified and "expected_output" not in ev:
        print(f"WARN|{label} ({name}): missing expected_output (recommended)")

    # Grading check: must have expectations OR assertions (or both)
    expectations = ev.get("expectations")
    assertions = ev.get("assertions")
    has_expectations = False
    has_assertions = False

    # Validate expectations (string[], 2+ items)
    if expectations is not None:
        if not isinstance(expectations, list):
            print(f"FAIL|{label} ({name}): expectations must be an array")
        elif len(expectations) < 2:
            print(f"FAIL|{label} ({name}): has {len(expectations)} expectations, need >= 2")
        else:
            invalid_exp = 0
            for j, e in enumerate(expectations):
                if not isinstance(e, str):
                    invalid_exp += 1
                    print(f"FAIL|{label} ({name}): expectations[{j}] must be a string")
                elif not e.strip():
                    invalid_exp += 1
                    print(f"FAIL|{label} ({name}): expectations[{j}] is empty")
            if invalid_exp == 0:
                has_expectations = True
                print(f"PASS|{label} ({name}): {len(expectations)} valid expectations")

    # Validate assertions (object[] or string[], 2+ items)
    if assertions is not None:
        if not isinstance(assertions, list):
            print(f"FAIL|{label} ({name}): assertions must be an array")
        elif len(assertions) < 2:
            print(f"FAIL|{label} ({name}): has {len(assertions)} assertions, need >= 2")
        else:
            invalid_assertions = 0
            for j, a in enumerate(assertions):
                if isinstance(a, str):
                    if not a.strip():
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): assertion[{j}] is empty")
                elif isinstance(a, dict):
                    if "type" not in a:
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): assertion[{j}] missing 'type'")
                    val = a.get("value") or a.get("pattern") or ""
                    if not str(val).strip():
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): assertion[{j}] missing 'value' or 'pattern'")
                else:
                    invalid_assertions += 1
                    print(f"FAIL|{label} ({name}): assertion[{j}] invalid type (not string or object)")

            if invalid_assertions == 0:
                has_assertions = True
                print(f"PASS|{label} ({name}): {len(assertions)} valid assertions")

    # Must have at least one grading mechanism
    if not has_expectations and not has_assertions:
        if expectations is None and assertions is None:
            print(f"FAIL|{label} ({name}): missing grading (need expectations or assertions)")
        # else: already reported specific validation errors above

# Duplicate names
seen = set()
dupes = set()
for n in names:
    if n in seen:
        dupes.add(n)
    seen.add(n)

if dupes:
    print(f"FAIL|Duplicate eval names: {', '.join(sorted(dupes))}")
else:
    print(f"PASS|No duplicate eval names")

# ID validation (if IDs are present)
if has_ids:
    # Check for duplicates
    id_counts = {}
    for eid in ids_found:
        id_counts[eid] = id_counts.get(eid, 0) + 1
    dupe_ids = [k for k, v in id_counts.items() if v > 1]
    if dupe_ids:
        print(f"FAIL|Duplicate IDs: {dupe_ids}")
    else:
        print(f"PASS|No duplicate IDs")

    # Check sequential (1-based)
    numeric_ids = sorted([x for x in ids_found if isinstance(x, int)])
    if numeric_ids:
        expected = list(range(1, len(numeric_ids) + 1))
        if numeric_ids != expected:
            gaps = set(expected) - set(numeric_ids)
            extra = set(numeric_ids) - set(expected)
            msg = ""
            if gaps:
                msg += f"missing: {sorted(gaps)}"
            if extra:
                if msg:
                    msg += ", "
                msg += f"unexpected: {sorted(extra)}"
            print(f"FAIL|IDs not sequential: {msg}")
        else:
            print(f"PASS|IDs sequential (1-{len(numeric_ids)})")
PYEOF
)

# --- Parse Python output ---
while IFS='|' read -r level msg; do
  case "$level" in
    PASS) pass "$msg" ;;
    FAIL) fail "$msg" ;;
    WARN) warn "$msg" ;;
    INFO) echo "  INFO: $msg" ;;
  esac
done <<< "$RESULT"

# --- Summary ---
echo ""
echo "---"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

exit 0
