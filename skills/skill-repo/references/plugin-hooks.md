# Plugin Hooks

A skill repository can ship Claude Code hooks in `hooks/hooks.json`. A hook
that registers, runs and exits 0 can still do nothing: `cli-tools-skill`
shipped one for months that could never have fired, and no check noticed.
Measured against the [hooks reference](https://code.claude.com/docs/en/hooks)
and a live session (2026-09).

## Contents

- Pick the event that fires
- Read the input the event actually carries
- Output only reaches the model through additionalContext
- Verify live, not only in unit tests

## Pick the event that fires

`PostToolUse` fires only after a tool call **succeeds**. A Bash command that
exits non-zero — `command not found` is exit 127 — fires
**`PostToolUseFailure`** instead. A hook meant to react to failures must
register for `PostToolUseFailure`; add `PostToolUse` only for the case where a
failing command sits inside a pipeline or list whose overall status is 0.

## Read the input the event actually carries

| Event | Where the text is |
|---|---|
| `PostToolUseFailure` | top-level `error`: first line `Exit code N`, then stdout and stderr interleaved |
| `PostToolUse` (Bash) | `tool_response.stdout` / `tool_response.stderr` |

There is no top-level `output` or `stdout`. Match only the lines the failing
program prints (e.g. `bash: line 1: rg: command not found`), not a phrase
anywhere in the text, or ordinary output that quotes it triggers the hook.

## Output only reaches the model through additionalContext

Plain stdout from these events goes nowhere the model sees. Emit JSON:

```json
{"hookSpecificOutput": {"hookEventName": "PostToolUseFailure", "additionalContext": "…"}}
```

Keep the text to what the hook knows: a shell's `command not found` means the
name did not resolve on PATH, not that the tool is absent. Fail open — any
exception exits 0 with no output — so a hook can never break the call it
observes.

## Verify live, not only in unit tests

Unit tests prove the script; they cannot prove Claude Code calls it, with
this input, and shows the result. Load the checkout as a plugin and make the
model trigger the hook:

```bash
claude -p --plugin-dir <checkout> --allowedTools Bash \
  "Run: bash -c 'PATH=/nonexistent; rg --version'. Quote verbatim any hook context you received, or say NONE."
```

`NONE` means the hook is dead, whatever its tests say. Repeat once after
installing from the marketplace, since `${CLAUDE_PLUGIN_ROOT}` then points
into the plugin cache.
