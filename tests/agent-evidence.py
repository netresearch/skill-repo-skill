#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for captured agent evidence, never model-quality claims."""

import copy
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "skills/skill-repo/scripts/validate-agent-evidence.py"
)
SPEC = importlib.util.spec_from_file_location("agent_evidence", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.trace = {
            "steps": [
                {
                    "source": "agent",
                    "message": "Checked the project.",
                    "tool_calls": [
                        {
                            "tool_call_id": "s",
                            "function_name": "Skill",
                            "arguments": {"skill": "review"},
                        },
                        {
                            "tool_call_id": "t",
                            "function_name": "Bash",
                            "arguments": {"command": "run-tests"},
                        },
                    ],
                    "observation": {
                        "results": [
                            {"source_call_id": "s", "content": "loaded"},
                            {"source_call_id": "t", "content": "ok"},
                        ]
                    },
                }
            ]
        }
        self.record = {
            "schema_version": 1,
            "evaluation": "task",
            "run_id": "r1",
            "case_id": "own-case",
            "arm": "after",
            "split": "validation",
            "status": "completed",
            "provenance": {
                "model": "model-revision",
                "harness": "harness-revision",
                "tool_environment": "image-digest",
                "skill_revision": "skill-hash",
                "task_revision": "task-hash",
                "target_revision": "result-hash",
                "effort": "high",
            },
            "expected": {
                "skill": "review",
                "should_trigger": True,
                "tool_calls": [{"name": "Bash", "arguments_contains": "run-tests"}],
            },
        }
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.record["outcome"] = self.artifact(
            "outcome.json",
            {
                "passed": True,
                "verifier": "independent-verifier@revision",
                "target_revision": "result-hash",
            },
        )

    def artifact(self, name, value):
        p = self.root / name
        p.write_text(json.dumps(value))
        return {"path": name, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}

    def evaluate(self):
        return MODULE.evaluate(self.record, self.root)

    def test_completed_task_uses_trace_and_outcome(self):
        self.assertEqual(self.evaluate()["verdict"], "pass")

    def test_answer_claim_is_not_a_tool_call(self):
        self.trace["steps"][0]["tool_calls"] = []
        self.trace["steps"][0]["message"] = (
            "Skill review invoked. Bash run-tests succeeded."
        )
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertFalse(result["routing_pass"])
        self.assertFalse(result["tools_pass"])
        self.assertEqual(result["verdict"], "fail")

    def test_called_tool_without_result_is_not_completed_execution(self):
        self.trace["steps"][0]["observation"]["results"] = []
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertEqual(result["verdict"], "incomplete")
        self.assertIsNone(result["tools_pass"])

    def test_negative_selection_cannot_pass_with_an_open_unrelated_call(self):
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        self.trace["steps"][0]["tool_calls"] = [
            {
                "tool_call_id": "x",
                "function_name": "Read",
                "arguments": {"file_path": "/instructions/AGENTS.md"},
            }
        ]
        self.trace["steps"][0].pop("observation")
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertEqual(result["verdict"], "incomplete")
        self.assertIsNone(result["routing_pass"])

    def test_negative_selection_cannot_pass_with_failed_atif_tool_return(self):
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "absent-skill", "should_trigger": False}
        self.trace["steps"][0]["observation"]["results"][0]["is_error"] = True
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_unloaded_atif_continuation_cannot_prove_negative_selection(self):
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        self.record["trajectory"] = self.artifact(
            "trajectory.json",
            {
                "steps": [
                    {"source": "agent", "message": "Continuing the investigation."}
                ],
                "continued_trajectory_ref": "next.json",
            },
        )
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_claude_selection_needs_nonerror_returns_even_with_successful_terminal_result(
        self,
    ):
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        events = [
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "x",
                            "name": "Read",
                            "input": {"file_path": "/instructions/AGENTS.md"},
                        },
                    ]
                },
            },
            {
                "type": "user",
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "x",
                            "content": "Permission denied",
                            "is_error": True,
                        },
                    ]
                },
            },
            {"type": "result", "is_error": False},
        ]
        self.record["trajectory"] = self.artifact("trajectory.json", events)
        self.assertEqual(self.evaluate()["verdict"], "incomplete")
        self.record["expected"]["should_trigger"] = True
        events[0]["message"]["content"][0].update(
            {"name": "Skill", "input": {"skill": "review"}}
        )
        events.pop(1)
        self.record["trajectory"] = self.artifact("trajectory.json", events)
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_claude_earlier_result_does_not_complete_a_later_unfinished_turn(self):
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        events = [
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "Earlier result."}]},
            },
            {"type": "result", "is_error": False},
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "Still working."}]},
            },
        ]
        self.record["trajectory"] = self.artifact("trajectory.json", events)
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_read_based_selection_requires_the_exact_installed_skill_path(self):
        self.record["expected"]["skill_path"] = "/app/.claude/skills/review/SKILL.md"
        self.trace["steps"][0]["tool_calls"][0].update(
            {
                "function_name": "Read",
                "arguments": {"file_path": "/app/.claude/skills/review/SKILL.md"},
            }
        )
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.assertTrue(self.evaluate()["routing_pass"])
        self.record["expected"]["skill_path"] = "/other/.claude/skills/review/SKILL.md"
        self.assertFalse(self.evaluate()["routing_pass"])

    def test_semantic_failure_is_not_overruled_by_routing(self):
        self.record["outcome"] = self.artifact(
            "outcome.json",
            {
                "passed": False,
                "verifier": "independent-verifier@revision",
                "target_revision": "result-hash",
            },
        )
        result = self.evaluate()
        self.assertTrue(result["routing_pass"])
        self.assertFalse(result["outcome_pass"])
        self.assertEqual(result["verdict"], "fail")

    def test_clean_negative_selection_needs_completed_run(self):
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        self.trace["steps"][0]["tool_calls"] = []
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.record.pop("outcome")
        self.assertEqual(self.evaluate()["verdict"], "pass")
        self.assertIsNone(self.evaluate()["outcome_pass"])
        for status in ["error", "timeout", "blocked"]:
            self.record["status"] = status
            self.assertEqual(self.evaluate()["verdict"], "incomplete")
            self.assertIsNone(self.evaluate()["routing_pass"])

    def test_missing_provenance_and_artifacts_are_invalid(self):
        for field in self.record["provenance"]:
            bad = copy.deepcopy(self.record)
            bad["provenance"].pop(field)
            with self.assertRaises(ValueError):
                MODULE.evaluate(bad, self.root)
        (self.root / "trajectory.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "hash"):
            self.evaluate()

    def test_stale_outcome_is_invalid(self):
        self.record["outcome"] = self.artifact(
            "outcome.json",
            {
                "passed": True,
                "verifier": "independent-verifier@revision",
                "target_revision": "old-hash",
            },
        )
        with self.assertRaisesRegex(ValueError, "revision"):
            self.evaluate()

    def test_text_only_ab_is_not_agent_evidence(self):
        with self.assertRaises(ValueError):
            MODULE.evaluate(
                {"with": "I ran tests", "without": "I ran tests"}, self.root
            )

    def test_empty_trajectory_and_user_quoted_calls_do_not_prove_routing(self):
        self.record["trajectory"] = self.artifact("trajectory.json", {"steps": []})
        with self.assertRaisesRegex(ValueError, "agent step"):
            self.evaluate()
        quoted = copy.deepcopy(self.trace["steps"][0])
        quoted["source"] = "user"
        self.record["trajectory"] = self.artifact(
            "trajectory.json",
            {
                "steps": [
                    quoted,
                    {"source": "agent", "message": "No tools needed."},
                ]
            },
        )
        self.assertFalse(self.evaluate()["routing_pass"])

    def test_missing_artifact_and_malformed_observation_are_invalid(self):
        (self.root / "trajectory.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing artifact"):
            self.evaluate()
        self.trace["steps"][0]["observation"]["results"] = [None]
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        with self.assertRaisesRegex(ValueError, "observation result"):
            self.evaluate()

    def test_claude_stream_json_records_calls_not_printed_text(self):
        events = [
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "s",
                            "name": "Skill",
                            "input": {"skill": "review"},
                        },
                        {
                            "type": "tool_use",
                            "id": "t",
                            "name": "Bash",
                            "input": {"command": "run-tests"},
                        },
                    ]
                },
            },
            {
                "type": "user",
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "s",
                            "content": "loaded",
                        },
                        {"type": "tool_result", "tool_use_id": "t", "content": "ok"},
                    ]
                },
            },
            {"type": "result", "is_error": False},
        ]
        p = self.root / "trace.jsonl"
        p.write_text("\n".join(json.dumps(e) for e in events))
        self.record["trajectory"] = {
            "path": p.name,
            "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
        }
        self.assertEqual(self.evaluate()["verdict"], "pass")
        events[-1]["is_error"] = True
        p.write_text("\n".join(json.dumps(e) for e in events))
        self.record["trajectory"]["sha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_cli_preserves_pass_fail_incomplete_and_invalid_exit_codes(self):
        p = self.root / "run.json"
        for status, expected in [("completed", 0), ("timeout", 2)]:
            self.record["status"] = status
            p.write_text(json.dumps(self.record))
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(p)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, expected)
            self.assertIn("verdict", json.loads(result.stdout))
        self.record["status"] = "completed"
        self.record["expected"]["skill"] = "different-skill"
        p.write_text(json.dumps(self.record))
        self.assertEqual(
            subprocess.run(
                [sys.executable, str(SCRIPT), str(p)], check=False, capture_output=True
            ).returncode,
            1,
        )
        p.write_text("{}")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(p)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["verdict"], "invalid")


if __name__ == "__main__":
    unittest.main()
