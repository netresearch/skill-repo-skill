#!/usr/bin/env bash
# tests/roll-changelog.sh — exercises skills/skill-repo/scripts/roll-changelog.py.
#
# The five released-heading shapes documented in release-discipline.md each get
# a round-trip, and every refusal guard is observed to actually fail on a
# violating fixture — a guard that has never been seen red proves only that it
# runs, not that it guards.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/skills/skill-repo/scripts/roll-changelog.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

roll() { # roll <file> <version> [args...] — captured exit code
    python3 "$SCRIPT" "$@" > "$WORK/out.txt" 2> "$WORK/err.txt"
    echo "$?"
}

echo "roll-changelog.py"

# --- 1. bracketed dash (keep-a-changelog) -----------------------------------
f="$WORK/dash.md"
cat > "$f" <<'EOF'
# Changelog

## [Unreleased]

### Added

- new fleet driver

## [1.2.3] - 2026-08-01

### Fixed

- old fix
EOF
check "bracketed dash: exits 0" 0 "$(roll "$f" 1.3.0 --date 2026-08-13)"
check "bracketed dash: new heading reproduced" yes \
    "$(grep -qx '## \[1.3.0\] - 2026-08-13' "$f" && echo yes || echo no)"
check "bracketed dash: fresh empty Unreleased kept" yes \
    "$(grep -qx '## \[Unreleased\]' "$f" && echo yes || echo no)"
check "bracketed dash: moved content intact" yes \
    "$(grep -q -- '- new fleet driver' "$f" && echo yes || echo no)"
check "bracketed dash: old release untouched" yes \
    "$(grep -qx '## \[1.2.3\] - 2026-08-01' "$f" && echo yes || echo no)"
# MD022: the new heading must have blank lines on both sides
check "bracketed dash: blank line after new heading" blank \
    "$(awk 'found { print ($0 == "" ? "blank" : "nonblank"); exit }
            /^## \[1\.3\.0\] - 2026-08-13$/ { found = 1 }' "$f")"
check "bracketed dash: blank line before new heading" blank \
    "$(awk '/^## \[1\.3\.0\] - 2026-08-13$/ { print (prev == "" ? "blank" : "nonblank"); exit }
            { prev = $0 }' "$f")"

# --- 2. bare paren -----------------------------------------------------------
f="$WORK/paren.md"
cat > "$f" <<'EOF'
# Changelog

## Unreleased

- something

## 1.11.2 (2026-07-30)

- earlier
EOF
check "bare paren: exits 0" 0 "$(roll "$f" 1.12.0 --date 2026-08-13)"
check "bare paren: shape reproduced" yes \
    "$(grep -qx '## 1.12.0 (2026-08-13)' "$f" && echo yes || echo no)"
check "bare paren: unbracketed Unreleased preserved" yes \
    "$(grep -qx '## Unreleased' "$f" && echo yes || echo no)"

# --- 3. bracketed em dash ----------------------------------------------------
f="$WORK/emdash.md"
cat > "$f" <<'EOF'
## [Unreleased]

- change

## [0.3.23] — 2026-07-02

- old
EOF
check "em dash: exits 0" 0 "$(roll "$f" 0.3.24 --date 2026-08-13)"
check "em dash: dash character reproduced" yes \
    "$(grep -qx '## \[0.3.24\] — 2026-08-13' "$f" && echo yes || echo no)"

# --- 4. linked, with v prefix: tag rewritten inside the URL ------------------
f="$WORK/linked.md"
cat > "$f" <<'EOF'
## [Unreleased]

- change

## [v2.6.0](https://github.com/x/y/releases/tag/v2.6.0) — 2026-02-28

- old
EOF
check "linked: exits 0" 0 "$(roll "$f" 2.7.0 --date 2026-08-13)"
check "linked: v prefix + URL tag rewritten" yes \
    "$(grep -qx '## \[v2.7.0\](https://github.com/x/y/releases/tag/v2.7.0) — 2026-08-13' "$f" && echo yes || echo no)"

# --- 5. first release: no released heading yet -------------------------------
f="$WORK/first.md"
cat > "$f" <<'EOF'
# Changelog

## [Unreleased]

- everything so far
EOF
check "first release: exits 0" 0 "$(roll "$f" 0.1.0 --date 2026-08-13)"
check "first release: keep-a-changelog default shape" yes \
    "$(grep -qx '## \[0.1.0\] - 2026-08-13' "$f" && echo yes || echo no)"

# --- 6. fence-blindness ------------------------------------------------------
f="$WORK/fence.md"
cat > "$f" <<'EOF'
## [Unreleased]

- documents the roll:

```markdown
## [Unreleased]

## [9.9.9] - 2099-01-01
```

## [1.0.0] - 2026-01-01

- old
EOF
check "fenced lookalikes: exits 0 (only the real Unreleased counts)" 0 \
    "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fenced example untouched" yes \
    "$(grep -qx '## \[9.9.9\] - 2099-01-01' "$f" && echo yes || echo no)"
check "shape came from the real heading, not the fenced one" yes \
    "$(grep -qx '## \[1.1.0\] - 2026-08-13' "$f" && echo yes || echo no)"

# --- guards: each one observed to fail --------------------------------------
f="$WORK/empty.md"
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
check "empty Unreleased refused" 1 "$(roll "$f" 1.1.0)"
check "empty Unreleased: file unchanged" yes \
    "$(grep -qx '## \[1.1.0\].*' "$f" && echo no || echo yes)"

f="$WORK/none.md"
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n' > "$f"
check "missing Unreleased refused" 1 "$(roll "$f" 1.1.0)"

f="$WORK/twice.md"
printf '## [Unreleased]\n\n- a\n\n## Unreleased\n\n- b\n' > "$f"
check "duplicate Unreleased refused" 1 "$(roll "$f" 1.1.0)"

f="$WORK/badver.md"
printf '## [Unreleased]\n\n- a\n' > "$f"
check "non-semver version refused" 1 "$(roll "$f" not-a-version)"
check "bad date refused" 1 "$(roll "$f" 1.0.0 --date yesterday)"

f="$WORK/inverted.md"
printf '## [1.0.0] - 2026-01-01\n\n- old\n\n## [Unreleased]\n\n- new\n' > "$f"
check "released heading before Unreleased refused" 1 "$(roll "$f" 1.1.0)"

# --- second roll on the same file: Unreleased is empty now -> refused --------
f="$WORK/dash.md"   # rolled successfully in test 1
check "re-roll after a roll is refused (empty Unreleased)" 1 "$(roll "$f" 1.4.0)"

# --- guard: unrecognized released-heading shape refused ----------------------
f="$WORK/weird.md"
printf '## [Unreleased]\n\n- a\n\n## Notes and thanks\n\n- b\n' > "$f"
check "unrecognized released-heading shape refused" 1 "$(roll "$f" 1.1.0)"

# --- guard: linked heading whose URL lacks its own tag refused ---------------
f="$WORK/badlink.md"
printf '## [Unreleased]\n\n- a\n\n## [v1.0.0](https://example.invalid/static) - 2026-01-01\n\n- b\n' > "$f"
check "linked heading URL without its tag refused (no guessed rewrite)" 1 "$(roll "$f" 1.1.0)"

# --- comment-only Unreleased is empty, not content ---------------------------
f="$WORK/comment.md"
printf '## [Unreleased]\n\n<!-- add entries here -->\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
check "comment-only Unreleased refused (would ship a visually empty release)" 1 \
    "$(roll "$f" 1.1.0)"

# --- tilde fences hide lookalikes too ----------------------------------------
f="$WORK/tilde.md"
printf '## [Unreleased]\n\n- a\n\n~~~\n## [9.9.9] - 2099-01-01\n~~~\n\n## [1.0.0] - 2026-01-01\n\n- b\n' > "$f"
check "~~~ fenced lookalike ignored" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "~~~ fenced example untouched" yes \
    "$(grep -qx '## \[9.9.9\] - 2099-01-01' "$f" && echo yes || echo no)"

# --- CRLF files keep their line endings --------------------------------------
f="$WORK/crlf.md"
printf '## [Unreleased]\r\n\r\n- change\r\n\r\n## [1.0.0] - 2026-01-01\r\n\r\n- old\r\n' > "$f"
check "CRLF file rolls cleanly" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "CRLF line endings preserved (no wholesale LF rewrite)" 0 \
    "$(grep -c $'[^\r]$' "$f")"

# --- keep-a-changelog link-reference definitions are rolled too --------------
f="$WORK/refs.md"
cat > "$f" <<'EOF'
## [Unreleased]

- change

## [1.2.0] - 2026-01-01

- old

[Unreleased]: https://github.com/x/y/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/x/y/compare/v1.1.0...v1.2.0
EOF
check "ref-style defs: exits 0" 0 "$(roll "$f" 1.3.0 --date 2026-08-13)"
check "ref-style defs: [Unreleased] range restarts at the new tag" yes \
    "$(grep -qx '\[Unreleased\]: https://github.com/x/y/compare/v1.3.0...HEAD' "$f" && echo yes || echo no)"
check "ref-style defs: the new release got its own definition" yes \
    "$(grep -qx '\[1.3.0\]: https://github.com/x/y/compare/v1.2.0...v1.3.0' "$f" && echo yes || echo no)"
f="$WORK/refs-odd.md"
printf '## [Unreleased]\n\n- a\n\n## [1.0.0] - 2026-01-01\n\n- b\n\n[Unreleased]: https://example.invalid/branches\n' > "$f"
check "ref-style defs in an unknown shape: roll succeeds with a warning" 0 \
    "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "…and the warning names the manual follow-up" yes \
    "$(grep -q 'WARNING: link-reference definitions' "$WORK/out.txt" && echo yes || echo no)"

# --- dry run writes nothing --------------------------------------------------
f="$WORK/dry.md"
printf '## [Unreleased]\n\n- pending\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
before=$(cat "$f")
check "dry run exits 0" 0 "$(roll "$f" 1.1.0 --dry-run)"
check "dry run leaves the file untouched" "$before" "$(cat "$f")"

# --- --check-unreleased ------------------------------------------------------
f="$WORK/chk.md"
printf '# C\n\n## [Unreleased]\n\n- pending\n\n## [1.0.0] - 2026-01-01\n\n- b\n' > "$f"
check "check-unreleased: content exits 0" 0 "$(roll "$f" --check-unreleased)"
check "check-unreleased: content reported" has-content "$(cat "$WORK/out.txt")"
check "check-unreleased: file untouched" yes \
    "$(grep -q '^- pending$' "$f" && echo yes)"

printf '# C\n\n## [Unreleased]\n\n<!-- only a comment -->\n\n## [1.0.0] - 2026-01-01\n\n- b\n' > "$f"
check "check-unreleased: comment-only is empty (same rule as the roll)" empty \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"

printf '# C\n\n## [1.0.0] - 2026-01-01\n\n- b\n' > "$f"
check "check-unreleased: no Unreleased heading" no-unreleased \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"

# shellcheck disable=SC2016  # the backticks are a literal markdown fence
printf '# C\n\n## [Unreleased]\n\n```\n## [Unreleased]\n```\n\n## [1.0.0] - 2026-01-01\n' > "$f"
check "check-unreleased: fenced lookalike is no heading; fence body counts as content" has-content \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"

check "no version without --check-unreleased still refused" 1 "$(roll "$f")"

echo
if [ "$fail" -eq 0 ]; then
    echo "All roll-changelog tests passed"
else
    echo "Some roll-changelog tests FAILED"
fi
exit "$fail"
