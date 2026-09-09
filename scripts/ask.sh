#!/usr/bin/env bash
# ask.sh <task-id> <decision-question>
# Surface a task's human-decision gate on Telegram: post the exact question with a
# "Reply to this message to decide." prompt, and remember the posted message so the
# orchestrator daemon can route the human's reply back into the task (task.sh
# resolve). Tolerant like notify.sh — missing creds just means "print only" (the
# task is still blocked, so it surfaces in NEEDS_HUMAN either way).
#
# Task 0071: the same question also reaches Quorum's chat for the project —
# the task's feature channel when it has one, its project chat otherwise —
# independent of Telegram creds and never affecting this script's own
# tolerance. Quorum has no reply-routing of its own: the human still answers
# on Telegram, task.sh resolve folds it in either way.
#
# Task 0072: that post is a `decision_request` message, not `text` — it
# carries the task id and the bare question, so Quorum renders a real card
# with a reply box that answers through the control plane's own decision
# endpoint (`POST .../tasks/{id}/decision`), same `task.sh resolve` underneath.
set -euo pipefail
id="${1:?usage: ask.sh <task-id> <question>}"
question="${2:?usage: ask.sh <task-id> <question>}"
workspace="$PWD"   # loop.sh runs at the project root; the daemon reuses it as cwd

echo "[ask] task $id needs a decision: $question"

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/quorum_post.sh"

# Same creds + per-project topic discovery as notify.sh.
tg_env="${TELEGRAM_ENV:-$HOME/.agent-orchestrator/telegram.env}"
# shellcheck disable=SC1090
if [ -f "$tg_env" ]; then . "$tg_env"; fi
ws=""
dir="$PWD"
while [ "$dir" != "/" ]; do
  # shellcheck disable=SC1090
  if [ -f "$dir/agents.env" ]; then . "$dir/agents.env"; ws="$dir"; break; fi
  # shellcheck disable=SC1090
  if [ -f "$dir/intentpipe/agents.env" ]; then . "$dir/intentpipe/agents.env"; ws="$dir/intentpipe"; break; fi
  dir="$(dirname "$dir")"
done
name="${PROJECT_NAME:-}"

text="🤔 Decision needed · task $id${name:+ · $name}

$question

Reply to this message to decide."

feature="$(quorum_feature_for_task "$ws" "$id" 2>/dev/null || true)"
quorum_post_decision "$name" "$id" "$question" "$feature"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "[ask] no telegram creds — printed only, no reply-routing" >&2
  exit 0
fi

resp=$(curl -fsS "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
  --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
  ${TELEGRAM_TOPIC_ID:+--data-urlencode "message_thread_id=$TELEGRAM_TOPIC_ID"} \
  --data-urlencode "text=$text") || { echo "[ask] telegram send failed" >&2; exit 0; }

# Remember message_id -> task so the daemon can route the reply. Shared with the
# orchestrator via a file in its run dir (override with DECISION_OFFERS_FILE).
offers="${DECISION_OFFERS_FILE:-${ORCH_HOME:-$HOME/.agent-orchestrator}/run/decision_offers.json}"
python3 - "$offers" "$resp" "$id" "$workspace" "$name" "$question" <<'PY'
import json, os, sys
offers_path, resp, tid, ws, name, question = sys.argv[1:7]
try:
    mid = json.loads(resp)["result"]["message_id"]
except Exception as e:
    print(f"[ask] could not read message_id ({e}) — no reply-routing", file=sys.stderr)
    sys.exit(0)
os.makedirs(os.path.dirname(offers_path), exist_ok=True)
try:
    with open(offers_path) as f:
        offers = json.load(f)
except (OSError, ValueError):
    offers = {}
offers[str(mid)] = {"task": tid, "workspace": ws, "name": name, "question": question}
if len(offers) > 200:   # cap: dict preserves insertion order → drop the oldest
    offers = dict(list(offers.items())[-200:])
tmp = offers_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(offers, f, indent=2)
os.replace(tmp, offers_path)
print(f"[ask] remembered decision offer msg {mid} -> task {tid}")
PY
