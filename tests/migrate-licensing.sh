#!/usr/bin/env bash
# tests/migrate-licensing.sh — exercises scripts/migrate-licensing.sh, which
# rewrites a repo's licensing in place (creates the split files, deletes the
# bare LICENSE, rewrites the README's License section).
#
# A script that deletes a file and rewrites a README had no test at all. The
# fixtures below are throwaway directories, never the repo itself.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/skills/skill-repo/scripts/migrate-licensing.sh"
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

# fixture <name> <license-kind: mit|gpl>
fixture() {
    local d="$WORK/$1"
    mkdir -p "$d"
    if [ "$2" = "gpl" ]; then
        printf 'GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n' > "$d/LICENSE"
    else
        printf 'MIT License\n\nCopyright (c) 2024 Someone\n' > "$d/LICENSE"
    fi
    cat > "$d/README.md" <<'EOF'
# Demo

## License

MIT — see LICENSE.

## Something else

Untouched.
EOF
    echo "$d"
}

echo "migrate-licensing.sh"

# --- 1. an MIT repo keeps its MIT text and gains the split ------------------
repo=$(fixture mit mit)
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "exits cleanly on an MIT repo" 0 "$?"
check "LICENSE-MIT created"          yes "$([ -f "$repo/LICENSE-MIT" ] && echo yes || echo no)"
check "LICENSE-CC-BY-SA-4.0 created" yes "$([ -f "$repo/LICENSE-CC-BY-SA-4.0" ] && echo yes || echo no)"
check "the bare LICENSE is gone"     yes "$([ -f "$repo/LICENSE" ] && echo no || echo yes)"
# The holder is preserved and only the year is extended — a foreign copyright
# notice must never be replaced by Netresearch's.
check "the original copyright holder survives" yes \
    "$(grep -q 'Someone' "$repo/LICENSE-MIT" && echo yes || echo no)"
check "the year range is extended to 2026" yes \
    "$(grep -q 'Copyright (c) 2024-2026 Someone' "$repo/LICENSE-MIT" && echo yes || echo no)"
check "the unrelated README section survives" yes \
    "$(grep -q '## Something else' "$repo/README.md" && echo yes || echo no)"

# --- 2. a GPL repo gets MIT written from scratch, not copied ----------------
repo=$(fixture gpl gpl)
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "exits cleanly on a GPL repo" 0 "$?"
check "GPL text is not carried into LICENSE-MIT" yes \
    "$(grep -q 'GNU GENERAL PUBLIC' "$repo/LICENSE-MIT" && echo no || echo yes)"
check "LICENSE-MIT is an MIT licence" yes \
    "$(grep -q 'MIT License' "$repo/LICENSE-MIT" && echo yes || echo no)"

# --- 3. rerunning is not destructive ----------------------------------------
before=$(cat "$repo/LICENSE-MIT")
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "a second run leaves LICENSE-MIT unchanged" "$before" "$(cat "$repo/LICENSE-MIT")"

echo
if [ "$fail" -eq 0 ]; then
    echo "All migrate-licensing tests passed"
else
    echo "Some migrate-licensing tests FAILED"
fi
exit "$fail"
