#!/usr/bin/env bash
# Generate/validate the skill effectiveness dashboard from results.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_FILE="$ROOT_DIR/docs/dashboard/data/results.json"
HTML_FILE="$ROOT_DIR/docs/dashboard/index.html"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }

# Validate JSON
if [[ ! -f "$DATA_FILE" ]]; then
    err "Results file not found: $DATA_FILE"
    exit 1
fi

if ! python3 -c "import json; json.load(open('$DATA_FILE'))" 2>/dev/null; then
    err "Invalid JSON in $DATA_FILE"
    exit 1
fi
ok "Valid JSON: $DATA_FILE"

# Extract stats
STATS=$(python3 << PYEOF
import json, sys

with open("$DATA_FILE") as f:
    data = json.load(f)

skills = data["skills"]
total_skills = len(skills)
total_evals = sum(s["eval_count"] for s in skills)
avg_delta = sum(s["results"]["opus"]["delta"] for s in skills) / total_skills
perfect = sum(1 for s in skills if s["results"]["opus"]["with_skill_pass_rate"] >= 1.0)
categories = {}
for s in skills:
    cat = s["category"]
    categories.setdefault(cat, []).append(s["results"]["opus"]["delta"])

print(f"Generated:     {data['generated']}")
print(f"Total skills:  {total_skills}")
print(f"Total evals:   {total_evals}")
print(f"Avg delta:     +{avg_delta*100:.1f}%")
print(f"100% pass:     {perfect}/{total_skills}")
print()
print("Category breakdown:")
for cat, deltas in sorted(categories.items(), key=lambda x: -sum(x[1])/len(x[1])):
    avg = sum(deltas) / len(deltas)
    print(f"  {cat:15s} {len(deltas):2d} skills  avg +{avg*100:.0f}%")

best = max(skills, key=lambda s: s["results"]["opus"]["delta"])
worst = min(skills, key=lambda s: s["results"]["opus"]["delta"])
print()
print(f"Highest delta: {best['name']} (+{best['results']['opus']['delta']*100:.0f}%)")
print(f"Lowest delta:  {worst['name']} (+{worst['results']['opus']['delta']*100:.0f}%)")
PYEOF
)

echo ""
echo -e "${BOLD}Dashboard Statistics${NC}"
echo "──────────────────────────────────"
echo "$STATS"
echo ""

# Check HTML exists
if [[ -f "$HTML_FILE" ]]; then
    ok "Dashboard HTML: $HTML_FILE"
else
    err "Dashboard HTML not found: $HTML_FILE"
    exit 1
fi

info "Dashboard ready at: file://$HTML_FILE"
