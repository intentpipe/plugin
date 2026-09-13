---
name: retro
description: Mine finished tasks for recurring pipeline weaknesses and propose intentpipe improvements. Human-gated — proposes, never applies.
disable-model-invocation: true
argument-hint: "[headless]"
---

Improve the pipeline from evidence. You may NOT edit the intentpipe plugin — you write proposals; the human applies them in the intentpipe repo. Unsupervised prompt self-editing degrades a pipeline (slop accumulates, goals drift), so prompt changes are release-engineered like code, and a hook physically blocks writes into the plugin.

Headless mode — when $ARGUMENTS contains `headless` (Telegram-triggered, nobody at a terminal): never prompt. Work exactly as below; step 6's report goes to stdout only — when this run finishes, the orchestrator daemon reads the new files in `intentpipe/retro/` and posts each proposal into the project's topic, where a reaction applies it (a headless run in the intentpipe repo that makes the proposed change and opens a PR). The human gate is the reaction plus the PR merge.

1. Read every `intentpipe/tasks/*/review.md` and `intentpipe/tasks/*/feedback.md` (human-written) since the last retro (check `intentpipe/retro/` for the last report date).
2. Look for PATTERNS, not incidents: a finding class the reviewer flags repeatedly, a misunderstanding recurring across implementer runs, human feedback contradicting an agent's instructions, cost outliers.
3. Rework signal: task.md records the update-note commit each task was planned from (`Intent:`), and repo commits carry `Task-Id` trailers — when later tasks rewrite files earlier tasks built, read the spawning note (`git show <Intent>`) to find out why. Rework from misunderstanding (agent built the wrong thing, decomposition drew bad boundaries) is a pipeline pattern; rework from a changed request ("now also do Y") is product evolution — never propose changes from it.
4. For each pattern (max 3 per retro — the highest-leverage ones), write `intentpipe/retro/<date>-<slug>.md`:
   - **Evidence:** task ids + the recurring quote/finding.
   - **Root cause:** which prompt/script/rule allows it.
   - **Proposed change:** exact diff against the intentpipe repo (agent prompt, skill, script, or hook) — the smaller the better. Prompt additions must pull their weight: would removing this line cause the mistake to recur?
   - **Risk:** what this change could regress.
5. One-off mistakes are not patterns — list them under "observed, no action" and move on.
6. Commit the new report files in the workspace repo (`retro: <date> — <one-line summary>`; only the retro files, nothing else), run `${CLAUDE_PLUGIN_ROOT}/scripts/state-land.sh` (PR + automerge for the state-only diff), then tell the user which proposals exist and your confidence in each.

Never edit files under the plugin root. Never edit agents' memory directly.
