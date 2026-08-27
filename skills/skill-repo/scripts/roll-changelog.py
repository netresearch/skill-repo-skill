#!/usr/bin/env python3
"""roll-changelog.py — move the [Unreleased] section of a CHANGELOG.md under a
new released heading, reproducing the repo's own heading shape.

Usage:
    roll-changelog.py FILE VERSION [--date YYYY-MM-DD] [--dry-run]

Why this exists (references/release-discipline.md, "Changelog Rollover"):
five released-heading shapes coexist in the fleet, and a roll anchored on one
shape matches nothing in the others and exits 0 — the release then ships with
its content still under Unreleased and nobody sees an error. This script
detects the shape from the newest *released* heading and reproduces it,
including the dash character and, for the linked form, the tag inside the URL.

Shapes:
    bracketed dash      ## [1.2.3] - 2026-08-08
    bare paren          ## 1.2.3 (2026-08-08)
    bracketed em dash   ## [0.3.23] — 2026-07-02
    linked              ## [v2.6.0](https://.../releases/tag/v2.6.0) — 2026-02-28
    none yet            first release: default to the keep-a-changelog
                        bracketed-dash form the [Unreleased] bracket implies

Guards:
    * exactly one Unreleased heading outside code fences, or abort;
    * the Unreleased section must have content — rolling nothing is an error,
      never a silent success;
    * heading-looking lines inside fenced code blocks are ignored (a ^##
      anchored scan is fence-blind and splices sections into examples);
    * output keeps a blank line after each heading so the rolled file stays
      markdownlint-clean (MD022/MD032 red-lit 16 of 63 repos mid-sweep once).

Exit codes: 0 = rolled (or clean --dry-run), 1 = refused; the file is never
partially written (temp file + atomic replace).
"""

import argparse
import datetime
import os
import re
import sys
import tempfile

UNRELEASED_RE = re.compile(r"^##\s+\[?unreleased\]?\s*$", re.IGNORECASE)
FENCE_RE = re.compile(r"^ {0,3}(```|~~~)")
# Newest released heading, one regex per shape. Order matters: the linked form
# also starts with "## [" and must win over plain bracketed.
LINKED_RE = re.compile(
    r"^##\s+\[(?P<tag>[^\]]+)\]\((?P<url>[^)]+)\)\s+(?P<dash>[-—–])\s+(?P<date>.+?)\s*$"
)
BRACKETED_RE = re.compile(
    r"^##\s+\[(?P<tag>[^\]]+)\]\s+(?P<dash>[-—–])\s+(?P<date>.+?)\s*$"
)
BARE_PAREN_RE = re.compile(r"^##\s+(?P<tag>\S+)\s+\((?P<date>[^)]+)\)\s*$")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def scan(lines):
    """Yield (index, line, in_fence) tracking fenced code blocks."""
    fence = None
    for i, line in enumerate(lines):
        m = FENCE_RE.match(line)
        if m:
            marker = m.group(1)
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            yield i, line, True
            continue
        yield i, line, fence is not None


def released_heading(version: str, sample: str, date: str) -> str:
    """Reproduce the shape of `sample` (a released heading) for `version`."""
    m = LINKED_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = f"v{version}" if old_tag.startswith("v") else version
        url = m.group("url")
        if old_tag not in url:
            fail(
                f"linked heading URL does not contain its own tag "
                f"('{old_tag}' not in '{url}') — refusing to guess the rewrite"
            )
        new_url = url.replace(old_tag, new_tag)
        return f"## [{new_tag}]({new_url}) {m.group('dash')} {date}"
    m = BRACKETED_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = f"v{version}" if old_tag.startswith("v") else version
        return f"## [{new_tag}] {m.group('dash')} {date}"
    m = BARE_PAREN_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = f"v{version}" if old_tag.startswith("v") else version
        return f"## {new_tag} ({date})"
    fail(f"unrecognized released-heading shape: '{sample.rstrip()}'")
    raise AssertionError  # unreachable; fail() exits


def parse_args():
    parser = argparse.ArgumentParser(
        description="Roll the [Unreleased] CHANGELOG section into a release."
    )
    parser.add_argument("file", help="path to CHANGELOG.md")
    parser.add_argument(
        "version",
        nargs="?",
        help="release version (leading v stripped); not needed with --check-unreleased",
    )
    parser.add_argument(
        "--date",
        default=datetime.datetime.now(datetime.timezone.utc)
        .astimezone()
        .date()
        .isoformat(),
        help="release date (default: today, ISO 8601)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the new heading and moved-section size, write nothing",
    )
    parser.add_argument(
        "--check-unreleased",
        action="store_true",
        help="report the Unreleased section's state (no-unreleased | empty | "
        "has-content) with the SAME emptiness rule the roll enforces, write "
        "nothing; surveys use this so an empty section surfaces before the "
        "bump fails on it",
    )
    args = parser.parse_args()
    if args.check_unreleased:
        return args
    if args.version is None:
        fail("version is required (only --check-unreleased goes without one)")
    args.version = args.version.lstrip("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", args.version):
        fail(f"'{args.version}' is not a semantic version")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        fail(f"--date '{args.date}' is not YYYY-MM-DD")
    return args


def read_changelog(path):
    """Return (lines, eol, trailing_newline), preserving the file's own line
    endings — rewriting a CRLF changelog wholesale to LF buries the roll in a
    whole-file diff."""
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            text = fh.read()
    except OSError as exc:
        fail(str(exc))
    eol = "\r\n" if text.count("\r\n") > text.count("\n") - text.count("\r\n") else "\n"
    return (
        text.replace("\r\n", "\n").splitlines(),
        eol,
        text.endswith(("\n", "\r\n")),
    )


def locate_headings(lines):
    """Return (unreleased_index, first_released) or refuse: exactly one
    Unreleased heading outside code fences, and no released heading above it."""
    unreleased_at = []
    first_released = None  # (index, line)
    for i, line, in_fence in scan(lines):
        if in_fence:
            continue
        if UNRELEASED_RE.match(line):
            unreleased_at.append(i)
        elif first_released is None and line.startswith("## "):
            first_released = (i, line)
    if len(unreleased_at) != 1:
        fail(
            f"{len(unreleased_at)} Unreleased headings outside code fences "
            f"(need exactly 1)"
        )
    idx = unreleased_at[0]
    if first_released is not None and first_released[0] < idx:
        fail(
            f"a released heading (line {first_released[0] + 1}) precedes the "
            f"Unreleased heading (line {idx + 1}) — refusing to roll a "
            f"non-standard layout"
        )
    return idx, first_released


def splice_roll(lines, idx, end, new_heading):
    """Return (new_lines, moved_count): the Unreleased heading stays as found,
    one blank line, the new released heading, one blank line, then the old
    section content — blank-line hygiene keeps markdownlint green."""
    content = lines[idx + 1 : end]
    while content and not content[0].strip():
        content.pop(0)
    # Exactly one blank line between the moved content and the next heading.
    while content and not content[-1].strip():
        content.pop()
    tail = lines[end:]
    new_lines = lines[:idx] + [lines[idx], "", new_heading, ""] + content
    if tail:
        new_lines += [""] + tail
    return new_lines, len(content)


def write_atomic(path, out):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".roll-changelog.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(out)
        os.replace(tmp_path, path)
    except OSError as exc:
        os.unlink(tmp_path)
        fail(str(exc))


def unreleased_state(lines):
    """One of 'no-unreleased' | 'empty' | 'has-content', by the same section
    boundaries and comments-are-not-content rule the roll itself enforces."""
    unreleased_at = []
    heading_at = []
    for i, line, in_fence in scan(lines):
        if in_fence:
            continue
        if UNRELEASED_RE.match(line):
            unreleased_at.append(i)
        elif line.startswith("## "):
            heading_at.append(i)
    if not unreleased_at:
        return "no-unreleased"
    if len(unreleased_at) > 1:
        fail(
            f"{len(unreleased_at)} Unreleased headings outside code fences "
            f"(need exactly 1)"
        )
    idx = unreleased_at[0]
    end = next((h for h in heading_at if h > idx), len(lines))
    section = "\n".join(lines[idx + 1 : end])
    if re.sub(r"<!--.*?-->", "", section, flags=re.DOTALL).strip():
        return "has-content"
    return "empty"


def main() -> None:
    args = parse_args()
    if args.check_unreleased:
        lines, _eol, _tn = read_changelog(args.file)
        print(unreleased_state(lines))
        return
    version = args.version
    lines, eol, trailing_newline = read_changelog(args.file)
    idx, first_released = locate_headings(lines)

    if first_released is None:
        # First release: no shape to copy. The [Unreleased] bracket implies
        # keep-a-changelog, so default to its bracketed-dash form.
        new_heading = f"## [{version}] - {args.date}"
    else:
        new_heading = released_heading(version, first_released[1], args.date)

    # The section to be rolled must contain content — and HTML comments are
    # not content: rolling a comment-only section would ship a visually empty
    # release.
    end = first_released[0] if first_released else len(lines)
    section = "\n".join(lines[idx + 1 : end])
    if not re.sub(r"<!--.*?-->", "", section, flags=re.DOTALL).strip():
        fail(
            "the Unreleased section is empty (comments are not content) — nothing to release"
        )

    new_lines, moved = splice_roll(lines, idx, end, new_heading)
    if new_lines == lines:
        fail("the roll changed no lines — refusing to report success")

    defs_note = update_link_reference_definitions(new_lines, new_heading, version)

    if args.dry_run:
        print(f"would insert: {new_heading}")
        print(f"would move: {moved} lines out of Unreleased")
    else:
        write_atomic(args.file, eol.join(new_lines) + (eol if trailing_newline else ""))
        print(f"rolled Unreleased -> {new_heading}")
    if defs_note:
        print(defs_note)


def update_link_reference_definitions(new_lines, new_heading, version):
    """Keep-a-changelog ref-style links: `[Unreleased]: …/compare/vOLD...HEAD`
    at the bottom, one definition per released heading. After a roll the
    Unreleased range must restart at the new tag and the new heading needs its
    own definition — otherwise the new release renders as a dead link and the
    Unreleased diff keeps showing released commits. Mutates new_lines in
    place; returns a note (updated/warning) or None when no definitions exist.
    """
    def_re = re.compile(r"^\[(?P<label>[Uu]nreleased)\]:\s*(?P<url>\S+)\s*$")
    for i, line in enumerate(new_lines):
        m = def_re.match(line)
        if not m:
            continue
        url = m.group("url")
        # Parsed from the right — a lazy .*? prefix before the version would
        # backtrack super-linearly on crafted input. The range URL must end in
        # <old-tag>...HEAD.
        stem = url[: -len("...HEAD")] if url.endswith("...HEAD") else None
        old_m = re.search(r"v?\d+\.\d+\.\d+$", stem) if stem else None
        head_m = re.match(r"^##\s+\[(?P<label>[^\]]+)\]", new_heading)
        if not old_m or not head_m:
            return (
                "WARNING: link-reference definitions found but not in the "
                "known compare-range shape — update [Unreleased] and add "
                f"[{version}] manually"
            )
        old = old_m.group(0)
        new_tag = f"v{version}" if old.startswith("v") else version
        base = stem[: old_m.start()]
        new_lines[i] = f"[{m.group('label')}]: {base}{new_tag}...HEAD"
        new_lines.insert(i + 1, f"[{head_m.group('label')}]: {base}{old}...{new_tag}")
        return f"updated link-reference definitions ([Unreleased] -> {new_tag}...HEAD)"
    return None


if __name__ == "__main__":
    main()
