# Security Audit Notes

## Known Scanner Findings (False Positives)

### Snyk E006 — CRITICAL: "Malicious code pattern" in migrate-licensing.sh

**Status:** False positive. Intentional tool.

The `scripts/migrate-licensing.sh` replaces GPL/MIT LICENSE files with split licensing (LICENSE-MIT + LICENSE-CC-BY-SA-4.0) and updates composer.json/plugin.json metadata. This is a one-time migration tool used to standardize licensing across Netresearch skill repos. It does not exfiltrate data, install backdoors, or perform any malicious operations.

**Evidence:** The script only modifies license-related files and metadata fields. All changes are committed via git and reviewable in PR diffs.
