# Authoring & CI Gotchas

## Contents

- Word-budget-first authoring
- macOS / BSD portability for shell **and** test scripts
- Lint without dirtying the worktree
- "Skill Validation" can run more than once — wait for all of it
- Installing the Claude Code CLI with `--ignore-scripts`
- Generated YAML: exactly one trailing newline
- `MD010` breaks copy-pasted Makefile snippets — exempt the fence, don't fake the tab

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
