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
import os
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
    """Exercise recorded evidence against positive and adversarial fixtures."""

    def setUp(self):
        """Create isolated, valid ATIF task evidence for each contract test."""
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
        """Serialize and hash a fixture as a collector artifact."""
        p = self.root / name
        p.write_text(json.dumps(value))
        return {"path": name, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}

    def evaluate(self):
        """Evaluate the current fixture through the public validation API."""
        return MODULE.evaluate(self.record, self.root)

    def test_completed_task_uses_trace_and_outcome(self):
        """Completed task uses trace and outcome."""
        self.assertEqual(self.evaluate()["verdict"], "pass")

    def test_non_ascii_argument_literal_matches_the_recorded_call(self):
        """Non ascii argument literal matches the recorded call."""
        self.trace["steps"][0]["tool_calls"][1]["arguments"]["command"] = "Prüfung"
        self.record["expected"]["tool_calls"][0]["arguments_contains"] = "Prüfung"
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.assertEqual(self.evaluate()["verdict"], "pass")

    def test_cli_reads_utf8_records_under_an_ascii_locale(self):
        """Cli reads utf8 records under an ascii locale."""
        self.record["case_id"] = "Prüfung"
        run = self.root / "run.json"
        run.write_text(json.dumps(self.record, ensure_ascii=False), encoding="utf-8")
        env = dict(os.environ, LC_ALL="C", PYTHONUTF8="0", PYTHONCOERCECLOCALE="0")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(run)],
            cwd=self.root,
            env=env,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout.decode("ascii"))
        self.assertEqual(json.loads(result.stdout)["case_id"], "Prüfung")

    def test_cli_refuses_record_paths_outside_the_working_directory(self):
        """Cli refuses record paths outside the working directory."""
        run = self.root / "run.json"
        run.write_text(json.dumps(self.record), encoding="utf-8")
        nested = self.root / "nested"
        nested.mkdir()
        for supplied in (str(run), "../run.json"):
            result = subprocess.run(
                [sys.executable, str(SCRIPT), supplied],
                cwd=nested,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("working directory", json.loads(result.stdout)["error"])

    def test_cli_refuses_a_record_symlink_outside_the_working_directory(self):
        """Cli refuses a record symlink outside the working directory."""
        run = self.root / "run.json"
        run.write_text(json.dumps(self.record), encoding="utf-8")
        nested = self.root / "nested"
        nested.mkdir()
        link = nested / "linked.json"
        link.symlink_to(run)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(link)],
            cwd=nested,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("working directory", json.loads(result.stdout)["error"])

    def test_claude_selection_requires_explicit_successful_terminal_fields(self):
        """Claude selection requires explicit successful terminal fields."""
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        for terminal in (
            {"type": "result"},
            {"type": "result", "is_error": False},
            {"type": "result", "subtype": "success"},
            {"type": "result", "subtype": "error_max_turns", "is_error": False},
        ):
            with self.subTest(terminal=terminal):
                self.record["trajectory"] = self.artifact(
                    "trajectory.json",
                    [
                        {"type": "assistant", "message": {"content": []}},
                        terminal,
                    ],
                )
                self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_nonstructured_tool_arguments_are_not_normalized_to_empty_objects(self):
        """Nonstructured tool arguments are not normalized to empty objects."""
        for arguments in (False, None, "", []):
            with self.subTest(arguments=arguments):
                self.trace["steps"][0]["tool_calls"][1]["arguments"] = arguments
                self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
                with self.assertRaisesRegex(ValueError, "structured arguments"):
                    self.evaluate()
        for arguments in (False, None, "", []):
            with self.subTest(claude_arguments=arguments):
                self.record["trajectory"] = self.artifact(
                    "trajectory.json",
                    [
                        {
                            "type": "assistant",
                            "message": {
                                "content": [
                                    {
                                        "type": "tool_use",
                                        "id": "t",
                                        "name": "Bash",
                                        "input": arguments,
                                    }
                                ]
                            },
                        },
                        {
                            "type": "user",
                            "message": {
                                "content": [
                                    {
                                        "type": "tool_result",
                                        "tool_use_id": "t",
                                        "content": "ok",
                                    }
                                ]
                            },
                        },
                        {"type": "result", "subtype": "success", "is_error": False},
                    ],
                )
                with self.assertRaisesRegex(ValueError, "structured arguments"):
                    self.evaluate()

    def test_task_recovers_from_a_failed_tool_after_a_successful_retry(self):
        """Task recovers from a failed tool after a successful retry."""
        step = self.trace["steps"][0]
        step["observation"]["results"][1]["is_error"] = True
        step["tool_calls"].append(
            {
                "tool_call_id": "green",
                "function_name": "Bash",
                "arguments": {"command": "run-tests"},
            }
        )
        step["observation"]["results"].append(
            {"source_call_id": "green", "content": "ok"}
        )
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(result["failed_tool_calls"], ["t"])
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "absent-skill", "should_trigger": False}
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_task_does_not_count_a_failed_required_tool_as_success(self):
        """Task does not count a failed required tool as success."""
        self.trace["steps"][0]["observation"]["results"][1]["is_error"] = True
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertFalse(result["tools_pass"])
        self.assertTrue(result["outcome_pass"])
        self.assertEqual(result["verdict"], "fail")

    def test_task_does_not_count_failed_skill_loading_as_routing(self):
        """Task does not count failed skill loading as routing."""
        self.trace["steps"][0]["observation"]["results"][0]["is_error"] = True
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertFalse(result["routing_pass"])
        self.assertEqual(result["verdict"], "fail")

    def test_claude_task_can_recover_but_selection_cannot_certify_failed_calls(self):
        """Claude task can recover but selection cannot certify failed calls."""
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
                            "id": "red",
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
                        {"type": "tool_result", "tool_use_id": "red", "is_error": True},
                    ]
                },
            },
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "green",
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
                            "tool_use_id": "green",
                            "content": "ok",
                        },
                    ]
                },
            },
            {"type": "result", "subtype": "success", "is_error": False},
        ]
        self.record["trajectory"] = self.artifact("trajectory.json", events)
        result = self.evaluate()
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(result["failed_tool_calls"], ["red"])
        self.record["outcome"] = self.artifact(
            "outcome.json",
            {
                "passed": False,
                "verifier": "independent-verifier@revision",
                "target_revision": "result-hash",
            },
        )
        self.assertEqual(self.evaluate()["verdict"], "fail")
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "absent-skill", "should_trigger": False}
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_atif_optional_null_containers_preserve_completed_runs(self):
        """Accept the optional null containers emitted by ATIF serializers."""
        self.trace["steps"][0]["observation"]["results"][0]["extra"] = None
        self.trace["steps"].extend(
            [
                {
                    "source": "agent",
                    "message": "All done.",
                    "tool_calls": None,
                    "observation": None,
                },
                {"source": "agent", "observation": {"results": None}},
            ]
        )
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.assertEqual(self.evaluate()["verdict"], "pass")

    def test_atif_wrong_nonnull_container_types_are_invalid(self):
        """Reject malformed containers while permitting omitted optional data."""
        for field, value in (("tool_calls", {}), ("observation", [])):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.trace)
                bad["steps"][0][field] = value
                self.record["trajectory"] = self.artifact("trajectory.json", bad)
                with self.assertRaises(ValueError):
                    self.evaluate()
        for field, value in (("results", {}), ("extra", [])):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.trace)
                observation = bad["steps"][0]["observation"]
                target = (
                    observation if field == "results" else observation["results"][0]
                )
                target[field] = value
                self.record["trajectory"] = self.artifact("trajectory.json", bad)
                with self.assertRaises(ValueError):
                    self.evaluate()

    def test_terminal_permission_denials_cannot_certify_negative_selection(self):
        """Retain native terminal permission denials even without tool messages."""
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        self.record["trajectory"] = self.artifact(
            "trajectory.json",
            [
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "Cannot load."}]},
                },
                {
                    "type": "result",
                    "subtype": "success",
                    "is_error": False,
                    "permission_denials": [
                        {
                            "tool_name": "Skill",
                            "tool_use_id": "denied",
                            "tool_input": {"skill": "review"},
                        }
                    ],
                },
            ],
        )
        result = self.evaluate()
        self.assertEqual(result["verdict"], "incomplete")
        self.assertIsNone(result["routing_pass"])
        self.assertEqual(result["permission_denials"][0]["tool_use_id"], "denied")

    def test_terminal_denials_do_not_erase_independently_verified_task_recovery(self):
        """A terminal denial log alone does not invalidate successful task recovery."""
        self.record["trajectory"] = self.artifact(
            "trajectory.json",
            [
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
                            {
                                "type": "tool_result",
                                "tool_use_id": "t",
                                "content": "ok",
                            },
                        ]
                    },
                },
                {
                    "type": "result",
                    "subtype": "success",
                    "is_error": False,
                    "permission_denials": [
                        {
                            "tool_name": "Bash",
                            "tool_use_id": "denied",
                            "tool_input": {"command": "unneeded-command"},
                        }
                    ],
                },
            ],
        )
        self.assertEqual(self.evaluate()["verdict"], "pass")

    def test_tool_returns_without_matching_calls_are_invalid(self):
        """Reject orphan results that could be spliced in from another run."""
        self.trace["steps"][0]["observation"]["results"].append(
            {"source_call_id": "foreign-call", "content": "ok"}
        )
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        with self.assertRaisesRegex(ValueError, "matching recorded call"):
            self.evaluate()
        self.record["trajectory"] = self.artifact(
            "trajectory.json",
            [
                {"type": "assistant", "message": {"content": []}},
                {
                    "type": "user",
                    "message": {
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "foreign-call",
                                "content": "ok",
                            },
                        ]
                    },
                },
                {"type": "result", "subtype": "success", "is_error": False},
            ],
        )
        with self.assertRaisesRegex(ValueError, "matching recorded call"):
            self.evaluate()

    def test_answer_claim_is_not_a_tool_call(self):
        """Answer claim is not a tool call."""
        self.trace["steps"][0]["tool_calls"] = []
        self.trace["steps"][0]["observation"]["results"] = []
        self.trace["steps"][0]["message"] = (
            "Skill review invoked. Bash run-tests succeeded."
        )
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertFalse(result["routing_pass"])
        self.assertFalse(result["tools_pass"])
        self.assertEqual(result["verdict"], "fail")

    def test_called_tool_without_result_is_not_completed_execution(self):
        """Called tool without result is not completed execution."""
        self.trace["steps"][0]["observation"]["results"] = []
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        result = self.evaluate()
        self.assertEqual(result["verdict"], "incomplete")
        self.assertIsNone(result["tools_pass"])

    def test_negative_selection_cannot_pass_with_an_open_unrelated_call(self):
        """Negative selection cannot pass with an open unrelated call."""
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
        """Negative selection cannot pass with failed atif tool return."""
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "absent-skill", "should_trigger": False}
        self.trace["steps"][0]["observation"]["results"][0]["is_error"] = True
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_unloaded_atif_continuation_cannot_prove_negative_selection(self):
        """Unloaded atif continuation cannot prove negative selection."""
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
        """Claude selection needs nonerror returns even with successful terminal result."""
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
            {"type": "result", "subtype": "success", "is_error": False},
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
        """Claude earlier result does not complete a later unfinished turn."""
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        events = [
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "Earlier result."}]},
            },
            {"type": "result", "subtype": "success", "is_error": False},
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "Still working."}]},
            },
        ]
        self.record["trajectory"] = self.artifact("trajectory.json", events)
        self.assertEqual(self.evaluate()["verdict"], "incomplete")

    def test_read_based_selection_requires_the_exact_installed_skill_path(self):
        """Read based selection requires the exact installed skill path."""
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
        """Semantic failure is not overruled by routing."""
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
        """Clean negative selection needs completed run."""
        self.record["evaluation"] = "selection"
        self.record["expected"] = {"skill": "review", "should_trigger": False}
        self.trace["steps"][0]["tool_calls"] = []
        self.trace["steps"][0]["observation"]["results"] = []
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        self.record.pop("outcome")
        self.assertEqual(self.evaluate()["verdict"], "pass")
        self.assertIsNone(self.evaluate()["outcome_pass"])
        for status in ["error", "timeout", "blocked"]:
            self.record["status"] = status
            self.assertEqual(self.evaluate()["verdict"], "incomplete")
            self.assertIsNone(self.evaluate()["routing_pass"])

    def test_missing_provenance_and_artifacts_are_invalid(self):
        """Missing provenance and artifacts are invalid."""
        for field in self.record["provenance"]:
            bad = copy.deepcopy(self.record)
            bad["provenance"].pop(field)
            with self.assertRaises(ValueError):
                MODULE.evaluate(bad, self.root)
        (self.root / "trajectory.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "hash"):
            self.evaluate()

    def test_stale_outcome_is_invalid(self):
        """Stale outcome is invalid."""
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
        """Text only ab is not agent evidence."""
        with self.assertRaises(ValueError):
            MODULE.evaluate(
                {"with": "I ran tests", "without": "I ran tests"}, self.root
            )

    def test_empty_trajectory_and_user_quoted_calls_do_not_prove_routing(self):
        """Empty trajectory and user quoted calls do not prove routing."""
        self.record["trajectory"] = self.artifact("trajectory.json", {"steps": []})
        with self.assertRaisesRegex(ValueError, "agent step"):
            self.evaluate()
        quoted = copy.deepcopy(self.trace["steps"][0])
        quoted["source"] = "user"
        quoted.pop("observation")
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
        """Missing artifact and malformed observation are invalid."""
        (self.root / "trajectory.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing artifact"):
            self.evaluate()
        self.trace["steps"][0]["observation"]["results"] = [None]
        self.record["trajectory"] = self.artifact("trajectory.json", self.trace)
        with self.assertRaisesRegex(ValueError, "observation result"):
            self.evaluate()

    def test_claude_stream_json_records_calls_not_printed_text(self):
        """Claude stream json records calls not printed text."""
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
            {"type": "result", "subtype": "success", "is_error": False},
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
        """Cli preserves pass fail incomplete and invalid exit codes."""
        p = self.root / "run.json"
        for status, expected in [("completed", 0), ("timeout", 2)]:
            self.record["status"] = status
            p.write_text(json.dumps(self.record))
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(p)],
                cwd=self.root,
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
                [sys.executable, str(SCRIPT), str(p)],
                cwd=self.root,
                check=False,
                capture_output=True,
            ).returncode,
            1,
        )
        p.write_text("{}")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(p)],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["verdict"], "invalid")


if __name__ == "__main__":
    unittest.main()
