#!/usr/bin/env bash
# tests/validate-skill.sh — smoke tests for the description-scalar parsing in
# skills/skill-repo/scripts/validate-skill.sh (regression cover for issue #119:
# single-quoted and block scalars were wrongly rejected).
#
# Runs each fixture through BOTH code paths of the validator:
#   - fallback : stdlib-only path, forced by shimming `import yaml` to fail
#   - yaml     : PyYAML-authoritative path (uses uv --with pyyaml if the system
#                python3 cannot import yaml; skipped with a notice if neither
#                a yaml-capable python3 nor uv is available)
#
# Asserts on the validator's description verdict line, not its overall exit code
# (the minimal fixtures intentionally lack composer.json/README so the validator
# always exits non-zero on unrelated checks).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
VALIDATOR="$REPO_ROOT/skills/skill-repo/scripts/validate-skill.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# yaml-disabling shim: placed first on PYTHONPATH so `import yaml` raises even
# when PyYAML is installed, deterministically exercising the stdlib fallback.
SHIM="$TMP/_noyaml"
mkdir -p "$SHIM"
printf 'raise ImportError("yaml disabled for fallback test")\n' > "$SHIM/yaml.py"

# Determine a yaml-capable runner for the authoritative path.
YAML_RUNNER=()
if python3 -c 'import yaml' >/dev/null 2>&1; then
    YAML_RUNNER=(env)
elif command -v uv >/dev/null 2>&1 && uv run --with pyyaml python3 -c 'import yaml' >/dev/null 2>&1; then
    YAML_RUNNER=(uv run --with pyyaml)
fi

PASS=0
FAIL=0
ACCEPT_LINE="Description starts with 'Use when'"

# fixture <name> <raw-content> -> echoes the created dir path
fixture() {
    local name="$1" content="$2" dir
    dir="$TMP/fx_$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%b' "$content" > "$dir/SKILL.md"
    printf '%s' "$dir"
    return 0
}

# run_validator <fallback|yaml> <dir>
run_validator() {
    local path="$1" dir="$2"
    case "$path" in
        fallback) PYTHONPATH="$SHIM" bash "$VALIDATOR" "$dir" 2>&1 ;;
        yaml)     "${YAML_RUNNER[@]}" bash "$VALIDATOR" "$dir" 2>&1 ;;
        *)        echo "unknown path: $path" >&2; return 2 ;;
    esac
    return 0
}

# assert <accept|reject> <path> <dir> <label>
assert() {
    local want="$1" path="$2" dir="$3" label="$4" out
    out="$(run_validator "$path" "$dir")"
    case "$want" in
        accept)
            if grep -qF "$ACCEPT_LINE" <<<"$out"; then ((PASS++)); else
                echo "  FAIL [$path] $label: expected ACCEPT, was rejected"; ((FAIL++)); fi ;;
        reject)
            if grep -qF "$ACCEPT_LINE" <<<"$out"; then
                echo "  FAIL [$path] $label: expected REJECT, was accepted"; ((FAIL++)); else ((PASS++)); fi ;;
        *)  echo "  FAIL [$path] $label: unknown expectation '$want'"; ((FAIL++)) ;;
    esac
    return 0
}

# Fixtures are keyed by name to avoid packing YAML (which contains '|', '>', ':')
# into a delimited string. content_for echoes the raw SKILL.md body for a name;
# CASES lists "name want" pairs with the expected verdict (same on both paths).
hdr='---\nname: t\n'
content_for() {
    local name="$1"
    case "$name" in
        plain)          printf '%s' "${hdr}description: Use when doing X\n---\n# T\n" ;;
        dquote)         printf '%s' "${hdr}description: \"Use when doing X\"\n---\n# T\n" ;;
        squote)         printf '%s' "${hdr}description: 'Use when doing X'\n---\n# T\n" ;;
        block_fold)     printf '%s' "${hdr}description: >-\n  Use when doing X\n  across lines\n---\n# T\n" ;;
        block_literal)  printf '%s' "${hdr}description: |\n  Use when doing X\n---\n# T\n" ;;
        dquote_comment) printf '%s' "${hdr}description: \"Use when doing X\"   # a comment\n---\n# T\n" ;;
        plain_comment)  printf '%s' "${hdr}description: Use when doing X  # c\n---\n# T\n" ;;
        empty_block)    printf '%s' "${hdr}description: |\nlicense: Use when fake\n---\n# T\n" ;;
        wrong_prefix)   printf '%s' "${hdr}description: 'Helps with X'\n---\n# T\n" ;;
        invalid_yaml)   printf '%s' "${hdr}description: \"Use when unterminated\n---\n# T\n" ;;
        *)              echo "unknown fixture: $name" >&2; return 2 ;;
    esac
    return 0
}
declare -a CASES=(
    "plain accept"
    "dquote accept"
    "squote accept"
    "block_fold accept"
    "block_literal accept"
    "dquote_comment accept"
    "plain_comment accept"
    "empty_block reject"
    "wrong_prefix reject"
    "invalid_yaml reject"
)

echo "== Fallback path (stdlib only, yaml shimmed out) =="
for c in "${CASES[@]}"; do
    read -r name want <<<"$c"
    assert "$want" fallback "$(fixture "$name" "$(content_for "$name")")" "$name"
done

if [[ ${#YAML_RUNNER[@]} -gt 0 ]]; then
    echo "== PyYAML-authoritative path (${YAML_RUNNER[*]}) =="
    for c in "${CASES[@]}"; do
        read -r name want <<<"$c"
        assert "$want" yaml "$(fixture "$name" "$(content_for "$name")")" "$name"
    done

    # #2: invalid YAML must be reported as such, not as a content error.
    out="$(run_validator yaml "$(fixture invalid_yaml2 "$(content_for invalid_yaml)")")"
    if grep -qF "frontmatter is not valid YAML" <<<"$out"; then ((PASS++)); else
        echo "  FAIL [yaml] invalid_yaml: expected 'not valid YAML' diagnostic"; ((FAIL++)); fi
else
    echo "== PyYAML-authoritative path: SKIPPED (no yaml-capable python3 or uv) =="
fi

echo "----------------------------------------"
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || { echo "Smoke tests FAILED"; exit 1; }
echo "All validator smoke tests passed"
