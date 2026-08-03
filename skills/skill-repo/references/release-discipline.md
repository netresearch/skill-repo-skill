# Release Discipline

Every step that caused the "30 failed plugin releases" incident, codified as rules.

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
```

What it checks:

- `.claude-plugin/plugin.json` has a `.version` field — exits with an error if missing.
- `composer.json` does **not** have a `.version` field — composer versions come from the git tag via the Release workflow, so a hard-coded version drifts silently.
- If a tag argument is provided, `plugin.json.version` equals that tag with the `v` prefix stripped.
- Every `skills/*/SKILL.md` that declares a version in frontmatter — `metadata.version` *or* a top-level `version:` key (both forms exist in the fleet; some SKILL.md files declare none, which is fine) — matches `plugin.json.version`.

If called without an argument and all parity passes, the script prints an advisory suggesting the next tag call. Run before every `git push origin vX.Y.Z`.

Bump tooling must handle the same two frontmatter forms: a bump script that only rewrites the indented `metadata.version` silently leaves a top-level `version:` at the old value, and the tag pipeline's `validate:skill` then fails on exactly that mismatch (it-maintenance-skill v1.10.0 died this way; typo3-upgrade-estimator-skill nearly repeated it in the 2026-07-16 sweep).

## Changelog Rollover in the Bump Commit

If the repo maintains a `CHANGELOG.md`, the version-bump commit moves the `[Unreleased]` content under a new `## [X.Y.Z] - YYYY-MM-DD` heading and leaves a fresh empty `[Unreleased]` section. A bump commit that skips this leaves shipped content labeled `[Unreleased]` — the next release then has to relabel history after the fact (typo3-upgrade-estimator-skill shipped its entire v2.2.0 changelog block as `[Unreleased]` and it was only relabeled in v2.2.1).

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

| Repo                        | Current | Target  | Change type | Notes                  |
|-----------------------------|---------|---------|-------------|------------------------|
| netresearch/git-workflow    | 1.9.0   | 1.10.0  | minor       | adds critical-rules    |
| netresearch/github-project  | 2.10.0  | 2.11.0  | minor       | multi-repo-operations  |
| netresearch/skill-repo      | 1.18.0  | 1.19.0  | minor       | release-discipline ref |

Preconditions (verified per repo):
  [✓] default branch CI green
  [✓] no pending version-bump PR
  [✓] version-parity check passes
  [✓] working tree clean

Execution order per repo:
  1. Create version-bump PR on feat/release-vX.Y.Z branch
  2. Wait for CI green and approval
  3. Merge via merge-commit (respects atomic-commit policy)
  4. Pull main; run check-version-parity.sh vX.Y.Z
  5. Create signed tag vX.Y.Z
  6. Push tag
  7. Monitor Release workflow to green
  8. Halt all further releases if this one fails — produce rollback

Reply "go" to proceed, or name repos to skip.
```

### Building the manifest: fleet-survey gotchas

**Prefer a remote-first survey — the GitHub API answers the whole classification without touching a checkout** (verified in the 2026-08-03 sweep: 40 repos surveyed, 7 released). Three calls per repo: `gh api repos/$O/$R/releases/latest` (tag of the latest *published release* — a 404 means the repo has never released; classify it for a first release instead of skipping), `gh api "repos/$O/$R/compare/<tag>...main"` (ahead-count, commit subjects *and* changed files in one response — enough for both the CI-only-delta filter and the bump-type decision; name the default branch explicitly, consistent with the `origin/main` guidance below), `gh api repos/$O/$R/contents/.claude-plugin/plugin.json` (prepared-vs-needs-bump). The local-checkout gotchas below then apply only to the repos that actually release.

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
- **CI-only deltas are not releases.** If every unreleased commit touches only `.github/**`, `.gitlab-ci.yml`, or `renovate.json`, the release archives would be byte-identical to the last tag — skip the repo and say so in the manifest.
- **Archived repos are release-infeasible** (pushes rejected). A deprecated repo whose deprecation-banner commit landed *after* the last tag has never shipped its own deprecation notice — flag it for an unarchive decision instead of silently skipping.
- **Read the version state from `origin/main`, never the local worktree.** Worktrees drift — some sit behind the remote, some ahead, some are dirty — so `cat repo/.claude-plugin/plugin.json` gives a misleading parity picture. Read the authoritative value with `git show origin/main:.claude-plugin/plugin.json` after fetching. `git show` takes a single literal path and does **not** glob, so enumerate the SKILL.md files first, then read each:

  ```bash
  for f in $(git ls-tree -r --name-only origin/main | grep -E 'skills/[^/]+/SKILL\.md$'); do
    git show "origin/main:$f"
  done
  ```

  Verified in the 2026-07-18 sweep (23 releases), where worktree reads disagreed with `origin/main` on ~6 repos.
- **`plugin.json` ahead of the last tag ⇒ the bump already merged — tag only, no bump PR.** Classify each repo from the `origin/main` value: `plugin.json.version > last tag` means a prior bump PR already landed and the repo just needs a signed tag; `plugin.json.version == last tag` means it needs a bump PR first. Tagging a "prepared" repo at its committed version keeps parity true by construction. Don't open a bump PR for a repo that is already prepared — it would double-bump.
- **`git pull origin main` merges into whatever branch the worktree has checked out.** A fleet sweep hits worktrees parked on a leftover feature branch, and `--ff-only` does not protect you — the stale branch fast-forwards onto `origin/main` "successfully" (observed 2026-08-03: a leftover `ci/*` branch silently advanced to the main tip). `git switch main` first, then pull.

## GitLab (`git.netresearch.de`) skill repos release on tag too

The release-discipline above is GitHub-centric, but the `coding-ai` GitLab skill repos ship the same way: **a pushed signed tag triggers a pipeline that creates the GitLab Release** via the `claude-code-skill` CI component (`include:` in `.gitlab-ci.yml`). There is no separate release workflow file and **no manual `glab release create`** — pushing `vX.Y.Z` is sufficient; the Release object appears when the tag pipeline goes green. Confirm with `glab api "projects/coding-ai%2F<repo>/releases/v<ver>"` (and the tag pipeline via `pipelines?ref=v<ver>`). Same bump-PR-then-tag order as GitHub applies; merge the bump MR only when `detailed_merge_status == "mergeable"`.

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
