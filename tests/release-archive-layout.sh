#!/usr/bin/env bash
# Every release archive must unpack into ONE top-level folder.
#
# `zip -qr ... .` from a staging directory that WAS the content root put SKILL.md
# at the archive root. Two things break on that, and neither shows up in the
# release job's own log:
#
#   - the OpenAI skills API takes "a .zip that contains a single top-level
#     folder" (developers.openai.com, Skills guide), so a flat archive is
#     rejected with a bare "Invalid skill" and no reason
#     (german-technical-writing-skill#2)
#   - every repo's README says "extract to your agent's skills directory", and a
#     flat archive unpacks SKILL.md and references/ straight into
#     ~/.claude/skills/, on top of whatever else lives there
#
# The packaging step is EXTRACTED from .github/workflows/release.yml and run
# against a fixture repository, rather than reproduced here: a test that
# reproduces the code it guards holds whatever that code does, and would pass
# just as happily after a revert. Running the whole step also means the staging
# layout is exercised, not only the four archive commands — the flat archive came
# from where the content was staged as much as from what was archived.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/release.yml"
STEP="Validate version and build packages"
FAILED=0

fail() {
	echo "  [FAIL] $1"
	FAILED=1
}

pass() {
	echo "  [OK] $1"
}

echo "Release archive layout"
echo "======================"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- extract the step's script ---------------------------------------------

python3 - "$WORKFLOW" "$STEP" >"$WORK/package.sh" <<'PY'
import sys

path, step = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
start = None
for i, line in enumerate(lines):
    if line.strip() == f"- name: {step}":
        start = i
        break
if start is None:
    sys.exit(f"no step named {step!r} in {path}")
for i in range(start, len(lines)):
    if lines[i].strip() == "run: |":
        indent = len(lines[i]) - len(lines[i].lstrip()) + 2
        body = []
        for line in lines[i + 1:]:
            if line.strip() and len(line) - len(line.lstrip()) < indent:
                break
            body.append(line[indent:] if len(line) >= indent else line)
        print("\n".join(body))
        break
else:
    sys.exit(f"step {step!r} has no `run: |` block")
PY

if [ ! -s "$WORK/package.sh" ]; then
	fail "could not extract the \"$STEP\" step from release.yml"
	echo ""
	echo "Release archive layout FAILED"
	exit 1
fi
pass "extracted the packaging step from release.yml"

# --- a fixture repository the step can package -----------------------------

REPO="$WORK/repo"
mkdir -p "$REPO/.claude-plugin" "$REPO/skills/demo-one/references" "$REPO/skills/demo-two"
cat >"$REPO/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "demo-plugin",
  "version": "9.9.9",
  "skills": ["./skills/demo-one", "./skills/demo-two"]
}
JSON
printf -- '---\nname: demo-one\n---\n' >"$REPO/skills/demo-one/SKILL.md"
printf -- '---\nname: demo-two\n---\n' >"$REPO/skills/demo-two/SKILL.md"
echo "reference" >"$REPO/skills/demo-one/references/one.md"
echo "MIT" >"$REPO/LICENSE-MIT"
echo "CC" >"$REPO/LICENSE-CC-BY-SA-4.0"

(cd "$REPO" && TAG_VERSION=v9.9.9 bash "$WORK/package.sh" >"$WORK/package.log" 2>&1) || {
	fail "the packaging step exited non-zero; log:"
	sed 's/^/      /' "$WORK/package.log"
	echo ""
	echo "Release archive layout FAILED"
	exit 1
}
pass "the packaging step ran against a fixture repository"

# --- the property ----------------------------------------------------------

check() {
	local archive="$1" expected="$2"
	local label entries tops
	label="$(basename "$archive")"
	if [ ! -f "$archive" ]; then
		fail "$label was not produced"
		return
	fi
	case "$archive" in
	*.zip) entries="$(unzip -Z1 "$archive")" ;;
	*) entries="$(tar -tzf "$archive")" ;;
	esac

	tops="$(printf '%s\n' "$entries" | cut -d/ -f1 | sort -u | grep -v '^$' || true)"
	if [ "$tops" = "$expected" ]; then
		pass "$label: one top-level entry, $expected/"
	else
		fail "$label: top-level entries [$(printf '%s' "$tops" | tr '\n' ' ')] — expected only $expected/"
	fi

	# The skill archives carry SKILL.md at the folder root. The plugin archive
	# carries BOTH its own manifest and the nested skills: asserting only the
	# nested SKILL.md would stay green if the workflow stopped copying
	# .claude-plugin, which is the half a plugin consumer actually needs.
	local wanted
	if [ "$expected" = "demo-plugin" ]; then
		wanted="$expected/.claude-plugin/plugin.json $expected/skills/demo-one/SKILL.md"
	else
		wanted="$expected/SKILL.md"
	fi
	for want in $wanted; do
		if printf '%s\n' "$entries" | grep -qx "$want"; then
			pass "$label: carries $want"
		else
			fail "$label: no $want"
		fi
	done
}

REL="$REPO/dist/releases"
for name in demo-one demo-two; do
	check "$REL/${name}-skill-v9.9.9.zip" "$name"
	check "$REL/${name}-skill-v9.9.9.tar.gz" "$name"
done
check "$REL/demo-plugin-plugin-v9.9.9.zip" "demo-plugin"
check "$REL/demo-plugin-plugin-v9.9.9.tar.gz" "demo-plugin"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Release archive layout passed"
	exit 0
fi
echo "Release archive layout FAILED"
exit 1
