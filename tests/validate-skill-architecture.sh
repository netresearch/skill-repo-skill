#!/usr/bin/env bash
# Regression test: validate-skill.sh enforces the Agent Skills budgets and the
# flat-discovery rule.
#
# Two things this pins that were wrong before:
#
#   * The size budget counted 500 WORDS over the WHOLE file. The spec says
#     "Keep your main SKILL.md under 500 lines", and counting the frontmatter
#     put the description -- the only surface that decides whether a skill is
#     used at all -- in competition with the instructions for one allowance.
#   * Nothing checked reachability. The spec says "Keep file references one
#     level deep from SKILL.md. Avoid deeply nested reference chains", because
#     a file reachable only through a second hop sits behind an unmarked door.
#
# Fixtures lack composer.json and README, so the validator exits non-zero
# regardless; every assertion reads the OUTPUT, never the exit status.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/skills/skill-repo/scripts/validate-skill.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# says <dir> <regex> -> "yes"/"no"; strips colour so patterns match plain text.
says() {
    local out
    out="$(bash "$VALIDATOR" "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    if grep -qE "$2" <<<"$out"; then printf 'yes\n'; else printf 'no\n'; fi
}

check() { # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        FAIL=$((FAIL + 1))
    fi
}

# skill <name> <desc> <body-lines> [extra frontmatter line] -> dir
skill() {
    local sname="$1" desc="$2" lines="$3" extra="${4:-}" dir
    dir="$(mktemp -d "$TMP/fx.XXXXXX")"
    mkdir -p "$dir/skills/$sname"
    {
        printf -- '---\n'
        printf 'name: %s\n' "$sname"
        printf 'description: "%s"\n' "$desc"
        [[ -n "$extra" ]] && printf '%s\n' "$extra"
        printf -- '---\n'
        python3 -c "print('\n'.join('line %d' % i for i in range(1, $lines + 1)))"
    } > "$dir/skills/$sname/SKILL.md"
    printf '%s' "$dir"
}

long_desc() { python3 -c "print('Use when ' + 'x' * ($1 - 9))"; }

echo "== description budget =="
d=$(skill demo "$(long_desc 1100)" 5)
check "over 1024 is an error"   yes "$(says "$d" 'ERROR.*description is 1[0-9]+ chars \(spec hard limit 1024\)')"
d=$(skill demo "$(long_desc 700)" 5)
check "501-1024 warns"          yes "$(says "$d" 'WARNING.*description is 7[0-9][0-9] chars')"
check "501-1024 is no error"    no  "$(says "$d" 'ERROR.*description is')"
d=$(skill demo "Use when demoing" 5)
check "under 500 is accepted"   yes "$(says "$d" 'OK.*description is [0-9]+ chars')"

echo "== spec name rules the character class alone does not catch =="
d=$(skill demo "Use when demoing" 5); mv "$d/skills/demo" "$d/skills/de--mo"
python3 -c "
import re,io
p='$d/skills/de--mo/SKILL.md'
s=open(p).read().replace('name: demo','name: de--mo')
open(p,'w').write(s)"
check "consecutive hyphens rejected" yes "$(says "$d" 'ERROR.*must not contain consecutive hyphens')"

echo "== compatibility cap =="
d=$(skill demo "Use when demoing" 5 "compatibility: \"$(python3 -c 'print("x"*600)')\"")
check "over 500 chars is an error" yes "$(says "$d" 'ERROR.*compatibility is 6[0-9][0-9] chars \(spec max 500\)')"

echo "== body size in LINES, not words =="
# 520 words on a handful of lines must NOT trip the budget any more.
d=$(mktemp -d "$TMP/fx.XXXXXX"); mkdir -p "$d/skills/demo"
{ printf -- '---\nname: demo\ndescription: "Use when demoing"\n---\n'
  python3 -c "print(' '.join('word' for _ in range(520)))"; } > "$d/skills/demo/SKILL.md"
check "520 words on 2 lines is fine" yes "$(says "$d" 'OK.*body is [0-9]+ lines')"
check "no word-count verdict at all" no  "$(says "$d" 'is [0-9]+ words')"

d=$(skill demo "Use when demoing" 520)
check "over 500 lines is an error"  yes "$(says "$d" 'ERROR.*body is 52[0-9] lines \(spec recommends under 500\)')"
d=$(skill demo "Use when demoing" 350)
check "301-500 lines warns"         yes "$(says "$d" 'WARNING.*body is 35[0-9] lines')"
check "301-500 lines is no error"   no  "$(says "$d" 'ERROR.*body is')"

echo "== flat discovery =="
d=$(mktemp -d "$TMP/fx.XXXXXX"); S="$d/skills/demo"
mkdir -p "$S/references" "$S/scripts"
printf -- '---\nname: demo\ndescription: "Use when demoing"\n---\n\n# demo\n\nSee references/known.md and run scripts/named.sh\n' > "$S/SKILL.md"
printf '# known\n\nDetail lives in references/hidden.md\n' > "$S/references/known.md"
printf '# hidden\n' > "$S/references/hidden.md"
printf '# orphan\n' > "$S/references/orphan.md"
printf '#!/bin/sh\n' > "$S/scripts/named.sh";  chmod +x "$S/scripts/named.sh"
printf '#!/bin/sh\n' > "$S/scripts/lonely.sh"; chmod +x "$S/scripts/lonely.sh"
printf '# sourced, not run\n' > "$S/scripts/lib-common.sh"   # deliberately NOT executable

check "second-hop reference warns, naming both" yes \
    "$(says "$d" 'WARNING.*references/hidden.md is reachable only via references/known.md')"
check "unreferenced reference warns"            yes \
    "$(says "$d" 'WARNING.*references/orphan.md is not named in SKILL.md')"
check "unnamed executable warns"                yes \
    "$(says "$d" 'WARNING.*script\(s\) not named in SKILL.md:.*lonely\.sh')"
# The exemption that keeps the warning honest: a sourced library is not a
# capability the agent invokes, so demanding it in the control plane is noise.
check "non-executable library is exempt"        no  "$(says "$d" 'not named in SKILL.md:.*lib-common\.sh')"
check "a named script is not flagged"           no  "$(says "$d" 'not named in SKILL.md:.*named\.sh')"

echo "== Contents section on long references =="
d=$(mktemp -d "$TMP/fx.XXXXXX"); S="$d/skills/demo"; mkdir -p "$S/references"
printf -- '---\nname: demo\ndescription: "Use when demoing"\n---\n\n# demo\n\nSee references/big.md and references/toc.md\n' > "$S/SKILL.md"
python3 -c "open('$S/references/big.md','w').write('# big\n' + '\n'.join('l%d' % i for i in range(150)))"
python3 -c "open('$S/references/toc.md','w').write('# toc\n\n## Contents\n\n- a\n\n' + '\n'.join('l%d' % i for i in range(150)))"
check "long reference without Contents warns" yes "$(says "$d" 'WARNING.*references/big.md is 1[0-9][0-9] lines with no Contents')"
check "long reference with Contents is fine"  no  "$(says "$d" 'references/toc.md is [0-9]+ lines with no Contents')"

echo "== this repository obeys its own rules =="
out="$(bash "$VALIDATOR" "$ROOT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
arch_warn="$(grep -cE 'WARNING.*(not named in SKILL.md|reachable only via|with no Contents)' <<<"$out")"
check "no architecture warnings on this repo" "0" "$arch_warn"

echo "----------------------------------------"
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || { echo "Architecture tests FAILED"; exit 1; }
echo "All architecture tests passed"
