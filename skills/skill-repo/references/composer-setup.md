<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Composer Setup for Skills

## Contents

- When to Add composer.json
- composer.json Structure
- Multi-Skill Packages
- Publishing to Packagist
- Skill repos that ship their own PHP code
- Files to NOT Include
- Validation
- Integration with Plugin
- Troubleshooting

Guide for adding Composer distribution to Netresearch skills.

## When to Add composer.json

Add `composer.json` to ALL skills **EXCEPT** those explicitly targeting non-PHP ecosystems.

| Skill Type | composer.json |
|------------|---------------|
| PHP/TYPO3 skills | Required |
| General skills | Required |
| Go-specific skills | Not needed |
| Rust-specific skills | Not needed |

## composer.json Structure

### Basic Structure

```json
{
  "name": "netresearch/{skill-name}-skill",
  "description": "{Skill description from SKILL.md}",
  "type": "ai-agent-skill",
  "license": "(MIT AND CC-BY-SA-4.0)",
  "authors": [
    {
      "name": "Netresearch DTT GmbH",
      "email": "plugins@netresearch.de",
      "homepage": "https://www.netresearch.de/",
      "role": "Manufacturer"
    }
  ],
  "require": {
    "netresearch/composer-agent-skill-plugin": "*"
  },
  "extra": {
    "ai-agent-skill": "SKILL.md"
  }
}
```

### Key Fields

| Field | Value | Purpose |
|-------|-------|---------|
| `name` | `netresearch/{repo-name}` | Must match GitHub repo name exactly |
| `type` | `ai-agent-skill` | Enables plugin discovery |
| `require` | `composer-agent-skill-plugin` | Plugin dependency |
| `extra.ai-agent-skill` | Path to SKILL.md | Skill location |

### Package Naming Convention

- **Rule: composer name = GitHub repo name** (`netresearch/{repo-name}`)
- All skill repos are named `*-skill` on GitHub
- Examples:
  - Repo `netresearch/typo3-docs-skill` → composer name `netresearch/typo3-docs-skill`
  - Repo `netresearch/jira-skill` → composer name `netresearch/jira-skill`

## Multi-Skill Packages

For packages containing multiple skills:

```json
{
  "name": "netresearch/{name}-skill",
  "type": "ai-agent-skill",
  "extra": {
    "ai-agent-skill": [
      "skills/skill-one/SKILL.md",
      "skills/skill-two/SKILL.md"
    ]
  }
}
```

### Example: jira-skill

```json
{
  "name": "netresearch/jira-skill",
  "extra": {
    "ai-agent-skill": [
      "skills/jira-communication/SKILL.md",
      "skills/jira-syntax/SKILL.md"
    ]
  }
}
```

## Publishing to Packagist

### Prerequisites

1. GitHub repository is public
2. composer.json is valid
3. Packagist account linked to GitHub

### Steps

1. Create version tag:
   ```bash
   git tag v1.0.0
   git push --tags
   ```

2. Register on Packagist:
   - Go to <https://packagist.org/packages/submit>
   - Enter repository URL
   - Submit

3. Check the auto-update webhook. When the Packagist account is linked to GitHub and the Packagist GitHub application has access to the organization, submitting the package makes Packagist create a repository webhook to `https://packagist.org/api/github` itself; its latest delivery in the repository's webhook settings answers 202. Only when no such hook exists, add one by hand with the values from <https://packagist.org/about#how-to-update-packages>: payload URL `https://packagist.org/api/github?username=<Packagist username>`, content type `json`, the push event only, the account's API token as the secret. Without `?username=` the hook answers 403 on every push, and Packagist keeps the state of its last crawl, so no later tag reaches `composer require`. Do not add a second hook next to a working one.

The API alternative to the submit form is `POST https://packagist.org/api/create-package` with the body `{"repository": "https://github.com/<org>/<repo>"}`, `Content-Type: application/json` and `Authorization: Bearer <username>:<main API token>`. It answers 202, and the first crawl followed within a minute when this was done for the skill repos. The Packagist API documentation marks the endpoint as requiring the main token; the safe token is not enough.

Check the result where Composer looks, not on the package page: `https://repo.packagist.org/p2/<vendor>/<name>.json` answers 404 for a name Composer cannot install. The reusable `release.yml` runs that check after every release and fails on 404.

### Renaming the package

Changing `name` in `composer.json` does not rename anything on Packagist. Packagist keeps the package under the name it was submitted with and publishes every later tag there, so the new name answers 404 and `composer require <new name>` fails with "Could not find a matching version of package". Until 2026-10-18 none of the 39 Netresearch skill repos was installable under its `composer.json` name: 16 were on Packagist only under an older name (`agent-*`, `agents-skill`), and 23 had never been submitted.

A rename therefore takes three steps:

1. Keep `"replace": {"<old name>": "self.version"}` in `composer.json`. When a project requires the new name and something in its tree still requires the old one, the new package satisfies both and is installed once, instead of two copies of the same skill. `self.version` makes the old name available only at the new package's own version, so this works while the old constraint (for example `^2.20`) accepts that version; a constraint the new versions do not meet has to be updated. A project that requires only the old name keeps installing the old package. The entry names the old package, never the package's own name: Packagist rejects every tag whose `replace` lists the package itself (`a package cannot set a replace on itself`). The rejected tags stay rejected, so a corrected `composer.json` reaches Packagist only with a new tag. The maintainer mail "failed to update due to invalid data" is sent only for an invalid branch: Composer's `VcsRepository` sets `branchErrorOccurred` in its branch loop, never for a skipped tag. After the fix, every remote branch that still carries the old `composer.json` keeps the mail coming until it is rebased or deleted; check them with `composer validate` on each branch's file. automated-assessment-skill shipped the new name there from v2.1.0 to v2.19.1, and Packagist served v2.0.0 until v2.19.2. The `Composer schema` step of the shared `validate.yml` runs `composer validate` and fails on this entry.
2. Submit the repository again, through the form or `create-package` above. Packagist reads the new name from `composer.json` and creates a second package for the same repository.
3. Mark the old package abandoned with the new name as its replacement (`https://packagist.org/packages/<old name>/abandon`, replacement field `package[replacement]`). Composer then prints the replacement to anyone who still installs the old name.

## Skill repos that ship their own PHP code

A skill repo with its own `src/`, `bin/` and dependencies runs `composer install` in its own root, locally and in CI. That activates `netresearch/composer-agent-skill-plugin` on the skill repo itself, and the plugin registers the repo as a skill inside itself:

- `extra.ai-agent-skill` is rewritten from the string path into an object (`{"skills": [...], "allow-skills": []}`). `validate-skill.sh` then fails with `composer.json extra.ai-agent-skill could not be parsed`.
- A `<skills_system>` block is appended to `AGENTS.md`.
- `composer.json.skill-trust.lock` appears next to `composer.json`.

Deny the plugin in the repo's own config. The package is the skill and has nothing to install into itself. Consumers are unaffected — `allow-plugins` applies to the root package, so an installing project decides for itself:

```json
{
  "config": {
    "allow-plugins": {
      "netresearch/composer-agent-skill-plugin": false
    }
  }
}
```

The field is not optional once the repo has dependencies of its own: without an entry, a non-interactive `composer install` exits 1 with `blocked by your allow-plugins config` instead of prompting.

Cover the artefacts in `.gitignore`:

```gitignore
/vendor/
/composer.lock
composer.json.skill-trust.lock
```

## Files to NOT Include

**Never add these to skill repos:**

- `composer.lock` - Locks are for applications, not libraries
- `vendor/` - Dependencies installed by users

## Validation

Check composer.json validity:

```bash
# Syntax check
composer validate

# Check type
grep '"type"' composer.json | grep "ai-agent-skill"

# Check plugin requirement
grep "composer-agent-skill-plugin" composer.json
```

## Integration with Plugin

The `composer-agent-skill-plugin` automatically:

1. Discovers installed `ai-agent-skill` packages
2. Parses SKILL.md frontmatter
3. Generates AGENTS.md index
4. Provides `composer list-skills` command
5. Provides `composer read-skill {name}` command

## Troubleshooting

### "Package not found"

- Ensure package is published on Packagist
- Check package name matches exactly
- Run `composer clear-cache`

### "Plugin not activated"

When prompted, allow the plugin:
```
Do you trust "netresearch/composer-agent-skill-plugin"? [y,n,d,?]
```

Or pre-authorize in composer.json:
```json
{
  "config": {
    "allow-plugins": {
      "netresearch/composer-agent-skill-plugin": true
    }
  }
}
```

This is the setting for a **consuming** project. A skill repo that ships its own PHP code sets it to `false` for itself — see [Skill repos that ship their own PHP code](#skill-repos-that-ship-their-own-php-code).

### "SKILL.md not found"

- Verify path in `extra.ai-agent-skill`
- Paths must be relative from package root
- Absolute paths are rejected for security
