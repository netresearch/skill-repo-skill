#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""roll-changelog.py — move the [Unreleased] section of a CHANGELOG.md under a
new released heading, reproducing the repo's own heading shape.

Usage:
    roll-changelog.py FILE VERSION [--date YYYY-MM-DD] [--dry-run] [--seed-entry TEXT]
    roll-changelog.py FILE --check-unreleased

Why this exists (references/release-discipline.md, "Changelog Rollover"):
seven released-heading shapes coexist in the fleet, and a roll anchored on one
shape matches nothing in the others and exits 0 — the release then ships with
its content still under Unreleased and nobody sees an error. This script
detects the shape from the newest *released* heading and reproduces it,
including the dash character and, for the linked form, the tag inside the URL.

Shapes:
    bracketed dash      ## [1.2.3] - 2026-08-08
    bare paren          ## 1.2.3 (2026-08-08)
    bare dash           ## 1.2.3 - 2026-08-08
    bare version        ## 1.2.3  (no date; the --date value is not used)
    bracketed em dash   ## [0.3.23] — 2026-07-02
    linked              ## [v2.6.0](https://.../releases/tag/v2.6.0) — 2026-02-28
    none yet            first release: default to the keep-a-changelog
                        bracketed-dash form the [Unreleased] bracket implies
                        (a "## " heading without a version, such as
                        "## Prior history", only ends [Unreleased])

Guards:
    * exactly one Unreleased heading outside code fences, or abort;
    * the Unreleased section must have content — rolling nothing is an error,
      never a silent success;
    * heading-looking lines inside fenced code blocks are ignored (a ^##
      anchored scan is fence-blind and splices sections into examples);
    * output keeps a blank line after each heading so the rolled file stays
      markdownlint-clean (MD022/MD032 red-lit 16 of 63 repos mid-sweep once).

Changelog fragments (changelog.d/ next to FILE):
    A pull request writes its entry into its own file instead of editing
    [Unreleased], so sibling pull requests never conflict in CHANGELOG.md.
    The convention is the one the org's TYPO3 extensions already use:
    * name <branch-slug>.<section>.md, lowercase, where <section> is one of
      upgrading, added, changed, deprecated, removed, fixed, security and
      selects the heading ("upgrading" -> "### Upgrading from X.Y", X.Y taken
      from the newest released heading, or an existing "### Upgrading…"
      heading in [Unreleased]); README.md is skipped;
    * content: one or more top-level bullets ("- "), every further line
      indented under its bullet (fences too), no line starting with "#" —
      the file name selects the heading.
    Before the roll every fragment is appended, in file-name order, at the end
    of its heading inside [Unreleased]; a missing heading is inserted in Keep
    a Changelog order, a duplicated heading (a rebase of sibling entries) is
    merged into its first occurrence, and a missing [Unreleased] heading is
    created. Any other entry in changelog.d/ refuses the whole run, nothing
    written. The fragments are deleted only after CHANGELOG.md is written;
    --dry-run lists them and deletes nothing; --check-unreleased reports
    has-content while fragments wait. Without fragments (no directory, or only
    README.md) the output is byte-identical to a run without this feature.

Exit codes: 0 = rolled (or clean --dry-run), 1 = refused; the file is never
partially written (temp file + atomic replace).
"""

import argparse
import datetime
import itertools
import os
import re
import sys
import tempfile
import textwrap

# `\[Unreleased\]` is the same heading with escaped brackets, valid Markdown
# that some formatters emit; missing it would seed a second heading above it.
UNRELEASED_RE = re.compile(r"^##\s+\\?\[?unreleased\\?\]?\s*$", re.IGNORECASE)
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
# First-column lines that interrupt a paragraph (CommonMark): a thematic break,
# a setext underline, a blockquote, a "*" or "+" bullet, an ordered item
# starting at 1, an HTML block. Each ends a fragment's list.
INTERRUPT_RE = re.compile(
    r"^(?:([*_-])[ \t]*(?:\1[ \t]*){2,}$|=+[ \t]*$|-+[ \t]*$|>|[*+](?:[ \t]|$)|1[.)](?:[ \t]|$)|<)"
)
# A "## " heading without a version ("## Prior history") is no release.
VERSION_RE = re.compile(r"\d\.\d")
# Newest released heading, one regex per shape. Order matters: the linked form
# also starts with "## [" and must win over plain bracketed.
LINKED_RE = re.compile(
    r"^##\s+\[(?P<tag>[^\]]+)\]\((?P<url>[^)]+)\)\s+(?P<dash>[-—–])\s+(?P<date>.+?)\s*$"
)
BRACKETED_RE = re.compile(
    r"^##\s+\[(?P<tag>[^\]]+)\]\s+(?P<dash>[-—–])\s+(?P<date>.+?)\s*$"
)
BARE_PAREN_RE = re.compile(r"^##\s+(?P<tag>\S+)\s+\((?P<date>[^)]+)\)\s*$")
BARE_DASH_RE = re.compile(
    r"^##\s+(?P<tag>v?\d[^\s\[\]]*)\s+(?P<dash>[-—–])\s+(?P<date>\S+)\s*$"
)
# The version alone, no date: "## 1.14.1" or "## v2.0.0". Last, so every form
# with a date or brackets wins; trailing words stay an unknown shape.
BARE_VERSION_RE = re.compile(r"^##\s+(?P<tag>v?\d+\.\d[^\s\[\]()]*)\s*$")
# Fragment type -> heading, in Keep a Changelog order; "upgrading" is resolved
# per file (see upgrading_heading). Same table and name pattern as the TYPO3
# extensions' collector (bin/changelog-fragments in netresearch/typo3-ci-
# workflows), so one changelog.d/ convention holds across the org; the content
# checks differ in detail.
FRAGMENT_SECTIONS = {
    "upgrading": None,
    "added": "### Added",
    "changed": "### Changed",
    "deprecated": "### Deprecated",
    "removed": "### Removed",
    "fixed": "### Fixed",
    "security": "### Security",
}
UPGRADING = "### Upgrading"
FRAGMENT_NAME_RE = re.compile(
    r"^[a-z0-9][a-z0-9._-]*\.(" + "|".join(FRAGMENT_SECTIONS) + r")\.md$"
)
# A keep-a-changelog link-reference definition ends [Unreleased] when no
# released heading follows it (first release).
LINK_DEF_RE = re.compile(r"^\[[^\]]+\]: \S")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def closes(fence, m):
    """True when the FENCE_RE match m closes the fence opened with fence: the
    same character, at least as long, nothing but whitespace after it
    (CommonMark). A shorter run or a line like "```python" is content."""
    marker = m.group(1)
    return (
        marker[0] == fence[0] and len(marker) >= len(fence) and not m.group(2).strip()
    )


def scan(lines):
    """Yield (index, line, in_fence) tracking fenced code blocks."""
    fence = None
    for i, line in enumerate(lines):
        m = FENCE_RE.match(line)
        if m:
            marker = m.group(1)
            if fence is None:
                fence = marker
            elif closes(fence, m):
                fence = None
            yield i, line, True
            continue
        yield i, line, fence is not None


def retag(old_tag: str, version: str) -> str:
    """`version` in the tag style of `old_tag`: with a leading v or without."""
    return f"v{version}" if old_tag.startswith("v") else version


def released_heading(version: str, sample: str, date: str) -> str:
    """Reproduce the shape of `sample` (a released heading) for `version`."""
    m = LINKED_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = retag(old_tag, version)
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
        new_tag = retag(old_tag, version)
        return f"## [{new_tag}] {m.group('dash')} {date}"
    m = BARE_PAREN_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = retag(old_tag, version)
        return f"## {new_tag} ({date})"
    m = BARE_DASH_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = retag(old_tag, version)
        return f"## {new_tag} {m.group('dash')} {date}"
    m = BARE_VERSION_RE.match(sample)
    if m:
        old_tag = m.group("tag")
        new_tag = retag(old_tag, version)
        return f"## {new_tag}"
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
        default=datetime.datetime.now(datetime.UTC).astimezone().date().isoformat(),
        help="release date (default: today, ISO 8601)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the new heading and moved-section size, write nothing",
    )
    parser.add_argument(
        "--seed-entry",
        metavar="TEXT",
        help="put TEXT as a '### Changed' bullet into Unreleased before rolling, "
        "creating the heading when the file has none; an existing section keeps "
        "its entries and TEXT is added once. For a release whose content is a "
        "statement rather than a change — the 0.x -> 1.0.0 stabilization, where "
        "the promise has to be in the changelog and nothing else is new",
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
    """Return (unreleased_index, end, first_released) or refuse: exactly one
    Unreleased heading outside code fences, and no released heading above it.
    end is the next "## " heading (or EOF); first_released is the first one
    below it that carries a version, the shape the new heading copies."""
    unreleased_at = []
    headings = []  # (index, line) of every other "## " heading
    for i, line, in_fence in scan(lines):
        if in_fence:
            continue
        if UNRELEASED_RE.match(line):
            unreleased_at.append(i)
        elif line.startswith("## "):
            headings.append((i, line))
    if len(unreleased_at) != 1:
        fail(
            f"{len(unreleased_at)} Unreleased headings outside code fences "
            f"(need exactly 1)"
        )
    idx = unreleased_at[0]
    end = next((i for i, _ in headings if i > idx), len(lines))
    first_released = next(
        (h for h in headings if h[0] < idx or VERSION_RE.search(h[1])), None
    )
    if first_released is not None and first_released[0] < idx:
        fail(
            f"a released heading (line {first_released[0] + 1}) precedes the "
            f"Unreleased heading (line {idx + 1}) — refusing to roll a "
            f"non-standard layout"
        )
    return idx, end, first_released


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


def seed_unreleased(lines, text):
    """Return lines with `- text` under a '### Changed' in Unreleased.

    Creates the Unreleased heading above the first released heading when the
    file has none (after the title block otherwise), joins an existing
    '### Changed' subsection rather than opening a second one (MD024), and is
    a no-op when the bullet is already there. Fence-aware like every scan here.
    """
    width = wrap_width(lines)
    bullet_lines = (
        textwrap.wrap(
            text,
            width=width,
            initial_indent="- ",
            subsequent_indent="  ",
            break_long_words=False,
            break_on_hyphens=False,
        )
        if width
        else [f"- {text}"]
    )
    wanted = " ".join(f"- {text}".split())
    lines, unreleased = ensure_unreleased(lines)
    # Only lines outside fences count: a fenced example holding "### Changed"
    # or the bullet itself must neither receive the promise nor suppress it.
    visible = [(i, line) for i, line, f in scan(lines) if not f and i > unreleased]
    end = next((i for i, line in visible if line.startswith("## ")), len(lines))
    section = [(i, line) for i, line in visible if i < end]
    # Compare the whitespace-collapsed section text, so a promise already
    # present in wrapped form is recognized as well as a one-line one.
    if wanted in " ".join(" ".join(line for _, line in section).split()):
        return lines
    changed = next((i for i, line in section if line.strip() == "### Changed"), None)
    if changed is not None:
        # first line after the subsection heading and its blank line
        at = changed + 1
        while at < end and not lines[at].strip():
            at += 1
        lines[at:at] = bullet_lines
    else:
        lines[unreleased + 1 : unreleased + 1] = ["", "### Changed", ""] + bullet_lines
    return lines


def ensure_unreleased(lines):
    """Return (lines, index of the Unreleased heading), creating the heading
    above the first released heading (after the title block otherwise) when
    the file has none. Fence-aware like every scan here."""
    unreleased = None
    first_heading = None
    for i, line, in_fence in scan(lines):
        if in_fence:
            continue
        if UNRELEASED_RE.match(line):
            unreleased = i
            break
        if first_heading is None and line.startswith("## "):
            first_heading = i
    lines = list(lines)
    if unreleased is None:
        at = first_heading if first_heading is not None else len(lines)
        block = ["## [Unreleased]", ""]
        if at == len(lines) and lines and lines[-1].strip():
            block = [""] + block
        lines[at:at] = block
        unreleased = at if block[0] else at + 1
    return lines, unreleased


def read_fragments(changelog_path):
    """Return (directory, fragments) for changelog.d/ next to the CHANGELOG.

    fragments is a list of (path, type, text_lines) in file-name order. No
    directory, an empty one or one holding only README.md gives []. Every
    other entry must be a regular file named <branch-slug>.<section>.md whose
    content starts with a top-level bullet and has no line starting with "#";
    any violation refuses the run with every problem listed, nothing written.
    """
    directory = os.path.join(
        os.path.dirname(os.path.abspath(changelog_path)), "changelog.d"
    )
    if os.path.islink(directory):
        # A symlink would let the deletion after the roll reach files outside
        # the repository the script was pointed at.
        fail(f"{directory} is a symlink — refusing to collect or delete through it")
    if not os.path.isdir(directory):
        return directory, []
    try:
        names = sorted(os.listdir(directory))
    except OSError as exc:
        fail(str(exc))
    problems = []
    fragments = []
    for name in names:
        if name == "README.md":
            continue
        path = os.path.join(directory, name)
        m = FRAGMENT_NAME_RE.match(name)
        if not m or os.path.islink(path) or not os.path.isfile(path):
            problems.append(
                f"  {name}  is not a file named <branch-slug>.<{'|'.join(FRAGMENT_SECTIONS)}>.md"
            )
            continue
        try:
            with open(path, encoding="utf-8", newline="") as fh:
                text = fh.read().replace("\r\n", "\n").strip()
        except (OSError, UnicodeDecodeError) as exc:
            problems.append(f"  {name}  cannot be read: {exc}")
            continue
        if not text.startswith("- "):
            problems.append(f'  {name}  must start with a top-level bullet ("- ")')
            continue
        text_lines = text.split("\n")
        if any(line.startswith("#") for line in text_lines):
            problems.append(
                f"  {name}  must not contain a heading; the file name selects the heading"
            )
            continue
        if stray_text(text_lines):
            problems.append(
                f"  {name}  has text outside a top-level bullet; indent it under its bullet"
            )
            continue
        if fence_open(text_lines):
            # An open fence would swallow every heading below the fragment
            # once it sits in the CHANGELOG, and the roll would misplace the
            # release history.
            problems.append(f"  {name}  has a code fence that is not closed")
            continue
        fragments.append((path, m.group(1), text_lines))
    if problems:
        fail(
            "changelog.d/ is not ready:\n"
            + "\n".join(problems)
            + "\nSee changelog.d/README.md for the format."
        )
    return directory, fragments


def fence_open(lines):
    """True when a fenced code block opened in lines is still open at the end."""
    fence = None
    for line in lines:
        m = FENCE_RE.match(line)
        if not m:
            continue
        if fence is None:
            fence = m.group(1)
        elif closes(fence, m):
            fence = None
    return fence is not None


def stray_text(lines):
    """True when a line starts in column 0 without "- " where Markdown ends the
    list: it opens a fence, sits inside one, interrupts a paragraph
    (INTERRUPT_RE), or follows anything but paragraph text (a blank line, a
    fence). It would land in the CHANGELOG outside the entry. Other text right
    after paragraph text is the bullet's lazy continuation."""
    fence, para = None, False
    for line in lines:
        m = FENCE_RE.match(line)
        stop = INTERRUPT_RE.match(line)
        col0 = line[:1] not in ("", " ", "\t") and (stop or not line.startswith("- "))
        if col0 and (m or stop or fence is not None or not para):
            return True
        if m and fence is None:
            fence = m.group(1)
        elif m and closes(fence, m):
            fence = None
        para = not m and fence is None and bool(line.strip())
    return False


def collect_fragments(lines, fragments):
    """Return lines with every fragment appended at the end of its heading in
    [Unreleased].

    The section is split into blocks at its '### ' headings (outside fences).
    A duplicated heading is folded into its first occurrence; a fragment goes
    to the end of its heading's block, in the same list when the block ends
    with a list item (see join_entries); a missing
    heading is inserted before the first heading that follows it in Keep a
    Changelog order, or at the end of the section. Text above the first
    '### ' stays on top. The section ends at the next '## ' heading or at a
    link-reference definition.
    """
    lines, idx = ensure_unreleased(lines)
    visible = [(i, line) for i, line, f in scan(lines) if not f]
    if sum(1 for _, line in visible if UNRELEASED_RE.match(line)) != 1:
        fail("more than one Unreleased heading outside code fences (need exactly 1)")
    end = next(
        (
            i
            for i, line in visible
            if i > idx and (line.startswith("## ") or LINK_DEF_RE.match(line))
        ),
        len(lines),
    )
    starts = [i for i, line in visible if idx < i < end and line.startswith("### ")]
    preamble = lines[idx + 1 : starts[0] if starts else end]
    blocks = []  # [head, [body lines]]
    for n, s in enumerate(starts):
        head = lines[s].rstrip()
        body = strip_blank_edges(
            lines[s + 1 : starts[n + 1] if n + 1 < len(starts) else end]
        )
        same = next((b for b in blocks if b[0] == head), None)
        if same is None:
            blocks.append([head, body])
        elif body:
            same[1] = join_entries(same[1], body)

    upgrading = upgrading_heading(lines, [b[0] for b in blocks])

    def heading_of(kind):
        return FRAGMENT_SECTIONS[kind] or upgrading

    def rank(head):
        for n, kind in enumerate(FRAGMENT_SECTIONS):
            if head == heading_of(kind) or (
                kind == "upgrading" and head.startswith(UPGRADING)
            ):
                return n
        return None

    for _path, kind, text_lines in fragments:
        heading = heading_of(kind)
        block = next((b for b in blocks if b[0] == heading), None)
        if block is None:
            want = rank(heading)
            at = next(
                (
                    n
                    for n, b in enumerate(blocks)
                    if rank(b[0]) is not None and rank(b[0]) > want
                ),
                len(blocks),
            )
            block = [heading, []]
            blocks.insert(at, block)
        block[1] = join_entries(block[1], text_lines)

    out = lines[: idx + 1]
    preamble = strip_blank_edges(preamble)
    if preamble:
        out += [""] + preamble
    for head, body in blocks:
        out += ["", head]
        if body:
            out += [""] + body
    tail = lines[end:]
    if tail:
        out += [""] + tail
    return out


def join_entries(body, text_lines):
    """Append a fragment's bullets to a heading's body.

    Directly after a list item (or its indented continuation) the bullets join
    the same list: a blank line between two items makes the whole list loose,
    and it renders with a paragraph gap between every entry. After any other
    text a blank line separates them (MD032).
    """
    if not body:
        return list(text_lines)
    last = body[-1]
    first = text_lines[0] if text_lines else ""
    in_list = last.startswith(("- ", "* ")) or (last.startswith("  ") and last.strip())
    if in_list and first.startswith(("- ", "* ")):
        return body + list(text_lines)
    return body + [""] + list(text_lines)


def strip_blank_edges(block):
    block = list(block)
    while block and not block[0].strip():
        block.pop(0)
    while block and not block[-1].strip():
        block.pop()
    return block


def upgrading_heading(lines, heads):
    """The heading an 'upgrading' fragment lands under: an existing
    '### Upgrading…' heading in [Unreleased] (the last one), else
    '### Upgrading from X.Y' with X.Y from the newest released heading of any
    of the seven shapes, else '### Upgrading'."""
    found = [h for h in heads if h.startswith(UPGRADING)]
    if found:
        return found[-1]
    labels = released_labels(lines)
    if labels:
        m = re.match(r"^(\d+\.\d+)", labels[0].removeprefix("v"))
        if m:
            return f"{UPGRADING} from {m.group(1)}"
    return UPGRADING


def wrap_width(lines):
    """Width to wrap a generated bullet at, or None to keep it on one line.

    A file whose list items continue on indented lines is hard-wrapped; a
    bullet longer than its widest line would break the line-length limit the
    file already meets (markdownlint MD013 in CI). Such a file gets the width
    of its widest non-fenced line; a file of one-line bullets gets None.
    """
    visible = [line for _, line, in_fence in scan(lines) if not in_fence]
    wrapped = any(
        prev.lstrip().startswith(("- ", "* ")) and re.match(r"^ {2,}\S", line)
        for prev, line in itertools.pairwise(visible)
    )
    if not wrapped:
        return None
    return max(len(line) for line in visible)


def main() -> None:
    args = parse_args()
    if args.check_unreleased:
        lines, _eol, _tn = read_changelog(args.file)
        state = unreleased_state(lines)
        # Waiting fragments are content: the roll collects them first, and
        # creates a missing Unreleased heading to hold them.
        _dir, fragments = read_fragments(args.file)
        print("has-content" if fragments else state)
        return
    version = args.version
    lines, eol, trailing_newline = read_changelog(args.file)
    if args.seed_entry:
        lines = seed_unreleased(lines, args.seed_entry.strip())
    fragment_dir, fragments = read_fragments(args.file)
    if fragments:
        # Checked before the write: a fragment that survives a written roll
        # would be collected a second time by the next one.
        if not args.dry_run and not os.access(fragment_dir, os.W_OK | os.X_OK):
            fail(
                f"{fragment_dir} is not writable — the fragments could not be removed after the roll"
            )
        lines = collect_fragments(lines, fragments)
    idx, end, first_released = locate_headings(lines)

    if first_released is None:
        # First release: no shape to copy. The [Unreleased] bracket implies
        # keep-a-changelog, so default to its bracketed-dash form.
        new_heading = f"## [{version}] - {args.date}"
    else:
        new_heading = released_heading(version, first_released[1], args.date)

    # The section to be rolled must contain content — and HTML comments are
    # not content: rolling a comment-only section would ship a visually empty
    # release.
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
    if fragments:
        names = [f"changelog.d/{os.path.basename(path)}" for path, _k, _t in fragments]
        if args.dry_run:
            for name in names:
                print(f"would collect: {name}")
            return
        kept = []
        for path, _kind, _text in fragments:
            try:
                os.remove(path)
            except OSError:
                kept.append(path)
        if kept:
            fail(
                f"{args.file} now holds the fragments, but {len(kept)} could not be "
                "deleted. Delete them before the next run, or it adds their entries "
                "again:\n  " + "\n  ".join(kept)
            )
        print(f"collected {len(names)} fragment(s): {', '.join(names)}")


def released_labels(lines):
    """Tag labels of every released heading, document order, fences skipped.

    The compare base for a new release is the heading directly below it, not
    whatever [Unreleased] happened to point at — see update_link_reference_
    definitions.
    """
    labels = []
    for _, line, in_fence in scan(lines):
        if in_fence:
            continue
        for rx in (
            LINKED_RE,
            BRACKETED_RE,
            BARE_PAREN_RE,
            BARE_DASH_RE,
            BARE_VERSION_RE,
        ):
            m = rx.match(line)
            if m:
                labels.append(m.group("tag"))
                break
    return labels


def styled_tag(label, v_prefixed):
    """Render `label` in the tag style the link definitions already use."""
    bare = label.removeprefix("v")
    return f"v{bare}" if v_prefixed else bare


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
        v_prefixed = old.startswith("v")
        new_tag = f"v{version}" if v_prefixed else version
        base = stem[: old_m.start()]

        # The compare base comes from the HEADINGS, not from [Unreleased].
        # [Unreleased] can be stale — an earlier roll that skipped a definition
        # leaves it pointing several releases back, and inheriting it spans the
        # new release across all of them (matrix-skill shipped
        # v3.1.1...v3.1.3 that way).
        labels = released_labels(new_lines)
        head_label = head_m.group("label")
        prev_label = labels[1] if len(labels) > 1 else None
        prev_tag = styled_tag(prev_label, v_prefixed) if prev_label else old

        new_lines[i] = f"[{m.group('label')}]: {base}{new_tag}...HEAD"
        new_lines.insert(i + 1, f"[{head_label}]: {base}{prev_tag}...{new_tag}")

        # A previous release with no definition of its own is what let the
        # stale base survive in the first place; write it while we can still
        # see the version below it.
        note = f"updated link-reference definitions ([Unreleased] -> {new_tag}...HEAD)"
        if prev_label is not None and len(labels) > 2:
            # Compared without the v prefix: a file may head its sections
            # `## [v3.1.2]` while defining `[3.1.2]:`. A raw match would call
            # the existing definition missing and add a second one under the
            # other spelling.
            want = prev_label.removeprefix("v")
            have_prev = any(
                ln.split("]:", 1)[0][1:].removeprefix("v") == want
                for ln in new_lines
                if ln.startswith("[") and "]:" in ln
            )
            if not have_prev:
                prev2_tag = styled_tag(labels[2], v_prefixed)
                new_lines.insert(
                    i + 2, f"[{prev_label}]: {base}{prev2_tag}...{prev_tag}"
                )
                note += f"; backfilled the missing [{prev_label}] definition"
        return note
    return None


if __name__ == "__main__":
    main()
