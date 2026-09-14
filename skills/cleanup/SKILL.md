---
name: cleanup
description: Read-only sweep of the project repos for dead and duplicated code; findings become one intent note in updates/ for the normal plan → build pipeline. Never edits code.
disable-model-invocation: true
argument-hint: "[headless]"
---

Find the junk the per-task loop cannot see. Fresh-context implementers re-invent helpers and leave
orphans; the reviewer sees one diff and files duplication as write-only nits. You read across the
whole codebase and turn what you find into plannable intent. You NEVER edit code — fixes ride the
normal pipeline (/plan → tasks → verify → review).

Headless mode — when $ARGUMENTS contains `headless`: never prompt; step 5's summary goes through
`${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh` as well as stdout.

1. Read intentpipe/agents.env (`REPOS`). Find the last cleanup note (`git log --oneline --
   intentpipe/updates/` for `cleanup-`); run `${CLAUDE_PLUGIN_ROOT}/scripts/task.sh nits` and
   take the nits from tasks done since then. You are the only consumer of nits (/plan never folds
   them into a task): each is a lead, not a finding — re-verify it against the current tree first,
   since the code may have moved since the review, and drop a nit whose premise is gone rather
   than carrying it. Survivors are candidates like any other in step 2.
2. Sweep each repo for: symbols with zero readers outside their own definition; near-identical
   logic at ≥2 call sites worth one shared helper; parallel variants of the same UI concept (two
   sheets/cards/pickers that should be one widget — a finding like any other; a variant that looks
   deliberate is flagged as a judgement call in the note, not skipped); orphaned files and exports;
   stale doc comments narrating removed designs. Grep-verify every candidate — a "dead" symbol
   with a reflective or string-keyed reader is a false positive that would plan a breaking task.
3. Keep only findings worth tasking, each with file:line evidence. Skip anything an open task or
   unmerged PR already touches (`task.sh status`) — don't race live work.
4. Nothing significant → report that and stop. Do not invent work; a near-empty sweep is the good
   outcome.
5. Else write ONE note `intentpipe/updates/cleanup-<date>.md`: per finding, the evidence and
   the intended action (delete / extract shared helper), plus the standing constraints — behaviour-
   preserving only, verify green, no test deleted to make a removal pass, judgement calls listed in
   task Notes. Sized for /plan to cut into 1–2 tasks. Report ≤5 lines; headless: notify
   `🧹 sweep: <N> findings → updates/cleanup-<date>.md — 🧠 to plan`.

Never edit repo code, never write tasks/ directly — the human gates the plan.
