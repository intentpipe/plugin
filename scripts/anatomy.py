#!/usr/bin/env python3
"""Where a build session's time and tokens went — per agent, per round.

task.md's `Cost:` and `Timing:` fields are totals; a total cannot say which
agent, which round, or which wait consumed a task. This reads the Claude Code
transcripts the CLI writes for the session and splits the totals that way.

  ~/.claude/projects/<cwd-slug>/<session>.jsonl              orchestrator
  ~/.claude/projects/<cwd-slug>/<session>/subagents/*.jsonl  implementer, reviewer, Explore

One row per agent ROUND: a subagent transcript is split at every message the
orchestrator sent it (the first prompt, then each resume), since rounds differ
in cost and a per-agent sum would hide that. Rows carry:

  req      API requests (deduped on requestId — a resumed session copies its
           predecessor's history into the new file)
  ctx      context per request, first → max: the floor is what every turn re-pays
  tok      input-side tokens (fresh + cache read + cache write); 95% is cache read
  rewarm   cache-write tokens spent re-uploading an already-seen context after
           the agent idled past the cache TTL — pure waste, caused by the idle
  $        API-equivalent at tokens.py's rates (a subscription bills nothing per
           token; the $ only weights a cache read against an output token)
  wall     first event → last event of the round
  model    time waiting on the model; tools: time waiting on tool calls
  idle     the gap between this round's end and the next resume message —
           time the agent sat stopped while the orchestrator waited on it

Plus the longest tool calls (a 600s `sleep` loop shows up here, an Agent call
does not — its duration is its child's row) and every verify.sh invocation
with who ran it and how long it took.

loop.sh runs this after each task's session(s) and writes tasks/<id>/anatomy.md
plus a one-line `Anatomy:` field in task.md. By hand:

  anatomy.py --cwd /path/to/project --session <id> [<id>...]
  anatomy.py --task-dir intentpipe/tasks/0072-…   (reads Session: from task.md)
  add --compact for the one-liner only.

Pure stdlib; tolerant — a missing transcript prints a one-line note and exits 0
so a hook never fails its caller.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

# Overridable so a test can plant a fixture transcript outside ~/.claude.
ROOT = os.environ.get("INTENTPIPE_TRANSCRIPTS") or os.path.expanduser("~/.claude/projects")

# $ per 1M (base input, output). Mirrors orchestrator/system-scripts/tokens.py —
# the cross-project report — so a task's per-agent $ adds up to what the daily
# report says. Unknown ids fall back to opus-class, never to zero.
PRICES = {
    "claude-opus-5": (5.0, 25.0),
    "claude-opus-4-8": (5.0, 25.0),
    "claude-opus-4-7": (5.0, 25.0),
    "claude-opus-4-6": (5.0, 25.0),
    "claude-fable-5": (10.0, 50.0),
    "claude-sonnet-5": (3.0, 15.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5": (1.0, 5.0),
}
FALLBACK = (5.0, 25.0)
CACHE_READ, CACHE_WRITE_5M, CACHE_WRITE_1H = 0.10, 1.25, 2.00


def cost(model, u):
    inp, out = PRICES.get(model, FALLBACK)
    cc = u.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    w5m = cc.get("ephemeral_5m_input_tokens", 0)
    if not (w1h or w5m):
        w5m = u.get("cache_creation_input_tokens", 0)
    return ((u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) * CACHE_READ) * inp
            + (w5m * CACHE_WRITE_5M + w1h * CACHE_WRITE_1H) * inp
            + u.get("output_tokens", 0) * out) / 1e6


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def slug(cwd):
    # Claude Code names the transcript dir after the cwd with every non-alnum
    # character replaced: /home/agent/projects/x → -home-agent-projects-x
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(cwd))


def short_model(m):
    m = m or "?"
    for k in ("opus", "sonnet", "fable", "haiku"):
        if k in m:
            return k
    return m


def short_agent(meta):
    a = meta.get("agentType") or "subagent"
    return a.split(":")[-1]


def load(path):
    ev = []
    for line in open(path, errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("timestamp") and d.get("type") in ("assistant", "user"):
            ev.append(d)
    ev.sort(key=lambda e: e["timestamp"])
    return ev


def is_resume(e):
    """A user message that is a prompt, not a tool result — the orchestrator's
    first prompt or a SendMessage. The harness's own "produce a visible
    response" nudge is a continuation, not a round."""
    c = e["message"].get("content")
    if isinstance(c, str):
        text = c
    elif isinstance(c, list) and c and all(b.get("type") == "text" for b in c):
        text = c[0].get("text", "")
    else:
        return False
    return not text.startswith("[Your previous response")


def rounds(ev, label, seen, src=""):
    """Split one transcript into rounds; returns a list of row dicts and
    appends every tool call to `calls` for the longest-calls list."""
    rows, calls = [], []
    cur = None
    pending = {}
    last_t = None
    for e in ev:
        t = ts(e["timestamp"])
        if e["type"] == "user" and is_resume(e):
            # Two prompts in a row (the /build command row, then its expanded
            # skill text) are one round: split only after the round did work.
            if cur and cur["req"]:
                cur["end"] = last_t
                rows.append(cur)
            elif cur:
                cur["start"] = t
                last_t = t
                continue
            cur = {"label": label, "src": src, "round": len(rows) + 1, "start": t, "end": t, "req": 0,
                   "tok": 0, "cr": 0, "cw": 0, "out": 0, "rewarm": 0, "cost": 0.0,
                   "ctx0": None, "ctxmax": 0, "model": None, "llm": 0.0, "tool": 0.0,
                   "models": {}}
            last_t = t
            continue
        if cur is None:  # transcript without a leading prompt — treat as one round
            cur = {"label": label, "src": src, "round": 1, "start": t, "end": t, "req": 0, "tok": 0,
                   "cr": 0, "cw": 0, "out": 0, "rewarm": 0, "cost": 0.0, "ctx0": None,
                   "ctxmax": 0, "model": None, "llm": 0.0, "tool": 0.0, "models": {}}
        m = e["message"]
        if e["type"] == "assistant":
            u = m.get("usage")
            rid = e.get("requestId") or m.get("id")
            if u and m.get("model") != "<synthetic>" and rid not in seen:
                seen.add(rid)
                ctx = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                       + u.get("cache_creation_input_tokens", 0))
                cw = u.get("cache_creation_input_tokens", 0)
                cur["req"] += 1
                cur["tok"] += ctx
                cur["cr"] += u.get("cache_read_input_tokens", 0)
                cur["cw"] += cw
                cur["out"] += u.get("output_tokens", 0)
                cur["cost"] += cost(m.get("model"), u)
                # A cache write covering most of the context on any request but
                # the transcript's first is the prefix being re-uploaded: the
                # agent idled past the cache TTL (5 min) and paid for what it had
                # already paid for.
                if cur["ctx0"] is not None or rows:
                    if ctx and cw > 0.5 * ctx:
                        cur["rewarm"] += cw
                if cur["ctx0"] is None:
                    cur["ctx0"] = ctx
                cur["ctxmax"] = max(cur["ctxmax"], ctx)
                mm = short_model(m.get("model"))
                cur["models"][mm] = cur["models"].get(mm, 0) + 1
                if last_t:
                    cur["llm"] += (t - last_t).total_seconds()
            for b in m.get("content", []) if isinstance(m.get("content"), list) else []:
                if b.get("type") == "tool_use":
                    i = b.get("input") or {}
                    desc = i.get("command") or i.get("description") or i.get("file_path") \
                        or i.get("pattern") or i.get("summary") or ""
                    full = str(desc).replace("\n", " ")
                    desc = full[:90]
                    if name_is_bg(i):
                        desc += " (backgrounded)"
                    pending[b["id"]] = (t, b["name"], desc, b["name"] == "Bash" and is_verify_call(full))
        else:
            c = m.get("content")
            if isinstance(c, list):
                for b in c:
                    if b.get("type") == "tool_result" and b.get("tool_use_id") in pending:
                        t0, name, desc, is_verify = pending.pop(b["tool_use_id"])
                        secs = (t - t0).total_seconds()
                        cur["tool"] += secs
                        body = json.dumps(b.get("content"))
                        note = ""
                        mo = re.search(r"did not complete within its (\d+)s timeout", body)
                        if mo:
                            # The harness moved it to the background at its Bash
                            # timeout (120s unless the call set one); the agent
                            # went on without the result.
                            note = f" ← hit the {mo.group(1)}s Bash timeout, moved to background"
                        elif "timed out" in body.lower():
                            note = " ← timed out"
                        elif b.get("is_error"):
                            note = " ← error"
                        calls.append((secs, label, cur["round"], name, desc, note, is_verify))
        last_t = t
        cur["end"] = t
    if cur:
        rows.append(cur)
    for r in rows:
        r["model"] = max(r["models"], key=r["models"].get) if r["models"] else "?"
    return rows, calls


VERIFY_RE = re.compile(r"(?:^|[;&|(]\s*|\bnohup\s+)\S*/verify\.sh(?:\s|$)")


def is_verify_call(desc):
    """The command RUNS verify.sh — not a grep for it, not a pgrep loop."""
    return bool(VERIFY_RE.search(desc))


def name_is_bg(i):
    cmd = i.get("command") or ""
    return bool(i.get("run_in_background")) or "nohup " in cmd or re.search(r"&\s*(echo|$)", cmd) is not None


def fmt_dur(s):
    s = int(round(s))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s // 3600}h{s % 3600 // 60:02d}m"


def fmt_tok(n):
    return f"{n / 1e6:.1f}M" if n >= 1e6 else f"{n / 1e3:.0f}k"


def analyze(cwd, sessions):
    d = os.path.join(ROOT, slug(cwd))
    seen = set()
    rows, calls = [], []
    found = 0
    for sid in sessions:
        main = os.path.join(d, sid + ".jsonl")
        if not os.path.exists(main):
            continue
        found += 1
        r, c = rounds(load(main), "orchestrator", seen)
        rows += r
        calls += c
        subs = sorted(glob.glob(os.path.join(d, sid, "subagents", "*.jsonl")),
                      key=lambda p: os.path.getmtime(p))
        for p in subs:
            try:
                meta = json.load(open(p.replace(".jsonl", ".meta.json")))
            except (OSError, ValueError):
                meta = {}
            ev = load(p)
            if not ev:
                continue
            r, c = rounds(ev, short_agent(meta), seen, src=p)
            rows += r
            calls += c
    subs = [r for r in rows if r["label"] != "orchestrator"]
    # idle = the wait between one round's last event and the agent's next
    # resume, minus any other subagent running meanwhile (a reviewer round
    # between implementer rounds is work, not idle): what is left is the agent
    # stopped and the orchestrator waiting on it.
    for a in subs:
        nxt = [b for b in subs if b["src"] == a["src"] and b["start"] > a["end"]]
        if not nxt:
            continue
        b = min(nxt, key=lambda x: x["start"])
        gap = (b["start"] - a["end"]).total_seconds()
        for o in subs:
            if o["src"] == a["src"]:
                continue
            lo, hi = max(o["start"], a["end"]), min(o["end"], b["start"])
            if hi > lo:
                gap -= (hi - lo).total_seconds()
        a["idle"] = max(gap, 0)
    if not found:
        return None, None
    # Sort rows by start so the table reads as a timeline
    rows.sort(key=lambda r: r["start"])
    return rows, calls


def render(rows, calls, compact_only=False):
    tot_tok = sum(r["tok"] for r in rows)
    tot_cost = sum(r["cost"] for r in rows)
    tot_req = sum(r["req"] for r in rows)
    t0 = min(r["start"] for r in rows)
    t1 = max(r["end"] for r in rows)
    span = (t1 - t0).total_seconds()
    idle = sum(r.get("idle", 0) for r in rows)
    span_sub = sum((r["end"] - r["start"]).total_seconds() for r in rows if r["label"] != "orchestrator")
    rewarm = sum(r["rewarm"] for r in rows)
    multi = {r["label"] for r in rows if r["round"] > 1}

    def who(lab, rnd):
        return f"{lab} r{rnd}" if lab in multi else lab
    # compact: one entry per agent kind, rounds summed
    by = {}
    for r in rows:
        a = by.setdefault(r["label"], {"model": r["model"], "req": 0, "tok": 0, "cost": 0.0,
                                       "wall": 0.0, "idle": 0.0, "rounds": 0})
        a["req"] += r["req"]
        a["tok"] += r["tok"]
        a["cost"] += r["cost"]
        a["wall"] += (r["end"] - r["start"]).total_seconds()
        a["idle"] += r.get("idle", 0)
        a["rounds"] += 1
    parts = []
    for name, a in by.items():
        s = f"{name} {a['model']} {a['req']}req {fmt_tok(a['tok'])} ${a['cost']:.2f} {fmt_dur(a['wall'])}"
        if a["rounds"] > 1:
            s += f" ×{a['rounds']}"
        if a["idle"] >= 60:
            s += f" (idle {fmt_dur(a['idle'])})"
        parts.append(s)
    verify = [c for c in calls if c[6]]

    if verify:
        parts.append(f"verify.sh ×{len(verify)}")
    compact = " · ".join(parts)
    if compact_only:
        return compact
    out = []
    out.append(f"# Anatomy — {fmt_dur(span)} wall · {tot_req} requests · {fmt_tok(tot_tok)} tokens · ~${tot_cost:.2f} API-equiv")
    out.append(f"subagents active {fmt_dur(span_sub)} · idle {fmt_dur(idle)} (a subagent stopped, orchestrator waiting on it) · rewarm {fmt_tok(rewarm)} tokens re-uploaded after idling")
    out.append("")
    out.append("| agent | model | start | wall | req | ctx first→max | tok | rewarm | $ | model-wait | tool-wait | idle after |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        lab = r["label"] + (f" r{r['round']}" if r["label"] in multi else "")
        out.append("| {} | {} | {} | {} | {} | {}→{} | {} | {} | {:.2f} | {} | {} | {} |".format(
            lab, r["model"], r["start"].strftime("%H:%M:%S"),
            fmt_dur((r["end"] - r["start"]).total_seconds()), r["req"],
            fmt_tok(r["ctx0"] or 0), fmt_tok(r["ctxmax"]), fmt_tok(r["tok"]),
            fmt_tok(r["rewarm"]) if r["rewarm"] else "-", r["cost"],
            fmt_dur(r["llm"]), fmt_dur(r["tool"]),
            fmt_dur(r["idle"]) if r.get("idle", 0) >= 5 else "-"))
    out.append("")
    longest = sorted((c for c in calls if c[3] not in ("Agent", "SendMessage")), reverse=True)[:8]
    if longest:
        out.append("Longest tool calls:")
        for secs, lab, rnd, name, desc, note, _ in longest:
            if secs < 20:
                break
            out.append(f"- {fmt_dur(secs):>7} {who(lab, rnd)} {name}: `{desc}`{note}")
        out.append("")
    if verify:
        out.append(f"verify.sh invocations ({len(verify)}):")
        for secs, lab, rnd, name, desc, note, _ in verify:
            out.append(f"- {fmt_dur(secs):>7} {who(lab, rnd)}: `{desc}`{note}")
        out.append("")
    out.append(f"compact: {compact}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cwd", help="project dir the session ran in (default: parent of --task-dir's workspace, else $PWD)")
    ap.add_argument("--session", nargs="*", default=[], help="session id(s) — every attempt of the task")
    ap.add_argument("--task-dir", help="read `Session:` from this task folder's task.md")
    ap.add_argument("--compact", action="store_true", help="one line only")
    a = ap.parse_args()
    sessions = list(a.session)
    cwd = a.cwd
    if a.task_dir:
        md = os.path.join(a.task_dir, "task.md")
        try:
            for line in open(md):
                if line.startswith("Session:"):
                    sessions += [s for s in line.split(":", 1)[1].split() if s != "-"]
        except OSError:
            pass
        if not cwd:
            # tasks/<id>/ → tasks → intentpipe/ → project
            cwd = os.path.abspath(os.path.join(a.task_dir, "..", "..", ".."))
    cwd = cwd or os.getcwd()
    if not sessions:
        print("anatomy: no session id (pass --session or a task.md with Session:)")
        return 0
    rows, calls = analyze(cwd, sessions)
    if not rows:
        print(f"anatomy: no transcript for {' '.join(sessions)} under {os.path.join(ROOT, slug(cwd))}")
        return 0
    print(render(rows, calls, a.compact))
    return 0


if __name__ == "__main__":
    sys.exit(main())
