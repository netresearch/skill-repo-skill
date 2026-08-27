#!/usr/bin/env bash
#
# fleet-release-github.sh — fleet release driver for the PUBLIC GitHub skill
# repos (github.com/<org>, default netresearch).
#
# Mechanizes references/release-discipline.md so a sweep stops hand-writing
# driver scripts and re-earning their bugs (issue #218). Fleets on other hosts
# ship their own driver in their own (private) infrastructure — the API shapes
# differ enough that one script serving several hosts is how jq filters
# silently return empty. Everything host-independent lives in
# fleet-release-common.sh; a foreign-host driver vendors that engine and
# defines the host_* callbacks documented in its header.
#
# Usage:
#   fleet-release-github.sh survey   --workdir DIR [--repos "r1 r2"|--repos-file F] [--org ORG]
#   fleet-release-github.sh manifest --workdir DIR
#   fleet-release-github.sh bump     --workdir DIR [--plan F]
#   fleet-release-github.sh finish   --workdir DIR [--plan F] [--continue]
#
# Flow: survey (read-only API) -> manifest (offline classification; STOPS for
# human approval) -> bump (worktree, bump-version.sh, changelog roll, PR,
# auto-merge arm) -> finish (merge gate, parity from origin/<default>, signed
# tag on the remote tip, Release verification, cleanup). Re-running any phase
# is resumable: remote reality, not local state, decides what is left to do.
#
# The driver never merges a PR this sweep did not open, never unarchives,
# never clones, never invents versions or PR bodies, never touches CI files,
# and only releases the default-branch tip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-release-common.sh
# shellcheck disable=SC1091  # resolved at runtime relative to this script
source "$SCRIPT_DIR/fleet-release-common.sh"

FR_HOST=github
# shellcheck disable=SC2034  # consumed by the sourced engine's epilogues
FR_DRIVER="$0"
FR_ORG="${FR_ORG:-netresearch}"

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

# ---------------------------------------------------------------------------
# Host callbacks (see the contract in fleet-release-common.sh)
# ---------------------------------------------------------------------------
host_display() { echo "$FR_ORG/$1"; }
host_origin_suffix() { echo "github.com/$FR_ORG/$1"; }

host_remote_tip() { # REPO BRANCH
    gh api "repos/$FR_ORG/$1/commits/$2" --jq .sha
}

gh_json() { # ARGS... — gh api that NEVER leaks an HTTP error body as data:
    # on 403/404/5xx gh prints the JSON error to STDOUT (verified with gh
    # 2.97), so every `$(gh api ... || echo "")` capture is poisoned. Output
    # only reaches the caller when the call succeeded.
    local out
    if out=$(gh api "$@" 2> /dev/null); then
        printf '%s\n' "$out"
        return 0
    fi
    return 1
}

host_survey_repo() { # REPO — one normalized row on stdout, or exit 1
    local r="$1" meta resolved archived def
    meta=$(gh_json "repos/$FR_ORG/$r") || return 1
    resolved=$(jq -r '.full_name' <<< "$meta")
    archived=$(jq -r '.archived' <<< "$meta")
    def=$(jq -r '.default_branch' <<< "$meta")

    local head
    head=$(gh_json "repos/$FR_ORG/$r/commits/$def" | jq -r '.sha // empty' || echo "")

    local rel last_tag tags
    rel=$(gh_json "repos/$FR_ORG/$r/releases/latest" | jq -r '.tag_name // empty' || echo "")
    # releases/latest 404s for never-released AND for tag-without-Release repos
    # (a release workflow that ran and died). The tags list tells them apart —
    # and it is NOT date-ordered, so pick the max by version, never .[0].
    # --paginate: one page would hide the newest tag of a >100-tag repo.
    tags=$(gh api --paginate "repos/$FR_ORG/$r/tags?per_page=100" 2> /dev/null \
        | jq -s '[.[][]]' || echo '[]')
    last_tag=$(jq -r "$FR_JQ_VPARSE"' map(.name) | max_by(vparse) // empty' <<< "$tags")

    local rootv cpv composer_has_version release_gate
    rootv=$(gh_json -H "Accept: application/vnd.github.raw" \
        "repos/$FR_ORG/$r/contents/plugin.json?ref=$def" \
        | jq -r '.version // empty' 2> /dev/null || echo "")
    cpv=$(gh_json -H "Accept: application/vnd.github.raw" \
        "repos/$FR_ORG/$r/contents/.claude-plugin/plugin.json?ref=$def" \
        | jq -r '.version // empty' 2> /dev/null || echo "")
    # bump-version.sh refuses a composer version field mid-bump with a
    # half-written tree — surface it as a manifest row instead.
    if gh_json -H "Accept: application/vnd.github.raw" \
        "repos/$FR_ORG/$r/contents/composer.json?ref=$def" \
        | jq -e 'has("version")' > /dev/null 2>&1; then
        composer_has_version=true
    else
        composer_has_version=false
    fi
    if gh_json "repos/$FR_ORG/$r/contents/.github/workflows/release.yml?ref=$def" \
        > /dev/null; then
        release_gate=true
    else
        release_gate=false
    fi

    # Unreleased-section state, by the same rule the bump-time roll enforces —
    # an empty section becomes a manifest warning instead of a mid-bump failure.
    local cl_raw cl_state
    cl_raw=$(gh_json -H "Accept: application/vnd.github.raw" \
        "repos/$FR_ORG/$r/contents/CHANGELOG.md?ref=$def" || echo "")
    cl_state=$(fr_changelog_state "$cl_raw")

    # Measured CI state of the default branch — the manifest's precondition
    # column must show a value, never an assumed checkmark.
    local ci_status
    ci_status=$(gh_json "repos/$FR_ORG/$r/commits/$def/check-runs?per_page=100" \
        | jq -r '[.check_runs[]] as $r
            | ([$r[] | select(.status != "completed")] | length) as $pending
            | ([$r[] | select(.status == "completed"
                and (.conclusion | IN("success","skipped","neutral") | not)) | .name]) as $failed
            | if ($r | length) == 0 then "none"
              elif .total_count > 100 then "truncated(\(.total_count) runs)"
              elif ($failed | length) > 0 then "failed: " + ($failed | join(","))
              elif $pending > 0 then "pending(\($pending))"
              else "success" end' 2> /dev/null || echo "unknown")

    # --limit 100: the default of 30 would let a foreign release PR beyond the
    # first page slip past the BLOCKED-FOREIGN-PR gate.
    local prs
    prs=$(gh pr list --repo "$FR_ORG/$r" --state open --limit 100 \
        --json number,title,author,headRefName,url 2> /dev/null \
        | jq '[.[] | select((.headRefName | startswith("release/"))
                        or (.title | startswith("chore(release)"))
                        or (.title | startswith("chore: release")))
               | {id: (.number | tostring), url, author: .author.login,
                  branch: .headRefName, title}]' || echo '[]')

    local base ahead=-1 nonci=-1 subjects='[]' files='[]' files_truncated=false cmp
    base="$rel"
    [[ -n "$base" ]] || base="$last_tag"
    if [[ -z "$base" ]]; then
        ahead=0   # first release: there is no base, and -1 must mean only
        nonci=0   # "measurement FAILED" (SURVEY-INCOMPLETE), never "no base"
    else
        # compare runs for archived repos too: the unarchive decision needs to
        # see whether anything (e.g. a deprecation banner) is unshipped.
        # A FAILED call keeps the -1 sentinel -> SURVEY-INCOMPLETE, because a
        # transient 403 must never read as "no delta".
        cmp=$(gh_json "repos/$FR_ORG/$r/compare/$base...$def" || echo "")
        if [[ -n "$cmp" ]]; then
            ahead=$(jq -r '.ahead_by // 0' <<< "$cmp")
            nonci=$(jq --arg f "$FR_CI_ONLY_RE" \
                '[.files[].filename] | map(select(test($f) | not)) | length' <<< "$cmp" 2> /dev/null || echo -1)
            subjects=$(jq '[.commits[].commit.message | split("\n")[0]]' <<< "$cmp" 2> /dev/null || echo '[]')
            files=$(jq --arg f "$FR_CI_ONLY_RE" \
                '[.files[].filename | select(test($f) | not)]' <<< "$cmp" 2> /dev/null || echo '[]')
            # the compare API caps .files at 300 — 0-vs-nonzero stays valid,
            # the file list itself may be partial
            [[ "$(jq '.files | length' <<< "$cmp")" -ge 300 ]] && files_truncated=true
        fi
    fi

    jq -nc \
        --arg host "$FR_HOST" --arg repo "$r" --arg resolved "$resolved" \
        --arg def "$def" --arg head "$head" --argjson archived "$archived" \
        --arg rel "$rel" --arg last_tag "$last_tag" \
        --arg rootv "$rootv" --arg cpv "$cpv" \
        --argjson chv "$composer_has_version" --argjson gate "$release_gate" \
        --arg ci "$ci_status" --argjson ahead "$ahead" --argjson nonci "$nonci" \
        --argjson subjects "$subjects" --argjson files "$files" \
        --argjson trunc "$files_truncated" --argjson prs "$prs" \
        --arg clstate "$cl_state" \
        '{host: $host, repo: $repo, resolved: $resolved, default: $def, head: $head,
          archived: $archived, empty: false, unreachable: false, duplicate_of: "",
          last_release: $rel, last_tag: $last_tag,
          root_plugin: $rootv, claude_plugin: $cpv,
          composer_has_version: $chv, release_gate: $gate, ci_status: $ci,
          ahead: $ahead, nonci: $nonci, files_truncated: $trunc,
          changelog_unreleased: $clstate,
          subjects: $subjects, files: $files,
          open_release_prs: $prs, ci_tag_rules: "", notes: ""}'
}

host_create_pr() { # REPO BRANCH TITLE BODY TARGET -> "<number> <url>"
    local r="$1" branch="$2" title="$3" body="$4" target="$5" url num
    url=$(gh pr create --repo "$FR_ORG/$r" --head "$branch" --base "$target" \
        --title "$title" --body "$body") || return 1
    num=$(gh pr view "$branch" --repo "$FR_ORG/$r" --json number --jq .number) || return 1
    echo "$num $url"
}

host_find_release_pr() { # REPO BRANCH -> "<number> <url> <state> <author>"
    gh pr list --repo "$FR_ORG/$1" --head "$2" --state all \
        --json number,url,state,author --limit 1 \
        --jq '.[0] | select(. != null)
              | "\(.number) \(.url) \(.state | ascii_downcase) \(.author.login)"'
}

host_arm_automerge() { # REPO NUMBER
    if gh pr merge --auto --merge "$2" --repo "$FR_ORG/$1" 2>&1; then
        echo "auto-merge armed"
    else
        echo "auto-merge not armed (finish will merge plainly when green)"
    fi
}

host_merge_gate() { # REPO NUMBER — completion-first: a QUEUED check reports
    # conclusion "" (not null) and must read as pending, never as failure
    local r="$1" num="$2" deadline j state mss failed pending automerge merr
    deadline=$(($(date +%s) + FR_MERGE_TIMEOUT))
    while true; do
        j=$(gh pr view "$num" --repo "$FR_ORG/$r" \
            --json state,mergeStateStatus,statusCheckRollup,autoMergeRequest 2> /dev/null) || j=""
        if [[ -z "$j" ]]; then
            echo "cannot read PR #$num"
            return 1
        fi
        state=$(jq -r '.state' <<< "$j")
        [[ "$state" == "MERGED" ]] && return 0
        if [[ "$state" == "CLOSED" ]]; then
            echo "PR #$num was closed without merge"
            return 1
        fi
        mss=$(jq -r '.mergeStateStatus // "UNKNOWN"' <<< "$j")
        failed=$(jq '[.statusCheckRollup[]
            | select(.__typename == "CheckRun" and .status == "COMPLETED"
                and (.conclusion | IN("SUCCESS","SKIPPED","NEUTRAL") | not))
            | .name]
            + [.statusCheckRollup[]
            | select(.__typename == "StatusContext"
                and (.state | IN("SUCCESS","PENDING","EXPECTED") | not))
            | .context]' <<< "$j")
        if [[ "$(jq length <<< "$failed")" -gt 0 ]]; then
            echo "red checks on PR #$num: $(jq -c . <<< "$failed") — PR left open"
            return 1
        fi
        pending=$(jq '[.statusCheckRollup[]
            | select((.__typename == "CheckRun" and .status != "COMPLETED")
                  or (.__typename == "StatusContext" and (.state | IN("PENDING","EXPECTED"))))]
            | length' <<< "$j")
        automerge=$(jq -r '.autoMergeRequest // empty | tostring' <<< "$j")
        echo "poll: state=$state mergeState=$mss pending=$pending automerge=${automerge:+armed}${automerge:-no}"
        # Merge plainly ONLY on GitHub's own CLEAN verdict — an empty or
        # not-yet-reported rollup is NOT green (queued workflows are invisible
        # to the rollup; pending==0 never meant "all reported").
        if [[ "$mss" == "CLEAN" && -z "$automerge" ]] \
            && ! merr=$(gh pr merge --merge "$num" --repo "$FR_ORG/$r" 2>&1); then
            echo "$merr"
            case "$merr" in
                *"not allowed"*|*"protected branch"*)
                    echo "merge method rejected for PR #$num — needs a human (merge it per repo policy)"
                    return 1
                    ;;
                *) : ;;
            esac
        fi
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            echo "TIMEOUT waiting for PR #$num to merge (state=$state mergeState=$mss pending=$pending)"
            return 1
        fi
        sleep "$FR_POLL_SECONDS"
    done
}

host_merge_commit() { # REPO NUMBER — the SHA the merged PR produced
    gh pr view "$2" --repo "$FR_ORG/$1" --json mergeCommit \
        --jq '.mergeCommit.oid // empty'
}

host_release_verify() { # REPO TAG — a pushed tag is not a release; assert the
    # Release object and its assets, then link it
    local r="$1" tag="$2" deadline rel assets
    deadline=$(($(date +%s) + FR_RELEASE_TIMEOUT))
    while true; do
        rel=$(gh api "repos/$FR_ORG/$r/releases/tags/$tag" 2> /dev/null || echo "")
        if [[ -n "$rel" ]]; then
            assets=$(jq '[.assets[].name] | length' <<< "$rel")
            if [[ "$assets" -gt 0 ]]; then
                echo "RELEASE: $(jq -r '.html_url' <<< "$rel") assets: $(jq -c '[.assets[].name]' <<< "$rel")"
                return 0
            fi
        fi
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            echo "no Release with assets for $tag — last workflow runs:"
            gh run list --repo "$FR_ORG/$r" --limit 3 2>&1 || true
            return 1
        fi
        sleep "$FR_POLL_SECONDS"
    done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || usage
CMD="$1"
shift
case "$CMD" in -h|--help) usage 0 ;; esac
REPOS_INLINE=""
REPOS_FILE=""
PLAN=""
CONTINUE=""
FR_WORKDIR=""
# shellcheck disable=SC2034  # FR_BASE_DIR is read by the sourced engine
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir)    FR_WORKDIR="${2:?}"; shift 2 ;;
        --repos)      REPOS_INLINE="${2:?}"; shift 2 ;;
        --repos-file) REPOS_FILE="${2:?}"; shift 2 ;;
        --org)        FR_ORG="${2:?}"; shift 2 ;;
        --plan)       PLAN="${2:?}"; shift 2 ;;
        --base-dir)   FR_BASE_DIR="${2:?}"; shift 2 ;;
        --continue)   CONTINUE="--continue"; shift ;;
        -h|--help)    usage 0 ;;
        *)            fr_err "unknown option: $1"; usage ;;
    esac
done
[[ -n "$FR_WORKDIR" ]] || { fr_err "--workdir is required"; usage; }
mkdir -p "$FR_WORKDIR"
PLAN="${PLAN:-$FR_WORKDIR/plan.jsonl}"

case "$CMD" in
    survey)
        fr_preflight survey gh
        REPOS=$(fr_repos_from "$REPOS_INLINE" "$REPOS_FILE" "$SCRIPT_DIR/fleet-repos-github.txt")
        [[ -n "$REPOS" ]] || fr_die "no repos: pass --repos/--repos-file or ship fleet-repos-github.txt"
        # shellcheck disable=SC2086  # word splitting is the point
        fr_survey $REPOS
        ;;
    manifest)
        FR_SELF_LOGIN="${FR_SELF_LOGIN:-$(gh api user --jq .login)}"
        fr_preflight manifest gh
        fr_manifest
        ;;
    bump)
        FR_SELF_LOGIN="${FR_SELF_LOGIN:-$(gh api user --jq .login)}"
        fr_preflight bump gh
        fr_bump "$PLAN"
        ;;
    finish)
        FR_SELF_LOGIN="${FR_SELF_LOGIN:-$(gh api user --jq .login)}"
        fr_preflight finish gh
        fr_finish "$PLAN" "$CONTINUE"
        ;;
    *)
        fr_err "unknown subcommand: $CMD"
        usage
        ;;
esac
