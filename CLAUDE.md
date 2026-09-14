# Intentpipe repo (plugin development)

You are editing intentpipe itself, not using it. In `scripts/`, the reason for every non-obvious line is a comment beside it — read it before changing the line, and when you add one, put its why beside it. In `agents/` and `skills/` the model re-reads every word on every request: prompts state rules only — no reasons, no incident history, no description of mechanisms the model does not act on. The why goes in the commit message.

Rules:
- Concision is a feature: agent/skill prompts earn every line ("would removing this cause a mistake?"). CLAUDE.mds < 200 lines.
- Mechanics belong in `scripts/` (deterministic), judgment in `agents/`/`skills/` (LLM). Never move logic from script to prompt.
- After editing scripts: `bash -n` them and run the smoke test in `tests/smoke.sh`.
- Changes motivated by a project retro should reference the proposal file in the commit message.
- Bump `version` in `.claude-plugin/plugin.json` on behavior changes.
