# Intentpipe repo (plugin development)

You are editing intentpipe itself, not using it. The reason for every non-obvious behavior is a comment next to the line that implements it — read it before changing the line, and when you add a non-obvious line, put its why beside it.

Rules:
- Concision is a feature: agent/skill prompts earn every line ("would removing this cause a mistake?"). CLAUDE.mds < 200 lines.
- Mechanics belong in `scripts/` (deterministic), judgment in `agents/`/`skills/` (LLM). Never move logic from script to prompt.
- After editing scripts: `bash -n` them and run the smoke test in `tests/smoke.sh`.
- Changes motivated by a project retro should reference the proposal file in the commit message.
- Bump `version` in `.claude-plugin/plugin.json` on behavior changes.
