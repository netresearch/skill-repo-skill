#!/usr/bin/env python3
"""Print one markdown bullet naming a skill's evals that carry no delta.

Reads an ab-results.json (as written by run-ab-evals.sh) and prints nothing at
all unless its `evals_without_delta` list is non-empty — so the caller can
append the output unconditionally and get an empty file when every eval
discriminates.

    no-delta-line.py <ab-results.json> <skill-name>

Lives in a script rather than inline in the sweep workflow: a multi-line
python -c inside a YAML block scalar has to be indented to stay valid YAML and
unindented to stay valid Python, and the version that satisfies both is
unreadable.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <ab-results.json> <skill-name>", file=sys.stderr)
        return 2
    path, name = sys.argv[1], sys.argv[2]
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as exc:
        # A missing or unreadable results file is the caller's problem to
        # report; this script stays silent rather than inventing a finding.
        print(f"{path}: {exc}", file=sys.stderr)
        return 0
    names = data.get("evals_without_delta") or []
    if names:
        listed = ", ".join(f"`{n}`" for n in names)
        print(f"- **{name}** ({len(names)}): {listed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
