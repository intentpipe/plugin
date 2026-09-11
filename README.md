# Intentpipe

A Claude Code plugin that turns plain-language intent notes into working software through a verify-gated task loop: fresh-context implementer (TDD) → deterministic verification → fresh-context reviewer → one squash-commit per feature per repo (or, for shared repos, a pre-reviewed PR — `DONE=pr`). Everything mechanical is a script; LLMs only where judgment is needed.

The shape is deliberate. The working part of autonomous coding is not an org chart of specialist agents but a verify-gated loop over small tasks with fresh context and file-based state: parallel agents win on independent *read* work (research, review) and lose on interdependent *write* work (Anthropic: ~15× tokens; Cognition: conflicting implicit decisions). Everything else was demoted to a skill or a script — a role earns its way back only when a demonstrated context doesn't fit.

## Install (once)

```
/plugin marketplace add [path-to-cloned-repo]
/plugin install intentpipe@intentpipe
```

Enable per workspace in `.claude/settings.json` (init-project does this): `{"enabledPlugins": {"intentpipe@intentpipe": true}}`.
Propagate improvements to all projects: commit here, then `/plugin marketplace update intentpipe`. A plugin installs once and is consumed read-only, so no project forks a copy that drifts (the alternatives — cloning into each project, submodules — did).

## Use

```
mkdir my-product && cd my-product && claude
/intentpipe:init-project          # interview → intentpipe/ (state) + code repos
# drop a note in intentpipe/updates/ describing what to build
/intentpipe:plan                  # notes → sized, verifiable tasks
/intentpipe:build all             # interactive: implement → verify → review → merge
$INTENTPIPE/scripts/loop.sh      # headless: fresh context per task, cost/task caps, rides out usage limits
```

Team repo (you're the only plugin user): set `DONE=pr` in `intentpipe/agents.env`. Preflight fetches a fresh `origin/<default>` base, `task.sh done` pushes the task branch and opens a pre-reviewed PR instead of merging, and `task.sh sync` (run by preflight) completes tasks once their PRs merge. A red upstream parks `loop.sh` (retry after `UPSTREAM_BACKOFF`) instead of blocking tasks.

Intent can be a picture: a photo texted into the project's Telegram topic (a UI mockup, a bug screenshot, a whiteboard sketch) becomes a permanent file in `intentpipe/resources/` plus a note referencing it — `/intentpipe:plan` reads the image and turns it into implementation tasks that carry the path (`Resources:`), so the implementer and reviewer look at the same picture.

Iterate: drop update notes (any shape) in `intentpipe/updates/` and re-run `/intentpipe:plan` — it commits your words to git history, then turns them into sized, verifiable tasks (only the delta not already built). There is no living spec to maintain; the notes' git history is the record of intent, each task.md records the note commit it was planned from (`Intent:`), and `/intentpipe:retro` reads that note to tell a misunderstanding from a changed request. In an existing codebase the code is the source of truth, so a maintained prose copy only drifts — the same goes for a "what is this system" doc; keep one if you like, the pipeline never reads it.

Human touchpoints: approve the plan, read `intentpipe/NEEDS_HUMAN.md` when a task blocks, write `intentpipe/tasks/<id>-*/feedback.md` after reviewing merged work, run `/intentpipe:retro` to turn feedback into intentpipe-improvement proposals (you apply them here — agents can't edit the plugin, a hook enforces it; or text `retro` in the project's Telegram topic — each proposal posts back as a message, and reacting to one applies it as a PR on this repo for you to merge).

## Scripts

The mechanics live in `scripts/` inside the plugin, not in your workspace. Claude sessions reach them via `${CLAUDE_PLUGIN_ROOT}/scripts/…`; from your own terminal use the plugin root — for a directory-source marketplace that is simply where you cloned this repo (check `installLocation` in `~/.claude/plugins/known_marketplaces.json`). Set it once:

```
export INTENTPIPE=~/path/to/intentpipe
```

Every script finds the workspace on its own by walking up from the current directory until it hits `agents.env` (directly or in a `intentpipe/` child). So they run identically from the project root, from `intentpipe/`, or from inside any code repo — `cd backend && $INTENTPIPE/scripts/verify.sh backend` works. The only requirement is being *somewhere below* the project root; there are no path arguments to get wrong.

| Script | What it does |
|---|---|
| `preflight.sh [--quick]` | Validate before agents run: repos exist and are clean, config sane, then a full verify run (`--quick` skips the verify). With `DONE=pr` it also checks `gh` auth + origin, fast-forwards each repo's default branch, and runs `task.sh sync`. Exit 3 means origin's default branch itself is red (wait it out, not your fault). |
| `verify.sh [--no-smoke] [repo …]` | The deterministic quality gate: runs each repo's `VERIFY_<repo>` command from agents.env, then its optional `SMOKE_<repo>` boot check — the app starts and answers (killed after `SMOKE_TIMEOUT`, default 300s; a repo that fails its own tests is never smoked). No args = all repos. Verify alone changes nothing, but a smoke command starts things — `--no-smoke` is the pure read-only color. |
| `task.sh new "<title>" [repos]` | Create the next `NNNN-slug` task folder; prints the id. Then fill in Goal / Acceptance criteria (usually `/intentpipe:plan` does this). |
| `task.sh start <id>` | Check out the task branch in each affected repo (creates it from the default branch, or resumes an existing one). |
| `task.sh next` / `task.sh status` | Print the first actionable task id — a todo, or an in-progress one to resume (so a killed session's orphan is picked back up and its dependents wait) / the full task table. Read-only. |
| `task.sh done <id>` | Finish a task: verify must be green, then `DONE=local` squash-merges one commit per repo; `DONE=pr` pushes the branch and opens a pre-reviewed PR (task parks at `Status: pr`). Every repo ends up back on the default branch, so if something serves this project, point agents.env's optional `AFTER_DONE` command at it — it runs detached with the branch that carries the landed work, once per headless loop run (log: `tasks/_after-done.log`). |
| `task.sh sync` | `DONE=pr` only: complete pr-status tasks whose PRs merged (records merge SHA, digests to `_log.md`, deletes local branches); a PR closed without merging blocks the task. Preflight runs this for you. |
| `task.sh block <id> "<reason>"` / `task.sh reopen <id>` / `task.sh abandon <id>` | Escalate a task to NEEDS_HUMAN.md (+ notification) / put a task back in play (a branch with commits resumes as in-progress, an empty one is abandoned to todo) / clean-restart a task: un-strand its repos to the default branch and delete the branch (refuses if it holds unmerged commits), back to todo. |
| `task.sh diagnose` | Read-only. List everything blocked or in-progress with the facts a recovery needs — one global verify color, then per item: has-commits, review verdict, whether a `loop-fail.log` exists, and the NEEDS_HUMAN reason. What `/intentpipe:unblock` reads to decide what it can safely auto-fix. |
| `loop.sh` | Headless driver: runs `claude -p "/intentpipe:build <id>"` with a fresh context per task. Caps via env vars: `MAX_TASKS` (default 5), `MAX_COST_USD` (15; skipped on a Claude subscription), `MAX_RESUME` (3 retries for sessions that die mid-task), `LIMIT_BACKOFF` / `UPSTREAM_BACKOFF` (seconds, default 1800), `MAX_LIMIT_RETRIES` (6 consecutive usage-limit waits before stopping with exit 5). Run it from the project root. |
| `state-land.sh` | Land committed workspace state: push on a branch, open a PR, and **merge it immediately when every changed path is routine pipeline state** (`tasks/`, `updates/`, `resources/`, `retro/`, `NEEDS_HUMAN.md`, `.claude/agent-memory/`). One foreign path (code, `agents.env`, `specs/`) demotes the PR to human-merge. A branch whose PR already merged is never reused — a fresh `state/<ts>` branch is cut at HEAD — and the merge is verified against `origin/<base>` before it reports success. Called by `loop.sh` at end of run and by /plan and /retro; tolerant like notify.sh, except that an unverified merge exits non-zero (callers already `|| true`). |
| `notify.sh "<msg>"` | The human-comms seam: prints, plus a macOS notification, a Telegram message when creds are set, and Quorum chat. Never fails its caller. Files (NEEDS_HUMAN.md) stay the durable record; messaging is a side channel. |

`preflight.sh`, `verify.sh` (`--no-smoke` if the project defines smoke commands — those start containers), `task.sh status`, and `task.sh sync` are safe to run by hand whenever you're curious; the rest mutate task state and are normally driven by `/intentpipe:build` or `loop.sh`.

## Layout

```
agents/       implementer, reviewer            (the only standing agents — earn the agent)
skills/       init-project, plan, build, design, retro, toolsmith, unblock, cleanup
scripts/      task.sh (lifecycle) · verify.sh (gate) · preflight.sh ·
              loop.sh (headless driver) · notify.sh (human comms seam) · lib.sh
hooks/        guard.py — blocks force-push, destructive rm, plugin
              self-modification, and (DONE=pr only) push-to-default
templates/    project-side starter files
```

The reason behind every non-obvious behavior sits in a comment next to the line that implements it.

## Workspace anatomy (per project)

```
my-product/         run claude here; git repo versioning the intentpipe state
  CLAUDE.md, .claude/, .gitignore   generated by init-project
  <repo>/           code repos, each its own git repo (ignored by the root repo)
  intentpipe/
    agents.env      repos (../<repo>) + verify commands (validated by preflight)
    updates/        intent notes — the human's input; /plan consumes them, git history keeps them
    resources/      permanent reference files — images texted into the topic land here; notes
                    reference them ([image: …]) and tasks record them (Resources:)
    tasks/          SINGLE SOURCE OF TRUTH: NNNN-slug/{task,review,feedback,design}.md
    tasks/_log.md   one line per merged task (bounded memory)
    NEEDS_HUMAN.md  escalations
```

## Further reading

Anthropic: [multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) · [effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) · [building effective agents](https://www.anthropic.com/engineering/building-effective-agents) · [best practices](https://code.claude.com/docs/en/best-practices) · [sub-agents](https://code.claude.com/docs/en/sub-agents) · [plugins](https://code.claude.com/docs/en/plugins) · [hooks](https://code.claude.com/docs/en/hooks)
Practitioners: [ghuntley.com/ralph](https://ghuntley.com/ralph/) · [Cognition: Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents) · [12-factor agents](https://github.com/humanlayer/12-factor-agents) · [ACE-FCA](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents) · [Willison: red/green TDD](https://simonwillison.net/guides/agentic-engineering-patterns/red-green-tdd/) · [Fowler/Böckeler on SDD](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
