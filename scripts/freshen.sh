#!/usr/bin/env bash
# Freshen the base at plan kickoff (DONE=pr): fetch origin/DEFAULT_BRANCH and
# move every clean repo onto it, so tasks planned this run branch from current
# upstream. Base advances here, once, not per-build — so a build run never
# yanks a repo onto a moved default branch while a PR is open (a stable base
# beats an always-latest one; the cost, a later feature not seeing an earlier
# same-run PR, is the stacked-PR limit /build already stops on). A resumed
# task branch gone stale against the moved base is NOT rebased here —
# mechanical salvage is the wrong tool; replan it through /plan. A repo with uncommitted changes is reported and left as-is, never
# clobbered; a dangling task branch is left intact (git checkout, not delete).
# No-op under DONE=local (no upstream to freshen). Never fails its caller:
# planning proceeds; preflight still validates before any build.
set -euo pipefail
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1091
source "$SCRIPTS/lib.sh"

[ "$DONE" = "pr" ] || { echo "freshen: nothing to do (DONE=$DONE)"; exit 0; }

warn=0
for repo in $REPOS; do
  path="$(repo_path "$repo")" || { warn=1; continue; }
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "SKIP: $repo is not a git repo" >&2; warn=1; continue; }
  git -C "$path" remote get-url origin >/dev/null 2>&1 \
    || { echo "SKIP: $repo has no origin remote" >&2; warn=1; continue; }
  git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
    || { echo "SKIP: $repo has uncommitted changes — left as-is" >&2; warn=1; continue; }
  git -C "$path" fetch -q origin "$DEFAULT_BRANCH" \
    || { echo "SKIP: $repo: fetch origin/$DEFAULT_BRANCH failed" >&2; warn=1; continue; }
  git -C "$path" checkout -q "$DEFAULT_BRANCH" \
    || { echo "SKIP: $repo: cannot checkout $DEFAULT_BRANCH" >&2; warn=1; continue; }
  git -C "$path" merge -q --ff-only "origin/$DEFAULT_BRANCH" \
    || { echo "WARN: $repo: $DEFAULT_BRANCH diverged from origin — reconcile manually" >&2; warn=1; continue; }
  echo "$repo → on $DEFAULT_BRANCH at origin"
done
[ "$warn" -eq 0 ] || echo "freshen: completed with warnings (see above)" >&2
exit 0
