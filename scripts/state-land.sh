#!/usr/bin/env bash
# Land committed workspace state: push it on a branch, open a PR, and — when
# every changed path is routine pipeline state — merge that PR immediately.
# State records (task history, notes, retro reports, agent memory) document
# work that already happened; parking them for a human tap adds nothing and
# unlanded piles rot into merge conflicts. Anything else in the diff (code,
# agents.env, specs/, session docs) demotes the PR to human-merge.
#
# Tolerant by design, same seam contract as notify.sh: state landing is a side
# channel — its failure must never fail the flow that called it. Every early
# return is exit 0 with a printed reason; only a push/merge that goes wrong
# escalates via notify.sh so the pile-up is visible instead of silent. The one
# non-zero exit is a merge that did not actually reach the base branch: a false
# "landed" is worse than a noisy failure, since nobody goes looking for it.
#
# Usage: state-land.sh   (run from anywhere below the project root)
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS/lib.sh"

say() { echo "[state-land] $*"; }

root=$(git -C "$WS" rev-parse --show-toplevel 2>/dev/null) \
  || { say "workspace is not in a git repo — nothing to land"; exit 0; }
git -C "$root" remote get-url origin >/dev/null 2>&1 \
  || { say "no origin — local-only workspace, nothing to land"; exit 0; }
# "intentpipe/" when state lives in a child dir of the scaffold repo, "" flat
prefix=$(git -C "$WS" rev-parse --show-prefix)

# Crash leftovers: stage and commit any pending edits in the state paths, so a
# session that died between snapshot_ws calls still lands complete records.
for p in "${prefix}tasks" "${prefix}updates" "${prefix}resources" \
         "${prefix}retro" "${prefix}NEEDS_HUMAN.md" ".claude/agent-memory"; do
  [ -e "$root/$p" ] && git -C "$root" add -- "$p"
done
git -C "$root" diff --cached --quiet \
  || git -C "$root" commit -qm "state: sync workspace records"

# The scaffold's own default branch (NOT agents.env DEFAULT_BRANCH — that is
# the code repos' base and the two can differ).
base=$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's|^origin/||') \
  || base=$(git -C "$root" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
[ -n "$base" ] || { say "cannot determine the scaffold default branch"; exit 0; }
git -C "$root" fetch -q origin "$base" \
  || { say "fetch failed — offline? leaving state committed locally"; exit 0; }

branch=$(git -C "$root" rev-parse --abbrev-ref HEAD)
ahead=$(git -C "$root" rev-list --count "origin/$base..HEAD")
[ "$ahead" -gt 0 ] || { say "nothing ahead of origin/$base"; exit 0; }

# Workspace state lands by PR whatever the code repos' DONE mode is (and under
# DONE=pr the guard forbids the direct push outright), so commits sitting on the
# default branch locally get their own state/ branch; a flow branch is pushed as itself —
# unless its PR is already merged. Reusing a landed branch pushes onto a branch
# nobody will merge again, and the PR lookup below then reports that merged PR
# as success while the new commits sit stranded off "$base". A fresh branch is
# cut at HEAD, so those stranded commits ride along instead of being abandoned.
land=""
if [ "$branch" != "$base" ]; then
  land="$branch"
  st=$(cd "$root" && gh pr view "$branch" --json state --jq .state 2>/dev/null) || st=""
  case "$st" in
    MERGED|CLOSED)
      say "PR for $branch is $st — cutting a fresh branch for the $ahead stranded commit(s)"
      land="" ;;
  esac
fi
if [ -z "$land" ]; then
  land="state/$(date -u +%Y%m%d-%H%M%S)"
  git -C "$root" branch "$land"
fi
git -C "$root" push -qu origin "$land" \
  || { "$SCRIPTS/notify.sh" "state-land: push of $land failed in $(basename "$root") — state is stranded locally"; exit 0; }

command -v gh >/dev/null 2>&1 \
  || { say "gh not available — $land pushed, PR/merge is manual"; exit 0; }

# Auto-merge is earned by the diff, not assumed: every changed path must be
# routine pipeline state. One foreign path → the PR waits for the human.
state_only=1
while IFS= read -r f; do
  case "$f" in
    "${prefix}tasks/"*|"${prefix}updates/"*|"${prefix}resources/"*|\
    "${prefix}retro/"*|"${prefix}NEEDS_HUMAN.md"|".claude/agent-memory/"*) ;;
    *) state_only=0; say "non-state path in diff: $f" ;;
  esac
done < <(git -C "$root" diff --name-only "origin/$base...$land")

# reuse an existing PR (rerun after an interrupted session), else create
url=$(cd "$root" && gh pr view "$land" --json url --jq .url 2>/dev/null) \
  || url=$(cd "$root" && gh pr create --head "$land" --base "$base" \
             --title "state: $ahead workspace record commit(s)" \
             --body "Routine pipeline state (task records, notes, retro reports, agent memory) landed by state-land.sh. Auto-merged when the diff is state-only.") \
  || { "$SCRIPTS/notify.sh" "state-land: $land pushed but PR creation failed in $(basename "$root")"; exit 0; }

if [ "$state_only" -ne 1 ]; then
  say "PR left for the human (non-state paths above): $url"
  exit 0
fi

if (cd "$root" && gh pr merge "$land" --merge >/dev/null 2>&1); then
  # "merged" is gh's claim about a PR, not proof that these commits reached
  # "$base" — check before saying so, or stranded state stays silent again.
  git -C "$root" fetch -q origin "$base" \
    || { say "merged $url but could not re-fetch to verify — check origin/$base"; exit 0; }
  left=$(git -C "$root" rev-list --count "origin/$base..HEAD")
  [ "$left" -eq 0 ] || {
    "$SCRIPTS/notify.sh" "state-land: $url reports merged but $left commit(s) are still off origin/$base in $(basename "$root") — state is stranded"
    exit 1
  }
  say "state landed and merged: $url"
  [ "$branch" = "$base" ] \
    && git -C "$root" pull -q --ff-only origin "$base" 2>/dev/null || true
  if [ "$land" != "$branch" ]; then  # a branch we cut, not the flow's own
    git -C "$root" branch -qD "$land" 2>/dev/null || true
    git -C "$root" push -q origin --delete "$land" 2>/dev/null || true
  fi
else
  "$SCRIPTS/notify.sh" "state-land: could not auto-merge $url (conflict with $base?) — needs a look"
fi
exit 0
