# Skill Retirement

How to decommission a skill that is superseded (e.g. by automation) or obsolete.
Order matters — each step keeps the trail auditable and every action reversible.

## Workflow

1. **Verify the successor.** Confirm the replacing process or tooling is live
   (ticket closed, automation running) before removing anything.

2. **Remove the marketplace entry.** MR/PR against the marketplace repo:
   delete the plugin entry from `marketplace.json` **and** the README skill
   table. Run the marketplace's own validator before committing
   (`make validate` in the Netresearch internal marketplace).

3. **Add a deprecation notice** at the top of the skill repo's README — name
   the successor and the tracking ticket. Push this **before** archiving:
   archived repos are read-only.

   ```markdown
   > **⚠️ DEPRECATED / ARCHIVED (<month year>)**
   >
   > Superseded by <successor> (<ticket>). This repository is archived.
   ```

4. **Archive the repository — never delete.** Archiving is reversible and
   preserves history, tags, and MRs.

   ```bash
   glab repo archive https://git.netresearch.de/GROUP/PROJECT   # GitLab
   gh repo archive OWNER/REPO                                   # GitHub
   ```

5. **Uninstall locally and verify propagation.**

   ```bash
   claude plugin uninstall <name>@<marketplace>
   claude plugin marketplace update <marketplace>   # refresh cache
   grep -c "<name>" <marketplace-cache>/.claude-plugin/marketplace.json  # expect 0
   ```

6. **Document in the tracking ticket.** What was removed, MR links, archive
   status — so the ticket history is self-contained.

## Relocation: the skill moves to another repository

When a skill is not retired but moves — typically into the repository whose
scripts it wraps, so a drifting copy disappears — the plugin keeps its name
and only the marketplace entry's `source.repo` changes. Done for `cli-tools`,
moved from `cli-tools-skill` into `coding_agent_cli_toolset` (2026-09):

1. **Port first, then move.** Fixes that exist only in the old repository
   go to the new one before anything is repointed; otherwise the move
   silently regresses them.
2. **Ship the plugin from the new repository** (`.claude-plugin/plugin.json`
   with the same `name`, skill under `skills/<name>/`) and verify it loaded
   live before touching the marketplace — `claude -p` needs a prompt, e.g.
   `claude -p --plugin-dir <checkout> "List the skills you have loaded"`; for
   a hook, see [plugin-hooks](plugin-hooks.md).
3. **Decide the version source.** Without `version` in `plugin.json` *and* in
   the marketplace entry, Claude Code versions the plugin by the source's
   commit SHA, so every merge to the default branch becomes available on the
   user's next plugin update (see below for what that takes). That fits
   a repository with no release flow; a fixed `version` would freeze users
   until someone bumps it. Such a repository does not belong in the release
   fleet list either — say so there, or the next refresh re-adds it.
4. **Repoint the marketplace entry** (and the README row); every consumer
   that links into the old repository is updated in the same sweep.
5. **Moved notice, then archive**, as in steps 3–4 above.

**How existing installations switch over (measured).** Third-party
marketplaces do not auto-update by default, and `plugin update` alone reads
the cached catalog. Users need both:

```bash
claude plugin marketplace update <marketplace>
claude plugin update <name>@<marketplace>   # 1.9.2 -> <commit sha> for cli-tools
```

Name both commands in the moved notice.

## Gotchas

- **Installed plugins outlive the marketplace entry.** Removing the entry does
  not uninstall existing local installations — they keep working from the
  plugin cache. Announce the retirement (team channel) so users uninstall.
- **README edits after archiving require unarchiving first.** Get the wording
  right before step 4.
- **Do not delete the repo or its tags.** Released versions may still be
  referenced by lockfiles, Satis indexes, or npm/composer installs.
