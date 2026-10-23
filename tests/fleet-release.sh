#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# tests/fleet-release.sh — exercises the fleet-release driver set:
#   skills/skill-repo/scripts/fleet-release-common.sh   (shared engine)
#   skills/skill-repo/scripts/fleet-release-github.sh   (public GitHub driver)
#   skills/skill-repo/scripts/fleet-repos-github.txt    (default fleet list)
#
# Everything here is offline: classification, version ordering, parity from a
# ref, tag idempotency, checkout-layout resolution, plan validation, the log
# invariant — the logic classes that historically broke in hand-written sweep
# drivers. Each guard tested HERE is observed to fail on a violating fixture,
# not just to pass on a clean one. Scope limit, stated plainly: the GitHub
# merge gate, the Release verification and one survey row run here against a
# stub `gh` (what ends their wait and what does not, and how a compare
# response becomes a row); the other network phases (the rest of the survey,
# bump/finish API calls) have no offline test — they are exercised against live hosts before
# releases, and their guards (freshness gate, foreign-PR stop, merge-commit
# anchoring) are enforced by code review plus the read-only live runs.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)/skills/skill-repo/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

# The lib is sourced, not executed; give it a self identity for the author gate.
# shellcheck disable=SC2034  # both are read by the sourced engine
declare FR_SELF_LOGIN=sweep-bot FR_HOST=test
FR_WORKDIR="$WORK/wd"
mkdir -p "$FR_WORKDIR"
# shellcheck source=../skills/skill-repo/scripts/fleet-release-common.sh
# shellcheck disable=SC1091  # resolved at runtime relative to this test
source "$SCRIPTS/fleet-release-common.sh"

echo "fleet-release-common.sh"

# --- version ordering: the 1.10.0 > 1.9.0 class -----------------------------
check "vercmp 1.10.0 > 1.9.0 (never lexicographic)" 1 "$(fr_vercmp 1.10.0 1.9.0)"
check "vercmp 1.9.0 < 1.10.0" -1 "$(fr_vercmp 1.9.0 1.10.0)"
check "vercmp equal" 0 "$(fr_vercmp 1.2.3 1.2.3)"
check "vercmp strips v prefix" 0 "$(fr_vercmp v1.2.3 1.2.3)"
# Custom tag conventions order by their TRAILING semver — a parse that degrades
# them all to zero made max_by pick an arbitrary old tag, and tender-estimation
# (deliberate `<repo>--vX.Y.Z` convention) read as DIVERGED live on 2026-08-13.
check "vercmp orders custom-prefixed tags by trailing semver" 1 \
    "$(fr_vercmp tender-estimation--v0.7.0 tender-estimation--v0.6.1)"
check "vercmp custom-prefixed tag equals its bare version" 0 \
    "$(fr_vercmp tender-estimation--v0.7.0 0.7.0)"

# --- checkout-layout resolution ----------------------------------------------
mk_repo() { # DIR — a minimal committed repo
    git init -q -b main "$1"
    ( cd "$1" && echo x > f && git add f && git commit -q -m init )
}
mkdir -p "$WORK/layout-bare"
git init -q --bare "$WORK/layout-bare/.bare"
check "layout: dir/.bare wins" "$WORK/layout-bare/.bare" \
    "$(fr_resolve_gitdir "$WORK/layout-bare")"
mk_repo "$WORK/layout-plain"
check "layout: plain repo at top level" yes \
    "$(fr_resolve_gitdir "$WORK/layout-plain" > /dev/null && echo yes || echo no)"
mkdir -p "$WORK/layout-nested"
mk_repo "$WORK/layout-nested/main"
check "layout: plain clone under main/" yes \
    "$(fr_resolve_gitdir "$WORK/layout-nested" > /dev/null && echo yes || echo no)"
check "layout: nothing there refused" no \
    "$(fr_resolve_gitdir "$WORK/does-not-exist" > /dev/null 2>&1 && echo yes || echo no)"

# --- origin verification: folder names lie -----------------------------------
mk_repo "$WORK/origin-check"
git -C "$WORK/origin-check" remote add origin git@github.com:acme/right-repo.git
check "origin match (ssh form)" yes \
    "$(fr_check_origin "$WORK/origin-check" "github.com/acme/right-repo" 2> /dev/null && echo yes || echo no)"
git -C "$WORK/origin-check" remote set-url origin https://github.com/acme/right-repo.git
check "origin match (https form)" yes \
    "$(fr_check_origin "$WORK/origin-check" "github.com/acme/right-repo" 2> /dev/null && echo yes || echo no)"
check "origin MISMATCH refused (would push to a foreign remote)" no \
    "$(fr_check_origin "$WORK/origin-check" "github.com/acme/other-repo" 2> /dev/null && echo yes || echo no)"
git -C "$WORK/origin-check" remote set-url origin "ssh://git@github.com:2222/acme/right-repo.git"
check "origin match survives an explicit port" yes \
    "$(fr_check_origin "$WORK/origin-check" "github.com/acme/right-repo" 2> /dev/null && echo yes || echo no)"
git -C "$WORK/origin-check" remote set-url origin "https://evil.example/github.com/acme/right-repo.git"
check "crafted path tail mimicking host/org/repo refused (exact match, not suffix)" no \
    "$(fr_check_origin "$WORK/origin-check" "github.com/acme/right-repo" 2> /dev/null && echo yes || echo no)"

# --- parity from a ref, never a working tree ---------------------------------
mk_parity_repo() { # DIR VERSION [composer-version|-] [skill-version]
    local d="$1" v="$2" cv="${3:--}" sv="${4:-$2}"
    git init -q -b main "$d"
    mkdir -p "$d/.claude-plugin" "$d/skills/demo"
    printf '{"name":"demo","version":"%s"}\n' "$v" > "$d/plugin.json"
    printf '{"name":"demo","version":"%s"}\n' "$v" > "$d/.claude-plugin/plugin.json"
    if [ "$cv" = "-" ]; then
        printf '{"name":"acme/demo"}\n' > "$d/composer.json"
    else
        printf '{"name":"acme/demo","version":"%s"}\n' "$cv" > "$d/composer.json"
    fi
    printf -- '---\nname: demo\ndescription: "Use when testing."\nmetadata:\n  version: "%s"\n---\n# Demo\n' \
        "$sv" > "$d/skills/demo/SKILL.md"
    ( cd "$d" && git add -A && git commit -q -m x )
}
mk_parity_repo "$WORK/parity-ok" 1.2.3
check "parity: consistent tree passes" yes \
    "$(fr_parity_from_ref "$WORK/parity-ok" HEAD 1.2.3 2> /dev/null && echo yes || echo no)"
check "parity: wrong expected version refused" no \
    "$(fr_parity_from_ref "$WORK/parity-ok" HEAD 1.2.4 2> /dev/null && echo yes || echo no)"
mk_parity_repo "$WORK/parity-composer" 1.2.3 9.9.9
check "parity: composer version field refused (TAG-ONLY path has no bump-version.sh to catch it)" no \
    "$(fr_parity_from_ref "$WORK/parity-composer" HEAD 1.2.3 2> /dev/null && echo yes || echo no)"
mk_parity_repo "$WORK/parity-skill" 1.2.3 - 1.0.0
check "parity: stale SKILL.md frontmatter refused" no \
    "$(fr_parity_from_ref "$WORK/parity-skill" HEAD 1.2.3 2> /dev/null && echo yes || echo no)"
# A --- rule in the BODY must not reopen frontmatter parsing — a stray body
# "version:" line would otherwise be read as the skill version.
mk_parity_repo "$WORK/parity-body" 1.2.3
printf -- '---\nname: demo\ndescription: "Use when testing."\nmetadata:\n  version: "1.2.3"\n---\n# Demo\n\n---\n\nExample config:\n\n    version: "9.9.9"\n' \
    > "$WORK/parity-body/skills/demo/SKILL.md"
( cd "$WORK/parity-body" && git add -A && git commit -q -m body )
check "parity: a version: line after a body --- rule is ignored" yes \
    "$(fr_parity_from_ref "$WORK/parity-body" HEAD 1.2.3 2> /dev/null && echo yes || echo no)"

# --- tag idempotency: peeled refs, local-tag recovery ------------------------
ORIGIN="$WORK/tag-origin"
git init -q --bare "$ORIGIN"
CLONE="$WORK/tag-clone"
mk_repo "$CLONE"
git -C "$CLONE" remote add origin "$ORIGIN"
git -C "$CLONE" push -q origin main
TIP=$(git -C "$CLONE" rev-parse HEAD)
# An annotated (unsigned, like signed-minus-signature) tag already on the remote:
git -C "$CLONE" tag -a v1.0.0 -m v1.0.0 "$TIP"
git -C "$CLONE" push -q origin v1.0.0
check "remote tag commit is the PEELED sha (annotated object != commit)" "$TIP" \
    "$(fr_remote_tag_commit "$CLONE" v1.0.0)"
check "tag already on remote at tip: skip, not re-tag" yes \
    "$(fr_tag_on_tip "$CLONE" v1.0.0 "$TIP" > /dev/null 2>&1 && echo yes || echo no)"
check "tag on remote at a DIFFERENT commit: refused (immutable)" no \
    "$(fr_tag_on_tip "$CLONE" v1.0.0 0000000000000000000000000000000000000000 > /dev/null 2>&1 && echo yes || echo no)"
# Crash window: local tag created, push never happened. Only the driver's own
# SIGNED tag may be pushed — an unsigned annotated tag at the tip is somebody
# else's work.
git -C "$CLONE" tag -a v1.9.9 -m v1.9.9 "$TIP"
check "local UNSIGNED tag at tip: refused" no \
    "$(fr_tag_on_tip "$CLONE" v1.9.9 "$TIP" > /dev/null 2>&1 && echo yes || echo no)"
check "…and it never reached the remote" "" "$(fr_remote_tag_commit "$CLONE" v1.9.9)"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/sigkey"
git -C "$CLONE" config gpg.format ssh
git -C "$CLONE" config user.signingkey "$WORK/sigkey"
if git -C "$CLONE" tag -s v1.1.0 -m v1.1.0 "$TIP" 2> /dev/null; then
    check "local SIGNED tag at tip (crashed before push): pushed, not re-created" yes \
        "$(fr_tag_on_tip "$CLONE" v1.1.0 "$TIP" > /dev/null 2>&1 && echo yes || echo no)"
    check "…and it arrived on the remote" "$TIP" "$(fr_remote_tag_commit "$CLONE" v1.1.0)"
else
    echo "  skip signed-tag recovery tests (ssh signing unavailable)"
fi
( cd "$CLONE" && echo y >> f && git add f && git commit -q -m second )
TIP2=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" tag -a v1.2.0 -m v1.2.0 "$TIP"   # points at the OLD commit
check "local tag at the wrong commit: refused with instructions" no \
    "$(fr_tag_on_tip "$CLONE" v1.2.0 "$TIP2" > /dev/null 2>&1 && echo yes || echo no)"
# "Cannot see the remote" must never read as "tag absent": a doomed duplicate
# push would follow.
mk_repo "$WORK/no-remote"
git -C "$WORK/no-remote" remote add origin /nonexistent/nowhere.git
rc2=0; fr_remote_tag_commit "$WORK/no-remote" v1.0.0 > /dev/null 2>&1 || rc2=$?
check "unreadable remote reports rc=2, not 'tag absent'" 2 "$rc2"
check "tag_on_tip refuses to tag blind on an unreadable remote" no \
    "$(fr_tag_on_tip "$WORK/no-remote" v1.0.0 "$TIP" > /dev/null 2>&1 && echo yes || echo no)"

# --- log invariant + summary markers -----------------------------------------
LOGD="$WORK/logs"
mkdir -p "$LOGD"
printf 'stuff\nOK repo-a done\n' > "$LOGD/repo-a.log"
printf 'stuff\nFAIL repo-b: boom\n' > "$LOGD/repo-b.log"
printf 'started and then nothing\n' > "$LOGD/repo-c.log"
check "log invariant holds at 3/3" yes \
    "$(fr_check_log_invariant "$LOGD" 3 > /dev/null 2>&1 && echo yes || echo no)"
check "log invariant catches a missing log (a killed batch 'completes')" no \
    "$(fr_check_log_invariant "$LOGD" 4 > /dev/null 2>&1 && echo yes || echo no)"
summary=$(fr_summarize_logs "$LOGD" 2> /dev/null; echo "rc=$?")
check "summary counts ok/fail/indeterminate" yes \
    "$(grep -q '1 ok, 1 failed, 1 indeterminate' <<< "$summary" && echo yes || echo no)"
check "summary is nonzero when anything is not OK" yes \
    "$(grep -q 'rc=1' <<< "$summary" && echo yes || echo no)"

# --- classification: one shared implementation, every class ------------------
row() { # KEY=VALUE... — build a survey row over sane defaults
    local json='{"host":"test","repo":"r","resolved":"o/r","default":"main",
      "archived":false,"empty":false,"unreachable":false,"duplicate_of":"",
      "last_release":"v1.9.0","last_tag":"v1.9.0","root_plugin":"1.9.0",
      "claude_plugin":"1.9.0","composer_has_version":false,"release_gate":true,
      "ci_status":"success","ahead":3,"nonci":2,"files_truncated":false,
      "subjects":[],"files":[],"open_release_prs":[],"ci_tag_rules":"","notes":""}'
    jq -c "$1" <<< "$json"
}
check "classify: BUMP" BUMP "$(fr_classify "$(row '.')")"
check "classify: SKIP-CI-ONLY (nonci=0)" SKIP-CI-ONLY "$(fr_classify "$(row '.nonci = 0')")"
check "classify: UP-TO-DATE (ahead=0)" UP-TO-DATE "$(fr_classify "$(row '.ahead = 0')")"
check "classify: TAG-ONLY needs NUMERIC compare (1.10.0 vs v1.9.0)" TAG-ONLY \
    "$(fr_classify "$(row '.claude_plugin = "1.10.0" | .root_plugin = "1.10.0"')")"
check "classify: BEHIND-TAG anomaly" BEHIND-TAG \
    "$(fr_classify "$(row '.claude_plugin = "1.8.0"')")"
check "classify: FIRST-RELEASE" FIRST-RELEASE \
    "$(fr_classify "$(row '.last_release = "" | .last_tag = ""')")"
check "classify: TAG-RELEASE-DIVERGED (tag without Release)" TAG-RELEASE-DIVERGED \
    "$(fr_classify "$(row '.last_release = ""')")"
check "classify: BLOCKED-COMPOSER-VERSION" BLOCKED-COMPOSER-VERSION \
    "$(fr_classify "$(row '.composer_has_version = true')")"
check "classify: BLOCKED-ARCHIVED" BLOCKED-ARCHIVED \
    "$(fr_classify "$(row '.archived = true')")"
check "classify: composer block outranks TAG-ONLY (blocks before actions)" BLOCKED-COMPOSER-VERSION \
    "$(fr_classify "$(row '.composer_has_version = true | .claude_plugin = "1.10.0"')")"
check "classify: NO-RELEASE-JOB" NO-RELEASE-JOB \
    "$(fr_classify "$(row '.release_gate = false')")"
check "classify: foreign release PR blocks (author gate)" BLOCKED-FOREIGN-PR \
    "$(fr_classify "$(row '.open_release_prs = [{"id":"1","url":"u","author":"colleague","branch":"release/v2.0.0","title":"chore(release): v2.0.0"}]')")"
check "classify: own open PR is its own class, not a block" OWN-PR-OPEN \
    "$(fr_classify "$(row '.open_release_prs = [{"id":"1","url":"u","author":"sweep-bot","branch":"release/v2.0.0","title":"chore(release): v2.0.0"}]')")"
check "classify: foreign outranks own when both exist" BLOCKED-FOREIGN-PR \
    "$(fr_classify "$(row '.open_release_prs = [{"id":"1","url":"u","author":"sweep-bot","branch":"b","title":"t"},{"id":"2","url":"u2","author":"colleague","branch":"b2","title":"t2"}]')")"
check "classify: DUPLICATE (rename redirect)" DUPLICATE \
    "$(fr_classify '{"host":"test","repo":"old-name","duplicate_of":"o/new-name"}')"
check "classify: UNREACHABLE" UNREACHABLE \
    "$(fr_classify '{"host":"test","repo":"gone","unreachable":true}')"
check "classify: EMPTY" EMPTY \
    "$(fr_classify '{"host":"test","repo":"bare","resolved":"o/bare","empty":true}')"

# --- FR_CI_ONLY_RE ----------------------------------------------------------
# The survey counts a changed path as consumer-visible unless this filter
# matches it; nonci=0 is what turns a row into SKIP-CI-ONLY. Exercised through
# the same jq `test()` the driver uses, so a pattern valid in grep but not in
# Oniguruma fails here rather than in a live sweep.
nonci() { # FILES-JSON -> count of paths the filter does NOT absorb
    jq --arg f "$FR_CI_ONLY_RE" '[.[] | select(test($f) | not)] | length' <<< "$1"
}
check "ci-only: workflow file" 0 "$(nonci '[".github/workflows/tests.yml"]')"
check "ci-only: renovate.json" 0 "$(nonci '["renovate.json"]')"
check "ci-only: .gitlab-ci.yml" 0 "$(nonci '[".gitlab-ci.yml"]')"
check "ci-only: pre-commit hook pin (#287)" 0 "$(nonci '[".pre-commit-config.yaml"]')"
check "ci-only: markdownlint configs" 0 \
    "$(nonci '[".markdownlint-cli2.jsonc",".markdownlint.jsonc"]')"
check "ci-only: yamllint and editorconfig" 0 \
    "$(nonci '[".yamllint.yml",".editorconfig"]')"
# The filter must not swallow anything a consumer installs.
check "not ci-only: SKILL.md" 1 "$(nonci '["skills/foo/SKILL.md"]')"
check "not ci-only: README.md" 1 "$(nonci '["README.md"]')"
check "not ci-only: plugin manifest" 1 "$(nonci '[".claude-plugin/plugin.json"]')"
# Anchored at the repo root: a config shipped inside a skill is content.
check "not ci-only: nested pre-commit config" 1 \
    "$(nonci '["skills/foo/templates/.pre-commit-config.yaml"]')"
check "not ci-only: mixed delta still counts the content file" 1 \
    "$(nonci '[".pre-commit-config.yaml","skills/foo/SKILL.md"]')"
# --- FR_NOT_SHIPPED_RE and SKIP-NOT-SHIPPED ----------------------------------
# A delta of README/docs/tests commits ships nothing, so it is not a release.
# The rule is an inert list: every path NOT on it counts as shipped, so a path
# nobody thought of releases instead of being skipped. Same jq test() as
# fr_add_shipped.
shipped() { # FILES-JSON -> count of paths the inert filter does NOT absorb
    local files="$1"
    jq --arg f "$FR_NOT_SHIPPED_RE" '[.[] | select(test($f) | not)] | length' <<< "$files"
    return 0
}
check "inert: README, AGENTS, CLAUDE, CHANGELOG, CONTRIBUTING, CODE_OF_CONDUCT" 0 \
    "$(shipped '["README.md","AGENTS.md","CLAUDE.md","CHANGELOG.md","CONTRIBUTING.md","CODE_OF_CONDUCT.md"]')"
check "inert: SECURITY*.md" 0 "$(shipped '["SECURITY.md","SECURITY-AUDIT.md"]')"
check "inert: root docs/, tests/, evals/" 0 \
    "$(shipped '["docs/ARCHITECTURE.md","tests/fleet-release.sh","evals/evals.json"]')"
check "inert: a skill's evals/, tests/ and README.md" 0 \
    "$(shipped '["skills/foo/evals/evals.json","skills/foo/tests/t.sh","skills/foo/README.md"]')"
check "shipped: skill SKILL.md, references, scripts, checkpoints" 4 \
    "$(shipped '["skills/foo/SKILL.md","skills/foo/references/a.md","skills/foo/scripts/x.sh","skills/foo/checkpoints.yaml"]')"
check "shipped: plugin surfaces and manifests at the root" 7 \
    "$(shipped '[".claude-plugin/plugin.json","hooks/hooks.json","commands/c.md","outputStyles/o.md","LICENSE-MIT","plugin.json","composer.json"]')"
# Review round 1: paths an allow-list of shipped paths missed.
check "shipped: a styles/ file a SKILL.md reads (netresearch-jira)" 1 \
    "$(shipped '["skills/netresearch-jira/styles/terse.md"]')"
check "shipped: workflows/ and config/ (it-maintenance, customer-spec)" 2 \
    "$(shipped '["skills/maintenance/workflows/update.md","skills/customer-spec/config/default.yml"]')"
check "shipped: a root package.json (npm files, aiAgentSkill)" 1 "$(shipped '["package.json"]')"
check "shipped: a skill's agents/openai.yaml" 1 "$(shipped '["skills/foo/agents/openai.yaml"]')"
check "shipped: GEMINI.md, which a Gemini extension loads" 1 "$(shipped '["GEMINI.md"]')"
check "shipped: a path that only resembles an inert one" 3 \
    "$(shipped '["docs.md","skills/foo/docs/a.md","README.md.tmpl"]')"

# The survey adds the count from the row's own files, for every host.
jq_shipped='.shipped'
check "survey: fr_add_shipped counts the non-inert files of the row" 1 \
    "$(fr_add_shipped '{"repo":"r","files":["README.md","skills/x/SKILL.md"]}' | jq "$jq_shipped")"
check "survey: a row without a file list gets no shipped key" null \
    "$(fr_add_shipped '{"repo":"r","unreachable":true}' | jq "$jq_shipped")"
check "survey: a count that cannot be made is -1, never 0" -1 \
    "$(fr_add_shipped '{"repo":"r","files":[1]}' | jq "$jq_shipped")"

docs_only='.files = ["README.md","docs/usage.md"] | .nonci = 2 | .shipped = 0 | .renames_counted = true'
check "classify: README/docs-only delta is SKIP-NOT-SHIPPED" SKIP-NOT-SHIPPED \
    "$(fr_classify "$(row "$docs_only")")"
check "classify: a delta touching skills/x/SKILL.md stays BUMP" BUMP \
    "$(fr_classify "$(row '.files = ["README.md","skills/x/SKILL.md"] | .nonci = 2 | .shipped = 1 | .renames_counted = true')")"
for extra in skills/netresearch-jira/styles/terse.md package.json skills/maintenance/workflows/update.md; do
    check "classify: README plus $extra stays BUMP" BUMP \
        "$(fr_classify "$(fr_add_shipped "$(row ".files = [\"README.md\", \"$extra\"] | .nonci = 2 | .renames_counted = true")")")"
done
check "classify: a truncated file list stays BUMP (unknown, not 'nothing shipped')" BUMP \
    "$(fr_classify "$(row "$docs_only | .files_truncated = true")")"
check "classify: a row without shipped (older survey, other driver) stays BUMP" BUMP \
    "$(fr_classify "$(row "$docs_only | del(.shipped)")")"
check "classify: a failed shipped count (-1) stays BUMP" BUMP \
    "$(fr_classify "$(row "$docs_only | .shipped = -1")")"
check "classify: a file list that does not reconcile with nonci stays BUMP" BUMP \
    "$(fr_classify "$(row '.files = [] | .nonci = 2 | .shipped = 0 | .renames_counted = true')")"
# A driver that reads only the new path of a rename (GitLab's .diffs[].new_path)
# cannot tell a move out of skills/ into docs/ from a docs edit.
check "classify: a row without renames_counted stays BUMP" BUMP \
    "$(fr_classify "$(row "$docs_only | del(.renames_counted)")")"
check "classify: renames_counted = false stays BUMP" BUMP \
    "$(fr_classify "$(row "$docs_only | .renames_counted = false")")"
check "classify: CI-only still outranks not-shipped" SKIP-CI-ONLY \
    "$(fr_classify "$(row '.files = [] | .nonci = 0 | .shipped = 0 | .renames_counted = true')")"
check "classify: no commits is UP-TO-DATE, not SKIP-NOT-SHIPPED" UP-TO-DATE \
    "$(fr_classify "$(row "$docs_only | .ahead = 0")")"

# A FAILED compare measurement (sentinel -1) must never read as "no delta" —
# that silently drops a repo with releasable commits from the sweep.
check "classify: failed compare is SURVEY-INCOMPLETE, never UP-TO-DATE" SURVEY-INCOMPLETE \
    "$(fr_classify "$(row '.ahead = -1 | .nonci = -1')")"
check "classify: failed nonci alone is SURVEY-INCOMPLETE too" SURVEY-INCOMPLETE \
    "$(fr_classify "$(row '.nonci = -1')")"

# --- plan validation refuses before anything mutates -------------------------
PLAN="$WORK/plan.jsonl"
printf '%s\n' '{"repo":"a","classification":"BUMP","version":"1.2.3","default":"main","last":"1.2.2"}' > "$PLAN"
check "plan: complete row passes" yes \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"b","classification":"BUMP","version":"","default":"main"}' >> "$PLAN"
check "plan: empty version on a BUMP row refused" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"c","classification":"BUMP","version":"1.2","default":"main"}' > "$PLAN"
check "plan: non-semver version refused" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' \
    '{"repo":"d","classification":"BUMP","version":"1.3.0","default":"main","last":"1.2.0"}' \
    '{"repo":"d","classification":"BUMP","version":"1.4.0","default":"main","last":"1.2.0"}' > "$PLAN"
check "plan: duplicate rows for one repo refused (two bump PRs otherwise)" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"sub/group","classification":"BUMP","version":"1.3.0","default":"main","last":"1.2.0"}' > "$PLAN"
check "plan: repo name with a slash refused (log/worktree paths would escape)" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
# Monotonicity: a plan below or equal to the surveyed version would ship a
# parity-consistent version REGRESSION no later gate can detect.
printf '%s\n' '{"repo":"e","classification":"BUMP","version":"1.2.0","default":"main","last":"1.10.0"}' > "$PLAN"
check "plan: version below the surveyed one refused" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"f","classification":"BUMP","version":"1.10.0","default":"main","last":"1.10.0"}' > "$PLAN"
check "plan: version equal to the surveyed one refused" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"g","classification":"TAG-ONLY","version":"1.4.0","default":"main","last":"1.3.0"}' > "$PLAN"
check "plan: TAG-ONLY must tag exactly the committed version" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
# FIRST-RELEASE has no previous release or tag to regress from: its `.last` is
# the committed plugin.json version. Tagging a prepared repo as-is must be
# expressible without retyping the row TAG-ONLY or inventing a version.
printf '%s\n' '{"repo":"i","classification":"FIRST-RELEASE","version":"0.7.0","default":"main","last":"0.7.0"}' > "$PLAN"
check "plan: FIRST-RELEASE may tag the already-committed version" yes \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"i","classification":"FIRST-RELEASE","version":"0.8.0","default":"main","last":"0.7.0"}' > "$PLAN"
check "plan: FIRST-RELEASE may also bump above the committed version" yes \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"i","classification":"FIRST-RELEASE","version":"0.6.0","default":"main","last":"0.7.0"}' > "$PLAN"
check "plan: FIRST-RELEASE below the committed version refused (parity would fail)" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
# A lexical compare would call 1.10.0 lower than 1.9.0 and refuse this row.
printf '%s\n' '{"repo":"i","classification":"FIRST-RELEASE","version":"1.10.0","default":"main","last":"1.9.0"}' > "$PLAN"
check "plan: FIRST-RELEASE ordering is NUMERIC (1.10.0 over 1.9.0)" yes \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"h","classification":"OWN-PR-OPEN","version":"","default":"main","last":"1.3.0"}' > "$PLAN"
check "plan: OWN-PR-OPEN needs its version filled" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
# STABILIZE lifts a 0.x repo to its first stable major, with or without new
# content. Anything that is not 0.x -> >=1.0.0 is some other release wearing
# the class, and the seeded promise would then be false.
printf '%s\n' '{"repo":"s","classification":"STABILIZE","version":"1.0.0","default":"main","last":"0.9.3"}' > "$PLAN"
check "plan: STABILIZE 0.9.3 -> 1.0.0 accepted" yes \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"s","classification":"STABILIZE","version":"0.10.0","default":"main","last":"0.9.3"}' > "$PLAN"
check "plan: STABILIZE to another 0.x refused" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"s","classification":"STABILIZE","version":"2.0.0","default":"main","last":"1.4.0"}' > "$PLAN"
check "plan: STABILIZE from a repo already >=1.0 refused" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"s","classification":"STABILIZE","version":"","default":"main","last":"0.9.3"}' > "$PLAN"
check "plan: STABILIZE needs its version filled" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"s","classification":"STABILIZE","version":"1.0.0","default":"main","last":""}' > "$PLAN"
check "plan: STABILIZE without a surveyed version refused (no evidence of 0.x)" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
printf '%s\n' '{"repo":"s","classification":"STABILIZE","version":"1.0.0-rc.1","default":"main","last":"0.9.3"}' > "$PLAN"
check "plan: STABILIZE to a prerelease refused (not a stable release)" no \
    "$( (fr_plan_validate "$PLAN" > /dev/null 2>&1) && echo yes || echo no)"
check "stabilize entry states the major-version promise" yes \
    "$(grep -q 'only in a new major version' <<< "$FR_STABILIZE_ENTRY" && echo yes || echo no)"

# --- opened.jsonl: the author-gate record ------------------------------------
fr_record_opened repo-x 42 https://example.invalid/pr/42 release/v1.0.0
check "opened.jsonl lookup finds the sweep's own PR" 42 "$(fr_opened_lookup repo-x)"
check "opened.jsonl lookup is empty for unopened repos" "" "$(fr_opened_lookup repo-y)"
check "opened.jsonl lookup is host-scoped (cross-host workdir reuse)" "" \
    "$(FR_HOST=otherhost fr_opened_lookup repo-x)"

# --- repo-list resolution ----------------------------------------------------
printf '# comment\n\nrepo-one\nrepo-two\n' > "$WORK/repos.txt"
check "repos: inline wins" "a b" "$(fr_repos_from "a b" "$WORK/repos.txt" /dev/null | tr '\n' ' ' | sed 's/ $//')"
check "repos: file skips comments and blanks" "repo-one repo-two" \
    "$(fr_repos_from "" "$WORK/repos.txt" /dev/null | tr '\n' ' ' | sed 's/ $//')"
check "repos: fallback file" "repo-one repo-two" \
    "$(fr_repos_from "" "" "$WORK/repos.txt" | tr '\n' ' ' | sed 's/ $//')"

# --- survey merge-mode: a partial re-survey must not truncate the rest ------
# (the manifest's own BLOCKED/SURVEY-INCOMPLETE advice is "re-run survey
# --repos X" — losing every other row on that command defeats the repair)
# shellcheck disable=SC2329  # invoked indirectly by the sourced fr_survey
host_survey_repo() { jq -nc --arg r "$1" --arg g "${SURVEY_GEN:-1}" \
    '{host: "test", repo: $r, resolved: ("o/" + $r), gen: $g}'; }
# shellcheck disable=SC2329  # invoked indirectly by the sourced fr_survey
host_display() { echo "test/$1"; }
# shellcheck disable=SC2034  # read by the sourced engine's epilogue
FR_DRIVER="test-driver"
( fr_survey alpha beta gamma > /dev/null 2>&1 )
check "survey writes one row per repo" 3 "$(wc -l < "$FR_WORKDIR/survey.jsonl" | tr -d ' ')"
( SURVEY_GEN=2 fr_survey beta > /dev/null 2>&1 )
check "partial re-survey keeps the other rows" 3 "$(wc -l < "$FR_WORKDIR/survey.jsonl" | tr -d ' ')"
check "partial re-survey replaced the requested row" 2 \
    "$(jq -r 'select(.repo == "beta") | .gen' "$FR_WORKDIR/survey.jsonl")"
check "partial re-survey left the others at gen 1" "1 1" \
    "$(jq -r 'select(.repo != "beta") | .gen' "$FR_WORKDIR/survey.jsonl" | tr '\n' ' ' | sed 's/ $//')"
# The shipped count comes from the engine, not the driver: a driver row that
# carries only `files` must reach survey.jsonl with `shipped` filled in.
# shellcheck disable=SC2329  # invoked indirectly by the sourced fr_survey
host_survey_repo() { local repo="$1"; jq -nc --arg r "$repo" \
    '{host: "test", repo: $r, resolved: ("o/" + $r), files: ["README.md", "skills/x/SKILL.md", "skills/x/references/a.md"]}'; return 0; }
( FR_WORKDIR="$WORK/wd-shipped"; mkdir -p "$FR_WORKDIR"; fr_survey delta > /dev/null 2>&1 )
check "survey: rows reach survey.jsonl with the engine's shipped count" 2 \
    "$(jq -r "$jq_shipped" "$WORK/wd-shipped/survey.jsonl")"

# --- commit retry: a reformatting hook aborts the first commit (#263) --------
# pre-commit's pretty-format-json --autofix (and black, ruff format, …) rewrites
# a staged file and then FAILS the run. Without the retry the bump dies as
# "FAIL <repo>: commit" and leaves a half-written worktree the resume refuses.
# The retry must re-walk the porcelain, not re-add the first pass's paths, or a
# hook that writes outside the version surfaces would ride in on the second try.
SIGNKEY="$WORK/signing-key"
ssh-keygen -q -t ed25519 -N '' -C fleet-test -f "$SIGNKEY" < /dev/null
mk_commit_repo() { # DIR HOOK-SCRIPT
    local d="$1" hook="$2"
    git init -q -b main "$d"
    mkdir -p "$d/.claude-plugin"
    printf '{"name":"demo","version":"1.0.0"}\n' > "$d/plugin.json"
    printf '{"name":"demo","version":"1.0.0"}\n' > "$d/.claude-plugin/plugin.json"
    ( cd "$d" && git add -A && git commit -q -m base )
    git -C "$d" config gpg.format ssh
    git -C "$d" config user.signingkey "$SIGNKEY.pub"
    printf '%s\n' "$hook" > "$d/.git/hooks/pre-commit"
    chmod +x "$d/.git/hooks/pre-commit"
    # the bump itself: both version surfaces move
    printf '{"name":"demo","version":"1.1.0"}\n' > "$d/plugin.json"
    printf '{"name":"demo","version":"1.1.0"}\n' > "$d/.claude-plugin/plugin.json"
}
# Fires once, rewrites a staged ALLOWLISTED file, fails — then passes, exactly
# as an --autofix hook behaves on the re-run.
REFORMAT_HOOK='#!/bin/sh
[ -f .git/HOOK_FIRED ] && exit 0
: > .git/HOOK_FIRED
printf %s "{\n  \"name\": \"demo\",\n  \"version\": \"1.1.0\"\n}\n" > .claude-plugin/plugin.json
exit 1'
mk_commit_repo "$WORK/commit-reformat" "$REFORMAT_HOOK"
out=$(fr_commit_allowlisted demo "$WORK/commit-reformat" 1.1.0 2>&1)
check "commit: first attempt fails on the reformatting hook (the defect)" yes \
    "$(grep -q 'COMMIT EXIT (1): [^0]' <<< "$out" && echo yes || echo no)"
check "commit: retry re-stages the hook's output and commits" yes \
    "$(grep -q 'COMMIT EXIT (2): 0' <<< "$out" && echo yes || echo no)"
check "commit: the bump landed as one commit" "chore(release): v1.1.0" \
    "$(git -C "$WORK/commit-reformat" log -1 --format=%s)"
check "commit: nothing left in the worktree afterwards" "" \
    "$(git -C "$WORK/commit-reformat" status --porcelain)"
# The retry must NOT widen the allowlist: a hook that writes an unrelated file
# still fails, on the second pass as on the first.
FOREIGN_HOOK='#!/bin/sh
[ -f .git/HOOK_FIRED ] && exit 0
: > .git/HOOK_FIRED
echo junk > NOTES.md
exit 1'
mk_commit_repo "$WORK/commit-foreign" "$FOREIGN_HOOK"
out=$(fr_commit_allowlisted demo "$WORK/commit-foreign" 1.1.0 2>&1; echo "rc=$?")
check "commit: a hook writing outside the version surfaces still FAILs" yes \
    "$(grep -q 'unexpected change outside the version surfaces: NOTES.md' <<< "$out" && echo yes || echo no)"
check "commit: that failure is reported to the caller" yes \
    "$(grep -q 'rc=1' <<< "$out" && echo yes || echo no)"
# A deterministic rejection is not a reformat — it must not become a retry loop.
REJECT_HOOK='#!/bin/sh
exit 1'
mk_commit_repo "$WORK/commit-reject" "$REJECT_HOOK"
out=$(fr_commit_allowlisted demo "$WORK/commit-reject" 1.1.0 2>&1; echo "rc=$?")
check "commit: a hook that always rejects fails after exactly two attempts" yes \
    "$([ "$(grep -c 'COMMIT EXIT' <<< "$out")" = 2 ] && echo yes || echo no)"
check "commit: the permanent rejection is reported to the caller" yes \
    "$(grep -q 'FAIL demo: commit' <<< "$out" && grep -q 'rc=1' <<< "$out" && echo yes || echo no)"

# --- FR_COMMIT_TRAILERS: disclosure the operator defines, not the driver -----
# A bump commit must be able to carry provenance trailers (Assisted-by,
# Agent-Session, Agent-Host …). The driver stays agent-neutral: it appends
# whatever `Key: value` lines the operator supplies and knows none of them.
# Unset must remain byte-identical to the old behaviour, or every repo that
# does not opt in changes shape.
mk_commit_repo "$WORK/commit-trailers" '#!/bin/sh
exit 0'
FR_COMMIT_TRAILERS='Assisted-by: some-agent:some-model
Agent-Session: https://example.invalid/session_1

Agent-Host: abcdef' \
    fr_commit_allowlisted demo "$WORK/commit-trailers" 1.1.0 > /dev/null 2>&1
body=$(git -C "$WORK/commit-trailers" log -1 --format=%B)
check "trailers: Assisted-by lands in the commit" yes \
    "$(grep -qx 'Assisted-by: some-agent:some-model' <<< "$body" && echo yes || echo no)"
check "trailers: Agent-Session lands in the commit" yes \
    "$(grep -qx 'Agent-Session: https://example.invalid/session_1' <<< "$body" && echo yes || echo no)"
check "trailers: Agent-Host lands in the commit" yes \
    "$(grep -qx 'Agent-Host: abcdef' <<< "$body" && echo yes || echo no)"
check "trailers: a blank line in the variable adds no empty trailer" 3 \
    "$(grep -cE '^(Assisted-by|Agent-Session|Agent-Host):' <<< "$body")"
check "trailers: --signoff still applies alongside them" yes \
    "$(grep -q '^Signed-off-by:' <<< "$body" && echo yes || echo no)"
check "trailers: the subject is untouched" "chore(release): v1.1.0" \
    "$(git -C "$WORK/commit-trailers" log -1 --format=%s)"
# Both attempts must carry them: a reformatting hook aborts the first commit,
# and the retry is a SECOND `git commit` — the one place trailers could silently
# be dropped for exactly the repos whose hooks rewrite the manifest.
mk_commit_repo "$WORK/commit-trailers-retry" "$REFORMAT_HOOK"
FR_COMMIT_TRAILERS='Assisted-by: some-agent:some-model' \
    fr_commit_allowlisted demo "$WORK/commit-trailers-retry" 1.1.0 > /dev/null 2>&1
check "trailers: survive the reformatting-hook retry" yes \
    "$(git -C "$WORK/commit-trailers-retry" log -1 --format=%B \
        | grep -qx 'Assisted-by: some-agent:some-model' && echo yes || echo no)"
# Unset: the opt-out stays exactly as before.
mk_commit_repo "$WORK/commit-no-trailers" '#!/bin/sh
exit 0'
( unset FR_COMMIT_TRAILERS
  fr_commit_allowlisted demo "$WORK/commit-no-trailers" 1.1.0 > /dev/null 2>&1 )
check "trailers: unset adds none" 0 \
    "$(git -C "$WORK/commit-no-trailers" log -1 --format=%B \
        | grep -cE '^(Assisted-by|Agent-Session|Agent-Host):')"

# --- a requested trailer that does not land fails the repo -------------------
# The 2026-09-11 defect: a driver copy predating FR_COMMIT_TRAILERS ignores the
# variable, commits cleanly, and reports OK. Four bump commits reached `main`
# without their disclosure trailers before anyone opened one. A stale engine
# cannot warn about itself, but every other producer of the same symptom — a
# message-rewriting hook, a git too old for --trailer — is caught here.
mk_commit_repo "$WORK/commit-trailer-stripped" '#!/bin/sh
exit 0'
# A prepare-commit-msg hook that throws the trailers away, standing in for any
# cause that leaves the commit without what the operator asked for.
# shellcheck disable=SC2016  # $1 is the hook's own argument — it must NOT expand here
printf '%s\n' '#!/bin/sh
grep -v "^Assisted-by:" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' \
    > "$WORK/commit-trailer-stripped/.git/hooks/prepare-commit-msg"
chmod +x "$WORK/commit-trailer-stripped/.git/hooks/prepare-commit-msg"
out=$(FR_COMMIT_TRAILERS='Assisted-by: some-agent:some-model' \
    fr_commit_allowlisted demo "$WORK/commit-trailer-stripped" 1.1.0 2>&1; echo "rc=$?")
check "trailers: a stripped trailer FAILs the repo" yes \
    "$(grep -q 'requested trailer did not land' <<< "$out" && echo yes || echo no)"
check "trailers: that failure reaches the caller" yes \
    "$(grep -q 'rc=1' <<< "$out" && echo yes || echo no)"
check "trailers: the failure names the key" yes \
    "$(grep -q 'Assisted-by:' <<< "$out" && echo yes || echo no)"
# Unset: the assertion must stay silent, or every repo that does not opt in fails.
mk_commit_repo "$WORK/commit-assert-optout" '#!/bin/sh
exit 0'
out=$( unset FR_COMMIT_TRAILERS
       fr_commit_allowlisted demo "$WORK/commit-assert-optout" 1.1.0 2>&1; echo "rc=$?" )
check "trailers: the assertion is silent when none were requested" yes \
    "$(grep -q 'rc=0' <<< "$out" && echo yes || echo no)"

# A hook that MOVES a requested line out of the trailer block and into the body
# leaves it findable by a plain grep, while `git log --grep` and every other
# trailer consumer stop seeing it as a trailer — which is the point of writing
# one. Parsed with `git interpret-trailers --parse`, so this still FAILs.
mk_commit_repo "$WORK/commit-trailer-moved" '#!/bin/sh
exit 0'
# shellcheck disable=SC2016  # $1 is the hook's own argument — it must NOT expand here
printf '%s\n' '#!/bin/sh
sed -i "s|^Assisted-by: \(.*\)$||" "$1"
sed -i "2i Assisted-by: some-agent:some-model" "$1"' \
    > "$WORK/commit-trailer-moved/.git/hooks/prepare-commit-msg"
chmod +x "$WORK/commit-trailer-moved/.git/hooks/prepare-commit-msg"
out=$(FR_COMMIT_TRAILERS='Assisted-by: some-agent:some-model' \
    fr_commit_allowlisted demo "$WORK/commit-trailer-moved" 1.1.0 2>&1; echo "rc=$?")
check "trailers: a line moved into the BODY does not count as landed" yes \
    "$(grep -q 'requested trailer did not land' <<< "$out" && echo yes || echo no)"
# A substring match would accept a longer line that merely contains the request.
mk_commit_repo "$WORK/commit-trailer-substring" '#!/bin/sh
exit 0'
FR_COMMIT_TRAILERS='Assisted-by: some-agent:some-model-extended' \
    fr_commit_allowlisted demo "$WORK/commit-trailer-substring" 1.1.0 > /dev/null 2>&1
out=$(FR_COMMIT_TRAILERS='Assisted-by: some-agent:some-model' \
    fr_assert_trailers_landed demo "$WORK/commit-trailer-substring" 2>&1; echo "rc=$?")
check "trailers: a longer line is not accepted for a shorter request" yes \
    "$(grep -q 'rc=1' <<< "$out" && echo yes || echo no)"

# --- the shipped fleet list is non-empty and comment-clean -------------------
n=$(grep -cvE '^\s*(#|$)' "$SCRIPTS/fleet-repos-github.txt")
check "fleet-repos-github.txt ships a non-empty list" yes \
    "$([ "$n" -gt 10 ] && echo yes || echo no)"

# --- driver surfaces ----------------------------------------------------------
echo
echo "fleet-release-github.sh (offline surface)"
check "github driver: --help exits 0" 0 \
    "$(bash "$SCRIPTS/fleet-release-github.sh" --help > /dev/null 2>&1; echo $?)"
check "github driver: unknown subcommand refused" no \
    "$(bash "$SCRIPTS/fleet-release-github.sh" frobnicate --workdir "$WORK/x" > /dev/null 2>&1 && echo yes || echo no)"
check "github driver: missing --workdir refused" no \
    "$(bash "$SCRIPTS/fleet-release-github.sh" survey > /dev/null 2>&1 && echo yes || echo no)"

# manifest is a pure offline transform — golden-test it through the driver
if command -v gh > /dev/null 2>&1; then
    MWD="$WORK/manifest-wd"
    mkdir -p "$MWD"
    {
        row '.repo = "bump-me" | .resolved = "o/bump-me" | .head = "abc123"'
        row '.repo = "prepared" | .resolved = "o/prepared" | .claude_plugin = "1.10.0" | .root_plugin = "1.10.0"'
        row '.repo = "ci-only" | .resolved = "o/ci-only" | .nonci = 0'
        row '.repo = "foreign" | .resolved = "o/foreign" | .open_release_prs = [{"id":"7","url":"https://example.invalid/7","author":"colleague","branch":"release/v9.9.9","title":"chore(release): v9.9.9"}]'
        row '.repo = "own-pr" | .resolved = "o/own-pr" | .open_release_prs = [{"id":"8","url":"https://example.invalid/8","author":"sweep-bot","branch":"release/v2.5.0","title":"chore(release): v2.5.0"}]'
        row '.repo = "blipped" | .resolved = "o/blipped" | .ahead = -1 | .nonci = -1'
        row '.repo = "ruled" | .resolved = "o/ruled" | .ci_tag_rules = "12: rules | if CI_COMMIT_TAG;30:release_job:"'
        row '.repo = "cl-empty" | .resolved = "o/cl-empty" | .changelog_unreleased = "empty"'
        row '.repo = "zero-quiet" | .resolved = "o/zero-quiet" | .claude_plugin = "0.3.4" | .root_plugin = "0.3.4" | .last_tag = "v0.3.4" | .last_release = "v0.3.4" | .ahead = 0 | .nonci = 0'
        row '.repo = "zero-busy" | .resolved = "o/zero-busy" | .claude_plugin = "0.9.3" | .root_plugin = "0.9.3" | .last_tag = "v0.9.3" | .last_release = "v0.9.3"'
        row '.repo = "docs-only" | .resolved = "o/docs-only" | .files = ["README.md","docs/a.md","tests/t.sh"] | .nonci = 3 | .shipped = 0 | .renames_counted = true'
        row '.repo = "zero-docs" | .resolved = "o/zero-docs" | .claude_plugin = "0.4.0" | .root_plugin = "0.4.0" | .last_tag = "v0.4.0" | .last_release = "v0.4.0" | .files = ["README.md"] | .nonci = 1 | .shipped = 0 | .renames_counted = true'
    } > "$MWD/survey.jsonl"
    out=$(FR_SELF_LOGIN=sweep-bot bash "$SCRIPTS/fleet-release-github.sh" manifest --workdir "$MWD" 2>&1)
    check "manifest: runs offline on a fixture survey" yes \
        "$([ -f "$MWD/manifest.md" ] && echo yes || echo no)"
    check "manifest: BUMP row classified" yes \
        "$(grep -q '| bump-me | BUMP |' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: prepared repo is TAG-ONLY (numeric compare)" yes \
        "$(grep -q '| prepared | TAG-ONLY |' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: CI-only delta skipped" yes \
        "$(grep -q '| ci-only | SKIP-CI-ONLY |' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: not-shipped delta skipped, naming the files" yes \
        "$(grep -q '| docs-only | SKIP-NOT-SHIPPED |.*only files no release ships: README.md, docs/a.md, tests/t.sh' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: a not-shipped delta gets no skeleton row" "" \
        "$(jq -r 'select(.repo == "docs-only") | .repo' "$MWD/plan.skeleton.jsonl")"
    check "manifest: a 0.x not-shipped repo is a stabilization candidate, like CI-only" STABILIZE \
        "$(jq -r 'select(.repo == "zero-docs") | .classification' "$MWD/plan.stabilize.jsonl")"
    check "manifest: foreign PR blocked with author named" yes \
        "$(grep -q '| foreign | BLOCKED-FOREIGN-PR |.*@colleague' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: empty Unreleased flagged in column and note" yes \
        "$(grep -q '| cl-empty | BUMP |.*| EMPTY |.*write the release entries before the bump' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: rows without the changelog field render a dash" yes \
        "$(grep -qE '\| bump-me \| BUMP \|.*\| — \| success \|' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: skeleton prefills TAG-ONLY version" 1.10.0 \
        "$(jq -r 'select(.repo == "prepared") | .version' "$MWD/plan.skeleton.jsonl")"
    # Assert the row EXISTS before asserting its emptiness — an absent row also
    # prints "" and would make this a vacuous check.
    check "manifest: skeleton has a row for the BUMP repo" bump-me \
        "$(jq -r 'select(.repo == "bump-me") | .repo' "$MWD/plan.skeleton.jsonl")"
    check "manifest: skeleton leaves BUMP version to the operator" "" \
        "$(jq -r 'select(.repo == "bump-me") | .version' "$MWD/plan.skeleton.jsonl")"
    check "manifest: skeleton carries the surveyed head for the finish gate" abc123 \
        "$(jq -r 'select(.repo == "bump-me") | .head' "$MWD/plan.skeleton.jsonl")"
    check "manifest: foreign-PR repo has NO skeleton row (never planned over a colleague)" "" \
        "$(jq -r 'select(.repo == "foreign") | .repo' "$MWD/plan.skeleton.jsonl")"
    check "manifest: own crashed PR gets a skeleton row with its branch version" 2.5.0 \
        "$(jq -r 'select(.repo == "own-pr") | .version' "$MWD/plan.skeleton.jsonl")"
    check "manifest: failed compare renders SURVEY-INCOMPLETE with a re-run note" yes \
        "$(grep -q '| blipped | SURVEY-INCOMPLETE |.*re-run survey' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: host tag rules are rendered for the operator" yes \
        "$(grep -q 'tag rules: 12:' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: pipe chars in rules are escaped so the table survives" yes \
        "$(grep -q 'rules ¦ if CI_COMMIT_TAG' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: a quiet 0.x repo is offered for stabilization" "STABILIZE 1.0.0 0.3.4" \
        "$(jq -r 'select(.repo == "zero-quiet") | "\(.classification) \(.version) \(.last)"' "$MWD/plan.stabilize.jsonl")"
    check "manifest: a 0.x repo with a delta is offered too" STABILIZE \
        "$(jq -r 'select(.repo == "zero-busy") | .classification' "$MWD/plan.stabilize.jsonl")"
    check "manifest: a 1.x repo is not a stabilization candidate" "" \
        "$(jq -r 'select(.repo == "bump-me") | .repo' "$MWD/plan.stabilize.jsonl")"
    check "manifest: stabilization stays opt-in (quiet 0.x repo not in the skeleton)" "" \
        "$(jq -r 'select(.repo == "zero-quiet") | .repo' "$MWD/plan.skeleton.jsonl")"
    check "manifest: 0.x rows carry the stabilization note" yes \
        "$(grep -q '| zero-quiet | UP-TO-DATE |.*0.x: stabilization candidate' "$MWD/manifest.md" && echo yes || echo no)"
    check "manifest: stops for approval (bump command only in 'next' steps)" yes \
        "$(grep -q 'review the manifest' <<< "$out" && echo yes || echo no)"
else
    echo "  skip manifest golden tests (gh not installed)"
fi

# --- a failed tag query is not an untagged repo ------------------------------
# A 403 or rate-limit on the tags endpoint leaves last_tag empty, which reads
# exactly like "never tagged" and would offer an initial tag over an existing
# history. The row carries the failure instead.
check "classify: tags_failed outranks FIRST-RELEASE" SURVEY-INCOMPLETE \
    "$(fr_classify "$(row '.tags_failed = true | .last_release = "" | .last_tag = ""')")"
check "classify: tags_failed outranks a normal BUMP row" SURVEY-INCOMPLETE \
    "$(fr_classify "$(row '.tags_failed = true')")"
# Blocks still outrank it: an archived repo is archived whether or not the tag
# query answered.
check "classify: BLOCKED-ARCHIVED still outranks tags_failed" BLOCKED-ARCHIVED \
    "$(fr_classify "$(row '.tags_failed = true | .archived = true')")"
# A row from a driver that does not emit the key at all must behave as before.
check "classify: absent tags_failed is not a failure" BUMP \
    "$(fr_classify "$(row 'del(.tags_failed)')")"
check "classify: tags_failed = false is not a failure" BUMP \
    "$(fr_classify "$(row '.tags_failed = false')")"

# --- poisoned-capture invariant ---------------------------------------------
# `gh` prints HTTP error bodies to STDOUT, so `$(gh api …)` captures the error
# as data: the caller sees non-empty output and parses {"message":"Not Found"}
# as if it were the resource. gh_json exists to make that impossible, and the
# only legitimate `$(gh api` in the driver is the one inside it. This is a
# source invariant rather than a behavioural test because the survey and
# release-verify paths are network-bound and out of this suite's offline scope.
# shellcheck disable=SC2016  # the patterns are literal source text, not expansions
stray_api=$(grep -n '\$(gh api' "$SCRIPTS/fleet-release-github.sh" \
    | grep -Ev '^[0-9]+: *#' \
    | grep -Fv 'out=$(gh api "$@"' || true)
check "no bare \$(gh api ...) capture outside gh_json" "" "$stray_api"

# --- merge gate: what ends the wait, and what does not (#393) ----------------
# host_merge_gate runs against a stub `gh` on PATH that serves one fixture per
# GraphQL poll (the last fixture repeats) and prints an error body to STDOUT
# with exit 1 for a FAIL fixture — what real gh does on a rate limit. The gate
# reads with --paginate --slurp, so a poll's output is an array of pages: a
# fixture that is already an array is served as the pages, any other one as a
# single page. The
# 2026-10-21 sweep failed every repo on one unreadable poll and on red checks
# no branch rule required, including a PR that had already merged.
echo
echo "fleet-release-github.sh (merge gate, stub gh)"
GATE_BIN="$WORK/gate-bin"
mkdir -p "$GATE_BIN"
cat > "$GATE_BIN/gh" << 'STUB'
#!/usr/bin/env bash
d="$GH_STUB_DIR"
case "$1 $2" in
    "api graphql")
        n=$(( $(cat "$d/count" 2> /dev/null || echo 0) + 1 ))
        echo "$n" > "$d/count"
        f="$d/r$n.json"
        [ -f "$f" ] || f=$(ls "$d"/r*.json | sort -V | tail -1)
        if [ "$(cat "$f")" = FAIL ]; then
            echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com/rest"}'
            exit 1
        fi
        # GraphQL's own error shape, wrapped by --paginate --slurp
        if [ "$(cat "$f")" = GQLFAIL ]; then
            echo '[{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 1."}]}]'
            exit 1
        fi
        case "$(head -c1 "$f")" in
            "[") cat "$f" ;;
            *) printf '[%s]\n' "$(cat "$f")" ;;
        esac
        ;;
    "pr merge") echo "merge $*" >> "$d/merges" ;;
    *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$GATE_BIN/gh"

gate_pr() { # STATE MERGESTATE MERGEABLE AUTOMERGE(true|false) CONTEXTS-JSON
    jq -nc --arg s "$1" --arg m "$2" --arg g "$3" --argjson a "$4" --argjson c "$5" \
        '{data: {repository: {pullRequest: {state: $s, mergeStateStatus: $m, mergeable: $g,
          autoMergeRequest: (if $a then {enabledAt: "2026-10-21T00:00:00Z"} else null end),
          commits: {nodes: [{commit: {statusCheckRollup: {contexts:
            {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $c}}}}]}}}}}'
}
gate_check() { # NAME REQUIRED(true|false) CONCLUSION
    jq -nc --arg n "$1" --argjson r "$2" --arg c "$3" \
        '{__typename: "CheckRun", name: $n, status: "COMPLETED", conclusion: $c, isRequired: $r}'
}
RED_OPT=$(gate_check "drift / Template drift" false FAILURE)
RED_REQ=$(gate_check "tests / Skill Tests" true FAILURE)
GREEN_REQ=$(gate_check "tests / Skill Tests" true SUCCESS)

run_gate() { # CASE TIMEOUT FIXTURE... — sets gate_out, gate_rc, gate_polls
    local dir="$WORK/gate-$1" timeout_s="$2" i=0
    shift 2
    mkdir -p "$dir"
    for fx in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$fx" > "$dir/r$i.json"
    done
    # Output goes to a file, not through $( ): a killed gate must end the case
    # even if a grandchild still holds a pipe open, and -k SIGKILLs a gate
    # that outlives its TERM. A regression that loops shows as rc 124.
    # shellcheck disable=SC2016  # $1 expands in the child bash, not here
    PATH="$GATE_BIN:$PATH" GH_STUB_DIR="$dir" FR_POLL_SECONDS=0 \
        FR_MERGE_TIMEOUT="$timeout_s" timeout -k 5 20 bash -c \
        'source "$1" && host_merge_gate some-skill 245' _ "$SCRIPTS/fleet-release-github.sh" \
        > "$dir/out" 2>&1 < /dev/null
    gate_rc=$?
    gate_out=$(< "$dir/out")
    gate_polls=$(cat "$dir/count" 2> /dev/null || echo 0)
}

run_gate unread-then-merged 60 FAIL FAIL "$(gate_pr MERGED UNKNOWN UNKNOWN true "[$GREEN_REQ]")"
check "merge gate: unreadable polls, then MERGED -> merged (rc 0)" 0 "$gate_rc"
check "merge gate: unreadable polls are retried, not fatal" 3 "$gate_polls"

run_gate gql-unread-then-merged 60 GQLFAIL "$(gate_pr MERGED UNKNOWN UNKNOWN true "[$GREEN_REQ]")"
check "merge gate: a GraphQL error array names its cause, not a network fault" yes \
    "$(grep -q '^gh api failed: API rate limit already exceeded for user ID 1\.$' <<< "$gate_out" && echo yes || echo no)"

run_gate unread-timeout 2 FAIL
check "merge gate: unreadable until the deadline -> rc 1" 1 "$gate_rc"
check "merge gate: unreadable until the deadline ends in TIMEOUT, naming the unread polls" yes \
    "$(grep -q 'TIMEOUT waiting for PR #245 to merge (unreadable for' <<< "$gate_out" && echo yes || echo no)"
check "merge gate: more than one unreadable poll before the timeout" yes \
    "$([ "$gate_polls" -ge 2 ] && echo yes || echo no)"

run_gate red-optional 60 \
    "$(gate_pr OPEN UNSTABLE MERGEABLE true "[$RED_OPT, $GREEN_REQ]")" \
    "$(gate_pr MERGED UNKNOWN UNKNOWN true "[$RED_OPT, $GREEN_REQ]")"
check "merge gate: red non-required check, otherwise mergeable -> merged (rc 0)" 0 "$gate_rc"
check "merge gate: poll line says armed, not the auto-merge object" yes \
    "$(grep -q 'automerge=armed$' <<< "$gate_out" && echo yes || echo no)"
check "merge gate: red non-required check is reported as a note" yes \
    "$(grep -q 'note: red checks on PR #245 that the branch rules do not require: \["drift / Template drift"\]' <<< "$gate_out" && echo yes || echo no)"

# Without auto-merge, UNSTABLE (mergeable; only an optional check is red) with
# nothing still running is merged plainly — on CLEAN alone the gate would sit
# out its timeout on exactly the PRs the first fix lets through.
run_gate red-optional-plain 60 \
    "$(gate_pr OPEN UNSTABLE MERGEABLE false "[$RED_OPT, $GREEN_REQ]")" \
    "$(gate_pr MERGED UNKNOWN UNKNOWN false "[$RED_OPT, $GREEN_REQ]")"
check "merge gate: UNSTABLE without auto-merge is merged plainly" "0 1" \
    "$gate_rc $(wc -l < "$WORK/gate-red-optional-plain/merges" 2> /dev/null | tr -d ' ' || echo 0)"

run_gate red-required 60 "$(gate_pr OPEN BLOCKED MERGEABLE true "[$RED_OPT, $RED_REQ]")"
check "merge gate: red REQUIRED check -> rc 1" 1 "$gate_rc"
check "merge gate: red REQUIRED check fails on the first poll, naming the check" "1 yes" \
    "$gate_polls $(grep -q 'red required checks on PR #245: \["tests / Skill Tests"\]' <<< "$gate_out" && echo yes || echo no)"

# The contexts connection is paginated: a red required check on page two is
# as fatal as one on page one, never a BLOCKED wait until the timeout.
run_gate required-page-two 60 \
    "[$(gate_pr OPEN BLOCKED MERGEABLE true "[$GREEN_REQ]"), $(gate_pr OPEN BLOCKED MERGEABLE true "[$RED_REQ]")]"
check "merge gate: red REQUIRED check on the second page of contexts -> rc 1 on the first poll" "1 1" \
    "$gate_rc $gate_polls"

run_gate merged-first 60 "$(gate_pr MERGED DIRTY CONFLICTING false "[$RED_REQ]")"
check "merge gate: MERGED on the first read wins over red checks and conflicts" "0 1" \
    "$gate_rc $gate_polls"

run_gate conflict 60 "$(gate_pr OPEN DIRTY CONFLICTING true "[$GREEN_REQ]")"
check "merge gate: a conflicting PR fails at once with its own message" "1 yes" \
    "$gate_rc $(grep -q 'has a merge conflict' <<< "$gate_out" && echo yes || echo no)"

# --- release verify: an unreadable read is not a missing Release -------------
# 2026-10-23: the REST quota stayed at 0 past FR_RELEASE_TIMEOUT while
# agent-rules-skill v3.16.5 was complete with 6 assets, and finish halted the
# sweep on "no verified Release". The stub serves one fixture per release
# read: FAIL is a 403 rate limit (error body on STDOUT, exit 1, as real gh),
# NOTFOUND is the 404 of a Release the workflow has not published yet (stderr
# text measured with gh 2.102), anything else is the Release JSON.
echo
echo "fleet-release-github.sh (release verify, stub gh)"
REL_BIN="$WORK/rel-bin"
mkdir -p "$REL_BIN"
cat > "$REL_BIN/gh" << 'STUB'
#!/usr/bin/env bash
d="$GH_STUB_DIR"
case "$1 $2" in
    "api repos/"*"/releases/tags/"*)
        n=$(( $(cat "$d/count" 2> /dev/null || echo 0) + 1 ))
        echo "$n" > "$d/count"
        f="$d/r$n.json"
        [ -f "$f" ] || f=$(ls "$d"/r*.json | sort -V | tail -1)
        case "$(cat "$f")" in
            FAIL)
                echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com/rest"}'
                echo 'gh: API rate limit exceeded (HTTP 403)' >&2
                exit 1
                ;;
            NOTFOUND)
                echo '{"message":"Not Found","status":"404"}'
                echo 'gh: Not Found (HTTP 404)' >&2
                exit 1
                ;;
            *) cat "$f" ;;
        esac
        ;;
    "api rate_limit") echo '{"resources":{"core":{"remaining":0,"reset":1792000000}}}' ;;
    "run list") echo "stub run list" ;;
    *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$REL_BIN/gh"
REL_OK='{"html_url":"https://example.invalid/releases/v3.16.5","assets":[{"name":"a.zip"},{"name":"SHA256SUMS.txt"}]}'

run_verify() { # CASE TIMEOUT FIXTURE... — sets ver_out, ver_rc, ver_polls
    local dir="$WORK/verify-$1" timeout_s="$2" i=0
    shift 2
    mkdir -p "$dir"
    for fx in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$fx" > "$dir/r$i.json"
    done
    # shellcheck disable=SC2016  # $1 expands in the child bash, not here
    PATH="$REL_BIN:$PATH" GH_STUB_DIR="$dir" FR_POLL_SECONDS=0 \
        FR_RELEASE_TIMEOUT="$timeout_s" timeout -k 5 20 bash -c \
        'source "$1" && host_release_verify some-skill v3.16.5' _ "$SCRIPTS/fleet-release-github.sh" \
        > "$dir/out" 2>&1 < /dev/null
    ver_rc=$?
    ver_out=$(< "$dir/out")
    ver_polls=$(cat "$dir/count" 2> /dev/null || echo 0)
    return 0
}

run_verify unread-then-ok 60 FAIL FAIL "$REL_OK"
check "release verify: unreadable reads, then the Release -> verified (rc 0)" 0 "$ver_rc"
check "release verify: unreadable reads are retried, not fatal" 3 "$ver_polls"
check "release verify: the verified Release is linked" yes \
    "$(grep -q '^RELEASE: https://example.invalid/releases/v3.16.5' <<< "$ver_out" && echo yes || echo no)"

run_verify unread-timeout 2 FAIL
check "release verify: unreadable until the deadline -> rc 3, not rc 1" 3 "$ver_rc"
check "release verify: the deadline message names the unreadable polls" yes \
    "$(grep -q '^UNVERIFIED: the Release for v3.16.5 could not be read at the deadline — the last [0-9]* poll(s) were unreadable' <<< "$ver_out" && echo yes || echo no)"
check "release verify: …and reports the quota from rate_limit" yes \
    "$(grep -q '^REST core quota: remaining=0 reset=' <<< "$ver_out" && echo yes || echo no)"
check "release verify: …and never claims the Release is missing" no \
    "$(grep -q 'no Release with assets' <<< "$ver_out" && echo yes || echo no)"
check "release verify: an unreadable read names its cause in the log" yes \
    "$(grep -q '^gh api failed: API rate limit exceeded$' <<< "$ver_out" && echo yes || echo no)"

# 404s and then the reads go dark: the 404s say "not published then", not
# "missing at the deadline" — a quota draining mid-window is the usual case.
run_verify notfound-then-unread 2 NOTFOUND NOTFOUND FAIL
check "release verify: 404s, then unreadable at the deadline -> rc 3" 3 "$ver_rc"
check "release verify: …names the earlier 404s in the UNVERIFIED line" yes \
    "$(grep -q '^UNVERIFIED: .*; 2 earlier poll(s) answered 404' <<< "$ver_out" && echo yes || echo no)"
check "release verify: …and still prints the workflow runs" yes \
    "$(grep -q '^stub run list' <<< "$ver_out" && echo yes || echo no)"

# The control: a 404 is a read that ANSWERED. An implementation that counts
# every failed call as unreadable passes both cases above and fails this one.
run_verify notfound-timeout 2 NOTFOUND
check "release verify: 404 until the deadline -> rc 1 (missing)" 1 "$ver_rc"
check "release verify: 404 until the deadline keeps the 'no Release with assets' message" yes \
    "$(grep -q '^no Release with assets for v3.16.5' <<< "$ver_out" && ! grep -q 'UNVERIFIED' <<< "$ver_out" && echo yes || echo no)"
check "release verify: an answered 404 stays quiet" no \
    "$(grep -q 'gh api failed' <<< "$ver_out" && echo yes || echo no)"
run_verify notfound-then-ok 60 NOTFOUND "$REL_OK"
check "release verify: 404 while queued, then the Release -> verified" 0 "$ver_rc"

# Back-off: with a fake clock and a sleep that records its argument, an
# always-unreadable read must wait 1x, 2x, 3x, then 4x the interval, stay at
# 4x, and never sleep past the deadline.
backoff_naps() { # INTERVAL TIMEOUT — the sleeps of one always-unreadable verify
    local interval="$1" limit="$2" dir="$WORK/verify-backoff-$1-$2"
    mkdir -p "$dir"
    printf 'FAIL\n' > "$dir/r1.json"
    # shellcheck disable=SC2016  # expands in the child bash, not here
    PATH="$REL_BIN:$PATH" GH_STUB_DIR="$dir" FR_POLL_SECONDS="$interval" \
        FR_RELEASE_TIMEOUT="$limit" timeout -k 5 20 bash -c '
            source "$1"
            NAPS="$2/naps"
            FAKE_NOW=1000
            date() { echo "$FAKE_NOW"; }
            sleep() { echo "$1" >> "$NAPS"; FAKE_NOW=$((FAKE_NOW + $1)); }
            host_release_verify some-skill v3.16.5' _ "$SCRIPTS/fleet-release-github.sh" "$dir" \
        > /dev/null 2>&1 < /dev/null
    paste -sd ' ' "$dir/naps"
    return 0
}
check "release verify: back-off grows 1x-4x, caps at 4x, and stops at the deadline" \
    "10 20 30 40 40 40 20" "$(backoff_naps 10 200)"

# The engine side: the outcome has to reach the FAIL line, because the summary
# and the per-repo tail show nothing else.
verify_line() { # RC — the FAIL line fr_release_verified prints for that outcome
    # shellcheck disable=SC2329  # invoked indirectly by fr_release_verified
    host_release_verify() { return "$VERIFY_RC"; }
    VERIFY_RC="$1" fr_release_verified demo v1.0.0 "no verified Release for v1.0.0"
    echo "rc=$?"
}
out=$(verify_line 3)
check "finish: an unverifiable Release says UNVERIFIED on the FAIL line" yes \
    "$(grep -q '^FAIL demo: Release for v1.0.0 UNVERIFIED — the last API read before the deadline failed' <<< "$out" && grep -q 'rc=1' <<< "$out" && echo yes || echo no)"
out=$(verify_line 1)
check "finish: a missing Release keeps its own FAIL line" yes \
    "$(grep -q '^FAIL demo: no verified Release for v1.0.0 (post-tag' <<< "$out" && echo yes || echo no)"
out=$(verify_line 0)
check "finish: a verified Release prints no FAIL line" "rc=0" "$out"

# --- survey row: a rename counts with both of its paths ----------------------
# host_survey_repo against a stub `gh` that answers the reads a released repo
# needs and serves a compare fixture. Moving skills/x/references/a.md to
# docs/a.md removes a shipped file; reading only the new name made it a
# docs-only delta.
echo
echo "fleet-release-github.sh (survey row, stub gh)"
SURV_BIN="$WORK/surv-bin"
mkdir -p "$SURV_BIN"
cat > "$SURV_BIN/gh" << 'STUB'
#!/usr/bin/env bash
[ "$1" = pr ] && { echo '[]'; exit 0; }
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
case "$path" in
    */compare/*) cat "$GH_STUB_COMPARE" ;;
    */releases/latest) echo '{"tag_name":"v1.0.0"}' ;;
    */tags\?*) echo '[{"name":"v1.0.0"}]' ;;
    */commits/main) echo '{"sha":"abc123"}' ;;
    */contents/.claude-plugin/plugin.json*) echo '{"name":"demo","version":"1.0.0"}' ;;
    */contents/.github/workflows/release.yml*) echo '{"name":"release.yml"}' ;;
    repos/*/*/*) echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
    repos/*/*) echo '{"full_name":"o/demo","archived":false,"default_branch":"main"}' ;;
esac
STUB
chmod +x "$SURV_BIN/gh"
survey_class() { # COMPARE-JSON — "<class> <nonci> <shipped>" of the surveyed row
    printf '%s\n' "$1" > "$WORK/surv-compare.json"
    # shellcheck disable=SC2016  # $1 expands in the child bash, not here
    PATH="$SURV_BIN:$PATH" GH_STUB_COMPARE="$WORK/surv-compare.json" FR_SELF_LOGIN=sweep-bot \
        timeout -k 5 20 bash -c 'source "$1" && row=$(fr_add_shipped "$(host_survey_repo demo)") \
            && echo "$(fr_classify "$row") $(jq -r "[.nonci, .shipped] | map(tostring) | join(\" \")" <<< "$row")"' \
        _ "$SCRIPTS/fleet-release-github.sh" 2> /dev/null < /dev/null
    return 0
}
check "survey: a docs-only delta surveys as SKIP-NOT-SHIPPED (control)" "SKIP-NOT-SHIPPED 2 0" \
    "$(survey_class '{"ahead_by":2,"commits":[{"commit":{"message":"docs: a"}}],"files":[{"filename":"docs/a.md"},{"filename":"README.md"}]}')"
check "survey: moving a reference into docs/ is a shipped change (BUMP)" "BUMP 3 1" \
    "$(survey_class '{"ahead_by":2,"commits":[{"commit":{"message":"docs: move"}}],"files":[{"filename":"docs/a.md","previous_filename":"skills/x/references/a.md","status":"renamed"},{"filename":"README.md"}]}')"
check "survey: moving a skill file under .github/ is not CI-only (BUMP)" "BUMP 1 1" \
    "$(survey_class '{"ahead_by":1,"commits":[{"commit":{"message":"ci: move"}}],"files":[{"filename":".github/x.md","previous_filename":"skills/x/SKILL.md","status":"renamed"}]}')"

echo
if [ "$fail" -eq 0 ]; then
    echo "All fleet-release tests passed"
else
    echo "Some fleet-release tests FAILED"
fi
exit "$fail"
