#!/usr/bin/env bash
# End-to-end smoke test: builds a scratch workspace, runs the full task
# lifecycle, and checks the guard hook. Run from anywhere; no side effects.
set -euo pipefail
INTENTPIPE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
# Seal the whole run from any real ~/.agent-orchestrator/telegram.env: task.sh
# fires notify.sh during the lifecycle, and a live creds file would send real
# messages. The dedicated notify section below sets its own creds inline.
export TELEGRAM_ENV=/nonexistent

# --- project root with one fake repo, state in intentpipe/ (default layout)
WS="$TMP/ws"; mkdir -p "$WS/app" "$WS/intentpipe/tasks"
git -C "$WS" init -qb main && git -C "$WS" config user.email t@t && git -C "$WS" config user.name t
git -C "$WS/app" init -qb main
git -C "$WS/app" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
cat > "$WS/intentpipe/agents.env" <<'EOF'
PROJECT_NAME=smoke
DEFAULT_BRANCH=main
REPOS="app"
REPO_app=../app
VERIFY_app="test -f ok.txt"
EOF
echo ok > "$WS/app/ok.txt"
git -C "$WS/app" add . && git -C "$WS/app" -c user.email=t@t -c user.name=t commit -qm "add ok"
cd "$WS"

# --- preflight
"$INTENTPIPE/scripts/preflight.sh" >/dev/null || fail "preflight should pass"
# a forked agent-memory store (a launcher ran from the wrong cwd) must hard-fail:
# lessons written there are invisible to every other launcher
mkdir -p intentpipe/tasks/.claude/agent-memory
out=$("$INTENTPIPE/scripts/preflight.sh" --quick 2>&1 || true)
echo "$out" | grep -q "agent memory forked" || fail "preflight must flag a forked memory store under tasks/"
rm -rf intentpipe/tasks/.claude
mkdir -p intentpipe/.claude/agent-memory
out=$("$INTENTPIPE/scripts/preflight.sh" --quick 2>&1 || true)
echo "$out" | grep -q "agent memory forked" || fail "preflight must flag a workspace-level memory store"
rm -rf intentpipe/.claude
mkdir -p .claude/agent-memory   # the PROJECT-ROOT store is the legitimate one
"$INTENTPIPE/scripts/preflight.sh" --quick >/dev/null || fail "preflight must accept the project-root store"
fout=$("$INTENTPIPE/scripts/freshen.sh"); [[ "$fout" == *"nothing to do"* ]] || fail "freshen must no-op under DONE=local"

# --- new / next / start
id=$("$INTENTPIPE/scripts/task.sh" new "Add greeting feature")
[ "$id" = "0001" ] || fail "expected id 0001, got $id"
[ "$("$INTENTPIPE/scripts/task.sh" next)" = "0001" ] || fail "next should return 0001"
"$INTENTPIPE/scripts/task.sh" start "$id" >/dev/null
git -C app rev-parse --abbrev-ref HEAD | grep -q "task/0001" || fail "not on task branch"
[ "$("$INTENTPIPE/scripts/task.sh" next)" = "0001" ] || fail "next should return the in-progress task to resume it"

# --- implement something on the branch
echo "hello" > app/greeting.txt
git -C app add . && git -C app -c user.email=t@t -c user.name=t commit -qm "wip greeting"

# --- done: squash-merge, trailer, log
"$INTENTPIPE/scripts/task.sh" done "$id" >/dev/null
[ "$(git -C app rev-parse --abbrev-ref HEAD)" = "main" ] || fail "should be back on main"
git -C app log -1 --format=%B | grep -q "Task-Id: 0001" || fail "missing Task-Id trailer"
git -C app log --oneline | wc -l | grep -q 3 || fail "expected exactly 3 commits (squash)"
grep -q "Status: done" intentpipe/tasks/0001-*/task.md || fail "status not done"
grep -q "app:" intentpipe/tasks/0001-*/task.md || fail "commit sha not recorded"
grep -q "^Intent:" intentpipe/tasks/0001-*/task.md || fail "no Intent field"
grep -q "0001" intentpipe/tasks/_log.md || fail "no log line"
git -C "$WS" log --oneline | grep -q "task 0001 done" || fail "no workspace snapshot commit"
git -C app rev-parse -q --verify task/0001-add-greeting-feature >/dev/null && fail "branch not deleted" || true

# --- block / reopen / NEEDS_HUMAN
id2=$("$INTENTPIPE/scripts/task.sh" new "Second thing")
"$INTENTPIPE/scripts/task.sh" block "$id2" "unclear spec" >/dev/null
grep -q "unclear spec" intentpipe/NEEDS_HUMAN.md || fail "no NEEDS_HUMAN entry"

# --- diagnose: read-only report the unblock skill judges on — global verify
# color, plus each blocked/in-progress item with its facts and NEEDS_HUMAN reason.
# id2 is blocked with no commits; verify is GREEN (ok.txt present); id1 is done.
diag=$("$INTENTPIPE/scripts/task.sh" diagnose)
echo "$diag" | grep -q "^verify: GREEN" || fail "diagnose: missing/ wrong verify color"
echo "$diag" | grep -q "^task 0002 blocked commits=no review=none faillog=no" || fail "diagnose: blocked task facts wrong"
echo "$diag" | grep -q "reason: unclear spec" || fail "diagnose: NEEDS_HUMAN reason not surfaced"
echo "$diag" | grep -q "0001" && fail "diagnose: must not list a done task" || true

# --- clean-repo + diagnose workspace scan: a dirty tree with NO blocked/
# in-progress task is invisible to the task loop yet preflight hard-fails on it.
# diagnose must surface it; clean-repo must recoverably clear it (stash, not lose).
echo "stray edit" >> app/ok.txt   # dirty a tracked file with no task involved
diag=$("$INTENTPIPE/scripts/task.sh" diagnose)
echo "$diag" | grep -q "^workspace app dirty on" || fail "diagnose: dirty workspace not surfaced"
"$INTENTPIPE/scripts/preflight.sh" --quick >/dev/null 2>&1 && fail "preflight should fail on a dirty tree" || true
"$INTENTPIPE/scripts/task.sh" clean-repo app | grep -q stashed || fail "clean-repo should stash a dirty tree"
{ git -C app diff --quiet && git -C app diff --cached --quiet; } || fail "clean-repo left the tree dirty"
git -C app stash list | grep -q "unblock clean-repo" || fail "clean-repo did not leave a recoverable stash"
"$INTENTPIPE/scripts/task.sh" clean-repo app | grep -q "already clean" || fail "clean-repo on clean tree should no-op"
git -C app stash drop >/dev/null 2>&1   # tidy the scratch repo

# --- clean-repo with root-owned container leftovers: reclaim ownership (bounded
# chown, destroys nothing) then stash — never leave agents to `sudo rm -rf`.
# Stub `id -un` to claim another owner so every path reads as foreign, and stub
# `sudo` to observe the chown without needing root.
STUB="$(mktemp -d)"
printf '#!/bin/bash\nif [ "$1" = "-un" ]; then echo nobody; else /usr/bin/id "$@"; fi\n' > "$STUB/id"
printf '#!/bin/bash\necho "sudo $*" >> "%s/sudo.log"\nexit 0\n' "$STUB" > "$STUB/sudo"
chmod +x "$STUB/id" "$STUB/sudo"
echo "stray edit" >> app/ok.txt
out=$(PATH="$STUB:$PATH" "$INTENTPIPE/scripts/task.sh" clean-repo app) || fail "clean-repo should succeed when chown works"
echo "$out" | grep -q "not owned by nobody" || fail "clean-repo should report foreign-owned paths"
echo "$out" | grep -q "ownership reclaimed" || fail "clean-repo should reclaim ownership before stashing"
grep -q "chown -R nobody" "$STUB/sudo.log" || fail "clean-repo should chown, not delete"
echo "$out" | grep -q "stashed" || fail "clean-repo should still stash after the chown"
git -C app stash drop >/dev/null 2>&1
# no passwordless sudo → fail loudly with the container fallback, don't half-stash
printf '#!/bin/bash\nexit 1\n' > "$STUB/sudo"; chmod +x "$STUB/sudo"
echo "stray edit" >> app/ok.txt
PATH="$STUB:$PATH" "$INTENTPIPE/scripts/task.sh" clean-repo app 2>"$STUB/err" && fail "clean-repo must fail when it cannot reclaim ownership" || true
grep -q "docker run" "$STUB/err" || fail "clean-repo failure should print the container fallback"
git -C app checkout -- ok.txt   # tidy for the tests below
rm -rf "$STUB"

"$INTENTPIPE/scripts/task.sh" next >/dev/null && fail "blocked task must not be next" || true
"$INTENTPIPE/scripts/task.sh" reopen "$id2" >/dev/null
[ "$("$INTENTPIPE/scripts/task.sh" next)" = "0002" ] || fail "reopened task should be next"

# --- successor-gating: a blocked task halts next (exit 3) so its dependents
# don't run; CONTINUE_ON_BLOCK=1 skips the block to the later todo
"$INTENTPIPE/scripts/task.sh" block "$id2" "gate test" >/dev/null
id_after=$("$INTENTPIPE/scripts/task.sh" new "After the block")
rc=0; "$INTENTPIPE/scripts/task.sh" next >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "next must halt (exit 3) on a blocked predecessor, got $rc"
[ "$(CONTINUE_ON_BLOCK=1 "$INTENTPIPE/scripts/task.sh" next)" = "$id_after" ] \
  || fail "CONTINUE_ON_BLOCK=1 should skip the block to the next todo"
"$INTENTPIPE/scripts/task.sh" reopen "$id2" >/dev/null   # restore for later tests

# --- smoke gate: SMOKE_<repo> boot check (optional, gated, skippable)
V="$INTENTPIPE/scripts/verify.sh"
"$V" >/dev/null || fail "smoke: a repo with no SMOKE_app must verify exactly as before"
SMOKE_app="touch smoked.txt" "$V" >/dev/null || fail "smoke: a passing smoke command must stay green"
[ -f app/smoked.txt ] || fail "smoke: command must run inside the repo dir"
rm -f app/smoked.txt
SMOKE_app="exit 3" "$V" >/dev/null 2>&1 && fail "smoke: a failing smoke command must fail verify" || true
out=$(SMOKE_app="exit 3" "$V" 2>&1 || true)
echo "$out" | grep -q "FAIL: app (smoke)" || fail "smoke: failure must name the repo and the phase"
SMOKE_app="exit 3" "$V" --no-smoke >/dev/null || fail "smoke: --no-smoke must skip the smoke command"
out=$(SMOKE_TIMEOUT=1 SMOKE_app="sleep 5" "$V" 2>&1 || true)
echo "$out" | grep -q "timed out" || fail "smoke: SMOKE_TIMEOUT must fire and say so"
mv app/ok.txt app/ok.hidden   # red verify: smoke must not run at all
SMOKE_app="touch smoked.txt" "$V" >/dev/null 2>&1 && fail "smoke: red verify must still fail" || true
[ ! -f app/smoked.txt ] || fail "smoke: must not run when the repo's verify failed"
mv app/ok.hidden app/ok.txt

# --- red verify blocks done
"$INTENTPIPE/scripts/task.sh" start "$id2" >/dev/null
"$INTENTPIPE/scripts/task.sh" start "$id2" >/dev/null || fail "start must resume an in-progress task"
git -C app rev-parse --abbrev-ref HEAD | grep -q "task/0002" || fail "resume not on task branch"
rm app/ok.txt && git -C app add -A && git -C app -c user.email=t@t -c user.name=t commit -qm "break verify"
"$INTENTPIPE/scripts/task.sh" done "$id2" >/dev/null 2>&1 && fail "done must refuse red verify" || true

# --- limit_wait: parses reset epoch, falls back to LIMIT_BACKOFF, ignores other errors
w=$(bash -c "source '$INTENTPIPE/scripts/lib.sh'; limit_wait 'Claude AI usage limit reached|$(( $(date +%s) + 600 ))'")
{ [ "$w" -ge 600 ] && [ "$w" -le 700 ]; } || fail "limit_wait epoch parse gave $w"
w=$(bash -c "source '$INTENTPIPE/scripts/lib.sh'; LIMIT_BACKOFF=42 limit_wait '5-hour limit reached'")
[ "$w" = 42 ] || fail "limit_wait fallback gave $w"
bash -c "source '$INTENTPIPE/scripts/lib.sh'; limit_wait 'ordinary task failure'" >/dev/null \
  && fail "limit_wait matched non-limit output" || true

# --- loop.sh merge enforcement: a session that ends in-progress with committed,
# review-approved work must be finishable. branch_has_commits detects the work;
# with an approving review.md the deterministic path runs task.sh done (no model).
id3=$("$INTENTPIPE/scripts/task.sh" new "Third thing")
"$INTENTPIPE/scripts/task.sh" start "$id3" >/dev/null
d3=$(echo intentpipe/tasks/"$id3"-*/)   # resolve the task dir once (review.md doesn't exist yet)
lib() { bash -c "source '$INTENTPIPE/scripts/lib.sh'; $1"; }
lib "branch_has_commits $id3" && fail "branch_has_commits: true before any commit" || true
echo "world" > app/third.txt
git -C app add . && git -C app -c user.email=t@t -c user.name=t commit -qm "wip third"
lib "branch_has_commits $id3" || fail "branch_has_commits: false after commit"
# park_wip commits leftover WIP so a retry's preflight stays green; no-op when clean.
# "uncommitted" = tracked modifications (what preflight checks), so dirty a tracked file.
echo "dirty" >> app/third.txt
lib "park_wip $id3 'wip: parked'" || fail "park_wip failed"
{ git -C app diff --quiet && git -C app diff --cached --quiet; } || fail "park_wip left tree dirty"
git -C app log -1 --format=%s | grep -q "wip: parked" || fail "park_wip did not commit"
lib "park_wip $id3 'should-not-appear'" || fail "park_wip on clean tree failed"
git -C app log -1 --format=%s | grep -q "should-not-appear" && fail "park_wip committed on clean tree" || true
# approving review.md + committed work → deterministic done merges it (loop.sh's belt path)
printf '## Round 1\nno findings\nVERDICT: approve\n' > "$d3/review.md"
verdict=$(grep '^VERDICT:' "$d3/review.md" | tail -1)
[ "$verdict" = "VERDICT: approve" ] || fail "last-verdict parse gave '$verdict'"
"$INTENTPIPE/scripts/task.sh" done "$id3" >/dev/null || fail "approved work should merge"
grep -q "Status: done" "$d3/task.md" || fail "id3 not done after merge"
git -C app log -1 --format=%B | grep -q "Task-Id: $id3" || fail "id3 merge missing trailer"

# --- task.sh nits: read-only digest of [nit] findings from DONE tasks — the one
# triage point /plan reads (nits never re-loop inside a build, DESIGN #5)
printf '## Round 1\n[nit] app/third.txt:1 — stale comment survives — cosmetic\nVERDICT: approve\n' > "$d3/review.md"
nout=$("$INTENTPIPE/scripts/task.sh" nits)
echo "$nout" | grep -q "$id3 \[nit\] app/third.txt:1" || fail "nits must list a done task's nit, id-prefixed: $nout"
echo "$nout" | grep -q "VERDICT" && fail "nits must emit only [nit] lines: $nout" || true
# an in-progress task's review is not listed (id2 is mid-flight with a review-less branch)

# --- branch_head: fingerprints the task branch tip so loop.sh can spot a resume
# that committed nothing. A sha while the branch lives (id2), "-" once merged/gone
# (id3's branch was deleted by done).
lib "branch_head $id2" | grep -qE "app:[0-9a-f]{7}" || fail "branch_head should show a sha for a live branch"
lib "branch_head $id3" | grep -q "app:-" || fail "branch_head should show - for a deleted branch"

# --- is_transient_api_error: matches self-clearing network/API drops (retry), not
# usage limits, out-of-credits, or ordinary task failures (which must surface)
for msg in "API Error: Connection closed mid-response." "read ECONNRESET" "overloaded_error" "Error 529" "service unavailable"; do
  lib "is_transient_api_error '$msg'" || fail "is_transient_api_error missed: $msg"
done
for msg in "Claude AI usage limit reached" "credit balance is too low" "acceptance test failed: expected 3"; do
  lib "is_transient_api_error '$msg'" && fail "is_transient_api_error false-matched: $msg" || true
done

# --- cold-start orphan: task.sh next returns an in-progress task (resume) instead
# of skipping it, so an orphan self-heals and gates its successors. The red-verify
# test above left id2 (0002) in-progress with commits, ahead of the 0003 todo.
[ "$("$INTENTPIPE/scripts/task.sh" next)" = "0002" ] \
  || fail "next must return the in-progress task, not skip to a later todo"

# a zero-commit orphan (killed before any work) → abandon resets to todo and
# un-strands the repo back to DEFAULT_BRANCH
orphan=$("$INTENTPIPE/scripts/task.sh" new "Orphan task")
"$INTENTPIPE/scripts/task.sh" start "$orphan" >/dev/null   # in-progress, on task branch, 0 commits
lib "branch_has_commits $orphan" && fail "orphan should have 0 commits" || true
"$INTENTPIPE/scripts/task.sh" abandon "$orphan" >/dev/null
grep -q "Status: todo" intentpipe/tasks/"$orphan"-*/task.md || fail "abandon should reset to todo"
[ "$(git -C app rev-parse --abbrev-ref HEAD)" = "main" ] || fail "abandon should un-strand the repo to main"
git -C app rev-parse -q --verify "task/$orphan-orphan-task" >/dev/null && fail "abandon should delete the empty branch" || true

# abandon must refuse to discard committed work (git branch -d, not -D)
keep=$("$INTENTPIPE/scripts/task.sh" new "Keep work")
"$INTENTPIPE/scripts/task.sh" start "$keep" >/dev/null
echo data > app/keep.txt
git -C app add . && git -C app -c user.email=t@t -c user.name=t commit -qm "real work"
rc=0; "$INTENTPIPE/scripts/task.sh" abandon "$keep" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "abandon must refuse a branch with unmerged commits"
git -C app rev-parse -q --verify "task/$keep-keep-work" >/dev/null || fail "abandon must not delete a committed branch"
grep -q "Status: in-progress" intentpipe/tasks/"$keep"-*/task.md || fail "abandon refusal must leave status in-progress"

# reopen: a committed branch resumes (in-progress); an empty branch abandons (todo)
"$INTENTPIPE/scripts/task.sh" block "$keep" "reopen test" >/dev/null
"$INTENTPIPE/scripts/task.sh" reopen "$keep" >/dev/null
grep -q "Status: in-progress" intentpipe/tasks/"$keep"-*/task.md || fail "reopen of a committed branch → in-progress"
empty=$("$INTENTPIPE/scripts/task.sh" new "Empty branch")
"$INTENTPIPE/scripts/task.sh" start "$empty" >/dev/null   # in-progress, 0 commits
"$INTENTPIPE/scripts/task.sh" reopen "$empty" >/dev/null
grep -q "Status: todo" intentpipe/tasks/"$empty"-*/task.md || fail "reopen of an empty branch → todo"
[ "$(git -C app rev-parse --abbrev-ref HEAD)" = "main" ] || fail "reopen-abandon should un-strand the repo"

# --- no-arg verify must run every repo (regression: "${@:-$REPOS}" collapsed
# multi-repo REPOS into one word, silently verifying nothing); flat layout
# (agents.env at the workspace root) must keep working
WS2="$TMP/ws2"; mkdir -p "$WS2/a" "$WS2/b"
cat > "$WS2/agents.env" <<'EOF'
PROJECT_NAME=smoke2
REPOS="a b"
REPO_a=a
REPO_b=b
VERIFY_a="touch ran_a"
VERIFY_b="touch ran_b"
EOF
(cd "$WS2" && "$INTENTPIPE/scripts/verify.sh" >/dev/null) || fail "two-repo verify should pass"
[ -f "$WS2/a/ran_a" ] && [ -f "$WS2/b/ran_b" ] || fail "no-arg verify skipped a repo"
# a workspace with no tasks/ dir must still verify silently (timing records are
# best-effort — they may never write an error into a caller's output)
(cd "$WS2" && "$INTENTPIPE/scripts/verify.sh" 2>&1 >/dev/null | grep -q . ) \
  && fail "verify wrote to stderr in a task-less workspace" || true

# --- a chatty runner must not dump its transcript into a piped caller's context
# (verify.sh run_step): green keeps the runner's last line, red keeps a named
# log tail bounded by VERIFY_LOG_LINES. A human at a TTY still sees everything.
WSV="$TMP/wsv"; mkdir -p "$WSV/c"
mkenvv() { cat > "$WSV/agents.env" <<EOF
PROJECT_NAME=smokev
REPOS="c"
REPO_c=c
VERIFY_c="$1"
EOF
}
mkenvv 'seq 1 200; echo 200 passed'
out=$(cd "$WSV" && "$INTENTPIPE/scripts/verify.sh" 2>&1)
[ "$(printf '%s\n' "$out" | wc -l)" -le 4 ] \
  || fail "green verify dumped the runner transcript ($(printf '%s\n' "$out" | wc -l) lines)"
printf '%s\n' "$out" | grep -q "200 passed" || fail "green verify must keep the runner's summary line"
printf '%s\n' "$out" | grep -qx "100" && fail "green verify leaked the transcript body" || true

mkenvv 'seq 1 200; exit 1'
out=$(cd "$WSV" && VERIFY_LOG_LINES=10 "$INTENTPIPE/scripts/verify.sh" 2>&1 || true)
printf '%s\n' "$out" | grep -q "full log:" || fail "red verify must name the full log"
printf '%s\n' "$out" | grep -qx "200" || fail "red verify must show the failing tail"
printf '%s\n' "$out" | grep -qx "150" && fail "red verify must respect VERIFY_LOG_LINES" || true

# --- done verifies the task's repos in full, the rest tests-only: an untouched
# repo's SMOKE must not fire (it would recreate a live preview mid-review), but
# its VERIFY must (a cross-repo break may not land green)
WS3="$TMP/ws3"; mkdir -p "$WS3/a" "$WS3/b" "$WS3/intentpipe/tasks"
git -C "$WS3" init -qb main && git -C "$WS3" config user.email t@t && git -C "$WS3" config user.name t
for r in a b; do
  git -C "$WS3/$r" init -qb main
  git -C "$WS3/$r" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
done
cat > "$WS3/intentpipe/agents.env" <<'EOF'
PROJECT_NAME=smoke3
DEFAULT_BRANCH=main
REPOS="a b"
REPO_a=../a
REPO_b=../b
VERIFY_a="touch ran_verify_a"
VERIFY_b="touch ran_verify_b"
SMOKE_a="touch ran_smoke_a"
SMOKE_b="touch ran_smoke_b"
EOF
(
  cd "$WS3"
  sid=$("$INTENTPIPE/scripts/task.sh" new "A-only change" a)
  "$INTENTPIPE/scripts/task.sh" start "$sid" >/dev/null
  echo x > a/x.txt && git -C a add . && git -C a -c user.email=t@t -c user.name=t commit -qm "x"
  "$INTENTPIPE/scripts/task.sh" done "$sid" >/dev/null || fail "a-only done failed"
  [ -f a/ran_verify_a ] && [ -f a/ran_smoke_a ] || fail "task repo must verify AND smoke at done"
  [ -f b/ran_verify_b ] || fail "untouched repo must still run its tests at done"
  [ -f b/ran_smoke_b ] && fail "untouched repo's smoke must NOT fire at done" || true
)
# --- publish: under DONE=local the squash-merge is the terminal state, so done
# must also push it — an unpublished green task is invisible until a human looks
# (bibbles sat three tasks behind origin). Tolerant: a rejected push is reported,
# never fatal. DONE=pr must not publish at all — the platform merges there.
WSP="$TMP/wsp"; mkdir -p "$WSP/a" "$WSP/intentpipe/tasks"
git -C "$WSP" init -qb main && git -C "$WSP" config user.email t@t && git -C "$WSP" config user.name t
git init -q --bare -b main "$TMP/origin-a.git"
git -C "$WSP/a" init -qb main
git -C "$WSP/a" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
git -C "$WSP/a" remote add origin "$TMP/origin-a.git"
git -C "$WSP/a" push -q origin main
cat > "$WSP/intentpipe/agents.env" <<'EOF'
PROJECT_NAME=smoke_pub
DEFAULT_BRANCH=main
REPOS="a"
REPO_a=../a
VERIFY_a="true"
EOF
(
  cd "$WSP"
  pid=$("$INTENTPIPE/scripts/task.sh" new "Publishable change" a)
  "$INTENTPIPE/scripts/task.sh" start "$pid" >/dev/null
  echo p > a/p.txt && git -C a add . && git -C a -c user.email=t@t -c user.name=t commit -qm "p"
  "$INTENTPIPE/scripts/task.sh" done "$pid" >/dev/null || fail "publish: done failed"
  git -C "$TMP/origin-a.git" log --oneline main | grep -q "Publishable change" \
    || fail "done under DONE=local must push the merged default branch to origin"
  out=$(DONE=pr "$INTENTPIPE/scripts/publish.sh" 2>&1)
  echo "$out" | grep -q "nothing to publish" || fail "publish must no-op under DONE=pr: $out"
  # origin moves under us (a human pushed from elsewhere): the push is rejected,
  # and that must be loud but never fatal — the commits are safe in local main.
  git clone -q "$TMP/origin-a.git" "$TMP/mate"
  git -C "$TMP/mate" -c user.email=t@t -c user.name=t commit -qm teammate --allow-empty
  git -C "$TMP/mate" push -q origin main
  echo q > a/q.txt && git -C a add . && git -C a -c user.email=t@t -c user.name=t commit -qm "q"
  "$INTENTPIPE/scripts/publish.sh" a > "$TMP/pub.out" 2>&1 \
    || fail "publish must exit 0 even when the push is rejected"
  grep -q "push failed" "$TMP/pub.out" || fail "publish must report a rejected push: $(cat "$TMP/pub.out")"
)
echo "[smoke] publish.sh ok"

# --- a verify command that leaves workers behind (flutter test does, on every
# run) must not leak them: the run owns a process group, reaped when it returns
WSR="$TMP/wsr"; mkdir -p "$WSR/c"
cat > "$WSR/agents.env" <<'EOF'
PROJECT_NAME=smoke_reap
REPOS="c"
REPO_c=c
VERIFY_c="nohup sleep 600 >/dev/null 2>&1 & echo \$! > worker.pid; disown"
EOF
(cd "$WSR" && "$INTENTPIPE/scripts/verify.sh" >/dev/null) \
  || fail "verify should pass while leaving a worker behind"
worker=$(cat "$WSR/c/worker.pid") || fail "orphan check: verify never spawned the worker"
sleep 3   # TERM, grace, KILL
kill -0 "$worker" 2>/dev/null && fail "verify leaked an orphaned worker" || true
cd "$WS"

# --- step timing: verify.sh records its own wall time into the in-progress
# task's timings.tsv, and timing_summary groups the rows (verify:a + verify:b →
# one `verify`) with a total. This is what gives a finished task a per-step
# breakdown without any LLM cooperation.
tt=$("$INTENTPIPE/scripts/task.sh" new "Timed task")
"$INTENTPIPE/scripts/task.sh" start "$tt" >/dev/null
INTENTPIPE_TIMING_ID=$tt "$INTENTPIPE/scripts/verify.sh" >/dev/null || fail "verify should pass for the timing check"
tf=$(ls intentpipe/tasks/"$tt"-*/timings.tsv) || fail "verify.sh recorded no timings"
grep -q '^verify:app' "$tf" || fail "timings.tsv missing a verify row"
printf 'llm\t120\nverify:app\t30\npreflight\t5\n' > "$tf"   # deterministic numbers
sum=$(lib "timing_summary $tt")
[ "$sum" = "total 2m35s · preflight 5s · llm 2m0s · verify 30s" ] || fail "timing_summary wrong: $sum"
[ "$(lib 'fmt_k 1839500')" = "1840k" ] || fail "fmt_k should round to the nearest thousand"
# a field the template gained later must still land on an older task.md, in the
# header block — otherwise loop.sh silently drops Timing/Cost on existing projects
tmd=$(ls intentpipe/tasks/"$tt"-*/task.md)
perl -ni -e 'print unless /^Timing:/' "$tmd"
lib "set_field $tmd Timing 'total 5m'"
grep -q '^Timing: total 5m' "$tmd" || fail "set_field must insert a missing field"
[ "$(grep -n '^Timing:' "$tmd" | cut -d: -f1)" -lt "$(grep -n '^## ' "$tmd" | head -1 | cut -d: -f1)" ] \
  || fail "an inserted field must land in the header block, not after it"
[ "$(lib 'fmt_dur 3720')" = "1h2m" ] || fail "fmt_dur hours wrong"
INTENTPIPE_TIMING_ID=$tt lib "timing_record smoke:app 7" && grep -q '^smoke:app	7$' "$tf" \
  || fail "INTENTPIPE_TIMING_ID should pin the record to that task"
"$INTENTPIPE/scripts/task.sh" abandon "$tt" >/dev/null

# --- DONE=pr: fresh base from origin, done pushes branch + opens PR (gh is
# stubbed, origin is a local bare repo), sync completes on merge, and a red
# origin/main makes preflight exit 3 (UPSTREAM RED)
WS3="$TMP/ws3"; mkdir -p "$WS3/app" "$WS3/intentpipe/tasks" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view") case "$3" in
               https://*) [ -n "${GH_PR_STATE:-}" ] || exit 1
                          echo "$GH_PR_STATE ${GH_PR_SHA:-}" ;;
               *) exit 1 ;;   # no PR exists for this branch yet
             esac ;;
  "pr create") echo "https://example.test/pr/1" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
git init --bare -qb main "$TMP/app-origin"
git -C "$WS3/app" init -qb main
git -C "$WS3/app" config user.email t@t && git -C "$WS3/app" config user.name t
echo ok > "$WS3/app/ok.txt"
git -C "$WS3/app" add . && git -C "$WS3/app" commit -qm init
git -C "$WS3/app" remote add origin "$TMP/app-origin"
git -C "$WS3/app" push -qu origin main
cat > "$WS3/intentpipe/agents.env" <<'EOF'
PROJECT_NAME=smoke3
DEFAULT_BRANCH=main
DONE=pr
REPOS="app"
REPO_app=../app
VERIFY_app="test -f ok.txt"
EOF
cd "$WS3"
"$INTENTPIPE/scripts/preflight.sh" >/dev/null || fail "pr-mode preflight should pass"
# freshen (decision #29): plan kickoff brings clean repos onto current upstream.
# Advance origin/main from a throwaway clone, sit the repo on a clean task branch,
# then freshen must move it onto main and ff to origin — without deleting the branch.
git clone -q "$TMP/app-origin" "$TMP/app-clone"
git -C "$TMP/app-clone" -c user.email=t@t -c user.name=t commit -qm "upstream advance" --allow-empty
git -C "$TMP/app-clone" push -q origin main
git -C "$WS3/app" checkout -qb stale-wip
echo w > "$WS3/app/w.txt" && git -C "$WS3/app" add . && git -C "$WS3/app" commit -qm "dangling wip"
"$INTENTPIPE/scripts/freshen.sh" >/dev/null || fail "freshen should succeed"
[ "$(git -C "$WS3/app" rev-parse --abbrev-ref HEAD)" = "main" ] || fail "freshen should move a clean repo onto main"
git -C "$WS3/app" rev-parse -q --verify stale-wip >/dev/null || fail "freshen must not delete a dangling task branch"
[ "$(git -C "$WS3/app" rev-parse main)" = "$(git -C "$WS3/app" rev-parse origin/main)" ] || fail "freshen should ff local main to origin"
git -C "$WS3/app" branch -qD stale-wip
# a repo with uncommitted (tracked) changes is reported and left as-is
echo dirty >> "$WS3/app/ok.txt"
fout=$("$INTENTPIPE/scripts/freshen.sh" 2>&1)
[[ "$fout" == *"uncommitted changes"* ]] || fail "freshen must report a dirty repo"
grep -q dirty "$WS3/app/ok.txt" || fail "freshen must not clobber uncommitted changes"
git -C "$WS3/app" checkout -q -- ok.txt
# AFTER_DONE (decision #36): a landed task tells the workspace which branch now
# carries the work, so whatever serves the project can follow it — `done` has just
# put every repo back on the default branch. Detached and tolerant: the hook here
# exits nonzero, and `done` must still succeed.
cat > "$TMP/bin/after-done-hook" <<'EOF'
#!/usr/bin/env bash
echo "$1 ws=$INTENTPIPE_WORKSPACE env=$INTENTPIPE_BRANCH" >> "$INTENTPIPE_WORKSPACE/after-done.seen"
exit 3
EOF
chmod +x "$TMP/bin/after-done-hook"
printf 'AFTER_DONE=%q\n' "$TMP/bin/after-done-hook" >> "$WS3/intentpipe/agents.env"

idp=$("$INTENTPIPE/scripts/task.sh" new "Pr flow")
"$INTENTPIPE/scripts/task.sh" start "$idp" >/dev/null
echo feature > app/feat.txt
git -C app add . && git -C app commit -qm "wip pr flow"
"$INTENTPIPE/scripts/task.sh" done "$idp" >/dev/null || fail "pr-mode done failed"
dp=$(echo intentpipe/tasks/"$idp"-*/)
grep -q "Status: pr" "$dp/task.md" || fail "status should be pr, not merged"
grep -q "PR: app:https://example.test/pr/1" "$dp/task.md" || fail "PR url not recorded"
[ "$(git -C app rev-parse --abbrev-ref HEAD)" = "main" ] || fail "should be back on main after pr"
seen="$WS3/intentpipe/after-done.seen"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$seen" ] && break; sleep 0.5; done
grep -q "^task/$idp-pr-flow ws=$WS3/intentpipe env=task/$idp-pr-flow$" "$seen" \
  || fail "AFTER_DONE should fire with the PR branch: $(cat "$seen" 2>&1)"
grep -q "task/$idp-pr-flow" intentpipe/tasks/_after-done.log || fail "hook run not logged"
: > "$seen"
# inside a loop run the hook is DEFERRED (the next task starts immediately, and a
# hook that checks branches out would fight it): task.sh records the branch,
# loop.sh fires the last one when the run is over.
lib3() { INTENTPIPE_LOOP=1 bash -c "cd '$WS3' && source '$INTENTPIPE/scripts/lib.sh'; $1"; }
lib3 "after_done feature/x" >/dev/null || fail "after_done under INTENTPIPE_LOOP failed"
sleep 0.5; [ -s "$seen" ] && fail "a loop's landing must not fire the hook immediately" || true
[ "$(cat intentpipe/tasks/_after-done.pending)" = "feature/x" ] || fail "deferred branch not recorded"
git -C "$TMP/app-origin" rev-parse -q --verify "task/$idp-pr-flow" >/dev/null || fail "branch not pushed to origin"
GH_PR_STATE=OPEN "$INTENTPIPE/scripts/task.sh" sync >/dev/null
grep -q "Status: pr" "$dp/task.md" || fail "open PR must not complete the task"
GH_PR_STATE=MERGED GH_PR_SHA=1234567890abcdef "$INTENTPIPE/scripts/task.sh" sync >/dev/null
grep -q "Status: done" "$dp/task.md" || fail "merged PR should complete the task"
grep -q "app:1234567" "$dp/task.md" || fail "merge sha not recorded"
grep -q "$idp" intentpipe/tasks/_log.md || fail "no log line after sync"
git -C app rev-parse -q --verify "task/$idp-pr-flow" >/dev/null && fail "local branch not cleaned up" || true

# --- DONE=pr + features: tasks squash-merge as single commits onto feature/<slug>;
# the PR opens only when the feature's last task lands; sync completes the feature
fa=$("$INTENTPIPE/scripts/task.sh" new "Feat part one" app login-flow)
fb=$("$INTENTPIPE/scripts/task.sh" new "Feat part two" app login-flow)
grep -q "Feature: login-flow" intentpipe/tasks/"$fa"-*/task.md || fail "Feature field not set"
grep -q "Tasks: $fa $fb" intentpipe/tasks/_features/login-flow.md || fail "feature file has wrong members"
"$INTENTPIPE/scripts/task.sh" start "$fa" >/dev/null
echo one > app/one.txt
git -C app add . && git -C app commit -qm "wip one"
"$INTENTPIPE/scripts/task.sh" done "$fa" >/dev/null || fail "feature task done failed"
grep -q "Status: done" intentpipe/tasks/"$fa"-*/task.md || fail "feature task should be done on landing"
grep -q "Status: open" intentpipe/tasks/_features/login-flow.md || fail "feature must stay open mid-feature"
# mid-feature the work lives on the integration branch, not the squashed-away task
# branch — that is what AFTER_DONE must name (its PR opens only when the last task lands)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$seen" ] && break; sleep 0.5; done
grep -q "^feature/login-flow " "$seen" || fail "AFTER_DONE should fire with the feature branch: $(cat "$seen" 2>&1)"
: > "$seen"
[ "$(git -C app rev-parse --abbrev-ref HEAD)" = "feature/login-flow" ] || fail "repo should sit on the feature branch mid-feature"
git -C app log -1 --format=%B | grep -q "Task-Id: $fa" || fail "feature merge missing Task-Id trailer"
"$INTENTPIPE/scripts/task.sh" start "$fb" >/dev/null
[ -f app/one.txt ] || fail "second feature task must see the first task's work"
echo two > app/two.txt
git -C app add . && git -C app commit -qm "wip two"
"$INTENTPIPE/scripts/task.sh" done "$fb" >/dev/null || fail "final feature task done failed"
grep -q "Status: pr" intentpipe/tasks/_features/login-flow.md || fail "feature should be pr after its last task"
grep -q "PR: app:https://example.test/pr/1" intentpipe/tasks/_features/login-flow.md || fail "feature PR url not recorded"
[ "$(git -C app rev-parse --abbrev-ref HEAD)" = "main" ] || fail "should be back on main after the feature ships"
git -C "$TMP/app-origin" rev-parse -q --verify feature/login-flow >/dev/null || fail "feature branch not pushed to origin"
[ "$(git -C app log --oneline main..feature/login-flow | wc -l | tr -d ' ')" = 2 ] \
  || fail "feature branch should carry exactly one commit per task"
# the last task of the feature fires it too (the PR that just opened is on that
# branch); drain it so the sync check below can't read a stale line
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$seen" ] && break; sleep 0.5; done
grep -q "^feature/login-flow " "$seen" || fail "AFTER_DONE should fire when the feature ships"
: > "$seen"
GH_PR_STATE=MERGED GH_PR_SHA=abcdef1234567890 "$INTENTPIPE/scripts/task.sh" sync >/dev/null
grep -q "Status: done" intentpipe/tasks/_features/login-flow.md || fail "merged feature PR should complete the feature"
sleep 1; [ -s "$seen" ] && fail "sync must not fire AFTER_DONE — a merge is the human's state change" || true
# ... and loop.sh drains what a run deferred (recorded above), on the way out — the
# queue is empty here, so the run exits at the peek and still fires it exactly once
"$INTENTPIPE/scripts/loop.sh" >/dev/null 2>&1 || fail "loop.sh with an empty queue should exit 0"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$seen" ] && break; sleep 0.5; done
grep -q "^feature/x " "$seen" || fail "loop.sh must fire the deferred hook: $(cat "$seen" 2>&1)"
[ -f intentpipe/tasks/_after-done.pending ] && fail "the deferred branch must be consumed" || true
git -C app rev-parse -q --verify feature/login-flow >/dev/null && fail "feature branch not cleaned up" || true
grep -q "feature login-flow" intentpipe/tasks/_log.md || fail "no feature log line"

# --- PR amendment window: a merged feature refuses new tasks; a feature with an
# open PR accepts them (they land on the same branch → same PR); sync blocks an
# amend task the merge raced past
"$INTENTPIPE/scripts/task.sh" new "Too late" app login-flow >/dev/null 2>&1 \
  && fail "new must refuse a task for a merged (done) feature" || true
fc=$("$INTENTPIPE/scripts/task.sh" new "Amend base" app amend-flow)
"$INTENTPIPE/scripts/task.sh" start "$fc" >/dev/null
echo base > app/amend1.txt
git -C app add . && git -C app commit -qm "wip amend base"
"$INTENTPIPE/scripts/task.sh" done "$fc" >/dev/null || fail "amend-flow base task failed"
grep -q "Status: pr" intentpipe/tasks/_features/amend-flow.md || fail "amend-flow should be pr after shipping"
fd=$("$INTENTPIPE/scripts/task.sh" new "Amend addition" app amend-flow) \
  || fail "new must accept a task for a feature with an open PR"
grep -q "Tasks: $fc $fd" intentpipe/tasks/_features/amend-flow.md || fail "amend task not appended to feature"
"$INTENTPIPE/scripts/task.sh" start "$fd" >/dev/null
[ -f app/amend1.txt ] || fail "amend task must branch from the live feature branch"
echo more > app/amend2.txt
git -C app add . && git -C app commit -qm "wip amend addition"
"$INTENTPIPE/scripts/task.sh" done "$fd" >/dev/null || fail "amend task done failed"
grep -q "Status: pr" intentpipe/tasks/_features/amend-flow.md || fail "amended feature should re-ship as pr"
[ "$(git -C app log --oneline main..feature/amend-flow | wc -l | tr -d ' ')" = 2 ] \
  || fail "feature branch should carry the original and the amend commit"
fe=$("$INTENTPIPE/scripts/task.sh" new "Raced amend" app amend-flow)
GH_PR_STATE=MERGED GH_PR_SHA=fedcba9876543210 "$INTENTPIPE/scripts/task.sh" sync >/dev/null
grep -q "Status: done" intentpipe/tasks/_features/amend-flow.md || fail "merged amend-flow should be done"
grep -q "Status: blocked" intentpipe/tasks/"$fe"-*/task.md \
  || fail "sync must block an amend task the merge raced past"
"$INTENTPIPE/scripts/task.sh" new "Way too late" app amend-flow >/dev/null 2>&1 \
  && fail "new must refuse the feature once its PR merged" || true

# red origin/main: verify fails with the repo exactly at origin → exit 3
rm app/ok.txt && git -C app add -A && git -C app commit -qm "teammate breaks main"
git -C app push -q origin main
rc=0; "$INTENTPIPE/scripts/preflight.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "red upstream should exit 3, got $rc"
cd "$WS"

# --- notify.sh Telegram leg: sends into the project's topic when creds are set,
# prints-only when they're not. curl is stubbed to log its args ($TMP/bin is on
# PATH from the pr-mode section above). TELEGRAM_ENV points nowhere so a real
# ~/.agent-orchestrator/telegram.env can't leak into the test.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
EOF
chmod +x "$TMP/bin/curl"
export CURL_LOG="$TMP/curl.log" TELEGRAM_ENV=/nonexistent
: > "$CURL_LOG"
TELEGRAM_BOT_TOKEN=tok TELEGRAM_CHAT_ID=42 TELEGRAM_TOPIC_ID=7 \
  "$INTENTPIPE/scripts/notify.sh" "hello from smoke" >/dev/null
grep -q "sendMessage" "$CURL_LOG" || fail "notify: no telegram send with creds set"
grep -q "chat_id=42" "$CURL_LOG" || fail "notify: chat_id not sent"
grep -q "message_thread_id=7" "$CURL_LOG" || fail "notify: topic id not sent"
grep -q "hello from smoke" "$CURL_LOG" || fail "notify: message text not sent"
: > "$CURL_LOG"
"$INTENTPIPE/scripts/notify.sh" "no creds here" >/dev/null
[ -s "$CURL_LOG" ] && fail "notify: hit telegram without creds" || true
# NOTIFY_SILENT suppresses only the telegram leg (still prints)
: > "$CURL_LOG"
TELEGRAM_BOT_TOKEN=tok TELEGRAM_CHAT_ID=42 NOTIFY_SILENT=1 \
  "$INTENTPIPE/scripts/notify.sh" "quiet please" >/dev/null
[ -s "$CURL_LOG" ] && fail "notify: NOTIFY_SILENT still hit telegram" || true

# --- human-decision gate: a task marked `Decision: <question>` is asked on
# Telegram (ask.sh posts the question + remembers message_id -> task), and
# task.sh resolve folds the human's answer in and returns the task to todo.
newtmpl=$("$INTENTPIPE/scripts/task.sh" new "Gated thing")
grep -q "^Decision: -" intentpipe/tasks/"$newtmpl"-*/task.md || fail "new task template missing Decision field"
gmd=$(echo intentpipe/tasks/"$newtmpl"-*/task.md)
lib "set_field '$gmd' Decision 'wilt over 7 days or 3?'"
[ "$(lib "get_field '$gmd' Decision")" = "wilt over 7 days or 3?" ] || fail "decision field not set"
# ask.sh: stub curl to return a message_id, check the offer file records msg -> task
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"message_id":555}}'
EOF
chmod +x "$TMP/bin/curl"
offers="$TMP/decision_offers.json"
TELEGRAM_BOT_TOKEN=tok TELEGRAM_CHAT_ID=42 TELEGRAM_TOPIC_ID=9 DECISION_OFFERS_FILE="$offers" \
  "$INTENTPIPE/scripts/ask.sh" "$newtmpl" "wilt over 7 days or 3?" >/dev/null
python3 -c "import json,sys; o=json.load(open('$offers')); e=o['555']; sys.exit(0 if e['task']=='$newtmpl' and e['question']=='wilt over 7 days or 3?' else 1)" \
  || fail "ask.sh did not remember the decision offer (msg 555 -> task $newtmpl)"
# resolve: fold the answer, clear the gate, back to todo
"$INTENTPIPE/scripts/task.sh" resolve "$newtmpl" "flowers 3 days; dishes consumed" >/dev/null
[ "$(lib "get_field '$gmd' Decision")" = "-" ] || fail "resolve did not clear the Decision gate"
grep -q "## Decision (resolved)" "$gmd" || fail "resolve did not record the decision section"
grep -q "flowers 3 days; dishes consumed" "$gmd" || fail "resolve did not fold the answer text"
grep -q "^Status: todo" "$gmd" || fail "resolve did not return the task to todo"
# a legacy task with no Decision field is not a false gate (get_field → empty)
legacy=$("$INTENTPIPE/scripts/task.sh" new "Ungated")
lmd=$(echo intentpipe/tasks/"$legacy"-*/task.md)
perl -ni -e 'print unless /^Decision:/' "$lmd"   # simulate a pre-feature task
d=$(lib "get_field '$lmd' Decision" || true); [ -z "$d" ] || fail "missing Decision field should read empty, got '$d'"

# --- inbound.sh: server drops raw messages into updates/.inbox/, inbound.sh
# turns them into updates/ notes (oldest first) and drains the inbox. No inbox
# (or an empty one) is a no-op, never an error.
"$INTENTPIPE/scripts/inbound.sh" >/dev/null || fail "inbound: no inbox should be a no-op"
mkdir -p "$WS/intentpipe/updates/.inbox"
echo "build the login page" > "$WS/intentpipe/updates/.inbox/1600000000-42.md"
echo "also add logout"      > "$WS/intentpipe/updates/.inbox/1600000005-43.md"
"$INTENTPIPE/scripts/inbound.sh" >/dev/null || fail "inbound: drain failed"
[ -f "$WS/intentpipe/updates/tg-1600000000-42.md" ] || fail "inbound: first note not created"
grep -q "build the login page" "$WS/intentpipe/updates/tg-1600000000-42.md" || fail "inbound: note text lost"
[ -f "$WS/intentpipe/updates/tg-1600000005-43.md" ] || fail "inbound: second note not created"
[ -z "$(ls -A "$WS/intentpipe/updates/.inbox")" ] || fail "inbound: inbox not drained"
"$INTENTPIPE/scripts/inbound.sh" >/dev/null || fail "inbound: empty inbox should be a no-op"
# an image dropped next to its caption note becomes a permanent resource, and the
# note's bare-basename reference is rewritten to the path a session reads
printf 'fakejpg' > "$WS/intentpipe/updates/.inbox/1600000010-44.jpg"
printf 'build this mockup\n\n[image: 1600000010-44.jpg]\n' > "$WS/intentpipe/updates/.inbox/1600000010-44.md"
"$INTENTPIPE/scripts/inbound.sh" >/dev/null || fail "inbound: image drain failed"
[ -f "$WS/intentpipe/resources/tg-1600000010-44.jpg" ] || fail "inbound: image not moved to resources/"
grep -q "\[image: intentpipe/resources/tg-1600000010-44.jpg\]" \
  "$WS/intentpipe/updates/tg-1600000010-44.md" || fail "inbound: image reference not rewritten"
# an already-pathed reference is left alone (no double rewrite on hand-written notes)
printf 'match this style\n\n[image: intentpipe/resources/style.png]\n' > "$WS/intentpipe/updates/.inbox/1600000011-45.md"
"$INTENTPIPE/scripts/inbound.sh" >/dev/null || fail "inbound: pathed-ref drain failed"
grep -q "\[image: intentpipe/resources/style.png\]" \
  "$WS/intentpipe/updates/tg-1600000011-45.md" || fail "inbound: pathed reference must not be rewritten"
[ -z "$(ls -A "$WS/intentpipe/updates/.inbox")" ] || fail "inbound: image inbox not drained"

# --- linear.sh: one issue per plan via the issueCreate GraphQL mutation, curl
# stubbed to return canned responses. Opt-in feature; only exercised where jq is
# present (linear.sh needs it). $TMP/bin is on PATH from the pr-mode section.
if command -v jq >/dev/null; then
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *issueCreate*) echo "$LINEAR_ISSUE_RESP" ;;
  *teams*)       echo "$LINEAR_TEAMS_RESP" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  export LINEAR_ENV=/nonexistent \
    LINEAR_ISSUE_RESP='{"data":{"issueCreate":{"issue":{"identifier":"ENG-123","url":"https://linear.app/acme/issue/ENG-123"}}}}' \
    LINEAR_TEAMS_RESP='{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}'
  # missing API key → loud error, never a silent no-op
  LINEAR_TEAM_KEY=ENG "$INTENTPIPE/scripts/linear.sh" create "t" "b" >/dev/null 2>&1 \
    && fail "linear: missing LINEAR_API_KEY must error" || true
  # happy path → IDENTIFIER<TAB>url, key first, so /plan can prefix feature slugs
  out=$(LINEAR_API_KEY=tok LINEAR_TEAM_KEY=ENG "$INTENTPIPE/scripts/linear.sh" create "Add payments" "- [ ] one")
  [ "$(printf '%s' "$out" | cut -f1)" = "ENG-123" ] || fail "linear: identifier not returned ($out)"
  printf '%s' "$out" | grep -q "linear.app/acme/issue/ENG-123" || fail "linear: url not returned ($out)"
  # unknown team key → error (issueCreate never reached)
  LINEAR_TEAMS_RESP='{"data":{"teams":{"nodes":[]}}}' \
    LINEAR_API_KEY=tok LINEAR_TEAM_KEY=NOPE "$INTENTPIPE/scripts/linear.sh" create "t" "b" >/dev/null 2>&1 \
    && fail "linear: unknown team must error" || true
  echo "[smoke] linear.sh ok"
else
  echo "[smoke] linear.sh skipped (no jq)"
fi

# --- loop.sh reporting: a finished task must say what it cost in TOKENS as well
# as dollars, and where its time went. `claude` is stubbed to emit a real JSON
# envelope and to run the gates the way a session does, so the `llm` figure is
# exercised as "session wall clock minus what the scripts recorded meanwhile".
WS4="$TMP/ws4"; mkdir -p "$WS4/app" "$WS4/intentpipe/tasks"
git -C "$WS4/app" init -qb main
git -C "$WS4/app" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
cat > "$WS4/intentpipe/agents.env" <<'EOF'
PROJECT_NAME=smoke4
DEFAULT_BRANCH=main
REPOS="app"
REPO_app=../app
VERIFY_app="sleep 1"
EOF
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/claude-args.log"
"$INTENTPIPE/scripts/verify.sh" >/dev/null 2>&1   # a session runs the gates
sleep 1
echo '{"total_cost_usd": 0.42, "usage": {"input_tokens": 12000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1828000, "output_tokens": 11500}}'
EOF
chmod +x "$TMP/bin/claude"
cd "$WS4"
t4=$("$INTENTPIPE/scripts/task.sh" new "Reported task")
# -u ANTHROPIC_*: pin subscription mode so the assertion doesn't depend on how
# this box happens to be authenticated.
lout=$(PATH="$TMP/bin:$PATH" MAX_TASKS=1 env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
       "$INTENTPIPE/scripts/loop.sh" 2>&1) || fail "loop.sh failed: $lout"
echo "$lout" | grep -q '1852k tok (1840k in / 12k out)' \
  || fail "loop.sh must report token usage next to the cost: $lout"
echo "$lout" | grep -qE '^   timing: total .* llm ' || fail "loop.sh must report a per-step timing line: $lout"
grep -q '^Cost: subscription (~\$0.42 API-equiv, 1852k tok)' intentpipe/tasks/"$t4"-*/task.md \
  || fail "Cost field must carry tokens alongside the API-equiv estimate"
grep -qE '^Timing: total [0-9]+[hms].* llm .* verify ' intentpipe/tasks/"$t4"-*/task.md \
  || fail "Timing field must break the task down per step"
grep -q '^verify:app	' intentpipe/tasks/"$t4"-*/timings.tsv \
  || fail "a gate run inside the session must land in that task's timings.tsv"

# --- per-task model: the planner's Model: field picks the session model, an
# explicit MODEL= pins the whole run over it, and an unknown value warns and
# falls back to the default instead of dying mid-queue.
grep -q -- '--model opus' "$TMP/claude-args.log" || fail "a task without a Model pick must run on the default (opus)"
lib "set_field $(ls intentpipe/tasks/"$t4"-*/task.md) Status done"   # unclog the queue for the next runs
t5=$("$INTENTPIPE/scripts/task.sh" new "Sonnet task")
t5md=$(ls intentpipe/tasks/"$t5"-*/task.md)
grep -q '^Model: -' "$t5md" || fail "task.sh new must stamp a Model field"
lib "set_field $t5md Model sonnet"
: > "$TMP/claude-args.log"
PATH="$TMP/bin:$PATH" MAX_TASKS=1 env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u MODEL \
  "$INTENTPIPE/scripts/loop.sh" >/dev/null 2>&1 || fail "loop.sh (Model: sonnet) failed"
grep -q -- '--model sonnet' "$TMP/claude-args.log" || fail "the planner's Model: sonnet must reach claude --model"
: > "$TMP/claude-args.log"
PATH="$TMP/bin:$PATH" MAX_TASKS=1 MODEL=fable env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  "$INTENTPIPE/scripts/loop.sh" >/dev/null 2>&1 || fail "loop.sh (MODEL=fable pin) failed"
grep -q -- '--model claude-fable-5' "$TMP/claude-args.log" \
  || fail "an explicit MODEL= must pin the run over the task's Model: pick"
lib "set_field $t5md Model gpt9"
: > "$TMP/claude-args.log"
lout5=$(PATH="$TMP/bin:$PATH" MAX_TASKS=1 env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u MODEL \
  "$INTENTPIPE/scripts/loop.sh" 2>&1) || fail "loop.sh (unknown Model) failed: $lout5"
grep -q -- '--model opus' "$TMP/claude-args.log" || fail "an unknown Model value must fall back to the default"
echo "$lout5" | grep -q "unknown Model 'gpt9'" || fail "an unknown Model value must warn"
cd "$WS"

# --- state-land.sh: PR + automerge for state-only diffs, via a stub gh that
# records calls; a bare "origin" stands in for GitHub.
SL="$TMP/sl"; mkdir -p "$SL/bin"
GHLOG="$SL/gh.log"
cat > "$SL/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHLOG"
case "\$1 \$2" in
  # a branch named in merged-prs has an already-merged PR; otherwise none → create path
  "pr view")   grep -qx "\$3" "$SL/merged-prs" 2>/dev/null || exit 1
               case "\$*" in *"--json state"*) echo MERGED ;; *) echo "https://example.test/pr/9" ;; esac ;;
  "pr create") echo "https://example.test/pr/1" ;;
  # merge for real, like GitHub would — the verification step checks origin
  "pr merge")  [ -e "$SL/merge-is-a-lie" ] || git push -q origin "\$3:main" ;;
esac
EOF
chmod +x "$SL/bin/gh"
git init -q --bare "$SL/origin.git"
git -C "$WS" remote add origin "$SL/origin.git" 2>/dev/null || git -C "$WS" remote set-url origin "$SL/origin.git"
git -C "$WS" add intentpipe && git -C "$WS" -c user.email=t@t -c user.name=t commit -qm base
git -C "$WS" push -qu origin main
git -C "$WS" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# nothing ahead → no-op, no gh call
out=$(PATH="$SL/bin:$PATH" "$INTENTPIPE/scripts/state-land.sh")
echo "$out" | grep -q "nothing ahead" || fail "state-land: clean tree must be a no-op"
[ ! -f "$GHLOG" ] || fail "state-land: no-op must not call gh"

# state-only commits on the default branch → state/ branch, PR, automerge,
# local main back in sync, no stray branch
echo "note" > intentpipe/updates/tg-1-1.md
git -C "$WS" add intentpipe/updates && git -C "$WS" -c user.email=t@t -c user.name=t commit -qm "state: note"
out=$(PATH="$SL/bin:$PATH" "$INTENTPIPE/scripts/state-land.sh")
echo "$out" | grep -q "state landed and merged" || fail "state-land: state-only diff must automerge"
grep -q "pr merge" "$GHLOG" || fail "state-land: merge was not attempted"
[ "$(git -C "$WS" rev-parse --abbrev-ref HEAD)" = "main" ] || fail "state-land: must end back on main"
[ -z "$(git -C "$WS" branch --list 'state/*')" ] || fail "state-land: state/ branch left behind"

# a branch whose PR already merged must not be reused: fresh branch, fresh PR
: > "$GHLOG"
git -C "$WS" checkout -qb state/stale
echo "note2" > intentpipe/updates/tg-1-2.md
git -C "$WS" add intentpipe/updates && git -C "$WS" -c user.email=t@t -c user.name=t commit -qm "state: note2"
echo state/stale > "$SL/merged-prs"
out=$(PATH="$SL/bin:$PATH" "$INTENTPIPE/scripts/state-land.sh")
grep -q "PR for state/stale is MERGED" <<<"$out" || fail "state-land: must not reuse a merged branch"
grep -q "pr create" "$GHLOG" || fail "state-land: merged branch must get a new PR"
grep -q "state landed and merged" <<<"$out" || fail "state-land: fresh branch must land"
[ "$(git -C "$WS" rev-list --count origin/main..HEAD)" = 0 ] || fail "state-land: commits stranded off main"
: > "$SL/merged-prs"

# a merge that does not actually reach main must fail loudly, not claim success
echo "note3" > intentpipe/updates/tg-1-3.md
git -C "$WS" add intentpipe/updates && git -C "$WS" -c user.email=t@t -c user.name=t commit -qm "state: note3"
: > "$SL/merge-is-a-lie"
out=$(PATH="$SL/bin:$PATH" "$INTENTPIPE/scripts/state-land.sh") && fail "state-land: unverified merge must exit non-zero"
grep -q "state landed and merged" <<<"$out" && fail "state-land: claimed success without landing" || true
grep -q "still off origin/main" <<<"$out" || fail "state-land: must report the stranded commits"
rm -f "$SL/merge-is-a-lie"
git -C "$WS" checkout -q main && git -C "$WS" reset -q --hard origin/main

# a non-state path in the diff → PR opened but NOT merged
: > "$GHLOG"
echo x > app-config.txt
git -C "$WS" add app-config.txt && git -C "$WS" -c user.email=t@t -c user.name=t commit -qm "config drift"
out=$(PATH="$SL/bin:$PATH" "$INTENTPIPE/scripts/state-land.sh")
echo "$out" | grep -q "left for the human" || fail "state-land: non-state diff must not automerge"
grep -q "pr merge" "$GHLOG" && fail "state-land: merged a non-state diff" || true
grep -q "non-state path in diff: app-config.txt" <<<"$out" || fail "state-land: must name the foreign path"
# clean up for the guard section: back to a synced main
git -C "$WS" checkout -q main 2>/dev/null || true
git -C "$WS" reset -q --hard origin/main
git -C "$WS" push -q origin --delete "$(git -C "$WS" branch -r | grep 'origin/state/' | sed 's|.*origin/||' | head -1)" 2>/dev/null || true
git -C "$WS" remote remove origin
echo "[smoke] state-land.sh ok"

# --- guard hook
g() { echo "$1" | python3 "$INTENTPIPE/hooks/guard.py" >/dev/null 2>&1; }
# The default-branch rule is DONE-scoped, so a push case must say where it runs:
# gl = from $WS (no DONE line => local), gp = from $WS3 (DONE=pr).
gl() { g "{\"tool_name\":\"Bash\",\"cwd\":\"${2:-$WS}\",\"tool_input\":{\"command\":\"$1\"}}"; }
gp() { g "{\"tool_name\":\"Bash\",\"cwd\":\"${2:-$WS3}\",\"tool_input\":{\"command\":\"$1\"}}"; }
g '{"tool_name":"Bash","tool_input":{"command":"git push --force origin x"}}' && fail "guard: force push allowed" || true
gp "git push origin main" && fail "guard: push to main under DONE=pr allowed" || true
gl "git push origin main" || fail "guard: push to main under DONE=local must be allowed"
g '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' && fail "guard: rm -rf / allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"git push origin task/0001-x"}}' || fail "guard: task-branch push blocked"
g '{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"}}' || fail "guard: normal rm blocked"
g '{"tool_name":"Bash","tool_input":{"command":"rm -rf intentpipe/updates"}}' && fail "guard: updates folder rm allowed" || true
g '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x/core/CLAUDE.md","content":"x"},"cwd":"/tmp/x"}' && fail "guard: CLAUDE.md write allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"echo map >> core/CLAUDE.md"},"cwd":"/tmp/x"}' && fail "guard: redirect into CLAUDE.md allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"cat CLAUDE.md"},"cwd":"/tmp/x"}' || fail "guard: reading CLAUDE.md blocked"
INTENTPIPE_ALLOW_CLAUDE_MD=1 g '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x/CLAUDE.md","content":"x"},"cwd":"/tmp/x"}' || fail "guard: CLAUDE.md override ignored"
# main/master is only a push target when it IS the ref: a chained `gh pr create
# --base master`, or a branch merely containing the word, must not read as one.
gp "git push -u origin feat/x; gh pr create --base master" \
  || fail "guard: --base master after a task-branch push must not read as a push to master"
gp "git push origin feat/x && gh pr create --base main" \
  || fail "guard: --base main after a task-branch push must not read as a push to main"
gp "git push origin fix/master-timeout" || fail "guard: a branch whose name contains master must be pushable"
gp "git push origin mainline" || fail "guard: a branch whose name starts with main must be pushable"
# ...and under DONE=pr the real thing stays blocked, in every shape it comes in
gp "git push origin HEAD:main" && fail "guard: HEAD:main refspec allowed" || true
gp "git push origin master:master" && fail "guard: master:master refspec allowed" || true
gp "git push origin refs/heads/main" && fail "guard: refs/heads/main allowed" || true
gp "git push -u origin master 2>&1 | tee log" && fail "guard: piped push to master allowed" || true
gp "echo hi && git push origin main" && fail "guard: push to main after a chain allowed" || true
# the mode is the workspace's, found by walking up — a repo subdir resolves too
gp "git push origin main" "$WS3/app" && fail "guard: DONE=pr not seen from a repo subdir" || true
# ...while under DONE=local every one of those shapes is ordinary work
gl "git push origin HEAD:main" || fail "guard: HEAD:main blocked under DONE=local"
gl "git push origin refs/heads/main" || fail "guard: refs/heads/main blocked under DONE=local"
gl "echo hi && git push origin main" || fail "guard: chained push to main blocked under DONE=local"
gl "git push origin main" "$WS/app" || fail "guard: DONE=local blocked from a repo subdir"
g '{"tool_name":"Bash","tool_input":{"command":"git push --force origin x | tee log"}}' && fail "guard: piped force-push allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"true; rm -rf /"}}' && fail "guard: chained rm -rf / allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"git rm -r updates/"}}' && fail "guard: git rm -r updates allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"rm updates/*"}}' && fail "guard: updates wildcard rm allowed" || true
g '{"tool_name":"Bash","tool_input":{"command":"git rm updates/tg-1600000000-42.md"}}' || fail "guard: single note rm blocked"
CLAUDE_PLUGIN_ROOT="$INTENTPIPE" python3 -c 'import json,subprocess,sys,os
root=os.environ["CLAUDE_PLUGIN_ROOT"]
def g(cwd): return subprocess.run(["python3", root+"/hooks/guard.py"], input=json.dumps({"tool_name":"Edit","cwd":cwd,"tool_input":{"file_path":root+"/agents/implementer.md"}}), capture_output=True, text=True).returncode
sys.exit(0 if g("/") == 2 and g(root) == 0 else 1)' || fail "guard: self-edit gate wrong (project must block, dev session must allow)"

echo "SMOKE OK"
