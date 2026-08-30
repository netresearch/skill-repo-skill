#!/usr/bin/env bash
# validate-evals.sh - Structural validation of evals.json files
# Supports three formats:
#   Unified (recommended): {"skill_name": "...", "evals": [{id, eval_name, prompt,
#       expected_output?, expectations?: ["..."], assertions?: [{type, pattern}]}]}
#     - Evals may use expectations (string[], LLM-as-judge), assertions (object[],
#       regex matching), or both. At least one grading mechanism is required.
#   Legacy A: {"skill_name": "...", "evals": [{id, eval_name, prompt, assertions: [...]}]}
#   Legacy B: [{name, prompt, assertions: [{type, value/pattern, description?}]}]
#
# Any eval may carry an optional self-check:
#   "samples": {"passing": "<answer every assertion must match>",
#               "failing": ["<answer at least one assertion must reject>"]}
# Patterns are checked with `grep -E` and matched with `grep -qiE`, the same
# binary and flags run-ab-evals.sh grades with, so the check cannot certify an
# eval the grader would fail. Every assertion carrying value/pattern counts,
# whatever its type, because the grader greps every one of them; `must_not` is
# checked inverted here and graded inverted there.
#
# Usage: bash validate-evals.sh [path-to-evals.json] [--require-evals]
#   If no path given, searches skills/*/evals/evals.json then evals/evals.json
#
#   --require-evals: only takes effect when no evals.json is found. Instead of
#     the plain "no evals.json found" error, checks whether any SKILL.md in
#     the repo exceeds the breadth threshold (body >300 words or >3 files in
#     references/). Small pointer-skills stay exempt. Broad skills without an
#     evals.json fail with a ::error:: annotation naming the skill.

set -euo pipefail

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
warn() { WARN=$((WARN + 1)); echo "  WARN: $1"; }

# --- Breadth check (--require-evals mode) ---
# Only called when no evals.json was found anywhere in the repo. Determines
# whether any skill is broad enough (body >300 words or >3 reference files)
# that it should have had one. Small pointer-skills are exempt. Exits 1 with
# a ::error:: annotation per offending skill; otherwise returns 0.
check_required_evals() {
  local skill_md skill_dir skill_name body_words ref_count
  local -a skill_files=() broad_skills=() ref_files=()

  [[ -f "SKILL.md" ]] && skill_files+=("SKILL.md")
  for skill_md in skills/*/SKILL.md; do
    [[ -f "$skill_md" ]] && skill_files+=("$skill_md")
  done

  if [[ ${#skill_files[@]} -eq 0 ]]; then
    echo "WARN: --require-evals set but no SKILL.md found, skipping breadth check"
    return 0
  fi

  for skill_md in "${skill_files[@]}"; do
    skill_dir=$(dirname "$skill_md")
    skill_name=$(basename "$skill_dir")
    [[ "$skill_dir" == "." ]] && skill_name=$(basename "$(pwd)")

    # Body word count: SKILL.md content after the frontmatter closing '---'.
    body_words=$(awk '
      BEGIN { has_fm = 0; fm_closed = 0; total_words = 0; body_words = 0 }
      NR == 1 { if (/^---$/) { has_fm = 1; next } }
      /^---$/ && has_fm && !fm_closed { fm_closed = 1; next }
      {
        total_words += NF
        if (fm_closed) { body_words += NF }
      }
      END { print (has_fm && fm_closed ? body_words : total_words) }
    ' "$skill_md")

    ref_count=0
    if [[ -d "$skill_dir/references" ]]; then
      ref_files=("$skill_dir/references"/*.md)
      if [[ -e "${ref_files[0]}" ]]; then
        ref_count=${#ref_files[@]}
      fi
    fi

    if [[ "$body_words" -gt 300 ]] || [[ "$ref_count" -gt 3 ]]; then
      broad_skills+=("$skill_name (body: ${body_words} words, references: ${ref_count} files)")
    fi
  done

  if [[ ${#broad_skills[@]} -eq 0 ]]; then
    echo "PASS: no skill exceeds the breadth threshold (body >300 words or >3 reference files); evals.json not required"
    return 0
  fi

  local entry
  for entry in "${broad_skills[@]}"; do
    echo "::error::require_evals: $entry exceeds the breadth threshold but has no evals.json — add skills/<name>/evals/evals.json (or evals/evals.json) with structural evals, or keep require_evals: false for this repo"
  done
  echo ""
  echo "Results: 0 passed, ${#broad_skills[@]} failed, 0 warnings"
  exit 1
}

# --- Locate evals.json ---
REQUIRE_EVALS=0
EVALS_FILE=""
for arg in "$@"; do
  case "$arg" in
    --require-evals) REQUIRE_EVALS=1 ;;
    *) EVALS_FILE="$arg" ;;
  esac
done

if [[ -z "$EVALS_FILE" ]]; then
  # Every candidate, not the first: a repo shipping several skills ships several
  # evals.json, and stopping at the first left the rest unchecked — six repos in
  # the fleet carry more than one, matrix-skill three. Same hole the skill
  # validator had (issue #214).
  EVALS_FILES=()
  for candidate in skills/*/evals/evals.json evals/evals.json; do
    [[ -f "$candidate" ]] && EVALS_FILES+=("$candidate")
  done

  if [[ ${#EVALS_FILES[@]} -gt 1 ]]; then
    # One run per file so each gets its own counters and summary, with the exit
    # code covering all of them.
    MULTI_RC=0
    for candidate in "${EVALS_FILES[@]}"; do
      echo "=============================================="
      bash "$0" "$candidate" || MULTI_RC=1
      echo ""
    done
    if [[ "$MULTI_RC" -ne 0 ]]; then
      echo "::error::at least one evals.json failed validation"
    else
      echo "All ${#EVALS_FILES[@]} evals.json files validate"
    fi
    exit "$MULTI_RC"
  fi

  EVALS_FILE="${EVALS_FILES[0]:-}"
fi

if [[ -z "$EVALS_FILE" ]] || [[ ! -f "$EVALS_FILE" ]]; then
  if [[ "$REQUIRE_EVALS" -eq 1 ]]; then
    check_required_evals
    exit 0
  fi
  echo "ERROR: No evals.json found"
  echo "Searched: skills/*/evals/evals.json, evals/evals.json"
  exit 1
fi

echo "Validating: $EVALS_FILE"
echo "---"

# --- Valid JSON ---
if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$EVALS_FILE" 2>/dev/null; then
  fail "Invalid JSON"
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
  exit 1
fi
pass "Valid JSON"

# --- Run all structural checks via Python ---
RESULT=$(python3 - "$EVALS_FILE" <<'PYEOF'
import json
import subprocess
import sys

# Assertions are graded by run-ab-evals.sh with `grep -qiE` after stripping a
# leading (?i) — case-insensitive POSIX ERE, not Python's re. Validating them
# with a different engine measures a different thing: `[^\n]` means one thing
# in Python and another in ERE, and case-sensitive matching rejects patterns
# the grader accepts. So the checks below call the same binary with the same
# flags rather than approximating it.
def _grep(args, text):
    try:
        return subprocess.run(
            ["grep", *args], input=text, text=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode
    except (OSError, subprocess.SubprocessError):
        return None


def _ere(pattern):
    return pattern[4:] if pattern.startswith("(?i)") else pattern


def pattern_compiles(pattern):
    # grep exits 2 on a pattern it cannot parse and 1 on "no match".
    rc = _grep(["-qE", "--", _ere(pattern)], "")
    return rc is None or rc != 2


def grader_matches(pattern, text):
    return _grep(["-qiE", "--", _ere(pattern)], text) == 0


with open(sys.argv[1]) as f:
    raw = json.load(f)

# Detect format and normalize to list of evals
if isinstance(raw, dict) and "evals" in raw:
    # Format A: {skill_name, evals: [...]}
    evals = raw["evals"]
    fmt = "A"
elif isinstance(raw, list):
    # Format B: [...]
    evals = raw
    fmt = "B"
else:
    print("FAIL|Top-level structure must be an array or object with 'evals' key")
    sys.exit(0)

print(f"INFO|Detected format {'A (object with evals key)' if fmt == 'A' else 'B (top-level array)'}")
print(f"INFO|Total evals: {len(evals)}")

if not isinstance(evals, list):
    print("FAIL|'evals' must be an array")
    sys.exit(0)

if len(evals) == 0:
    print("FAIL|No evals found")
    sys.exit(0)

# Check eval count thresholds
if len(evals) < 10:
    print(f"FAIL|Eval count {len(evals)} < 10 minimum")
elif len(evals) < 15:
    print(f"WARN|Eval count {len(evals)} < 15 recommended")
else:
    print(f"PASS|Eval count {len(evals)} >= 15")

# Track names for duplicate check
names = []
ids_found = []
has_ids = False

for i, ev in enumerate(evals):
    label = f"eval[{i}]"

    if not isinstance(ev, dict):
        print(f"FAIL|{label}: not an object")
        continue

    # Name/ID check: accept 'name', 'eval_name', or 'id' (integer) as identifier
    name = str(ev.get("name") or ev.get("eval_name") or "").strip()
    if not name:
        # Fall back to id as identifier for Anthropic format
        eid = ev.get("id")
        if isinstance(eid, int):
            name = f"id={eid}"
        else:
            print(f"FAIL|{label}: missing or empty name/eval_name/id")
    if name:
        names.append(name)

    # Prompt check (accept 'prompt' or legacy 'input')
    prompt = ev.get("prompt") or ev.get("input") or ""
    if not prompt or not str(prompt).strip():
        print(f"FAIL|{label} ({name}): missing or empty prompt/input")
    else:
        print(f"PASS|{label} ({name}): has prompt")

    # ID check (optional but validated if present; must be integer)
    if "id" in ev:
        if not isinstance(ev["id"], int):
            print(f"FAIL|{label} ({name}): id must be an integer")
        else:
            has_ids = True
            ids_found.append(ev["id"])

    # expected_output check (recommended for unified format, skip for legacy)
    is_unified = any(key in ev for key in ("eval_name", "id", "expectations", "expected_output"))
    if is_unified and "expected_output" not in ev:
        print(f"WARN|{label} ({name}): missing expected_output (recommended)")

    # Grading check: must have expectations OR assertions (or both)
    expectations = ev.get("expectations")
    assertions = ev.get("assertions")
    has_expectations = False
    has_assertions = False

    # Validate expectations (string[], 2+ items)
    if expectations is not None:
        if not isinstance(expectations, list):
            print(f"FAIL|{label} ({name}): expectations must be an array")
        elif len(expectations) < 2:
            print(f"FAIL|{label} ({name}): has {len(expectations)} expectations, need >= 2")
        else:
            invalid_exp = 0
            for j, e in enumerate(expectations):
                if not isinstance(e, str):
                    invalid_exp += 1
                    print(f"FAIL|{label} ({name}): expectations[{j}] must be a string")
                elif not e.strip():
                    invalid_exp += 1
                    print(f"FAIL|{label} ({name}): expectations[{j}] is empty")
            if invalid_exp == 0:
                has_expectations = True
                print(f"PASS|{label} ({name}): {len(expectations)} valid expectations")

    # Validate assertions (object[] or string[], 2+ items)
    if assertions is not None:
        if not isinstance(assertions, list):
            print(f"FAIL|{label} ({name}): assertions must be an array")
        elif len(assertions) < 2:
            print(f"FAIL|{label} ({name}): has {len(assertions)} assertions, need >= 2")
        else:
            invalid_assertions = 0
            for j, a in enumerate(assertions):
                if isinstance(a, str):
                    if not a.strip():
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): assertion[{j}] is empty")
                elif isinstance(a, dict):
                    if "type" not in a:
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): assertion[{j}] missing 'type'")
                    val = a.get("value") or a.get("pattern") or ""
                    if not str(val).strip():
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): assertion[{j}] missing 'value' or 'pattern'")
                else:
                    invalid_assertions += 1
                    print(f"FAIL|{label} ({name}): assertion[{j}] invalid type (not string or object)")

            # A pattern only had to be a non-empty string until now, so an
            # unbalanced group passed validation and first misbehaved wherever
            # the eval was actually graded. Which assertions count is decided by
            # the grader, not by a type name: run-ab-evals.sh greps
            # `value or pattern` from EVERY assertion, so a broken pattern under
            # type "tool_use", "content_regex" or any other label is graded and
            # must be validated the same way. The type decides only the
            # DIRECTION of the verdict -- `must_not` passes when the pattern is
            # absent -- not whether the assertion is graded at all.
            patterns = []
            for j, a in enumerate(assertions):
                if not isinstance(a, dict):
                    continue
                pat = str(a.get("pattern") or a.get("value") or "")
                if not pat.strip():
                    continue
                if not pattern_compiles(pat):
                    # A *_contains assertion states a literal, and the value is
                    # usually not meant as a regex at all — `((` in a Concourse
                    # eval, `public function __construct(` in a PHP one. The
                    # grader still greps it as an ERE, so it never matches, but
                    # the defect is the grader's literal handling rather than
                    # the eval's, and failing here would turn CI red in repos
                    # this change does not fix. It warns instead.
                    literal = "contains" in str(a.get("type") or "")
                    if literal:
                        print(
                            f"WARN|{label} ({name}): assertion[{j}] is not a valid POSIX ERE. "
                            "run-ab-evals.sh greps every assertion with -qiE, including this "
                            "one, so it can never match — escape the value or make it a regex"
                        )
                    else:
                        invalid_assertions += 1
                        print(
                            f"FAIL|{label} ({name}): assertion[{j}] is not a valid POSIX ERE "
                            "— grep rejects it, so the grader scores it as never matching"
                        )
                    continue
                patterns.append((j, pat, a.get("type") == "must_not"))

            # Optional self-check. Without it nothing distinguishes an assertion
            # that discriminates from one that is inverted or vacuous: both look
            # like a non-empty string. With it, the eval carries one answer that
            # must satisfy every assertion and answers that must not.
            samples = ev.get("samples")
            if samples is not None and not isinstance(samples, dict):
                invalid_assertions += 1
                print(f"FAIL|{label} ({name}): samples must be an object, got {type(samples).__name__}")
            elif isinstance(samples, dict):
                unknown = sorted(set(samples) - {"passing", "failing"})
                if unknown:
                    invalid_assertions += 1
                    print(
                        f"FAIL|{label} ({name}): samples has unknown key(s) {', '.join(unknown)} "
                        "— only 'passing' and 'failing' are read, so a typo would check nothing"
                    )
                if not patterns:
                    invalid_assertions += 1
                    print(
                        f"FAIL|{label} ({name}): samples present but no assertion carries a "
                        "pattern — the self-check would verify nothing"
                    )
                passing = samples.get("passing")
                if passing is not None and (not isinstance(passing, str) or not passing.strip()):
                    invalid_assertions += 1
                    print(f"FAIL|{label} ({name}): samples.passing must be a non-empty string")
                elif isinstance(passing, str) and passing.strip():
                    for j, pat, negated in patterns:
                        hit = grader_matches(pat, passing)
                        if hit == negated:
                            problem = (
                                "matches its own passing sample although it is a must_not "
                                "assertion" if negated else
                                "does not match its own passing sample — the eval would "
                                "reject a correct answer"
                            )
                            invalid_assertions += 1
                            print(f"FAIL|{label} ({name}): assertion[{j}] {problem}")
                failing = samples.get("failing")
                if isinstance(failing, str):
                    failing = [failing]
                if failing is not None and not isinstance(failing, list):
                    invalid_assertions += 1
                    print(f"FAIL|{label} ({name}): samples.failing must be a string or an array")
                    failing = []
                for k, bad in enumerate(failing or []):
                    if not isinstance(bad, str) or not bad.strip():
                        invalid_assertions += 1
                        print(f"FAIL|{label} ({name}): samples.failing[{k}] must be a non-empty string")
                        continue
                    if patterns and all(
                        grader_matches(pat, bad) != negated for _, pat, negated in patterns
                    ):
                        invalid_assertions += 1
                        print(
                            f"FAIL|{label} ({name}): failing sample[{k}] satisfies every "
                            "assertion — the eval would accept an answer it calls wrong"
                        )

            if invalid_assertions == 0:
                has_assertions = True
                print(f"PASS|{label} ({name}): {len(assertions)} valid assertions")

    # Must have at least one grading mechanism
    if not has_expectations and not has_assertions:
        if expectations is None and assertions is None:
            print(f"FAIL|{label} ({name}): missing grading (need expectations or assertions)")
        # else: already reported specific validation errors above

# Duplicate names
seen = set()
dupes = set()
for n in names:
    if n in seen:
        dupes.add(n)
    seen.add(n)

if dupes:
    print(f"FAIL|Duplicate eval names: {', '.join(sorted(dupes))}")
else:
    print(f"PASS|No duplicate eval names")

# ID validation (if IDs are present)
if has_ids:
    # Check for duplicates
    id_counts = {}
    for eid in ids_found:
        id_counts[eid] = id_counts.get(eid, 0) + 1
    dupe_ids = [k for k, v in id_counts.items() if v > 1]
    if dupe_ids:
        print(f"FAIL|Duplicate IDs: {dupe_ids}")
    else:
        print(f"PASS|No duplicate IDs")

    # Check sequential (1-based)
    numeric_ids = sorted([x for x in ids_found if isinstance(x, int)])
    if numeric_ids:
        expected = list(range(1, len(numeric_ids) + 1))
        if numeric_ids != expected:
            gaps = set(expected) - set(numeric_ids)
            extra = set(numeric_ids) - set(expected)
            msg = ""
            if gaps:
                msg += f"missing: {sorted(gaps)}"
            if extra:
                if msg:
                    msg += ", "
                msg += f"unexpected: {sorted(extra)}"
            print(f"FAIL|IDs not sequential: {msg}")
        else:
            print(f"PASS|IDs sequential (1-{len(numeric_ids)})")
PYEOF
)

# --- Parse Python output ---
while IFS='|' read -r level msg; do
  case "$level" in
    PASS) pass "$msg" ;;
    FAIL) fail "$msg" ;;
    WARN) warn "$msg" ;;
    INFO) echo "  INFO: $msg" ;;
  esac
done <<< "$RESULT"

# --- Trigger evals -----------------------------------------------------------
# evals.json cannot detect a description that never routes: run-ab-evals.sh
# pastes the whole SKILL.md into the system prompt, so the skill is force-fed
# and routing never happens. A skill whose description omits the words its users
# say passes every eval and is reached by nobody -- measured at 1 of 25 trials
# for one fleet skill whose 30 evals were green throughout. See
# references/materialization-contract.md, Rule 7.
#
# A warning, not an error: nothing in this repository runs these queries yet,
# and failing a build for a missing file whose runner does not exist would be a
# gate nobody can pass.
TRIGGER_FILE="$(dirname "$EVALS_FILE")/eval_queries.json"
if [[ -f "$TRIGGER_FILE" ]]; then
  # One reader, one verdict. Counting positives in a second call meant a
  # malformed entry raised there and `|| echo 0` turned the failure into
  # "0 positives", so the validator printed PASS for a file it could not read.
  TRIGGER_READ=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    print('ERR|not valid JSON: %s' % exc); raise SystemExit
q = d.get('queries') if isinstance(d, dict) else d
if not isinstance(q, list):
    print('ERR|no list of queries (expected a top-level list, or a queries key)')
    raise SystemExit
bad = [i for i, x in enumerate(q) if not isinstance(x, dict) or 'query' not in x
       or not isinstance(x.get('should_trigger'), bool)]
if bad:
    print('ERR|entr(y|ies) %s lack a query string or a boolean should_trigger'
          % ', '.join(str(i) for i in bad[:5]))
    raise SystemExit
print('OK|%d|%d' % (len(q), sum(1 for x in q if x['should_trigger'])))
" "$TRIGGER_FILE" 2>&1)

  case "$TRIGGER_READ" in
    OK\|*)
      n_q=$(echo "$TRIGGER_READ" | cut -d'|' -f2)
      n_pos=$(echo "$TRIGGER_READ" | cut -d'|' -f3)
      if [[ "$n_q" -eq 0 ]]; then
        warn "$(basename "$TRIGGER_FILE") carries no queries - an empty file is not a trigger test"
      else
        pass "$(basename "$TRIGGER_FILE"): $n_q trigger quer(y|ies), $n_pos labelled should_trigger"
        if [[ "$n_pos" -eq "$n_q" ]]; then
          warn "every trigger query is a positive - without negatives the file cannot catch a description that fires on everything"
        fi
      fi
      ;;
    *)
      fail "$(basename "$TRIGGER_FILE"): ${TRIGGER_READ#ERR|}"
      ;;
  esac
else
  warn "no eval_queries.json beside this file - evals.json measures what the skill does once loaded, never whether a real request reaches it (materialization-contract.md, Rule 7)"
fi

# --- Summary ---
echo ""
echo "---"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

exit 0
