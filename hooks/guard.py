#!/usr/bin/env python3
"""PreToolUse guard: deterministic safety rails.
Blocks: force-push, destructive rm, any write to a CLAUDE.md (code is ground truth;
orientation lives in agent memory — INTENTPIPE_ALLOW_CLAUDE_MD=1 for a deliberate human
edit), and any edit to the intentpipe plugin itself
(self-modification must go through /intentpipe:retro proposals). Under DONE=pr
it also blocks pushing the default branch — see PR_MODE_DENY.
Exempt: dev sessions — when the session cwd is inside the plugin root, the
plugin is the thing being developed, not used, so edits are allowed.
Exit 2 = block (stderr goes to the agent). Exit 0 = allow.
"""
import json
import os
import re
import sys

CLAUDE_MD_REASON = ("CLAUDE.md is read-only for the pipeline: code is ground truth, and a module map "
                    "in a file is re-paid by every session on every turn. Put orientation in agent "
                    "memory. A human editing on purpose sets INTENTPIPE_ALLOW_CLAUDE_MD=1.")


def claude_md_allowed() -> bool:
    return os.environ.get("INTENTPIPE_ALLOW_CLAUDE_MD") == "1"


BASH_DENY = [
    (r"git\s+push\b.*(\s--force\b|\s-f\b|\+\S+:)", "force-push is forbidden"),
    (r"rm\s+(-\w*[rf]\w*\s+)+(/|~|\$HOME)(\s|$)", "destructive rm on / or ~ is forbidden"),
    (r"git\s+checkout\s+.*--\s+\.", "wholesale checkout-discard is forbidden; revert specific files"),
    (r"rm\s+(-\S+\s+)*\S*\bupdates/?['\"]?(\s|$)", "deleting the updates/ folder is forbidden; remove only the note files you planned — the folder and its README stay"),
    (r"rm\s+(-\S+\s+)*\S*\bupdates/\*", "wildcard rm in updates/ is forbidden (it takes README.md with it); remove planned note files by name"),
    (r"(>>?|\btee\b(\s+-a)?)\s*\S*\bCLAUDE\.md\b", CLAUDE_MD_REASON),
    (r"\bsed\s+(-\S+\s+)*-i\b.*\bCLAUDE\.md\b", CLAUDE_MD_REASON),
]

# Only under DONE=pr, where the platform is the merge arbiter (DESIGN #18): a
# hand-push of the default branch there lands work that skipped review. Under
# DONE=local the pipeline publishes that branch itself (publish.sh, #42), so
# pushing it is the normal flow, not an offence.
PR_MODE_DENY = [
    # main/master must be the ref being pushed — a whole argument, or the right
    # half of a `HEAD:main` refspec. `\b(main|master)\b` also fired on
    # `feat/master-fix` and, worse, on a `gh pr create --base master` chained
    # after a perfectly good task-branch push.
    (r"git\s+push\b.*(\s|:)(refs/heads/)?(main|master)(\s|:|$)",
     "under DONE=pr, pushing the default branch is forbidden; work on the task branch, task.sh opens the PR"),
]

# One command line is usually several commands. Scanning it as one string lets a
# later command incriminate an earlier one — `git push origin task/x && gh pr
# create --base master` is a legal push and a legal PR, but `git push.*master`
# reads straight across the `&&` and blocks it. Match per segment instead, so a
# pattern only ever sees the command it is about. This cannot hide a real
# offender: splitting only ever puts MORE boundaries around it.
SEPARATORS = re.compile(r"&&|\|\||[;\n|]")


def segments(cmd: str):
    return [s for s in SEPARATORS.split(cmd) if s.strip()]


def done_mode(cwd: str) -> str:
    """DONE from the workspace's agents.env — lib.sh's find_workspace walk, in
    Python. No workspace (a plugin dev session, a stray dir) means lib.sh's own
    default: local."""
    d = os.path.realpath(cwd)
    while True:
        for env in (os.path.join(d, "agents.env"), os.path.join(d, "intentpipe", "agents.env")):
            if os.path.isfile(env):
                mode = "local"
                try:
                    with open(env) as fh:
                        for line in fh:
                            m = re.match(r"\s*(?:export\s+)?DONE\s*=\s*[\"']?(\w+)", line)
                            if m:
                                mode = m.group(1).lower()
                except OSError:
                    pass
                return mode
        parent = os.path.dirname(d)
        if parent == d:
            return "local"
        d = parent


def deny(reason: str) -> None:
    print(f"BLOCKED by intentpipe guard: {reason}", file=sys.stderr)
    sys.exit(2)

def main() -> None:
    data = json.load(sys.stdin)
    tool = data.get("tool_name", "")
    tin = data.get("tool_input", {})

    cwd = data.get("cwd") or os.getcwd()

    if tool == "Bash":
        rules = [r for r in BASH_DENY if r[1] != CLAUDE_MD_REASON or not claude_md_allowed()]
        rules += PR_MODE_DENY if done_mode(cwd) == "pr" else []
        for seg in segments(tin.get("command", "")):
            for pattern, reason in rules:
                if re.search(pattern, seg):
                    deny(reason)

    if tool in ("Write", "Edit", "NotebookEdit"):
        if os.path.basename(tin.get("file_path", "")) == "CLAUDE.md" and not claude_md_allowed():
            deny(CLAUDE_MD_REASON)
        plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
        if plugin_root:
            root = os.path.realpath(plugin_root)
            here = os.path.realpath(cwd)
            dev_session = here == root or here.startswith(root + os.sep)
            path = os.path.realpath(tin.get("file_path", ""))
            if not dev_session and path.startswith(root + os.sep):
                deny("the intentpipe plugin is read-only inside projects; use /intentpipe:retro to propose changes")

    sys.exit(0)

if __name__ == "__main__":
    main()
