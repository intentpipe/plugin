# Retro 2026-09-20 · the reviewer runs at full price on every task, and features cannot build in parallel

Proposal — part A applied in this PR (`skills/plan/SKILL.md`, `skills/build/SKILL.md`), parts B and C
are follow-ups with the problems named. Evidence window: tell-your-friends tasks 0048–0073.

## Evidence

**The reviewer is a quarter to a third of a task, and drives more than that through fix rounds.**
Only the three tasks built since anatomy.py exist with a per-agent breakdown:

| task | kind | total | reviewer | review-driven (reviewer + fix rounds) |
|---|---|---|---|---|
| 0071 | one l10n string | $2.17 | $0.52 (24%), 2m08s | same |
| 0072 | two l10n strings + one call-site arity change | $5.62 | $1.35 (24%), 2 rounds | ~$3 |
| 0073 | map reveal logic | $10.78 | $3.52 (33%), 3 rounds, 28 of 81 min | ~$6 |

**What 26 per-task reviews (0048–0073) returned.** 20 approved in round 1 with no findings. 6 opened a
fix round. Of the 9 blocking findings in those rounds:

- 4 were real user-visible bugs: 0060 (curated tag order destroyed in a surface the note excluded),
  0065 (log-out leaves the settings sheet painted over the auth screen), 0066 (scope invalidation
  skipped when the sheet closes mid-PATCH), 0073 round 1 (the new pin is gated but never guaranteed).
- 5 were only "this criterion has no executed check": 0054 (vacuous test), 0072 (arity swap unpinned),
  and all three findings of 0073's rounds 1b and 2.

Three of the four real bugs were caught inside multi-task features (tyf-186, tyf-195) with the task's
own context still fresh. The reviewer pays for itself on logic tasks.

**`Review: light` has never fired.** The tier exists since 0.43.0 (planner sets it, build spawns the
reviewer on sonnet, reviewer escalates on logic). Only two tasks carry the field, both `full`. The
rule says "copy, constants, styling values or config in ≤2 files of one repo". A one-string change
in the Flutter app touches six files: two `.arb`, three generated `app_localizations*.dart`, one
test (0069: `68e3c97`, 0071: `d988d33`). The count can never be ≤2 here, so every copy tweak gets
opus at high effort with executed checks.

**Where the tiny-task chain came from.** tyf-180 (composer dock) is nine tasks, 0048–0056, seven of
them one-to-six-dollar pixel or copy tweaks, each reviewed at full. They were not planned as nine:
each was a follow-up note after the human looked at the preview. Amendments to an open feature are
the pipeline's iteration loop, and each iteration currently pays a full review.

## A. Review tiers (applied in this PR)

1. **Measure the diff by hand-written source, not file count.** Generated files (l10n output,
   build_runner output, lockfiles) and tests do not count toward the light threshold. The 2-file cap
   stays, on source files only.
2. **`Review: none` for pure value changes.** A change map that is only string, constant or config
   *values* skips the reviewer. verify.sh remains the gate. The build skill checks the landed diff
   with `git diff --name-only`: a hand-written source file outside the value files downgrades `none`
   to `light` (the reviewer's existing tier-mismatch escalation then covers `light` → `full`), so a
   task that *looked* like copy but changed a call site (0072) is still reviewed.
3. **Amendments are light by default.** A task planned into a still-open feature that re-tunes
   values or layout in files its earlier task touched is `light` regardless of the file count. An
   amendment that adds logic (0057, a real shadow-rendering fix) is `full` as before.

Expected effect on the evidence: 0069, 0071 → `none` (saves ~$0.5 and 2 min each, plus the opus
round-trip); 0050–0053, 0055, 0056 → `light` on sonnet (saves ~$0.3–0.5 each); 0072 → planned
`none`, escalated to `light` by the diff check, reviewer on sonnet (~$0.2 instead of $1.35 and a
fix round). The four real bugs all sit in tasks that remain `full`.

**Not applied — review per feature instead of per task.** Rejected as the default. A feature-level
review of a nine-task diff is not nine times cheaper: reviewer cost scales with diff size plus
executed checks, and only the orientation overhead (~$0.3–0.5 a round) is saved. What it loses is
the fix-round locality: the three bugs found inside tyf-186/tyf-195 were fixed by an implementer
holding one task's context. The cheap version of the same idea is item 3: amendments get the light
reviewer, so a chain of tweaks costs one full review at the head and sonnet afterwards.

## B. Follow-up — cap review rounds on test-strength findings

Two of 0073's three rounds and 0072's only round carried no behaviour finding, only "add an executed
check for this criterion". Proposal: after round 1, a round whose blocking findings are all
test-strength (the code is right, the pin is missing) becomes the fix round's *nits* rather than a
new round, so a task converges in ≤2 reviews unless behaviour is wrong. Needs a reviewer.md rule
(tag such findings `[blocking-test]`) and one build.md branch. Not in this PR: it changes what the
reviewer may block on, which deserves its own evidence window.

## C. Follow-up — build features in parallel (`updates/<feature>/` subfolders)

Requested shape: `intentpipe/updates/<slug>/*.md` → the planner makes one feature per subfolder
(flat notes → one feature, as today), and one loop per feature builds them concurrently. This is
the natural extension of the existing "one feature per plan run" rule and needs no new task
schema. The build side has real problems, all solvable, in rough order of size:

1. **One working tree per repo.** `task.sh start` checks the task branch out in the shared clone
   (`REPO_X` path) and `done` checks `DEFAULT_BRANCH` back out; verify.sh, the reviewer's
   `git diff` and the AFTER_DONE preview hook all act on that checkout. Two loops would flip each
   other's branches mid-verify. Fix: a `git worktree` per feature (`<repo>/../.wt/<slug>`), with
   `repo_path()` in lib.sh honouring a per-loop override so every script and agent prompt resolves
   the feature's tree. Git refuses the same branch in two worktrees, so `done` must not check out
   `DEFAULT_BRANCH` inside a worktree (detach, or stay on the feature branch), and the first task
   of a feature becomes `git worktree add -b feature/<slug>` instead of `checkout -b`.
2. **Verify isolation for core.** `VERIFY_core` boots `tyf-db-test` and `SMOKE_core` force-recreates
   `tyf-api` via docker compose with fixed container names and a fixed `DB_PORT` from `.env.test`.
   Two concurrent core verifies collide. Fix: a compose project name per worktree (`-p`) and a port
   derived from it; or stage 1 allows parallelism only for features that do not span core, which is
   most of tyf's recent queue. Flutter test runs are safe in parallel, just CPU-bound.
3. **Agent memory forks by cwd.** `memory: project` resolves from the launcher's cwd
   (preflight already hard-fails on a forked store). Each loop must keep cwd at the project root and
   address the worktree by path, never `cd` into it — the same rule the build skill states for the
   orchestrator today.
4. **One queue, one pidfile.** `task.sh next` walks a single id-ordered queue where a blocked task
   gates everything after it; the daemon's "already running for project" guard is per project. Fix:
   `task.sh next --feature <slug>` (blocked tasks gate only their own feature), `FEATURE=` on
   loop.sh, and a per-feature pidfile in the daemon. CONTINUE_ON_BLOCK becomes unnecessary for this.
5. **Workspace state repo races.** Both loops commit `task.md`, `_log.md`, `_timings.tsv` into the
   same `intentpipe/` repo and run state-land.sh. Concurrent commits race on `index.lock`;
   concurrent state PRs conflict on the append-only files. Fix: an flock around the commit helper in
   lib.sh and `merge=union` for `_log.md` / `_timings.tsv` (task folders never overlap).
6. **Cross-feature file overlap.** Two features touching the same file conflict at `dev` after both
   PRs merge, and neither loop can see the other's diff. The subfolder split makes the human the
   partitioner; the planner should still compare change maps across concurrently open features and
   flag an overlap in its plan message rather than plan it.
7. **Preview follows the last landed branch.** AFTER_DONE runs checkout.py on the main clone; with
   two loops it alternates between features. Acceptable, but the hook should report which feature
   it is serving, or take a pinned feature from agents.env.
8. **Shared subscription window.** Two loops double the burn rate; the limit-wait logic is per
   process, so both park on the same reset. Nothing to fix, but worth knowing when reading costs.

`DONE=pr` is the right precondition: under `DONE=local` two features squash-merging into a shared
`dev` checkout would serialize on the main clone anyway. Suggested staging: (1) worktrees +
per-feature queue + state lock, parallel only for app-mobile-only features; (2) compose isolation
for core; (3) daemon pidfile per feature and a feature-prefixed Telegram report line.
