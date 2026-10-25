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
    """Reject evidence that violates a contract prerequisite."""
    if not condition:
        raise ValueError(message)


def nonempty(value):
    """Accept only nonblank string identifiers and provenance."""
    return isinstance(value, str) and bool(value.strip())


def artifact(spec, root):
    """Read a UTF-8 artifact after confining its path and checking its hash."""
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
    """Identify supported ATIF JSON or complete Claude JSON/JSONL events."""
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


def optional_container(value, kind, label):
    """Normalize optional null containers while rejecting other wrong types."""
    if value is None:
        return kind()
    require(isinstance(value, kind), f"invalid {label}")
    return value


def atif_calls(event):
    """Extract invocations only from ATIF agent steps."""
    if event.get("source") != "agent":
        return []
    calls = []
    raw = optional_container(event.get("tool_calls"), list, "ATIF tool calls")
    for call in raw:
        require(isinstance(call, dict), "invalid ATIF tool call")
        calls.append(
            {
                "id": call.get("tool_call_id"),
                "name": call.get("function_name"),
                "arguments": call.get("arguments", {}),
            }
        )
    return calls


def atif_results(event):
    """Collect ATIF returned and failed call IDs separately."""
    observation = optional_container(event.get("observation"), dict, "ATIF observation")
    results = optional_container(observation.get("results"), list, "ATIF results")
    returned, failed = set(), set()
    for result in results:
        require(isinstance(result, dict), "invalid ATIF observation result")
        extra = optional_container(result.get("extra"), dict, "ATIF result extra")
        call_id = result.get("source_call_id")
        if call_id:
            returned.add(call_id)
            if result.get("is_error") or extra.get("is_error"):
                failed.add(call_id)
    return returned, failed, False, []


def claude_blocks(event):
    """Read full Claude message blocks; ignore partial stream deltas."""
    message = event.get("message", {})
    require(isinstance(message, dict), "invalid Claude message")
    content = message.get("content", [])
    return (
        [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
    )


def claude_calls(event):
    """Extract invocations only from complete Claude assistant messages."""
    if event.get("type") != "assistant":
        return []
    return [
        {"id": b.get("id"), "name": b.get("name"), "arguments": b.get("input", {})}
        for b in claude_blocks(event)
        if b.get("type") == "tool_use"
    ]


def claude_results(event):
    """Keep returned IDs, tool failures, and terminal run errors distinct."""
    returned, failed = set(), set()
    if event.get("type") == "result":
        denials = optional_container(
            event.get("permission_denials"), list, "Claude permission denials"
        )
        return returned, failed, bool(event.get("is_error")), denials
    if event.get("type") != "user":
        return returned, failed, False, []
    for block in claude_blocks(event):
        if block.get("type") != "tool_result":
            continue
        call_id = block.get("tool_use_id")
        if call_id:
            returned.add(call_id)
            if block.get("is_error"):
                failed.add(call_id)
    return returned, failed, False, []


def claude_completed(events):
    """Require an explicit successful terminal result after an assistant turn."""
    turns = [e for e in events if e.get("type") in {"assistant", "user", "result"}]
    if not turns or not any(e.get("type") == "assistant" for e in turns):
        return False
    final = turns[-1]
    return (
        final.get("type") == "result"
        and final.get("subtype") == "success"
        and final.get("is_error") is False
    )


def recorded_calls(text):
    """Read calls, successful returns, completeness, failures, and permission denials.

    ATIF is Harbor's steps/tool_calls/observation format. Claude stream-json
    uses complete assistant/user messages, so partial deltas cannot count twice.
    """
    fmt, events, continued = trajectory_events(text)
    require(all(isinstance(e, dict) for e in events), "invalid trajectory event")
    calls, returned, failed, denials = [], set(), set(), []
    broken = continued
    if fmt == "atif":
        require(
            any(e.get("source") == "agent" for e in events),
            "trajectory contains no recorded agent step",
        )
        extract_calls, extract_results = atif_calls, atif_results
    else:
        broken = not claude_completed(events)
        extract_calls, extract_results = claude_calls, claude_results
    for event in events:
        calls.extend(extract_calls(event))
        event_returns, event_failures, event_error, event_denials = extract_results(
            event
        )
        returned.update(event_returns)
        failed.update(event_failures)
        denials.extend(event_denials)
        broken = broken or event_error
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
    require(returned.issubset(call_ids), "tool result has no matching recorded call")
    broken = broken or not call_ids.issubset(returned)
    return calls, returned - failed, broken, failed, denials


def selected(calls, expected):
    """Match an actual skill invocation or an exact installed skill read."""
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


def measured_verdict(result):
    """Combine only the measured boolean checks into a pass or fail verdict."""
    checks = []
    for key in ("routing_pass", "tools_pass", "outcome_pass"):
        if result[key] is not None:
            checks.append(result[key])
    return "pass" if all(checks) else "fail"


def validate_record(record):
    """Validate the collector's run contract before reading trajectory artifacts."""
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
    return provenance, expected, requirements


def evaluate(record, root):
    """Measure routing, tool execution, and independent task outcomes separately."""
    provenance, expected, requirements = validate_record(record)
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
    calls, returned, broken, failed, denials = recorded_calls(
        artifact(record.get("trajectory"), root)
    )
    result["failed_tool_calls"] = sorted(failed)
    result["permission_denials"] = denials
    if broken or (record["evaluation"] == "selection" and (failed or denials)):
        result["run_status"] = "error"
        return result
    triggered = selected([c for c in calls if c["id"] in returned], expected)
    result["triggered"] = triggered
    result["routing_pass"] = triggered == expected["should_trigger"]
    if requirements:
        result["tools_pass"] = all(
            any(
                c["name"] == req["name"]
                and c["id"] in returned
                and req.get("arguments_contains", "")
                in json.dumps(c["arguments"], sort_keys=True, ensure_ascii=False)
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
    result["verdict"] = measured_verdict(result)
    return result


def main():
    """Validate a run record confined to the current working directory."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "record", type=Path, help="run record within cwd; artifacts resolve beside it"
    )
    args = parser.parse_args()
    try:
        root = Path.cwd().resolve()
        record_path = (root / args.record).resolve()
        if not record_path.is_relative_to(root):
            raise ValueError("record must remain inside the working directory")
        result = evaluate(
            json.loads(record_path.read_text(encoding="utf-8")), record_path.parent
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
