# Validation checklist — skill repository changes

Agents **must** walk through this list before declaring a skill-repo task complete.
Marketplace-only checks live in **`netresearch/claude-code-marketplace`/`AGENTS.md`** — do not merge those steps here.

## Contents

- README
- SKILL.md
- Manifests
- Agents / OpenAI
- Discovery metadata
- GitHub repository SEO
- GitHub Pages
- Related skills
- Marketplace sync expectations
- Links and automation
- Optional extended validation
- Which validator catches what
- claude.ai Organization settings sync
- Third-party install scanners

## README

- [ ] `README.md` contains **all** required sections listed in [`readme-template.md`](readme-template.md).
- [ ] **Example prompts:** ≥ **3** realistic prompts in `## Example prompts`.
- [ ] **Related skills:** declared **or** `none (justified: …)`.
- [ ] First screen answers: problem, when, outputs, context, installation — verifiable without scrolling past ~1 screen (approx. first 40 lines).

## SKILL.md

- [ ] Frontmatter includes **`name`** and **`description`**; **no** discovery-only keys (`slug`, `tags`, `category`, `keywords`, …).
- [ ] Optional keys only if needed: `license`, `compatibility`, `metadata`, `allowed-tools` (per validator).
- [ ] `description` starts with `Use when`.
- [ ] Body describes triggers and use cases without duplicating full README marketing copy.

## Manifests

- [ ] Root **`plugin.json`** exists and targets `https://agent-plugins.org/schemas/1.0.0/plugin.schema.json`.
- [ ] It carries **only** the fields of the closed schema — no `skills`, `agents`, … — see [`agent-plugins-compat.md`](agent-plugins-compat.md).
- [ ] Neither manifest carries `support`: it is not a Claude Code field either. `claude plugin validate --strict .` exits **0**.
- [ ] `.claude-plugin/plugin.json` regenerated: `bash skills/skill-repo/scripts/sync-plugin-manifest.sh` leaves the tree clean (`--check` exits 0).
- [ ] Version bumped in the **root** `plugin.json` (source of truth), then synced; `check-version-parity.sh` exits 0.
- [ ] Every skill lives at `skills/<name>/SKILL.md` — a root `SKILL.md` is invisible to Agent Plugins clients.

## Agents / OpenAI

- [ ] `agents/openai.yaml` exists **or** README documents exception.
- [ ] File contains a **short, user-understandable** description of the skill (what/when).

## Discovery metadata

- [ ] Optional `metadata/discovery.yaml` (or documented equivalent) matches README if used — see [`skill-discovery-metadata.md`](skill-discovery-metadata.md).
- [ ] **`action_level`** and **`risk_level`** present in discovery YAML **or** README classification table.

## GitHub repository SEO

- [ ] Repository **Description** ≤ **160** characters, names concrete tech or use case — not generic “AI assistant”.
- [ ] **Topics** include `agent-skill` plus relevant tech/domain tags; no irrelevant stuffing.

## GitHub Pages

- [ ] `gh api repos/netresearch/<repo>/pages` returns **HTTP 404** (Pages disabled — the default).
- [ ] **If Pages is enabled:** the PR description names which `repository-quality-rules.md` Pages criterion is satisfied, and the README contains the mandatory artefacts (justification, canonical URL, source path, build/deploy commands, link-checking, content-split note).

## Related skills

- [ ] Related skills list is **honest** (exists, planned, or external) — see [`repository-quality-rules.md`](repository-quality-rules.md).

## Marketplace sync expectations

- [ ] README contains note or checkbox: when discovery fields change, marketplace entry must be updated **or** override documented (see [`marketplace-integration.md`](marketplace-integration.md)).

## Links and automation

- [ ] All links in touched docs resolve (internal paths and GitHub URLs).
- [ ] `bash skills/skill-repo/scripts/validate-skill.sh` exits **0** from repo root.
- [ ] If repo has CI calling `netresearch/skill-repo-skill/.github/workflows/validate.yml`, PR checks are green.

## Optional extended validation

- [ ] `scripts/audit-skills.sh` (if present in repo) reports no new orphan `references/` files.

## Which validator catches what

Three checkers run over a skill repository and none of them is a superset of the others. A green run of one is not a release gate for the others.

| Checker | Catches | Does **not** catch |
|---|---|---|
| `validate-skill.sh` | repo structure, required files, root `LICENSE-MIT` + `LICENSE-CC-BY-SA-4.0`, shared-field parity between `plugin.json` and `.claude-plugin/plugin.json` (`version` among them) | anything the Claude Code manifest schema defines; `SKILL.md` version metadata, tag parity and the `composer.json` version rule, which belong to `check-version-parity.sh` |
| `claude plugin validate [--strict]` | unknown top-level manifest fields (`--strict` turns the warning into exit 1), malformed manifest | dangling symlinks, markup inside a `SKILL.md` description |
| claude.ai marketplace import | unknown manifest fields, **symlinks whose target is not in the repository**, **angle brackets in a `SKILL.md` description** (reported as XML tags), **a `SKILL.md` description over 1024 characters**, **a top-level `bin/`** — see [claude.ai Organization settings sync](#claudeai-organization-settings-sync) | — |
| Hermes `skills_guard.py` (install-time scanner) | regex matches in the skill directory that block a community install — see [Third-party install scanners](#third-party-install-scanners) | what the matched text does; a pattern matches prose as readily as code |

The gap is not theoretical: on 2026-09-17 three `skills/*/LICENSE` symlinks in `netresearch/matrix-skill` had pointed at a file deleted six months earlier, and a description in `netresearch/orocommerce-skill` carried a literal `<Secret:>` placeholder. Both passed `validate-skill.sh` and `claude plugin validate --strict`; only the marketplace import named them. Run the import, or check symlinks and descriptions by hand, before assuming a repository is clean:

```bash
git ls-files -s | awk '$1=="120000" {print $4}' | while read -r l; do [ -e "$l" ] || echo "DANGLING: $l"; done
```

The description check has two traps, and a one-line `grep` walks into both. It must read the **frontmatter only** — an unscoped `/^description:/` also matches the SKILL.md template inside a body code fence, and this repository's own `skills/skill-repo/SKILL.md` carries `description: "Use when <trigger conditions>"` there, a false positive that reads exactly like a real defect. And it must read the **whole value**: `validate-skill.sh` accepts block scalars (`|`, `>`), so a tag on a continuation line is part of the description the import rejects while a check anchored on the `description:` line alone reports the file clean.

```bash
python3 - skills/*/SKILL.md <<'PY'
import re, sys
for p in sys.argv[1:]:
    txt = open(p, encoding="utf-8").read()
    fm = txt.split("\n---", 1)[0][4:] if txt.startswith("---\n") else ""
    val, grab = [], False
    for ln in fm.split("\n"):
        if grab:
            if ln[:1] in (" ", "\t") or not ln.strip():
                val.append(ln); continue
            break
        m = re.match(r"description:(.*)", ln)
        if m:
            val.append(m.group(1)); grab = True
    for ln in val:
        if re.search(r"<[A-Za-z/]", ln):
            print(f"{p}: {ln.strip()[:110]}")
PY
```

## claude.ai Organization settings sync

A plugin distributed through claude.ai **Organization settings › Plugins** is packaged by a sync that applies rules to the skill repository's own files which no local tool enforces. `claude plugin validate` 2.1.281 passes all of them: it accepts a 2033-character description as `validate .` and as `validate skills`. Measured on 2026-09-23, when the sync of an internal marketplace reported 38 warnings across 13 plugins.

| Rule | Sync message | Fix |
|---|---|---|
| `SKILL.md` description has no `<` | `SKILL.md description cannot contain XML tags` | write a placeholder as `{NAME}`, never `<NAME>` — same meaning, same length |
| `SKILL.md` description ≤ 1024 characters | `field 'description' in SKILL.md must be at most 1024 characters` | cut process detail into the body; keep every backticked command and quoted example phrasing |
| No top-level `bin/` | `Plugin contains a top-level bin/ directory` | the whole plugin is skipped and stays at its last synced version; move the executables to `scripts/` and call them by full path |

Two properties of the sync decide how to check for these:

- **It reports only the first failure per file.** A description that is both too long and bracketed shows only the length warning; the fleet had 18 reported bracket violations and 29 real ones. Fix every instance of the reported failure class — the reported one included — then re-check.
- **Length is the parsed YAML value**, not the raw frontmatter line. A single-quoted scalar doubles every apostrophe it contains, so the raw slice runs long: 1029 raw against 1023 parsed on one description, which decides a 1024 limit. Measure with a YAML parser.

Rules on the marketplace manifest itself — HTTPS plugin source URLs, the 500-character plugin description of each marketplace entry — are marketplace checks and live with the marketplace repository. The internal GitLab fleet enforces the three rules above in the `validate:descriptions` job of `ci-components/claude-code-skill`.

## Third-party install scanners

Some agents scan a skill before they install it. Hermes Agent scans community skills with `tools/skills_guard.py` in [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent). Everything below was read at commit [`26780d5`](https://github.com/NousResearch/hermes-agent/blob/26780d55ae5023817dc20e074e07127d5234d59e/tools/skills_guard.py) (`SCANNER_VERSION = "skills-guard-v6"`); rules and severities change between versions.

The module uses only the Python standard library. Run it from the repository root; `scan_skill` takes a `pathlib.Path`, and a plain string raises `AttributeError`:

```bash
curl -fsSLo skills_guard.py https://raw.githubusercontent.com/NousResearch/hermes-agent/26780d55ae5023817dc20e074e07127d5234d59e/tools/skills_guard.py
python3 - <<'PY'
from pathlib import Path
from skills_guard import scan_skill
r = scan_skill(Path("skills/<name>"), source="community")
print(r.verdict)
for f in r.findings:
    if f.severity in ("critical", "high"):
        print(f.severity, f.pattern_id, f"{f.file}:{f.line}", f.match)
PY
```

**Verdict.** Any `critical` finding makes the verdict `dangerous`, any `high` finding makes it `caution`, otherwise it is `safe`; `medium` and `low` findings never change it. A skill installed from a repository outside the scanner's trusted list is `community`: there `caution` blocks the install unless the user passes `--force`, and `dangerous` blocks it with no override.

**Matching.** Every rule is a case-insensitive regex, applied line by line to `SKILL.md` and to every file with a scanned extension (`.md`, `.json`, `.sh`, `.py`, `.yaml` and others); paths listed in a `.skillignore` are skipped. A rule matches text, not what the text does:

| Rule | Severity | Matches, for example |
|---|---|---|
| `env_exfil_curl` | critical | `curl` followed on the same line by `$…KEY`, `$…TOKEN`, `$…SECRET` or `$…PASSWORD`, such as a documented bearer-token request |
| `dump_all_env` | high | `printenv` or `env` followed by a pipe — also the word `env` before a Markdown table pipe, and `venv\|` in a regex alternation |
| `ssh_dir_access` | high | `~/.ssh` or `$HOME/.ssh` anywhere, including prose |
| `git_clone`, `unpinned_pip_install` | medium | `git clone`, `pip install` without `==` |
| `allowed_tools_field` | low | an `allowed-tools:` frontmatter line |

**Reviewing a pull request that cites a scanner verdict.**

- Verify each finding against the tree: open the file and line, and decide whether the text does what the rule name says.
- Fix a real defect on its own merits, with the tests any other fix gets.
- Decline a change whose only effect is moving the verdict, and give the reason in the review.
- A verdict that follows from the skill's purpose does not move by rewording: a skill whose job is writing agent configuration keeps that capability whatever its files say.

Precedents: [netresearch/agent-rules-skill#94](https://github.com/netresearch/agent-rules-skill/issues/94) reported a `dangerous` verdict; checking each claim against the tree turned up four real defects, fixed with regression tests, and the proposed restructuring was declined because it would not have changed the verdict. [netresearch/concourse-ci-skill#76](https://github.com/netresearch/concourse-ci-skill/pull/76) proposes clearing `ssh_dir_access` by writing the key to `deploy_key` in the task root, then running `cd source/ansible` and passing `--private-key=../deploy_key`, which resolves to `source/deploy_key` — a file that is never written.
