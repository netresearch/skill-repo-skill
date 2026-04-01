#!/bin/bash
# validate-evals.sh - Structural validation of evals.json files
# Supports two formats:
#   Format A: {"skill_name": "...", "evals": [{id, eval_name, prompt, assertions: ["..."]}]}
#   Format B: [{name, prompt, assertions: [{type, value/pattern, description?}]}]
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

    # Name check (supports both 'name' and 'eval_name')
    name = ev.get("name") or ev.get("eval_name") or ""
    if not name or not str(name).strip():
        print(f"FAIL|{label}: missing or empty name/eval_name")
    else:
        names.append(str(name).strip())

    # Prompt check
    prompt = ev.get("prompt", "")
    if not prompt or not str(prompt).strip():
        print(f"FAIL|{label} ({name}): missing or empty prompt")
    else:
        print(f"PASS|{label} ({name}): has prompt")

    # ID check (optional but validated if present)
    if "id" in ev:
        has_ids = True
        ids_found.append(ev["id"])

    # Assertions check
    assertions = ev.get("assertions")
    if assertions is None:
        print(f"FAIL|{label} ({name}): missing assertions")
        continue

    if not isinstance(assertions, list):
        print(f"FAIL|{label} ({name}): assertions must be an array")
        continue

    if len(assertions) < 2:
        print(f"FAIL|{label} ({name}): has {len(assertions)} assertions, need >= 2")
        continue

    # Validate assertion contents
    empty_assertions = 0
    for j, a in enumerate(assertions):
        if isinstance(a, str):
            if not a.strip():
                empty_assertions += 1
        elif isinstance(a, dict):
            # Object assertions: need at least type + (value or pattern)
            if "type" not in a:
                print(f"FAIL|{label} ({name}): assertion[{j}] missing 'type'")
            val = a.get("value") or a.get("pattern") or ""
            if not str(val).strip():
                print(f"FAIL|{label} ({name}): assertion[{j}] missing 'value' or 'pattern'")
        else:
            print(f"FAIL|{label} ({name}): assertion[{j}] invalid type (not string or object)")

    if empty_assertions > 0:
        print(f"FAIL|{label} ({name}): {empty_assertions} empty string assertion(s)")
    else:
        print(f"PASS|{label} ({name}): {len(assertions)} valid assertions")

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
