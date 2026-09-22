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
NOW="$(date +%Y)"
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
check "the year range is extended to the current year" yes \
    "$(grep -q "Copyright (c) 2024-$NOW Someone" "$repo/LICENSE-MIT" && echo yes || echo no)"
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

# A rerun on a migrated MIT repo must keep the holder the first run preserved.
# The bare LICENSE is gone by then, and the from-scratch branch used to rewrite
# LICENSE-MIT with Netresearch as the copyright holder.
repo=$(fixture rerun_mit mit)
bash "$SCRIPT" "$repo" >/dev/null 2>&1
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "a rerun keeps a foreign copyright holder" yes \
    "$(grep -q 'Someone' "$repo/LICENSE-MIT" && echo yes || echo no)"

# --- 4. --help prints usage and touches nothing (issue #341) ----------------
# The flag used to be taken as the repository path: the script got as far as
# writing into a directory named `--help`.
cd "$WORK" || exit 1
out=$(bash "$SCRIPT" --help 2>&1); rc=$?
check "--help exits 0"                 0   "$rc"
check "--help prints the usage line"   yes "$(grep -q 'Usage:' <<<"$out" && echo yes || echo no)"
check "--help does not start a migration" yes "$(grep -q 'Migrating licensing' <<<"$out" && echo no || echo yes)"
bash "$SCRIPT" --bogus >/dev/null 2>&1
check "an unknown option exits 2"      2   "$?"
bash "$SCRIPT" "$WORK/does-not-exist" >/dev/null 2>&1
check "a missing directory exits 2"    2   "$?"

# --- 5. the years come from the repository (issue #341) ---------------------
# A repository whose first commit is from 2023 gets 2023-<now>, not a literal.
repo=$(fixture history gpl)
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty --date='2023-05-01T12:00:00' -m first
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "LICENSE-MIT carries the repository's own years" yes \
    "$(grep -q "Copyright (c) 2023-$NOW Netresearch DTT GmbH" "$repo/LICENSE-MIT" && echo yes || echo no)"
check "LICENSE-CC-BY-SA-4.0 carries the same years" yes \
    "$(grep -q "Copyright (c) 2023-$NOW Netresearch DTT GmbH" "$repo/LICENSE-CC-BY-SA-4.0" && echo yes || echo no)"

# An existing range is extended, not nested.
repo=$(fixture range mit)
printf 'MIT License\n\nCopyright (c) 2021-2022 Someone\n' > "$repo/LICENSE"
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "an existing year range is extended, not nested" "Copyright (c) 2021-$NOW Someone" \
    "$(grep -o 'Copyright (c) [0-9-]* Someone' "$repo/LICENSE-MIT")"

# Every notice is extended on its own: one already current must not stop the
# others. And a notice that starts this year stays one year, not "now-now".
repo=$(fixture two_notices mit)
printf 'MIT License\n\nCopyright (c) 2019 Someone\nCopyright (c) %s Other\n' "$NOW" > "$repo/LICENSE"
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "a stale notice beside a current one is still extended" yes \
    "$(grep -q "Copyright (c) 2019-$NOW Someone" "$repo/LICENSE-MIT" && echo yes || echo no)"
check "a notice from this year stays a single year" yes \
    "$(grep -qx "Copyright (c) $NOW Other" "$repo/LICENSE-MIT" && echo yes || echo no)"

# A shallow clone hides the first commit, so the years cannot be derived. The
# script refuses and writes nothing rather than stamping a wrong year.
src=$(fixture shallow_src gpl)
git -C "$src" init -q
git -C "$src" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty --date='2020-01-01T12:00:00' -m first
git -C "$src" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
git clone -q --depth 1 "file://$src" "$WORK/shallow" 2>/dev/null
cp "$src/LICENSE" "$src/README.md" "$WORK/shallow/"
bash "$SCRIPT" "$WORK/shallow" >/dev/null 2>&1
check "a shallow clone exits 2"        2  "$?"
check "a shallow clone gets no LICENSE-MIT" yes \
    "$([ -f "$WORK/shallow/LICENSE-MIT" ] && echo no || echo yes)"

# --- 6. the source-of-truth manifest is edited, at its own indent (#341) ----
repo=$(fixture manifest mit)
mkdir -p "$repo/.claude-plugin"
printf '{\n  "name": "demo",\n  "version": "1.0.0",\n  "license": "MIT"\n}\n' > "$repo/plugin.json"
printf '{\n  "name": "demo",\n  "version": "1.0.0",\n  "license": "MIT",\n  "skills": ["./skills/demo"]\n}\n' \
    > "$repo/.claude-plugin/plugin.json"
bash "$SCRIPT" "$repo" >/dev/null 2>&1
check "the root plugin.json carries the new licence" '(MIT AND CC-BY-SA-4.0)' \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$repo/plugin.json")"
check "the generated copy is regenerated to match" '(MIT AND CC-BY-SA-4.0)' \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$repo/.claude-plugin/plugin.json")"
check "the root plugin.json keeps its 2-space indent" yes \
    "$(grep -q '^  "name"' "$repo/plugin.json" && echo yes || echo no)"

echo
if [ "$fail" -eq 0 ]; then
    echo "All migrate-licensing tests passed"
else
    echo "Some migrate-licensing tests FAILED"
fi
exit "$fail"
