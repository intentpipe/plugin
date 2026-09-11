#!/usr/bin/env bash
# Headless driver: fresh Claude context per task, deterministic task selection,
# hard iteration + cost caps. On a Claude subscription the cost cap is skipped
# (no per-token bill; cost is only an API-equiv estimate). A usage/rate-limit
# exit pauses until the reset and retries the task instead of blocking it —
# bounded by MAX_LIMIT_RETRIES consecutive waits (exit 5 past that, since a limit
# that hasn't cleared in that long isn't one waiting will clear), and announced
# only on the first wait and on giving up, not on every attempt.
# Out of credits (billing exhausted — doesn't reset on a timer) hard-stops with
# exit 4; a human must top up or switch MODEL, so retrying is pointless.
# Every retry of the SAME task (limit wait, transient drop, in-progress resume)
# re-invokes with --resume on the dead session's id, so it continues that
# conversation instead of re-orienting from zero; fresh context stays per-task.
# A session that ends still in-progress (work committed but not merged) is driven
# to a terminal state: finished deterministically when the branch is green +
# committed (review approved, or a resume that stalled — so it is never blocked
# merely for lacking a review verdict), else re-invoked up to MAX_RESUME times,
# else blocked with the verify color (GREEN/RED) in the reason.
# DONE=pr: a red origin/DEFAULT_BRANCH (preflight exit 3) parks the loop and
# retries after UPSTREAM_BACKOFF — teammate breakage is not a task failure.
# Run from the project root.
# Task selection halts on a blocked task (task.sh next gates its successors);
# CONTINUE_ON_BLOCK=1 skips past it. The queue is peeked before preflight, so a
# run with nothing to build exits in seconds instead of paying a full verify. A transient API/network drop and an env crash
# before any work (no network, stranded tree) are retried up to MAX_RETRIES with
# RETRY_BACKOFF between tries — never counting against MAX_RESUME — then hard-stop
# with the captured reason; a zero-commit branch is abandoned so the retry is clean.
# Each task's IMPLEMENTER runs on the model the planner chose for it (Model:
# sonnet|opus in task.md; unset/unknown → opus), handed to the build skill as
# `model=<m>`; the orchestrating session itself runs on ORCH_MODEL (default opus).
# An explicitly set MODEL=sonnet|opus|fable pins the implementer for the whole run instead — the escape hatch for limits/credits stays a one-knob
# override — and either way the session never silently falls back to a cheaper
# default. Effort works the same way: the planner's Effort: field (low|medium|high|
# xhigh|max, unset/unknown → medium) sets the implementer session's reasoning depth,
# and EFFORT= pins it for the run. Medium is the default because the reviewer runs
# at high regardless (agents/reviewer.md) and catches what a cheaper pass misses.
# (The agent-frontmatter `effort:` key was undocumented at CLI 2.1.263; if it is
# ignored the reviewer inherits the session's effort — check a reviewer
# transcript before relying on it.)
# Every finished task reports what it cost in BOTH currencies — dollars (real, or
# API-equivalent on a subscription) and tokens — plus a per-step wall-clock
# breakdown (preflight / llm / verify / smoke) collected in tasks/<id>/timings.tsv
# by the scripts themselves. Both are recorded into task.md (Cost:, Timing:).
# Not built: token accounting inside interactive sessions — the CLI exposes
# usage only in this headless JSON output.
# Usage: MODEL=opus ORCH_MODEL=opus EFFORT=medium MAX_TASKS=5 MAX_COST_USD=15 MAX_RESUME=3 MAX_RETRIES=10 RETRY_BACKOFF=60 LIMIT_BACKOFF=1800 MAX_LIMIT_RETRIES=6 UPSTREAM_BACKOFF=1800 CONTINUE_ON_BLOCK=0 loop.sh
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS/lib.sh"
# `claude -p` below resolves the agents' `memory: project` store from cwd, so
# every launcher must agree on one directory or the implementer's and reviewer's
# lessons fork per launcher (proposals/2026-07-29-agent-memory-forks-by-cwd.md).
# That directory is the project root — the workspace's parent when state lives in
# an intentpipe/ child, the workspace itself in the flat layout.
case "$(basename "$WS")" in intentpipe) cd "$(dirname "$WS")" ;; *) cd "$WS" ;; esac

MAX_TASKS="${MAX_TASKS:-5}"
MAX_COST_USD="${MAX_COST_USD:-15}"
MAX_RESUME="${MAX_RESUME:-3}"
MAX_RETRIES="${MAX_RETRIES:-10}"
RETRY_BACKOFF="${RETRY_BACKOFF:-60}"
# A usage limit clears on a timer, so waiting is the right move — but not forever.
# Six waits covers a normal 5-hour session window (limit_wait honours the reset
# stamp when the CLI sends one, LIMIT_BACKOFF=30m when it doesn't); past that the
# limit is not the kind that's about to clear and a human should decide.
MAX_LIMIT_RETRIES="${MAX_LIMIT_RETRIES:-6}"
BUILD_SKILL="${BUILD_SKILL:-/intentpipe:build}"
# Model resolution: the planner picks per task (Model: field); an explicitly set
# MODEL pins the whole run and overrides those picks. Friendly names map to what
# claude --model accepts, and an unknown name is loud, never a silent fallback.
model_arg() {
  case "$1" in
    opus)   echo "opus" ;;
    sonnet) echo "sonnet" ;;
    fable)  echo "claude-fable-5" ;;
    *) return 1 ;;
  esac
}
effort_ok() { case "$1" in low|medium|high|xhigh|max) return 0 ;; *) return 1 ;; esac; }
EFFORT_PINNED="${EFFORT:+1}"
EFFORT="${EFFORT:-medium}"
effort_ok "$EFFORT" || { echo "ERROR: EFFORT must be low, medium, high, xhigh or max (got '$EFFORT')" >&2; exit 1; }
MODEL_PINNED="${MODEL:+1}"
MODEL="${MODEL:-opus}"
MODEL_ARG=$(model_arg "$MODEL") \
  || { echo "ERROR: MODEL must be opus, sonnet, or fable (got '$MODEL')" >&2; exit 1; }
# The build session itself is the orchestrator: it spawns the implementer and
# the reviewer, reads verdicts, decides fix rounds and blocks — few turns, all
# judgment. It runs on ORCH_MODEL (default opus) whatever the task's pick; the
# task's Model: is handed to the skill in the prompt (`model=<m>`) and applies to
# the implementer agent only. Quorum 0071: a sonnet orchestrator parked itself on
# a wake-up timer waiting for a subagent and ended its turn — a headless run
# ends with the turn, and the task blocked with no committed work.
ORCH_MODEL="${ORCH_MODEL:-opus}"
ORCH_MODEL_ARG=$(model_arg "$ORCH_MODEL") \
  || { echo "ERROR: ORCH_MODEL must be opus, sonnet, or fable (got '$ORCH_MODEL')" >&2; exit 1; }
total_cost=0 n=0 retries=0 total_in=0 total_out=0 total_secs=0
# Consecutive usage-limit waits (reset when a task finishes) and the total time
# spent in them, for the give-up message.
limit_retries=0 limit_waited=0

# On a Claude subscription there's no per-token bill, so total_cost_usd is an
# API-equivalent estimate, not real spend — record it but don't cap on it.
# Detect it: no API credentials and not routed through Bedrock/Vertex.
SUBSCRIPTION=
[ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] \
  && [ "${CLAUDE_CODE_USE_BEDROCK:-}" != "1" ] && [ "${CLAUDE_CODE_USE_VERTEX:-}" != "1" ] \
  && SUBSCRIPTION=1
errf=$(mktemp); trap 'rm -f "$errf"' EXIT
# Inherited by every script the session runs: tells task.sh that a landed task's
# AFTER_DONE hook belongs to the END of this run, not to the moment it lands.
export INTENTPIPE_LOOP=1

# The run's closing summary. Also used by the pre-preflight peek below, so an
# early exit reports exactly the way a completed run does.
finish_notify() {
  local run_toks spent pending
  # Land the run's workspace-state commits (task records, memory, logs) before
  # summarising: PR + automerge when state-only. Tolerant — never fails the run.
  "$SCRIPTS/state-land.sh" || true
  # Fire the workspace's AFTER_DONE hook once, for the branch that landed LAST —
  # task.sh only records it while a loop is running (lib.sh), because a hook that
  # checks branches out would fight the next task. Every exit path comes through
  # here, including the ones that build nothing (no file, no hook).
  pending="$TASKS/_after-done.pending"
  if [ -f "$pending" ]; then
    INTENTPIPE_LOOP= after_done "$(cat "$pending")"
    rm -f "$pending"
  fi
  run_toks="$(fmt_k $((total_in + total_out))) tok"
  if [ -n "$SUBSCRIPTION" ]; then spent="subscription (~\$$total_cost API-equiv, $run_toks)"; else spent="\$$total_cost, $run_toks"; fi
  "$SCRIPTS/notify.sh" "loop.sh finished: $n task(s) in $(fmt_dur "$total_secs"), $spent. $("$SCRIPTS/task.sh" status | tail -n +2 | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"
}

# Peek the queue before preflight: with nothing to build (empty queue, or a
# blocked task gating it) a run should cost seconds, not a multi-minute verify of
# every repo that is immediately followed by "0 task(s)". next also returns
# in-progress orphans, so a cold start still reaches the reconcile below.
prc=0; "$SCRIPTS/task.sh" next >/dev/null || prc=$?
if [ "$prc" -ne 0 ]; then
  if [ "$prc" -eq 3 ]; then
    echo "── stopping: a blocked task gates the queue (set CONTINUE_ON_BLOCK=1 to skip)"
    "$SCRIPTS/notify.sh" "loop.sh stopped: a blocked task gates the queue" || true
  else
    echo "no todo tasks left"
  fi
  finish_notify
  exit 0
fi

until "$SCRIPTS/preflight.sh"; do
  rc=$?
  [ "$rc" -eq 3 ] || exit "$rc"
  wait="${UPSTREAM_BACKOFF:-1800}"
  echo "── upstream red; retrying preflight in $((wait / 60))m"
  "$SCRIPTS/notify.sh" "loop.sh: origin/$DEFAULT_BRANCH is red — retrying in $((wait / 60))m" || true
  sleep "$wait"
done

# Cold-start reconcile: a session killed mid-task leaves an orphan in-progress
# that a fresh run's task.sh next would otherwise skip. One with committed work is
# resumed (task.sh next now returns in-progress); one with a zero-commit branch was
# killed before any work landed — abandon it so its repo is restored to
# DEFAULT_BRANCH and it restarts clean rather than resuming an empty branch. Either
# way task.sh next gates its dependents until it reaches a terminal state.
for d in "$TASKS"/[0-9]*/; do
  [ -f "$d/task.md" ] || continue
  [ "$(get_field "$d/task.md" Status)" = "in-progress" ] || continue
  oid=$(basename "$d" | cut -d- -f1)
  if branch_has_commits "$oid"; then
    echo "── cold start: $oid is in-progress with commits — will resume"
  else
    echo "── cold start: $oid is in-progress but empty — abandoning to todo"
    "$SCRIPTS/task.sh" abandon "$oid" >/dev/null
  fi
done

while [ "$n" -lt "$MAX_TASKS" ]; do
  nrc=0; id=$("$SCRIPTS/task.sh" next) || nrc=$?
  if [ "$nrc" -ne 0 ]; then
    if [ "$nrc" -eq 3 ]; then
      echo "── stopping: a blocked task gates the queue (set CONTINUE_ON_BLOCK=1 to skip)"
      "$SCRIPTS/notify.sh" "loop.sh stopped: a blocked task gates the queue" || true
    else
      echo "no todo tasks left"
    fi
    break
  fi
  # A task the planner gated on a human decision (`Decision: <question>`) must not
  # be built blindly — the builder can't invent the call, so it would end with no
  # committed work and the loop would respin on it forever. Ask the human on
  # Telegram (reply-to-decide) and block so the queue stops here until task.sh
  # resolve folds the answer in and reopens it. block is silenced so the human sees
  # only ask.sh's question, not a duplicate generic "blocked" line.
  decision=$(get_field "$(task_dir "$id")/task.md" Decision) || decision=""
  if [ -n "$decision" ] && [ "$decision" != "-" ]; then
    echo "── task $id needs a human decision — asking on Telegram and blocking"
    NOTIFY_SILENT=1 "$SCRIPTS/task.sh" block "$id" "awaiting human decision: $decision" >/dev/null
    "$SCRIPTS/ask.sh" "$id" "$decision" || true
    continue
  fi
  if [ -n "$SUBSCRIPTION" ]; then spent="subscription"; else spent="\$$total_cost"; fi
  echo "══ task $id (task $((n + 1))/$MAX_TASKS, spent $spent)"
  # The planner's per-task pick, unless the run pinned a model. An unknown value
  # (a typo'd field) warns and falls back rather than dying mid-queue.
  task_model="$MODEL" task_model_arg="$MODEL_ARG"
  if [ -z "$MODEL_PINNED" ]; then
    tmodel=$(get_field "$(task_dir "$id")/task.md" Model) || tmodel=""
    if [ -n "$tmodel" ] && [ "$tmodel" != "-" ]; then
      if targ=$(model_arg "$tmodel"); then
        task_model="$tmodel" task_model_arg="$targ"
      else
        echo "WARN: task $id has unknown Model '$tmodel' — using $MODEL" >&2
      fi
    fi
  fi
  task_effort="$EFFORT"
  if [ -z "$EFFORT_PINNED" ]; then
    teffort=$(get_field "$(task_dir "$id")/task.md" Effort) || teffort=""
    if [ -n "$teffort" ] && [ "$teffort" != "-" ]; then
      if effort_ok "$teffort"; then task_effort="$teffort"
      else echo "WARN: task $id has unknown Effort '$teffort' — using $EFFORT" >&2; fi
    fi
  fi
  echo "Solving task with $(echo "$task_model" | tr '[:lower:]' '[:upper:]') at effort $task_effort (orchestrator: $ORCH_MODEL)"
  resume=0; task_cost=0; task_in=0; task_out=0; fail_reason=""; prompt="$BUILD_SKILL $id model=$task_model"; sid=""
  # INTENTPIPE_TIMING_ID pins every script the session runs (preflight/verify) to this
  # task's timings.tsv, whatever its Status has become by then.
  export INTENTPIPE_TIMING_ID="$id"
  while :; do
    before=$(branch_head "$id")   # branch tips before the session, to detect a no-op resume
    rc=0
    # LLM time = session wall clock minus whatever the scripts recorded while it
    # ran, so `llm` is the model's own work (implement + review) and the rows in
    # timings.tsv stay non-overlapping — their sum is the task's real total.
    sess_t0=$(date +%s); scripted_before=$(timing_total "$id")
    # No --max-turns on purpose: a task that genuinely needs 200 turns should get
    # them; size is the lever, and it is pulled at plan time. Timers are
    # disallowed because a headless orchestrator has nothing to wait for that a
    # synchronous Agent call does not already wait for (see ORCH_MODEL above).
    out=$(claude -p "$prompt" \
          ${sid:+--resume "$sid"} \
          --model "$ORCH_MODEL_ARG" \
          --effort "$task_effort" \
          --permission-mode acceptEdits \
          --allowedTools "Bash,Read,Edit,Write,Glob,Grep,Agent,Skill,TodoWrite" \
          --disallowedTools "ScheduleWakeup,CronCreate" \
          --output-format json 2>"$errf") || rc=$?
    sess_secs=$(( $(date +%s) - sess_t0 ))
    scripted=$(( $(timing_total "$id") - scripted_before ))
    [ "$scripted" -ge 0 ] && [ "$scripted" -le "$sess_secs" ] || scripted=0
    timing_record llm "$(( sess_secs - scripted ))"
    # The envelope's session_id: any retry of the SAME task below (limit wait,
    # transient drop with commits, in-progress resume) --resumes it, continuing
    # the conversation — files read, plan, partial work — instead of paying full
    # re-orientation in a fresh context. Fresh context stays per-TASK; only
    # within-task retries reuse. Unparseable output keeps the previous id:
    # resuming the last session that produced one still beats starting over.
    # (--resume forks to a new id, so each attempt re-captures.)
    newsid=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' 2>/dev/null) || newsid=""
    [ -n "$newsid" ] && sid="$newsid"
    dir=$(task_dir "$id"); status=$(get_field "$dir/task.md" Status)
    if [ "$rc" -ne 0 ] && [ "$status" != "done" ] && [ "$status" != "pr" ] \
       && wait=$(limit_wait "$out"$'\n'"$(cat "$errf")"); then
      # usage limit, not a task failure: park WIP so preflight passes on retry,
      # reopen if the dying session blocked it, then wait it out and rerun.
      park_wip "$id" "wip: interrupted by usage limit"
      [ "$status" = "blocked" ] && "$SCRIPTS/task.sh" reopen "$id" >/dev/null
      limit_retries=$((limit_retries + 1))
      # Bounded, and loud only once. Unbounded retries polled a limit for 3.5h
      # (seven waits on one task) and fired an identical Telegram ping every time,
      # which trains the human to ignore the channel. The FIRST wait is worth a
      # notification — it explains a stalled loop — and so is giving up; the ones
      # in between say nothing new and stay in the log.
      if [ "$limit_retries" -gt "$MAX_LIMIT_RETRIES" ]; then
        echo "── stopped: usage limit on $id still not cleared after $MAX_LIMIT_RETRIES retries" >&2
        "$SCRIPTS/notify.sh" "loop.sh stopped: usage limit on $id persisted through $MAX_LIMIT_RETRIES retries ($((limit_waited / 60))m) — relaunch when it resets, or switch model (MODEL=sonnet|fable)" || true
        exit 5
      fi
      limit_waited=$((limit_waited + wait))
      echo "── usage limit on $id ($limit_retries/$MAX_LIMIT_RETRIES); retrying in $((wait / 60))m"
      [ "$limit_retries" -eq 1 ] && \
        "$SCRIPTS/notify.sh" "loop.sh: usage limit — retrying task $id in $((wait / 60))m (up to $MAX_LIMIT_RETRIES tries; quiet until it clears or gives up)" || true
      sleep "$wait"
      continue
    fi
    if [ "$rc" -ne 0 ] && is_out_of_credits "$out"$'\n'"$(cat "$errf")"; then
      # Out of credits doesn't reset on a timer, so waiting/retrying is useless.
      # Park any WIP and hard-stop (exit 4) with an exact, actionable message
      # rather than burning MAX_RETRIES on a condition only a human can clear.
      park_wip "$id" "wip: interrupted, out of credits"
      echo "── stopped: out of credits on $id — top up (/usage-credits) or switch model (MODEL=sonnet|fable)"
      "$SCRIPTS/notify.sh" "loop.sh stopped: out of credits on $id — top up or switch model" || true
      exit 4
    fi
    if [ "$rc" -ne 0 ] && [ "$status" != "done" ] && [ "$status" != "pr" ] \
       && is_transient_api_error "$(echo "$out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except Exception: pass' 2>/dev/null)"$'\n'"$(cat "$errf")"; then
      # Transient network/API drop (e.g. "connection closed mid-response") — external
      # and self-clearing, not the task's fault. It must never count against MAX_RESUME
      # nor terminate the loop. No committed work → abandon so the branch/repo restart
      # clean and the retry starts fresh; work landed → park it. Retry the SAME task,
      # bounded by MAX_RETRIES so a persistent outage still hard-stops.
      if branch_has_commits "$id"; then
        park_wip "$id" "wip: interrupted by transient API error" || true
      else
        "$SCRIPTS/task.sh" abandon "$id" >/dev/null 2>&1 || true
        resume=0; prompt="$BUILD_SKILL $id"; sid=""   # empty branch is gone; start fresh
      fi
      retries=$((retries + 1))
      if [ "$retries" -ge "$MAX_RETRIES" ]; then
        echo "── $id: transient API error ${retries}× — persistent outage, stopping the loop" >&2
        "$SCRIPTS/notify.sh" "loop.sh hard-stop: transient API error on $id ${retries}× — relaunch to retry" || true
        break 2
      fi
      echo "── $id: transient API error ($retries/$MAX_RETRIES) — retrying in ${RETRY_BACKOFF}s"
      sleep "$RETRY_BACKOFF"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      # Preserve the full failure and surface a concise reason from claude's JSON
      # result envelope (subtype/is_error/result), not just "nonzero".
      log="$dir/loop-fail.log"
      { echo "# $(date -u +%FT%TZ)  rc=$rc  status=$status  attempt=$n/$MAX_TASKS"
        echo "## reason (claude JSON envelope)"
        echo "$out" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print("subtype=%s is_error=%s num_turns=%s duration_ms=%s"%(
        d.get("subtype"), d.get("is_error"), d.get("num_turns"), d.get("duration_ms")))
    r=d.get("result") or d.get("error") or ""
    if r: print("result: "+str(r))
except Exception as e:
    print("(stdout was not a JSON envelope: %s)"%e)'
        echo "## stdout(raw)"; echo "$out"
        echo "## stderr"; cat "$errf"
      } >"$log" 2>&1
      # One-line reason for messages + the resume prompt: prefer the last stderr
      # line (where a connection/network error lands), else the parsed envelope.
      fail_reason=$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -1 | cut -c1-200)
      [ -n "$fail_reason" ] || fail_reason=$(sed -n '3,4p' "$log" | tr '\n' ' ' | cut -c1-200)
      echo "WARN: claude exited nonzero (rc=$rc) on $id — full detail in $log" >&2
      sed -n '2,6p' "$log" | sed 's/^/    /' >&2
    fi
    cost=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("total_cost_usd", 0))' 2>/dev/null || echo 0)
    task_cost=$(python3 -c "print(round($task_cost + $cost, 2))")
    # Tokens from the same envelope. Cache reads/writes are input the session
    # really consumed, so they count — an API-equiv cost figure with no token
    # count behind it says nothing about how much work a task actually was.
    usage=$(echo "$out" | python3 -c 'import json,sys
try: u = json.load(sys.stdin).get("usage") or {}
except Exception: u = {}
g = lambda k: u.get(k) or 0
print(g("input_tokens") + g("cache_creation_input_tokens") + g("cache_read_input_tokens"), g("output_tokens"))' 2>/dev/null || echo "0 0")
    task_in=$((task_in + ${usage%% *})); task_out=$((task_out + ${usage##* }))
    # A stalled resume: the session exited cleanly but committed nothing new — so
    # resuming again would just no-op. Detected by comparing branch tips.
    stalled=; { [ "$rc" -eq 0 ] && [ "$(branch_head "$id")" = "$before" ]; } && stalled=1
    # The merge (task.sh done) runs inside the model session; a session that ends a
    # step early leaves the task in-progress — work committed, unmerged. Drive it to
    # a terminal state rather than accepting that as a failure. This handles the
    # committed-work case; a nonzero exit with NO work falls through to the env-retry
    # guard below (there is nothing to resume).
    if [ "$status" = "in-progress" ] && branch_has_commits "$id"; then
      approved=; [ "VERDICT: approve" = "$(grep '^VERDICT:' "$dir/review.md" 2>/dev/null | tail -1)" ] && approved=1
      # Deterministic finish (no extra model call): merge when the review approved,
      # or when resuming is pointless — the session stalled (no new commit) or the
      # resume budget is nearly spent. task.sh done re-runs verify.sh, so a red tree
      # is never merged; green committed work is finished, not blocked for lack of a
      # review verdict (the failure this guards against).
      if { [ -n "$approved" ] || [ -n "$stalled" ] || [ "$resume" -ge "$((MAX_RESUME - 1))" ]; } \
         && "$SCRIPTS/task.sh" done "$id" >/dev/null 2>&1; then
        status=$(get_field "$dir/task.md" Status)   # done, or pr when DONE=pr
      elif [ "$resume" -lt "$MAX_RESUME" ] && [ -z "$stalled" ]; then
        # Bounded auto-resume: re-invoke the same task. task.sh start resumes its
        # existing branch, so build continues into review + merge. The prior failure
        # reason rides along so the retry doesn't repeat the mistake.
        resume=$((resume + 1))
        park_wip "$id" "wip: interrupted session"
        echo "── $id ended in-progress; resuming to finish ($resume/$MAX_RESUME)"
        prompt="$BUILD_SKILL $id — already in progress on its branch; finish the pipeline (review if needed) and RUN task.sh done to verify + merge. Do not stop until Status is done or blocked.${fail_reason:+ Previous attempt failed: $fail_reason}"
        continue
      else
        # Can't finish and can't usefully resume — block, naming the verify color so
        # a human can tell finished-but-unmerged (GREEN) from genuinely broken (RED).
        # --no-smoke: this only colors a block reason; booting the app proves nothing here.
        if "$SCRIPTS/verify.sh" --no-smoke >/dev/null 2>&1; then vcolor="verify GREEN"; else vcolor="verify RED"; fi
        "$SCRIPTS/task.sh" block "$id" "loop.sh: still in-progress after $resume resume attempt(s); $vcolor${fail_reason:+ — last failure: $fail_reason}"
        status=blocked
      fi
    fi
    # A clean session (rc=0) that ended in-progress with no committed work did
    # nothing to resume or merge — block for a human rather than spin on it.
    if [ "$status" = "in-progress" ] && [ "$rc" -eq 0 ]; then
      "$SCRIPTS/task.sh" block "$id" "loop.sh: session ended in-progress with no committed work"
      status=blocked
    fi
    break
  done
  total_cost=$(python3 -c "print(round($total_cost + $task_cost, 2))")
  total_in=$((total_in + task_in)); total_out=$((total_out + task_out))
  unset INTENTPIPE_TIMING_ID
  # Env failure with no work done: claude errored before anything was committed —
  # status still todo (never started), or in-progress on a zero-commit branch (a
  # drop right after task.sh start). No network, a stranded tree, a crash. Not the
  # task's fault: retry the SAME task up to MAX_RETRIES WITHOUT spending the task
  # budget (n). Abandon a zero-commit in-progress branch first so the retry starts
  # clean and its repo is un-stranded. A standing condition (MAX_RETRIES straight
  # fails) hard-stops with the captured reason; the task is left todo.
  if [ "$rc" -ne 0 ] && { [ "$status" = "todo" ] || [ -z "$status" ] \
       || { [ "$status" = "in-progress" ] && ! branch_has_commits "$id"; }; }; then
    if [ "$status" = "in-progress" ]; then "$SCRIPTS/task.sh" abandon "$id" >/dev/null 2>&1 || true; fi
    retries=$((retries + 1))
    if [ "$retries" -ge "$MAX_RETRIES" ]; then
      echo "── $id failed $retries× before doing any work — giving up (task left todo)"
      "$SCRIPTS/notify.sh" "loop.sh hard-stop: $id failed $retries× with no work — ${fail_reason:-see loop-fail.log}" || true
      break
    fi
    echo "── $id errored before any work ($retries/$MAX_RETRIES) — ${fail_reason:-see loop-fail.log}; retrying in ${RETRY_BACKOFF}s"
    sleep "$RETRY_BACKOFF"
    continue
  fi
  retries=0   # a task that reached a real state clears the transient-failure streak
  # …and so does the usage-limit budget: the cap exists to stop polling a limit
  # that is NOT clearing, so a task finishing after one proves it did clear. Only
  # consecutive waits with no progress between them count toward the cap.
  limit_retries=0
  n=$((n + 1))
  # Tokens ride with every cost figure: on a subscription the dollar number is an
  # estimate, the token count is what was actually spent.
  toks="$(fmt_k $((task_in + task_out))) tok"
  toks_detail="$toks ($(fmt_k "$task_in") in / $(fmt_k "$task_out") out)"
  timing=$(timing_summary "$id")
  total_secs=$((total_secs + $(timing_total "$id")))
  set_field "$dir/task.md" Timing "${timing:--}"
  if [ -n "$SUBSCRIPTION" ]; then
    set_field "$dir/task.md" Cost "subscription (~\$$task_cost API-equiv, $toks)"
    echo "── task $id → $status ($n/$MAX_TASKS; subscription; ~\$$task_cost API-equiv; $toks_detail)"
  else
    set_field "$dir/task.md" Cost "\$$task_cost ($toks)"
    echo "── task $id → $status ($n/$MAX_TASKS; \$$task_cost; $toks_detail)"
  fi
  [ -z "$timing" ] || echo "   timing: $timing"
  if [ -z "$SUBSCRIPTION" ] && python3 -c "exit(0 if $total_cost >= $MAX_COST_USD else 1)"; then
    "$SCRIPTS/notify.sh" "loop.sh stopped: cost cap \$$MAX_COST_USD reached"
    break
  fi
done
finish_notify
