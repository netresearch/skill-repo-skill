#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Every release archive must unpack into ONE top-level folder, carry the
# directories its SKILL.md references (checker/, skill-repo-skill#368), and the
# step must refuse to build when a referenced directory would be dropped.
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
mkdir -p "$REPO/.claude-plugin" "$REPO/skills/demo-one/references" "$REPO/skills/demo-one/checker" \
	"$REPO/skills/demo-one/evals" "$REPO/skills/demo-two"
cat >"$REPO/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "demo-plugin",
  "version": "9.9.9",
  "skills": ["./skills/demo-one", "./skills/demo-two"]
}
JSON
# demo-one references a checker/ directory (typo3-site-conformance-skill's
# layout, skill-repo-skill#368) and links evals/, which is deliberately left
# out of every archive and must not fail the step.
cat >"$REPO/skills/demo-one/SKILL.md" <<'MD'
---
name: demo-one
---
Run `python3 checker/check.py <repo>`. Rules: [one](references/one.md).
The [eval rubric](evals/evals.json) is for maintainers.
MD
printf -- '---\nname: demo-two\n---\n' >"$REPO/skills/demo-two/SKILL.md"
echo "reference" >"$REPO/skills/demo-one/references/one.md"
echo "print('check')" >"$REPO/skills/demo-one/checker/check.py"
echo "{}" >"$REPO/skills/demo-one/evals/evals.json"
echo "MIT" >"$REPO/LICENSE-MIT"
echo "CC" >"$REPO/LICENSE-CC-BY-SA-4.0"

# A second copy whose SKILL.md references a directory the allow-list does not
# ship, in the ${CLAUDE_SKILL_DIR}/ form most fleet skills use: the step must
# refuse to build archives that drop it. Copied before the
# first run, so it holds no dist/ of its own.
BROKEN="$WORK/broken"
cp -r "$REPO" "$BROKEN"
mkdir -p "$BROKEN/skills/demo-two/config"
echo "key: value" >"$BROKEN/skills/demo-two/config/settings.yaml"
cat >"$BROKEN/skills/demo-two/SKILL.md" <<'MD'
---
name: demo-two
---
Read `${CLAUDE_SKILL_DIR}/config/settings.yaml` first.
MD

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
	# checker/ is asserted in both archive kinds that carry demo-one: the
	# allow-list once dropped it from both (skill-repo-skill#368).
	local wanted
	if [ "$expected" = "demo-plugin" ]; then
		wanted="$expected/.claude-plugin/plugin.json $expected/skills/demo-one/SKILL.md"
		wanted="$wanted $expected/skills/demo-one/checker/check.py"
	elif [ "$expected" = "demo-one" ]; then
		wanted="$expected/SKILL.md $expected/checker/check.py"
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

# --- a referenced directory the archive would drop -------------------------

if (cd "$BROKEN" && TAG_VERSION=v9.9.9 bash "$WORK/package.sh" >"$WORK/broken.log" 2>&1); then
	fail "the packaging step succeeded although demo-two/SKILL.md references config/, which no archive carries"
elif grep -q '^::error file=skills/demo-two/SKILL.md::.*references config/settings.yaml' "$WORK/broken.log"; then
	pass "the packaging step fails on a SKILL.md reference the archive does not carry"
else
	fail "the packaging step failed, but not with the missing-reference error; log:"
	sed 's/^/      /' "$WORK/broken.log"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Release archive layout passed"
	exit 0
fi
echo "Release archive layout FAILED"
exit 1
