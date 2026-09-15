---
name: build
description: Run the pipeline for one task (or the next todo one) — implement, verify, review, then squash-merge (DONE=local) or open a PR (DONE=pr).
disable-model-invocation: true
argument-hint: "[task-id | all]"
---

Arguments: $ARGUMENTS — the first word is the target (a task id; empty or `all` → `task.sh next`), and an optional `model=<sonnet|opus|fable>` is the implementer's model (absent → `opus`).
Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`. You orchestrate; you never write code.
Spawn every agent with `run_in_background: false` and wait for its result. Never end your turn while an agent you spawned is still working; never park on a timer (`ScheduleWakeup`, cron). A completion notice for an agent you did not spawn is noise: do not forward it, wait for it, or act on it.
Shell: every Bash call runs from the project root — never `cd`; the cwd persists across calls and every agent spawned afterwards resolves its `memory: project` store from it. Address files by path: `sed -i 's/^Rounds: 0/Rounds: 1/' intentpipe/tasks/<id>-<slug>/task.md`. Run `task.sh done` in the foreground with the Bash call's `timeout` at 900000; never background it and never poll for it with `pgrep -f` (the pattern matches the polling shell itself).

1. `preflight.sh --quick`; then `task.sh start <id>`.
2. Spawn ONE `implementer` for the whole task — never one per repo, never two in parallel worktrees — with `model` set to the `model=` argument: "Implement task <id>. Folder: intentpipe/tasks/<id>-<slug>/". If UI-heavy and no design.md exists, run /intentpipe:design first.
3. `RESULT: blocked` → `task.sh block <id> "<question>"`, report to the user, stop this task.
4. Spawn the `reviewer` — always, even on a resume where the branch is already complete; it must write a verdict to `review.md`. Model per task.md's `Review:` field: `light` → `model: sonnet`; `full`, unset or unknown → no override. A `light` review that returns the tier-mismatch finding (`[blocking] task.md — Review: light but the diff …`) is re-run once at full (no override); that re-run is not a Round. Never stop at Status `in-progress`. Then:
   - `VERDICT: approve` → step 5.
   - `VERDICT: blocking` and Rounds < 2 → increment Rounds in task.md, spawn a NEW `implementer` (foreground, same `model`) with the round's blocking findings AND its nits: "Fix review round <n> on task <id>; the branch holds the implementation. Fix these blocking findings: <findings>. Also fix these nits — skip one only if it is outside the files this task touches, and say so under Notes: <nits>. Re-verify, commit. Folder: …". Nits never open a round on their own. Never `SendMessage` the finished one or poll for its commit. Then review again.
   - still blocking at Rounds = 2 → `task.sh block <id> "review did not converge: <summary>"`, stop this task. Two is a hard cap.
5. `task.sh done <id>` — verifies green, then squash-merges (`DONE=local`) or pushes the branch and opens a PR (`DONE=pr`; with a `Feature:` it lands on the feature branch and the PR opens when the feature's last task lands). If it fails, treat the output as a blocking finding: one repair round, then block.
6. Report ≤5 lines to the user: task, verdict, commits or PR URL, cost if known, anything odd.
7. If the argument was `all`, repeat from step 1 until `task.sh next` reports no task; it halts on a blocked task — stop and report. `DONE=pr`: if the next task builds on work in an unmerged PR of another feature (or of a featureless task), stop and say so. Same-feature dependencies are fine.

Never edit code yourself, never merge manually, never bypass a red verify.
