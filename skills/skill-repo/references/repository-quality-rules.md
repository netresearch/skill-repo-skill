# Repository Quality Rules (skill repositories)

Prüfbare Regeln für **einzelne Skill-Repositories** (`netresearch/*-skill`).  
**Nicht** für das Marketplace-Repository — Discovery-Katalog- und SEO-Governance für den Hub liegen in **`netresearch/claude-code-marketplace`** (`AGENTS.md` dort).

---

## Lizenz (Netresearch Split-Modell)

- **PASS**, wenn `LICENSE-MIT` und `LICENSE-CC-BY-SA-4.0` vorhanden sind und **keine** bare `LICENSE`-Datei existiert (siehe `validate-skill.sh` / Checkpoints).
- **PASS für „LICENSE oder LICENSE.md“-Anforderungen außerhalb Netresearch:** Split-Lizenz gilt als erfüllte Lizenzpflicht; einzelne `LICENSE`-Datei ist hier **FAIL**, wenn sie das Split-Modell ersetzt.

---

## Mindestbestandteile eines Skill-Repos

Jedes Repo **muss** die folgenden Elemente enthalten **oder** eine **explizite Begründung** in `README.md` unter z. B. `## Repository extras` (warum ein Pflichtobjekt fehlt).

| Element | Prüfregel |
| --- | --- |
| `README.md` | Datei existiert (`validate-skill.sh`). |
| Lizenz | `LICENSE-MIT` + `LICENSE-CC-BY-SA-4.0` (Policy). |
| `CONTRIBUTING.md` | Datei existiert **oder** README verlinkt auf ein externes Contributing-Dokument und nennt den Ort (**ein** kanonischer Ort). |
| `SECURITY.md` | Datei existiert **oder** README enthält Abschnitt „Security“ mit Kontakt/Ort der Policy. **Ausnahme:** klar als **private/internal-only** gekennzeichnete Repos — dann **muss** das im README stehen (`Private-only: no SECURITY.md`). |
| `.github/pull_request_template.md` | Datei existiert **oder** Issue/PR-Richtlinie ist in `CONTRIBUTING.md` als PR-Checkliste beschrieben (mind. 5 konkrete Checkboxen). |
| Skill-Verzeichnis mit `SKILL.md` | Pfad entspricht `.claude-plugin/plugin.json` → `skills`. |
| `agents/openai.yaml` | Datei existiert **oder** Begründung + Alternative (z. B. „Agent Stack nicht OpenAI“) im README. |
| `references/`, `scripts/`, `assets/` | **PASS**, wenn SKILL.md alle Referenzen erreichbar macht **oder** README erklärt bewusst schlankes Repo („no references: …“). |

---

## Pflicht für README-Oberfläche

Siehe [`readme-template.md`](readme-template.md) für die **exakten Überschriften** und [`skill-discovery-metadata.md`](skill-discovery-metadata.md) für YAML-Zusatzfelder außerhalb von `SKILL.md`.

---

## SKILL.md vs. Discovery

- **`SKILL.md`**: Laufzeitverhalten, Trigger, Arbeitsablauf — siehe [`skill-quality.md`](skill-quality.md).
- **Discovery / SEO / Marketplace-Felder**: README, `agents/openai.yaml`, optionale Metadatei(en), GitHub Description/Topics — **nicht** als zusätzliche YAML-Schlüssel im `SKILL.md`-Frontmatter für Katalogzwecke.

### Frontmatter (technische Grenze)

- **Erforderlich:** `name`, `description` (mit Präfix `Use when…`).
- **Verboten für Discovery:** eigene Schlüssel wie `slug`, `tags`, `category`, `keywords`, `seo_*` im Frontmatter.
- **Optional** (Agent Skills / Validator): `license`, `compatibility`, `metadata`, `allowed-tools` — nur wenn technisch nötig; keine Marketing-/SEO-Felder dort.

---

## Related Skills (Repo-Ebene)

- Im README oder in Discovery-YAML **als Slugs oder volle URLs** angeben.
- **PASS**, wenn mindestens ein Eintrag **oder** die Zeile `Related skills: none (justified — …)` mit Grund vorhanden ist.
- **FAIL**, wenn beliebige Links nur für SEO gesetzt sind (nicht fachlich nachvollziehbar).

---

## Marketplace-Sync (Quelle bleibt Repo)

Bei Änderungen an Discovery-Inhalten: siehe [`marketplace-integration.md`](marketplace-integration.md). Agents **müssen** am Ende einer Änderung prüfen, ob Marketplace-Felder aktualisiert werden müssen (oder Override dokumentiert ist).

---

## GitHub Repository SEO

### Repository Description

- **PASS:** String length **≤ 160** characters (count before save).
- **PASS:** Mentions **concrete technology** (e.g. TYPO3, OroCommerce, Docker) **or** a **named task domain** (e.g. “extension PHPUnit matrix”, “Vite sitepackage build”).
- **FAIL:** Generic phrases such as “Useful AI skill for developers”, “ultimate automation assistant”.
- **PASS:** Understandable **without** opening `README.md`.

**Good:** `Agent skill for TYPO3 Vite setup, SCSS architecture and frontend asset integration.`  
**Bad:** `Useful AI skill for developers.`

### GitHub Topics

- **PASS:** Includes **`agent-skill`**.
- **PASS:** At least **one** stack tag (`typo3`, `php`, `docker`, …) or domain tag (`testing`, `security`, `frontend`, …) matching the skill.
- **FAIL:** Irrelevant trending tags just for visibility (keyword stuffing).
- Document proposed topics in README under `## Repository extras` if maintainers cannot edit Topics immediately.

---

## GitHub Pages policy

The [marketplace](https://github.com/netresearch/claude-code-marketplace) is the canonical public discovery and storytelling layer for all Netresearch Agent Skills. Repository Pages are **secondary, skill-specific documentation surfaces**.

### Default: Pages disabled

Skill repositories **must not** enable GitHub Pages by default.

- **PASS:** `gh api repos/netresearch/<repo>/pages` returns **HTTP 404** (Pages disabled).
- **FAIL:** Pages is enabled without satisfying the criteria below.

### When Pages is appropriate

Enable GitHub Pages only when the repository contains standalone public material that is too large, too visual, too navigational, or too strategically important to live well in `README.md`. **At least one** of the following must be true:

- the documentation requires multiple pages,
- the skill has a gallery of examples, reports, dashboards, screenshots or demos,
- the skill publishes generated reference documentation,
- the skill provides versioned documentation,
- the skill is a public reference implementation,
- the skill explains a reusable methodology or assessment model,
- the skill has a specific SEO target that the marketplace landing cannot cover without becoming too broad.

### When Pages is NOT appropriate

Do not enable Pages if the site would only duplicate:

- the README,
- the marketplace detail page (`https://github.com/netresearch/claude-code-marketplace#<slug>` or the future landing),
- installation instructions,
- `SKILL.md`,
- the basic example prompts.

### Mandatory artefacts when Pages is enabled

If Pages is enabled, the repository **must** include:

- a short justification block in `README.md` (which criterion above is satisfied),
- a documented canonical URL pointing at the Pages site,
- a clear source path (default: `docs/`),
- documented build and deployment commands (`make docs`, `npm run docs`, or equivalent — referenced from the README),
- link-checking or equivalent validation in CI,
- a note explaining which content belongs on Pages vs. README vs. marketplace.

### Mirroring rule

Skill-specific metadata originates in the skill repository (`metadata/discovery.yaml`, README sections, `agents/openai.yaml`, GitHub settings). The marketplace consumes it. Do not duplicate the same metadata across README, Pages site and marketplace landing — pick one canonical surface per fact and link from the others.
