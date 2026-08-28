#!/usr/bin/env bash
# tests/fleet-release.sh — exercises the fleet-release driver set:
#   skills/skill-repo/scripts/fleet-release-common.sh   (shared engine)
#   skills/skill-repo/scripts/fleet-release-github.sh   (public GitHub driver)
#   skills/skill-repo/scripts/fleet-repos-github.txt    (default fleet list)
#
# Everything here is offline: classification, version ordering, parity from a
# ref, tag idempotency, checkout-layout resolution, plan validation, the log
# invariant — the logic classes that historically broke in hand-written sweep
# drivers. Each guard tested HERE is observed to fail on a violating fixture,
# not just to pass on a clean one. Scope limit, stated plainly: the network
# phases (survey/bump/finish API calls, merge gates, Release polling) have no
# offline test — they are exercised against live hosts before releases, and
# their guards (freshness gate, foreign-PR stop, merge-commit anchoring) are
# enforced by code review plus the read-only live runs, not by this file.

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
    check "manifest: stops for approval (bump command only in 'next' steps)" yes \
        "$(grep -q 'review the manifest' <<< "$out" && echo yes || echo no)"
else
    echo "  skip manifest golden tests (gh not installed)"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "All fleet-release tests passed"
else
    echo "Some fleet-release tests FAILED"
fi
exit "$fail"
