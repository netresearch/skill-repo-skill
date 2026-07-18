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

## Gotchas

- **Installed plugins outlive the marketplace entry.** Removing the entry does
  not uninstall existing local installations — they keep working from the
  plugin cache. Announce the retirement (team channel) so users uninstall.
- **README edits after archiving require unarchiving first.** Get the wording
  right before step 4.
- **Do not delete the repo or its tags.** Released versions may still be
  referenced by lockfiles, Satis indexes, or npm/composer installs.
