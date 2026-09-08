---
name: toolsmith
description: Wrap an observed repetitive operation into a project-local script or skill. Invoke when the same multi-step dance appears in ≥3 tasks.
argument-hint: "<the repetitive operation>"
---

Build one tool for: $ARGUMENTS

1. Confirm the repetition is real: find the ≥3 places (task notes, transcripts, code) where agents did this by hand. If you can't, say so and stop — speculative tooling is forbidden.
2. Prefer, in order: a script in the project's `bin/` (deterministic, no LLM) → a project skill in `.claude/skills/` (procedure needing judgment) → an MCP server (only for external-system access).
3. The tool must be self-verifying: clear usage line, loud failures, an example invocation that you run and show passing.
4. Record it in ONE line in your agent memory (`MEMORY.md`) so the next session finds it — CLAUDE.md is read-only for the pipeline.

Tools live in the project, never in the intentpipe plugin.
