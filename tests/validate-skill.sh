#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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
elif command -v uv >/dev/null 2>&1 && uv run --no-build --with 'pyyaml==6.0.3' python3 -c 'import yaml' >/dev/null 2>&1; then
    YAML_RUNNER=(uv run --no-build --with 'pyyaml==6.0.3')
fi

PASS=0
FAIL=0
# Every per-skill message is prefixed with the file it is about, so the
# assertion matches from the word after the path onwards.
ACCEPT_LINE="description starts with 'Use when'"

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

# #214: a repo shipping several skills must have every one of them validated.
# Before this, discovery stopped at the first skills/*/SKILL.md, so a defect in
# any later skill was invisible — matrix-skill carried a 1348-word SKILL.md
# under a green "Skill Validation" for as long as the repo existed. The second
# skill here is the one that is broken, so the check fails if discovery ever
# goes back to first-match-wins.
echo "== Multi-skill discovery (#214) =="
multi="$TMP/fx_multi"
rm -rf "$multi"
mkdir -p "$multi/skills/aaa-good" "$multi/skills/zzz-broken" "$multi/skills/zzz-long"
printf '%b' "${hdr}description: Use when doing X\n---\n# Good\n" > "$multi/skills/aaa-good/SKILL.md"
printf '%b' "${hdr}description: 'Helps with X'\n---\n# Broken\n" > "$multi/skills/zzz-broken/SKILL.md"
# Over the 500-LINE cap, in a skill that is not the first alphabetically.
# Was 520 words on one line until the budget was corrected: the spec says
# "Keep your main SKILL.md under 500 lines", and a word count over the whole
# file is a different, much tighter rule that also charged the frontmatter to
# the body. The point of this fixture is unchanged -- a violation in a LATER
# skill must still be reported -- only the metric it violates.
{
    printf '%b' "${hdr}description: Use when doing Y\n---\n# Long\n"
    for _ in $(seq 1 520); do printf 'line\n'; done
} > "$multi/skills/zzz-long/SKILL.md"
multi_out="$(run_validator fallback "$multi")"

if grep -qF "skills/aaa-good/SKILL.md description starts with 'Use when'" <<<"$multi_out"; then ((PASS++)); else
    echo "  FAIL [multi] first skill not validated"; ((FAIL++)); fi
if grep -qF "skills/zzz-broken/SKILL.md description must start with 'Use when'" <<<"$multi_out"; then ((PASS++)); else
    echo "  FAIL [multi] a later skill's bad description was not reported"; ((FAIL++)); fi
if grep -qE "skills/zzz-long/SKILL.md body is [0-9]+ lines \(spec recommends under 500\)" <<<"$multi_out"; then ((PASS++)); else
    echo "  FAIL [multi] a later skill's body size was not reported"; ((FAIL++)); fi
# Discovery itself, independent of any single verdict: all three are reported.
# (Not asserted on the exit code — these fixtures lack composer.json and README,
# so the run exits non-zero either way and the assertion could not fail.)
found_count="$(grep -cF 'SKILL.md found:' <<<"$multi_out")"
if [[ "$found_count" -eq 3 ]]; then ((PASS++)); else
    echo "  FAIL [multi] expected 3 discovered skills, got $found_count"; ((FAIL++)); fi

# Dangling references: a skill-relative path named in SKILL.md must exist under
# the skill directory (retro-skill#19 shipped scripts/ and references/ outside
# it, so every path was dead on a faithful install). The present file must not
# be reported, the missing ones must -- including the ${CLAUDE_SKILL_DIR} form.
# Globs and placeholders are not paths and must stay silent. Markdown link
# targets count as names too, and a link's #anchor is not part of the path.
echo "== Dangling references =="
dang="$TMP/fx_dangling"
rm -rf "$dang"
mkdir -p "$dang/skills/d/references" "$dang/skills/d/scripts"
printf '# present\n' > "$dang/skills/d/references/present.md"
printf '#!/bin/sh\n' > "$dang/skills/d/scripts/present.sh"
chmod +x "$dang/skills/d/scripts/present.sh"
{
    printf '%b' "${hdr}description: Use when doing X\n---\n# D\n"
    printf 'Read \x60references/present.md\x60 and \x60references/missing.md\x60.\n'
    printf '%s\n' "Run \`scripts/present.sh\` or \`\${CLAUDE_SKILL_DIR}/scripts/missing.sh\`;"
    printf 'never \x60references/*.md\x60 wholesale, nor \x60references/<topic>.md\x60.\n'
    printf 'Project files live under \x60assets/\x60 (a bare directory, not a file).\n'
    printf 'See [here](references/present.md#anchor) and [gone](references/linked.md).\n'
    printf 'Angle-wrapped targets are links too: [w](<references/wrapped.md>).\n'
} > "$dang/skills/d/SKILL.md"
dang_out="$(run_validator fallback "$dang")"
dang_line="$(grep -F 'names path(s) that do not exist' <<<"$dang_out" || true)"
if [[ -n "$dang_line" ]]; then ((PASS++)); else
    echo "  FAIL [dangling] missing paths were not reported"; ((FAIL++)); fi
for want in references/missing.md scripts/missing.sh references/linked.md references/wrapped.md; do
    if grep -qF " $want" <<<"$dang_line"; then ((PASS++)); else
        echo "  FAIL [dangling] $want not named in: $dang_line"; ((FAIL++)); fi
done
for absent in present.md present.sh 'references/*.md' 'references/<topic>.md' 'assets/'; do
    if grep -qF "$absent" <<<"$dang_line"; then
        echo "  FAIL [dangling] $absent wrongly reported"; ((FAIL++)); else ((PASS++)); fi
done

# A shared reference can resolve in the source tree and disappear when only
# the skill directory is installed. Validate the unpacked directory as well.
echo "== Shared references after standalone installation =="
shared="$TMP/fx_shared"
mkdir -p "$shared/skills/d" "$shared/references" "$TMP/installed/d"
printf '# shared\n' > "$shared/references/shared.md"
printf '%b' "${hdr}description: Use when doing X\n---\n# D\n" > "$shared/skills/d/SKILL.md"
printf 'Read [the shared rule](../../references/shared.md).\n' >> "$shared/skills/d/SKILL.md"
shared_out="$(run_validator fallback "$shared")"
if grep -qF 'names path(s) that do not exist' <<<"$shared_out"; then
    echo "  FAIL [shared] existing source reference was rejected"; ((FAIL++)); else ((PASS++)); fi
cp "$shared/skills/d/SKILL.md" "$TMP/installed/d/SKILL.md"
installed_out="$(run_validator fallback "$TMP/installed/d")"
if grep -qE 'names path\(s\) that do not exist.*\.\./\.\./references/shared\.md' <<<"$installed_out"; then
    ((PASS++))
else
    echo "  FAIL [shared] standalone install silently lost shared.md"; ((FAIL++))
fi

# --- allowed-tools: interpreter-wide rule in a skill that ships scripts (#271)
# Warns only when both hold. A skill without scripts/ keeps its interpreter
# rule without comment, and a converted rule must stay silent -- otherwise the
# warning would fire across a fleet that has already done the work.
at_case() { # at_case <allowed-tools line> <with-scripts:yes|no> <expect:warn|quiet> <label>
    local line="$1" with_scripts="$2" expect="$3" label="$4" dir out hit
    dir="$(mktemp -d)"; mkdir -p "$dir/skills/d"
    [[ "$with_scripts" == yes ]] && { mkdir -p "$dir/skills/d/scripts"; printf '#!/usr/bin/env bash\necho hi\n' > "$dir/skills/d/scripts/x.sh"; }
    printf '{"name":"d","version":"1.0.0"}\n' > "$dir/plugin.json"
    {
        printf -- '---\n'
        printf 'name: d\n'
        printf 'description: "Use when exercising the allowed-tools check."\n'
        printf '%s\n' "$line"
        printf -- '---\n\n# D\n'
    } > "$dir/skills/d/SKILL.md"
    out="$(run_validator fallback "$dir")"
    hit="$(grep -cF 'allowed-tools grants an interpreter' <<<"$out" || true)"
    rm -rf "$dir"
    if [[ "$expect" == warn && "$hit" -ge 1 ]] || [[ "$expect" == quiet && "$hit" -eq 0 ]]; then
        ((PASS++))
    else
        echo "  FAIL [allowed-tools] $label: expected $expect, got $hit hit(s)"; ((FAIL++))
    fi
}
at_case 'allowed-tools: Bash(bash:*) Read'                                    yes warn  'interpreter rule'
at_case 'allowed-tools: Bash(python3:*) Read'                                 yes warn  'python3 rule'
at_case 'allowed-tools: Bash(uv:*) Read'                                      yes warn  'uv rule'
at_case 'allowed-tools: Bash(git:*,make:*,bash:*) Read'                       yes warn  'comma syntax hides bash'
at_case 'allowed-tools: Bash Read Write'                                      yes warn  'bare Bash'
# Single-quoted on purpose: the validator must see the variable unexpanded,
# the way it appears in a real frontmatter line.
# shellcheck disable=SC2016
at_case 'allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(git:*) Read' yes quiet 'converted rule'
at_case 'allowed-tools: Bash(git:*) Bash(gh:*) Read'                          yes quiet 'no interpreter at all'
at_case 'allowed-tools: Bash(bash:*) Read'                                    no  quiet 'no scripts/ to name'

# The spec accepts a plain scalar, a folded/literal block and a YAML list, so a
# check that reads only the key line misses a rule on a continuation line.
# shellcheck disable=SC2016
at_case 'allowed-tools: >-
  Bash(bash:*)
  Read'                                                                       yes warn  'folded scalar'
at_case 'allowed-tools:
  - Bash(python3:*)
  - Read'                                                                     yes warn  'yaml list'
# shellcheck disable=SC2016
at_case 'allowed-tools: >-
  Bash(${CLAUDE_SKILL_DIR}/scripts/*)
  Read'                                                                       yes quiet 'folded scalar, converted'

# A blank line is legal inside a folded scalar, and the spec allows comma
# separation and quoting -- all three defeated an earlier version of the check.
at_case 'allowed-tools: >-
  Read

  Bash(python3:*)'                                                            yes warn  'blank line inside value'
at_case 'allowed-tools: Bash,Read'                                            yes warn  'comma-separated bare Bash'
at_case 'allowed-tools: "Bash"'                                               yes warn  'quoted bare Bash'
# shellcheck disable=SC2016
at_case 'allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*),Read'             yes quiet 'comma-separated, converted'

# A comment is not part of the value, and a flow list is still a list.
at_case 'allowed-tools:
  - Read
  # Bash(python3:*) is not granted'                                           yes quiet 'comment mentioning an interpreter'
at_case 'allowed-tools: [Bash]'                                               yes warn  'flow list, bare Bash'
at_case 'allowed-tools: [Bash(bash:*), Read]'                                 yes warn  'flow list, interpreter'
# shellcheck disable=SC2016
at_case 'allowed-tools: [Bash(${CLAUDE_SKILL_DIR}/scripts/*), Read]'          yes quiet 'flow list, converted'
at_case 'allowed-tools: Read # Bash(bash:*) would be wrong'                   yes quiet 'trailing comment'
# A script whose own name ends in .sh is not the interpreter: the pattern for
# `sh:*` must not match inside `context7.sh:*`.
# shellcheck disable=SC2016
at_case 'allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/context7.sh:*) Read'  yes quiet 'script name ending in .sh'
# shellcheck disable=SC2016
at_case 'allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/context7.sh:*) Read' yes quiet 'bash plus script name ending in .sh'
at_case 'allowed-tools: Bash(git:*, bash:*) Read'                             yes warn  'interpreter after comma and space'
at_case 'allowed-tools: Bash(/bin/bash:*) Read'                                  yes warn  'interpreter named by path'
at_case 'allowed-tools: Bash(/usr/bin/python3:*) Read'                           yes warn  'python3 named by path'
# shellcheck disable=SC2016
at_case 'allowed-tools: Bash(${CLAUDE_SKILL_DIR}/bin/sh:*) Read'                 yes warn  'sh named by a path under the skill'

echo "----------------------------------------"
echo "README install-instruction checks"
echo "----------------------------------------"
# netresearch/retro-skill#90: the documented steps failed on the first command
# for as long as the README existed, and nothing in CI could see it.

# readme_case <name> <readme-body> <expect-present|expect-absent> <pattern> <label>
readme_case() {
    local name="$1" body="$2" want="$3" pat="$4" label="$5" dir out
    dir="$TMP/rm_$name"
    rm -rf "$dir"; mkdir -p "$dir/.claude-plugin"
    printf '%b' "$body" > "$dir/README.md"
    printf '{"name":"x","version":"1.0.0"}\n' > "$dir/.claude-plugin/plugin.json"
    out="$(GITHUB_REPOSITORY=netresearch/demo-skill bash "$VALIDATOR" "$dir" 2>&1)"
    case "$want" in
        expect-present)
            if grep -qF -- "$pat" <<< "$out"; then ((PASS++)); else
                echo "  FAIL $label: expected output matching '$pat'"; ((FAIL++)); fi ;;
        expect-absent)
            if grep -qF -- "$pat" <<< "$out"; then
                echo "  FAIL $label: '$pat' should NOT have fired"; ((FAIL++)); else ((PASS++)); fi ;;
    esac
    return 0
}

# shellcheck disable=SC2016  # literal markdown fixture, not an expansion
FENCED_SELF='## Install\n\n```text\n/plugin marketplace add netresearch/demo-skill\n/plugin install demo@netresearch/demo-skill\n```\n'
readme_case self_add "$FENCED_SELF" expect-present \
    "cannot work" "self-referencing marketplace add is an error"
readme_case self_install "$FENCED_SELF" expect-present \
    "not owner/repo" "owner/repo after @ is an error"

# The same wrong line OUTSIDE a fence is documentation about the mistake, not an
# instruction — this repo's own README carries one. The unfenced copy below
# starts at column 0, so only the fence tracking can exclude it: a version of
# this check that reads the whole file matches it and reports an error.
# shellcheck disable=SC2016  # literal markdown fixture, not an expansion
PROSE_ONLY='## Install\n\n```text\n/plugin marketplace add netresearch/claude-code-marketplace\n/plugin install demo@netresearch-claude-code-marketplace\n```\n\nDo not write this, it fails:\n\n/plugin marketplace add netresearch/demo-skill\n'
readme_case prose_only "$PROSE_ONLY" expect-absent \
    "cannot work" "the same line in prose does not fire"
readme_case prose_ok "$PROSE_ONLY" expect-present \
    "install target names a marketplace" "the correct pair is accepted"

# shellcheck disable=SC2016  # literal markdown fixture, not an expansion
# The slug is compared against the ADD ARGUMENT, not the line. A catalog whose
# name merely starts with this repo's slug must not read as self-referencing.
# shellcheck disable=SC2016  # literal markdown fixture, not an expansion
PREFIX_CATALOG='## Install\n\n```text\n/plugin marketplace add netresearch/demo-skill-catalog\n/plugin install demo@demo-skill-catalog\n```\n'
readme_case prefix_catalog "$PREFIX_CATALOG" expect-absent \
    "cannot work" "a catalog whose slug extends this repo's is not self-reference"

# Two spaces after `install` must still yield the target, not an empty string.
# shellcheck disable=SC2016  # literal markdown fixture, not an expansion
DOUBLE_SPACE='## Install\n\n```text\n/plugin marketplace add netresearch/claude-code-marketplace\n/plugin  install   demo@netresearch-claude-code-marketplace\n```\n'
readme_case double_space "$DOUBLE_SPACE" expect-present \
    "install target names a marketplace: demo@netresearch-claude-code-marketplace" \
    "irregular spacing still parses the install target"

# shellcheck disable=SC2016  # literal markdown fixture, not an expansion
NO_INSTALL='## Install\n\n```text\n/plugin marketplace add netresearch/claude-code-marketplace\n```\n'
readme_case no_install "$NO_INSTALL" expect-present \
    "no plugin" "an add line without an install line warns"

# A hand-typed shields.io version badge is updated by no release step and
# drifts: typo3-testing-skill showed 3.0.0 while the latest release was v5.22.1.
# Both directions: the live release badge must stay quiet, or a check that
# fires on any shields.io URL would pass.
STATIC_BADGE='# Demo\n\n[![Version](https://img.shields.io/badge/version-3.0.0-blue.svg)](https://github.com/netresearch/demo-skill/releases)\n'
readme_case static_badge "$STATIC_BADGE" expect-present \
    "static version badge" "a hand-typed version badge warns"
LIVE_BADGE='# Demo\n\n[![Release](https://img.shields.io/github/v/release/netresearch/demo-skill?sort=semver)](https://github.com/netresearch/demo-skill/releases)\n'
readme_case live_badge "$LIVE_BADGE" expect-absent \
    "static version badge" "the live release badge does not warn"

echo "----------------------------------------"
echo "Release path checks (issue #341)"
echo "----------------------------------------"
# A GitLab skill repository has no release.yml and must not have one: the
# claude-code-skill CI component creates the Release from the tag pipeline.
# The validator used to demand the file there, an error nobody could act on.

# release_case <name> <gitlab-ci-content|-> <with-release-yml:yes|no> <expect-present|expect-absent> <pattern> <label>
release_case() {
    local name="$1" ci="$2" rel="$3" want="$4" pat="$5" label="$6" dir out
    dir="$TMP/rel_$name"
    rm -rf "$dir"; mkdir -p "$dir"
    [[ "$ci" == "-" ]] || printf '%b' "$ci" > "$dir/.gitlab-ci.yml"
    if [[ "$rel" == yes ]]; then
        mkdir -p "$dir/.github/workflows"
        printf 'name: Release\n' > "$dir/.github/workflows/release.yml"
    fi
    out="$(bash "$VALIDATOR" "$dir" 2>&1)"
    case "$want" in
        expect-present)
            if grep -qF -- "$pat" <<< "$out"; then ((PASS++)); else
                echo "  FAIL $label: expected output matching '$pat'"; ((FAIL++)); fi ;;
        expect-absent)
            if grep -qF -- "$pat" <<< "$out"; then
                echo "  FAIL $label: '$pat' should NOT have fired"; ((FAIL++)); else ((PASS++)); fi ;;
    esac
    return 0
}

# Copied from coding-ai/ecom-orocommerce-docker-skill, the repository #341 was
# measured on — the real include line, not a reconstruction of it.
# shellcheck disable=SC2016  # literal YAML fixture, $CI_SERVER_FQDN is not an expansion
REAL_GITLAB_CI='# Pipeline = central component. See ci-components/claude-code-skill for jobs.\ninclude:\n  - component: $CI_SERVER_FQDN/ci-components/claude-code-skill/skill-pipeline@v1\n'
release_case gitlab_component "$REAL_GITLAB_CI" no expect-absent \
    "release.yml not found" "a GitLab repo with the component is not asked for release.yml"
release_case gitlab_component_ok "$REAL_GITLAB_CI" no expect-present \
    "the claude-code-skill CI component creates the Release" "the component is recognised as the release path"
release_case gitlab_no_component 'stages: [test]\n' no expect-present \
    "does not include the claude-code-skill CI component" "a GitLab repo without the component is an error"
# The name in a comment is not an include: nothing would create the Release.
release_case gitlab_comment_only '# claude-code-skill component removed\nstages: [test]\n' no expect-present \
    "does not include the claude-code-skill CI component" "a comment naming the component is not an include"
release_case github_missing - no expect-present \
    "release.yml not found" "a GitHub repo without release.yml is still an error"
release_case github_present - yes expect-present \
    "release.yml exists" "a GitHub repo with release.yml passes"

echo "----------------------------------------"
echo "Script test lookup"
echo "----------------------------------------"
# A repository may keep its tests next to the scripts, under
# skills/<name>/scripts/tests/ (github-release-skill does). The lookup used to
# read only a root tests/ directory, so every such script was reported as
# untested although a test named it.

# script_test_case <name> <test-location: root|beside|none> <expect-present|expect-absent> <pattern> <label>
script_test_case() {
    local name="$1" where="$2" want="$3" pat="$4" label="$5" dir out
    dir="$TMP/st_$name"
    rm -rf "$dir"; mkdir -p "$dir/skills/d/scripts"
    printf '%b' "${hdr}description: Use when doing X\n---\n# D\n" > "$dir/skills/d/SKILL.md"
    printf '#!/usr/bin/env bash\necho hi\n' > "$dir/skills/d/scripts/x.sh"
    case "$where" in
        root)   mkdir -p "$dir/tests"; printf 'bash skills/d/scripts/x.sh\n' > "$dir/tests/x.sh" ;;
        beside) mkdir -p "$dir/skills/d/scripts/tests"; printf 'bash ../x.sh\n' > "$dir/skills/d/scripts/tests/x.test.sh" ;;
        none)   ;;
    esac
    out="$(bash "$VALIDATOR" "$dir" 2>&1)"
    case "$want" in
        expect-present)
            if grep -qF -- "$pat" <<< "$out"; then ((PASS++)); else
                echo "  FAIL $label: expected output matching '$pat'"; ((FAIL++)); fi ;;
        expect-absent)
            if grep -qF -- "$pat" <<< "$out"; then
                echo "  FAIL $label: '$pat' should NOT have fired"; ((FAIL++)); else ((PASS++)); fi ;;
    esac
    return 0
}

script_test_case beside beside expect-absent \
    "no test references these script(s)" "a test under skills/*/scripts/tests/ counts"
script_test_case beside_ok beside expect-present \
    "is referenced by a test" "a script tested beside itself is reported as tested"
script_test_case root root expect-absent \
    "no test references these script(s)" "a test under tests/ still counts"
script_test_case none none expect-present \
    "no test references these script(s): x.sh" "a script no test names still warns"

echo "== Python scripts declare >=3.11 and start through uv run (retro-skill#201) =="
PY_MANIFEST='{"name":"d","version":"1.0.0"}'
PY_PLAIN='#!/usr/bin/env python3\nprint(1)\n'
# py_case <mode:755|644> <script head> <skill line> <expect-pattern> <want:present|absent> <label> [script name]
py_case() {
    local mode="$1" head="$2" line="$3" pat="$4" want="$5" label="$6" name="${7:-x.py}" dir out
    dir="$(mktemp -d)"; mkdir -p "$dir/skills/d/scripts" "$dir/skills/d/references"
    printf '%s\n' "$PY_MANIFEST" > "$dir/plugin.json"
    printf '%b\nprint(1)\n' "$head" > "$dir/skills/d/scripts/$name"
    chmod "$mode" "$dir/skills/d/scripts/$name"
    {
        printf -- '---\nname: d\ndescription: "Use when exercising the Python floor check."\n---\n\n# D\n\n'
        printf 'Run %s.\n\n%s\n' "$name" "$line"
    } > "$dir/skills/d/SKILL.md"
    out="$(run_validator fallback "$dir")"
    rm -rf "$dir"
    if [[ "$want" == present ]] && grep -qF -- "$pat" <<<"$out"; then ((PASS++))
    elif [[ "$want" == absent ]] && ! grep -qF -- "$pat" <<<"$out"; then ((PASS++))
    else echo "  FAIL [python-floor] $label: expected '$pat' $want"; ((FAIL++)); fi
    return 0
}
good_head='#!/usr/bin/env -S uv run --script\n#\n# /// script\n# requires-python = ">=3.11"\n# dependencies = []\n# ///'
# shellcheck disable=SC2016  # the validator must see ${CLAUDE_SKILL_DIR} unexpanded
uv_line='uv run ${CLAUDE_SKILL_DIR}/scripts/x.py'
py_case 755 '#!/usr/bin/env python3' "$uv_line" 'scripts/x.py: no requires-python' present \
    "an executable script without a PEP 723 block warns"
py_case 755 "${good_head/3.11/3.10}" "$uv_line" 'scripts/x.py: >=3.10' present \
    "a floor below 3.11 warns"
py_case 755 "$good_head" "$uv_line" 'requires-python = ">=3.11" in a PEP 723' absent \
    "a script declaring >=3.11 is quiet"
py_case 755 "${good_head/-S uv run --script/python3}" "$uv_line" 'scripts/x.py - start the file with' present \
    "a >=3.11 block under a python3 shebang warns"
py_case 755 "$good_head" "$uv_line" 'start the file with' absent \
    "the uv shebang is quiet"
py_case 644 '# a module loaded by path' "$uv_line" 'requires-python = ">=3.11" in a PEP 723' absent \
    "a non-executable module is not checked"
# Case one is the line from retro-skill's commands/retro.md that crashed on macOS;
# its trailing backslash is the line continuation of the original.
# shellcheck disable=SC2016,SC1003
py_case 755 "$good_head" 'python3 ${CLAUDE_SKILL_DIR}/scripts/x.py \' 'SKILL.md:10: python3 ${CLAUDE_SKILL_DIR}/scripts/x.py' present \
    "a python3 call in SKILL.md warns with its line"
# Copied from retro-skill's references/workflow.md: `\c` ends `echo -e` output.
# shellcheck disable=SC2016
py_case 755 "$good_head" 'py -3 -X utf8 "$skillDir\scripts\codex-transcript.py" --transcript-file $transcript --match $token |' 'SKILL.md:10: py -3 -X utf8 $skillDir\scripts\codex-transcript.py - start Python' present \
    "a Windows py -3 call warns and its backslashes survive echo -e" codex-transcript.py
# Copied from markdown-to-pdf-skill's SKILL.md: uv reads no header behind `python3`.
# shellcheck disable=SC2016
py_case 755 "$good_head" 'uv run --with markdown --with weasyprint python3 "${SKILL_DIR}/scripts/convert.py" in.md' 'SKILL.md:10: python3 ${SKILL_DIR}/scripts/convert.py - start Python' present \
    "uv run python3 without --python warns" convert.py
# shellcheck disable=SC2016
py_case 755 "$good_head" 'uv run ${CLAUDE_SKILL_DIR}/scripts/x.py && python3 ${CLAUDE_SKILL_DIR}/scripts/x.py' 'SKILL.md:10: python3 ${CLAUDE_SKILL_DIR}/scripts/x.py - start Python' present \
    "a python3 call after && warns although the line starts with uv run"
# shellcheck disable=SC2016
py_case 755 "$good_head" 'uv run --python 3.12 python ${CLAUDE_SKILL_DIR}/scripts/x.py && python3 ${CLAUDE_SKILL_DIR}/scripts/x.py' 'SKILL.md:10: python3 ${CLAUDE_SKILL_DIR}/scripts/x.py - start Python' present \
    "the --python of an earlier command does not cover a later python3"
# shellcheck disable=SC2016
py_case 755 "$good_head" 'python3 \
  ${CLAUDE_SKILL_DIR}/scripts/x.py --flag' 'SKILL.md:10: python3    ${CLAUDE_SKILL_DIR}/scripts/x.py - start Python' present \
    "a call continued onto the next line warns at its first line"
py_case 755 "$good_head" "$uv_line" 'start Python scripts with' absent \
    "a uv run call is quiet"
# shellcheck disable=SC2016
py_case 755 "$good_head" 'uv run --python 3.12 python ${CLAUDE_SKILL_DIR}/scripts/x.py' 'start Python scripts with' absent \
    "the CI form uv run --python X python is quiet"
# Copied from motion-video-skill's SKILL.md:256: the directory sits in a variable.
# shellcheck disable=SC2016
py_case 755 "$good_head" 'python3 "$S"/stt_check.py out/my-video.mp4 --words audio/vo.words.json --offset 0.5 --cues audio/mix.cues.json  # authorized speech check' 'SKILL.md:10: python3 $S/stt_check.py - start Python' present \
    "a call whose directory is a variable warns" stt_check.py
py_case 755 "$good_head" "python3 -c \"print(open('scripts/x.py').read())\"" 'start Python scripts with' absent \
    "inline code that mentions a shipped script is quiet"
# Copied from markdown-to-pdf-skill's SKILL.md:77: prose naming the wrong call.
# shellcheck disable=SC2016  # the backticks are Markdown, not command substitution
py_case 755 "$good_head" '| WeasyPrint missing | `uv run convert.py` installs it from the script'"'"'s inline metadata; if it was started as `python3 convert.py`, rerun it with `uv run` |' 'start Python scripts with' absent \
    "a bare script name without a directory is quiet" convert.py
# Copied from git-workflow-skill's references/code-quality-tools.md: an example, no shipped script.
py_case 755 "$good_head" 'guard() { python3 ./scripts/guard.py "$@"; }' 'start Python scripts with' absent \
    "a call naming a script the repository does not ship is quiet"
# A directory named like a script must not crash the scan and drop the other findings.
dir_dir="$(mktemp -d)"; mkdir -p "$dir_dir/skills/d/scripts/bad.py"
printf '%s\n' "$PY_MANIFEST" > "$dir_dir/plugin.json"
printf '%b' "$PY_PLAIN" > "$dir_dir/skills/d/scripts/x.py"; chmod 755 "$dir_dir/skills/d/scripts/x.py"
printf -- '---\nname: d\ndescription: "Use when exercising the Python floor check."\n---\n\n# D\n\nRun x.py.\n' > "$dir_dir/skills/d/SKILL.md"
dir_out="$(run_validator fallback "$dir_dir")"
rm -rf "$dir_dir"
if grep -qF 'scripts/x.py: no requires-python' <<<"$dir_out"; then ((PASS++)); else
    echo "  FAIL [python-floor] a directory named scripts/bad.py hides the other findings"; ((FAIL++)); fi

# The crash itself came from a slash command, outside the skill directory.
cmd_dir="$(mktemp -d)"; mkdir -p "$cmd_dir/skills/d/scripts" "$cmd_dir/commands"
printf '%s\n' "$PY_MANIFEST" > "$cmd_dir/plugin.json"
printf -- '---\nname: d\ndescription: "Use when exercising the Python floor check."\n---\n\n# D\n\nRun detect-mechanical.py.\n' > "$cmd_dir/skills/d/SKILL.md"
printf '%b\nprint(1)\n' "$good_head" > "$cmd_dir/skills/d/scripts/detect-mechanical.py"; chmod 755 "$cmd_dir/skills/d/scripts/detect-mechanical.py"
# shellcheck disable=SC2016,SC1003
printf '%s\n' '---' 'description: "x"' '---' '' 'python3 ${CLAUDE_PLUGIN_ROOT}/skills/retro/scripts/detect-mechanical.py \' '  --transcript-file "$TF"' > "$cmd_dir/commands/retro.md"
cmd_out="$(cd "$cmd_dir" && PYTHONPATH="$SHIM" bash "$VALIDATOR" . 2>&1)"
rm -rf "$cmd_dir"
# shellcheck disable=SC2016
if grep -qF 'commands/retro.md:5: python3 ${CLAUDE_PLUGIN_ROOT}/skills/retro/scripts/detect-mechanical.py - start Python' <<<"$cmd_out"; then ((PASS++)); else
    echo "  FAIL [python-floor] a python3 call in commands/*.md warns, run as 'validate-skill.sh .'"; ((FAIL++)); fi

# Hooks start root scripts/ on every matching tool call. The command is copied
# from data-tools-skill's hooks/hooks.json. A root script hooks.json does not
# name is a maintenance tool and is not checked.
hk_dir="$(mktemp -d)"; mkdir -p "$hk_dir/skills/d" "$hk_dir/scripts" "$hk_dir/hooks"
printf '%s\n' "$PY_MANIFEST" > "$hk_dir/plugin.json"
# shellcheck disable=SC2016
printf -- '---\nname: d\ndescription: "Use when exercising the Python floor check."\n---\n\n# D\n\nRun:\n\npython3 ${CLAUDE_PLUGIN_ROOT}/scripts/maint.py\n' > "$hk_dir/skills/d/SKILL.md"
for n in pre_bash_structured_warn.py maint.py; do
    printf '%b' "$PY_PLAIN" > "$hk_dir/scripts/$n"; chmod 755 "$hk_dir/scripts/$n"
done
# shellcheck disable=SC2016
printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [' \
    '  {"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/pre_bash_structured_warn.py"},' \
    '  {"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/qa_gate_hook.py"},' \
    '  {"type": "command", "command": "uv run ${CLAUDE_PLUGIN_ROOT}/hooks/floored_hook.py"},' \
    '  {"type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/pre_bash_structured_warn.py\" --x"}' \
    ']}]}}' > "$hk_dir/hooks/hooks.json"
# 100644, as in it-maintenance-skill: a hook needs no executable bit. The second
# one declares the floor; not executable, its python3 shebang is never used.
printf '%b' "$PY_PLAIN" > "$hk_dir/hooks/qa_gate_hook.py"; chmod 644 "$hk_dir/hooks/qa_gate_hook.py"
printf '%b\nprint(1)\n' "${good_head/-S uv run --script/python3}" > "$hk_dir/hooks/floored_hook.py"; chmod 644 "$hk_dir/hooks/floored_hook.py"
hk_out="$(cd "$hk_dir" && PYTHONPATH="$SHIM" bash "$VALIDATOR" . 2>&1)"
rm -rf "$hk_dir"
# shellcheck disable=SC2016
for want in 'hooks/hooks.json:2: python3 ${CLAUDE_PLUGIN_ROOT}/scripts/pre_bash_structured_warn.py - start Python' \
            'scripts/pre_bash_structured_warn.py: no requires-python' \
            'hooks/hooks.json:3: python3 ${CLAUDE_PLUGIN_ROOT}/hooks/qa_gate_hook.py - start Python' \
            'hooks/qa_gate_hook.py: no requires-python' \
            'hooks/hooks.json:5: python3 ${CLAUDE_PLUGIN_ROOT}/scripts/pre_bash_structured_warn.py - start Python' \
            'skills/d/SKILL.md:10: python3 ${CLAUDE_PLUGIN_ROOT}/scripts/maint.py - start Python'; do
    if grep -qF -- "$want" <<<"$hk_out"; then ((PASS++)); else
        echo "  FAIL [python-floor] hooks and root scripts: expected '$want'"; ((FAIL++)); fi
done
# The fixture's commands are unquoted, so the quoting check names this file too.
if grep -F 'hooks/floored_hook.py' <<<"$hk_out" | grep -qvF 'put the placeholder'; then
    echo "  FAIL [python-floor] a non-executable hook script with the floor got a warning"; ((FAIL++)); else ((PASS++)); fi
if grep -qF 'scripts/maint.py: no requires-python' <<<"$hk_out"; then
    echo "  FAIL [python-floor] a root script hooks.json does not name was checked"; ((FAIL++)); else ((PASS++)); fi

# Root SKILL.md layout, as in pagerangers-skill: repo/scripts is the skill's
# scripts/, and a 100644 hook script there still needs the floor.
rs_dir="$(mktemp -d)"; mkdir -p "$rs_dir/scripts" "$rs_dir/hooks"
printf '%s\n' "$PY_MANIFEST" > "$rs_dir/plugin.json"
printf -- '---\nname: d\ndescription: "Use when exercising the Python floor check."\n---\n\n# D\n\nRun detect_credentials.py.\n' > "$rs_dir/SKILL.md"
printf '%b' "$PY_PLAIN" > "$rs_dir/scripts/detect_credentials.py"; chmod 644 "$rs_dir/scripts/detect_credentials.py"
printf '%b' "$PY_PLAIN" > "$rs_dir/scripts/helper.py"; chmod 644 "$rs_dir/scripts/helper.py"
# shellcheck disable=SC2016
printf '%s\n' '{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "uv run ${CLAUDE_PLUGIN_ROOT}/scripts/detect_credentials.py"}]}]}}' > "$rs_dir/hooks/hooks.json"
rs_out="$(cd "$rs_dir" && PYTHONPATH="$SHIM" bash "$VALIDATOR" . 2>&1)"
rm -rf "$rs_dir"
if [[ "$(grep -cF 'scripts/detect_credentials.py: no requires-python' <<<"$rs_out")" -eq 1 ]]; then ((PASS++)); else
    echo "  FAIL [python-floor] root SKILL.md: a 100644 hook script is reported once"; ((FAIL++)); fi
if grep -qF 'scripts/helper.py' <<<"$rs_out"; then
    echo "  FAIL [python-floor] root SKILL.md: a 100644 module hooks.json does not name was checked"; ((FAIL++)); else ((PASS++)); fi
# The Python floor is an error, not a warning: read the severity, not the wording.
if grep -F 'scripts/detect_credentials.py: no requires-python' <<<"$rs_out" | grep -qF 'ERROR:'; then ((PASS++)); else
    echo "  FAIL [python-floor] a script without the floor is reported as an ERROR"; ((FAIL++)); fi

echo "== Hook commands quote their path placeholders =="
# Case one is github-release-skill's guard command before #204 quoted it: under
# a plugin root with a space, uv could not open the script and exited 2.
q_dir="$(mktemp -d)"; mkdir -p "$q_dir/skills/d" "$q_dir/hooks"
printf '%s\n' "$PY_MANIFEST" > "$q_dir/plugin.json"
printf -- '---\nname: d\ndescription: "Use when exercising the hook quoting check."\n---\n\n# D\n' > "$q_dir/skills/d/SKILL.md"
# shellcheck disable=SC2016
printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [' \
    '  {"type": "command", "command": "uv run ${CLAUDE_PLUGIN_ROOT}/skills/github-release/scripts/guard-gh-release.py", "onFailure": "block"},' \
    '  {"type": "command", "command": "bash ${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh"},' \
    '  {"type": "command", "command": "uv run --offline \"${CLAUDE_PLUGIN_ROOT}/scripts/quoted.py\" || true"},' \
    '  {"type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}\"/scripts/format.js --fix"},' \
    '  {"type": "command", "command": "sh -c '"'"'uv run ${CLAUDE_PLUGIN_ROOT}/nested.py'"'"'"},' \
    '  {"type": "command", "command": "uv run '"'"'${CLAUDE_PLUGIN_ROOT}/single.py'"'"'"},' \
    '  {"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/exec.py", "args": ["--check"]}' \
    ']}]}}' > "$q_dir/hooks/hooks.json"
q_out="$(cd "$q_dir" && PYTHONPATH="$SHIM" bash "$VALIDATOR" . 2>&1)"
rm -rf "$q_dir"
# shellcheck disable=SC2016
for want in 'hooks/hooks.json: uv run ${CLAUDE_PLUGIN_ROOT}/skills/github-release/scripts/guard-gh-release.py - put the placeholder' \
            'hooks/hooks.json: bash ${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh - put the placeholder' \
            "hooks/hooks.json: sh -c 'uv run \${CLAUDE_PLUGIN_ROOT}/nested.py' - put the placeholder" \
            "hooks/hooks.json: uv run '\${CLAUDE_PLUGIN_ROOT}/single.py' - put the placeholder"; do
    if grep -F -- "$want" <<<"$q_out" | grep -qF 'WARNING:'; then ((PASS++)); else
        echo "  FAIL [hook-quote] expected a WARNING '$want'"; ((FAIL++)); fi
done
for quiet in quoted.py format.js exec.py; do
    if grep -F 'put the placeholder' <<<"$q_out" | grep -qF -- "$quiet"; then
        echo "  FAIL [hook-quote] $quiet is quoted or exec form and must stay quiet"; ((FAIL++)); else ((PASS++)); fi
done

echo "== Organisation reusables are called at @main =="
# reusable_case <name> <want> <workflow line> <label>
# Case one is the line that slipped into netresearch-branding-skill, copied.
reusable_case() {
    local name="$1" want="$2" line="$3" label="$4" dir out
    dir="$(fixture "reusable_$name" "${hdr}description: Use when doing X\n---\n# T\n")"
    mkdir -p "$dir/.github/workflows"
    printf 'jobs:\n  j:\n%s\n' "$line" > "$dir/.github/workflows/ci.yml"
    out="$(bash "$VALIDATOR" "$dir" 2>&1)"
    local got=accept
    if grep -qF "reusable workflow pinned to a commit hash: .github/workflows/ci.yml:3" <<<"$out"; then
        got=reject
    fi
    if [[ "$got" == "$want" ]]; then ((PASS++)); else
        echo "  FAIL $label: expected $want, got $got"; ((FAIL++)); fi
    return 0
}
reusable_case real reject \
    '    uses: netresearch/.github/.github/workflows/script-check.yml@d9e0aa0325124dbee7a2ad206f76dcf37347d0ba # main' \
    "the hash pin found in netresearch-branding-skill is rejected"
reusable_case quoted reject \
    "    uses: 'netresearch/skill-repo-skill/.github/workflows/validate.yml@0123456789abcdef0123456789abcdef01234567'" \
    "a quoted hash pin is rejected"
reusable_case spaced reject \
    '    uses : netresearch/.github/.github/workflows/script-check.yml@0123456789abcdef0123456789abcdef01234567' \
    "a hash pin written with a space before the colon is rejected"
reusable_case main accept \
    '    uses: netresearch/.github/.github/workflows/script-check.yml@main' \
    "@main is accepted"
reusable_case thirdparty accept \
    '    uses: actions/checkout/.github/workflows/x.yml@0123456789abcdef0123456789abcdef01234567' \
    "a third-party SHA pin is not this check's business"

echo "----------------------------------------"
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || { echo "Smoke tests FAILED"; exit 1; }
echo "All validator smoke tests passed"
