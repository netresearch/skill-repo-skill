#!/usr/bin/env bash
# tests/portable-manifest.sh — cover the Agent Plugins 1.0.0 portable manifest:
#   * validate-skill.sh verdicts for ./plugin.json (schema, name, closed field
#     set, parity with .claude-plugin/plugin.json, skills/ discoverability)
#   * sync-plugin-manifest.sh generate + --check behaviour
#
# Fixtures are minimal on purpose: the validator also reports missing
# composer.json/README.md, so every assertion matches a specific verdict line
# instead of the overall exit code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
VALIDATOR="$REPO_ROOT/skills/skill-repo/scripts/validate-skill.sh"
SYNC="$REPO_ROOT/skills/skill-repo/scripts/sync-plugin-manifest.sh"
BUMP="$REPO_ROOT/skills/skill-repo/scripts/bump-version.sh"
PARITY="$REPO_ROOT/skills/skill-repo/scripts/check-version-parity.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

SCHEMA="https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"

# fixture <name> — repo with a valid skill, Claude manifest and portable manifest
fixture() {
    local dir="$TMP/$1"
    rm -rf "$dir"
    mkdir -p "$dir/skills/demo" "$dir/.claude-plugin"
    printf -- '---\nname: demo\ndescription: "Use when demoing."\n---\n\n# Demo\n' \
        > "$dir/skills/demo/SKILL.md"
    cat > "$dir/plugin.json" <<JSON
{
  "\$schema": "$SCHEMA",
  "name": "demo",
  "version": "1.0.0",
  "license": "(MIT AND CC-BY-SA-4.0)",
  "author": {
    "name": "Netresearch DTT GmbH",
    "url": "https://www.netresearch.de"
  }
}
JSON
    cat > "$dir/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "demo",
  "version": "1.0.0",
  "author": {
    "name": "Netresearch DTT GmbH",
    "url": "https://www.netresearch.de"
  },
  "license": "(MIT AND CC-BY-SA-4.0)",
  "skills": [
    "./skills/demo"
  ]
}
JSON
    printf '%s' "$dir"
}

# assert_line <expect|reject> <dir> <needle> <label>
assert_line() {
    local want="$1" dir="$2" needle="$3" label="$4" out
    out="$(bash "$VALIDATOR" "$dir" 2>&1)"
    case "$want" in
        expect)
            if grep -qF -- "$needle" <<<"$out"; then ((PASS++)); else
                echo "  FAIL $label: expected a line containing '$needle'"; ((FAIL++)); fi ;;
        reject)
            if grep -qF -- "$needle" <<<"$out"; then
                echo "  FAIL $label: did not expect '$needle'"; ((FAIL++)); else ((PASS++)); fi ;;
    esac
    return 0
}

# assert_cmd <expect_exit> <label> <command...>
assert_cmd() {
    local want="$1" label="$2"; shift 2
    "$@" >/dev/null 2>&1
    local rc=$?
    if [[ $rc -eq $want ]]; then ((PASS++)); else
        echo "  FAIL $label: exit $rc, wanted $want"; ((FAIL++)); fi
    return 0
}

echo "== validate-skill.sh: portable manifest =="

d="$(fixture happy)"
assert_line expect "$d" "plugin.json (portable Agent Plugins manifest) exists" "happy: detected"
assert_line expect "$d" "plugin.json targets Agent Plugins 1.0.0" "happy: schema"
assert_line expect "$d" "plugin.json name valid: demo" "happy: name"
assert_line expect "$d" ".claude-plugin/plugin.json is in sync" "happy: parity"
assert_line expect "$d" "skills/ holds 1 portable skill(s): demo" "happy: discovery"

d="$(fixture no_portable)"
rm "$d/plugin.json"
assert_line expect "$d" "portable Agent Plugins 1.0.0 manifest) not found" "missing: reported"
# The absence is an error since the fleet finished adopting the manifest.
out="$(bash "$VALIDATOR" "$d" 2>&1)"
if grep -E "ERROR.*portable Agent Plugins 1\.0\.0 manifest\) not found" <<<"$out" >/dev/null; then
    ((PASS++))
else
    echo "  FAIL missing: absence of plugin.json must raise an ERROR"; ((FAIL++))
fi

d="$(fixture bad_schema)"
python3 - "$d/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["$schema"] = "https://agent-plugins.org/schemas/0.9.0/plugin.schema.json"
json.dump(d, open(p, "w"), indent=2)
PY
assert_line expect "$d" "plugin.json \$schema must be" "bad schema: rejected"

d="$(fixture bad_name)"
python3 - "$d/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["name"] = "Demo--Skill"
json.dump(d, open(p, "w"), indent=2)
PY
assert_line expect "$d" "plugin.json name is invalid" "bad name: rejected"

d="$(fixture unknown_field)"
python3 - "$d/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["skills"] = ["./skills/demo"]
json.dump(d, open(p, "w"), indent=2)
PY
assert_line expect "$d" "fields outside the Agent Plugins schema: skills" "unknown field: rejected"

d="$(fixture drift)"
python3 - "$d/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["version"] = "2.0.0"
json.dump(d, open(p, "w"), indent=2)
PY
assert_line expect "$d" "out of sync with plugin.json on: version" "drift: rejected"

d="$(fixture root_skill_only)"
rm -rf "$d/skills"
printf -- '---\nname: demo\ndescription: "Use when demoing."\n---\n\n# Demo\n' > "$d/SKILL.md"
assert_line expect "$d" "no skills/<name>/SKILL.md found" "root SKILL.md: rejected"

d="$(fixture bad_author)"
python3 - "$d/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["author"] = "Netresearch DTT GmbH"
json.dump(d, open(p, "w"), indent=2)
PY
assert_line expect "$d" "author must be an object" "author string: rejected"

echo "== sync-plugin-manifest.sh =="

d="$(fixture sync_ok)"
assert_cmd 0 "sync: in-sync fixture passes --check" bash "$SYNC" --repo "$d" --check

d="$(fixture sync_drift)"
python3 - "$d/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["version"] = "2.0.0"
json.dump(d, open(p, "w"), indent=2)
PY
assert_cmd 1 "sync: drift fails --check" bash "$SYNC" --repo "$d" --check
assert_cmd 0 "sync: writes the Claude manifest" bash "$SYNC" --repo "$d"
assert_cmd 0 "sync: --check passes after write" bash "$SYNC" --repo "$d" --check

if [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$d/.claude-plugin/plugin.json")" == "2.0.0" ]]; then
    ((PASS++))
else
    echo "  FAIL sync: version not projected into the Claude manifest"; ((FAIL++))
fi

if [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("skills"))' "$d/.claude-plugin/plugin.json")" == "['./skills/demo']" ]]; then
    ((PASS++))
else
    echo "  FAIL sync: Claude-only 'skills' key was not preserved"; ((FAIL++))
fi

# shellcheck disable=SC2016  # "$schema" is a Python string literal, not a shell expansion
if python3 -c 'import json,sys;sys.exit(0 if "$schema" not in json.load(open(sys.argv[1])) else 1)' "$d/.claude-plugin/plugin.json"; then
    ((PASS++))
else
    echo "  FAIL sync: \$schema leaked into the Claude manifest"; ((FAIL++))
fi

# key order in the Claude manifest is not the check's business
d="$(fixture sync_reordered)"
python3 - "$d/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
open(p, "w").write(json.dumps(dict(reversed(list(d.items()))), indent=4) + "\n")
PY
assert_cmd 0 "sync: reordered/reformatted Claude manifest still passes --check" bash "$SYNC" --repo "$d" --check

# a shared key present only in the Claude manifest is drift too
d="$(fixture sync_claude_only_key)"
python3 - "$d/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["keywords"] = ["extra"]
json.dump(d, open(p, "w"), indent=2)
PY
assert_cmd 1 "sync: Claude-only shared key fails --check" bash "$SYNC" --repo "$d" --check

d="$(fixture sync_absent)"
rm "$d/plugin.json"
assert_cmd 0 "sync: no portable manifest is a no-op" bash "$SYNC" --repo "$d" --check

echo "== bump-version.sh =="

json_version() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$1"; }
skill_version() {
    awk '/^---$/{fm=!fm;next} fm && /^[[:space:]]*version:/{
        gsub(/^[[:space:]]*version:[[:space:]]*/,""); gsub(/["\047]/,""); print; exit}' "$1"
}

# A repo carrying the portable manifest must end up bumped on BOTH manifests.
# Before the fix the bump wrote only .claude-plugin/plugin.json and then exited 1
# on its own parity check, leaving the tree half-written.
d="$(fixture bump_portable)"
printf -- '---\nname: demo\nmetadata:\n  version: 1.0.0\n---\n\n# Demo\n' > "$d/skills/demo/SKILL.md"
assert_cmd 0 "bump: succeeds on a portable-manifest repo" bash "$BUMP" --repo "$d" 2.0.0 --apply
for f in plugin.json .claude-plugin/plugin.json; do
    if [[ "$(json_version "$d/$f")" == "2.0.0" ]]; then ((PASS++)); else
        echo "  FAIL bump: $f is $(json_version "$d/$f"), wanted 2.0.0"; ((FAIL++)); fi
done
if [[ "$(skill_version "$d/skills/demo/SKILL.md")" == "2.0.0" ]]; then ((PASS++)); else
    echo "  FAIL bump: SKILL.md metadata.version not bumped"; ((FAIL++)); fi
assert_cmd 0 "bump: result passes the parity check" bash "$PARITY" --repo "$d" v2.0.0

# Claude-only keys must survive the projection.
if [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("skills"))' \
        "$d/.claude-plugin/plugin.json")" == "['./skills/demo']" ]]; then ((PASS++)); else
    echo "  FAIL bump: Claude-only 'skills' key lost during the bump"; ((FAIL++)); fi

# A repo that never adopted the portable manifest keeps the old direct-write path.
d="$(fixture bump_legacy)"
rm "$d/plugin.json"
assert_cmd 0 "bump: succeeds without a portable manifest" bash "$BUMP" --repo "$d" 2.0.0 --apply
if [[ "$(json_version "$d/.claude-plugin/plugin.json")" == "2.0.0" ]]; then ((PASS++)); else
    echo "  FAIL bump: legacy repo's Claude manifest not bumped"; ((FAIL++)); fi

# Dry run writes nothing but still reports the root manifest.
d="$(fixture bump_dryrun)"
out="$(bash "$BUMP" --repo "$d" 2.0.0 2>&1)"
if grep -qE '^  plugin\.json ' <<<"$out"; then ((PASS++)); else
    echo "  FAIL bump: dry run does not report the root plugin.json"; ((FAIL++)); fi
if [[ "$(json_version "$d/plugin.json")" == "1.0.0" ]]; then ((PASS++)); else
    echo "  FAIL bump: dry run wrote to plugin.json"; ((FAIL++)); fi

echo "----------------------------------------"
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || { echo "Portable manifest tests FAILED"; exit 1; }
echo "All portable manifest tests passed"
