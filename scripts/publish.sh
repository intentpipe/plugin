#!/usr/bin/env bash
# Publish the merged default branch: push DEFAULT_BRANCH to origin for the named
# repos (all REPOS when none are named). Under DONE=local the squash-merge in
# task.sh done IS the terminal state, so without this a green task never leaves
# the box — bibbles ran three tasks deep (0133-0135) with origin/main stale
# behind local main, discovered only because a human went looking. Publishing is
# the second half of a local merge, not a separate ceremony.
#
# Tolerant by design, same seam contract as notify.sh and state-land.sh: this
# must never fail the task that already merged green. Every skip prints a reason
# and exits 0; a push that actually FAILS (offline, or origin moved) escalates
# via notify.sh so the backlog is visible instead of silent, and still exits 0 —
# the commits are safe on the local default branch either way.
#
# Never force, never merge: a rejected push means origin moved under us, and
# reconciling someone else's history is a human's call, not a script's.
#
# DONE=pr workspaces are skipped outright — there the platform is the merge
# arbiter and hand-pushing the default branch bypasses review.
#
# Usage: publish.sh [repo...]   (run from anywhere below the project root)
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS/lib.sh"

say() { echo "[publish] $*"; }

[ "$DONE" = "local" ] || { say "DONE=$DONE — the platform merges; nothing to publish"; exit 0; }

failed=""
for repo in ${*:-$REPOS}; do
  path=$(repo_path "$repo") || { failed="$failed $repo"; continue; }
  git -C "$path" remote get-url origin >/dev/null 2>&1 \
    || { say "$repo: no origin — local-only repo, nothing to publish"; continue; }
  git -C "$path" rev-parse -q --verify "$DEFAULT_BRANCH" >/dev/null \
    || { say "$repo: no $DEFAULT_BRANCH branch"; continue; }
  # Fetch so "ahead" is measured against what origin holds NOW, not a stale
  # tracking ref. A failed fetch is not fatal: push below reports the truth.
  git -C "$path" fetch -q origin "$DEFAULT_BRANCH" 2>/dev/null \
    || say "$repo: fetch failed — pushing anyway, the push settles it"
  if git -C "$path" rev-parse -q --verify "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null; then
    ahead=$(git -C "$path" rev-list --count "origin/$DEFAULT_BRANCH..$DEFAULT_BRANCH")
    [ "$ahead" -gt 0 ] || { say "$repo: nothing ahead of origin/$DEFAULT_BRANCH"; continue; }
  else
    ahead="all"   # never published — first push creates the branch upstream
  fi
  if git -C "$path" push -q origin "$DEFAULT_BRANCH:$DEFAULT_BRANCH" 2>/dev/null; then
    say "$repo: pushed $ahead commit(s) to origin/$DEFAULT_BRANCH"
  else
    say "$repo: push failed — offline, or origin/$DEFAULT_BRANCH moved; reconcile by hand"
    failed="$failed $repo"
  fi
done

[ -z "$failed" ] || "$SCRIPTS/notify.sh" \
  "publish.sh: could not push$failed to origin/$DEFAULT_BRANCH — merged locally, unpublished" || true
exit 0
