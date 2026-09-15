---
name: plan
description: Decompose the intent notes in intentpipe/updates/ into small, verifiable tasks. Run after dropping a note (or a batch).
disable-model-invocation: true
argument-hint: "[which note or area to plan, default: all unplanned]"
---

Turn the notes in `intentpipe/updates/` into tasks. Focus: $ARGUMENTS

Headless mode ($ARGUMENTS contains `headless`): never prompt, never call notify.sh; everything a step would say or ask goes into your final message, which the daemon posts to the human as one message when the run ends.

1. Run, in order: `${CLAUDE_PLUGIN_ROOT}/scripts/freshen.sh` (report what it flags), `${CLAUDE_PLUGIN_ROOT}/scripts/task.sh sync`, `${CLAUDE_PLUGIN_ROOT}/scripts/inbound.sh`. Commit any uncommitted notes as written. Ignore `README.md`. No notes → ask the user what to build and stop (headless: final message "nothing queued — text intent first", then stop).
2. Read the notes, `intentpipe/tasks/_log.md`, and `${CLAUDE_PLUGIN_ROOT}/scripts/task.sh status`. A note may reference an image (`[image: intentpipe/resources/…]`): Read the file — it is the intent, the caption is not. Never fold `[nit]` findings from `tasks/*/review.md` into a task; they belong to `/intentpipe:cleanup`. Plan only what the notes ask for, is not already covered by a task, and is not already in the code — check the repos first.
3. Draft the task list. Each task MUST have:
   - a goal one implementer can finish and verify in a single green run,
   - testable acceptance criteria ("WHEN <condition> THE SYSTEM SHALL <behavior>") at the level the change lives: copy, constants and config name the key and its value; "WHEN a user …" only for a task that changes behaviour — the reviewer executes exactly what a criterion names,
   - explicit non-goals ("don't touch X") that exclude other work, never another instance of the defect the note reports,
   - for a client that writes to a server: one criterion for the failed write (what the user sees, what the UI reverts to) and one for what the client renders after a refetch,
   - the repos it spans (cross-repo only when the feature genuinely spans them),
   - a `## Change map` section in task.md: the files, functions and tests to touch, as far as you can see (spawn an `Explore` agent to see it). More than ~6 files, or more than one repo → split.
   - `Model:` — `sonnet` by default; `opus` only when the task spans repos, settles a design question the note left open, or chases an unclear root cause — say which in Notes.
   - `Effort:` — `medium` by default; `high` only for a task that also earned `opus`.
   - `Review:` — `light` when the change map is copy, constants, styling values or config in ≤2 files of one repo, with no control flow, data contract, migration or auth/security surface; `full` for everything else (any logic, an API shape, a schema, a dependency, anything the note calls a bug). The tier measures what a wrong implementation could hide, not diff size: a one-line auth check is `full`.
   Prefer the smaller split: split whenever a task carries two separable deliverables; keep them together only when neither half verifies alone; too big for one run → split, always. Vague note → ask the user now, not the implementer later.
   `DONE=pr`: group all of this run's tasks into ONE feature (slug: a short name for the run's intent); separate features only when the user explicitly asks for separately mergeable PRs. A note that amends work in a still-open PR (`tasks/_features/<slug>` says `Status: pr`) → plan into that same feature: pass its slug to `task.sh new`. A feature marked `done` takes no amendments (`task.sh new` refuses the slug): plan a fresh task/feature and say so. A featureless task's PR cannot be amended: plan a follow-up.
4. Order by dependency, then present the list — feature grouping, each task's model pick, and for a task amending an open PR that PR's URL from the feature file — for approval (headless: skip; approval is the 🚀 message after the run's message). Decomposition quality is the leading indicator of pipeline success — spend your effort here.
5. On approval: if `LINEAR_TEAM_KEY` is set in agents.env and `DONE=pr`, run `${CLAUDE_PLUGIN_ROOT}/scripts/linear.sh create "<plan title>" "<task list as a markdown checklist, grouped by feature>"` (prints `<KEY>\t<url>`), prefix every feature slug with the key lowercased (`eng-123-<slug>`), and put every task in a feature (wrap a one-off in its own).
   For each task: `${CLAUDE_PLUGIN_ROOT}/scripts/task.sh new "<title>" ["<repos>"] ["<feature-slug>"]`, fill Goal / Change map / Acceptance criteria / Non-goals, set `Model:`, `Effort:`, `Review:`. A task planned from an image sets `Resources:` to the path(s). A task that hinges on a product decision the user has not made (a lifetime, a threshold, an either/or, how far a defect's fix reaches) sets `Decision: <the exact question>` — never a silent assumption in the Goal, never an interpretation "flagged for review" in prose. Then delete the note files you fully planned and commit the deletion. Never delete the `updates/` folder, its `README.md`, or `.inbox/`. Do not implement anything. Headless: run `${CLAUDE_PLUGIN_ROOT}/scripts/state-land.sh` (its exit never blocks you), then end — your final message is the created task list only (titles, feature grouping, amendments with their PR URL, the Linear url if any), nothing about the run itself.
