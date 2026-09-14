---
name: init-project
description: Bootstrap the current directory as a intentpipe workspace (control repo + code repos as subdirectories).
disable-model-invocation: true
---

Set up the current directory as a workspace. Templates: `${CLAUDE_PLUGIN_ROOT}/templates/`.

1. Interview the user (AskUserQuestion): project name; the code repos (existing URLs to clone, existing local dirs to move in, or new ones to create — each a top-level directory of the project root, never the root itself); each repo's verify command (build + lint + test in one line; for an existing repo propose one from its CI config, e.g. `.github/workflows`, and confirm); default branch; how finished tasks land — `DONE=local` (squash-merge) or `DONE=pr` (push branch + GitHub PR; needs `gh` authenticated).
2. Layout — repos and intentpipe state are siblings under the project root. Create `intentpipe/` with `agents.env` (from template, filled; repo paths relative to it, e.g. `REPO_backend=../backend`), `updates/README.md` (from `templates/updates-README.md`), `tasks/_log.md`. Create at the root: `CLAUDE.md` (from CLAUDE.template.md), `.gitignore` (repo dirs + template entries), `.claude/settings.json` enabling this plugin: `{"enabledPlugins": {"intentpipe@intentpipe": true}}`.
3. Clone/create the repos. A new repo gets git init, the default branch, a minimal toolchain that makes the verify command pass on empty code, and one initial commit.
4. `git init` the project root and commit the state files (repo dirs stay ignored — each is its own git repo).
5. Run `${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh`; it must print PREFLIGHT OK. Fix or report anything red.
6. Tell the user: drop a first note in `intentpipe/updates/` describing what to build, run `/intentpipe:plan`, then `/intentpipe:build all` (or `scripts/loop.sh` headless); a later change is another note plus `/intentpipe:plan`.
