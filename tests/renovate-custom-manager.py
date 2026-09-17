#!/usr/bin/env python3
"""Regression tests for the Renovate customManager in renovate.json.

The manager pins ad-hoc tool versions in .github/workflows (`uvx ruff@0.16.0`,
`uv run --with pyyaml==6.0.3`) so Renovate opens a PR when they move. Two ways
it has failed, both silent, because "no dependency found here" and "nothing to
update here" look identical from outside:

  * it stopped matching. The pattern was written against `uvx <name>@<version>`
    and a later commit hardened the pin to `uvx --no-build ruff@0.16.0`; the
    pin then sat unmoved for weeks while the tool released eight versions.
  * it matched the wrong token. Allowing arbitrary words before the pinned name
    lets `uvx --from git+https://github.com/o/r@2843b87 tool` hand Renovate a
    git revision as the `pypi` version of an unrelated package.

So the cases below pin both directions: every invocation shape that must yield a
version, and the shapes that must yield nothing at all.

Renovate runs the pattern through RE2, whose named groups are `(?<name>...)`;
Python's re spells them `(?P<name>...)`. That translation is the one thing these
tests cannot check, so a green run here is evidence about the pattern, not about
Renovate's engine.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

#: (label, command line, expected currentValue or None)
CASES: list[tuple[str, str, str | None]] = [
    ("plain uvx", "uvx ruff@0.16.0 check .", "0.16.0"),
    ("boolean flag", "uvx --no-build ruff@0.16.0 check .", "0.16.0"),
    ("flag with value", "uvx --no-build --python 3.14 ruff@0.16.8 check .", "0.16.8"),
    ("--from a package", "uvx --from bandit bandit@1.9.4 -r .", "1.9.4"),
    ("uv run --with", "uv run --with pyyaml==6.0.3 python x.py", "6.0.3"),
    # A git revision is not a version of the pypi package the comment names.
    ("--from a git url", "uvx --from git+https://github.com/o/r@2843b87 tool", None),
    (
        "git url behind a flag",
        "uvx --no-build --from git+https://github.com/o/r@1234567 tool",
        None,
    ),
    # ... and it must not shadow a real pin standing after it.
    (
        "git url then a pin",
        "uvx --from git+https://github.com/o/r@2843b87 ruff@0.16.8 x",
        "0.16.8",
    ),
    ("no renovate comment", None, None),
]


def pattern() -> str:
    """The shipped pattern, with RE2 named groups translated for `re`."""
    config = json.loads((REPO_ROOT / "renovate.json").read_text(encoding="utf-8"))
    managers = config["customManagers"]
    if len(managers) != 1 or len(managers[0]["matchStrings"]) != 1:
        raise SystemExit("renovate-custom-manager: expected exactly one matchString")
    return managers[0]["matchStrings"][0].replace("(?<", "(?P<")


def captured(regex: re.Pattern[str], line: str | None) -> str | None:
    """`currentValue` for an annotated command, or for a bare one when line is None."""
    if line is None:
        text = "          uvx --no-build ruff@0.16.0 check .\n"
    else:
        text = f"# renovate: datasource=pypi depName=ruff\n          {line}\n"
    match = regex.search(text)
    return match.group("currentValue") if match else None


def main() -> int:
    regex = re.compile(pattern())
    failures = 0

    for label, line, expected in CASES:
        actual = captured(regex, line)
        if actual != expected:
            print(f"FAIL {label}: expected {expected!r}, got {actual!r}")
            failures += 1

    # The pattern is only worth anything if it matches the file it was written
    # for: the workflow that carries the repository's own ruff pins.
    workflow = (REPO_ROOT / ".github/workflows/validate.yml").read_text(
        encoding="utf-8"
    )
    found = [m.group("depName") for m in regex.finditer(workflow)]
    if found != ["ruff", "ruff"]:
        print(f"FAIL validate.yml: expected both ruff pins, got {found!r}")
        failures += 1

    if failures:
        print(f"{failures} failure(s)")
        return 1
    print(f"renovate-custom-manager: {len(CASES) + 1} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
