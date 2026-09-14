---
name: retro
description: Mine finished tasks for recurring pipeline weaknesses and propose intentpipe improvements. Human-gated — proposes, never applies.
disable-model-invocation: true
argument-hint: "[headless]"
---

Improve the pipeline from evidence. You write proposals; you never edit the intentpipe plugin (a hook blocks writes into it).

Headless mode ($ARGUMENTS contains `headless`): never prompt; step 6's report goes to stdout only — the orchestrator daemon posts each new file in `intentpipe/retro/` to the project's topic.

1. Read every `intentpipe/tasks/*/review.md` and `intentpipe/tasks/*/feedback.md` (human-written) since the last retro (last report date: `intentpipe/retro/`), and each task's `Anatomy:` line in task.md.
2. Look for PATTERNS, not incidents: a finding class the reviewer flags repeatedly, a misunderstanding recurring across implementer runs, human feedback contradicting an agent's instructions, cost outliers (idle time, re-uploaded context, extra review rounds, repeated verify runs).
3. Rework signal: when later tasks rewrite files earlier tasks built (repo commits carry `Task-Id` trailers), read the spawning note (`git show <task.md's Intent: sha>`). Rework from misunderstanding (wrong thing built, bad decomposition boundaries) is a pipeline pattern; rework from a changed request ("now also do Y") is product evolution — never propose from it.
4. For each pattern (max 3, the highest-leverage), write `intentpipe/retro/<date>-<slug>.md`:
   - **Evidence:** task ids + the recurring quote/finding.
   - **Root cause:** which prompt/script/rule allows it.
   - **Proposed change:** exact diff against the intentpipe repo (agent prompt, skill, script, or hook), the smaller the better. A prompt addition must pull its weight: would removing the line cause the mistake to recur?
   - **Risk:** what this change could regress.
5. One-off mistakes are not patterns: list them under "observed, no action".
6. Commit the new report files in the workspace repo (`retro: <date> — <one-line summary>`; only the retro files), run `${CLAUDE_PLUGIN_ROOT}/scripts/state-land.sh`, then tell the user which proposals exist and your confidence in each.

Never edit files under the plugin root. Never edit agents' memory directly.
