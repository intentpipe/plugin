#!/usr/bin/env bash
# Task lifecycle. Deterministic — no LLM involved.
# Usage: task.sh new "<title>" [repos] [feature] | start <id> | next | status | diagnose | nits | done <id> | sync | block <id> "<reason>" | reopen <id> | abandon <id> | clean-repo <repo> | resolve <id> "<decision>"
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { grep '^# Usage' "$0" | cut -c3-; exit 1; }

snapshot_ws() { # commit workspace state (update-note/task history for /retro)
  git -C "$WS" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local p
  for p in tasks updates resources NEEDS_HUMAN.md; do [ -e "$WS/$p" ] && git -C "$WS" add "$p"; done
  git -C "$WS" diff --cached --quiet || git -C "$WS" commit -qm "$1" \
    || echo "WARN: workspace snapshot commit failed" >&2
}

cmd_new() {
  local title="${1:?usage: task.sh new \"<title>\" [repos] [feature]}"
  local repos="${2:-$REPOS}"
  local feature="${3:-}"
  local last id slug dir intent fmd fstatus
  last=$(ls "$TASKS" 2>/dev/null | grep -E '^[0-9]{4}-' | sort | tail -1 | cut -d- -f1 || true)
  id=$(printf '%04d' $((10#${last:-0} + 1)))
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)
  intent=$(git -C "$WS" log -1 --format=%h -- updates 2>/dev/null) || intent=""
  if [ -n "$feature" ]; then
    feature=$(echo "$feature" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)
    fmd="$TASKS/_features/$feature.md"
    if [ -f "$fmd" ]; then
      # A feature accepts new tasks while open or its PR is still open (amendment
      # lands on the same branch → same PR); a merged/closed PR ends the window.
      fstatus=$(get_field "$fmd" Status)
      case "$fstatus" in done|blocked)
        echo "ERROR: feature $feature is $fstatus — its PR is closed to amendments; plan a new feature" >&2; exit 1 ;;
      esac
      set_field "$fmd" Tasks "$(get_field "$fmd" Tasks) $id"
    else
      mkdir -p "$TASKS/_features"
      printf '# feature · %s\n\nStatus: open\nBranch: feature/%s\nTasks: %s\nPR: -\n' \
        "$feature" "$feature" "$id" > "$fmd"
    fi
  fi
  dir="$TASKS/$id-$slug"
  mkdir -p "$dir"
  cat > "$dir/task.md" <<EOF
# $id · $title

Status: todo
Repos: $repos
Branch: task/$id-$slug
Feature: ${feature:--}
Intent: ${intent:--}
Commits: -
PR: -
Rounds: 0
Cost: -
Timing: -
Decision: -
Resources: -
Model: -
Effort: -

## Goal

## Change map

## Acceptance criteria

- [ ]

## Non-goals

## Notes
EOF
  echo "$id"
}

cmd_start() {
  local id="${1:?task id}" dir md branch base repo path status
  dir=$(task_dir "$id"); md="$dir/task.md"
  status=$(get_field "$md" Status)
  [ "$status" = "todo" ] || [ "$status" = "in-progress" ] \
    || { echo "ERROR: task $id is $status, not startable" >&2; exit 1; }
  branch=$(get_field "$md" Branch); base=$(task_base "$md")
  for repo in $(get_field "$md" Repos); do
    path=$(repo_path "$repo")
    if git -C "$path" rev-parse -q --verify "$branch" >/dev/null; then
      git -C "$path" checkout -q "$branch"   # resume an interrupted task
    else
      git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
        || { echo "ERROR: $repo has uncommitted changes" >&2; exit 1; }
      git -C "$path" rev-parse -q --verify "$base" >/dev/null \
        || { git -C "$path" checkout -q "$DEFAULT_BRANCH"
             git -C "$path" checkout -qb "$base"; }   # first task of the feature
      git -C "$path" checkout -q "$base"
      git -C "$path" checkout -qb "$branch"
    fi
  done
  set_field "$md" Status in-progress
  echo "started $id on $branch"
}

cmd_next() {
  # Scan in id order and return the first actionable task — todo, or in-progress.
  # Returning in-progress (an orphan from a killed session; task.sh start resumes
  # its branch) does double duty: it self-heals a cold-start orphan AND gates the
  # orphan's dependents, since a prerequisite counts as satisfied only once it is
  # done/pr — an unfinished one sorts first and holds the queue. A blocked task
  # gates the same way but needs a human, so stop and signal (exit 3) rather than
  # hand it back. Todos *before* a block still run; CONTINUE_ON_BLOCK=1 skips past
  # it for independent task sets.
  local d s
  for d in "$TASKS"/[0-9]*/; do
    [ -f "$d/task.md" ] || continue
    s=$(get_field "$d/task.md" Status)
    if [ "$s" = "blocked" ] && [ "${CONTINUE_ON_BLOCK:-}" != "1" ]; then
      echo "next: blocked task $(basename "$d" | cut -d- -f1) gates the queue" >&2
      return 3
    fi
    { [ "$s" = "in-progress" ] || [ "$s" = "todo" ]; } && { basename "$d" | cut -d- -f1; return 0; }
  done
  return 1
}

cmd_nits() { # every [nit] from a done task's review, newest task first. The
  # disposal channel for DESIGN #5: nits are never re-looped inside a build, so
  # /plan is the only place they get triaged into work or dropped on purpose.
  local d md id
  for d in $(ls -dr "$TASKS"/[0-9]*/ 2>/dev/null); do
    md="$d/task.md"; [ -f "$md" ] || continue
    [ "$(get_field "$md" Status)" = "done" ] || continue
    [ -f "$d/review.md" ] || continue
    id=$(basename "$d" | cut -d- -f1)
    grep -h '\[nit\]' "$d/review.md" | sed "s|^|$id |" || true
  done
}

cmd_status() {
  local d md
  printf '%-6s %-12s %s\n' ID STATUS TITLE
  for d in "$TASKS"/[0-9]*/; do
    md="$d/task.md"; [ -f "$md" ] || continue
    printf '%-6s %-12s %s\n' "$(basename "$d" | cut -d- -f1)" "$(get_field "$md" Status)" "$(task_title "$md")"
  done
}

human_reason() { # last reason block under "## <header>" in NEEDS_HUMAN.md, or -
  local header="$1" f="$WS/NEEDS_HUMAN.md"
  [ -f "$f" ] || { echo "-"; return; }
  awk -v h="## $header" '
    $0==h { buf=""; grab=1; next }
    /^## / { grab=0 }
    grab { buf=(buf=="" ? $0 : buf " " $0) }
    END { print (buf=="" ? "-" : buf) }
  ' "$f"
}

cmd_diagnose() {
  # Read-only. Enumerate everything that needs attention and the facts the
  # unblock skill judges on: one global verify color (the current checkout), then
  # each blocked/in-progress task and each blocked feature with its recovery
  # signals — has-commits, review verdict, whether a loop-fail.log exists, and the
  # NEEDS_HUMAN reason. Deterministic data-gathering; the judgment is the skill's.
  local vcolor d md id status fmd found=0 review repo path branch
  # --no-smoke: diagnose is documented read-only, and a smoke command starts things.
  if "$(dirname "${BASH_SOURCE[0]}")/verify.sh" --no-smoke >/dev/null 2>&1; then vcolor=GREEN; else vcolor=RED; fi
  echo "verify: $vcolor"
  for d in "$TASKS"/[0-9]*/; do
    md="$d/task.md"; [ -f "$md" ] || continue
    status=$(get_field "$md" Status)
    case "$status" in blocked|in-progress) ;; *) continue ;; esac
    found=1; id=$(basename "$d" | cut -d- -f1)
    review=none
    [ ! -f "$d/review.md" ] || review=$(grep '^VERDICT:' "$d/review.md" | tail -1 | sed 's/^VERDICT:[[:space:]]*//' || echo none)
    printf 'task %s %s commits=%s review=%s faillog=%s\n' "$id" "$status" \
      "$(branch_has_commits "$id" && echo yes || echo no)" \
      "${review:-none}" \
      "$([ -f "$d/loop-fail.log" ] && echo yes || echo no)"
    echo "  reason: $(human_reason "$(basename "$d")")"
  done
  for fmd in "$TASKS"/_features/*.md; do
    [ -f "$fmd" ] || continue
    [ "$(get_field "$fmd" Status)" = "blocked" ] || continue
    found=1
    printf 'feature %s blocked\n' "$(basename "$fmd" .md)"
    echo "  reason: $(human_reason "feature $(basename "$fmd" .md)")"
  done
  # Workspace cleanliness — independent of task status. A build session that died
  # after editing files but before committing (or once its task was reset to todo)
  # leaves a dirty tree that preflight hard-fails on, while NO task is
  # blocked/in-progress — so the loop above sees nothing and unblock used to find
  # nothing to do. Surface it as its own signal; clean-repo (below) resolves it.
  for repo in $REPOS; do
    path="$(repo_path "$repo")" || continue
    [ -d "$path" ] || continue
    if ! { git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
           && [ -z "$(git -C "$path" ls-files --others --exclude-standard)" ]; }; then
      found=1; branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
      printf 'workspace %s dirty on %s\n' "$repo" "${branch:-?}"
    fi
  done
  [ "$found" = 1 ] || echo "(nothing blocked or in-progress)"
}

cmd_clean_repo() { # Recoverably clear a repo's dirty working tree so preflight
  # passes again. Safe by construction: `git stash push -u` never discards — the
  # snapshot is recoverable with `git -C <path> stash list/pop`. The scaffold only
  # ever lands work as commits on task branches, so a dirty tree is always a
  # crashed session's leftover; stashing (not resetting) keeps it if it mattered.
  local repo="${1:?usage: task.sh clean-repo <repo>}" path
  path=$(repo_path "$repo")
  if git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
     && [ -z "$(git -C "$path" ls-files --others --exclude-standard)" ]; then
    echo "clean-repo: $repo already clean"; return 0
  fi
  # A crashed docker run writes root-owned build artifacts through the bind
  # mount; the stash below then dies on EPERM, and agents have improvised
  # unbounded `sudo rm -rf` inside the checkout. Reclaim OWNERSHIP instead —
  # bounded to this repo and destroys nothing; the stash still decides what
  # leaves the tree.
  local foreign owner
  owner=$(id -un)
  foreign=$(find "$path" ! -user "$owner" 2>/dev/null | head -200) || true
  if [ -n "$foreign" ]; then
    echo "clean-repo: $repo has $(echo "$foreign" | wc -l) path(s) not owned by $owner (container leftovers), e.g.:"
    echo "$foreign" | head -5 | sed 's/^/  /'
    if sudo -n chown -R "$owner" -- "$path" 2>/dev/null; then
      echo "clean-repo: ownership reclaimed (sudo chown -R $owner)"
    else
      echo "clean-repo: cannot reclaim ownership (no passwordless sudo); fix it via a container instead:" >&2
      echo "  docker run --rm -v \"$path\":/w busybox chown -R $(id -u):$(id -g) /w" >&2
      return 1
    fi
  fi
  git -C "$path" stash push -u -m "unblock clean-repo $(date -u +%FT%TZ)" >/dev/null
  echo "clean-repo: $repo stashed (recover: git -C $path stash list)"
}

feature_md() { echo "$TASKS/_features/$1.md"; }

feature_complete() { # rc 0 if every member task of feature <slug> is done
  local tid
  for tid in $(get_field "$(feature_md "$1")" Tasks); do
    [ "$(get_field "$(task_dir "$tid")/task.md" Status)" = "done" ] || return 1
  done
  return 0
}

# GitHub rejects a createPullRequest whose body exceeds 65536 characters. A
# feature that aggregates many task contracts blows past that, and the failure
# lands after the branch is already pushed — so degrade the body instead.
PR_BODY_MAX=64000

feature_body() { # <slug> <1|0 include reviews> → aggregated PR body on stdout
  local slug="$1" reviews="$2" tid d
  for tid in $(get_field "$(feature_md "$slug")" Tasks); do
    d=$(task_dir "$tid")
    printf '## %s\n\n' "$(head -1 "$d/task.md" | sed 's/^# //')"
    awk '/^## Goal/,0' "$d/task.md"
    [ "$reviews" != 1 ] || [ ! -f "$d/review.md" ] \
      || printf '\n### Agent review\n\n%s\n' "$(cat "$d/review.md")"
    printf '\nTask-Id: %s\n\n' "$tid"
  done
}

ship_feature() { # all member tasks landed → push feature/<slug>, open one PR
  # per repo with the aggregated task contracts + reviews; sync completes it.
  local slug="$1" fmd branch tid d repo path repos="" url urls="" body cut
  fmd=$(feature_md "$slug"); branch="feature/$slug"
  body=$(mktemp)
  # Contracts first, reviews only if they fit: the contract is what a human
  # merging the PR must read; the reviews are on the branch either way.
  feature_body "$slug" 1 > "$body"
  if [ "$(wc -c < "$body")" -gt "$PR_BODY_MAX" ]; then
    { feature_body "$slug" 0
      printf '\n---\n\n_Per-task agent reviews omitted to fit the PR body limit — they are in `intentpipe/tasks/<id>/review.md` on this branch._\n'
    } > "$body"
  fi
  if [ "$(wc -c < "$body")" -gt "$PR_BODY_MAX" ]; then   # contracts alone still over
    cut=$(mktemp)
    head -c "$((PR_BODY_MAX - 300))" "$body" > "$cut"
    printf '\n\n---\n\n_Truncated to fit the PR body limit — the full task contracts are in `intentpipe/tasks/` on this branch._\n' >> "$cut"
    mv "$cut" "$body"
  fi
  for tid in $(get_field "$fmd" Tasks); do
    d=$(task_dir "$tid")
    for repo in $(get_field "$d/task.md" Repos); do
      case " $repos " in *" $repo "*) ;; *) repos="$repos $repo" ;; esac
    done
  done
  for repo in $repos; do
    path=$(repo_path "$repo")
    [ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$branch" ] \
      || git -C "$path" checkout -q "$DEFAULT_BRANCH"
    if [ -n "$(git -C "$path" log --oneline "$DEFAULT_BRANCH..$branch" 2>/dev/null)" ]; then
      git -C "$path" push -qu origin "$branch"
      # reuse an existing PR (rerun after an interrupted session), else create
      url=$(cd "$path" && gh pr view "$branch" --json url --jq .url 2>/dev/null) \
        || url=$(cd "$path" && gh pr create --head "$branch" --base "$DEFAULT_BRANCH" --title "$slug" --body-file "$body")
      urls="$urls $repo:$url"
    else
      git -C "$path" branch -qD "$branch" 2>/dev/null || true   # no changes in this repo
    fi
  done
  rm -f "$body"
  if [ -z "$urls" ]; then
    set_field "$fmd" Status done
    echo "- feature $slug · no changes" >> "$TASKS/_log.md"
    echo "feature $slug → no changes"
  else
    set_field "$fmd" Status pr
    set_field "$fmd" PR "${urls# }"
    echo "feature $slug →$urls"
  fi
}

cmd_done() {
  local id="${1:?task id}" dir md branch target feature title repo path shas sha url urls body
  dir=$(task_dir "$id"); md="$dir/task.md"
  [ "$(get_field "$md" Status)" = "in-progress" ] || { echo "ERROR: task $id is not in-progress" >&2; exit 1; }
  # The gate: the task's repos verify in full (tests + smoke boot); every other
  # repo runs tests-only. A cross-repo break must not land green, but re-booting
  # a service the task never touched serves nobody — SMOKE's --force-recreate
  # restarts the preview a human may be reviewing on. Word lists, unquoted.
  local task_repos other_repos r
  task_repos=$(get_field "$md" Repos); other_repos=""
  for r in $REPOS; do
    case " $task_repos " in *" $r "*) ;; *) other_repos="$other_repos $r" ;; esac
  done
  # shellcheck disable=SC2086
  "$(dirname "${BASH_SOURCE[0]}")/verify.sh" $task_repos \
    || { echo "ERROR: verify failed — not merging" >&2; exit 1; }
  # shellcheck disable=SC2086
  [ -z "${other_repos// /}" ] || "$(dirname "${BASH_SOURCE[0]}")/verify.sh" --no-smoke $other_repos \
    || { echo "ERROR: verify failed — not merging" >&2; exit 1; }
  branch=$(get_field "$md" Branch); title=$(task_title "$md"); shas=""
  feature=$(get_field "$md" Feature) || feature="-"
  target=$(task_base "$md")
  for repo in $(get_field "$md" Repos); do
    path=$(repo_path "$repo")
    git -C "$path" diff --quiet && git -C "$path" diff --cached --quiet \
      || { echo "ERROR: $repo has uncommitted changes on $branch" >&2; exit 1; }
  done
  if [ "$DONE" = "pr" ] && [ "$target" = "$DEFAULT_BRANCH" ]; then
    # Push the branch and open a pre-reviewed PR; the platform merges (its
    # squash policy keeps one commit per feature). task.sh sync completes the
    # task once the PR is merged by a human.
    urls=""; body=$(mktemp)
    { awk '/^## Goal/,0' "$md"
      [ ! -f "$dir/review.md" ] || printf '\n## Agent review\n\n%s\n' "$(cat "$dir/review.md")"
      printf '\nTask-Id: %s\n' "$id"
    } > "$body"
    for repo in $(get_field "$md" Repos); do
      path=$(repo_path "$repo")
      if [ -n "$(git -C "$path" log --oneline "$DEFAULT_BRANCH..$branch" 2>/dev/null)" ]; then
        git -C "$path" push -qu origin "$branch"
        # reuse an existing PR (rerun after an interrupted session), else create
        url=$(cd "$path" && gh pr view "$branch" --json url --jq .url 2>/dev/null) \
          || url=$(cd "$path" && gh pr create --head "$branch" --base "$DEFAULT_BRANCH" --title "$title" --body-file "$body")
        urls="$urls $repo:$url"
        git -C "$path" checkout -q "$DEFAULT_BRANCH"
      else
        git -C "$path" checkout -q "$DEFAULT_BRANCH"
        git -C "$path" branch -qD "$branch"   # no changes in this repo
      fi
    done
    rm -f "$body"
    if [ -z "$urls" ]; then
      set_field "$md" Status done
      echo "- $id · $title · no changes" >> "$TASKS/_log.md"
      snapshot_ws "task $id done: $title"
      echo "done $id → no changes"
    else
      set_field "$md" Status pr
      set_field "$md" PR "${urls# }"
      snapshot_ws "task $id pr: $title"
      echo "pr $id →$urls"
      # The work now lives on the PR branch, but every repo has been put BACK on
      # DEFAULT_BRANCH above — so anything serving this project (a preview stack)
      # is showing the mainline, not what was just built. AFTER_DONE is where a
      # workspace says what to do about that; it gets the branch that carries it.
      after_done "$branch"
    fi
    return
  fi
  # Squash-merge into $target: DEFAULT_BRANCH (DONE=local), or the feature
  # integration branch (DONE=pr + Feature) — one commit per task either way.
  for repo in $(get_field "$md" Repos); do
    path=$(repo_path "$repo")
    git -C "$path" checkout -q "$target"
    if ! git -C "$path" merge --squash -q "$branch" >/dev/null; then
      git -C "$path" reset -q --hard "$target"
      git -C "$path" checkout -q "$branch"
      echo "ERROR: squash-merge conflict in $repo — resolve on $branch, then rerun done" >&2
      exit 1
    fi
    if git -C "$path" diff --cached --quiet; then
      git -C "$path" reset -q --hard "$target"   # no changes in this repo
    else
      git -C "$path" commit -qm "$title" -m "Task-Id: $id"
      sha=$(git -C "$path" rev-parse --short HEAD)
      shas="$shas $repo:$sha"
    fi
    git -C "$path" branch -qD "$branch"
  done
  set_field "$md" Status done
  set_field "$md" Commits "${shas# }"
  echo "- $id · $title ·${shas:- no changes}" >> "$TASKS/_log.md"
  # Push what just landed. Under DONE=local the merge above is the whole terminal
  # state, so a task that never publishes leaves origin silently stale; doing it
  # per task (not per loop run) means a run killed mid-flight — usage limit,
  # crash — still leaves origin current for the tasks that did land. publish.sh
  # is tolerant and no-ops under DONE=pr, so a failed push never fails a green task.
  # shellcheck disable=SC2086
  [ -z "$shas" ] || "$(dirname "${BASH_SOURCE[0]}")/publish.sh" $(get_field "$md" Repos) || true
  if [ "$target" != "$DEFAULT_BRANCH" ] && feature_complete "$feature"; then
    ship_feature "$feature"   # last member task landed → open the feature PR
  fi
  snapshot_ws "task $id done: $title"
  echo "done $id →${shas:- no changes}"
  # $target, not $branch: the task branch is squashed away and deleted by now —
  # the commit lives on the feature branch (DONE=pr) or DEFAULT_BRANCH (local).
  # Only when something actually landed: a no-change task moved nothing to follow.
  [ -z "$shas" ] || after_done "$target"
}

cmd_sync() {
  # DONE=pr: reconcile pr-status tasks against GitHub. Merged → done (+digest,
  # local branch cleanup), closed unmerged → blocked, open → leave as-is.
  [ "$DONE" = "pr" ] || { echo "sync: nothing to do (DONE=$DONE)"; return 0; }
  local d md id title branch entry repo url out state sha shas open path fmd slug tid tstatus
  for d in "$TASKS"/[0-9]*/; do
    md="$d/task.md"; [ -f "$md" ] || continue
    [ "$(get_field "$md" Status)" = "pr" ] || continue
    id=$(basename "$d" | cut -d- -f1); shas=""; open=""
    for entry in $(get_field "$md" PR); do
      repo="${entry%%:*}"; url="${entry#*:}"
      out=$(gh pr view "$url" --json state,mergeCommit --jq '.state + " " + (.mergeCommit.oid // "")') \
        || { echo "WARN: cannot check $url — skipping $id" >&2; open=1; break; }
      state="${out%% *}"; sha="${out#* }"
      case "$state" in
        MERGED) shas="$shas $repo:${sha:0:7}" ;;
        CLOSED) cmd_block "$id" "PR closed without merge: $url" >/dev/null; continue 2 ;;
        *)      open=1 ;;
      esac
    done
    [ -z "$open" ] || continue
    title=$(task_title "$md"); branch=$(get_field "$md" Branch)
    for repo in $(get_field "$md" Repos); do
      path=$(repo_path "$repo")
      git -C "$path" rev-parse -q --verify "$branch" >/dev/null || continue
      [ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$branch" ] || git -C "$path" checkout -q "$DEFAULT_BRANCH"
      git -C "$path" branch -qD "$branch"
    done
    set_field "$md" Status done
    set_field "$md" Commits "${shas# }"
    echo "- $id · $title ·$shas" >> "$TASKS/_log.md"
    snapshot_ws "task $id merged: $title"
    echo "synced $id → done (${shas# })"
  done
  # Feature PRs reconcile the same way. Member tasks are done — except an
  # amendment the merge raced past (planned while the PR was open, unfinished
  # at merge): its integration branch is gone, so it is blocked for a replan.
  for fmd in "$TASKS"/_features/*.md; do
    [ -f "$fmd" ] || continue
    [ "$(get_field "$fmd" Status)" = "pr" ] || continue
    slug=$(basename "$fmd" .md); branch="feature/$slug"; shas=""; open=""
    for entry in $(get_field "$fmd" PR); do
      repo="${entry%%:*}"; url="${entry#*:}"
      out=$(gh pr view "$url" --json state,mergeCommit --jq '.state + " " + (.mergeCommit.oid // "")') \
        || { echo "WARN: cannot check $url — skipping feature $slug" >&2; open=1; break; }
      state="${out%% *}"; sha="${out#* }"
      case "$state" in
        MERGED) shas="$shas $repo:${sha:0:7}" ;;
        CLOSED) set_field "$fmd" Status blocked
                { echo "## feature $slug"; echo "PR closed without merge: $url"; echo; } >> "$WS/NEEDS_HUMAN.md"
                "$(dirname "${BASH_SOURCE[0]}")/notify.sh" "Feature $slug blocked: PR closed without merge" || true
                echo "blocked feature $slug"
                continue 2 ;;
        *)      open=1 ;;
      esac
    done
    [ -z "$open" ] || continue
    for entry in $(get_field "$fmd" PR); do
      path=$(repo_path "${entry%%:*}")
      git -C "$path" rev-parse -q --verify "$branch" >/dev/null || continue
      [ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$branch" ] || git -C "$path" checkout -q "$DEFAULT_BRANCH"
      git -C "$path" branch -qD "$branch"
    done
    set_field "$fmd" Status done
    for tid in $(get_field "$fmd" Tasks); do
      tstatus=$(get_field "$(task_dir "$tid")/task.md" Status)
      case "$tstatus" in todo|in-progress)
        cmd_block "$tid" "feature $slug PR merged before this task landed — replan against the fresh base" >/dev/null ;;
      esac
    done
    echo "- feature $slug · merged ·$shas" >> "$TASKS/_log.md"
    snapshot_ws "feature $slug merged"
    echo "synced feature $slug → done (${shas# })"
  done
}

cmd_block() {
  local id="${1:?task id}" reason="${2:?reason}" dir md
  dir=$(task_dir "$id"); md="$dir/task.md"
  set_field "$md" Status blocked
  { echo "## $(basename "$dir")"; echo "$reason"; echo; } >> "$WS/NEEDS_HUMAN.md"
  "$(dirname "${BASH_SOURCE[0]}")/notify.sh" "Task $id blocked: $reason" || true
  echo "blocked $id"
}

cmd_resolve() { # fold a human's decision into a gated task and return it to the queue.
  # A task the planner marked `Decision: <question>` was asked on Telegram and
  # blocked (loop.sh); this records the human's answer where the builder will read
  # it, clears the gate, and resets to todo so the next build implements it.
  local id="${1:?task id}" answer="${2:?decision text}" dir md
  dir=$(task_dir "$id"); md="$dir/task.md"
  set_field "$md" Decision -
  printf '\n## Decision (resolved)\n\n%s\n' "$answer" >> "$md"
  set_field "$md" Status todo
  snapshot_ws "task $id decision recorded: $answer"
  "$(dirname "${BASH_SOURCE[0]}")/notify.sh" "Task $id decision recorded: $answer — back in the queue" || true
  echo "resolved $id"
}

cmd_reopen() {
  local id="${1:?task id}" dir md
  dir=$(task_dir "$id"); md="$dir/task.md"
  # A branch with commits is resumable work — reopen to in-progress and let
  # task.sh start check it out. A branch with no commits (or none at all) is an
  # empty orphan: abandon it (restore repos, delete branch) so it restarts clean
  # instead of resuming an empty branch — the manual recovery this used to need.
  if branch_has_commits "$id"; then
    set_field "$md" Status in-progress; echo "reopened $id (branch has commits — resume)"; return
  fi
  cmd_abandon "$id"
}

cmd_abandon() { # discard an empty/unwanted task branch and reset to todo. Safe:
  # git branch -d refuses a branch with unmerged commits, so committed work is
  # never silently thrown away — merge it with task.sh done, or -D it by hand.
  local id="${1:?task id}" dir md branch base repo path
  dir=$(task_dir "$id"); md="$dir/task.md"
  branch=$(get_field "$md" Branch); base=$(task_base "$md")
  for repo in $(get_field "$md" Repos); do
    path=$(repo_path "$repo")
    git -C "$path" rev-parse -q --verify "$branch" >/dev/null || continue
    [ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$branch" ] \
      || git -C "$path" checkout -q "$base" 2>/dev/null \
      || git -C "$path" checkout -q "$DEFAULT_BRANCH"   # un-strand the repo
    git -C "$path" branch -qd "$branch" 2>/dev/null \
      || { echo "ERROR: $repo branch $branch has unmerged commits — task.sh done to merge, or delete by hand" >&2; exit 1; }
  done
  set_field "$md" Status todo
  echo "abandoned $id → todo"
}

case "${1:-}" in
  new|start|next|status|diagnose|nits|done|sync|block|reopen|abandon|clean-repo|resolve) c="${1//-/_}"; shift; "cmd_$c" "$@" ;;
  *) usage ;;
esac
