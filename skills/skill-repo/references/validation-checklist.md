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
| claude.ai marketplace import | unknown manifest fields, **symlinks whose target is not in the repository**, **angle brackets in a `SKILL.md` description** (reported as XML tags), **a `SKILL.md` description over 1024 characters**, **a plugin description over 500**, **a top-level `bin/`**, **a plugin source URL that is not `https://`** — see [claude.ai Organization settings sync](#claudeai-organization-settings-sync) | — |

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

A marketplace distributed through claude.ai **Organization settings › Plugins** is packaged by a sync that applies rules no local tool enforces. `claude plugin validate` 2.1.281 passes all of them: it accepts a 2033-character description as `validate .` and as `validate skills`. Measured on 2026-09-23 against `coding-ai/marketplace` on git.netresearch.de, where the first sync skipped every plugin and the second reported 38 warnings across 13 plugins.

| Rule | Sync message | Fix |
|---|---|---|
| Plugin source URL is `https://` | `Git source URL must use https://` | the scp form `git@host:path` is rejected even for a `url` source on the marketplace's own GitLab host |
| `SKILL.md` description has no `<` | `SKILL.md description cannot contain XML tags` | write a placeholder as `{NAME}`, never `<NAME>` — same meaning, same length |
| `SKILL.md` description ≤ 1024 characters | `field 'description' in SKILL.md must be at most 1024 characters` | cut process detail into the body; keep every backticked command and quoted example phrasing |
| Plugin description ≤ 500 characters | `Plugin description must be at most 500 characters` | checked against the **marketplace entry** — the eight plugins reported were exactly the eight manifest entries over 500, while only three of their `plugin.json` copies were |
| No top-level `bin/` | `Plugin contains a top-level bin/ directory` | the whole plugin is skipped and stays at its last synced version; move the executables to `scripts/` and call them by full path |

Three properties of the sync decide how to check for these:

- **It reports only the first failure per file.** A description that is both too long and bracketed shows only the length warning; the fleet had 18 reported bracket violations and 29 real ones. Fix the class, then re-check — do not fix the reported instance.
- **Length is the parsed YAML value**, not the raw frontmatter line. A single-quoted scalar doubles every apostrophe it contains, so the raw slice runs long: 1029 raw against 1023 parsed on one description, which decides a 1024 limit. Measure with a YAML parser.
- **A private `url` source is only readable on the marketplace's own GitLab host**, through the access token of the organization's GitLab configuration. A group access token with `read_repository` on the group holding the plugins covers all of them.

Where a marketplace's CLI users rely on the SSH form, rewriting the URLs breaks every existing `/plugin marketplace add git@…` until each machine gains a credential helper or an `insteadOf` rule. Keep the SSH form in the source repository and point the sync at a generated mirror that differs only in the URL scheme; the mirror has to be regenerated after every manifest change. The internal GitLab fleet enforces the description and `bin/` rules in the `validate:descriptions` job of `ci-components/claude-code-skill`.
