#!/usr/bin/env bash
# tests/tests-workflow.sh — the shell steps of the tests.yml reusable, run
# against fixture repositories.
#
# Each step is EXTRACTED from .github/workflows/tests.yml and executed, the way
# tests/release-archive-layout.sh does it for release.yml: a copy of the step
# in this file would hold whatever the copy does and pass after a revert.
#
# WORKFLOW may point at another copy of tests.yml (for example the one on
# origin/main) to show which assertions an older version fails.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${WORKFLOW:-$ROOT/.github/workflows/tests.yml}"
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

# step_body <step name> — prints the `run: |` block of that step, or nothing
step_body() {
    python3 - "$WORKFLOW" "$1" <<'PY'
import sys

path, step = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
start = next((i for i, l in enumerate(lines) if l.strip() == f"- name: {step}"), None)
if start is None:
    sys.exit(0)
for i in range(start + 1, len(lines)):
    if lines[i].strip().startswith("- name:"):
        break
    if lines[i].strip() == "run: |":
        indent = len(lines[i]) - len(lines[i].lstrip()) + 2
        body = []
        for line in lines[i + 1:]:
            if line.strip() and len(line) - len(line.lstrip()) < indent:
                break
            body.append(line[indent:] if len(line) >= indent else line)
        print("\n".join(body))
        break
PY
}

# input_default <input name> — prints the workflow_call input's default
input_default() {
    python3 - "$WORKFLOW" "$1" <<'PY'
import sys

path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
start = next((i for i, l in enumerate(lines) if l.strip() == f"{name}:"), None)
if start is None:
    sys.exit(0)
indent = len(lines[start]) - len(lines[start].lstrip())
for line in lines[start + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) <= indent:
        break
    if line.strip().startswith("default:"):
        print(line.split(":", 1)[1].strip().strip('"'))
        break
PY
}

# run_step <step name> <repo dir> [VAR=value ...] — runs the step in <repo dir>
# with GITHUB_OUTPUT pointed at <repo dir>/.out; prints the step's output and
# a last line `step exit: <status>`
run_step() {
    local step="$1" dir="$2" body
    shift 2
    body="$(step_body "$step")"
    if [ -z "$body" ]; then
        echo "no step named '$step' with a run block"
        return 0
    fi
    : > "$dir/.out"
    local rc=0
    (cd "$dir" && env GITHUB_OUTPUT="$dir/.out" "$@" bash --noprofile --norc -eo pipefail -c "$body" 2>&1) || rc=$?
    echo "step exit: $rc"
}

output_of() { # output_of <repo dir> <key>
    sed -n "s/^$2=//p" "$1/.out" 2>/dev/null | tail -1
}

echo "tests.yml: steps against fixture repositories ($WORKFLOW)"

# --- 1. shipped scripts are counted before the tests, regular files only ----
# Three scripts: by extension (.sh, .py) and by the executable bit. Everything
# else is a directory, a data file or a by-product of a test run, and counting
# it inflated the number the require_tests gate reports.
repo="$WORK/count"
mkdir -p "$repo/skills/a/scripts/tests" "$repo/skills/a/scripts/__pycache__"
printf '#!/usr/bin/env bash\n' > "$repo/skills/a/scripts/tool.sh"
printf 'print(1)\n' > "$repo/skills/a/scripts/helper.py"
printf '#!/usr/bin/env bash\n' > "$repo/skills/a/scripts/runner"
chmod +x "$repo/skills/a/scripts/runner"
printf '{}\n' > "$repo/skills/a/scripts/rules.json"
printf '# notes\n' > "$repo/skills/a/scripts/README.md"
printf 'data\n' > "$repo/skills/a/scripts/.coverage"
printf 'x\n' > "$repo/skills/a/scripts/__pycache__/helper.cpython-313.pyc"
printf '#!/usr/bin/env bash\n' > "$repo/skills/a/scripts/tests/tool.test.sh"

run_step "Count shipped scripts" "$repo" > "$WORK/count.log"
check "the count step reports three shipped scripts" 3 "$(output_of "$repo" count)"
report="$(run_step "Report coverage of shipped scripts" "$repo" \
    SHIPPED_COUNT="$(output_of "$repo" count)" SHELL_COUNT=1 PYTHON_COUNT=0 PHP_COUNT=0 REQUIRE_TESTS=false)"
check "the report names three shipped scripts" 1 "$(grep -c '^shipped scripts: 3 |' <<<"$report")"
grep -q '^shipped scripts: 3 |' <<<"$report" || echo "       report said: $(grep '^shipped scripts' <<<"$report")"

# --- 2. the default globs find tests next to the scripts ---------------------
# github-release-skill keeps its tests in skills/github-release/scripts/tests/;
# a default that looked only under tests/ ran none of them. Each fixture test
# leaves a marker, so the assertion is on what ran, not on what matched.
repo="$WORK/discover"
mkdir -p "$repo/tests" "$repo/skills/a/scripts/tests/nested"
for rel in tests/root.sh skills/a/scripts/tests/near.sh skills/a/scripts/tests/nested/deep.sh; do
    printf 'touch "%s.ran"\n' "$rel" > "$repo/$rel"
done
for rel in tests/root_test.py skills/a/scripts/tests/near_test.py; do
    printf 'open("%s.ran", "w").close()\n' "$rel" > "$repo/$rel"
done

run_step "Shell tests" "$repo" SHELL_GLOB="$(input_default shell_glob)" > "$WORK/shell.log"
check "the shell leg runs root and skill-local tests" 3 "$(output_of "$repo" count)"
for rel in tests/root.sh skills/a/scripts/tests/near.sh skills/a/scripts/tests/nested/deep.sh; do
    check "ran $rel" yes "$([ -f "$repo/$rel.ran" ] && echo yes || echo no)"
done

run_step "Python tests" "$repo" PYTHON_GLOB="$(input_default python_glob)" > "$WORK/python.log"
check "the python leg runs root and skill-local tests" 2 "$(output_of "$repo" count)"
for rel in tests/root_test.py skills/a/scripts/tests/near_test.py; do
    check "ran $rel" yes "$([ -f "$repo/$rel.ran" ] && echo yes || echo no)"
done

# --- 3. require_tests covers every place a skill repo ships scripts ---------
# data-tools-skill ships its scripts in a root scripts/ directory,
# typo3-site-conformance-skill in skills/<name>/checker/. With no test run,
# require_tests must fail for both, as it does for skills/*/scripts/.
for layout in scripts skills/a/checker; do
    repo="$WORK/require-${layout//\//-}"
    mkdir -p "$repo/$layout"
    printf 'print(1)\n' > "$repo/$layout/check.py"
    run_step "Count shipped scripts" "$repo" > "$WORK/require.log"
    check "$layout/: counted as a shipped script" 1 "$(output_of "$repo" count)"
    report="$(run_step "Report coverage of shipped scripts" "$repo" \
        SHIPPED_COUNT="$(output_of "$repo" count)" SHELL_COUNT=0 PYTHON_COUNT=0 PHP_COUNT=0 REQUIRE_TESTS=true)"
    check "$layout/: require_tests fails without a test" 1 "$(grep -c '^step exit: 1$' <<<"$report")"
    report="$(run_step "Report coverage of shipped scripts" "$repo" \
        SHIPPED_COUNT="$(output_of "$repo" count)" SHELL_COUNT=1 PYTHON_COUNT=0 PHP_COUNT=0 REQUIRE_TESTS=true)"
    check "$layout/: require_tests passes once a test ran" 1 "$(grep -c '^step exit: 0$' <<<"$report")"
done

echo
if [ "$fail" -eq 0 ]; then
    echo "All tests.yml step tests passed"
else
    echo "Some tests.yml step tests FAILED"
fi
exit "$fail"
