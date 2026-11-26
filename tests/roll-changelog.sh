#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# tests/roll-changelog.sh — exercises skills/skill-repo/scripts/roll-changelog.py.
#
# The six released-heading shapes documented in release-discipline.md each get
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

# --- 2b. bare dash (tender-estimation shape) ---------------------------------
f="$WORK/baredash.md"
cat > "$f" <<'EOF'
# Changelog

## Unreleased

- something

## 1.4.0 - 2026-10-23

- earlier
EOF
check "bare dash: exits 0" 0 "$(roll "$f" 1.5.0 --date 2026-11-08)"
check "bare dash: shape reproduced" yes \
    "$(grep -qx '## 1.5.0 - 2026-11-08' "$f" && echo yes || echo no)"
check "bare dash: unbracketed Unreleased preserved" yes \
    "$(grep -qx '## Unreleased' "$f" && echo yes || echo no)"

# An older bare-dash release below a bracketed one still counts as the base
# for the backfill of a missing definition.
f="$WORK/baredash-mixed.md"
cat > "$f" <<'EOF'
## [Unreleased]

- next

## [1.5.0] - 2026-11-08

- newer

## 1.4.0 - 2026-10-23

- older

[Unreleased]: https://example.org/r/compare/v1.4.0...HEAD
EOF
check "bare dash mixed: exits 0" 0 "$(roll "$f" 1.6.0 --date 2026-11-09)"
check "bare dash mixed: missing [1.5.0] backfilled from the bare-dash base" yes \
    "$(grep -qxF '[1.5.0]: https://example.org/r/compare/v1.4.0...v1.5.0' "$f" && echo yes || echo no)"

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
# The compare base comes from the headings, not from [Unreleased] (#281).
# Reproduces matrix-skill: [Unreleased] still points at v3.1.1 and the [3.1.2]
# definition was never written, so the old code shipped v3.1.1...v3.1.3.
f="$WORK/refs-stale.md"
cat > "$f" <<'EOF'
## [Unreleased]

- change

## [3.1.2] - 2026-02-01

- mid

## [3.1.1] - 2026-01-01

- old

[Unreleased]: https://github.com/x/y/compare/v3.1.1...HEAD
[3.1.1]: https://github.com/x/y/compare/v3.1.0...v3.1.1
EOF
check "stale base: exits 0" 0 "$(roll "$f" 3.1.3 --date 2026-08-13)"
check "stale base: new release compares against the heading below it" yes \
    "$(grep -qx '\[3.1.3\]: https://github.com/x/y/compare/v3.1.2...v3.1.3' "$f" && echo yes || echo no)"
check "stale base: NOT the stale [Unreleased] base" yes \
    "$(grep -q 'compare/v3.1.1\.\.\.v3.1.3' "$f" && echo no || echo yes)"
check "stale base: the missing [3.1.2] definition is backfilled" yes \
    "$(grep -qx '\[3.1.2\]: https://github.com/x/y/compare/v3.1.1...v3.1.2' "$f" && echo yes || echo no)"
check "stale base: [Unreleased] still restarts at the new tag" yes \
    "$(grep -qx '\[Unreleased\]: https://github.com/x/y/compare/v3.1.3...HEAD' "$f" && echo yes || echo no)"

# Headings and definitions may spell the tag differently. The backfill must see
# the existing definition through that difference, or it writes a second one.
f="$WORK/refs-mixed.md"
cat > "$f" <<'EOF'
## [Unreleased]

- change

## [v2.1.0] - 2026-02-01

- mid

## [v2.0.0] - 2026-01-01

- old

[Unreleased]: https://github.com/x/y/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/x/y/compare/v2.0.0...v2.1.0
EOF
check "mixed label style: exits 0" 0 "$(roll "$f" 2.2.0 --date 2026-08-13)"
check "mixed label style: no duplicate definition for the previous version" 1 \
    "$(grep -c 'compare/v2.0.0\.\.\.v2.1.0' "$f")"

# Unprefixed tag style must stay unprefixed on both ends of the range.
f="$WORK/refs-bare.md"
cat > "$f" <<'EOF'
## [Unreleased]

- change

## [2.0.0] - 2026-02-01

- old

[Unreleased]: https://github.com/x/y/compare/2.0.0...HEAD
[2.0.0]: https://github.com/x/y/compare/1.9.0...2.0.0
EOF
check "bare tag style: exits 0" 0 "$(roll "$f" 2.1.0 --date 2026-08-13)"
check "bare tag style: no v prefix leaks into the new range" yes \
    "$(grep -qx '\[2.1.0\]: https://github.com/x/y/compare/2.0.0...2.1.0' "$f" && echo yes || echo no)"

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

# --- --seed-entry: a stabilization release has no new content of its own ----
# The fleet driver passes the 1.0.0 promise; the roll must land it whether the
# section is missing, empty or already holds entries, and never twice.
SEED='First stable release. From 1.0.0 on, breaking changes need a new major.'

printf '# C\n\n## [Unreleased]\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: empty section is seeded and rolled" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: entry sits under the new heading" "- $SEED" \
    "$(awk '/^## \[1\.0\.0\] - 2026-09-29$/ { on = 1; next } on && /^- / { print; exit }' "$f")"
check "seed: entry carries a Changed subsection" yes \
    "$(awk '/^## \[1\.0\.0\]/ { on = 1; next } on && /^## / { exit } on && /^### Changed$/ { print "yes"; exit }' "$f")"
check "seed: a fresh empty Unreleased remains" empty \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"

printf '# C\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: missing Unreleased heading is created, then rolled" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: new heading placed above the old release" "## [1.0.0] - 2026-09-29|## [0.3.0] - 2026-01-01" \
    "$(grep -E '^## \[[0-9]' "$f" | head -2 | paste -sd'|')"
check "seed: created Unreleased stays above everything" "## [Unreleased]" \
    "$(grep -m1 '^## ' "$f")"

printf '# C\n\n## [Unreleased]\n\n### Fixed\n\n- a fix\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: section with content keeps it and adds the entry" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: existing entry kept" yes "$(grep -qx -- '- a fix' "$f" && echo yes || echo no)"
check "seed: promise added once" 1 "$(grep -cxF -- "- $SEED" "$f")"

printf '# C\n\n## [Unreleased]\n\n### Changed\n\n- other\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: roll into an existing Changed succeeds" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: joins an existing Changed subsection instead of a second one" 1 \
    "$(awk '/^## \[1\.0\.0\]/ { on = 1; next } on && /^## / { exit } on && /^### Changed$/ { n++ } END { print n + 0 }' "$f")"

printf '# C\n\n## [Unreleased]\n\n### Changed\n\n- %s\n\n## [0.3.0] - 2026-01-01\n\n- b\n' "$SEED" > "$f"
check "seed: roll with the entry already present succeeds" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: an entry already present is not duplicated" 1 "$(grep -cxF -- "- $SEED" "$f")"

# A file whose bullets wrap gets the promise wrapped at its own widest line, so
# a markdownlint MD013 limit the file already meets is not broken by the seed
# (ecom-phpstorm-index-skill v1.0.0, 2026-11-04: a 235-column line at limit 120).
LONG='First stable release. From 1.0.0 on, an incompatible change to what this plugin exposes ships only in a new major version.'
printf '# C\n\n## [Unreleased]\n\n## [0.3.0] - 2026-01-01\n\n- a wrapped entry that runs over\n  two lines of the file\n' > "$f"
check "seed: wrapped file is seeded and rolled" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$LONG")"
check "seed: no line wider than the file's widest" 32 \
    "$(awk '{ if (length > m) m = length } END { print m }' "$f")"
check "seed: the wrapped promise reads back as the whole sentence" yes \
    "$(awk '/^## \[1\.0\.0\]/ { on = 1; next } on && /^## / { exit } on' "$f" | tr -s ' \n' ' ' | grep -qF -- "- $LONG" && echo yes || echo no)"
printf '# C\n\n## [Unreleased]\n\n### Changed\n\n- First stable release. From 1.0.0 on, an incompatible\n  change to what this plugin exposes ships only in a new\n  major version.\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: a wrapped promise already present is recognized" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$LONG")"
check "seed: the wrapped promise is not added a second time" 1 "$(grep -c 'First stable' "$f")"
printf '# C\n\n## [Unreleased]\n\n## [0.3.0] - 2026-01-01\n\n- short\n' > "$f"
check "seed: unwrapped file keeps the promise on one line" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$LONG")"
check "seed: one-line promise in an unwrapped file" 1 "$(grep -cxF -- "- $LONG" "$f")"

printf '# C\n\n## \\[Unreleased\\]\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: an escaped \\[Unreleased\\] heading is recognized, not duplicated" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: escaped heading file still has one Unreleased heading" 1 "$(grep -ci 'unreleased' "$f")"

# shellcheck disable=SC2016  # the backticks are a literal markdown fence
printf '# C\n\n## [Unreleased]\n\n### Fixed\n\n- a fix\n\n```\n### Changed\n\n- %s\n```\n\n## [0.3.0] - 2026-01-01\n\n- b\n' "$SEED" > "$f"
check "seed: fenced example in the section rolls" 0 \
    "$(roll "$f" 1.0.0 --date 2026-09-29 --seed-entry "$SEED")"
check "seed: fenced lookalike neither receives nor suppresses the promise" 2 \
    "$(grep -cxF -- "- $SEED" "$f")"
check "seed: the visible promise sits above the fence" yes \
    "$(awk -v b="- $SEED" '/^```/ { fence = !fence; next } !fence && $0 == b { print "yes"; exit }' "$f")"

printf '# C\n\n## [0.3.0] - 2026-01-01\n\n- b\n' > "$f"
check "seed: --dry-run writes nothing" 0 "$(roll "$f" 1.0.0 --dry-run --seed-entry "$SEED")"
check "seed: --dry-run left the file alone" 0 "$(grep -c 'Unreleased' "$f")"

# --- changelog.d fragments ----------------------------------------------------
# Every case gets its own directory: the script reads changelog.d/ next to the
# CHANGELOG it rolls, so a shared directory would leak fragments between cases.
fragcase() { # NAME — fresh dir with an empty changelog.d/; sets d and f
    d="$WORK/frag-$1"
    rm -rf "$d"
    mkdir -p "$d/changelog.d"
    f="$d/CHANGELOG.md"
}
section() { # FILE HEADING-REGEX — the lines under one ## heading, up to the next
    awk -v h="$2" '$0 ~ h { on = 1; next } on && /^## / { exit } on' "$1"
}

# The defect this exists for: rebasing sibling PRs that each added a
# "### Changed" left the heading twice in [Unreleased] (MD024, and two lists
# under one release). With a fragment in play, the collection folds them.
fragcase dup
cat > "$f" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- first sibling

### Changed

- second sibling

## [1.0.0] - 2026-01-01

- old
EOF
printf -- '- from a fragment\n' > "$d/changelog.d/third-sibling.changed.md"
check "fragments: duplicate ### Changed + fragment rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: duplicate ### Changed folded into one heading" 1 \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep -cx '### Changed')"
check "fragments: entries in order, existing first, fragment last" "- first sibling|- second sibling|- from a fragment" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep '^- ' | paste -sd'|')"
check "fragments: folded and collected entries form one tight list" "- first sibling|- second sibling|- from a fragment" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep -A2 -x -- '- first sibling' | paste -sd'|')"
check "fragments: collected fragment deleted" no \
    "$([ -e "$d/changelog.d/third-sibling.changed.md" ] && echo yes || echo no)"

# Into an empty [Unreleased]: headings in Keep a Changelog order, not file order.
fragcase empty
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- a fix\n' > "$d/changelog.d/a-branch.fixed.md"
printf -- '- a feature\n  continued\n- second feature\n' > "$d/changelog.d/b-branch.added.md"
printf '# Changelog fragments\n' > "$d/changelog.d/README.md"
check "fragments: empty Unreleased + fragments rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: the run reports what it collected" yes \
    "$(grep -q '^collected 2 fragment(s): changelog.d/a-branch.fixed.md, changelog.d/b-branch.added.md$' "$WORK/out.txt" && echo yes || echo no)"
check "fragments: headings in Keep a Changelog order" "### Added|### Fixed" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep '^### ' | paste -sd'|')"
check "fragments: multi-line fragment kept verbatim" yes \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep -qx '  continued' && echo yes || echo no)"
check "fragments: a fresh empty Unreleased remains" empty \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"
check "fragments: README.md is not collected (stays, and its text is not in the CHANGELOG)" "yes no" \
    "$([ -e "$d/changelog.d/README.md" ] && echo yes || echo no) $(grep -q 'Changelog fragments' "$f" && echo yes || echo no)"
check "fragments: the directory itself stays" yes "$([ -d "$d/changelog.d" ] && echo yes || echo no)"
check "fragments: blank line after every collected heading (MD022)" 0 \
    "$(awk 'p ~ /^#/ && $0 != "" { n++ } { p = $0 } END { print n + 0 }' "$f")"

# Into a filled [Unreleased], same category: one heading, existing entry first.
fragcase same
printf '## [Unreleased]\n\nIntro text.\n\n### Added\n\n- existing\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- new\n' > "$d/changelog.d/x.added.md"
check "fragments: same category rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: same category keeps one heading, existing first" "Intro text.|### Added|- existing|- new" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep -v '^$' | paste -sd'|')"
# A blank line between two items makes the whole list loose (a paragraph gap
# after every entry when rendered): the fragment joins the list it continues.
check "fragments: appended bullet joins the existing list (no blank line)" "- existing|- new" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep -A1 -x -- '- existing' | paste -sd'|')"

# After a paragraph, the list starts after a blank line (MD032).
fragcase para
printf '## [Unreleased]\n\n### Added\n\nA note, not a list.\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- new\n' > "$d/changelog.d/x.added.md"
check "fragments: after a paragraph rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: blank line between a paragraph and the appended list" "A note, not a list.||- new" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep -A2 -x 'A note, not a list.' | paste -sd'|')"

# Different category: the missing heading lands in Keep a Changelog order.
fragcase other
printf '## [Unreleased]\n\n### Fixed\n\n- a fix\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- a feature\n' > "$d/changelog.d/x.added.md"
printf -- '- hardening\n' > "$d/changelog.d/x.security.md"
check "fragments: different categories roll" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: Added inserted before Fixed, Security after it" "### Added|### Fixed|### Security" \
    "$(section "$f" '^## \\[1\\.1\\.0\\]' | grep '^### ' | paste -sd'|')"

# upgrading -> "### Upgrading from X.Y" of the newest release, before Added.
fragcase upgrading
printf '## [Unreleased]\n\n### Added\n\n- a\n\n## [v2.3.1] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- run the wizard\n' > "$d/changelog.d/x.upgrading.md"
check "fragments: upgrading rolls" 0 "$(roll "$f" 2.4.0 --date 2026-08-13)"
check "fragments: upgrading heading names the last minor, before Added" "### Upgrading from 2.3|### Added" \
    "$(section "$f" '^## \\[v2\\.4\\.0\\]' | grep '^### ' | paste -sd'|')"

# An indented fence inside a bullet is content, not a heading.
fragcase fenced
printf '## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
# shellcheck disable=SC2016  # the backticks are a literal markdown fence
printf -- '- documents the format:\n\n  ```markdown\n  ### Added\n  ```\n' > "$d/changelog.d/x.changed.md"
check "fragments: indented fenced lookalike rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: the fenced line is kept verbatim" 1 "$(grep -cx '  ### Added' "$f")"
check "fragments: …and creates no Added heading" 0 "$(grep -cx '### Added' "$f")"

# First release: link-reference definitions end [Unreleased].
fragcase firstrel
printf '## [Unreleased]\n\n### Fixed\n\n- f\n\n[Unreleased]: https://example.invalid/commits/main\n' > "$f"
printf -- '- a feature\n' > "$d/changelog.d/x.added.md"
check "fragments: first release with link definitions rolls" 0 "$(roll "$f" 0.1.0 --date 2026-08-13)"
check "fragments: collected above the link definitions, which stay last" "### Added|### Fixed|[Unreleased]: https://example.invalid/commits/main" \
    "$(grep -E '^(### |\[Unreleased\]:)' "$f" | paste -sd'|')"

# Refusals: each refuses the whole run, writes nothing, deletes nothing.
for bad in heading prose name upper other-ext; do
    fragcase "bad-$bad"
    # A filled Unreleased, so a script that ignores changelog.d/ would roll.
    printf '## [Unreleased]\n\n- pending\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
    printf -- '- fine\n' > "$d/changelog.d/a-ok.added.md"
    case "$bad" in
        heading) printf -- '- x\n\n### Fixed\n\n- y\n' > "$d/changelog.d/b.fixed.md" ;;
        prose) printf 'Some prose first.\n\n- y\n' > "$d/changelog.d/b.fixed.md" ;;
        name) printf -- '- y\n' > "$d/changelog.d/b.notes.md" ;;
        upper) printf -- '- y\n' > "$d/changelog.d/B.fixed.md" ;;
        other-ext) printf -- '- y\n' > "$d/changelog.d/b.fixed.txt" ;;
    esac
    before=$(sha256sum "$f")
    check "fragments: invalid fragment ($bad) refused" 1 "$(roll "$f" 1.1.0 --date 2026-08-13)"
    check "fragments: invalid fragment ($bad) named in the error" yes \
        "$(grep -q 'changelog.d/ is not ready' "$WORK/err.txt" && grep -qE '  (b|B)\.' "$WORK/err.txt" && echo yes || echo no)"
    check "fragments: invalid fragment ($bad) leaves CHANGELOG.md unchanged" "$before" "$(sha256sum "$f")"
    check "fragments: invalid fragment ($bad) deletes no fragment" yes \
        "$([ -e "$d/changelog.d/a-ok.added.md" ] && echo yes || echo no)"
    check "fragments: invalid fragment ($bad) also fails --check-unreleased" 1 "$(roll "$f" --check-unreleased)"
done

# A fragment directory the roll cannot delete from is refused before the write.
fragcase readonly
printf '## [Unreleased]\n\n- pending\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- x\n' > "$d/changelog.d/x.added.md"
before=$(sha256sum "$f")
chmod a-w "$d/changelog.d"
check "fragments: unwritable changelog.d refused" 1 "$(roll "$f" 1.1.0 --date 2026-08-13)"
chmod u+w "$d/changelog.d"
check "fragments: unwritable changelog.d leaves CHANGELOG.md unchanged" "$before" "$(sha256sum "$f")"

# --dry-run lists the fragments and touches nothing.
fragcase dry
printf '## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- x\n' > "$d/changelog.d/x.added.md"
before=$(sha256sum "$f")
check "fragments: dry run exits 0 on an Unreleased that only fragments fill" 0 "$(roll "$f" 1.1.0 --dry-run)"
check "fragments: dry run lists the fragment it would collect" yes \
    "$(grep -qx 'would collect: changelog.d/x.added.md' "$WORK/out.txt" && echo yes || echo no)"
check "fragments: dry run deletes nothing" yes "$([ -e "$d/changelog.d/x.added.md" ] && echo yes || echo no)"
check "fragments: dry run writes nothing" "$before" "$(sha256sum "$f")"

# --check-unreleased: waiting fragments are content, and the roll agrees.
fragcase chk
printf '## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- x\n' > "$d/changelog.d/x.added.md"
check "fragments: check-unreleased with only fragments" has-content \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"
check "fragments: …and the roll of the same tree succeeds" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
fragcase chk-missing
printf '# C\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$f"
printf -- '- x\n' > "$d/changelog.d/x.added.md"
check "fragments: check-unreleased with fragments and no Unreleased heading" has-content \
    "$(roll "$f" --check-unreleased > /dev/null; cat "$WORK/out.txt")"
check "fragments: …and the roll creates the heading and succeeds" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: created Unreleased stays on top, the fragment under the release" "## [Unreleased]|## [1.1.0] - 2026-08-13|### Added|- x|## [1.0.0] - 2026-01-01" \
    "$(grep -E '^(## |### |- x$)' "$f" | paste -sd'|')"

# No fragments: README.md alone (the steady state of an adopting repo) and an
# empty directory give the byte-identical output of a tree without changelog.d.
SRC='# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- a\n\n### Changed\n\n- b\n\n## [1.0.0] - 2026-01-01\n\n- old\n'
src() { printf '%b' "$SRC"; }
mkdir -p "$WORK/nofrag-plain"
src > "$WORK/nofrag-plain/CHANGELOG.md"
roll "$WORK/nofrag-plain/CHANGELOG.md" 1.1.0 --date 2026-08-13 > /dev/null
plain_out=$(cat "$WORK/out.txt")
fragcase readme-only
src > "$f"
printf '# Changelog fragments\n' > "$d/changelog.d/README.md"
check "fragments: README.md only rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: README.md only is byte-identical to no changelog.d" yes \
    "$(cmp -s "$f" "$WORK/nofrag-plain/CHANGELOG.md" && [ "$(cat "$WORK/out.txt")" = "$plain_out" ] && echo yes || echo no)"
check "fragments: …which keeps a duplicate heading untouched (merge only with fragments)" 2 \
    "$(grep -cx '### Changed' "$f")"
fragcase emptydir
src > "$f"
check "fragments: empty changelog.d rolls" 0 "$(roll "$f" 1.1.0 --date 2026-08-13)"
check "fragments: empty changelog.d is byte-identical to no changelog.d" yes \
    "$(cmp -s "$f" "$WORK/nofrag-plain/CHANGELOG.md" && echo yes || echo no)"

echo
if [ "$fail" -eq 0 ]; then
    echo "All roll-changelog tests passed"
else
    echo "Some roll-changelog tests FAILED"
fi
exit "$fail"
