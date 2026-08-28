# shellcheck shell=bash
# fleet-release-common.sh — shared engine for the fleet-release drivers.
#
# Sourced by a host driver (fleet-release-github.sh here; a private-host fleet
# ships its own driver in its own infrastructure and vendors this engine); not
# executable on its own. Everything host-independent lives here so a bug fixed
# for one host is fixed for both (the 2026-08-13 sweep's phase_b scripts were
# literally identical for 20 lines — twice).
#
# The driver must define these host callbacks before calling a phase:
#   host_survey_repo REPO          emit ONE normalized survey row (compact JSON)
#   host_remote_tip REPO BRANCH    print the remote head SHA of BRANCH
#   host_create_pr REPO BRANCH TITLE BODY TARGET
#                                  create the PR/MR against TARGET; print '<id> <url>'
#   host_find_release_pr REPO BRANCH
#                                  print '<id> <url> <state> <author>' of the
#                                  newest PR/MR for BRANCH, or nothing
#   host_arm_automerge REPO ID     arm auto-merge (or no-op); never fails the repo
#   host_merge_gate REPO ID        wait until merged; 0 merged, 1 failed/timeout
#   host_merge_commit REPO ID      print the SHA the merged PR/MR produced
#   host_release_verify REPO TAG   wait for the Release object; 0 ok, 1 missing
#   host_origin_suffix REPO        expected origin URL suffix, e.g. 'org/repo'
#   host_display REPO              display identity, e.g. 'netresearch/repo'
#
# Normalized survey row schema (both hosts emit exactly these keys):
#   host repo resolved default archived empty unreachable duplicate_of
#   last_release last_tag root_plugin claude_plugin composer_has_version
#   release_gate ci_status ahead nonci changelog_unreleased files_truncated subjects files
#   open_release_prs [{id,url,author,branch,title}] ci_tag_rules notes
#
# Every phase writes into $FR_WORKDIR:
#   survey.jsonl   one row per repo (jq -nc: ROW COUNTS MUST EQUAL LINE COUNTS)
#   manifest.md    the approval manifest
#   plan.skeleton.jsonl / plan.jsonl
#   opened.jsonl   the PRs/MRs THIS sweep opened — the only ones finish may
#                  ever wait on or merge (a colleague's bump PR is never
#                  covered by sweep approval; release-discipline.md)
#   logs/<phase>/<repo>.log

# ---------------------------------------------------------------------------
# Globals (drivers may override before sourcing or via flags)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # consumed across the lib/driver file boundary
FR_BASE_DIR="${FR_BASE_DIR:-$HOME/projects}"
FR_POLL_SECONDS="${FR_POLL_SECONDS:-20}"
FR_MERGE_TIMEOUT="${FR_MERGE_TIMEOUT:-1800}"
FR_RELEASE_TIMEOUT="${FR_RELEASE_TIMEOUT:-600}"
FR_SELF_LOGIN="${FR_SELF_LOGIN:-}"        # resolved by the driver (gh/glab)
FR_BRANCH_PREFIX="release/v"              # owned by github-release-skill
FR_COMMIT_PREFIX="chore(release): v"      # owned by github-release-skill
# CI-only delta filter: commits touching only these paths ship a byte-identical
# archive — not a release (release-discipline.md).
# shellcheck disable=SC2034  # consumed by the host drivers' survey callbacks
FR_CI_ONLY_RE='^\.github/|^\.gitlab-ci\.yml$|^renovate\.json$'
# The only files a bump commit may touch.
FR_ALLOWLIST_RE='^(plugin\.json|\.claude-plugin/plugin\.json|skills/[^/]+/SKILL\.md|CHANGELOG\.md)$'
# Version-aware compare/sort, shared by every jq call site. Extracts the
# TRAILING semver so custom tag conventions (tender-estimation--v0.6.1) order
# correctly too — a parse that degrades them all to [0] makes max_by pick an
# arbitrary old tag and misclassify the repo as diverged (seen live 2026-08-13).
# Input with no trailing semver at all degrades to 0.0.0; the manifest flags
# those rows as nonstandard instead of trusting the math.
FR_JQ_VPARSE='def vparse: (capture("(?<v>[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?)$") // {v: "0.0.0"}) | .v | split("-")[0] | split("+")[0] | split(".") | map(tonumber? // 0);'

FR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fr_tool() { # NAME — locate a skill-repo tool (bump-version.sh, roll-changelog.py,
    # …). A driver vendored into another repo has no sibling copies, so the
    # lookup falls back to the INSTALLED skill-repo skill (reading/executing
    # installed paths is fine; editing them is what cache-safety forbids).
    # FR_TOOLS_DIR pins an explicit source-of-truth checkout when set.
    local name="$1" d
    for d in "${FR_TOOLS_DIR:-}" "$FR_SCRIPT_DIR" \
        "$HOME/.claude/skills/skill-repo/scripts"; do
        [[ -n "$d" && -f "$d/$name" ]] && { echo "$d/$name"; return 0; }
    done
    d=$(find "$HOME/.claude/plugins/cache" -path '*/skills/skill-repo/scripts/'"$name" 2> /dev/null | sort -V | tail -1)
    [[ -n "$d" ]] && { echo "$d"; return 0; }
    fr_err "cannot locate $name (set FR_TOOLS_DIR to a skill-repo-skill checkout's skills/skill-repo/scripts)"
    return 1
}

fr_note() { printf '%s\n' "$*"; }
fr_err()  { printf 'ERROR: %s\n' "$*" >&2; }

fr_changelog_state() { # RAW-CONTENT — "absent" | "empty" | "has-content" |
    # "no-unreleased" | "unknown". An empty argument means the survey found no
    # CHANGELOG.md. Classification is delegated to roll-changelog.py
    # --check-unreleased so the survey warns by the SAME emptiness rule the
    # bump-time roll enforces — five repos failed mid-bump on empty
    # [Unreleased] sections in the 2026-08-27 sweep, each one visible to the
    # survey that ran hours earlier.
    local raw="$1" tool tmp state
    [[ -n "$raw" ]] || { echo "absent"; return 0; }
    tool=$(fr_tool roll-changelog.py 2> /dev/null) || { echo "unknown"; return 0; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/fr-clstate.XXXXXX") || { echo "unknown"; return 0; }
    printf '%s\n' "$raw" > "$tmp"
    state=$(python3 "$tool" --check-unreleased "$tmp" 2> /dev/null) || state="unknown"
    rm -f "$tmp"
    echo "${state:-unknown}"
}
fr_die()  { fr_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
fr_preflight() { # PHASE TOOL...
    local phase="$1"; shift
    [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] \
        || fr_die "bash >= 4 required (this is bash ${BASH_VERSION:-unknown}); on macOS: brew install bash"
    local t
    for t in git jq "$@"; do
        command -v "$t" > /dev/null 2>&1 || fr_die "required tool missing: $t"
    done
    case "$phase" in
        bump)
            command -v python3 > /dev/null 2>&1 \
                || fr_die "python3 required for the changelog roll"
            ;;
        *) : ;;
    esac
    # Never write into installed/cache paths (release-discipline.md,
    # "Cache Safety") — neither the workdir nor the checkouts base.
    local p
    for p in "$FR_WORKDIR" "$FR_BASE_DIR"; do
        case "$p" in
            */.claude/skills*|*/.claude/plugins*|*/.bare|*/.bare/*)
                fr_die "refusing to operate under installed/cache path: $p"
                ;;
            *) : ;;
        esac
    done
    mkdir -p "$FR_WORKDIR/logs/$phase"
    # Signing preflight: an agent that silently dropped the key fails every
    # repo mid-fleet; fail here instead. FR_SKIP_SIGN_CHECK=1 for GPG setups
    # the check cannot see.
    if [[ "$phase" == "bump" || "$phase" == "finish" ]] \
        && [[ "${FR_SKIP_SIGN_CHECK:-0}" != "1" ]]; then
        local fmt
        fmt=$(git config --get gpg.format 2> /dev/null || echo openpgp)
        if [[ "$fmt" == "ssh" ]] && ! ssh-add -l > /dev/null 2>&1; then
            fr_die "gpg.format=ssh but ssh-add -l lists no key — signing every commit/tag would fail (FR_SKIP_SIGN_CHECK=1 to override)"
        fi
    fi
    fr_lock "$phase"
}

fr_lock() { # PHASE — one sweep per workdir; stale locks (dead PID) are taken over
    local lock="$FR_WORKDIR/.lock" pid
    if mkdir "$lock" 2> /dev/null; then
        echo "$$" > "$lock/pid"
    else
        pid=$(cat "$lock/pid" 2> /dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2> /dev/null; then
            fr_die "workdir locked by running pid $pid ($lock) — a second sweep on the same workdir would interleave logs and state"
        fi
        fr_note "taking over stale lock (pid ${pid:-unknown} is gone)"
        echo "$$" > "$lock/pid"
    fi
    # shellcheck disable=SC2064  # expand $lock now: it is stable and local
    trap "rm -rf '$lock'" EXIT
}

# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------
fr_vercmp() { # A B — prints -1|0|1 (numeric per component; never lexicographic:
    # bash [[ < ]] and BSD sort would call 1.10.0 older than 1.9.0)
    jq -rn --arg a "$1" --arg b "$2" \
        "$FR_JQ_VPARSE"' ($a|vparse) as $A | ($b|vparse) as $B
         | if $A > $B then "1" elif $A < $B then "-1" else "0" end'
}

fr_resolve_gitdir() { # DIR — three checkout layouts coexist (release-discipline.md)
    local d="$1"
    if [[ -d "$d/.bare" ]]; then
        echo "$d/.bare"
    elif git -C "$d" rev-parse --absolute-git-dir 2> /dev/null; then
        return 0
    elif git -C "$d/main" rev-parse --absolute-git-dir 2> /dev/null; then
        return 0
    else
        return 1
    fi
}

fr_check_origin() { # GITDIR EXPECTED — folder names lie; origin URLs don't.
    # A checkout whose origin points elsewhere would receive the wrong repo's
    # release branch. Normalize scheme/user/port away and compare host/path
    # EXACTLY — a suffix match would accept a crafted path whose tail merely
    # mimics host/org/repo.
    local gitdir="$1" want="$2" url
    url=$(git -C "$gitdir" config --get remote.origin.url 2> /dev/null || echo "")
    [[ -n "$url" ]] || { fr_err "no remote.origin.url in $gitdir"; return 1; }
    local norm="${url%.git}"
    norm="${norm#*://}"          # scheme
    norm="${norm#*@}"            # user
    if [[ "$norm" =~ ^([^/:]+):[0-9]+(/.*)$ ]]; then
        norm="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"   # host:PORT/path -> host/path
    fi
    norm="${norm//:/\/}"         # scp-style host:org/repo -> host/org/repo
    if [[ "$norm" == "$want" ]]; then
        return 0
    fi
    fr_err "origin of $gitdir is '$url' (normalized $norm), expected $want — refusing to push there"
    return 1
}

fr_worktree_path() { # DIR VERSION — layout-aware worktree location
    local d="$1" v="$2"
    if [[ -d "$d/.bare" ]]; then
        echo "$d/release-$v"
    else
        echo "$d-release-$v"
    fi
}

fr_fetch_branches() { # GITDIR — branches only: one stale tag would fail the
    # whole fetch ('would clobber existing tag') and take the branches with it
    git -C "$1" fetch origin --prune --no-tags \
        "+refs/heads/*:refs/remotes/origin/*" 2>&1
}

fr_show_version() { # GITDIR REF FILE — .version of a JSON file at a ref, or empty
    git -C "$1" show "$2:$3" 2> /dev/null | jq -r '.version // empty' 2> /dev/null || true
}

fr_parity_from_ref() { # GITDIR REF VERSION — parity read from the ref, never a
    # working tree (worktrees drift; ~6 of 23 disagreed in one sweep)
    local gitdir="$1" ref="$2" want="$3" fail=0 cp root f sv
    cp=$(fr_show_version "$gitdir" "$ref" ".claude-plugin/plugin.json")
    if [[ -z "$cp" ]]; then
        fr_err "parity: $ref has no .claude-plugin/plugin.json version"
        return 1
    fi
    [[ "$cp" == "$want" ]] || { fr_err "parity: .claude-plugin/plugin.json=$cp != $want"; fail=1; }
    if git -C "$gitdir" cat-file -e "$ref:plugin.json" 2> /dev/null; then
        root=$(fr_show_version "$gitdir" "$ref" "plugin.json")
        [[ "$root" == "$want" ]] || { fr_err "parity: plugin.json=$root != $want"; fail=1; }
    fi
    # composer.json must NOT carry a version — the tag is the source of truth,
    # and TAG-ONLY repos never pass through bump-version.sh's own refusal.
    if git -C "$gitdir" show "$ref:composer.json" 2> /dev/null \
        | jq -e 'has("version")' > /dev/null 2>&1; then
        fr_err "parity: composer.json at $ref carries a version field"
        fail=1
    fi
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        sv=$(git -C "$gitdir" show "$ref:$f" | awk '
            # Frontmatter is the FIRST --- ... --- block only; a --- rule in
            # the body must not reopen it (a body "version:" would then be
            # parsed as the skill version).
            /^---$/ { if (fm) exit; fm = 1; next }
            fm && /^[[:space:]]*version:[[:space:]]*/ {
                gsub(/^[[:space:]]*version:[[:space:]]*/, "")
                gsub(/["\047]/, "")
                gsub(/[[:space:]]+$/, "")
                print
                exit
            }')
        if [[ -n "$sv" && "$sv" != "$want" ]]; then
            fr_err "parity: $f version=$sv != $want"
            fail=1
        fi
    done < <(git -C "$gitdir" ls-tree -r --name-only "$ref" \
        | grep -E '^skills/[^/]+/SKILL\.md$' || true)
    return "$fail"
}

fr_remote_tag_commit() { # GITDIR TAG — the COMMIT a remote tag points at, or
    # empty. Signed tags are annotated: ls-remote's plain line is the tag
    # OBJECT sha; only the peeled ^{} line is the commit. Comparing unpeeled
    # would call every resumed signed tag "wrong SHA".
    # Exit 2 when the remote could not be read at all — "cannot see the tag"
    # must never read as "tag absent", or a network blip triggers a doomed
    # duplicate tag push.
    local gitdir="$1" tag="$2" out
    out=$(git -C "$gitdir" ls-remote origin \
        "refs/tags/$tag" "refs/tags/$tag^{}" 2> /dev/null) || return 2
    if printf '%s\n' "$out" | grep -q "refs/tags/$tag\^{}$"; then
        printf '%s\n' "$out" | awk '/\^\{\}$/ { print $1 }'
    else
        printf '%s\n' "$out" | awk 'NF { print $1; exit }'
    fi
}

fr_tag_is_signed() { # GITDIR TAG — annotated AND carrying a signature block;
    # a crashed run's own tag was created with -s, anything else is suspect
    [[ "$(git -C "$1" cat-file -t "$2" 2> /dev/null)" == "tag" ]] || return 1
    git -C "$1" cat-file tag "$2" | grep -Eq -- '-----BEGIN (PGP|SSH) SIGNATURE-----'
}

fr_tag_on_tip() { # GITDIR TAG TIP — signed tag on the verified remote tip; no
    # checkout, no working tree (a parked worktree stays untouched). Idempotent
    # across the crash windows: tag already remote, tag local-only.
    local gitdir="$1" tag="$2" tip="$3" remote local_commit rc
    rc=0
    remote=$(fr_remote_tag_commit "$gitdir" "$tag") || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        fr_err "cannot read remote tags for $tag (ls-remote failed) — not tagging blind"
        return 1
    fi
    if [[ -n "$remote" ]]; then
        if [[ "$remote" == "$tip" ]]; then
            fr_note "tag $tag already on remote at the tip — skipping to verification"
            return 0
        fi
        fr_err "tag $tag exists on remote at $remote, tip is $tip — a released tag is immutable; this needs a human"
        return 1
    fi
    if git -C "$gitdir" rev-parse -q --verify "refs/tags/$tag" > /dev/null 2>&1; then
        local_commit=$(git -C "$gitdir" rev-parse "$tag^{commit}")
        if [[ "$local_commit" == "$tip" ]] && fr_tag_is_signed "$gitdir" "$tag"; then
            fr_note "local signed tag $tag already at the tip (crashed before push) — pushing it"
        elif [[ "$local_commit" == "$tip" ]]; then
            fr_err "local tag $tag is at the tip but UNSIGNED — not this driver's work; inspect, 'git -C $gitdir tag -d $tag', re-run"
            return 1
        else
            fr_err "local tag $tag points at $local_commit, tip is $tip — inspect and 'git -C $gitdir tag -d $tag' manually"
            return 1
        fi
    else
        git -C "$gitdir" tag -s "$tag" -m "$tag" "$tip" || { fr_err "tag -s failed"; return 1; }
    fi
    git -C "$gitdir" push origin "refs/tags/$tag"
    local ec=$?
    fr_note "TAG PUSH EXIT: $ec"
    return "$ec"
}

fr_check_log_invariant() { # LOGDIR EXPECTED — a killed batch 'completes' with
    # fewer logs than repos and nothing says so; count before trusting anything
    local logdir="$1" expected="$2" actual
    actual=$(find "$logdir" -maxdepth 1 -name '*.log' | wc -l | tr -d ' ')
    if [[ "$actual" -ne "$expected" ]]; then
        fr_err "log invariant violated: $actual logs for $expected repos in $logdir"
        return 1
    fi
    fr_note "log invariant holds: $actual/$expected"
}

fr_summarize_logs() { # LOGDIR — count explicit end-state markers; a truncated
    # log (hard kill mid-repo) is neither OK nor FAIL and must be visible
    local logdir="$1" f ok=0 failed=0 other=0
    for f in "$logdir"/*.log; do
        [[ -e "$f" ]] || continue
        if grep -q '^OK ' "$f"; then
            ok=$((ok + 1))
        elif grep -q '^FAIL ' "$f"; then
            failed=$((failed + 1))
            fr_note "FAIL: $(basename "$f" .log): $(grep '^FAIL ' "$f" | tail -1)"
        else
            other=$((other + 1))
            fr_note "INDETERMINATE (no OK/FAIL marker — truncated?): $f"
        fi
    done
    fr_note "summary: $ok ok, $failed failed, $other indeterminate"
    [[ "$failed" -eq 0 && "$other" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Survey
# ---------------------------------------------------------------------------
fr_survey() { # REPO... — remote-first; per-repo failures become rows, not aborts.
    # A re-survey of a SUBSET (the manifest's own "re-run survey --repos X"
    # advice) replaces exactly those rows and keeps the rest — truncating the
    # whole file would throw away the sweep it is trying to repair.
    local out="$FR_WORKDIR/survey.jsonl" seen="$FR_WORKDIR/.seen-resolved" repo row resolved tmp
    if [[ -s "$out" ]]; then
        tmp=$(mktemp)
        jq -c --args 'select(.repo as $r | $ARGS.positional | index($r) | not)' "$@" < "$out" > "$tmp"
        mv "$tmp" "$out"
        jq -r 'select((.resolved // "") != "") | .resolved' "$out" > "$seen"
        fr_note "keeping $(wc -l < "$out" | tr -d ' ') existing rows; re-surveying: $*"
    else
        : > "$out"
        : > "$seen"
    fi
    for repo in "$@"; do
        fr_note "surveying $(host_display "$repo") ..."
        row=$(host_survey_repo "$repo" < /dev/null) \
            || row=$(jq -nc --arg r "$repo" --arg h "$FR_HOST" \
                '{host:$h, repo:$r, unreachable:true}')
        # A renamed repo answers on both names (API redirect) — the SECOND row
        # for one resolved identity must not become a second bump PR.
        resolved=$(jq -r '.resolved // empty' <<< "$row")
        if [[ -n "$resolved" ]] && grep -Fxq "$resolved" "$seen"; then
            row=$(jq -nc --arg r "$repo" --arg h "$FR_HOST" --arg d "$resolved" \
                '{host:$h, repo:$r, duplicate_of:$d}')
        elif [[ -n "$resolved" ]]; then
            printf '%s\n' "$resolved" >> "$seen"
        fi
        printf '%s\n' "$row" >> "$out"   # rows are compact: wc -l == repo count
    done
    fr_note ""
    fr_note "survey: $(wc -l < "$out" | tr -d ' ') rows -> $out"
    fr_note "next: $FR_DRIVER manifest --workdir $FR_WORKDIR"
}

# ---------------------------------------------------------------------------
# Classification + manifest
# ---------------------------------------------------------------------------
fr_classify() { # ROW-JSON — one shared implementation for both hosts; blocks
    # outrank actions (a composer-version repo must never reach TAG-ONLY)
    jq -r --arg self "$FR_SELF_LOGIN" "$FR_JQ_VPARSE"'
        if .unreachable == true then "UNREACHABLE"
        elif (.duplicate_of // "") != "" then "DUPLICATE"
        elif .empty == true then "EMPTY"
        elif .archived == true then "BLOCKED-ARCHIVED"
        elif .composer_has_version == true then "BLOCKED-COMPOSER-VERSION"
        elif ([.open_release_prs[]? | select(.author != $self)] | length) > 0 then "BLOCKED-FOREIGN-PR"
        elif ([.open_release_prs[]? | select(.author == $self)] | length) > 0 then "OWN-PR-OPEN"
        elif .release_gate == false then "NO-RELEASE-JOB"
        elif (.last_release // "") == "" and (.last_tag // "") == "" then "FIRST-RELEASE"
        elif (.last_tag // "") != "" and (.last_tag != (.last_release // "")) then "TAG-RELEASE-DIVERGED"
        else
            ((.claude_plugin // "") | vparse) as $p
            | ((.last_tag // "") | vparse) as $t
            | if $p > $t then "TAG-ONLY"
              elif $p < $t then "BEHIND-TAG"
              # ahead/nonci < 0 = the compare MEASUREMENT failed, which must
              # never read as "no delta": a transient API blip would silently
              # drop a repo with releasable commits from the sweep.
              elif (.ahead // 0) < 0 or (.nonci // 0) < 0 then "SURVEY-INCOMPLETE"
              elif (.ahead // 0) == 0 then "UP-TO-DATE"
              elif (.nonci // 0) == 0 then "SKIP-CI-ONLY"
              else "BUMP"
              end
        end' <<< "$1"
}

fr_manifest() {
    local survey="$FR_WORKDIR/survey.jsonl" manifest="$FR_WORKDIR/manifest.md"
    local skeleton="$FR_WORKDIR/plan.skeleton.jsonl" row cls
    [[ -s "$survey" ]] || fr_die "no survey at $survey — run: $FR_DRIVER survey first"
    [[ -n "$FR_SELF_LOGIN" ]] || fr_die "FR_SELF_LOGIN unresolved — cannot apply the foreign-PR author gate"
    : > "$skeleton"
    {
        echo "# Fleet Release Manifest ($FR_HOST, $(date +%F))"
        echo
        echo "Approval covers ONLY the PRs this sweep opens. Rows marked"
        echo "BLOCKED-FOREIGN-PR need that author's separate go-ahead."
        echo
        echo "| Repo | Class | Last tag | Release | plugin.json | Ahead | Non-CI | Changelog | CI on default | Notes |"
        echo "|---|---|---|---|---|---|---|---|---|---|"
    } > "$manifest"
    while IFS= read -u 3 -r row; do
        cls=$(fr_classify "$row")
        jq -r --arg cls "$cls" "$FR_JQ_VPARSE"'
            def ordash: if . == null or . == "" then "—" else . end;
            [ .repo,
              $cls,
              (.last_tag | ordash),
              (.last_release | ordash),
              (.claude_plugin | ordash),
              ((.ahead // "") | tostring | ordash),
              ((.nonci // "") | tostring | ordash),
              ((.changelog_unreleased // "") | if . == "empty" then "EMPTY" else ordash end),
              (.ci_status | ordash),
              ([ (if (.open_release_prs // []) | length > 0
                  then "PRs: " + ([.open_release_prs[] | "\(.url) by @\(.author)"] | join("; "))
                  else empty end),
                 (if (.last_tag // "") != "" and ((.last_tag | test("^v?[0-9]+\\.[0-9]+\\.[0-9]+")) | not)
                  then "nonstandard tag convention" else empty end),
                 (if .files_truncated == true then "compare file list truncated" else empty end),
                 (if $cls == "NO-RELEASE-JOB"
                  then "no tag-triggered release job — adopt the shared release CI first; this driver does not write CI files"
                  else empty end),
                 (if $cls == "TAG-RELEASE-DIVERGED"
                  then "tag exists without a matching Release — check the release job matched the tag pattern; usually a CI fix plus a NEW version (re-plan as BUMP)"
                  else empty end),
                 (if $cls == "BLOCKED-ARCHIVED"
                  then "unarchive is a human decision; afterwards re-run survey --repos \(.repo)"
                  else empty end),
                 (if $cls == "BUMP" and (.changelog_unreleased // "") == "empty"
                  then "CHANGELOG [Unreleased] is empty — write the release entries before the bump phase, or its roll fails on exactly this"
                  else empty end),
                 (if $cls == "SURVEY-INCOMPLETE"
                  then "the compare MEASUREMENT failed (this is not a no-delta result) — re-run survey --repos \(.repo)"
                  else empty end),
                 (if (.ci_tag_rules // "") != ""
                  then "tag rules: " + (.ci_tag_rules | gsub("\\|"; "¦"))
                  else empty end),
                 ((.notes // "") | if . == "" then empty else gsub("\\|"; "¦") end)
               ] | join(". ") | ordash)
            ] | "| " + join(" | ") + " |"' <<< "$row" >> "$manifest"
        case "$cls" in
            BUMP|FIRST-RELEASE|TAG-ONLY|TAG-RELEASE-DIVERGED|OWN-PR-OPEN)
                # TAG-ONLY carries its committed version — tagging a prepared
                # repo at that version keeps parity true by construction.
                # OWN-PR-OPEN carries the version its open PR branch encodes,
                # so a crashed sweep's own PR re-enters the flow instead of
                # being silently dropped. BUMP versions and bodies are operator
                # judgment: the driver never invents either. `head` is the
                # surveyed default-branch tip — finish refuses to tag a
                # TAG-ONLY repo whose branch moved past it.
                jq -c --arg cls "$cls" \
                    '{repo, classification: $cls, default: (.default // "main"),
                      last: (.claude_plugin // ""), last_tag: (.last_tag // ""),
                      head: (.head // ""),
                      version: (if $cls == "TAG-ONLY" then (.claude_plugin // "")
                                elif $cls == "OWN-PR-OPEN"
                                then ([.open_release_prs[]? | .branch
                                      | capture("^release/v(?<v>.+)$") | .v] | first // "")
                                else "" end),
                      body: "", tag: "",
                      subjects: (.subjects // [])}' <<< "$row" >> "$skeleton"
                ;;
        esac
    done 3< "$survey"
    {
        echo
        echo "Preconditions are per-repo MEASURED values above (CI on default,"
        echo "open PRs, composer version field) — never assumed checkmarks."
        echo
        echo "Scope: this driver releases the DEFAULT branch tip only. Maintenance-line"
        echo "releases (--latest=false handling) are out of scope — do those by hand."
    } >> "$manifest"
    cat "$manifest"
    fr_note ""
    fr_note "manifest -> $manifest"
    fr_note "plan skeleton -> $skeleton"
    fr_note "next: 1. review the manifest with the operator/user and get approval"
    fr_note "      2. cp $skeleton $FR_WORKDIR/plan.jsonl"
    fr_note "      3. fill 'version' (and 'body') for every BUMP/FIRST-RELEASE row; drop rows to skip"
    fr_note "      4. $FR_DRIVER bump --workdir $FR_WORKDIR"
}

# ---------------------------------------------------------------------------
# Plan handling
# ---------------------------------------------------------------------------
fr_plan_validate() { # PLAN — refuse the whole phase before mutating anything
    local plan="$1" bad
    [[ -s "$plan" ]] || fr_die "no plan at $plan (copy plan.skeleton.jsonl and fill it)"
    jq -e . > /dev/null 2>&1 < "$plan" || fr_die "plan is not valid JSON lines: $plan"
    # Repo names become branch names, log paths and worktree paths — a slash
    # (GitLab subgroup) or space would land the log/worktree somewhere else.
    bad=$(jq -r 'select((.repo // "") | test("^[A-Za-z0-9._-]+$") | not) | .repo // "<empty>"' < "$plan")
    [[ -z "$bad" ]] || fr_die "plan rows with unusable repo names (subgroups are unsupported): $(tr '\n' ' ' <<< "$bad")"
    # One row per repo: two rows with different versions would open two bump
    # PRs against one repo.
    bad=$(jq -r '.repo' < "$plan" | sort | uniq -d)
    [[ -z "$bad" ]] || fr_die "duplicate plan rows for: $(tr '\n' ' ' <<< "$bad")"
    bad=$(jq -r 'select((.classification == "BUMP" or .classification == "FIRST-RELEASE" or .classification == "TAG-ONLY" or .classification == "OWN-PR-OPEN")
                  and ((.version // "") == "")) | .repo' < "$plan")
    [[ -z "$bad" ]] || fr_die "plan rows without a version: $(tr '\n' ' ' <<< "$bad")— fill them or drop them"
    bad=$(jq -r 'select((.version // "") != "")
                 | select((.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?$")) | not) | .repo' < "$plan")
    [[ -z "$bad" ]] || fr_die "plan rows with a non-semver version: $(tr '\n' ' ' <<< "$bad")"
    # Monotonicity: a planned version below or equal to the surveyed one would
    # ship a parity-consistent version REGRESSION that no later gate can see.
    # Two classes are exceptions, for opposite reasons:
    #   TAG-ONLY      the bump already merged, so the plan must name that exact
    #                 committed version and nothing else.
    #   FIRST-RELEASE there is no previous release OR tag to regress from — its
    #                 `.last` is the committed plugin.json version, not a
    #                 shipped one. Tagging it as-is is the normal case for a
    #                 repo someone already prepared, and bumping above it is
    #                 equally legal; only going BELOW the committed version is
    #                 wrong, because parity would then fail at tag time.
    #                 Rejecting equality here left a prepared first release
    #                 unrepresentable: the operator had to either retype the row
    #                 TAG-ONLY by hand or invent a version nobody wrote
    #                 (hit on both ecom-* repos in the 2026-08-17 sweep).
    bad=$(jq -r "$FR_JQ_VPARSE"'
        select((.version // "") != "" and (.last // "") != "")
        | if .classification == "TAG-ONLY"
          then select(.version != .last)
               | "\(.repo) (TAG-ONLY must tag the committed \(.last), not \(.version))"
          elif .classification == "FIRST-RELEASE"
          then select((.version | vparse) < (.last | vparse))
               | "\(.repo) (FIRST-RELEASE may tag or exceed the committed \(.last), not fall below it with \(.version))"
          else select((.version | vparse) <= (.last | vparse))
               | "\(.repo) (\(.version) is not above the surveyed \(.last))"
          end' < "$plan")
    [[ -z "$bad" ]] || fr_die "plan version ordering: $(tr '\n' ';' <<< "$bad")"
}

fr_record_opened() { # REPO ID URL BRANCH — append-only; survives crashes
    jq -nc --arg h "$FR_HOST" --arg r "$1" --arg i "$2" --arg u "$3" --arg b "$4" \
        '{host: $h, repo: $r, id: $i, url: $u, branch: $b}' >> "$FR_WORKDIR/opened.jsonl"
}

fr_opened_lookup() { # REPO — id of the PR/MR this sweep opened, or empty.
    # Host-filtered: a workdir reused across both drivers must never resolve
    # the other host's PR number.
    [[ -f "$FR_WORKDIR/opened.jsonl" ]] || return 0
    jq -r --arg r "$1" --arg h "$FR_HOST" \
        'select(.repo == $r and .host == $h) | .id' "$FR_WORKDIR/opened.jsonl" | tail -1
}

# ---------------------------------------------------------------------------
# Bump phase
# ---------------------------------------------------------------------------
fr_bump_one() { # ROW — runs inside the per-repo subshell; log via redirection
    local row="$1"
    local repo version body default last cls
    repo=$(jq -r '.repo' <<< "$row")
    version=$(jq -r '.version // ""' <<< "$row")
    body=$(jq -r '.body // ""' <<< "$row")
    default=$(jq -r '.default // "main"' <<< "$row")
    last=$(jq -r '.last // ""' <<< "$row")
    cls=$(jq -r '.classification // "BUMP"' <<< "$row")
    local branch="${FR_BRANCH_PREFIX}${version}"
    echo "=== $(host_display "$repo") v$version ($cls) ==="
    [[ -n "$version" ]] || { echo "FAIL $repo: plan row has no version"; return 1; }

    if [[ "$cls" == "TAG-ONLY" ]]; then
        echo "OK $repo v$version no bump needed (prepared repo; finish will tag)"
        return 0
    fi
    # OWN-PR-OPEN re-enters here on purpose: the remote-reality checks below
    # find the sweep's own open PR and record it instead of double-bumping.
    if [[ "$cls" != "BUMP" && "$cls" != "FIRST-RELEASE" && "$cls" != "OWN-PR-OPEN" ]]; then
        echo "FAIL $repo: classification $cls does not belong in the bump phase"
        return 1
    fi

    local dir="$FR_BASE_DIR/$repo" gitdir
    gitdir=$(fr_resolve_gitdir "$dir") \
        || { echo "FAIL $repo: no checkout at $dir (survey is remote-first; bump needs a local checkout — clone it deliberately, this driver will not)"; return 1; }
    fr_check_origin "$gitdir" "$(host_origin_suffix "$repo")" \
        || { echo "FAIL $repo: origin mismatch"; return 1; }
    fr_fetch_branches "$gitdir" || { echo "FAIL $repo: fetch"; return 1; }

    # Freshness gate: classification happened at survey time and approval is
    # human-paced. If the fleet moved since (a colleague released), writing the
    # planned version would be a parity-consistent version REGRESSION that
    # every later gate happily waves through — refuse instead.
    local cur
    cur=$(fr_show_version "$gitdir" "origin/$default" ".claude-plugin/plugin.json")
    if [[ "$cur" == "$version" ]]; then
        echo "OK $repo v$version already at $version on origin/$default (nothing to bump; finish will tag)"
        return 0
    fi
    if [[ "$cur" != "$last" ]]; then
        echo "FAIL $repo: fleet moved since survey (surveyed $last, origin/$default now $cur) — re-run survey and re-plan this repo"
        return 1
    fi

    # Remote reality is the resume truth, interrogated per step; the crash
    # windows (after commit, after push, after PR create) each land in one of
    # these branches instead of a dead end.
    if git -C "$gitdir" rev-parse -q --verify "refs/remotes/origin/$branch" > /dev/null 2>&1; then
        local pr prid prurl prstate prauthor
        pr=$(host_find_release_pr "$repo" "$branch" < /dev/null || true)
        if [[ -n "$pr" ]]; then
            read -r prid prurl prstate prauthor <<< "$pr"
            case "$prstate" in
                merged|MERGED)
                    echo "OK $repo v$version bump already merged ($prurl) — run finish"
                    return 0
                    ;;
                open|OPEN|opened)
                    if [[ "$prauthor" != "$FR_SELF_LOGIN" ]]; then
                        echo "FAIL $repo: open release PR $prurl by @$prauthor — a colleague's PR needs their go, not sweep approval"
                        return 1
                    fi
                    [[ -n "$(fr_opened_lookup "$repo")" ]] || fr_record_opened "$repo" "$prid" "$prurl" "$branch"
                    echo "OK $repo v$version PR already open: $prurl"
                    return 0
                    ;;
            esac
        fi
        local bv extra
        bv=$(fr_show_version "$gitdir" "origin/$branch" ".claude-plugin/plugin.json")
        if [[ "$bv" == "$version" ]]; then
            # Version alone does not prove the branch is a bump: an auto-merge
            # will merge whatever else it carries unseen. Only the four version
            # surfaces may differ from the base.
            extra=$(git -C "$gitdir" diff --name-only "origin/$default" "origin/$branch" \
                | grep -vE "$FR_ALLOWLIST_RE" || true)
            if [[ -n "$extra" ]]; then
                echo "FAIL $repo: remote branch $branch changes more than the version surfaces ($(tr '\n' ' ' <<< "$extra")) — not adopting it for auto-merge; inspect it"
                return 1
            fi
            echo "branch $branch already pushed at $version (crashed before PR create) — creating the PR"
            fr_create_and_record "$repo" "$branch" "$version" "$body" "$default" || return 1
            echo "OK $repo v$version PR created from existing branch"
            return 0
        fi
        echo "FAIL $repo: leftover remote branch $branch at version '${bv:-unknown}' != $version — inspect and delete it first"
        return 1
    fi

    local wt
    wt=$(fr_worktree_path "$dir" "$version")
    if [[ -e "$wt" ]]; then
        fr_resume_worktree "$repo" "$wt" "$branch" "$version" "$default" "$gitdir" || return 1
    else
        git -C "$gitdir" worktree add "$wt" -b "$branch" "origin/$default" \
            || { echo "FAIL $repo: worktree add"; return 1; }
    fi

    if [[ "$(fr_show_version "$gitdir" "$branch" ".claude-plugin/plugin.json" 2> /dev/null)" != "$version" ]]; then
        local bump_tool roll_tool
        bump_tool=$(fr_tool bump-version.sh) || { echo "FAIL $repo: bump-version.sh not found"; return 1; }
        bash "$bump_tool" --repo "$wt" "$version" --apply \
            || { echo "FAIL $repo: bump"; return 1; }
        if [[ -f "$wt/CHANGELOG.md" ]]; then
            roll_tool=$(fr_tool roll-changelog.py) || { echo "FAIL $repo: roll-changelog.py not found"; return 1; }
            python3 "$roll_tool" "$wt/CHANGELOG.md" "$version" \
                || { echo "FAIL $repo: changelog roll"; return 1; }
            fr_lint_changelog "$wt"
        fi
        fr_commit_allowlisted "$repo" "$wt" "$version" || return 1
    else
        echo "bump already committed on $branch (crashed before push)"
    fi

    ( cd "$wt" && git push -u origin "$branch" )
    local ec=$?
    echo "PUSH EXIT: $ec"
    [[ "$ec" -eq 0 ]] || { echo "FAIL $repo: push"; return 1; }

    fr_create_and_record "$repo" "$branch" "$version" "$body" "$default" || return 1
    echo "OK $repo v$version bump PR open"
}

fr_resume_worktree() { # REPO WT BRANCH VERSION DEFAULT GITDIR — reuse only what
    # is provably this sweep's own half-done work; anything else is a loud stop
    local repo="$1" wt="$2" branch="$3" version="$4" default="$5" gitdir="$6"
    local head cur
    head=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2> /dev/null || echo "")
    if [[ "$head" != "$branch" ]]; then
        echo "FAIL $repo: $wt exists on branch '${head:-?}' (expected $branch) — not this sweep's worktree, inspect manually"
        return 1
    fi
    if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
        echo "FAIL $repo: $wt is dirty — a half-written bump; inspect, then 'git -C $gitdir worktree remove --force $wt'"
        return 1
    fi
    cur=$(jq -r '.version // empty' "$wt/.claude-plugin/plugin.json" 2> /dev/null || echo "")
    if [[ "$cur" == "$version" ]]; then
        echo "reusing $wt: bump already committed"
        return 0
    fi
    if [[ "$(git -C "$wt" rev-parse HEAD)" == "$(git -C "$gitdir" rev-parse "origin/$default")" ]]; then
        echo "reusing $wt: fresh worktree, bump not yet applied"
        return 0
    fi
    echo "FAIL $repo: $wt is clean but at version '$cur' on a stale base — inspect, then remove it"
    return 1
}

fr_lint_changelog() { # WT — the roll is generated text and generated text is
    # what nobody proofreads; 16 of 63 repos went red on MD022/MD032 once.
    # Advisory when no runner exists (the roll itself emits clean structure).
    # Only an ALREADY-INSTALLED binary is used — an on-demand `npx --yes`
    # would download and execute an unpinned package mid-sweep.
    local wt="$1"
    if command -v markdownlint-cli2 > /dev/null 2>&1; then
        ( cd "$wt" && markdownlint-cli2 CHANGELOG.md ) \
            && echo "markdownlint: CHANGELOG.md clean" \
            || echo "WARN: markdownlint flagged CHANGELOG.md — fix before merge goes red"
    else
        echo "markdownlint-cli2 not installed — structural guarantees from roll-changelog.py only"
    fi
}

fr_stage_allowlisted() { # REPO WT — stage every pending path, refusing anything
    # outside the version surfaces; -z parsing (paths with spaces exist in the
    # fleet), no add -A ever
    local repo="$1" wt="$2"
    local entry status path
    local paths=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] || continue
        status="${entry:0:2}"
        path="${entry:3}"
        case "$status" in
            R*|C*)
                echo "FAIL $repo: unexpected rename/copy in bump tree: $entry"
                return 1
                ;;
        esac
        if ! grep -qE "$FR_ALLOWLIST_RE" <<< "$path"; then
            echo "FAIL $repo: unexpected change outside the version surfaces: $path"
            return 1
        fi
        paths+=("$path")
    done < <(git -C "$wt" status --porcelain -z)
    [[ "${#paths[@]}" -gt 0 ]] || { echo "FAIL $repo: nothing to commit after bump"; return 1; }
    git -C "$wt" add -- "${paths[@]}"
}

fr_commit_allowlisted() { # REPO WT VERSION — only the four version surfaces may
    # move. Two attempts: a reformatting hook (pre-commit's pretty-format-json
    # --autofix, black, ruff format, …) rewrites a staged file and FAILS the
    # commit, and re-staging its output is the documented remedy — without it
    # a bump dies as "FAIL <repo>: commit" and leaves a half-written worktree
    # the resume then refuses as dirty (#263: it-maintenance-skill v1.15.0 and
    # netresearch-jira-skill v2.11.1 in the 2026-08-28 sweep, where the hook
    # sorts the keys sync-plugin-manifest.sh emits unsorted). The retry re-walks
    # the porcelain instead of re-adding the first attempt's paths, so a hook
    # that writes OUTSIDE the version surfaces still fails the allowlist. A
    # deterministic rejection fails the second attempt too and reports as before.
    local repo="$1" wt="$2" version="$3"
    local attempt ec
    for attempt in 1 2; do
        echo "--- porcelain (attempt $attempt):"
        git -C "$wt" status --porcelain
        fr_stage_allowlisted "$repo" "$wt" || return 1
        ( cd "$wt" && git commit -S --signoff -m "${FR_COMMIT_PREFIX}${version}" )
        ec=$?
        echo "COMMIT EXIT ($attempt): $ec"   # bare exit code — a pipe here once hid a hook abort
        if [[ "$ec" -eq 0 ]]; then
            return 0
        fi
        # An `if`, not `cond && echo`: the latter is the loop body's last
        # command and returns 1 on the second pass, which would make the
        # function's own status depend on how the caller suppresses `set -e`.
        if [[ "$attempt" -eq 1 ]]; then
            echo "commit failed — retrying once, in case a hook rewrote a staged file"
        fi
    done
    echo "FAIL $repo: commit"
    return 1
}

fr_create_and_record() { # REPO BRANCH VERSION BODY TARGET
    local repo="$1" branch="$2" version="$3" body="$4" target="$5" out prid prurl
    out=$(host_create_pr "$repo" "$branch" "${FR_COMMIT_PREFIX}${version}" "$body" "$target" < /dev/null) \
        || { echo "FAIL $repo: PR/MR create: $out"; return 1; }
    read -r prid prurl <<< "$out"
    fr_record_opened "$repo" "$prid" "$prurl" "$branch"
    echo "PR: $prurl"
    # Arm failure is not repo failure — finish merges plainly when green.
    host_arm_automerge "$repo" "$prid" < /dev/null || true
}

fr_bump() { # PLAN
    local plan="$1" logdir="$FR_WORKDIR/logs/bump" row repo n=0 rc=0
    fr_plan_validate "$plan"
    # Logs are per-RUN evidence: stale ones from a previous run would fail the
    # count invariant and resurrect old FAIL lines into this run's summary.
    find "$logdir" -maxdepth 1 -name '*.log' -delete 2> /dev/null || true
    while IFS= read -u 3 -r row || [[ -n "$row" ]]; do
        [[ -n "$row" ]] || continue
        repo=$(jq -r '.repo' <<< "$row")
        n=$((n + 1))
        fr_note "bump: $repo ..."
        # Subshell, never a brace group: a per-repo exit inside { } > log kills
        # the whole driver and the batch "completes" with missing logs.
        ( fr_bump_one "$row" ) > "$logdir/$repo.log" 2>&1 || rc=1
        tail -1 "$logdir/$repo.log" 2> /dev/null || rc=1
    done 3< "$plan"
    fr_check_log_invariant "$logdir" "$n" || rc=1
    fr_summarize_logs "$logdir" || rc=1
    fr_note ""
    fr_note "opened PRs recorded in $FR_WORKDIR/opened.jsonl"
    fr_note "next: $FR_DRIVER finish --workdir $FR_WORKDIR"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Finish phase
# ---------------------------------------------------------------------------
fr_finish_one() { # ROW — exit 0 ok, 1 pre-tag failure (loop continues),
    # 2 post-tag failure (systemic: the release machinery itself broke — the
    # loop HALTS, because "halt all further releases if this one fails" is a
    # numbered step of the spec's execution order)
    local row="$1"
    local repo version default cls tag_override
    repo=$(jq -r '.repo' <<< "$row")
    version=$(jq -r '.version // ""' <<< "$row")
    default=$(jq -r '.default // "main"' <<< "$row")
    cls=$(jq -r '.classification // "BUMP"' <<< "$row")
    tag_override=$(jq -r '.tag // ""' <<< "$row")
    local tag="${tag_override:-v$version}"
    local branch="${FR_BRANCH_PREFIX}${version}"
    local head
    head=$(jq -r '.head // ""' <<< "$row")
    echo "=== $(host_display "$repo") $tag ($cls) ==="
    [[ -n "$version" ]] || { echo "FAIL $repo: plan row has no version"; return 1; }
    case "$cls" in
        BUMP|FIRST-RELEASE|TAG-ONLY|OWN-PR-OPEN) ;;
        *)
            echo "FAIL $repo: classification $cls does not belong in the finish phase — resolve it first"
            return 1
            ;;
    esac

    local dir="$FR_BASE_DIR/$repo" gitdir
    gitdir=$(fr_resolve_gitdir "$dir") || { echo "FAIL $repo: no checkout at $dir"; return 1; }
    fr_check_origin "$gitdir" "$(host_origin_suffix "$repo")" || { echo "FAIL $repo: origin mismatch"; return 1; }

    # Idempotent re-run: a tag already on the remote means this repo released
    # (or a human tagged it) — verify the Release and stop, instead of failing
    # on "tip moved past the tag" after later commits landed on the default
    # branch.
    local pre_rc=0 pre_existing
    pre_existing=$(fr_remote_tag_commit "$gitdir" "$tag") || pre_rc=$?
    if [[ "$pre_rc" -eq 2 ]]; then
        echo "FAIL $repo: cannot read remote tags — not proceeding blind"
        return 1
    fi
    if [[ -n "$pre_existing" ]]; then
        echo "tag $tag already on the remote at $pre_existing — verifying its Release"
        host_release_verify "$repo" "$tag" < /dev/null \
            || { echo "FAIL $repo: tag $tag exists but has no verified Release (post-tag — halting the sweep)"; return 2; }
        fr_cleanup_release_branch "$dir" "$gitdir" "$branch" "$version" "$(fr_opened_lookup "$repo")"
        echo "OK $repo $tag released (verified on re-run)"
        return 0
    fi

    local prid
    prid=$(fr_opened_lookup "$repo")
    if [[ -z "$prid" ]]; then
        # No PR recorded: legitimate for TAG-ONLY / already-at-version repos.
        # An open release PR by SELF from a crashed earlier workdir is adopted;
        # anyone else's PR is never touched.
        local pr prurl prstate prauthor
        pr=$(host_find_release_pr "$repo" "$branch" < /dev/null || true)
        if [[ -n "$pr" ]]; then
            read -r prid prurl prstate prauthor <<< "$pr"
            case "$prstate" in
                open|OPEN|opened)
                    if [[ "$prauthor" == "$FR_SELF_LOGIN" ]]; then
                        echo "adopting own open PR $prurl (crashed earlier sweep)"
                        fr_record_opened "$repo" "$prid" "$prurl" "$branch"
                    else
                        echo "FAIL $repo: open release PR $prurl by @$prauthor — needs their go-ahead, not this sweep's"
                        return 1
                    fi
                    ;;
                *) prid="" ;;
            esac
        fi
    fi
    local target i
    if [[ -n "$prid" ]]; then
        host_merge_gate "$repo" "$prid" < /dev/null || { echo "FAIL $repo: merge gate"; return 1; }
        echo "merged."
        # Tag the MERGE COMMIT, not whatever the tip is by now: between merge
        # and tag a colleague's push can land, and tagging the live tip would
        # release unsurveyed commits. The merge commit is exactly what the
        # sweep's approval covered.
        target=$(host_merge_commit "$repo" "$prid" < /dev/null || true)
        [[ -n "$target" ]] || { echo "FAIL $repo: cannot resolve the merge commit of the bump PR"; return 1; }
        for i in 1 2 3 4 5; do
            fr_fetch_branches "$gitdir" > /dev/null
            git -C "$gitdir" cat-file -e "$target^{commit}" 2> /dev/null && break
            [[ "$i" -lt 5 ]] && sleep "$FR_POLL_SECONDS"
        done
        git -C "$gitdir" cat-file -e "$target^{commit}" 2> /dev/null \
            || { echo "FAIL $repo: merge commit $target never became fetchable"; return 1; }
        git -C "$gitdir" merge-base --is-ancestor "$target" "origin/$default" \
            || { echo "FAIL $repo: merge commit $target is not on origin/$default"; return 1; }
    else
        echo "no bump PR for this repo (${cls}) — tagging the committed version directly"
        target=$(host_remote_tip "$repo" "$default" < /dev/null) \
            || { echo "FAIL $repo: cannot read remote tip"; return 1; }
        for i in 1 2 3 4 5; do
            fr_fetch_branches "$gitdir" > /dev/null
            [[ "$(git -C "$gitdir" rev-parse "origin/$default")" == "$target" ]] && break
            [[ "$i" -lt 5 ]] && sleep "$FR_POLL_SECONDS"
        done
        [[ "$(git -C "$gitdir" rev-parse "origin/$default")" == "$target" ]] \
            || { echo "FAIL $repo: origin/$default never reached the remote tip $target"; return 1; }
        # Freshness: the sweep's approval covered the SURVEYED tip. Commits
        # since then are acceptable only if they touch nothing but the version
        # surfaces (i.e. the bump itself landed in between) — anything else on
        # the branch was never surveyed and must not ride into this tag.
        if [[ -n "$head" && "$target" != "$head" ]]; then
            local drift
            if ! drift=$(git -C "$gitdir" diff --name-only "$head" "$target" 2> /dev/null); then
                echo "FAIL $repo: surveyed head $head is unknown here (force-push?) — re-run survey"
                return 1
            fi
            drift=$(grep -vE "$FR_ALLOWLIST_RE" <<< "$drift" || true)
            if [[ -n "$drift" ]]; then
                echo "FAIL $repo: $default moved past the surveyed head with non-bump changes ($(tr '\n' ' ' <<< "$drift")) — re-run survey and re-plan"
                return 1
            fi
            echo "tip moved past the surveyed head by version-surface changes only — acceptable"
        elif [[ -z "$head" ]]; then
            echo "WARN: plan row carries no surveyed head — tagging the current tip unverified against the survey"
        fi
    fi

    fr_parity_from_ref "$gitdir" "$target" "$version" \
        || { echo "FAIL $repo: version parity at $target"; return 1; }
    echo "parity OK ($version at $target)"

    fr_tag_on_tip "$gitdir" "$tag" "$target" || { echo "FAIL $repo: tag"; return 1; }

    # Past this point a failure means the tag is on the remote but the release
    # machinery did not produce a verified Release object — that class is
    # contagious (a broken shared workflow breaks every following repo too).
    host_release_verify "$repo" "$tag" < /dev/null \
        || { echo "FAIL $repo: no verified Release for $tag (post-tag — halting the sweep)"; return 2; }

    fr_cleanup_release_branch "$dir" "$gitdir" "$branch" "$version" "$prid"
    echo "OK $repo $tag released"
}

fr_cleanup_release_branch() { # DIR GITDIR BRANCH VERSION PRID — tolerant;
    # the REMOTE branch is deleted only when this sweep owns a PR for it —
    # deleting a branch the sweep never created is not cleanup, it is damage
    local dir="$1" gitdir="$2" branch="$3" version="$4" prid="$5" wt
    wt=$(fr_worktree_path "$dir" "$version")
    if [[ -e "$wt" ]]; then
        git -C "$gitdir" worktree remove "$wt" 2> /dev/null && echo "worktree removed"
    fi
    git -C "$gitdir" branch -D "$branch" > /dev/null 2>&1 || true
    if [[ -n "$prid" ]]; then
        git -C "$gitdir" push origin --delete "$branch" 2> /dev/null \
            && echo "remote branch deleted" || echo "remote branch already gone"
    fi
}

fr_finish() { # PLAN [--continue]
    local plan="$1" cont="${2:-}" logdir="$FR_WORKDIR/logs/finish" row repo n=0 rc=0 ec
    fr_plan_validate "$plan"
    find "$logdir" -maxdepth 1 -name '*.log' -delete 2> /dev/null || true
    while IFS= read -u 3 -r row || [[ -n "$row" ]]; do
        [[ -n "$row" ]] || continue
        repo=$(jq -r '.repo' <<< "$row")
        n=$((n + 1))
        fr_note "finish: $repo ..."
        ec=0
        # Tested context on purpose: it suppresses errexit inside the subshell
        # so the explicit FAIL/return handling governs, not set -e.
        ( fr_finish_one "$row" ) > "$logdir/$repo.log" 2>&1 || ec=$?
        tail -1 "$logdir/$repo.log" 2> /dev/null || rc=1
        if [[ "$ec" -eq 2 && "$cont" != "--continue" ]]; then
            rc=1
            fr_err "post-tag failure in $repo — halting (release-discipline: halt all further releases if one fails). Diagnose, then re-run finish; --continue overrides."
            break
        fi
        [[ "$ec" -eq 0 ]] || rc=1
    done 3< "$plan"
    fr_summarize_logs "$logdir" || rc=1
    fr_note ""
    fr_note "logs: $logdir"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Repo-list resolution
# ---------------------------------------------------------------------------
fr_repos_from() { # REPOS_INLINE REPOS_FILE DEFAULT_FILE — echoes the list;
    # '#' comment lines and blanks in files are skipped
    local inline="$1" file="$2" fallback="$3"
    if [[ -n "$inline" ]]; then
        printf '%s\n' "$inline" | tr ' ' '\n' | grep -v '^$' || true
    elif [[ -n "$file" ]]; then
        grep -vE '^\s*(#|$)' "$file" || true
    elif [[ -f "$fallback" ]]; then
        grep -vE '^\s*(#|$)' "$fallback" || true
    fi
}
