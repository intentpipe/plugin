#!/usr/bin/env bash
# Shared helpers. Source, don't execute.
set -euo pipefail

# Walk up from cwd to find the workspace (dir containing agents.env — either
# directly or in an intentpipe/ child, so it's found from the project root and repos).
find_workspace() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    [ -f "$dir/agents.env" ] && { echo "$dir"; return 0; }
    [ -f "$dir/intentpipe/agents.env" ] && { echo "$dir/intentpipe"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: no agents.env found between $PWD and /" >&2
  return 1
}

WS="$(find_workspace)"
# shellcheck disable=SC1091
source "$WS/agents.env"
: "${DEFAULT_BRANCH:=main}"
# Declared, never sniffed from an origin remote: a solo project may push for
# backup, and guessing would silently change merge semantics.
: "${DONE:=local}"   # local = squash-merge | pr = push branch + GitHub PR
: "${REPOS:?agents.env must set REPOS}"
TASKS="$WS/tasks"

repo_path() { # repo_path <name> -> absolute path
  local var="REPO_$1"
  local rel="${!var:?agents.env must set REPO_$1}"
  echo "$WS/$rel"
}

verify_cmd() { # verify_cmd <name> -> command string
  local var="VERIFY_$1"
  echo "${!var:?agents.env must set VERIFY_$1}"
}

smoke_cmd() { # smoke_cmd <name> -> command string, empty when the repo defines none
  # Optional (`:-`), unlike verify_cmd's `:?`: most repos have nothing to boot.
  # Declared, never auto-detected: the plugin cannot know which service is the
  # app or which endpoint proves readiness, and a wrong guess either hangs the
  # gate or greenlights a dying app.
  local var="SMOKE_$1"
  echo "${!var:-}"
}

task_dir() { # task_dir <id> -> path (fails if missing)
  local d
  d=$(ls -d "$TASKS/$1-"*/ 2>/dev/null | head -1) || true
  [ -n "${d:-}" ] || { echo "ERROR: no task $1" >&2; return 1; }
  echo "${d%/}"
}

get_field() { # get_field <task.md> <Field>
  grep -m1 "^$2:" "$1" | sed "s/^$2:[[:space:]]*//"
}

set_field() { # set_field <task.md> <Field> <value>
  # A field the file doesn't have yet is APPENDED to the header block (the run of
  # `Name: value` lines under the title) rather than silently dropped — so a field
  # added to the template later still lands on tasks created before it.
  if grep -q "^$2:" "$1"; then
    FIELD="$2" VALUE="$3" perl -pi -e 's/^$ENV{FIELD}:.*/$ENV{FIELD}: $ENV{VALUE}/' "$1"
  else
    FIELD="$2" VALUE="$3" perl -pi -e '
      if (!$done && /^\s*$/ && $prev =~ /^[A-Za-z][\w -]*:/) { print "$ENV{FIELD}: $ENV{VALUE}\n"; $done = 1 }
      $prev = $_;' "$1"
    grep -q "^$2:" "$1" || printf '%s: %s\n' "$2" "$3" >> "$1"
  fi
}

task_title() { head -1 "$1" | sed 's/^# [0-9]* · //'; }

is_out_of_credits() { # rc 0 if <output> is a credit/billing exhaustion, not a
  # timer-based limit. Anthropic's canonical message is "Your credit balance is
  # too low to access the Anthropic API. … upgrade or purchase credits." These
  # do NOT reset on a schedule (unlike limit_wait), so retrying is pointless.
  echo "$1" | grep -qiE 'credit balance (is )?too low|purchase credits|insufficient (credit|funds)|out of (usage )?credits?'
}

is_transient_api_error() { # rc 0 if <output> looks like a transient, self-clearing
  # API/network drop worth an immediate retry — distinct from a usage limit (waits
  # for a reset), out-of-credits (human must act), or a genuine task failure. Keep
  # the pattern tight: prefer claude's JSON `result` field over raw stderr so a task
  # whose own output mentions "internal server error" isn't misread as a drop.
  echo "$1" | grep -qiE 'connection closed mid-response|connection reset|connection error|econnreset|etimedout|socket hang up|network( error|.*unreachable)|error 5[0-9][0-9]|overloaded_error|internal server error|service unavailable'
}

limit_wait() { # limit_wait <claude output> -> seconds to wait, or rc 1 if not a usage/rate limit
  echo "$1" | grep -qiE 'usage limit|rate.?limit|(hour|weekly|session) limit' || return 1
  local reset now
  reset=$(echo "$1" | grep -oE '\|[0-9]{10}' | head -1 | tr -d '|' || true)
  now=$(date +%s)
  if [ -n "$reset" ] && [ "$reset" -gt "$now" ] && [ $((reset - now)) -lt $((8 * 86400)) ]; then
    echo $((reset - now + 60))   # buffer past the advertised reset
  else
    echo "${LIMIT_BACKOFF:-1800}"
  fi
}

task_base() { # task_base <task.md> -> branch this task integrates into: its
  # feature branch (DONE=pr + Feature set) or DEFAULT_BRANCH
  local f
  f=$(get_field "$1" Feature) || f=""
  if [ "$DONE" = "pr" ] && [ -n "$f" ] && [ "$f" != "-" ]; then
    echo "feature/$f"
  else
    echo "$DEFAULT_BRANCH"
  fi
}

park_wip() { # park_wip <id> <msg>: commit leftover WIP on the task branch so
  # preflight passes on a retry (task.sh done squashes it away). No-op if clean.
  local id="$1" msg="$2" dir branch repo path
  dir=$(task_dir "$id"); branch=$(get_field "$dir/task.md" Branch)
  for repo in $(get_field "$dir/task.md" Repos); do
    path=$(repo_path "$repo")
    [ "$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ] || continue
    git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
      || { git -C "$path" add -A; git -C "$path" commit -qm "$msg"; }
  done
}

after_done() { # after_done <branch>: fire the optional AFTER_DONE hook for work
  # that just landed on <branch> (the PR branch, the feature branch it integrates
  # into, or DEFAULT_BRANCH under DONE=local).
  #
  # Declared per workspace in agents.env, never auto-detected (#17/#33): what a
  # project does when a task lands — refresh a preview onto the branch, deploy,
  # ping a webhook — is not something the plugin can know or should. The seam is
  # the same shape as notify.sh: a command the workspace names, run DETACHED and
  # tolerantly. Detached because a real hook takes minutes (a preview rebuild is
  # docker + a release web build) and the loop must move on to the next task;
  # tolerant because a hook is a side channel — its failure is not the task's.
  local branch="${1:-}" log
  [ -n "${AFTER_DONE:-}" ] || return 0
  if [ -n "${INTENTPIPE_LOOP:-}" ]; then
    # Inside a headless loop the NEXT task starts the moment this one lands, so a
    # hook firing now would run against a tree that is about to move (and rebuild
    # once per task for a state nobody looks at). Record the branch; loop.sh fires
    # the last one when the run is over — one hook per run, on a settled tree.
    { printf '%s\n' "$branch" > "$TASKS/_after-done.pending"; } 2>/dev/null || true
    echo "[after-done] $branch → deferred to the end of the loop run"
    return 0
  fi
  log="$TASKS/_after-done.log"
  # A hook's output is diagnostic, not a record: keep the last few runs, not
  # every run since the workspace was born (it was 230 KB on quorum, committed
  # and re-diffed by every state landing).
  if [ -f "$log" ] && [ "$(wc -l < "$log")" -gt 400 ]; then
    { tail -n 200 "$log" > "$log.tmp" && mv "$log.tmp" "$log"; } 2>/dev/null || true
  fi
  { printf '\n=== %s · %s\n' "$(date -u +%FT%TZ)" "$branch"; } >> "$log" 2>/dev/null || true
  # $1 inside the -c string, so a branch name is an argument and never re-parsed
  # as shell by the hook command. INTENTPIPE_WORKSPACE/INTENTPIPE_BRANCH are for the hook that
  # needs them *inside* its command string (single-quote it in agents.env, which
  # is sourced long before the hook runs) — e.g. a preview refresh, which is
  # per-project and must be told which project.
  INTENTPIPE_WORKSPACE="$WS" INTENTPIPE_BRANCH="$branch" \
    nohup bash -c "$AFTER_DONE \"\$1\"" after_done "$branch" >> "$log" 2>&1 &
  disown 2>/dev/null || true
  echo "[after-done] $branch → $AFTER_DONE (detached; log: $log)"
  return 0
}

branch_has_commits() { # rc 0 if any affected repo's task branch is ahead of its base
  local id="$1" dir branch base repo path
  dir=$(task_dir "$id"); branch=$(get_field "$dir/task.md" Branch)
  base=$(task_base "$dir/task.md")
  for repo in $(get_field "$dir/task.md" Repos); do
    path=$(repo_path "$repo")
    git -C "$path" rev-parse -q --verify "$branch" >/dev/null || continue
    [ -n "$(git -C "$path" log --oneline "$base..$branch" 2>/dev/null)" ] && return 0
  done
  return 1
}

# ── step timing ─────────────────────────────────────────────────────────────
# Every deterministic step (preflight, verify, smoke) records its own wall time
# into the task's timings.tsv — "<step>\t<seconds>", one row per run. loop.sh
# adds the LLM time it measures directly (session wall clock minus whatever the
# scripts recorded meanwhile), so the rows never overlap and a plain sum is the
# task's real total. That is what makes a per-step breakdown deterministic: no
# LLM has to cooperate, and a step that runs twice (verify in the build, again in
# task.sh done) is simply counted twice — which is the truth.
#
# The target task is INTENTPIPE_TIMING_ID when set (loop.sh exports it around the
# session, so nested scripts land in the right file even as Status changes),
# else the first in-progress task — the scaffold runs one at a time, so that is
# the one a hand-run build is working on — else a scratch file nobody reads.
timing_file() {
  local id="${INTENTPIPE_TIMING_ID:-}" d
  if [ -z "$id" ]; then
    for d in "$TASKS"/[0-9]*/; do
      [ -f "$d/task.md" ] || continue
      [ "$(get_field "$d/task.md" Status)" = "in-progress" ] || continue
      id=$(basename "$d" | cut -d- -f1); break
    done
  fi
  [ -n "$id" ] && d=$(task_dir "$id" 2>/dev/null) && { echo "$d/timings.tsv"; return; }
  echo "$TASKS/_timings.tsv"
}

timing_record() { # timing_record <step> <seconds> — never fails its caller
  local f
  f=$(timing_file 2>/dev/null) || return 0
  # Check the dir first: a failed `>>` redirection prints its own error, which
  # `|| true` can't suppress — and a workspace with no tasks/ dir is legitimate.
  [ -d "$(dirname "$f")" ] || return 0
  { printf '%s\t%s\n' "$1" "$2" >> "$f"; } 2>/dev/null || true
  return 0
}

timing_total() { # timing_total [id] -> seconds recorded so far (0 when none)
  local f
  f=$(INTENTPIPE_TIMING_ID="${1:-${INTENTPIPE_TIMING_ID:-}}" timing_file 2>/dev/null) || { echo 0; return; }
  [ -f "$f" ] || { echo 0; return; }
  awk -F'\t' '{s += $2} END {print s + 0}' "$f"
}

fmt_dur() { # fmt_dur <seconds> -> 45s | 3m10s | 1h4m
  local s="${1:-0}"
  if   [ "$s" -lt 60 ];   then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m$((s % 60))s"
  else echo "$((s / 3600))h$((s % 3600 / 60))m"; fi
}

fmt_k() { # fmt_k <tokens> -> "1840k", rounded to the nearest thousand
  local n="${1:-0}"
  echo "$(( (n + 500) / 1000 ))k"
}

timing_summary() { # timing_summary <id> -> "total 18m2s · llm 14m2s · verify 3m10s …"
  # Rows are grouped on the part before ':' (verify:core + verify:app_mobile →
  # one `verify`), reported in pipeline order with anything unknown appended.
  local f d id="$1"
  d=$(task_dir "$id" 2>/dev/null) || return 0
  f="$d/timings.tsv"
  [ -f "$f" ] || return 0
  local out="" step secs
  out="total $(fmt_dur "$(awk -F'\t' '{s += $2} END {print s + 0}' "$f")")"
  while IFS=$'\t' read -r step secs; do
    out="$out · $step $(fmt_dur "$secs")"
  done < <(awk -F'\t' '
    { split($1, a, ":"); k = a[1]; sum[k] += $2; if (!(k in seen)) { seen[k]; order[++n] = k } }
    END {
      split("preflight llm verify smoke", pipeline, " ")
      for (i = 1; i <= 4; i++) if (pipeline[i] in sum) { print pipeline[i] "\t" sum[pipeline[i]]; done[pipeline[i]] }
      for (i = 1; i <= n; i++) if (!(order[i] in done)) print order[i] "\t" sum[order[i]]
    }' "$f")
  echo "$out"
}

branch_head() { # branch_head <id> -> "repo:sha …" tips of the task branch (- if absent),
  # a cheap fingerprint for detecting whether a resume session committed anything.
  local id="$1" dir branch repo path sha out=""
  dir=$(task_dir "$id"); branch=$(get_field "$dir/task.md" Branch)
  for repo in $(get_field "$dir/task.md" Repos); do
    path=$(repo_path "$repo")
    sha=$(git -C "$path" rev-parse -q --verify "$branch" 2>/dev/null) || sha="-"
    out="$out $repo:$sha"
  done
  echo "${out# }"
}
