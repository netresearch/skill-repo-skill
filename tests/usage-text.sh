#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# tests/usage-text.sh — the --help text of the shipped scripts.
#
# Four scripts print their usage by reading their own header comment, three of
# them by line number. The SPDX notice sits in that header, so a script that
# reads fixed lines prints the notice and drops its last lines instead. Each
# case pins the first and the last line of the usage text and asserts that no
# SPDX line leaks into it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)/skills/skill-repo/scripts"
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
has() { grep -qF -- "$1" <<<"$2" && echo yes || echo no; }

# usage_case <script> <first expected line> <last expected line>
usage_case() {
    local script="$1" first="$2" last="$3" out rc
    out=$(cd "$WORK" && bash "$SCRIPTS/$script" --help 2>&1); rc=$?
    check "$script --help exits 0" 0 "$rc"
    check "$script --help prints its first usage line" yes "$(has "$first" "$out")"
    check "$script --help prints its last usage line" yes "$(has "$last" "$out")"
    check "$script --help prints no SPDX notice" no "$(has "SPDX-" "$out")"
}

usage_case migrate-licensing.sh \
    "Usage: ./migrate-licensing.sh [<repo-root-path>]" \
    "./migrate-licensing.sh --help"
usage_case check-version-parity.sh \
    "check-version-parity.sh — verify plugin.json, composer.json, and SKILL.md" \
    "Exit codes: 0 = parity OK, 1 = mismatch or missing version."
usage_case fleet-release-github.sh \
    "fleet-release-github.sh — fleet release driver for the PUBLIC GitHub skill" \
    "bump commit as git trailers (requires git >= 2.32)."
# shellcheck disable=SC2016  # literal usage text, not an expansion
usage_case sync-plugin-manifest.sh \
    "sync-plugin-manifest.sh — project the portable Agent Plugins manifest" \
    '`$schema` and `extensions` are portable-manifest concerns and never copied.'

echo ""
if [ "$fail" -eq 0 ]; then
    echo "All usage-text tests passed"
else
    echo "usage-text tests FAILED"
fi
exit "$fail"
