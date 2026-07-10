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
import sys


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

    with open(args.data_file) as f:
        data = json.load(f)
    with open(args.ab_results) as f:
        ab = json.load(f)

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

    with open(args.data_file, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(
        f"{args.name}: merged {checks} checks "
        f"(without={without_rate} with={with_rate} "
        f"delta={entry['results'][provenance['model']]['delta']}) "
        f"model={provenance['model']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
