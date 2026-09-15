---
name: unblock
description: Diagnose why the build queue is stuck and auto-resolve the safe cases (finished-but-unmerged, clean retry), escalating the rest with a precise reason.
disable-model-invocation: true
argument-hint: "[task-id | all] [headless]"
---

Target: $ARGUMENTS (empty or `all` → every blocked/in-progress item). You diagnose and orchestrate; you never write code, never bypass a red verify, never merge by hand.
Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`.

Headless mode ($ARGUMENTS contains `headless`): never prompt, never call notify.sh; the closing summary is your final message, which the daemon posts to the human as one message when the run ends.

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/task.sh diagnose`: one global `verify:` color; per stuck item `commits=`, `review=`, `faillog=` and the NEEDS_HUMAN `reason:`; a `workspace <repo> dirty on <branch>` line per repo with an uncommitted tree. `(nothing blocked or in-progress)` → say so and stop. A given task id → act only on it.
2. For each item read the evidence before deciding: the `reason:` line, the tail of `tasks/<id>/loop-fail.log` when `faillog=yes`, `tasks/<id>/review.md` when the reason is about review. Classify against the cases below.
3. Auto-resolve only these mechanical cases, then re-run `task.sh diagnose` to confirm the item cleared:
   - **Finished but unmerged** — `commits=yes` and `verify: GREEN`: `task.sh reopen <id>` then `task.sh done <id>`; report the commits or PR URL. If `done` fails, treat it as RED and escalate — never retry-loop.
   - **Nothing built** — `commits=no`: `task.sh reopen <id>` (resets the task to `todo`). Report the original reason; a credit stop still needs a top-up or a `MODEL=` switch before a retry can succeed.
   - **Dirty workspace** — a `workspace <repo> dirty on <branch>` line: `task.sh clean-repo <repo>` (stashes with `git stash push -u`, reclaiming root-owned files first). Report the stash (`git -C <path> stash list`). Never `sudo rm -rf`, or any `sudo` deletion, inside a checkout; if clean-repo cannot clear it, report exactly what it printed and stay blocked. `reopen` does not clean a tree.
4. Escalate everything else: leave the item blocked and record one specific line — the why plus the recommended human action:
   - `verify: RED` with `commits=yes` → name the failing repo/finding from loop-fail.log; recommend `/intentpipe:build <id>`.
   - review did not converge → summarize the blocking finding from review.md.
   - an implementer question in the reason → quote it verbatim.
   - a blocked feature, or "PR closed without merge" / "merged before this task landed" → a human decision; say which.
5. `(nothing blocked or in-progress)` while `updates/` still holds unplanned notes → the plan step never ran or failed: say so and point to `/intentpipe:plan` (headless: 🧠); do not plan here.
6. Close with a summary: what you auto-resolved, and each item still needing a human with its one-line reason. If you reset a task to `todo` or merged finished work, say the queue is clear for `/intentpipe:build all` (headless: 🚀). Headless → it is your final message, nothing after it. Append nothing to NEEDS_HUMAN.md the diagnosis did not establish.

Never edit code, never merge manually, never bypass a red verify. Unsure whether a case is safe → escalate.
