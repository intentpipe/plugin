#!/usr/bin/env bash
# Validate the workspace before any agent runs. Fail loud, fail early.
# Config is verified, not assumed: agents.env names repos generically (REPOS=…),
# so any topology works, and nothing runs until it checks out.
# Usage: preflight.sh [--quick]   (--quick skips the verify run)
# Exit 3 (DONE=pr): origin/DEFAULT_BRANCH itself is red — an environment
# condition to wait out (loop.sh retries), not a workspace failure.
set -euo pipefail
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPTS/lib.sh"

# Time the checks-and-sync phase for the task breakdown. The trap covers the
# early exits (a failed check still cost time); it is cleared before the verify
# run below, which records itself — so the two never double-count.
_pf_t0=$(date +%s)
trap 'timing_record preflight "$(( $(date +%s) - _pf_t0 ))"' EXIT

err=0
if [ "$DONE" = "pr" ]; then
  gh auth status >/dev/null 2>&1 || { echo "FAIL: DONE=pr needs an authenticated gh CLI" >&2; err=1; }
fi
for repo in $REPOS; do
  path="$(repo_path "$repo")" || { err=1; continue; }
  [ -d "$path" ] || { echo "FAIL: $repo path missing: $path" >&2; err=1; continue; }
  [ "$(cd "$path" && pwd)" != "$WS" ] || { echo "FAIL: $repo must be a subdirectory, not the workspace root" >&2; err=1; continue; }
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: $repo is not a git repo" >&2; err=1; continue; }
  git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
    || { echo "FAIL: $repo has uncommitted changes" >&2; err=1; }
  git -C "$path" rev-parse -q --verify "$DEFAULT_BRANCH" >/dev/null \
    || { echo "FAIL: $repo has no branch $DEFAULT_BRANCH" >&2; err=1; }
  if [ "$DONE" = "pr" ]; then
    # Base freshening happens at plan kickoff (freshen.sh) so a build
    # run never advances the default branch mid-flight — no repo is yanked onto a
    # moved base while a PR is open. Preflight only validates origin and fetches
    # the ref the upstream-red check (below) and task.sh sync compare against.
    git -C "$path" remote get-url origin >/dev/null 2>&1 \
      || { echo "FAIL: $repo has no origin remote (required by DONE=pr)" >&2; err=1; continue; }
    git -C "$path" fetch -q origin "$DEFAULT_BRANCH" \
      || { echo "FAIL: $repo: fetch origin/$DEFAULT_BRANCH failed" >&2; err=1; continue; }
  fi
  verify_cmd "$repo" >/dev/null || err=1
done
[ -d "$TASKS" ] || { echo "FAIL: no tasks/ dir (run /intentpipe:init-project)" >&2; err=1; }
# The agents' `memory: project` store resolves from the session's cwd. A store
# anywhere but the project root means some launcher ran from the wrong directory
# — the lessons written there are invisible to every other launcher
# (proposals/2026-07-29-agent-memory-forks-by-cwd.md). Hard-fail until merged.
strays=("$TASKS/.claude/agent-memory" "$TASKS"/*/.claude/agent-memory)
[ "$(basename "$WS")" != "intentpipe" ] || strays+=("$WS/.claude/agent-memory")
for stray in "${strays[@]}"; do
  [ ! -d "$stray" ] || { echo "FAIL: agent memory forked into $stray — merge its files into the project root's .claude/agent-memory and delete it" >&2; err=1; }
done
[ "$err" -eq 0 ] || { echo "PREFLIGHT FAILED" >&2; exit 1; }

# DONE=pr: complete tasks whose PRs merged since the last run
[ "$DONE" != "pr" ] || "$SCRIPTS/task.sh" sync

timing_record preflight "$(( $(date +%s) - _pf_t0 ))"; trap - EXIT

if [ "${1:-}" != "--quick" ] && ! "$SCRIPTS/verify.sh"; then
  if [ "$DONE" = "pr" ]; then
    # every repo exactly at origin/DEFAULT_BRANCH → the breakage is upstream
    red_upstream=1
    for repo in $REPOS; do
      path="$(repo_path "$repo")"
      [ "$(git -C "$path" rev-parse HEAD)" = "$(git -C "$path" rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null)" ] \
        || red_upstream=0
    done
    [ "$red_upstream" -eq 0 ] || { echo "UPSTREAM RED: origin/$DEFAULT_BRANCH fails verify" >&2; exit 3; }
  fi
  exit 1
fi
echo "PREFLIGHT OK"
