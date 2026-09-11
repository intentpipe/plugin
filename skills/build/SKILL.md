---
name: build
description: Run the pipeline for one task (or the next todo one) — implement, verify, review, then squash-merge (DONE=local) or open a PR (DONE=pr).
disable-model-invocation: true
argument-hint: "[task-id | all]"
---

Arguments: $ARGUMENTS — the first word is the target (a task id; empty or `all` → use `task.sh next`), and an optional `model=<sonnet|opus|fable>` is the implementer's model (the planner's `Model:` pick, or the run's `MODEL=` pin; absent → `opus`).
Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`. You orchestrate; you do not write code yourself.
Spawn every agent with `run_in_background: false` and wait for its result — the loop runs headless, and ending your turn tears down a background agent mid-work, stranding its uncommitted edits (this line can go once headless runs await background children). **Never end your turn while an agent you spawned is still working, and never park on a timer (`ScheduleWakeup`, cron): a headless run ends the moment your turn ends, and the task blocks with no committed work.** A completion notice for an agent you did not spawn (a subagent's own child) is noise — the agent you spawned returns its own result in the same call; do not forward, do not wait, do not act on it.

1. `preflight.sh --quick`; then `task.sh start <id>`.
2. Spawn one `implementer` agent for the whole task — never one per repo (a pair drifts on the API contract), never two in parallel worktrees (worktrees solve file collisions, not decision conflicts) — with `model` set to the `model=` argument: "Implement task <id>. Folder: intentpipe/tasks/<id>-<slug>/". If UI-heavy and no design.md exists, run /intentpipe:design first.
3. `RESULT: blocked` → `task.sh block <id> "<question>"`, report to user, stop this task.
4. Spawn the `reviewer` agent on the task — **always**, and always let it write a verdict to `review.md`, even on a resume where the branch is already complete and step 2 was a no-op. A branch that already looks finished still flows review → done; never stop at Status `in-progress`. Then:
   - `VERDICT: approve` → step 5.
   - `VERDICT: blocking` and Rounds < 2 → increment Rounds in task.md, send ONLY the blocking findings back to the implementer to fix, then review again.
   - still blocking at Rounds = 2 → `task.sh block <id> "review did not converge: <summary>"`, stop this task. Two is a hard cap: review converges by construction (nits never re-loop, blocking re-loops twice), never by ping-pong.
5. `task.sh done <id>` — verifies green, then per `DONE` in agents.env: `local` squash-merges one commit per repo; `pr` pushes the branch and opens a pre-reviewed PR (the task completes via `task.sh sync` once a human merges it). `pr` with a `Feature:` in task.md instead merges the task as one commit onto its `feature/<slug>` branch; the PR opens automatically when the feature's last task lands. If it fails, treat the failure output as a blocking finding: one repair round, then block.
6. Report ≤5 lines to the user: task, verdict, commits or PR URL, cost if known, anything odd.
7. If the argument was `all`, repeat from step 1 until `task.sh next` reports no task — it halts (and says so) on a blocked task, which gates its successors, so stop and report when it does. `DONE=pr`: if the next task builds on work sitting in an unmerged PR *of another feature (or featureless task)*, stop and say so — it would branch from a base without that work. Same-feature dependencies are fine: they share the feature branch.

Never edit code yourself, never merge manually, never bypass a red verify.
