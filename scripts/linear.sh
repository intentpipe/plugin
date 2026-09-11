#!/usr/bin/env bash
# Create a Linear issue for an approved plan. Deterministic — the plan skill
# supplies the title and checklist (judgment); this is the GraphQL mechanics.
# Usage: linear.sh create "<title>" "<markdown body>"
#   prints: <IDENTIFIER><TAB><url>   (e.g. ENG-123<TAB>https://linear.app/…)
# Opt-in: the skill only calls this when LINEAR_TEAM_KEY is set. Requires
# LINEAR_API_KEY (shared, in ~/.agent-orchestrator/linear.env or the env) and
# LINEAR_TEAM_KEY (per-project, in agents.env). Errors loudly, never a no-op.
# One-directional (plan → issue → PRs): no status sync back, no sub-issue per
# task — a drifting mirror of task state is worse than none. The key rides the
# feature slug (feature/eng-123-<slug>) so every PR auto-links via Linear's
# containment match, with zero change to task.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"   # → agents.env (LINEAR_TEAM_KEY)

linear_env="${LINEAR_ENV:-$HOME/.agent-orchestrator/linear.env}"
# shellcheck disable=SC1090
[ -f "$linear_env" ] && . "$linear_env"
: "${LINEAR_API_KEY:?LINEAR_API_KEY not set (put it in $linear_env)}"
: "${LINEAR_TEAM_KEY:?LINEAR_TEAM_KEY not set in agents.env}"
command -v jq >/dev/null || { echo "ERROR: linear.sh needs jq" >&2; exit 1; }

api() { # api <request-json> -> response body; personal keys go straight in the header
  curl -fsS https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    --data "$1"
}

cmd_create() {
  local title="${1:?usage: linear.sh create \"<title>\" \"<body>\"}" body="${2:-}"
  local q resp team_id ident url

  q='query($k:String!){teams(filter:{key:{eq:$k}}){nodes{id}}}'
  resp=$(api "$(jq -n --arg q "$q" --arg k "$LINEAR_TEAM_KEY" '{query:$q,variables:{k:$k}}')")
  team_id=$(echo "$resp" | jq -r '.data.teams.nodes[0].id // empty')
  [ -n "$team_id" ] || { echo "ERROR: no Linear team with key $LINEAR_TEAM_KEY — $resp" >&2; exit 1; }

  q='mutation($t:String!,$d:String!,$team:String!){issueCreate(input:{title:$t,description:$d,teamId:$team}){issue{identifier url}}}'
  resp=$(api "$(jq -n --arg q "$q" --arg t "$title" --arg d "$body" --arg team "$team_id" \
    '{query:$q,variables:{t:$t,d:$d,team:$team}}')")
  ident=$(echo "$resp" | jq -r '.data.issueCreate.issue.identifier // empty')
  url=$(echo "$resp" | jq -r '.data.issueCreate.issue.url // empty')
  [ -n "$ident" ] || { echo "ERROR: issueCreate failed — $resp" >&2; exit 1; }
  printf '%s\t%s\n' "$ident" "$url"
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  *) grep '^# Usage' "$0" | cut -c3-; exit 1 ;;
esac
