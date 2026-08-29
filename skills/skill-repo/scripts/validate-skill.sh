#!/usr/bin/env bash
# validate-skill.sh - Validate Netresearch skill repository structure
# Usage: ./validate-skill.sh [repo-root-path]
#
# Checks: SKILL.md frontmatter, word count, composer.json, plugin.json,
#          cross-file consistency, required files
# Env:    STRICT_README=1 (also true/yes, case-insensitive) promotes README heading misses from warnings to errors
# Exit: 0 = valid, 1 = errors found

set -euo pipefail

REPO_DIR="${1:-.}"
ERRORS=0
WARNINGS=0
NAME=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1"; ((ERRORS++)) || true; }
warning() { echo -e "${YELLOW}WARNING:${NC} $1"; ((WARNINGS++)) || true; }
success() { echo -e "${GREEN}OK:${NC} $1"; }

# Check python3 availability (required for JSON parsing)
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}ERROR:${NC} python3 is required for JSON parsing but not found in PATH"
    exit 1
fi

echo "Validating skill repository: $REPO_DIR"
echo "========================================"

# --- Discover every SKILL.md ---
# A repo may ship several skills. Validating only the first one meant the rest
# had no frontmatter check, no "Use when" check and no word count: matrix-skill
# reported a single 498-word line for skills/matrix-administration while
# matrix-communication sat at 896 words, over the cap, for as long as the repo
# existed (issue #214). Every skill found is validated and every finding counts
# toward the exit code.
SKILL_FILES=()
if [[ -f "$REPO_DIR/SKILL.md" ]]; then
    SKILL_FILES+=("$REPO_DIR/SKILL.md")
fi
for f in "$REPO_DIR"/skills/*/SKILL.md; do
    if [[ -f "$f" ]]; then
        # A skills/<name>/SKILL.md that is the root file (symlink or hardlink)
        # would otherwise be reported twice under two names.
        if [[ ${#SKILL_FILES[@]} -gt 0 && "$f" -ef "${SKILL_FILES[0]}" ]]; then
            continue
        fi
        SKILL_FILES+=("$f")
    fi
done

# --- Per-skill checks ---
# Every message names the file it is about, so a finding in a multi-skill repo
# is attributable without counting output lines.
validate_skill_md() {
    local skill_file="$1"
    local rel="${skill_file#"$REPO_DIR"/}"
    local skill_name=""
    # Declared local so nothing carries over from the previous skill in the loop.
    local closing_line frontmatter extra_fields field_names desc compat
    local desc_chars body_lines skill_body base unnamed linked_from ref_lines
    local relative_paths count skill_dir skill_dir_rel checkpoints_justified
    local untested misclassified f s base dangling token rel
    # After the local declarations, not before them: `local skill_dir` resets a
    # value assigned above it, so an earlier assignment silently becomes unset
    # and `set -u` then aborts the run mid-way -- which prints no summary and
    # reads as a repository that passed.
    skill_dir="$(dirname "$skill_file")"
    skill_dir_rel="${skill_dir#"$REPO_DIR"}"
    skill_dir_rel="${skill_dir_rel#/}"
    skill_dir_rel="${skill_dir_rel:-.}"
    success "SKILL.md found: $rel"

    # Frontmatter delimiter
    if head -1 "$skill_file" | grep -q "^---$"; then
        # Verify closing --- delimiter exists (within first 30 lines)
        closing_line=$(sed -n '2,30{/^---$/=}' "$skill_file" | head -1)
        if [[ -z "$closing_line" ]]; then
            error "$rel frontmatter has opening --- but no closing --- delimiter"
        else
            success "$rel has frontmatter"
        fi

        # Extract frontmatter fields (between first two --- lines)
        frontmatter=$(sed -n '2,/^---$/{ /^---$/d; p; }' "$skill_file")

        # Check frontmatter fields match Agent Skills spec
        # Allowed: name, description, license, compatibility, metadata, allowed-tools
        extra_fields=$(echo "$frontmatter" | grep -E "^[a-z_-]+:" | grep -vE "^(name|description|license|compatibility|metadata|allowed-tools):" || true)
        if [[ -z "$extra_fields" ]]; then
            success "$rel frontmatter fields are valid per Agent Skills spec"
        else
            field_names=$(echo "$extra_fields" | sed 's/:.*//' | tr '\n' ', ' | sed 's/,$//')
            error "$rel frontmatter has non-spec fields: $field_names (allowed: name, description, license, compatibility, metadata, allowed-tools)"
        fi

        # Check name field
        if echo "$frontmatter" | grep -q "^name:"; then
            skill_name=$(echo "$frontmatter" | grep "^name:" | head -1 | sed 's/name: *//' | tr -d '"')
            # The plugin.json comparison further down uses one name. Single-skill
            # repos keep the behaviour they had; multi-skill repos skip that
            # comparison anyway, since plugin.json names the plugin, not a skill.
            if [[ -z "$NAME" ]]; then
                NAME="$skill_name"
            fi
            # The spec forbids more than the character class does: no leading
            # or trailing hyphen, and no consecutive hyphens. A name that only
            # passes the class still fails a spec-conformant loader.
            if [[ ! "$skill_name" =~ ^[a-z0-9-]{1,64}$ ]]; then
                error "$rel name invalid (lowercase, hyphens, max 64): $skill_name"
            elif [[ "$skill_name" == -* || "$skill_name" == *- ]]; then
                error "$rel name must not start or end with a hyphen: $skill_name"
            elif [[ "$skill_name" == *--* ]]; then
                error "$rel name must not contain consecutive hyphens: $skill_name"
            else
                success "$rel name valid: $skill_name"
            fi
        else
            error "$rel missing 'name' field"
        fi

        # Check description field and prefix
        if echo "$frontmatter" | grep -q "^description:"; then
            # Parse the *YAML value* of description so every valid scalar style
            # (plain, single/double-quoted, block) is accepted as long as the
            # parsed value starts with "Use when". Uses PyYAML when available,
            # otherwise a stdlib-only fallback covering the common scalar styles,
            # so the script keeps running with just python3 (no yq/PyYAML needed).
            # When PyYAML is present it is authoritative: invalid YAML is
            # reported (sentinel __PARSE_ERROR__), not silently re-parsed by the
            # fallback. The stdlib-only fallback runs solely when PyYAML is
            # absent, so the script still works with just python3.
            desc=$(FRONTMATTER="$frontmatter" python3 <<'PYEOF' 2>/dev/null || echo "__PARSE_ERROR__"
import os, re, sys

fm = os.environ["FRONTMATTER"]

try:
    import yaml
except Exception:
    yaml = None

if yaml is not None:
    # PyYAML available: trust it fully so semantics match CI exactly.
    try:
        data = yaml.safe_load(fm)
    except Exception:
        print("__PARSE_ERROR__")
        sys.exit(0)
    desc = data.get("description") if isinstance(data, dict) else None
    print(desc if desc is not None else "")
    sys.exit(0)

# Fallback without PyYAML: best-effort for the common scalar styles
# (plain, single/double-quoted, block). description: is a column-0 key.
desc = None
lines = fm.splitlines()
for i, line in enumerate(lines):
    m = re.match(r"description:[ \t]*(.*)$", line)
    if not m:
        continue
    val = m.group(1).strip()
    if val[:1] in ("|", ">"):
        # Block scalar: first non-blank line that is indented into the block.
        # A column-0 (non-indented) line is the next sibling key -> empty body.
        for nxt in lines[i + 1:]:
            if not nxt.strip():
                continue
            if not nxt[:1].isspace():
                break
            desc = nxt.strip()
            break
    else:
        dq = re.match(r'"((?:[^"\\]|\\.)*)"[ \t]*(?:#.*)?$', val)
        sq = re.match(r"'((?:[^']|'')*)'[ \t]*(?:#.*)?$", val)
        if dq:
            desc = dq.group(1)
        elif sq:
            desc = sq.group(1).replace("''", "'")
        else:
            # Plain scalar: strip a trailing ' #' comment (YAML needs the space).
            desc = re.sub(r"[ \t]+#.*$", "", val)
    break

print(desc if desc is not None else "")
PYEOF
)
            if [[ "$desc" == "__PARSE_ERROR__" ]]; then
                error "$rel frontmatter is not valid YAML (could not parse 'description')"
            elif [[ "$desc" == Use\ when* ]]; then
                success "$rel description starts with 'Use when'"
            else
                error "$rel description must start with 'Use when': ${desc:0:60}..."
            fi

            # The description is a ROUTER, not documentation. It is the only
            # thing loaded at startup for every skill, so it decides whether
            # this skill is ever consulted -- a gap here is the one failure
            # that cannot be recovered later. The spec sets a hard 1024.
            #
            # The soft 500 is a nudge, not a defect: the official guidance is
            # "a few sentences to a short paragraph" and explicitly says to
            # err on the side of being pushy about listing contexts. Long is
            # not automatically wrong; long AND full of workflow steps is.
            if [[ "$desc" != "__PARSE_ERROR__" ]]; then
                desc_chars=${#desc}
                if (( desc_chars > 1024 )); then
                    error "$rel description is $desc_chars chars (spec hard limit 1024) - cut process detail, keep capability and trigger"
                elif (( desc_chars > 500 )); then
                    warning "$rel description is $desc_chars chars - past 500 it is usually workflow narration; the description should say WHAT and WHEN, not HOW"
                else
                    success "$rel description is $desc_chars chars"
                fi
            fi
        else
            error "$rel missing 'description' field"
        fi

        # compatibility: spec caps it at 500 characters, and most skills should
        # not carry the field at all.
        if echo "$frontmatter" | grep -q "^compatibility:"; then
            # Octal escapes for the two quote characters: a literal quote here
            # would terminate the string it lives in (the same trap the awk
            # programs in this file avoid the same way).
            compat=$(echo "$frontmatter" | grep "^compatibility:" | head -1 \
                     | sed 's/compatibility: *//' | tr -d '\42\47')
            if (( ${#compat} > 500 )); then
                error "$rel compatibility is ${#compat} chars (spec max 500)"
            fi
        fi
    else
        error "$rel missing frontmatter (must start with ---)"
    fi

    # Body size. The spec recommends "Keep your main SKILL.md under 500 lines"
    # and "< 5000 tokens recommended" for the instructions loaded on activation.
    # This used to count 500 WORDS over the WHOLE file -- a much tighter and
    # differently shaped budget, and one that charged the frontmatter to the
    # body. That inversion is the expensive part: the description is the
    # routing surface, so making it compete with the instructions for one
    # allowance buys a shorter description at the price of an undocumented
    # capability. Lines, body only.
    #
    # 300 is the WARN, not the target: past it, ask which lines are control
    # flow and which are reference material that belongs in references/.
    body_lines=$(awk 'BEGIN{d=0} /^---$/{d++; next} d>=2{print}' "$skill_file" | wc -l)
    if (( body_lines > 500 )); then
        error "$rel body is $body_lines lines (spec recommends under 500) - move reference material into references/"
    elif (( body_lines > 300 )); then
        warning "$rel body is $body_lines lines - past 300, split reference material out and keep SKILL.md the control plane"
    else
        success "$rel body is $body_lines lines"
    fi
    # Check for relative script paths that should use ${CLAUDE_SKILL_DIR}
    # Matches: uv run scripts/, python3 scripts/, python scripts/, bash scripts/, ./scripts/, sh scripts/
    # But ignores lines already using ${CLAUDE_SKILL_DIR}
    relative_paths=$(grep -nE '(uv run|python3?|bash|sh|\./)([ ]+)scripts/' "$skill_file" | grep -v 'CLAUDE_SKILL_DIR' || true)
    if [[ -n "$relative_paths" ]]; then
        count=$(echo "$relative_paths" | wc -l)
        warning "$rel has $count script reference(s) using relative paths instead of \${CLAUDE_SKILL_DIR}/scripts/"
    fi

    # --- Flat discovery ------------------------------------------------------
    # Agent Skills spec: "Keep file references one level deep from SKILL.md.
    # Avoid deeply nested reference chains." The rule exists because each hop is
    # a decision the agent may not make. SKILL.md is read in full on activation;
    # a reference is read only if SKILL.md said what it holds and when to open
    # it. A file reachable only through a second hop sits behind an unmarked
    # door. These are warnings, not errors: a chain is a smell, not a breach.
    if [[ -n "$skill_dir" && -d "$skill_dir" ]]; then
        skill_body=$(awk 'BEGIN{d=0} /^---$/{d++; next} d>=2{print}' "$skill_file")

        # Scripts are executed, never loaded into context, so naming one costs a
        # line and is the only chance the agent has of knowing it exists.
        if [[ -d "$skill_dir/scripts" ]]; then
            unnamed=""
            for f in "$skill_dir"/scripts/*; do
                [[ -f "$f" ]] || continue
                base="$(basename "$f")"
                case "$base" in *.md|*.txt|README*) continue ;; esac
                # Non-executable files are sourced libraries, not capabilities
                # the agent invokes; their caller is what belongs in SKILL.md.
                [[ -x "$f" ]] || continue
                grep -qF "$base" <<<"$skill_body" || unnamed="$unnamed $base"
            done
            if [[ -n "$unnamed" ]]; then
                warning "${skill_dir_rel}: script(s) not named in SKILL.md:${unnamed} - a script reachable only through a reference is found only if that reference is opened"
            fi
        fi

        if [[ -d "$skill_dir/references" ]]; then
            for f in "$skill_dir"/references/*.md; do
                [[ -f "$f" ]] || continue
                base="$(basename "$f")"

                if ! grep -qF "$base" <<<"$skill_body"; then
                    linked_from=""
                    for other in "$skill_dir"/references/*.md; do
                        [[ -f "$other" && "$other" != "$f" ]] || continue
                        if grep -qF "$base" "$other"; then
                            linked_from="$(basename "$other")"
                            break
                        fi
                    done
                    if [[ -n "$linked_from" ]]; then
                        warning "${skill_dir_rel}: references/${base} is reachable only via references/${linked_from} - the spec asks for one level; link it from SKILL.md too"
                    else
                        warning "${skill_dir_rel}: references/${base} is not named in SKILL.md - nothing tells the agent it exists or when to read it"
                    fi
                fi

                # Agents preview long files rather than reading them whole, so a
                # contents list is what makes the rest of a long reference
                # visible at all.
                ref_lines=$(grep -c "" "$f")
                if (( ref_lines > 100 )) && ! grep -qiE '^#{1,3} +(contents|table of contents|overview|in this (file|document))' "$f"; then
                    warning "${skill_dir_rel}: references/${base} is $ref_lines lines with no Contents section - agents preview long files; add one so the rest is discoverable"
                fi
            done
        fi
    fi

    # --- Dangling references -------------------------------------------------
    # The mirror image of flat discovery: a path SKILL.md names must exist under
    # the skill directory. A reference that resolves to nothing is a door the
    # agent opens onto a wall -- it costs a tool call and returns an error where
    # the skill promised content. retro-skill#19 hit this in production: the
    # skill shipped with scripts/ and references/ outside the declared skill
    # directory, so every path in SKILL.md was dead on a faithful install.
    # Skill-relative directories per the Agent Skills spec (scripts/,
    # references/, assets/) plus evals/; `${CLAUDE_SKILL_DIR}/` resolves to the
    # skill directory and is accepted as a prefix. Globs, placeholders and
    # other variables are not paths and are skipped.
    #
    # Both spellings count: a backticked span and a Markdown link target. A
    # SKILL.md that names its references as links only -- the common shape --
    # would otherwise pass this check without a single path being looked at.
    if [[ -n "$skill_dir" && -d "$skill_dir" ]]; then
        dangling=""
        while IFS= read -r token; do
            token="${token#\`}"
            token="${token%\`}"
            token="${token#](}"
            token="${token%)}"
            # `[x](<references/y.md>)` is a valid link. Only a wholly wrapped
            # target is unwrapped, so the `references/<topic>.md` placeholder
            # keeps its angle brackets and stays filtered out below.
            if [[ "$token" == "<"*">" ]]; then
                token="${token#<}"
                token="${token%>}"
            fi
            token="${token%[.,;:)]}"
            rel="${token#\$\{CLAUDE_SKILL_DIR\}/}"
            # A link may point into a file: references/x.md#section is x.md.
            rel="${rel%%#*}"
            case "$rel" in
                scripts/*|references/*|assets/*|evals/*) ;;
                *) continue ;;
            esac
            # A bare directory name is prose about a kind of place ("keep
            # fixtures under `assets/`", a project's own `assets/`), not a file
            # the agent is told to open; dxp-frontend-license was flagged for a
            # project directory this way.
            case "$rel" in scripts/|references/|assets/|evals/) continue ;; esac
            case "$rel" in *'*'*|*'<'*|*'>'*|*'{'*|*'}'*|*'$'*|*' '*|*'?'*) continue ;; esac
            [[ -e "$skill_dir/$rel" ]] && continue
            case " $dangling " in *" $rel "*) continue ;; esac
            dangling="$dangling $rel"
        done < <(
            grep -oE "\`[^\`]+\`" <<<"$skill_body" || true
            grep -oE '\]\([^) ]+\)' <<<"$skill_body" || true
        )
        if [[ -n "$dangling" ]]; then
            warning "${skill_dir_rel}: SKILL.md names path(s) that do not exist under the skill directory:${dangling} - fix the path or ship the file"
        fi
    fi

    # checkpoints.yaml presence (warning only — many skills legitimately lack
    # one; a documented justification marker suppresses the warning per
    # add-checkpoints' suitability criteria, e.g. purely conceptual skills)
    checkpoints_justified=0
    for f in "$skill_file" "$REPO_DIR/README.md"; do
        if [[ -f "$f" ]] && grep -qiE "^[[:space:]]*([*-][[:space:]]+)?checkpoints:[[:space:]]*none[[:space:]]*\(justified" "$f"; then
            checkpoints_justified=1
            break
        fi
    done
    if [[ -f "$skill_dir/checkpoints.yaml" ]]; then
        success "checkpoints.yaml exists"
    elif [[ $checkpoints_justified -eq 1 ]]; then
        success "checkpoints.yaml absence is justified"
    else
        warning "checkpoints.yaml not found in ${skill_dir_rel} — add checkpoints (see add-checkpoints skill) or document opt-out with 'Checkpoints: none (justified — <reason>)' in SKILL.md or README.md"
    fi

    # --- Shipped scripts without a test ---
    # A skill's scripts are its executable surface, and until this check existed
    # nothing noticed when they had no test: across the fleet, 27 of 33 repos
    # that ship scripts had no test file at all. Referenced-by-name is a coarse
    # signal on purpose — it costs nothing and catches the "no test whatsoever"
    # case, which is the one that actually occurs.
    if [[ -d "$skill_dir/scripts" ]]; then
        untested=$(
            shopt -s nullglob
            for s in "$skill_dir"/scripts/*; do
                [[ -f "$s" ]] || continue
                base="$(basename "$s")"
                if [[ -d "$REPO_DIR/tests" ]] && grep -rqF -- "$base" "$REPO_DIR/tests" 2>/dev/null; then
                    continue
                fi
                printf '%s ' "$base"
            done
        )
        untested="${untested% }"
        if [[ -z "$untested" ]]; then
            success "every script under ${skill_dir_rel}/scripts is referenced by a test"
        else
            warning "no test references these script(s): ${untested} — add a test under tests/ (run by the tests.yml reusable) or the script ships unexercised"
        fi
    fi

    # --- LLM checkpoints that are mechanically verifiable ---
    # add-checkpoints reserves llm_reviews for "subjective requirements that
    # can't be mechanically verified". A prompt that opens a line with a
    # runnable command is describing a mechanical check in prose — GW-21 in
    # git-workflow shipped a whole shell pipeline inside an llm_review, so the
    # rule was never executable and never regressed visibly. Prose that merely
    # mentions a command inline ("Use `git log …` to analyze") does not match:
    # the command must start the line.
    #
    # An entry that legitimately keeps both halves — a mechanical checkpoint for
    # the decidable part, an LLM prompt for the judgement — declares it with a
    # `# mechanical-counterpart: <ID>` comment anywhere in its block, and is
    # then exempt.
    if [[ -f "$skill_dir/checkpoints.yaml" ]]; then
        misclassified=$(awk '
            /^llm_reviews:/ { in_llm = 1; next }
            /^[a-z_]+:/     { in_llm = 0 }
            !in_llm         { next }
            # A marker above the entry (2-space comment) belongs to the entry
            # that follows; one inside the block belongs to the current entry.
            /^  #.*mechanical-counterpart:/     { pending = 1; next }
            /^ {3,}#.*mechanical-counterpart:/  { if (id != "") exempt[id] = 1; next }
            /^  - id:/ { id = $3; if (pending) { exempt[id] = 1; pending = 0 } ; next }
            /^[[:space:]]+(git|gh|grep|sed|awk|test|jq|yq|find|ls|python3?|composer|npm|curl)[[:space:]]/ {
                if (id != "") hit[id] = 1
            }
            END { n = 0; for (i in hit) if (!(i in exempt)) ids[n++] = i
                  for (a = 0; a < n; a++) for (b = a + 1; b < n; b++)
                      if (ids[b] < ids[a]) { t = ids[a]; ids[a] = ids[b]; ids[b] = t }
                  for (a = 0; a < n; a++) printf "%s ", ids[a] }
        ' "$skill_dir/checkpoints.yaml")
        misclassified="${misclassified% }"
        if [[ -n "$misclassified" ]]; then
            warning "${skill_dir_rel}/checkpoints.yaml: llm_reviews checkpoint(s) contain a runnable command: ${misclassified} — if the command decides the outcome, move it to mechanical (type: command); keep the LLM entry only for the judgement the command cannot make"
        fi
    fi
}

if [[ ${#SKILL_FILES[@]} -gt 0 ]]; then
    for skill_file in "${SKILL_FILES[@]}"; do
        validate_skill_md "$skill_file"
    done
else
    error "SKILL.md not found (checked root and skills/*/)"
fi

# --- Shebang without the committed executable bit ---
# Repo-wide, so it runs once rather than once per skill.
#
# ruff's EXE001 covers the Python case, but it does not fire on every developer
# machine: the same pinned ruff, same command, same mode-0644 file passes
# locally and fails on the runner (issue #235, mechanism unestablished). A local
# "clean" is therefore not evidence, and the first signal is a red CI job on
# someone else's push.
#
# This reads the INDEX rather than the working tree, so it answers the same
# everywhere regardless of what the filesystem reports. Severity follows what CI
# already enforces: an error for *.py, because ruff fails the build on exactly
# these; a warning for *.sh, where nothing fails today and a shebang on a file
# only ever invoked as `bash file` is merely decorative.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    shebang_no_exec() { # shebang_no_exec <pathspec...>
        git -C "$REPO_DIR" ls-files -s -- "$@" 2>/dev/null \
            | awk '$1=="100644"{ sub(/^[0-9]+ [0-9a-f]+ [0-9]+\t/, ""); print }' \
            | while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                case "$(head -c 2 "$REPO_DIR/$f" 2>/dev/null)" in
                    '#!') printf '%s ' "$f" ;;
                esac
            done
    }

    PY_NOT_EXEC="$(shebang_no_exec '*.py')"; PY_NOT_EXEC="${PY_NOT_EXEC% }"
    SH_NOT_EXEC="$(shebang_no_exec '*.sh')"; SH_NOT_EXEC="${SH_NOT_EXEC% }"

    if [[ -n "$PY_NOT_EXEC" ]]; then
        error "committed 100644 but carries a shebang: ${PY_NOT_EXEC} — ruff EXE001 fails the build on this, and a local ruff run does not reproduce it (issue #235). Fix: chmod +x <file> && git update-index --chmod=+x <file>"
    elif [[ -z "$SH_NOT_EXEC" ]]; then
        success "every committed script with a shebang is mode 100755"
    fi
    if [[ -n "$SH_NOT_EXEC" ]]; then
        warning "committed 100644 but carries a shebang: ${SH_NOT_EXEC} — either make it executable (chmod +x && git update-index --chmod=+x) or drop the shebang if it is only ever run as \`bash <file>\`"
    fi
fi

# --- Required files ---
for file in README.md LICENSE-MIT LICENSE-CC-BY-SA-4.0 .gitignore; do
    if [[ -f "$REPO_DIR/$file" ]]; then
        success "$file exists"
    else
        error "$file not found"
    fi
done

# Warn about old single LICENSE file
if [[ -f "$REPO_DIR/LICENSE" ]] && [[ -f "$REPO_DIR/LICENSE-MIT" ]]; then
    warning "Old LICENSE file still exists alongside LICENSE-MIT — remove it"
elif [[ -f "$REPO_DIR/LICENSE" ]] && [[ ! -f "$REPO_DIR/LICENSE-MIT" ]]; then
    warning "Single LICENSE file found — migrate to LICENSE-MIT + LICENSE-CC-BY-SA-4.0"
fi

# Release workflow
if [[ -f "$REPO_DIR/.github/workflows/release.yml" ]]; then
    success "release.yml exists"
else
    error ".github/workflows/release.yml not found"
fi

# No composer.lock
if [[ -f "$REPO_DIR/composer.lock" ]]; then
    error "composer.lock must not exist in skill repos"
else
    success "No composer.lock"
fi

# --- composer.json checks ---
if [[ -f "$REPO_DIR/composer.json" ]]; then
    success "composer.json exists"

    # Type
    if grep -q '"type".*"ai-agent-skill"' "$REPO_DIR/composer.json"; then
        success "composer.json type is ai-agent-skill"
    else
        error "composer.json type must be 'ai-agent-skill'"
    fi

    # License SPDX expression
    COMP_LICENSE=$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(f'{sys.argv[1]}/composer.json', 'r') as f:
    print(json.load(f).get('license', ''))
PYEOF
)
    if [[ "$COMP_LICENSE" == "(MIT AND CC-BY-SA-4.0)" ]]; then
        success "composer.json license is correct SPDX expression"
    else
        warning "composer.json license should be '(MIT AND CC-BY-SA-4.0)', got: $COMP_LICENSE"
    fi

    # Name must match GitHub repo name (netresearch/{repo-name})
    COMP_NAME=$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(f'{sys.argv[1]}/composer.json', 'r') as f:
    print(json.load(f).get('name', ''))
PYEOF
)
    REPO_NAME=""
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        REPO_NAME="${GITHUB_REPOSITORY#*/}"
    elif git -C "$REPO_DIR" remote get-url origin &>/dev/null; then
        REMOTE_URL=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)
        REPO_NAME=$(basename "$REMOTE_URL" .git)
    fi
    if [[ -n "$REPO_NAME" ]]; then
        EXPECTED_NAME="netresearch/$REPO_NAME"
        if [[ "$COMP_NAME" == "$EXPECTED_NAME" ]]; then
            success "composer.json name matches repo: $COMP_NAME"
        else
            error "composer.json name must match repo name: expected '$EXPECTED_NAME', got '$COMP_NAME'"
        fi
    elif [[ "$COMP_NAME" =~ ^netresearch/.*-skill$ ]]; then
        success "composer.json name: $COMP_NAME (repo name check skipped - no git remote)"
    else
        error "composer.json name must match netresearch/{repo-name}: $COMP_NAME"
    fi

    # Plugin dependency
    if grep -q "composer-agent-skill-plugin" "$REPO_DIR/composer.json"; then
        success "composer.json requires skill plugin"
    else
        warning "composer.json should require netresearch/composer-agent-skill-plugin"
    fi

    # ai-agent-skill extra path(s) exist (supports both string and array values)
    SKILL_PATH_ERRORS=$(python3 - "$REPO_DIR" <<'PYEOF' 2>/dev/null || echo "ERROR"
import json, os, sys
repo_dir = sys.argv[1]
data = json.load(open(os.path.join(repo_dir, 'composer.json')))
val = data.get('extra', {}).get('ai-agent-skill', '')
paths = val if isinstance(val, list) else [val] if val else []
if not paths:
    print('MISSING')
else:
    for p in paths:
        if not os.path.isfile(os.path.join(repo_dir, p)):
            print('NOTFOUND:' + p)
        else:
            print('OK:' + p)
PYEOF
)
    if [[ "$SKILL_PATH_ERRORS" == "MISSING" ]]; then
        error "composer.json missing extra.ai-agent-skill"
    elif [[ "$SKILL_PATH_ERRORS" == "ERROR" ]]; then
        error "composer.json extra.ai-agent-skill could not be parsed"
    else
        while IFS= read -r line; do
            case "$line" in
                OK:*) success "composer.json skill path exists: ${line#OK:}" ;;
                NOTFOUND:*) error "composer.json skill path missing: ${line#NOTFOUND:}" ;;
            esac
        done <<< "$SKILL_PATH_ERRORS"
    fi
else
    error "composer.json not found"
fi

# --- plugin.json checks ---
PLUGIN_FILE="$REPO_DIR/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_FILE" ]]; then
    success "plugin.json exists"

    # Name matches SKILL.md name (only for single-skill repos)
    PLUGIN_NAME=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(sys.argv[1], 'r') as f:
    print(json.load(f).get('name', ''))
PYEOF
)
    SKILL_COUNT=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo "1"
import json, sys
with open(sys.argv[1], 'r') as f:
    print(len(json.load(f).get('skills', [])))
PYEOF
)
    if [[ "$SKILL_COUNT" -le 1 ]]; then
        if [[ -n "$NAME" ]] && [[ "$PLUGIN_NAME" == "$NAME" ]]; then
            success "plugin.json name matches SKILL.md: $PLUGIN_NAME"
        elif [[ -n "$NAME" ]]; then
            error "plugin.json name '$PLUGIN_NAME' does not match SKILL.md name '$NAME'"
        fi
    else
        success "plugin.json is multi-skill ($SKILL_COUNT skills), name check skipped"
    fi

    # Skills is array
    SKILLS_TYPE=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo "unknown"
import json, sys
with open(sys.argv[1], 'r') as f:
    s = json.load(f).get('skills')
print('array' if isinstance(s, list) else type(s).__name__)
PYEOF
)
    if [[ "$SKILLS_TYPE" == "array" ]]; then
        success "plugin.json skills is array"

        # Check each skill path exists as directory
        MISSING_PATHS=$(python3 - "$PLUGIN_FILE" "$REPO_DIR" <<'PYEOF' 2>/dev/null || true
import json, os, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
for path in data.get('skills', []):
    full = os.path.join(sys.argv[2], path)
    if not os.path.isdir(full):
        print(path)
PYEOF
)
        if [[ -z "$MISSING_PATHS" ]]; then
            success "All plugin.json skill paths exist"
        else
            while IFS= read -r p; do
                error "plugin.json skill path missing: $p"
            done <<< "$MISSING_PATHS"
        fi
    else
        error "plugin.json skills must be an array (got: $SKILLS_TYPE)"
    fi

    # Author URL
    AUTHOR_URL=$(python3 - "$PLUGIN_FILE" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
with open(sys.argv[1], 'r') as f:
    print(json.load(f).get('author', {}).get('url', ''))
PYEOF
)
    if [[ -z "$AUTHOR_URL" ]]; then
        error "plugin.json author.url is missing or empty; it must be https://www.netresearch.de"
    else
        AUTHOR_URL_CLEAN="${AUTHOR_URL%/}"
        if [[ "$AUTHOR_URL_CLEAN" == "https://www.netresearch.de" ]]; then
            success "plugin.json author.url is correct"
        else
            error "plugin.json author.url must be https://www.netresearch.de (got: $AUTHOR_URL)"
        fi
    fi
else
    error ".claude-plugin/plugin.json not found"
fi

# --- Portable manifest checks (Agent Plugins 1.0.0) ---
# Root ./plugin.json is the portable manifest every Agent Plugins client reads.
# It is the source of truth for shared metadata; .claude-plugin/plugin.json is
# generated from it by sync-plugin-manifest.sh. Its absence is an error: the
# fleet finished adopting it on 2026-08-07, so a repo without one is a new gap,
# not a repo still waiting its turn.
PORTABLE_FILE="$REPO_DIR/plugin.json"
if [[ -f "$PORTABLE_FILE" ]]; then
    PORTABLE_REPORT=$(python3 - "$PORTABLE_FILE" "$PLUGIN_FILE" "$REPO_DIR" <<'PYEOF' 2>&1 || true
import json
import os
import re
import sys

portable_path, claude_path, repo_dir = sys.argv[1], sys.argv[2], sys.argv[3]

SCHEMA_URL = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
# Closed schema: agent-plugins.org/schemas/1.0.0/plugin.schema.json
ALLOWED = ["$schema", "name", "version", "description", "author",
           "homepage", "repository", "license", "keywords", "extensions"]
SHARED = ["name", "version", "description", "author",
          "homepage", "repository", "license", "keywords"]
NAME_RE = re.compile(r"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")

out = []


def err(msg):
    out.append("ERROR:" + msg)


def ok(msg):
    out.append("OK:" + msg)


try:
    with open(portable_path, encoding="utf-8") as fh:
        data = json.load(fh)
except ValueError as exc:
    err(f"plugin.json is not valid JSON: {exc}")
    data = None
except OSError as exc:
    err(f"plugin.json could not be read: {exc}")
    data = None

if isinstance(data, dict):
    ok("plugin.json (portable Agent Plugins manifest) exists")

    if data.get("$schema") != SCHEMA_URL:
        err(f'plugin.json $schema must be "{SCHEMA_URL}" (got: {data.get("$schema")!r})')
    else:
        ok("plugin.json targets Agent Plugins 1.0.0")

    name = data.get("name")
    if not isinstance(name, str) or not name:
        err("plugin.json is missing the required 'name' field")
    elif len(name) > 64 or not NAME_RE.match(name):
        err(f"plugin.json name is invalid: {name!r} "
            "(1-64 chars, lowercase a-z0-9 . -, must start and end alphanumeric, no -- or ..)")
    else:
        ok(f"plugin.json name valid: {name}")

    unknown = [k for k in data if k not in ALLOWED]
    if unknown:
        err("plugin.json has fields outside the Agent Plugins schema: "
            + ", ".join(sorted(unknown))
            + " (client-specific data belongs in 'extensions' or in .claude-plugin/plugin.json)")
    else:
        ok("plugin.json has no fields outside the Agent Plugins schema")

    for key in ("version", "description", "homepage", "repository", "license"):
        if key in data and not isinstance(data[key], str):
            err(f"plugin.json {key} must be a string")
    if "keywords" in data and (not isinstance(data["keywords"], list)
                               or not all(isinstance(k, str) for k in data["keywords"])):
        err("plugin.json keywords must be an array of strings")
    if "author" in data:
        author = data["author"]
        if not isinstance(author, dict):
            err("plugin.json author must be an object with name/email/url")
        else:
            extra = [k for k in author if k not in ("name", "email", "url")]
            if extra:
                err("plugin.json author allows only name, email, url — got: "
                    + ", ".join(sorted(extra)))
            for k, v in author.items():
                if not isinstance(v, str):
                    err(f"plugin.json author.{k} must be a string")
    if "extensions" in data:
        ext = data["extensions"]
        if not isinstance(ext, dict) or not all(isinstance(v, dict) for v in ext.values()):
            err("plugin.json extensions must be an object of reverse-domain "
                "namespace keys mapping to objects")

    # Parity with the generated Claude Code manifest.
    if os.path.isfile(claude_path):
        try:
            with open(claude_path, encoding="utf-8") as fh:
                claude = json.load(fh)
        except (OSError, ValueError):
            claude = None
        if isinstance(claude, dict):
            drift = [k for k in SHARED if k in data and claude.get(k) != data[k]]
            if drift:
                err(".claude-plugin/plugin.json is out of sync with plugin.json on: "
                    + ", ".join(drift)
                    + " — run skills/skill-repo/scripts/sync-plugin-manifest.sh")
            else:
                ok(".claude-plugin/plugin.json is in sync with plugin.json")

    # Agent Plugins clients discover skills only under skills/<name>/SKILL.md.
    skills_dir = os.path.join(repo_dir, "skills")
    found = []
    if os.path.isdir(skills_dir):
        found = sorted(d for d in os.listdir(skills_dir)
                       if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md")))
    if found:
        ok(f"skills/ holds {len(found)} portable skill(s): " + ", ".join(found))
    else:
        err("no skills/<name>/SKILL.md found — Agent Plugins clients do not "
            "discover a SKILL.md at the repository root")

print("\n".join(out))
PYEOF
)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            OK:*) success "${line#OK:}" ;;
            ERROR:*) error "${line#ERROR:}" ;;
            *) error "portable manifest check produced unexpected output: $line" ;;
        esac
    done <<< "$PORTABLE_REPORT"
else
    error "plugin.json (portable Agent Plugins 1.0.0 manifest) not found at repo root — Agent Plugins clients (Cursor, Copilot, …) cannot load this plugin; see skill-repo skills/skill-repo/references/agent-plugins-compat.md"
fi

# --- README.md quality checks (warnings by default) ---
# Heading misses are warnings unless STRICT_README=1 promotes them to errors.
# The default must stay warnings-only: consumer repos run this script from
# main via the reusable validate.yml, so flipping the default would break
# their CI. Opt in per repo (or org-wide, later) by exporting STRICT_README=1.
readme_heading_miss() { case "${STRICT_README:-0}" in 1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) error "$1" ;; *) warning "$1" ;; esac; }

# Required level-2 headings (whole-line match) per skills/skill-repo/references/readme-template.md
README_REQUIRED_HEADINGS=(
    "What this skill solves"
    "Why this is a skill (model delta)"
    "Use when"
    "Expected outputs"
    "Context requirements"
    "Example prompts"
    "Related skills"
    "Installation"
    "Contributing"
    "License"
)

if [[ -f "$REPO_DIR/README.md" ]]; then
    if grep -q "Netresearch" "$REPO_DIR/README.md"; then
        success "README.md contains Netresearch reference"
    else
        warning "README.md should contain Netresearch credits"
    fi

    for heading in "${README_REQUIRED_HEADINGS[@]}"; do
        # Whole-line match only (avoids substring hits inside ### headings or prose)
        if grep -Fxq "## ${heading}" "$REPO_DIR/README.md"; then
            success "README.md has ## ${heading}"
        else
            readme_heading_miss "README.md missing section (exact line ## ${heading}) — see skill-repo-skill skills/skill-repo/references/readme-template.md"
        fi
    done

    # Every documented slash-command should be enumerated in the README so the
    # command (and mode) list does not silently drift when one is added. Warning
    # only: the name match is heuristic and a skill may intentionally omit one.
    if [[ -d "$REPO_DIR/commands" ]]; then
        for cmd_file in "$REPO_DIR"/commands/*.md; do
            [[ -e "$cmd_file" ]] || continue
            cmd_name="$(basename "$cmd_file" .md)"
            # -F: match the command name literally (a filename with regex
            # metacharacters can't break or mis-match). -w: require word
            # boundaries, so `/work-update` does not match inside
            # `commands/work-update.md` or a URL like `netresearch/work-update`.
            if grep -qFw -- "/${cmd_name}" "$REPO_DIR/README.md"; then
                success "README.md references /${cmd_name}"
            else
                warning "README.md does not mention command /${cmd_name} (commands/${cmd_name}.md) — keep the README command/mode list in sync when adding commands or modes"
            fi
        done
    fi
fi

# --- Summary ---
echo ""
echo "========================================"
echo "Validation Summary"
echo "========================================"
echo -e "Errors:   ${RED}$ERRORS${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}Skill repository is valid!${NC}"
    exit 0
else
    echo -e "${RED}Skill repository has $ERRORS error(s) that must be fixed.${NC}"
    exit 1
fi
