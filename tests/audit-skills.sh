#!/usr/bin/env bash
# Regression test for scripts/audit-skills.sh get_description().
# Guards issue #160: exit-in-a-rule used to trigger the END block, printing
# the description twice and inflating the reported char count ~2x.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../scripts/audit-skills.sh"

get_description() { :; }
eval "$(sed -n '/^get_description()/,/^}/p' "$script")"

fm=$'name: x\ndescription: "Use when doing a thing with a description of a known, specific length here."\nlicense: MIT'
expected='Use when doing a thing with a description of a known, specific length here.'
got="$(get_description "$fm")"

fail=0
[[ "$got" == "$expected" ]] || { echo "FAIL: get_description returned '$got', expected '$expected'"; fail=1; }
[[ "$got" != *$'\n'* ]] || { echo "FAIL: output contains a newline (double-print regression)"; fail=1; }
[[ ${#got} -eq ${#expected} ]] || { echo "FAIL: char count ${#got} != real ${#expected}"; fail=1; }

if [[ "$fail" == "0" ]]; then echo "PASS: get_description single-prints, char count matches real length"; fi
exit "$fail"
