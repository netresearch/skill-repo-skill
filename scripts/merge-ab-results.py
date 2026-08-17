#!/usr/bin/env python3
"""Merge one run-ab-evals.sh ab-results.json into the dashboard data file.

Updates (or inserts) the entry for a single skill in
docs/dashboard/data/results.json, preserving all other entries. The result
block is keyed by the model id recorded in the run's provenance block, and
the provenance block itself is stored on the entry.

Usage:
    merge-ab-results.py --data-file docs/dashboard/data/results.json \
        --name file-search --repo netresearch/file-search-skill \
        --ab-results /tmp/ab-out/file-search.json \
        [--category tooling] [--version 1.3.0] \
        [--skill-path skills/file-search/SKILL.md] \
        [--evals-path skills/file-search/evals/evals.json]
"""

import argparse
import datetime
import json
import pathlib
import sys


def contained_json_path(raw: str, must_exist: bool) -> pathlib.Path:
    """Resolve a CLI-supplied path; refuse escapes from the working tree.

    Both callers pass workspace-relative paths; anything resolving outside
    the current working tree (or without a .json suffix) is rejected before
    any file access.
    """
    root = pathlib.Path.cwd().resolve()
    resolved = pathlib.Path(raw).resolve()
    if not resolved.is_relative_to(root):
        sys.exit(f"refusing path outside {root}: {raw}")
    if resolved.suffix != ".json":
        sys.exit(f"refusing non-.json path: {raw}")
    if must_exist and not resolved.is_file():
        sys.exit(f"not a file: {raw}")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-file", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--ab-results", required=True)
    parser.add_argument("--category", default="")
    parser.add_argument("--version", default="")
    parser.add_argument("--skill-path", default="")
    parser.add_argument("--evals-path", default="")
    args = parser.parse_args()

    data_file = contained_json_path(args.data_file, must_exist=True)
    ab_results = contained_json_path(args.ab_results, must_exist=True)
    with open(data_file) as f:
        data = json.load(f)
    with open(ab_results) as f:
        ab = json.load(f)

    if not isinstance(data, dict) or not isinstance(data.get("skills"), list):
        sys.exit(
            f"{args.data_file}: malformed data file "
            f"(expected an object with a 'skills' array)"
        )

    provenance = ab["provenance"]
    combined = ab["totals"]["combined"]
    checks = combined["checks"]
    if checks <= 0:
        print(f"{args.name}: no graded checks in {args.ab_results}; not merging")
        return 1

    without_rate = round(combined["without"] / checks, 4)
    with_rate = round(combined["with"] / checks, 4)

    entry = next(
        (
            s
            for s in data["skills"]
            if s.get("repo") == args.repo or s.get("name") == args.name
        ),
        None,
    )
    if entry is None:
        entry = {"top_finding": ""}
        data["skills"].append(entry)

    entry["name"] = args.name
    entry["repo"] = args.repo
    entry["eval_count"] = ab["eval_count"]
    entry["results"] = {
        provenance["model"]: {
            "without_skill_pass_rate": without_rate,
            "with_skill_pass_rate": with_rate,
            "delta": round(with_rate - without_rate, 4),
        }
    }
    entry["provenance"] = provenance
    # A delta belongs to the actor tuple it was measured under, so the
    # dashboard has to be able to render it next to the number. Older runs
    # have no harness field; say so rather than implying the current one.
    provenance.setdefault("harness", "unknown")
    if "discriminating_checks" in ab:
        entry["discriminating_checks"] = ab["discriminating_checks"]
    if "evals_without_delta" in ab:
        entry["evals_without_delta"] = ab["evals_without_delta"]
    if args.category:
        entry["category"] = args.category
    entry.setdefault("category", "other")
    if args.version:
        entry["version"] = args.version
    entry.setdefault("version", "unknown")
    if args.skill_path:
        entry["skill_path"] = args.skill_path
    if args.evals_path:
        entry["evals_path"] = args.evals_path

    data["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    with open(data_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    version = entry.get("version", "unknown")
    print(
        f"{args.name}@{version}: merged {checks} checks "
        f"(without={without_rate} with={with_rate} "
        f"delta={entry['results'][provenance['model']]['delta']}) "
        f"model={provenance['model']} harness={provenance['harness']}"
    )
    no_delta = entry.get("evals_without_delta") or []
    if no_delta:
        print(
            f"{args.name}: {len(no_delta)} eval(s) with no check the baseline "
            f"fails: {', '.join(no_delta)}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
