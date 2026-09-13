#!/usr/bin/env bash
# Best-effort fan-out into Quorum chat — the plugin-side twin of the
# orchestrator's quorum_report.py (task 0071). Sourced by notify.sh and
# ask.sh; defines functions only, never executes anything on its own.
#
# Config lives beside the Telegram block, in the same box-wide file:
# QUORUM_CHAT_URL + QUORUM_PIPE_TOKEN (the dedicated `pipe` account's minted
# token — never the shared Telegram creds, so the chat service attributes
# every post here to that account, not whatever a body might claim).

# The feature slug `text` names and that resolves within workspace `ws`
# (`tasks/_features/<slug>.md` must exist there), or nothing at all — named
# either directly ("feature <slug>") or through a task ("task <id>",
# resolved via that task's own `Feature:` line). Mirrors the orchestrator's
# quorum_report.resolve_feature so both halves of the seam agree on what
# "names a feature" means.
quorum_resolve_feature() { # ws text
  local ws="$1" text="$2" slug tid
  [ -z "$ws" ] && return 1
  # No \b here: bash's [[ =~ ]] regex engine does not honor it inside a
  # bracket-adjacent group the way PCRE does, so the boundary is spelled out
  # as "start of string, or a non-word character" instead.
  if [[ "$text" =~ (^|[^[:alnum:]])[Ff]eature[[:space:]]+([a-zA-Z][a-zA-Z0-9-]*) ]]; then
    slug="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
    [ -f "$ws/tasks/_features/$slug.md" ] && { printf '%s' "$slug"; return 0; }
    return 1
  fi
  if [[ "$text" =~ (^|[^[:alnum:]])[Tt]ask[[:space:]]+([0-9]+) ]]; then
    tid="${BASH_REMATCH[2]}"
    quorum_feature_for_task "$ws" "$tid"
    return $?
  fi
  return 1
}

# The Feature: slug task `id`'s task.md names within `ws`, only once that
# slug's own tasks/_features/<slug>.md also exists — the same pairing
# quorum_report.py's feature_for_task + known_feature does together.
quorum_feature_for_task() { # ws id
  local ws="$1" id="$2" tmd slug
  [ -z "$ws" ] && return 1
  tmd=$(ls -d "$ws"/tasks/"$id"-*/task.md 2>/dev/null | head -1)
  [ -z "$tmd" ] && return 1
  slug=$(grep "^Feature:" "$tmd" 2>/dev/null | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  { [ -z "$slug" ] || [ "$slug" = "-" ]; } && return 1
  [ -f "$ws/tasks/_features/$slug.md" ] || return 1
  printf '%s' "$slug"
}

# Fan `text` into Quorum's chat for `project` — its feature channel when
# `feature` is given, its project chat otherwise. Silent no-op without
# QUORUM_CHAT_URL/QUORUM_PIPE_TOKEN/project; never raises and always returns
# 0, so a caller's Telegram leg (already sent, or already decided not to be)
# is never affected by a Quorum outage.
quorum_post() { # project text [feature]
  local project="$1" text="$2" feature="${3:-}" url body
  [ -n "${QUORUM_CHAT_URL:-}" ] || return 0
  [ -n "${QUORUM_PIPE_TOKEN:-}" ] || return 0
  [ -n "$project" ] || return 0
  if [ -n "$feature" ]; then
    url="${QUORUM_CHAT_URL%/}/v1/chat/features/$project/$feature/messages"
  else
    url="${QUORUM_CHAT_URL%/}/v1/chat/projects/$project/messages"
  fi
  body="$(python3 -c 'import json,sys; print(json.dumps({"kind": "text", "text": sys.argv[1]}))' "$text")"
  curl -fsS "$url" \
    -H "Authorization: Bearer $QUORUM_PIPE_TOKEN" -H "Content-Type: application/json" \
    --data-binary "$body" >/dev/null \
    || echo "[quorum] post to $project failed (non-fatal)" >&2
  return 0
}

# Task 0072: the twin of quorum_post for a decision gate — a `decision_request`
# message carrying the task id and the bare question (never the Telegram-shaped
# text quorum_post sends), so the app can render a real card with a reply box
# and answer through the control plane's own decision endpoint. Same silent,
# never-raising, always-0 tolerance.
quorum_post_decision() { # project task_id question [feature]
  local project="$1" task_id="$2" question="$3" feature="${4:-}" url body
  [ -n "${QUORUM_CHAT_URL:-}" ] || return 0
  [ -n "${QUORUM_PIPE_TOKEN:-}" ] || return 0
  [ -n "$project" ] || return 0
  if [ -n "$feature" ]; then
    url="${QUORUM_CHAT_URL%/}/v1/chat/features/$project/$feature/messages"
  else
    url="${QUORUM_CHAT_URL%/}/v1/chat/projects/$project/messages"
  fi
  body="$(python3 -c 'import json,sys; print(json.dumps({"kind": "decision_request", "task_id": sys.argv[1], "question": sys.argv[2]}))' "$task_id" "$question")"
  curl -fsS "$url" \
    -H "Authorization: Bearer $QUORUM_PIPE_TOKEN" -H "Content-Type: application/json" \
    --data-binary "$body" >/dev/null \
    || echo "[quorum] decision post to $project failed (non-fatal)" >&2
  return 0
}
