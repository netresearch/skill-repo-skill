# Authoring & CI Gotchas

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

Security scanners (SonarCloud `githubactions:S6505`) require `npm install
--ignore-scripts` in workflows — but that breaks `@anthropic-ai/claude-code`,
whose **postinstall downloads the platform-native binary**; the CLI then exits
with "claude native binary not installed". The package documents its own
sanctioned two-step (verified with 2.1.206):

```bash
npm install -g --ignore-scripts @anthropic-ai/claude-code@<pinned-version>
node "$(npm root -g)/@anthropic-ai/claude-code/install.cjs"
claude --version   # proves the binary is in place
```

This blocks lifecycle scripts of the whole dependency tree while running only
the CLI's own vetted installer, explicitly.
