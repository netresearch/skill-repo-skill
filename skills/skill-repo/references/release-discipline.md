# Release Discipline

Every step that caused the "30 failed plugin releases" incident, codified as rules.

## Fleet sweeps: use the shipped driver, do not hand-write a new one

Everything below that a fleet sweep needs is mechanized in
`scripts/fleet-release-github.sh` on top of the host-neutral
`scripts/fleet-release-common.sh` engine. The driver runs `survey` →
`manifest` (stops for human approval; versions and PR bodies are operator
judgment the scripts never invent) → `bump` → `finish`, resumable from remote
reality at every step. The changelog rollover below is its own tool,
`scripts/roll-changelog.py`. Fleets on other hosts keep their driver, their
repo list and their host specifics in their own (private) repository — that
driver vendors the shared engine and implements the `host_*` callbacks its
header documents; host knowledge stays with the host. Every sweep before
these existed re-implemented this page as one-off scripts and re-earned the
same bugs (#218 records the last one: brace-group exits, pretty-printed survey
rows, `//` on empty strings — all now encoded as tests). Deliberately out of
scope, by design: merging anyone else's PR, unarchiving, cloning missing
checkouts, writing CI files (a NO-RELEASE-JOB manifest row means adopt the
shared release CI first), and non-default-branch releases — the
`--latest=false` rule below stays a manual concern. When a sweep needs
something the driver lacks, extend it in a PR; a session-local driver script
is how the next incident starts.

**Budget the API before a sweep: the survey costs ~10 calls per repo, and
each GitHub quota pool (REST 5,000/h, GraphQL 5,000 points/h — separate
pools) is shared across every tool, watcher and agent in the session.** A
40-repo survey plus check-watchers plus a merge-gate poll can exhaust them
mid-sweep — the GraphQL pool usually dies first because `gh pr merge`,
`gh pr view --json` and pr-status.sh all draw from it, while plain REST
still answers apart from short burst limits (2026-08-13: a sweep session hit
exactly this between "all gates verified" and "merge"). Practice: act on a verified, unchanged head
with ONE call instead of re-running preflight batteries — the REST merge
takes an `sha` pin (`gh api -X PUT .../pulls/N/merge -f merge_method=merge
-f sha=$(git rev-parse HEAD)`) whose 409 IS the freshness check — prefer one
`--watch` over repeated status reads, and stop any watcher whose answer is
already known.

## Canonical Order: Bump PR Merged → Tag Pushed

**Tag a version only after the version-bump PR is merged to the default branch.** Tagging first causes the Release workflow to run against the old code, fail CI, and produce an immutable GitHub release locked to a bad tag.

```
WRONG: git tag -s v1.2.4 → git push → open bump PR
RIGHT: open bump PR → merge → pull main → git tag -s v1.2.4 → git push
```

## Pre-Release Version-Parity Check

Before pushing any tag, all version identifiers must match. This is the single check that would have prevented the 30-repo release failure.

Use the shipped script `scripts/check-version-parity.sh` (in this repo under `skills/skill-repo/scripts/check-version-parity.sh`):

```bash
# No arguments — compare plugin.json against SKILL.md metadata.version
skills/skill-repo/scripts/check-version-parity.sh

# With tag argument — also require plugin.json.version == tag (v prefix optional)
skills/skill-repo/scripts/check-version-parity.sh v1.2.4

# From a driver that iterates over many checkouts — name the repo explicitly
skills/skill-repo/scripts/check-version-parity.sh --repo /path/to/repo v1.2.4
```

All paths the script reads are relative to the repo root, so without `--repo`
the root is the current directory. A fleet driver that passes the repo as a
bare argument gets it parsed as a *tag* and the script then aborts on the
missing `plugin.json` — after the bump has already been written to disk,
leaving every repo in that batch dirty (observed 2026-08-06: five repos in one
batch). Pass `--repo`, or `cd` into the checkout first.

What it checks:

- Root `plugin.json` (Agent Plugins manifest), when present, is the **source of truth**: bump it first, run `sync-plugin-manifest.sh`, and the check fails if `.claude-plugin/plugin.json` still disagrees. Repos that have not adopted the portable manifest are unaffected — see [`agent-plugins-compat.md`](agent-plugins-compat.md).
- `.claude-plugin/plugin.json` has a `.version` field — exits with an error if missing.
- `composer.json` does **not** have a `.version` field — composer versions come from the git tag via the Release workflow, so a hard-coded version drifts silently.
- If a tag argument is provided, `plugin.json.version` equals that tag with the `v` prefix stripped.
- Every `skills/*/SKILL.md` that declares a version in frontmatter — `metadata.version` *or* a top-level `version:` key (both forms exist in the fleet; some SKILL.md files declare none, which is fine) — matches `plugin.json.version`.

If called without an argument and all parity passes, the script prints an advisory suggesting the next tag call. Run before every `git push origin vX.Y.Z`.

Bump tooling must handle the same two frontmatter forms: a bump script that only rewrites the indented `metadata.version` silently leaves a top-level `version:` at the old value, and the tag pipeline's `validate:skill` then fails on exactly that mismatch (it-maintenance-skill v1.10.0 died this way; typo3-upgrade-estimator-skill nearly repeated it in the 2026-07-16 sweep).

Use `scripts/bump-version.sh <version> [--apply]` rather than a per-repo helper. It writes every surface `check-version-parity.sh` validates — the root `plugin.json`, the `.claude-plugin/plugin.json` projected from it, plus *each* frontmatter `version:` line in *every* `skills/*/SKILL.md`, both forms, indentation and quoting preserved — refuses when `composer.json` carries a version, and re-runs the parity check afterwards. Dry-run by default.

**The root `plugin.json` is the surface a bump is most likely to miss.** Until v1.28.0 the script wrote only the *generated* `.claude-plugin/plugin.json`, so on every repo that had adopted the portable manifest it left the source of truth at the old version, failed its own parity check, and exited 1 with the tree half-written. That is the same failure mode as the two frontmatter forms above, one level up: the surface the tooling does not know about is the one that silently keeps the old value. A fleet sweep hits it in every repo at once — 65 of them on 2026-08-08.

It deliberately does not commit, tag or push. A helper that bumps and tags in one step is how the canonical order above gets skipped: the tag then lands on an unmerged branch, or on a tree where only one of the version surfaces moved. Two repos grew such a target locally (`make release` in it-account-lifecycle-skill and it-maintenance-skill) and both diverged from this page — one bumped only `plugin.json`, the other hard-coded a single skill path and produced the v1.10.0 failure above.

## Changelog Rollover in the Bump Commit

If the repo maintains a `CHANGELOG.md`, the version-bump commit moves the `[Unreleased]` content under a new `## [X.Y.Z] - YYYY-MM-DD` heading and leaves a fresh empty `[Unreleased]` section. A bump commit that skips this leaves shipped content labeled `[Unreleased]` — the next release then has to relabel history after the fact (typo3-upgrade-estimator-skill shipped its entire v2.2.0 changelog block as `[Unreleased]` and it was only relabeled in v2.2.1).

**Five heading shapes exist in the fleet**, not the two this page claimed until
v1.29.0 — the 2026-08-08 sweep hit all of them across 63 repos:

| Shape | Example | Seen in |
|---|---|---|
| bracketed dash | `## [1.2.3] - 2026-08-08` | most keep-a-changelog repos |
| bare paren | `## 1.2.3 (2026-08-08)` | it-maintenance-skill, gitlab-skill |
| bracketed em dash | `## [0.3.23] — 2026-07-02` | nr-monatliche-abrechnung |
| linked | `## [v2.6.0](…/releases/tag/v2.6.0) — 2026-02-28` | typo3-docs-skill |
| `[Unreleased]` only, no released heading yet | — | source-digest-skill |

A roll anchored on one shape matches nothing in the others and exits 0, so the
release ships with its content still under `Unreleased` and nobody sees an error.
Detect the shape from the newest *released* heading and reproduce it — including
the dash character and, for the linked form, rewriting the tag inside the URL.
The fifth shape has no released heading to copy from; that is the first release,
not an error, so default to the keep-a-changelog form its `[Unreleased]` bracket
already implies rather than aborting.

**Fail the roll when it changed no lines** — a no-match must not be
indistinguishable from a successful roll. Same rule as for `metadata.version` vs
a top-level `version:`: whichever surface the tooling does not know about is the
one that silently keeps the old value.

**A generated entry must satisfy markdownlint, because every repo lints its
CHANGELOG in CI.** Emit a blank line after each `### Added`/`### Fixed` heading
and around every list, or the bump PR goes red on MD022 (blanks-around-headings)
and MD032 (blanks-around-lists) — in one repo, in every repo, all at once. This
red-lit 16 of 63 repos mid-sweep on 2026-08-08. It is worth running
`npx markdownlint-cli2 CHANGELOG.md` on the rolled file before committing:
the roll is generated text, and generated text is exactly what nobody proofreads.

Boundary regexes are also **fence-blind** — a scan anchored on `^##` matches a
heading-looking line inside a fenced code block and splices the new section into
the middle of an example. Track fences while scanning.

## Cache Safety: Never Edit the Installed Copy

Installed skills and plugins live under `~/.claude/` (or wherever the marketplace resolves them). Editing these paths directly is always wrong — the next `/plugin update` or marketplace sync will silently overwrite your changes, taking any local fixes with it.

### Paths that are off-limits for edits

- `~/.claude/skills/**`
- `~/.claude/plugins/cache/**`
- `~/.claude/plugins/marketplaces/**`
- Anything inside a `.bare/` directory (git bare clone; worktree source)

### Pre-edit check

Before every Write or Edit in skill-repo workflows:

```bash
pwd_real=$(realpath .)
case "$pwd_real" in
  */.claude/skills/*|*/.claude/plugins/*|*/.bare/*)
    echo "REFUSING to edit installed/cache path: $pwd_real"
    echo "Navigate to the source worktree first."
    exit 1
    ;;
esac
```

### Recovery when edits landed in the wrong place

1. Stop. Do not run `/plugin update` or `composer update` — they may wipe your edits.
2. `diff -r ~/.claude/skills/<name>/ ~/projects/<name>-skill/main/skills/<name>/` to see what drifted.
3. Copy the legitimate changes into the source worktree.
4. Commit from the worktree; never from the cache.

## Multi-Skill-Repo Release Dry-Run

When releasing >3 skill repos in one sweep, produce this manifest and wait for user approval before executing:

```
Skill-Repo Release Plan (2026-04-18)

| Repo                        | Current | Target  | Change type | Bump PR   | Notes                  |
|-----------------------------|---------|---------|-------------|-----------|------------------------|
| netresearch/git-workflow    | 1.9.0   | 1.10.0  | minor       | mine      | adds critical-rules    |
| netresearch/github-project  | 2.10.0  | 2.11.0  | minor       | mine      | multi-repo-operations  |
| netresearch/skill-repo      | 1.18.0  | 1.19.0  | minor       | #42 @kim  | NEEDS AUTHOR'S GO      |

Preconditions (verified per repo):
  [✓] default branch CI green
  [✓] no pending version-bump PR by another author
  [✓] version-parity check passes
  [✓] working tree clean

Execution order per repo:
  1. Create version-bump PR on release/vX.Y.Z branch
  2. Wait for CI green and approval
  3. Merge via merge-commit (respects atomic-commit policy)
  4. Pull main; run check-version-parity.sh vX.Y.Z
  5. Create signed tag vX.Y.Z
  6. Push tag
  7. Monitor Release workflow to green
  8. Halt all further releases if this one fails — produce rollback

Reply "go" to proceed, or name repos to skip.
```

The branch and commit names are not this file's to invent: `release/vX.Y.Z` and
`chore(release): vX.Y.Z` are owned by `github-release-skill`
(`commands/release.md`, steps 4 and 8). Follow that skill when the two disagree.

### A pre-existing bump PR by another author is not covered by the sweep's approval

A sweep will sometimes find a repo whose version-bump PR is already open —
opened by a colleague, days earlier, mergeable and green. Merging it is what the
release needs, and the manifest row looks exactly like every other row, which is
the problem: a single "go" over a 19-row table reads as approval of *your* work,
and the author is never asked.

Give the manifest a **Bump PR** column naming the author of every pre-existing
PR, mark those rows as needing that author's go-ahead, and get it separately.
Blanket batch approval covers only the PRs the sweep itself opens. (Observed
2026-08-06: `ecom-orocommerce-docker-skill !5`, authored by a colleague, was
merged inside a 19-repo batch on one blanket approval.)

### Building the manifest: fleet-survey gotchas

**Prefer a remote-first survey — the GitHub API answers the whole classification without touching a checkout** (verified in the 2026-08-03 sweep: 40 repos surveyed, 7 released). Three calls per repo: `gh api repos/$O/$R/releases/latest` (tag of the latest *published release* — a 404 means the repo has never released; classify it for a first release instead of skipping), `gh api "repos/$O/$R/compare/<tag>...main"` (ahead-count, commit subjects *and* changed files in one response — enough for both the CI-only-delta filter and the bump-type decision; name the default branch explicitly, consistent with the `origin/main` guidance below), `gh api repos/$O/$R/contents/.claude-plugin/plugin.json` (prepared-vs-needs-bump). The local-checkout gotchas below then apply only to the repos that actually release.

**The GitLab arm needs its own call triple — the response shapes differ.** Half
the fleet lives on `git.netresearch.de/coding-ai`, and a GitHub-shaped `jq`
filter returns *empty* against these rather than erroring, so the repo looks
like it has no delta:

```bash
P="coding-ai%2F$R"
glab api "projects/$P/releases?per_page=1"                                  # .[0].tag_name; empty ⇒ never released
glab api "projects/$P/repository/compare?from=$tag&to=main"                 # .commits[].title  and  .diffs[].new_path
glab api "projects/$P/repository/files/.claude-plugin%2Fplugin.json/raw?ref=main"
```

Note `.diffs[].new_path` where GitHub has `.files[].filename`, and
`.commits[].title` where GitHub has `.commits[].commit.message`. GitLab's
compare returns no `ahead_by`, so count `.commits[]` yourself. Verified in the
2026-08-06 sweep (74 repos surveyed across both hosts, 19 released).

**Compute the CI-only-delta filter, do not eyeball it.** The rule below ("CI-only
deltas are not releases") is only usable if the survey reports it per repo. From
the same compare response:

```bash
jq '[.files[].filename] | map(select(test("^\\.github/|^\\.gitlab-ci\\.yml$|^renovate\\.json$") | not)) | length'
```

A zero means the release archive would be byte-identical to the last tag — skip
the repo and say so in the manifest. In the 2026-08-06 sweep this filter alone
removed 13 of 32 repos that had commits since their tag.

Surveying dozens of local skill-repo checkouts for "commits since last tag" hits these, verified in the 2026-07-16 sweep (16 releases):

- **Three checkout layouts coexist** under the projects dir: bare + worktrees (`repo/.bare`), a plain repo at the top level (`repo/.git`, which is a pointer *file* when the top level is itself a worktree), and a plain clone one level down (`repo/main/.git`). Resolve the git dir per repo instead of assuming one shape:

  ```bash
  G=$([[ -d "$d/.bare" ]] && echo "$d/.bare" \
      || git -C "$d" rev-parse --absolute-git-dir 2>/dev/null \
      || git -C "$d/main" rev-parse --absolute-git-dir 2>/dev/null)
  ```

  `rev-parse --absolute-git-dir` handles both plain repos and worktree pointer files; it cannot discover `$d/.bare` (a worktree *parent* dir is not a repo, and upward discovery never looks into `.bare`), and it must not run first from `$d` when only `$d/main` is the repo — hence the explicit order.
- **`git fetch --tags` fails wholesale on one stale tag** (`would clobber existing tag`), taking the branch fetch down with it. Survey with a branches-only refspec plus `git ls-remote --tags origin` and the peeled (`^{}`) SHA for the ahead-count; never resolve the tag locally.
- **Duplicate checkouts happen** (two dirs, same `origin`). Dedupe the manifest by remote URL, not by directory name, or the same repo gets two bump PRs.
- **A per-repo `exit` inside a `{ … } > log` block kills the whole driver.** A brace group is not a subshell, so the first failing repo silently cancels every repo after it — the batch "completes" with fewer log files than repos and nothing says so. Wrap each repo's body in `( … ) > log` instead, and compare log count against repo count before trusting the summary. (2026-08-13: a three-repo driver died on repo two; repo three was skipped, revealed only by its missing log.)
- **Emit survey rows with `jq -nc`, not `jq -n`.** Bare `jq -n >> file` pretty-prints, so `wc -l` counts JSON lines, not rows — a 74-repo survey reported "1400 rows". Downstream `jq -c .` still parses the concatenated stream, but every row-count sanity check lies until the file is one-object-per-line.
- **jq's `//` treats the empty string as present.** Fields captured as `""` (not null) sail straight through `.last_release // .last_tag`, so the coalesce prints nothing instead of falling back. When the producer writes empty strings, select explicitly: `if .last_release != "" then .last_release else .last_tag end`.
- **A renamed repo answers on both names — the API redirect turns one repo into two survey rows.** `gh api repos/$O/<old-name>` follows the rename redirect and returns the new repo's data wholesale, so a fleet list that still carries the old name surveys the same repo twice, and the sweep would open two bump PRs against one repo. Dedupe survey rows by the response's `.full_name`, never by the name you queried (2026-08-13: `agents-skill` surveyed as a live repo with the exact ahead-count and version of `agent-rules-skill` — it is a redirect to it).
- **CI-only deltas are not releases.** If every unreleased commit touches only `.github/**`, `.gitlab-ci.yml`, or `renovate.json`, the release archives would be byte-identical to the last tag — skip the repo and say so in the manifest.
- **Archived repos are release-infeasible** (pushes rejected). A deprecated repo whose deprecation-banner commit landed *after* the last tag has never shipped its own deprecation notice — flag it for an unarchive decision instead of silently skipping.
- **The unarchive → final release → re-archive path** (walked 2026-08-13 for claude-coach-plugin v2.6.0 and typo3-frontend-patterns-skill v1.2.1) has its own traps. A sweep that was blocked by the archive may have left a prepared, signed local bump branch — verify its signature and content, then push and reuse it rather than recreating. Expect the frozen repo to fail reusables that evolved while it slept, and fix proportionately: measure ruff with the fleet config (`select = ["E","F","W"]`, `line-length = 120`) before concluding code work exists — 439 default-rule findings were **zero** under it, so the fix was one `ruff.toml`, not a rewrite. `ruff format` also rewrites ` ```python ` blocks inside `.md` files, and a config change invalidates every earlier `--check` measurement — re-measure after the config lands, and AST-verify the formatted files before claiming the change is behavior-free. A red Template Drift paired with a Security `startup_failure` usually shares one cause: the frozen `security.yml` still passes the org-removed `GITLEAKS_LICENSE` secret — syncing `templates/skill/.github/workflows/security.yml` from `netresearch/.github` fixes both at once. Re-archive only after the Release object and its assets are verified.
- **Cleaning up after the sweep is not an ancestry question.** The branches a sweep leaves behind get classified by whether their work is safe to drop, and `git merge-base --is-ancestor <branch> origin/main` does not answer that: a squash-merged PR puts the content on `main` under one new commit, so the branch SHAs are absent and shipped work reads as "unmerged". Use the PR/MR state, with `git cherry` as the offline fallback — `git-workflow-skill` → `references/advanced-git.md` ("Is This Branch Safe to Delete?") owns the rule and the commands. Applies to the *report* as much as the deletion: in the 2026-08-06 sweep this misclassification turned 2 genuinely unsaved commits into 18 alarming-looking branches.
- **Read the version state from `origin/main`, never the local worktree.** Worktrees drift — some sit behind the remote, some ahead, some are dirty — so `cat repo/.claude-plugin/plugin.json` gives a misleading parity picture. Read the authoritative value with `git show origin/main:.claude-plugin/plugin.json` after fetching. `git show` takes a single literal path and does **not** glob, so enumerate the SKILL.md files first, then read each:

  ```bash
  for f in $(git ls-tree -r --name-only origin/main | grep -E 'skills/[^/]+/SKILL\.md$'); do
    git show "origin/main:$f"
  done
  ```

  Verified in the 2026-07-18 sweep (23 releases), where worktree reads disagreed with `origin/main` on ~6 repos.
- **Survey for a `composer.json` `version` field before the sweep, not at bump
  time.** `bump-version.sh` and `check-version-parity.sh` both refuse while it is
  present, so a repo carrying one fails mid-bump with a half-written tree and has
  to be re-run after the field is removed. Four GitLab repos hit this on
  2026-08-08, and three of the four were already *behind* their own latest tag
  (`dxp-project-init` declared `0.1.0` against tag `v0.2.6`) — which is precisely
  the drift the no-version rule exists to prevent, so removing it is the fix, not
  a workaround. One extra call per repo during the survey turns a mid-sweep
  failure into a manifest row:

  ```bash
  glab api "projects/coding-ai%2F$R/repository/files/composer.json/raw?ref=main" | jq -e 'has("version")'
  ```

- **A QUEUED GitHub check reports `conclusion: ""`, not `null` — so the obvious
  red-check filter calls it a failure.** The natural gate,
  `select(.conclusion != null and .conclusion != "SUCCESS" …)`, lets the empty
  string through and the sweep aborts on checks that were merely still starting.
  Gate on completion first and only then on the verdict:

  ```bash
  gh pr view "$BRANCH" --repo "$O/$R" --json mergeStateStatus,statusCheckRollup --jq '{
    p: [.statusCheckRollup[] | select((.__typename=="CheckRun" and .status!="COMPLETED")
                                    or (.__typename=="StatusContext" and .state=="PENDING")) | .name],
    f: [.statusCheckRollup[] | select(.__typename=="CheckRun" and .status=="COMPLETED"
                                    and (.conclusion|IN("SUCCESS","SKIPPED","NEUTRAL")|not)) | .name]}'
  ```

  Wait while `p` is non-empty; fail only on `f`. The two shapes in the rollup need
  different fields — `CheckRun` has `.status`/`.conclusion`, `StatusContext` has
  `.state` — and a filter written for one silently mis-reads the other. Note also
  that `gh pr checks --watch` only blocks *while it can run*: if its output
  redirect fails (a missing log directory), the command dies instantly and the
  very next query reads a still-pending rollup. Observed 2026-08-08.
- **`plugin.json` ahead of the last tag ⇒ the bump already merged — tag only, no bump PR.** Classify each repo from the `origin/main` value: `plugin.json.version > last tag` means a prior bump PR already landed and the repo just needs a signed tag; `plugin.json.version == last tag` means it needs a bump PR first. Tagging a "prepared" repo at its committed version keeps parity true by construction. Don't open a bump PR for a repo that is already prepared — it would double-bump.
- **`git pull origin main` merges into whatever branch the worktree has checked out.** A fleet sweep hits worktrees parked on a leftover feature branch, and `--ff-only` does not protect you — the stale branch fast-forwards onto `origin/main` "successfully" (observed 2026-08-03: a leftover `ci/*` branch silently advanced to the main tip).

  **Do not check out at all — tag `origin/main` directly.** Fetching, verifying
  and tagging need no working tree, which removes the hazard instead of stepping
  around it, and it is the only form that leaves a colleague's parked worktree
  untouched (in the 2026-08-06 sweep, `skill-repo-skill`'s only checkout sat on a
  leftover `release/v1.25.2` the whole time; `git switch main` there would have
  moved someone's workspace out from under them):

  ```bash
  git -C "$G" fetch origin --prune --quiet
  remote_tip=$(gh api "repos/$O/$R/commits/main" --jq .sha)
  [[ "$(git -C "$G" rev-parse origin/main)" == "$remote_tip" ]] || exit 1
  # parity read from the ref, never from a working tree
  git -C "$G" show "origin/main:.claude-plugin/plugin.json" | jq -r .version
  git -C "$G" tag -s "v$V" -m "v$V" "$remote_tip"
  git -C "$G" push origin "v$V"
  ```

  `git tag` takes any commit-ish, and it does not touch the index or the working
  tree — so this is safe even in a plain (non-bare) checkout that is mid-edit.
  Keep switch-then-pull only for the repos where you genuinely need files on disk.

## GitLab (`git.netresearch.de`) skill repos release on tag too

The release-discipline above is GitHub-centric, but the `coding-ai` GitLab skill repos ship the same way: **a pushed signed tag triggers a pipeline that creates the GitLab Release** via the `claude-code-skill` CI component (`include:` in `.gitlab-ci.yml`). There is no separate release workflow file and **no manual `glab release create`** — pushing `vX.Y.Z` is sufficient; the Release object appears when the tag pipeline goes green. Confirm with `glab api "projects/coding-ai%2F<repo>/releases/v<ver>"` (and the tag pipeline via `pipelines?ref=v<ver>`). Same bump-PR-then-tag order as GitHub applies; merge the bump MR only when `detailed_merge_status == "mergeable"`.

This holds only for repos whose release job is gated on the tag you actually push — see [A pushed tag is not a release](#a-pushed-tag-is-not-a-release--check-the-pattern-the-release-job-matches) below, which is where the exceptions live.

## A pushed tag is not a release — check the pattern the release job matches

The sentence above ("pushing `vX.Y.Z` is sufficient") holds **only while the tag
you push matches the pattern that repo's release job is gated on.** When it does
not, the push succeeds, the pipeline may even go green, and no Release object is
ever created. Nothing fails; the release is simply missing. Three variants, all
found in the 2026-08-08 sweep:

| Repo | Tag pushed | Release rule | Result |
|---|---|---|---|
| `dxp-project-maintenance` | `0.5.4` (bare) | component: `^v\d+\.\d+\.\d+$` | job never ran; releases hand-made for months |
| `oro-bundle-upgrade-skill` | `v1.1.0` | no tag rule at all — CI runs only on MRs and the default branch | job does not exist; releases hand-made |
| `tender-estimation` | `tender-estimation--v0.6.1` | `^tender-estimation--v\d+\.\d+\.\d+$` | **correct** — a deliberate non-standard convention |

So the check is not "does the repo use `vX.Y.Z`" but **"does its release job's
rule match the tag its maintainers actually cut?"** The third row is the reason:
that prefix is deliberate, documented in the file as matching the
`claude plugin tag` CLI, and its release job fires on it. Normalising it to
`vX.Y.Z` would have *broken* a working release path.

Before tagging a repo you have not released before, read the whole
`.gitlab-ci.yml` / release workflow and compare the rule against the last tag:

```bash
glab api "projects/coding-ai%2F$R/repository/tags?per_page=1" | jq -r '.[0].name'
glab api "projects/coding-ai%2F$R/repository/files/.gitlab-ci.yml/raw?ref=main" | grep -n 'CI_COMMIT_TAG'
```

**Read the whole file, not its head.** A release job commonly sits at the bottom,
after the lint and validate jobs; concluding "this repo has no release job" from
the first screenful is wrong, and in this sweep that mistake was made and acted
on — it produced a plan to "fix" CI that was already correct.

After every tag push, **verify the Release object exists rather than assuming the
tag implied it.** If it is missing, the tag pipeline's job list says why — a rule
that did not match shows up as the release job being absent from an otherwise
green pipeline, not as a failure:

```bash
glab api "projects/coding-ai%2F$R/pipelines?ref=$TAG" | jq -r '.[0].id'
glab api "projects/coding-ai%2F$R/pipelines/<id>/jobs" | jq -r '.[]|"\(.stage)/\(.name): \(.status)"'
```

The same trap exists on the GitHub side one level in: `node-agent-skill-coordinator`'s
release workflow ran, but died on `Script not found "build"` because the caller
never set `build-cmd` and the shared reusable defaults to `bun run build`. A
caller that adopts a reusable and then does not cut a release has not tested it —
the first tag after the adoption is the test.

## Immutable-Release Caveat

Deleted GitHub releases do NOT free the tag for reuse. Once a release is published and deleted, that tag string is permanently locked as a deleted release — a new release with the same tag will fail. See `git-workflow-skill` → `references/github-releases.md`. Therefore: get it right the first time. The version-parity check above is what "right the first time" means in practice.

## Tag Signing (Mandatory)

```bash
git tag -s vX.Y.Z -m "vX.Y.Z"         # -s: sign with GPG/SSH
git push origin vX.Y.Z                # signed tag reaches the remote
```

Never `git tag vX.Y.Z` (unsigned). Repos with protected tag rulesets will reject unsigned tags.

## No `--latest` Drift for Non-Default Branches

When releasing from a non-default branch (e.g. a v1.x maintenance line while v2.x is default), pass `--latest=false` to avoid stealing the "Latest" badge by timestamp:

```bash
gh release create v1.5.12 --latest=false --title "v1.5.12" --notes-file CHANGELOG-v1.5.12.md
```

GitHub marks releases "Latest" by creation timestamp, not semver. A v1.5.12 created after v2.0.0 will become "Latest" without this flag — wrong, misleading, and often noticed only by downstream consumers.

## Supply-Chain Attestation

Every release ships with provenance-attested archives and a Cosign-signed `SHA256SUMS.txt` that binds those archives by digest. Only the checksum file is Cosign-signed; the `.zip`/`.tar.gz` archives are integrity-protected through it — verifying the signature on `SHA256SUMS.txt` and then running `sha256sum --check` against the downloaded archive proves the archive was produced by this workflow.

All of this happens in the SAME job that publishes the GitHub Release, BEFORE the assets are made public — there is no window where unsigned or unattested artifacts are downloadable. The flow, in order:

1. Build `*.zip` and `*.tar.gz` archives.
2. Generate `SHA256SUMS.txt` over them.
3. **Cosign** keyless `sign-blob` the `SHA256SUMS.txt` → produces `SHA256SUMS.txt.sigstore.json` (Sigstore bundle format: cert + signature + Rekor inclusion proof in a single self-contained JSON; cosign v3+ default). The `.sigstore.json` extension is chosen so OSSF Scorecard's `signed-releases` probe recognises the signature — the content is identical to cosign's `--bundle` default output.
4. **`actions/attest-build-provenance`** generates a SLSA build-provenance attestation for the archives + checksums file → published to GitHub's attestation API.
5. **`softprops/action-gh-release`** publishes the GitHub Release with all assets attached at once.

Callers must grant three permissions on the calling job:

```yaml
# .github/workflows/release.yml in the consuming repo
jobs:
  release:
    uses: netresearch/skill-repo-skill/.github/workflows/release.yml@main
    permissions:
      contents: write          # release upload
      id-token: write          # OIDC for sigstore (Cosign + attest-build-provenance)
      attestations: write      # GitHub native attestation API
```

If any of those scopes is missing the job fails fast with `Resource not accessible by integration`; `contents: write` alone is not enough.

### Verify a downloaded release archive

Both commands below pin verification to the **specific repository** that's expected to have produced the release. `--owner netresearch` and `https://github.com/netresearch/.*` are tempting shortcuts but match every workflow run in the org — meaning a compromised or unrelated netresearch repo could mint a valid-looking attestation against an artefact that was never released from this repo. Always pin to the named repo.

```bash
# SLSA build provenance (GitHub-native attestation API)
# Substitute <repo-name> with the actual skill repo, e.g. matrix-skill.
# Archive name patterns: <skill>-skill-vX.Y.Z.zip and <plugin>-plugin-vX.Y.Z.zip.
gh attestation verify <skill-name>-skill-vX.Y.Z.zip --repo netresearch/<repo-name>

# Cosign sign-blob signature on the checksums (no GitHub API needed).
# The cert SAN reflects the SIGNER, which is the shared reusable release
# workflow (`netresearch/skill-repo-skill`), NOT the consuming repo. Pin the
# regex to skill-repo-skill, not the consumer. (`gh attestation verify` above
# walks the chain automatically; cosign's verifier doesn't.) The org-wide form
# `https://github.com/netresearch/.*` would accept signatures from any repo,
# branch, or workflow in the org — too loose for supply-chain verification.
cosign verify-blob \
  --bundle SHA256SUMS.txt.sigstore.json \
  --certificate-identity-regexp "^https://github\.com/netresearch/skill-repo-skill/\.github/workflows/release\.yml@" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  SHA256SUMS.txt

# Then verify the archive matches the (now-signed) checksum
sha256sum --check SHA256SUMS.txt
```

If verification fails:

- `gh attestation verify` returns `error: no attestations found` when `--repo` is wrong (or when the release predates this workflow).
- `cosign verify-blob` returns `error: certificate identity does not match` when the regex is wrong, or `bundle verification failed` when `.sigstore.json` doesn't correspond to the file.

### Why one atomic job

Splitting attestation into a separate `needs: release` job (the original design here) creates a race: the GitHub Release publishes BEFORE the attestation exists, so anyone downloading in that window gets unsigned, un-attested artifacts. Folding everything into the same job before the upload eliminates the window — either the whole bundle (archives + signature + provenance) ships, or nothing does.

Same pattern as `netresearch/.github/.github/workflows/golib-create-release.yml` and `netresearch/typo3-ci-workflows/.github/workflows/release.yml`. No reason for skill repos to diverge.

The previously-documented `with: attest: true` opt-in is gone; the input is still declared as `DEPRECATED — ignored` so any caller that still passes it doesn't error syntactically, but every release now gets provenance unconditionally. Drop the `with:` block if `attest` was its only entry (also true for `bump`).
