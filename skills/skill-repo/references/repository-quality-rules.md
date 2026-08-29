# Repository Quality Rules (skill repositories)

## Contents

- Lizenz (Netresearch Split-Modell)
- Mindestbestandteile eines Skill-Repos
- Scripts-first (mechanisch prüfbare Regeln)
- Pflicht für README-Oberfläche
- SKILL.md vs. Discovery
- allowed-tools (vorab gewährte Rechte)
- Related Skills (Repo-Ebene)
- Marketplace-Sync (Quelle bleibt Repo)
- GitHub Repository SEO
- GitHub Pages policy

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

## Scripts-first (mechanisch prüfbare Regeln)

Generalisiert die Routing-Regel der retro-skill `destination-taxonomy` („mechanisch erkennbare Regel → `checkpoints.yaml`“) auf die Autorenseite: Was sich mechanisch prüfen lässt, wird nicht als Prosa ausgeliefert.

- **PASS**, wenn jede mechanisch prüfbare Anforderung (Regex, Datei-Existenz, Kommando mit Exit-Code) als Eintrag in `checkpoints.yaml` **oder** als Script in `scripts/` vorliegt und der Fließtext nur mit **einer** Zeile darauf verweist.
- **FAIL**, wenn eine mechanisch prüfbare Anforderung ausschließlich als Prosa-Anweisung existiert — der Agent muss sie dann bei jeder Anwendung neu interpretieren, und Abweichungen bleiben unentdeckt.
- **Hinweis:** Checkpoint-Patterns unterliegen der Runner-Allowlist (`is_safe_eval_command`, automated-assessment `run-checkpoints.sh`): einzeilig, kein `bash` als Basiskommando, kein `;`/`&&`/`$()`; Repo-Scripts sind dort nicht aufrufbar — komplexe Prüfungen gehören nach `scripts/` und werden im Checkpoint als allowlist-konformes Pattern **gespiegelt, nicht aufgerufen** (Beispiel: Checkpoint SR-37 spiegelt `skills/skill-repo/scripts/check-version-parity.sh`).
- **FAIL**, wenn ein `llm_reviews`-Checkpoint einen ausführbaren Befehl am Zeilenanfang enthält. Ein Prompt, der eine Shell-Pipeline zeigt, beschreibt eine mechanische Prüfung in Prosa — sie läuft nie und kann nicht regressieren. Gehört der entscheidende Teil nach `mechanical`, bleibt im LLM-Eintrag nur die Bewertung, die das Kommando nicht leisten kann. Behält ein Eintrag bewusst beide Hälften, deklariert er das mit `# mechanical-counterpart: <ID>` im Block; `validate-skill.sh` prüft beides.
- **FAIL**, wenn ein ausgeliefertes Script unter `scripts/` von keinem Test unter `tests/` referenziert wird. Skripte sind die ausführbare Oberfläche eines Skills, und ohne Test überlebt ein Defekt beliebig lange: eine Flottenmessung fand **276 Scripts in 27 von 33 Repos** ohne eine einzige Testdatei, darunter ein Verifier, der wegen `set -e` plus `((VAR++))` seit Jahren nach dem ersten Treffer abbrach und 11 von 12 Abschnitten übersprang. Ausgeführt werden die Tests vom Reusable `netresearch/skill-repo-skill/.github/workflows/tests.yml@main` — ein Test, den keine Pipeline startet, ist kein Gate.
- Inhaltliche Bewertung, was überhaupt in einen Skill gehört: siehe Content value rubric in [`skill-quality.md`](skill-quality.md).

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
- **Optional** (Agent Skills / Validator): `license`, `compatibility`, `metadata`, `allowed-tools` — nur wenn technisch nötig; keine Marketing-/SEO-Felder dort. Zur Formulierung von `allowed-tools` siehe unten.

---

## allowed-tools (vorab gewährte Rechte)

`allowed-tools` schaltet für den Zug, in dem der Skill aufgerufen wird, die Rückfrage ab. Das Feld beschränkt nichts: laut Doku bleibt jedes Tool aufrufbar, und für alles Nichtgenannte greifen weiterhin die normalen Berechtigungseinstellungen. Was in der Zeile steht, ist also nicht die Fähigkeit des Skills, sondern die Fläche, auf der er ohne Nachfrage arbeitet — und genau die liest ein Prüfer, der ein fremdes Repo bewertet.

**Regel: Ein Skill, der eigene Skripte mitbringt, deklariert die Skripte, nicht den Interpreter.**

```yaml
# ❌ deckt jedes bash-Kommando ab, das der Skill je absetzt
allowed-tools: Bash(bash:*) Read Glob Grep

# ✅ deckt das Skriptverzeichnis ab statt jeden bash-Aufruf
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*) Read Glob Grep
```

Beide Formen gehören in die Zeile: ein Muster greift über das Präfix, und `./foo.sh` und `bash foo.sh` haben verschiedene. Wer Python-Skripte mitliefert, braucht `Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/*)` zusätzlich — oder ruft sie direkt auf, was Ausführungsbit und Shebang voraussetzt.

Das Muster begrenzt auf ein Präfix, nicht auf eine Dateimenge: `*` schließt `/` ein, ein Aufruf mit `..` im Pfad liegt also formal noch darin. Wer eine harte Grenze braucht, zählt die Skripte einzeln auf — das kostet einen Eintrag je Skript und muss beim nächsten neuen Skript nachgezogen werden. Für die meisten Skills ist das Verzeichnismuster der richtige Tausch, solange man es als das liest, was es ist.

Claude Code ersetzt `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PROJECT_DIR}` und in Plugin-Skills `${CLAUDE_PLUGIN_ROOT}` an zwei Stellen: im Text der `SKILL.md` und in den Bash-Regeln des Frontmatters. Deshalb funktioniert das Muster über Installationsarten und Versionsstände hinweg, ohne einen Pfad festzuschreiben. `${CLAUDE_SKILL_DIR}` ist die breitere Wahl, weil sie auch außerhalb einer Plugin-Installation gesetzt ist.

Zwei Fallstricke:

- **Muster und Aufruf müssen zusammenpassen.** `bash x.sh` und `./x.sh` sind verschiedene Präfixe. Wenn die `SKILL.md` relative Aufrufe dokumentiert (`scripts/foo.sh PATH`), trifft eine absolute Regel sie nicht — dann kommt bei jedem Skriptaufruf eine Rückfrage, die der Nutzer wegklickt. Skill-Text und Regel gehören in denselben Commit.
- **Werkzeuge, die der Agent selbst absetzt, bleiben separat.** Verifiziert der Skill Ergebnisse mit `git`, `jq` oder `grep`, gehören die weiter einzeln in die Zeile. Die Regel betrifft den Interpreter-Platzhalter, nicht jede Bash-Regel.

Nach dem Umstellen einmal im Standardmodus durchlaufen, mit unveränderten Einstellungen — nicht unter `--dangerously-skip-permissions`, und nicht mit einer `permissions.allow`-Regel, die dasselbe Kommando ohnehin freigibt. Sonst beweist keines der beiden Ergebnisse etwas: eine ausbleibende Rückfrage kann von einer anderen Freigabe kommen, und eine Rückfrage kann aus einer `ask`- oder `deny`-Regel stammen, die `allowed-tools` unabhängig vom Muster sticht — ein zusammengesetztes Kommando braucht ohnehin für jeden Teil einen Treffer. Im Zweifel das tatsächlich abgefragte Kommando gegen die geltenden Regeln halten, bevor das Muster geändert wird.

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

### Repository / skill name

- **PASS:** Leads with the **rankable proper noun** of the tool/domain (e.g. `jujutsu`, `oro`, `vite`) — not a generic short alias that is crowded in search (e.g. `jj`).
- **FAIL:** Spends name tokens on **redundant words** — `agent`, `agentic`, or `ai` in the repository name, or `skill` in the skill slug. The repository's `-skill` suffix and the marketplace already imply "agent skill"; **every** skill is for agents, so these add no discriminating signal.
- **PASS:** The remaining token names the **distinctive function** (`-workflow`, `-conformance`, `-upgrade`, …) so the slug isn't a bare proper noun colliding with a sibling skill's `name`.
- **PASS:** Name candidates validated against GitHub search results — `gh search repos "<candidate phrase>"` — preferring an uncontested, descriptive phrase over a crowded generic one.
- **PASS:** Short aliases or command names (e.g. `jj`) are kept in the **description and topics** rather than spent on the slug, so command-searchers still match.

- **Good:** repo `jujutsu-workflow-skill`, skill `jujutsu-workflow` (rankable noun + function; `jj` lives in description/topics).
- **Bad:** `jj-agent-workflow-skill` (`jj` is generic/crowded; `agent` is redundant for a skill).

### Repository Description

- **PASS:** String length **≤ 160** characters (count before save).
- **PASS:** Mentions **concrete technology** (e.g. TYPO3, OroCommerce, Docker) **or** a **named task domain** (e.g. “extension PHPUnit matrix”, “Vite sitepackage build”).
- **FAIL:** Generic phrases such as “Useful AI skill for developers”, “ultimate automation assistant”.
- **PASS:** Understandable **without** opening `README.md`.

- **Good:** `Agent skill for TYPO3 Vite setup, SCSS architecture and frontend asset integration.`
- **Bad:** `Useful AI skill for developers.`

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
