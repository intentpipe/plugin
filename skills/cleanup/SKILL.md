---
name: cleanup
description: Read-only sweep of the project repos for dead and duplicated code; findings become one intent note in updates/ for the normal plan → build pipeline. Never edits code.
disable-model-invocation: true
argument-hint: "[headless]"
---

Sweep the whole codebase for dead and duplicated code and turn what you find into one plannable intent note. You NEVER edit code.

Headless mode ($ARGUMENTS contains `headless`): never prompt; step 5's summary goes through `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh` as well as stdout.

1. Read `intentpipe/agents.env` (`REPOS`). Find the last cleanup note (`git log --oneline -- intentpipe/updates/`, `cleanup-`); run `${CLAUDE_PLUGIN_ROOT}/scripts/task.sh nits` for the nits of tasks done since. A nit is a lead, not a finding: re-verify it against the current tree and drop it if its premise is gone. Survivors are candidates like any other in step 2.
2. Sweep each repo for: symbols with zero readers outside their own definition; near-identical logic at ≥2 call sites worth one shared helper; parallel variants of the same UI concept (two sheets/cards/pickers that should be one widget; a variant that looks deliberate is flagged as a judgement call in the note, not skipped); orphaned files and exports; stale doc comments narrating removed designs. Grep-verify every candidate; a "dead" symbol with a reflective or string-keyed reader is a false positive.
3. Keep only findings worth tasking, each with file:line evidence. Skip anything an open task or unmerged PR already touches (`task.sh status`).
4. Nothing significant → report that and stop. Do not invent work.
5. Else write ONE note `intentpipe/updates/cleanup-<date>.md`: per finding the evidence and the intended action (delete / extract shared helper), plus the standing constraints — behaviour-preserving only, verify green, no test deleted to make a removal pass, judgement calls listed in task Notes. Sized for /plan to cut into 1–2 tasks. Report ≤5 lines; headless: notify `🧹 sweep: <N> findings → updates/cleanup-<date>.md — 🧠 to plan`.

Never edit repo code, never write tasks/ directly.
