<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Security assurance case — skill-repo-skill

This document states what a user can expect from this repository in terms of security, and argues why that expectation holds. Every claim names the file that implements it and, where one exists, the test that checks it. Reporting a vulnerability: see the organisation's [security policy](https://github.com/netresearch/.github/blob/main/SECURITY.md). Known scanner false positives are recorded in [SECURITY-AUDIT.md](../SECURITY-AUDIT.md).

## What the repository ships

| Part | Files | Runs where |
| --- | --- | --- |
| Skill content | `skills/skill-repo/SKILL.md`, `references/*.md` | Read by an agent as instructions |
| Templates | `skills/skill-repo/templates/*` | Copied into new skill repositories |
| Check scripts | `validate-skill.sh`, `validate-evals.sh`, `check-version-parity.sh` in `skills/skill-repo/scripts/` | On the user's machine, in consumers' CI, and as pre-commit hooks declared in `.pre-commit-hooks.yaml` |
| Release scripts | `bump-version.sh`, `sync-plugin-manifest.sh`, `roll-changelog.py`, `migrate-licensing.sh` | On the user's machine, in the repository they are pointed at |
| Fleet release driver | `fleet-release-github.sh`, `fleet-release-common.sh`, `fleet-repos-github.txt` | On a maintainer's machine, against GitHub repositories, with the maintainer's `gh` login and git credentials |
| Reusable workflows | `.github/workflows/{validate,tests,eval-validate,harness-verify,validate-agents,dependency-audit,ci-python,npm-pack-smoke,pr-quality,release}.yml` | In the CI of each calling repository, with the permissions that caller grants |
| Release artefacts | archives, `SHA256SUMS.txt` and its Sigstore bundle, built by `.github/workflows/release.yml` | Downloaded by users from GitHub releases |
| Maintainer tooling | `scripts/`, `Build/`, `.github/workflows/ab-evals-*.yml`, `tests/` | In this repository's CI and on maintainers' machines |

The scripts have no network listener and store no credentials. Only the fleet driver talks to GitHub, and it uses the operator's existing `gh` login.

## Security requirements

1. The check scripts only read the repository they check; they do not run code from its files (for `git` itself, see "What a user cannot expect").
2. Data read from a checked repository reaches Python code in the check and release scripts as an argument, an environment variable or a file, never as part of the Python source.
3. The release scripts write only inside the repository they are pointed at. Those that update versions or the changelog have a mode that writes nothing: `bump-version.sh` by default, `sync-plugin-manifest.sh --check`, `roll-changelog.py --dry-run`.
4. The fleet release driver changes only repositories the operator listed and approved, creates each tag on a merge commit that is part of the default branch, never moves a tag that exists on the remote, and leaves pull requests of other authors alone.
5. A pull-request author cannot inject shell commands into this repository's workflows.
6. Tools downloaded during CI are pinned, and the downloads that allow it are checked against a hash.
7. A release can be verified against the workflow run that built it.

## Actors and trust boundaries

- **User or agent running a script.** The scripts act with the caller's file-system permissions; they add no privilege and remove none.
- **The repository being checked or changed.** Its files are data to the check scripts. The release scripts change a fixed set of files in it (see "What a user cannot expect").
- **Fleet operator.** Runs the driver with their own GitHub and signing credentials; the driver is as trusted as that operator.
- **Calling repositories.** Each skill repository calls the reusable workflows at `@main` and passes inputs. It trusts this repository's `main`. The workflows in turn treat the caller's inputs and code as the caller's own: `ci-python.yml` runs `inputs.test-command` verbatim, and `tests.yml` runs the caller's tests and `composer install`.
- **GitHub Actions.** Third-party actions are pinned to commit SHAs. The organisation's reusable workflows (`netresearch/.github`, `netresearch/typo3-ci-workflows`) are called at `@main`.
- **Contributors.** Changes reach `main` through pull requests. At the time of writing, the branch protection of `main` requires signed commits, a branch that is up to date with `main`, and nine status checks: Skill Validation, the npm tarball check, Composer Audit and its preflight, Opengrep SAST, secret scanning, CodeQL for Actions, SonarCloud and DCO. It requires no approving review. These are repository settings, not files in this repository.

## Threats and countermeasures

| Threat | Countermeasure | Evidence |
| --- | --- | --- |
| Content of a checked repository gets executed (CWE-94) | The check scripts parse files with Python and `jq`. Values reach Python as `argv`, through an environment variable or on stdin to a quoted heredoc | `validate-skill.sh` (`python3 - "$REPO_DIR" <<'PYEOF'`, `FRONTMATTER=… python3 <<'PYEOF'`), `validate-evals.sh` (`json.load(open(sys.argv[1]))`), `check-version-parity.sh`; `tests/validate-skill.sh`, `tests/validate-evals.sh` |
| A regular expression from an eval file is read as a `grep` option | `validate-evals.sh` passes patterns after `--` | `skills/skill-repo/scripts/validate-evals.sh`; `tests/validate-evals.sh` |
| A pull-request title, branch name or author reaches a shell (CWE-78) | Event data reaches `run:` blocks only through `env:`. Two expressions stand directly in a shell: `${{ github.repository }}` in `validate.yml`, the caller's repository name, whose characters GitHub restricts; and `${{ inputs.test-command }}` in `ci-python.yml`, the calling repository's own test command, run verbatim by design | `.github/workflows/*.yml` |
| A release script writes more than intended | `bump-version.sh` is a dry run unless given `--apply`; `sync-plugin-manifest.sh --check` and `roll-changelog.py --dry-run` write nothing; `bump-version.sh` and `roll-changelog.py` write through a temporary file that replaces the target | `skills/skill-repo/scripts/bump-version.sh`, `sync-plugin-manifest.sh`, `roll-changelog.py`; `tests/portable-manifest.sh`, `tests/roll-changelog.sh` |
| The fleet driver releases the wrong repository or version | It checks each clone's `origin` against the expected host and repository, validates the whole plan (repository names, semver, versions only go up) before changing anything, stages only version files and `CHANGELOG.md`, refuses to work inside `~/.claude` skill or plugin directories, tags only a merge commit that is an ancestor of the default branch, skips a tag already on the remote, and blocks a repository with another author's open release pull request | `skills/skill-repo/scripts/fleet-release-common.sh` (`fr_check_origin`, `fr_plan_validate`, `FR_ALLOWLIST_RE`), `fleet-release-github.sh`; `tests/fleet-release.sh` |
| A downloaded tool is replaced (CWE-494) | Step-level actions are pinned to 40-character SHAs. The ShellCheck binary is fetched over HTTPS only and checked against a SHA-256. bandit and pip-audit are installed with `--require-hashes --only-binary :all:` from `.github/requirements/*.txt`. `ruff` and `pyyaml` are pinned to exact versions | `.github/workflows/validate.yml`, `ci-python.yml`, `dependency-audit.yml` |
| A release artefact is tampered with | `release.yml` accepts only an annotated tag whose signature GitHub reports as verified and whose version equals `.claude-plugin/plugin.json`. It signs `SHA256SUMS.txt` with Cosign (keyless), verifies the signature against the release workflow's identity, and attests build provenance for the archives and checksums | `.github/workflows/release.yml`; `tests/release-archive-layout.sh` |
| A secret, a vulnerable dependency or an insecure pattern is merged | `security.yml` runs secret scanning (Betterleaks), zizmor on the workflows, dependency review on pull requests, and Composer Audit with an Opengrep scan that fails on findings of severity WARNING or higher; the secret scan, Composer Audit and Opengrep are required checks | `.github/workflows/security.yml` and the organisation workflows it calls |
| A change to a shipped script breaks it unnoticed | Skill Tests (`tests-caller.yml` → `tests.yml`) runs the suite in `tests/` on every push and pull request; Self-test (`self-test.yml`) runs the validator and manifest tests and validates this repository with the validator from the pull request itself. Neither is a required status check at the time of writing | `.github/workflows/tests-caller.yml`, `self-test.yml`, `tests/` |

## Secure design principles applied

- **Least privilege:** every workflow except `release.yml` either sets `permissions: {}` at the top and grants per job, or grants `contents: read`. The exception: `release.yml` grants `contents: write` at the top. Write permissions appear only in jobs that publish something: `release.yml` (`contents: write`, `id-token: write`, `attestations: write`), `ab-evals-schedule.yml` (a results pull request), `pr-quality.yml`, the auto-merge and labeler callers, and `security-events: write` for the scans that upload results (`security.yml`, `scorecard.yml`).
- **Fail-safe defaults:** `bump-version.sh` previews unless told to apply; the fleet driver refuses the whole phase when one plan row is invalid.
- **Separation of data and code:** the check scripts hand data to Python as arguments or environment, not as source text.
- **Economy of mechanism:** the scripts need Bash, Python's standard library, `git` and `jq`; PyYAML is optional in `validate-skill.sh`, which falls back to a standard-library parser.
- **Open design:** what each check does is documented in `AGENTS.md`, `docs/ARCHITECTURE.md` and the header of each script.

## What a user cannot expect

- Consumers call the reusable workflows at `@main`, and `validate.yml` and `eval-validate.yml` check out their scripts, `ci-python.yml` and `dependency-audit.yml` their hash-locked requirement files, from this repository's `main`. A change merged to `main` reaches every consumer on its next run. Pinning a workflow to a commit SHA fixes the workflow file only: those four still fetch these files from `main`.
- `validate-skill.sh` runs `git` in the directory it checks, and `git` honours that directory's local configuration. Run it only on checkouts you would run `git` in.
- `migrate-licensing.sh` has no dry run. It writes the licence files, edits `composer.json`, `plugin.json` and `README.md`, and deletes `LICENSE`. Run it on a clean working tree and review the diff.
- The fleet driver acts with the operator's credentials. Its approval step is a plan file the operator fills in; there is no dry-run flag. `FR_SKIP_SIGN_CHECK=1` skips its signing-key check.
- `pr-quality.yml` approves pull requests of collaborators with write access automatically. In a repository that uses it, that approval is not a review by a second person.
- Harden Runner runs with `egress-policy: audit`: it records outbound connections and blocks none.
- `release.yml` accepts any tag signature that GitHub marks as verified; it does not check the signer against a list, and it does not check that the tagged commit is on `main`. Anyone who may push tags can publish a release.
- `allowed-tools` in `SKILL.md` pre-approves tools for the agent; it does not remove the tools the agent already has and is not a sandbox.
- The A/B evaluation tooling (`scripts/run-ab-evals.sh`, `.github/workflows/ab-evals-*.yml`) is maintainer tooling. It sends eval prompts to the Anthropic API with a repository secret and is not covered by the requirements above.
- Security fixes follow the supported-versions rules of the organisation's security policy; older releases may not receive them.
