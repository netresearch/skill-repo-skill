#!/usr/bin/env bash
# audit-skills.sh - Per-skill content quality audit for Claude Code skill directories
# Usage: ./audit-skills.sh [--help] [--json] [DIR ...]
#
# Scans SKILL.md files and reports:
#   - DESCRIPTION length (PASS/WARN >500 chars/FAIL >1536 chars)
#   - BODY word count (PASS/INFO >500/WARN >1000/FAIL >2000) and line metrics
#   - CODE FENCE longest block (PASS/INFO at >25 lines)
#   - REFERENCES reachability (P1 direct cite, P2 catalog convention,
#                              P3 list-and-pick, ORPHAN otherwise)
# Exit: 0 if no FAILs, 1 otherwise.
#
# shellcheck disable=SC2155 # local var with command substitution is intentional
# shellcheck disable=SC2016 # single-quoted awk/grep patterns are deliberate
# shellcheck disable=SC2207 # word-split into array via $(...) is fine here
# shellcheck disable=SC2034 # some color vars are unused when --json is selected

set -uo pipefail

# --- CLI parsing ---
JSON_OUTPUT=0
DIRS=()

usage() {
    cat <<'EOF'
Usage: audit-skills.sh [--help] [--json] [DIR ...]

Audits Claude Code skill directories (SKILL.md files) for content quality.

Options:
  --help    Show this help and exit.
  --json    Emit one JSON object per skill (newline-delimited) instead of
            human-readable text. Summary is suppressed in JSON mode.
  DIR ...   One or more directories to scan recursively for SKILL.md.
            If none given, defaults to:
              ~/.claude/skills
              ~/.claude/plugins/cache
            Paths matching */evals/* are always skipped.

Quality rules:
  DESCRIPTION  WARN >500 chars,  FAIL >1536 chars (Claude Code truncates).
  BODY         INFO >500 words, WARN >1000 words, FAIL >2000 words.
               Thresholds set by per-invocation token cost (~1.4x word count).
  CODE FENCES  INFO when longest fenced block exceeds 25 lines.
  REFERENCES   ORPHAN when references/*.md has no reachability pattern.

Exit code: 0 if no FAILs across all skills, 1 otherwise.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --json) JSON_OUTPUT=1; shift ;;
        --) shift; while [[ $# -gt 0 ]]; do DIRS+=("$1"); shift; done ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

if [[ ${#DIRS[@]} -eq 0 ]]; then
    DIRS=("$HOME/.claude/skills" "$HOME/.claude/plugins/cache")
fi

# --- Color codes (suppressed under --json) ---
if [[ $JSON_OUTPUT -eq 0 ]] && [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    YEL=$'\033[1;33m'
    GRN=$'\033[0;32m'
    BLU=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED=""; YEL=""; GRN=""; BLU=""; NC=""
fi

# --- Counters ---
TOTAL_SKILLS=0
TOTAL_FAIL=0
TOTAL_WARN=0
TOTAL_INFO=0
TOTAL_ORPHANS=0
SKILLS_WITH_ORPHANS=0

# --- Helpers ---

# json_escape: escape a string for embedding in a JSON string literal.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# extract_frontmatter <skill_md>: prints YAML frontmatter (between first two ---)
# Returns nonzero if frontmatter is missing or malformed.
extract_frontmatter() {
    local f="$1"
    # Must start with "---" on line 1
    local first
    first=$(head -n 1 "$f")
    [[ "$first" == "---" ]] || return 1
    # Find the closing --- after line 1
    local close
    close=$(awk 'NR==1 && $0=="---"{next} $0=="---"{print NR; exit}' "$f")
    [[ -n "$close" ]] || return 1
    # Print lines between (exclusive)
    awk -v end="$close" 'NR>1 && NR<end' "$f"
    return 0
}

# get_description <frontmatter>: print description value, stripped of surrounding
# quotes and leading/trailing whitespace. Empty output => not found.
get_description() {
    awk '
        BEGIN { collecting=0; val="" }
        /^[a-zA-Z_][a-zA-Z0-9_-]*:/ {
            if (collecting) { print val; exit }
        }
        /^description:/ {
            sub(/^description:[[:space:]]*/, "", $0)
            val = $0
            collecting = 1
            next
        }
        collecting && /^[[:space:]]+/ {
            sub(/^[[:space:]]+/, " ", $0)
            val = val $0
        }
        END { if (collecting) print val }
    ' <<<"$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# get_body <skill_md>: print SKILL.md content excluding frontmatter.
get_body() {
    local f="$1"
    local first
    first=$(head -n 1 "$f")
    if [[ "$first" == "---" ]]; then
        local close
        close=$(awk 'NR==1 && $0=="---"{next} $0=="---"{print NR; exit}' "$f")
        if [[ -n "$close" ]]; then
            awk -v start="$((close+1))" 'NR>=start' "$f"
            return
        fi
    fi
    cat "$f"
}

# fence_stats <body_text>: prints "<count> <longest_lines>"
fence_stats() {
    awk '
        BEGIN { in_fence=0; count=0; cur=0; longest=0 }
        /^[[:space:]]*```/ {
            if (in_fence) {
                if (cur > longest) longest = cur
                in_fence = 0
                cur = 0
            } else {
                in_fence = 1
                count++
                cur = 0
            }
            next
        }
        in_fence { cur++ }
        END {
            if (in_fence && cur > longest) longest = cur
            print count, longest
        }
    ' <<<"$1"
}

# audit_one <skill_md_path>
audit_one() {
    local skill_md="$1"
    local skill_dir
    skill_dir=$(dirname "$skill_md")
    local skill_name
    skill_name=$(basename "$skill_dir")

    # Path display: relative to cwd if it's inside cwd, else absolute.
    local display_path="$skill_md"
    local cwd_abs
    cwd_abs=$(pwd -P)
    if [[ "$skill_md" == "$cwd_abs"/* ]]; then
        display_path="${skill_md#"$cwd_abs"/}"
    fi

    TOTAL_SKILLS=$((TOTAL_SKILLS + 1))

    # --- Frontmatter & description ---
    local fm desc desc_status="PASS" desc_len=0 desc_warn_msg=""
    if ! fm=$(extract_frontmatter "$skill_md"); then
        # Broken frontmatter - WARN, skip rest of frontmatter checks.
        # Pass all 17 args expected by emit_skill, with valid status strings
        # for body/fence so $16/$17 are never unset under set -u.
        TOTAL_WARN=$((TOTAL_WARN + 1))
        emit_skill "$skill_name" "$display_path" \
            "WARN" "0" "broken or missing frontmatter" \
            "PASS" "0" "0" \
            "PASS" "0" "0" \
            "0" "0" "0" "0" "0" ""
        return
    fi

    desc=$(get_description "$fm")
    if [[ -z "$desc" ]]; then
        desc_status="FAIL"
        desc_warn_msg="missing description field"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    else
        desc_len=${#desc}
        if (( desc_len > 1536 )); then
            desc_status="FAIL"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        elif (( desc_len > 500 )); then
            desc_status="WARN"
            TOTAL_WARN=$((TOTAL_WARN + 1))
        fi
    fi

    # --- Body metrics ---
    local body
    body=$(get_body "$skill_md")
    local body_words body_lines
    body_words=$(printf '%s' "$body" | wc -w | tr -d ' ')
    body_lines=$(printf '%s' "$body" | grep -c '^' || echo 0)
    local body_status="PASS"
    if (( body_words > 2000 )); then
        body_status="FAIL"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    elif (( body_words > 1000 )); then
        body_status="WARN"
        TOTAL_WARN=$((TOTAL_WARN + 1))
    elif (( body_words > 500 )); then
        body_status="INFO"
        TOTAL_INFO=$((TOTAL_INFO + 1))
    fi

    # --- Code fences ---
    local fence_line fence_count fence_longest
    fence_line=$(fence_stats "$body")
    fence_count=$(awk '{print $1}' <<<"$fence_line")
    fence_longest=$(awk '{print $2}' <<<"$fence_line")
    [[ -z "$fence_count" ]] && fence_count=0
    [[ -z "$fence_longest" ]] && fence_longest=0
    local fence_status="PASS"
    if (( fence_longest > 25 )); then
        fence_status="INFO"
        TOTAL_INFO=$((TOTAL_INFO + 1))
    fi

    # --- References reachability ---
    local refs_dir="$skill_dir/references"
    local ref_total=0 ref_p1=0 ref_p2=0 ref_p3=0 ref_orphan=0
    local orphan_list=""
    if [[ -d "$refs_dir" ]]; then
        # Detect Pattern 3 (list-and-pick) once for the whole SKILL.md
        local p3_hit=0
        if grep -qE -i \
'list[[:space:]]+`?references/`?|browse[[:space:]]+(the[[:space:]]+)?references/?[[:space:]]+(directory|dir|folder)|read[[:space:]]+the[[:space:]]+(relevant|appropriate|matching)[[:space:]]+(file|files)[[:space:]]+in[[:space:]]+`?references/`?|see[[:space:]]+`?references/`?[[:space:]]+for' \
            "$skill_md"; then
            p3_hit=1
        fi

        # Detect Pattern 2 (catalog-with-convention).
        # Look for a heading or paragraph mentioning references/ or "in references";
        # then within the next ~30 lines look for a parenthetical convention like
        # (*-foo) or (.md implied).
        # Capture suffixes from "(*-suffix)" patterns.
        local p2_suffixes=()
        local p2_md_implied=0
        local awk_p2
        awk_p2=$(awk '
            BEGIN { trigger=0; window=0 }
            function scan_line(    line, tok) {
                line=$0
                # Extract (*-suffix) or (`*-suffix`) patterns; allow optional backticks
                while (match(line, /\(`?\*-[A-Za-z0-9_-]+`?\)/)) {
                    tok=substr(line, RSTART+1, RLENGTH-2)  # strip leading "(" and trailing ")"
                    gsub(/`/, "", tok)                      # strip optional backticks
                    sub(/^\*-/, "", tok)                    # strip leading "*-"
                    print "SUFFIX:" tok
                    line=substr(line, RSTART+RLENGTH)
                }
                # Detect ".md implied" inside a parenthetical (allowing backticks/extra text)
                if (tolower($0) ~ /\([^)]*\.md[^)]*implied[^)]*\)/ || tolower($0) ~ /\(`?\.md`?\)/) {
                    print "MDIMPLIED"
                }
            }
            tolower($0) ~ /references\// || tolower($0) ~ /in[[:space:]]+references\>/ {
                trigger=1; window=30
                scan_line()
                next
            }
            trigger && window>0 {
                window--
                scan_line()
                if (window==0) { trigger=0 }
            }
        ' "$skill_md" 2>/dev/null || true)
        while IFS= read -r p2line; do
            [[ -z "$p2line" ]] && continue
            case "$p2line" in
                SUFFIX:*) p2_suffixes+=("${p2line#SUFFIX:}") ;;
                MDIMPLIED) p2_md_implied=1 ;;
            esac
        done <<<"$awk_p2"

        # Iterate through references/*.md
        local refpath base
        while IFS= read -r refpath; do
            [[ -z "$refpath" ]] && continue
            ref_total=$((ref_total + 1))
            base=$(basename "$refpath" .md)

            # Pattern 1: direct cite "references/<name>.md"
            if grep -qF "references/${base}.md" "$skill_md"; then
                ref_p1=$((ref_p1 + 1))
                continue
            fi

            # Pattern 2: matches a captured suffix
            local matched_p2=0
            if (( ${#p2_suffixes[@]} > 0 )); then
                local sfx
                for sfx in "${p2_suffixes[@]}"; do
                    if [[ "$base" == *"-${sfx}" ]] || [[ "$base" == *"${sfx}" ]]; then
                        matched_p2=1
                        break
                    fi
                done
            fi
            # Or: "(.md implied)" convention + base name appears as a bullet-ish word
            if (( matched_p2 == 0 )) && (( p2_md_implied == 1 )); then
                if grep -qE "(^|[[:space:]\`*-])${base}([[:space:]\`,.)]|$)" "$skill_md"; then
                    matched_p2=1
                fi
            fi
            if (( matched_p2 == 1 )); then
                ref_p2=$((ref_p2 + 1))
                continue
            fi

            # Pattern 3: SKILL.md instructs listing references/
            if (( p3_hit == 1 )); then
                ref_p3=$((ref_p3 + 1))
                continue
            fi

            # Otherwise: ORPHAN
            ref_orphan=$((ref_orphan + 1))
            if [[ -z "$orphan_list" ]]; then
                orphan_list="$(basename "$refpath")"
            else
                orphan_list="${orphan_list}|$(basename "$refpath")"
            fi
        done < <(find "$refs_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

        if (( ref_orphan > 0 )); then
            TOTAL_ORPHANS=$((TOTAL_ORPHANS + ref_orphan))
            SKILLS_WITH_ORPHANS=$((SKILLS_WITH_ORPHANS + 1))
        fi
    fi

    emit_skill "$skill_name" "$display_path" \
        "$desc_status" "$desc_len" "$desc_warn_msg" \
        "$body_status" "$body_words" "$body_lines" \
        "$fence_status" "$fence_count" "$fence_longest" \
        "$ref_total" "$ref_p1" "$ref_p2" "$ref_p3" \
        "$ref_orphan" "$orphan_list"
}

# emit_skill: prints results in either text or JSON form.
# Args: name path desc_status desc_len desc_msg
#       body_status body_words body_lines
#       fence_status fence_count fence_longest
#       ref_total ref_p1 ref_p2 ref_p3 ref_orphan orphan_list
emit_skill() {
    local name="$1" path="$2"
    local ds="$3" dl="$4" dm="$5"
    local bs="$6" bw="$7" bln="$8"
    local fs="$9" fc="${10}" fl="${11}"
    local rt="${12}" rp1="${13}" rp2="${14}" rp3="${15}" rorph="${16}" olist="${17}"

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        # Build orphan JSON array
        local orphans_json="[]"
        if [[ -n "$olist" ]]; then
            local arr=()
            IFS='|' read -r -a arr <<<"$olist"
            local items=""
            local item
            for item in "${arr[@]}"; do
                [[ -z "$item" ]] && continue
                if [[ -z "$items" ]]; then
                    items="\"$(json_escape "$item")\""
                else
                    items="$items,\"$(json_escape "$item")\""
                fi
            done
            orphans_json="[$items]"
        fi
        printf '{"name":"%s","path":"%s","description":{"status":"%s","chars":%s,"message":"%s"},"body":{"status":"%s","words":%s,"lines":%s},"code_fences":{"status":"%s","count":%s,"longest_lines":%s},"references":{"total":%s,"p1_direct":%s,"p2_catalog":%s,"p3_listpick":%s,"reachable":%s,"orphans":%s,"orphan_files":%s}}\n' \
            "$(json_escape "$name")" "$(json_escape "$path")" \
            "$ds" "$dl" "$(json_escape "$dm")" \
            "$bs" "$bw" "$bln" \
            "$fs" "$fc" "$fl" \
            "$rt" "$rp1" "$rp2" "$rp3" "$((rp1 + rp2 + rp3))" "$rorph" "$orphans_json"
        return
    fi

    # Text output
    echo "=========================================="
    echo "SKILL: $name"
    echo "PATH: $path"
    echo "=========================================="
    local ds_color="$GRN"
    case "$ds" in WARN) ds_color="$YEL" ;; FAIL) ds_color="$RED" ;; esac
    if [[ -n "$dm" ]]; then
        echo "DESCRIPTION: $dl chars [${ds_color}${ds}${NC}] - $dm"
    else
        echo "DESCRIPTION: $dl chars [${ds_color}${ds}${NC}]"
    fi
    local bs_color="$GRN"
    case "$bs" in INFO) bs_color="$BLU" ;; WARN) bs_color="$YEL" ;; FAIL) bs_color="$RED" ;; esac
    echo "BODY: $bw words, $bln lines [${bs_color}${bs}${NC}]"
    local fs_color="$GRN"; [[ "$fs" == "INFO" ]] && fs_color="$BLU"
    echo "CODE FENCES: $fc fenced blocks, longest $fl lines [${fs_color}${fs}${NC}]"
    local reachable=$((rp1 + rp2 + rp3))
    if (( rt > 0 )); then
        echo "REFERENCES: $rt total -> ${rp1}/P1 + ${rp2}/P2 + ${rp3}/P3 = ${reachable} reachable, ${rorph} ORPHAN"
        if [[ -n "$olist" ]]; then
            local arr=()
            IFS='|' read -r -a arr <<<"$olist"
            local item
            for item in "${arr[@]}"; do
                [[ -z "$item" ]] && continue
                echo "  ORPHAN: $item"
            done
        fi
    else
        echo "REFERENCES: 0 total (no references/ directory)"
    fi
    echo ""
}

# --- Find SKILL.md files across DIRS ---
# Skip */evals/* paths.
SKILL_FILES=()
for d in "${DIRS[@]}"; do
    if [[ ! -d "$d" ]]; then
        if [[ $JSON_OUTPUT -eq 0 ]]; then
            echo "${YEL}WARN:${NC} directory not found, skipping: $d" >&2
        fi
        continue
    fi
    while IFS= read -r f; do
        [[ -n "$f" ]] && SKILL_FILES+=("$f")
    done < <(find "$d" -type f -name 'SKILL.md' -not -path '*/evals/*' 2>/dev/null | sort -u)
done

if [[ ${#SKILL_FILES[@]} -eq 0 ]]; then
    if [[ $JSON_OUTPUT -eq 0 ]]; then
        echo "No SKILL.md files found in: ${DIRS[*]}" >&2
    fi
    exit 0
fi

# --- Audit each skill ---
for sf in "${SKILL_FILES[@]}"; do
    audit_one "$sf"
done

# --- Summary (text only) ---
if [[ $JSON_OUTPUT -eq 0 ]]; then
    echo "SUMMARY: $TOTAL_SKILLS skills, $TOTAL_FAIL FAIL, $TOTAL_WARN WARN, $TOTAL_INFO INFO, $TOTAL_ORPHANS ORPHAN refs across $SKILLS_WITH_ORPHANS skills"
fi

if (( TOTAL_FAIL > 0 )); then
    exit 1
fi
exit 0
