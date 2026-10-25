#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check captured agent evidence; never run an agent or infer tools from prose.

Usage: uv run validate-agent-evidence.py RUN.json
Exit: 0 = measured pass, 1 = measured fail, 2 = invalid or incomplete evidence.
The collector and independent outcome verifier are trusted inputs. Hashes bind
their files, not their truth. See references/agent-evidence.md for the contract.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

PROVENANCE = (
    "model",
    "harness",
    "tool_environment",
    "skill_revision",
    "task_revision",
    "target_revision",
    "effort",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def artifact(spec, root):
    require(isinstance(spec, dict), "artifact must name path and sha256")
    require(nonempty(spec.get("path")), "artifact path is required")
    path = (root / spec["path"]).resolve()
    require(
        path.is_relative_to(root.resolve()),
        "artifact must remain inside the run directory",
    )
    require(path.is_file(), f"missing artifact: {spec['path']}")
    content = path.read_bytes()
    require(
        hashlib.sha256(content).hexdigest() == spec.get("sha256"),
        f"artifact hash mismatch: {spec['path']}",
    )
    return content.decode("utf-8")


def trajectory_events(text):
    try:
        raw = json.loads(text)
    except json.JSONDecodeError:
        raw = [json.loads(line) for line in text.splitlines() if line.strip()]
    if isinstance(raw, dict) and isinstance(raw.get("steps"), list):
        return "atif", raw["steps"], raw.get("continued_trajectory_ref") is not None
    if isinstance(raw, dict):
        raw = [raw]
    require(
        isinstance(raw, list) and bool(raw),
        "trajectory must contain ATIF steps or Claude events",
    )
    require(all(isinstance(e, dict) for e in raw), "invalid trajectory event")
    require(
        any(e.get("type") in {"assistant", "result"} for e in raw),
        "unknown trajectory format",
    )
    return "claude", raw, False


def recorded_calls(text):
    """Return structured invocations, returned call IDs and a recorded run error.

    ATIF is Harbor's steps/tool_calls/observation format. Claude stream-json
    uses complete assistant/user messages; partial stream_event deltas are
    deliberately ignored, so the same call cannot count twice.
    """
    fmt, events, continued = trajectory_events(text)
    calls, returned = [], set()
    turns = [
        e
        for e in events
        if isinstance(e, dict) and e.get("type") in {"assistant", "user", "result"}
    ]
    broken = continued or (
        fmt == "claude"
        and not (
            turns
            and turns[-1].get("type") == "result"
            and any(e.get("type") == "assistant" for e in events)
        )
    )
    if fmt == "atif":
        require(
            any(isinstance(e, dict) and e.get("source") == "agent" for e in events),
            "trajectory contains no recorded agent step",
        )
    for event in events:
        require(isinstance(event, dict), "invalid ATIF step")
        if fmt == "atif":
            for call in (
                (event.get("tool_calls") or [])
                if event.get("source") == "agent"
                else []
            ):
                require(isinstance(call, dict), "invalid ATIF tool call")
                calls.append(
                    {
                        "id": call.get("tool_call_id"),
                        "name": call.get("function_name"),
                        "arguments": call.get("arguments") or {},
                    }
                )
            observation = event.get("observation") or {}
            require(isinstance(observation, dict), "invalid ATIF observation")
            for result in observation.get("results") or []:
                require(isinstance(result, dict), "invalid ATIF observation result")
                extra = result.get("extra") or {}
                failed = result.get("is_error") or (
                    isinstance(extra, dict) and extra.get("is_error")
                )
                if failed:
                    broken = True
                if result.get("source_call_id") and not failed:
                    returned.add(result["source_call_id"])
        else:
            if event.get("type") == "result" and event.get("is_error"):
                broken = True
            message = event.get("message") or {}
            require(isinstance(message, dict), "invalid Claude message")
            content = message.get("content") or []
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if event.get("type") == "assistant" and block.get("type") == "tool_use":
                    calls.append(
                        {
                            "id": block.get("id"),
                            "name": block.get("name"),
                            "arguments": block.get("input") or {},
                        }
                    )
                if event.get("type") == "user" and block.get("type") == "tool_result":
                    if block.get("is_error"):
                        broken = True
                    elif block.get("tool_use_id"):
                        returned.add(block["tool_use_id"])
    require(
        all(
            nonempty(c["id"])
            and nonempty(c["name"])
            and isinstance(c["arguments"], dict)
            for c in calls
        ),
        "tool call needs id, name and structured arguments",
    )
    call_ids = {c["id"] for c in calls}
    require(
        len(call_ids) == len(calls),
        "duplicate tool call id makes the evidence ambiguous",
    )
    broken = broken or not call_ids.issubset(returned)
    return calls, returned, broken


def selected(calls, expected):
    skill = expected["skill"]
    for call in calls:
        args = call["arguments"]
        if call["name"].lower() in {"skill", "invokeskill"}:
            value = args.get("skill") or args.get("name") or args.get("command")
            if isinstance(value, str) and value.strip().lstrip("/") == skill:
                return True
        # Read-based hosts must name the exact installed path in the contract.
        if (
            call["name"] == "Read"
            and expected.get("skill_path")
            and args.get("file_path") == expected["skill_path"]
        ):
            return True
    return False


def evaluate(record, root):
    require(
        isinstance(record, dict)
        and type(record.get("schema_version")) is int
        and record["schema_version"] == 1,
        "schema_version must be 1",
    )
    require(
        record.get("evaluation") in {"selection", "task"},
        "evaluation must be selection or task",
    )
    for field in ("run_id", "case_id"):
        require(nonempty(record.get(field)), f"{field} is required")
    require(
        record.get("arm") in {"before", "after", "without"}, "unknown comparison arm"
    )
    require(
        record.get("split") in {"training", "validation", "holdout"},
        "unknown dataset split",
    )
    require(
        record.get("status") in {"completed", "error", "timeout", "blocked"},
        "unknown run status",
    )
    provenance = record.get("provenance")
    require(isinstance(provenance, dict), "provenance is required")
    for field in PROVENANCE:
        require(nonempty(provenance.get(field)), f"provenance.{field} is required")
    expected = record.get("expected")
    require(
        isinstance(expected, dict) and nonempty(expected.get("skill")),
        "expected.skill is required",
    )
    require(
        type(expected.get("should_trigger")) is bool, "should_trigger must be boolean"
    )
    require(
        "skill_path" not in expected or nonempty(expected["skill_path"]),
        "skill_path must be a path string",
    )
    requirements = expected.get("tool_calls", [])
    require(isinstance(requirements, list), "expected.tool_calls must be a list")
    for item in requirements:
        require(
            isinstance(item, dict) and nonempty(item.get("name")),
            "required tool needs a name",
        )
        require(
            "arguments_contains" not in item or nonempty(item["arguments_contains"]),
            "arguments_contains must be a nonempty literal",
        )
    result = {
        "schema_version": 1,
        "run_id": record["run_id"],
        "case_id": record["case_id"],
        "evaluation": record["evaluation"],
        "arm": record["arm"],
        "split": record["split"],
        "provenance": provenance,
        "run_status": record["status"],
        "verdict": "incomplete",
        "routing_pass": None,
        "tools_pass": None,
        "outcome_pass": None,
    }
    if record["status"] != "completed":
        return result
    calls, returned, broken = recorded_calls(artifact(record.get("trajectory"), root))
    if broken:
        result["run_status"] = "error"
        return result
    triggered = selected(calls, expected)
    result["triggered"] = triggered
    result["routing_pass"] = triggered == expected["should_trigger"]
    if requirements:
        result["tools_pass"] = all(
            any(
                c["name"] == req["name"]
                and c["id"] in returned
                and req.get("arguments_contains", "")
                in json.dumps(c["arguments"], sort_keys=True)
                for c in calls
            )
            for req in requirements
        )
    if record["evaluation"] == "task":
        outcome = json.loads(artifact(record.get("outcome"), root))
        require(
            isinstance(outcome, dict) and type(outcome.get("passed")) is bool,
            "outcome must contain boolean passed",
        )
        require(
            nonempty(outcome.get("verifier")),
            "outcome must identify the independent verifier",
        )
        require(
            outcome.get("target_revision") == provenance["target_revision"],
            "outcome target revision does not match the recorded target",
        )
        result["outcome_pass"] = outcome["passed"]
    checks = [
        result[k]
        for k in ("routing_pass", "tools_pass", "outcome_pass")
        if result[k] is not None
    ]
    result["verdict"] = "pass" if all(checks) else "fail"
    return result


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "record", type=Path, help="run record; artifact paths resolve beside this file"
    )
    args = parser.parse_args()
    try:
        result = evaluate(
            json.loads(args.record.read_text()), args.record.resolve().parent
        )
    except (ValueError, OSError, TypeError, KeyError) as exc:
        print(
            json.dumps({"schema_version": 1, "verdict": "invalid", "error": str(exc)})
        )
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return {"pass": 0, "fail": 1, "incomplete": 2}[result["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
