<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Plugin Hooks

A skill repository can ship Claude Code hooks in `hooks/hooks.json`. A hook
that registers, runs and exits 0 can still do nothing: `cli-tools-skill`
shipped one for months that could never have fired, and no check noticed.
Measured against the [hooks reference](https://code.claude.com/docs/en/hooks)
and a live session (2026-09).

## Contents

- Pick the event that fires
- Read the input the event actually carries
- Plain stdout does not reach the model
- Start the hook script
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

## Plain stdout does not reach the model

Plain stdout from these events goes nowhere the model sees. To add context
without signalling an error, emit JSON:

```json
{"hookSpecificOutput": {"hookEventName": "PostToolUseFailure", "additionalContext": "…"}}
```

The other path is exit status 2: its stderr is shown to Claude as feedback on
the failed or completed call. Use it for a genuine objection, not for advice
on a call that behaved normally.

Keep the text to what the hook knows: a shell's `command not found` means the
name did not resolve on PATH, not that the tool is absent. A hint hook fails
open — any exception exits 0 with no output — so it can never break the call
it observes. A guard is the exception: see the next section.

## Start the hook script

A hook `command` without `args` runs through `sh -c`. Three things decide
whether it starts at all, and each was measured in the 2026-10 rollout of
Python 3.11 across the skill repositories.

**Quote the path placeholder.** An unquoted `${CLAUDE_PLUGIN_ROOT}` is split
at every space in the install path. Under a plugin root containing a space,
all nine hook commands of the fleet failed to open their script ("No such file
or directory"); quoted, all nine started. Write
`uv run "${CLAUDE_PLUGIN_ROOT}/scripts/x.py"` — double quotes; in single
quotes the placeholder reaches the program unexpanded, or an inner
`sh -c '…'` expands and splits it — or use exec form, where
`command` is the executable and `args` holds one argument per element without
any shell. `validate-skill.sh` warns about an unquoted placeholder.

**The launcher's own exit code counts.** Exit 2 blocks the call; any other
non-zero exit, a timeout or "command not found" (127) lets it through. `uv run`
exits **2** when it finds no Python that satisfies the script's
`requires-python`, so a hook that cannot start blocks as if it had objected.
Decide per hook which way a failure to start should fall:

| Hook | Command | A start failure |
|---|---|---|
| Guard (it denies) | `uv run "${CLAUDE_PLUGIN_ROOT}/…/guard.py"` with `"onFailure": "block"` | blocks: a guard that cannot run must not silently let everything through |
| Hint (it only adds context; it denies, if at all, through JSON) | `uv run --offline "${CLAUDE_PLUGIN_ROOT}/…/hint.py" \|\| true` | lets the call through |
| Guard that blocks with its own exit 2 but is documented as fail-open | `if uv python find --no-python-downloads ">=3.11" >/dev/null 2>&1; then uv run --offline "${CLAUDE_PLUGIN_ROOT}/…/gate.py"; fi` | lets the call through; once it runs, its exit 2 still blocks |

`|| true` would turn the third hook's own exit 2 into a pass, so it never
blocks; the bare guard form would block every call on a machine without
Python 3.11. The `uv python find` test separates the two: measured, it exits 0
on `python:3.9-slim` without starting the script, and passes the script's exit
2 through on `python:3.12-slim`. Without uv the test fails and the hook is
skipped. The script must declare only standard-library dependencies, because
`--offline` makes a package missing from uv's cache an exit 2.

`onFailure: "block"` turns every failure of the hook — crash, timeout, missing
uv — into a block. Claude Code honours it from v2.1.295; older clients ignore
the field, so say so in the `compatibility` line of `SKILL.md`. A guard's
timeout must cover the first start on a machine without Python 3.11, when uv
downloads one (36 MiB, 1.8 s in a `python:3.9-slim` container).

**A hint hook stays off the network.** Without `--offline`, that first start
downloads the interpreter inside the hook. With `--offline`, uv uses only what
is installed: on Python 3.9 it exits 2 after 0.3 s without a download, which
`|| true` turns into a pass; on 3.12 the script runs as before. Any other
`uv run` of a skill script installs the interpreter, and the hook works from
then on.

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
