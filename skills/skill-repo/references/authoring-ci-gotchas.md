# Authoring & CI Gotchas

## Contents

- Word-budget-first authoring
- macOS / BSD portability for shell **and** test scripts
- Lint without dirtying the worktree
- "Skill Validation" can run more than once — wait for all of it
- Installing the Claude Code CLI with `--ignore-scripts`
- Generated YAML: exactly one trailing newline
- `MD010` breaks copy-pasted Makefile snippets — exempt the fence, don't fake the tab
- A validator over a structured value parses it; it does not pattern-match it
- SonarCloud's `shelldre` rules fire on our own shell conventions — triage, don't comply
- `uv pip compile --universal` drops marker-conditional deps — pin the floor
- A Renovate regex manager fails silently in both directions
- A SAST job's interpreter bounds what it scans, and says nothing
- A new script is committed `100755`, not just `chmod +x` locally

Process learnings from a cross-session retrospective (2026-06-27). Companion to
[`skill-quality.md`](skill-quality.md) (SKILL.md sizing) and the
[`validation-checklist.md`](validation-checklist.md) (pre-completion checks).
Each item is a habit that prevents a costly redo, not a structural rule.

## 1. Word-budget-first authoring

This repo enforces a **hard 500-word cap on `SKILL.md`** (`scripts/validate-skill.sh`
fails above 500; this repo's SKILL.md sits at ~495). The body also persists in context
for the whole session, so every word is paid on each invocation — see
[`skill-quality.md`](skill-quality.md) for the full cost model.

**Before editing an existing `SKILL.md`, `wc -w` it first.** If it is already near
the ceiling, decide the **architecture before you type**:

- new content that is a lookup/detail → a `references/*.md` file (lazy-loaded, free
  until cited),
- a genuinely separate capability → a new standalone skill,
- only then, prose edits to the body itself.

Do **not** open by iteratively trimming the maintainer's existing prose to free up
room. In a real 2026-06-27 case that approach burned ~7 edit cycles shaving words off
carefully-written copy before the obvious move — put the addition in a reference file
and add one catalog line — was taken. Architecture decision first, word-shaving last
(and rarely).

## 2. macOS / BSD portability for shell **and** test scripts

This repo's CI matrix runs on macOS, not just Linux: `validate-agents.yml` defaults its
`os-matrix` to `["ubuntu-latest", "macos-latest"]`. Any `*.sh` (and any test script the
workflows execute) therefore has to be **BSD/macOS-portable**, not just GNU-portable.

The classic trap a reviewer flagged: **`sed -i` is GNU-only.** BSD `sed` (macOS) requires
an explicit empty backup-suffix argument:

```sh
sed -i 's/a/b/' file      # GNU only — fails on macOS
sed -i '' 's/a/b/' file   # BSD only — fails on GNU
```

Prefer a form that needs no in-place flag at all, e.g. write to a temp file and move it,
or use `perl -i -pe`. This complements the portability notes already in `SKILL.md`
(`grep -E` not `-P`; `bash` shebangs not `zsh`; `[[ ]]` conditionals). If the CI matrix
ever drops macOS these become Linux-only conveniences again — verify the matrix before
relying on a GNU-ism.

## 3. Lint without dirtying the worktree

Running the JS-based linters locally (e.g. `bunx markdownlint-cli2`) can make `bun`
resolve and **write a lockfile**, emitting `Saved lockfile` and leaving the working tree
dirty — exactly when you are about to commit or merge and want a clean status.

Run a frozen/no-save install first so the lint step touches nothing:

```sh
bun install --frozen-lockfile   # then run the linter
# or invoke the linter in a no-save mode
```

(CI itself runs markdownlint via the pinned `markdownlint-cli2-action`, so this is a
**local-authoring** hygiene step — keep the pre-commit / pre-merge `git status` clean.)

## 4. "Skill Validation" can run more than once — wait for all of it

The skill-validation gate can surface as **more than one run/check context** for a single
PR (this repo wires it through the reusable `validate.yml`, and `lint.yml` triggers on
both `push` to `main` and `pull_request`; reusable-workflow nesting can add further
contexts). A lagging second instance can keep a PR `BLOCKED` for a short while **after
the first one has already gone green**.

Before concluding the gate is stuck, confirm **every** validation run/check has reported
— `gh pr checks <n>` — rather than acting on the first green. Re-running or "fixing" a gate
that is merely still finishing wastes a round-trip.

## 5. Installing the Claude Code CLI with `--ignore-scripts`

Security scanners (SonarCloud `githubactions:S6505`) require the
`--ignore-scripts` flag on `npm install` in workflows — but that breaks
`@anthropic-ai/claude-code`, whose **postinstall downloads the platform-native
binary**; the CLI then exits with "claude native binary not installed". The package documents its own
sanctioned two-step (verified with 2.1.206):

```bash
npm install -g --ignore-scripts @anthropic-ai/claude-code@<pinned-version>
node "$(npm root -g)/@anthropic-ai/claude-code/install.cjs"
claude --version   # proves the binary is in place
```

This blocks lifecycle scripts of the whole dependency tree while running only
the CLI's own vetted installer, explicitly.

## 6. Generated YAML: exactly one trailing newline

The reusable `validate.yml` runs yamllint, whose **default config** (`extends:
default`, `empty-lines: max-end: 0`) rejects trailing blank lines; the workflow
writes that default only when the repo ships no `.yamllint*` of its own, so a
repo config can override it — most skill repos don't. Batch-generated YAML
(heredoc, `echo`, templating) routinely picks up a trailing blank line. One deploy of `auto-merge-deps.yml` across
22 repos failed CI in every one of them on exactly this.

When writing YAML programmatically, emit the content with a single trailing
newline and verify before committing:

```bash
printf '%s\n' "$CONTENT" > file.yml     # not: echo "$CONTENT" > file.yml
tail -c 2 file.yml | xxd -p             # must NOT be 0a0a
```

## 7. `MD010` breaks copy-pasted Makefile snippets — exempt the fence, don't fake the tab

A ` ```makefile ` fenced block showing a real recipe line needs a literal tab —
`make` rejects a space there with `*** missing separator. Stop.` But
markdownlint's `MD010` (no-hard-tabs) flags a hard tab **inside a fenced code
block by default**, not just in prose. Substituting a single leading space to
keep the linter quiet (observed in a skill repo's own docs, twice, across two
separate snippets) produces a snippet that reads clean but silently fails the
moment someone copies it into a real `Makefile`.

The fix is a linter exemption, not a fake tab:

```jsonc
// .markdownlint-cli2.jsonc — add the key to the EXISTING "config" object.
// A separate .markdownlint.jsonc file does not merge with .markdownlint-cli2.jsonc's
// "config" — it replaces it wholesale, silently re-enabling every other rule this
// repo already disables there (MD013, MD033, etc.).
{
  "config": {
    "MD010": { "ignore_code_languages": ["makefile"] }
    // ...alongside this repo's other existing "config" entries
  }
}
```

This keeps `MD010` enforcing real prose/other-language blocks while letting a
` ```makefile ` fence carry an actual, pastable tab. Verify the fix reproduces
correctly before trusting it — write the fenced snippet to a scratch file and
run `make -n -f <scratch-file>` against it (`-n` alone silently looks for
`Makefile`/`makefile`/`GNUmakefile` in the current directory and ignores an
arbitrarily named scratch file); a `make` that resolves the target confirms
the tab survived, a lint pass alone does not.

---

## 8. A validator over a structured value parses it; it does not pattern-match it

A check added to `validate-skill.sh` read `allowed-tools` with one anchored
`grep`. It went through four review rounds, and each one found another **legal
spelling of the same value** the pattern did not anticipate:

| Round | Spelling that slipped past |
|---|---|
| 1 | folded scalar `>-`, and the YAML list form — the check read only the key line |
| 2 | a blank line inside the value, which ended collection; `Bash,Read` and `"Bash"`, where the boundary was whitespace-only |
| 3 | a YAML comment mentioning what it does *not* grant, matched as if it did |
| 4 | flow list `[Bash]`, where `]` was not a delimiter |

Widening the pattern each round buys one shape. The signal that the *approach*
is wrong rather than incomplete is the repetition itself: the value never
changed, only its spelling.

What worked was taking the value apart instead:

1. **Collect** the key line plus every continuation, ending only at a new
   top-level key — so a blank line inside a folded scalar keeps the value open.
2. **Drop** comment lines and everything after a space-`#`, which is where a YAML
   comment starts. Anchoring on `[^)]*$` here fails on a comment that contains
   a parenthesis, which is exactly what a comment about `Bash(python3:*)` does.
3. **Split** on whitespace, comma, bracket and quote — but only at parenthesis
   depth 0, so `Bash(git:*,make:*)` stays one entry and
   `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)` survives its space.
4. **Match each entry on its own**, anchored.

`[Bash]` then falls out without a special case, because the bracket is a
delimiter like any other. Two of the four rounds also broke *existing* passing
tests when the split was naive — the suite is what caught it, so write the
shape cases (plain, folded, literal, block list, flow list, comma-separated,
quoted, commented) before widening anything.

## 9. SonarCloud's `shelldre` rules fire on our own shell conventions — triage, don't comply

Every skill repo here is mostly shell and Python and runs SonarCloud, so a PR
touching one script reliably reports a dozen new MAJOR code smells while the
quality gate passes. The count is alarming and the content is not: on
git-workflow-skill#300, sixteen new issues over a 96-line diff were
`shelldre:S7688` (use `[[` instead of `[`), `shelldre:S7679` (assign positional
parameters to local variables) and one `shelldre:S7682` (add an explicit
`return` at the end of the function).

The first two are house style, not drift. `pr-status.sh` uses `[` twenty-one
times and `[[` not once, and the `check`/`check_contains` helpers are copied
verbatim between test files. "Fixing" four new lines makes them the only ones of
their kind in the file, which is worse than the finding.

`S7682` is the one to read rather than skim, because complying with it can
introduce the bug:

```bash
collect_raw() {
  gh api graphql -f owner="$OWNER" … -f query='…'
}        # no explicit return: the function's status IS gh's status
```

The caller reads that status (`out=$(collect_raw 2>"$err"); rc=$?`) to tell a
failed query from a successful one. `return 0` there would report every failure
as a success — precisely the defect that PR was fixing. Adding `return $?` is a
no-op that satisfies a linter and says nothing.

So: read what the rule asks against what the code promises, resolve the
intentional ones in the SonarCloud UI rather than contorting the code, and say
in the PR which findings stand and why. A reviewer seeing "16 new issues" with
no explanation has to re-derive that triage themselves.

Pick the status by what is actually true of the finding — these are ordinary
issues (`type: CODE_SMELL` from `api/issues`), not Security Hotspots, which live
on their own endpoint with their own `Safe` / `Fixed` / `Acknowledged` review:

- **Accept** — the rule read the code correctly and we are keeping it anyway.
  That is the house-style case, `S7688` and `S7679` above.
- **False positive** — the analysis itself does not hold. `S7682` on a function
  whose exit status is its contract belongs here: the rule's premise, that a
  missing `return` is an oversight, is wrong for that function.

`Safe` is not available for either; reaching for it means you are in the
hotspot review by mistake.

## 10. `uv pip compile --universal` drops marker-conditional deps — pin the floor

`--universal` is not "resolve for every Python". It resolves from the running
interpreter's version upward, so a dependency whose environment marker excludes
that version is omitted from the lock entirely — silently, with exit 0.

The omission surfaces where the lock is *consumed*, not where it is written. Our
hash-locked tool envs install with `--require-hashes`, and pip refuses the whole
file rather than the one line:

```
ERROR: In --require-hashes mode, all requirements must have their versions
pinned with ==. These do not:
    typing_extensions<5.0,>=4.6 ... (from cyclonedx-python-lib==11.11.0)
```

`cyclonedx-python-lib` declares `typing_extensions ; python_version < "3.13"`.
Compiled on 3.14 the marker excludes it and the entry is never written; the
audit job runs on the runner's default `python3` (3.12), which needs it. Compile
and install therefore disagree, and only the install fails.

Pass the floor the consumer actually runs on:

```bash
uv pip compile --universal --generate-hashes --python-version 3.12 \
  requirements.in -o .github/requirements/pip-audit.txt
```

Two things follow. **The compile command belongs in a comment next to the file
it produces, with the floor in it** — ours said only
`uv pip compile --universal --generate-hashes`, so following it on a newer
machine reproduced the defect. And because this is shared CI, one stale lock
fails the job in every consuming repo at once; it presents as one repo's red
check, since the others have not run since.

Verify on the consumer's interpreter, not yours:

```bash
python3.12 -m venv /tmp/probe
/tmp/probe/bin/pip install --dry-run --require-hashes --only-binary :all: \
  -r .github/requirements/pip-audit.txt
```

## 11. A Renovate regex manager fails silently in both directions

A `customManagers` entry pins ad-hoc tool versions in workflow files
(`uvx ruff@0.16.0`, `uv run --with pyyaml==6.0.3`) so Renovate opens a PR when
they move. Both of its failure modes are invisible, because **"no dependency
found here" and "nothing to update here" produce the same output: none.**

*It stops matching.* Ours was written against `uvx <name>@<version>` with an
optional `--from <x>` in front. Sixteen minutes later another commit hardened
the pin to `uvx --no-build ruff@0.16.0`, and the pattern matched nothing from
then on. The pin sat unmoved for seven weeks while ruff released eight versions,
and nothing reported it — the repository looked up to date.

*It matches the wrong token.* Widening the prefix to "any word may stand here"
fixed that and broke the other direction: under a `datasource=pypi` comment,
`uvx --from git+https://github.com/o/r@2843b87 tool` yields `2843b87` as the
PyPI version of the package the comment names.

Three habits follow.

**Run the pattern against the real file after every change to an annotated
command line, and check the count.** One call, and it distinguishes the two
states the tool cannot:

```bash
python3 - <<'PY'
import json, re, pathlib
pat = json.loads(pathlib.Path("renovate.json").read_text())["customManagers"][0]["matchStrings"][0]
text = pathlib.Path(".github/workflows/validate.yml").read_text()
print([m.group("currentValue") for m in re.finditer(pat.replace("(?<", "(?P<"), text)])
PY
```

**Shape the pinned token, not the prefix.** `[A-Za-z][A-Za-z0-9._-]*@` is a
package name; `\S+@` is also a URL. Because the repeat consumes whole
space-separated words, a name can only begin where a word begins, so the `cli@`
inside `git+https://…/cli@2843b87` is not a candidate and a `--from <source>` is
excluded without enumerating the tool's flags. That matters: **Renovate runs the
pattern through RE2, which has no lookahead**, so a flag allow-list would have to
exclude the value-taking flags from its own generic branch to be safe.

**Pin both directions in a test.** A case list that only asserts what *must*
match cannot catch the second failure. Assert the shapes that must yield nothing
as well, and note in the test that translating `(?<name>` to `(?P<name>` for
Python's `re` is evidence about the pattern, not about RE2 — the proof for that
half is the bump PR Renovate opens.

## 12. A SAST job's interpreter bounds what it scans, and says nothing

`python3 -m venv` in a CI job takes the runner image's interpreter. On
`ubuntu-latest` that is 3.12.3 today — for most repositories the **oldest**
version their matrix tests, not the newest. Bandit parses with the `ast` of the
interpreter it runs on, and a file it cannot parse is skipped with a warning
while the run still exits 0. The gate reports clean instead of reporting that it
scanned nothing.

Measured with bandit 1.9.4 on one file holding a PEP 696 type-parameter default
and a shell-injection finding under it:

| Interpreter | Result |
|---|---|
| 3.12.14 | `Files skipped (1): syntax error while parsing AST` · exit 0 · no `B602` |
| 3.14.7 | `B602 subprocess call with shell=True` · exit 1 |

```python
import subprocess


class Box[T = int]:  # PEP 696, 3.13+
    def run(self, cmd: str) -> None:
        subprocess.call(cmd, shell=True)  # B602
```

So derive the interpreter from what the caller tests rather than inheriting it,
and assert the venv landed on it — a venv on the wrong interpreter runs fine and
scans less:

```bash
BANDIT_PYTHON="$(printf '%s' "$PYTHON_VERSIONS" \
  | jq -r 'max_by(split(".") | map(gsub("[^0-9]";"") | tonumber? // 0))')"
uv python install "$BANDIT_PYTHON"
uv venv --seed --python "$BANDIT_PYTHON" "$RUNNER_TEMP/bandit-env"
"$RUNNER_TEMP/bandit-env/bin/python" -V
```

Two details that cost a round each. `--seed` is what puts a pip into the venv,
which is what reads a hash-locked requirements file under `--require-hashes`
(§10's lock installs unchanged on a newer interpreter — verify, do not assume).
And `gsub` before `tonumber`: a caller may test a free-threaded build (`3.13t`),
where a bare `tonumber` aborts the job. Compare on the digits and install the
value as written — then compare the assertion on the numeric prefix too, since
`python -V` answers `Python 3.13.x` for a `3.13t` request.

## 13. A new script is committed `100755`, not just `chmod +x` locally

ruff's `EXE001` fails the build on a file that carries a shebang and is committed
`100644`, and a local ruff run does not reproduce it — the mode in the index is
what CI reads. `validate-skill.sh` catches it with the exact fix, but only after
a push, so the cheap moment is when the file is created:

```bash
chmod +x path/to/new-script.py && git update-index --chmod=+x path/to/new-script.py
```

Worth the one line: this cost two separate CI rounds in a single session, once on
a maintainer's PR and once on a contributor's, both on freshly added test
scripts. Drop the shebang instead where the file is genuinely only imported — a
module is not a script, and making it executable settles the mismatch from the
wrong side.
