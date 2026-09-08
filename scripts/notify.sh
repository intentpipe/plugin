#!/usr/bin/env bash
# Notify the human — the single seam for human comms. Always prints; adds a
# macOS notification (Darwin), a Telegram message when creds are set, and
# (task 0071) the same text into Quorum's chat for the project — its
# feature channel when the text names one that resolves, its project chat
# otherwise. Tolerant by design: never fails its caller, on either leg.
set -euo pipefail
msg="${*:?usage: notify.sh <message>}"
echo "[notify] $msg"

if [ "$(uname)" = "Darwin" ]; then
  osascript -e "display notification \"${msg//\"/}\" with title \"Intentpipe\"" 2>/dev/null || true
fi

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/quorum_post.sh"

# Telegram + Quorum: shared bot/pipe creds from a global file, per-project
# topic/name from agents.env. All optional — missing creds or no workspace
# just means "print only".
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

# NOTIFY_SILENT suppresses both outbound legs (still prints + macOS notifies):
# a caller pairing notify with a richer own message (e.g. ask.sh's decision
# question, which fans into both channels itself) sets it so the human sees
# one message, not two, on either channel.
if [ -z "${NOTIFY_SILENT:-}" ]; then
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      ${TELEGRAM_TOPIC_ID:+--data-urlencode "message_thread_id=$TELEGRAM_TOPIC_ID"} \
      --data-urlencode "text=$msg" >/dev/null \
      || echo "[notify] telegram send failed" >&2
  fi
  feature="$(quorum_resolve_feature "$ws" "$msg" || true)"
  quorum_post "${PROJECT_NAME:-}" "$msg" "$feature"
fi
