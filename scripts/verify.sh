#!/usr/bin/env bash
# Deterministic quality gate. Runs each repo's verify command from agents.env,
# then — if the repo defines one — its smoke command (SMOKE_<repo>): the app
# actually starts and answers. Unit tests can't see a startup path (a migration
# that fails on existing data, a bad env var, an import error at boot), so a
# repo that ships a runnable app should define one.
# Hierarchy of trust: compiler/tests >> fresh-context reviewer >> LLM-as-judge
# (never built as a gate — the weakest verifier class). The implementer may not
# weaken a test to get green, and the reviewer checks for it.
# Usage: verify.sh [--no-smoke] [repo ...]   (default: all repos, smoke on)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

smoke=1
[ "${1:-}" != "--no-smoke" ] || { smoke=0; shift; }

run_reaped() { # run_reaped <cmd ...> -> the command's exit code
  # Test runners fork workers that outlive them — every `flutter test` left a
  # flutter_tester behind, and they piled up across days until a 4G box hit a
  # 6.2G memory / 1.8G swap peak, slowing every later build. `set -m` puts the
  # run in its own process group (pgid = $!, guaranteed by bash — no setsid, no
  # racy `ps` lookup), so once it returns the survivors are addressable as a
  # group and get reaped. A failing TERM means nothing survived: the good case.
  local pid rc=0
  set -m; "$@" & pid=$!; set +m
  trap 'kill -TERM -- "-$pid" 2>/dev/null; exit 130' INT TERM   # Ctrl-C now stops
  wait "$pid" || rc=$?                                          # at us; pass it on
  trap - INT TERM
  if kill -TERM -- "-$pid" 2>/dev/null; then
    sleep 2                                    # grace, then insist
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  return "$rc"
}

# Test runners are chatty, and on a green run none of that transcript is
# evidence the PASS line doesn't already carry. It isn't free: the implementer
# runs verify after every meaningful change (agents/implementer.md rule 4), the
# output lands in its context, and every later turn re-pays it.
# So a piped caller gets one summary line on green and the tail on red — the
# full log stays on disk, named, for when the tail isn't enough. A human at a
# terminal still watches it all scroll, which is why they ran it by hand.
LOG_LINES="${VERIFY_LOG_LINES:-60}"

run_step() { # run_step <label> <cmd ...> -> the command's exit code
  local label="$1"; shift
  local rc=0 log
  if [ -t 1 ]; then
    run_reaped "$@" || rc=$?
    return "$rc"
  fi
  log=$(mktemp "${TMPDIR:-/tmp}/verify-XXXXXX.log")
  run_reaped "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    # The runner's own last word ("538 passed", "All tests passed!") — the line
    # the implementer cites as evidence, and nothing else.
    { tail -n 5 "$log" | grep -vE '^[[:space:]]*$' | tail -n 1; } || true
    rm -f "$log"
  else
    echo "── $label: last $LOG_LINES lines (full log: $log)" >&2
    tail -n "$LOG_LINES" "$log" >&2
  fi
  return "$rc"
}

failed=""
[ $# -gt 0 ] || set -- $REPOS
for repo in "$@"; do
  echo "── verify: $repo"
  # Each run is timed into the task's timings.tsv (see lib.sh) — a red run too,
  # since a failed test suite still spent the time.
  t0=$(date +%s); rc=0
  (cd "$(repo_path "$repo")" && run_step "verify:$repo" bash -c "$(verify_cmd "$repo")") || rc=$?
  timing_record "verify:$repo" "$(( $(date +%s) - t0 ))"
  if [ "$rc" -ne 0 ]; then
    echo "── FAIL: $repo" >&2
    failed="$failed $repo"
    continue    # a repo that fails its own tests has nothing to smoke
  fi
  cmd="$(smoke_cmd "$repo")"
  if [ "$smoke" -eq 0 ] || [ -z "$cmd" ]; then
    echo "── PASS: $repo"
    continue
  fi
  echo "── smoke: $repo"
  # `bash -c` (not eval) so `timeout` owns the process: a smoke command that
  # hangs — a container that never turns healthy, a curl with no deadline —
  # would otherwise wedge the whole loop. rc 124 = the timeout fired.
  t0=$(date +%s); rc=0
  (cd "$(repo_path "$repo")" && run_step "smoke:$repo" timeout "${SMOKE_TIMEOUT:-300}" bash -c "$cmd") || rc=$?
  timing_record "smoke:$repo" "$(( $(date +%s) - t0 ))"
  if [ "$rc" -eq 0 ]; then
    echo "── PASS: $repo"
  else
    [ "$rc" -ne 124 ] || echo "── smoke timed out after ${SMOKE_TIMEOUT:-300}s" >&2
    echo "── FAIL: $repo (smoke)" >&2
    failed="$failed $repo"
  fi
done
[ -z "$failed" ] || { echo "VERIFY FAILED:$failed" >&2; exit 1; }
echo "VERIFY GREEN"
