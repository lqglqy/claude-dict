#!/usr/bin/env python3
"""Spawn a spare, report its RSS (incl. children) while idle, then use it after a long idle."""
import json, os, subprocess, sys, time

CLAUDE = os.path.expanduser(os.environ.get("CLAUDE_BIN", "~/.local/bin/claude"))
idle = float(sys.argv[1]) if len(sys.argv) > 1 else 60
env = dict(os.environ)
for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
    env.pop(k, None)
args = [CLAUDE, "-p", "--model", "haiku", "--system-prompt", "Output only the result.",
        "--tools", "", "--no-session-persistence", "--safe-mode", "--input-format", "stream-json",
        "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                     env=env, cwd=os.environ.get("PROBE_CWD", os.getcwd()))

def tree_rss(pid):
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss=,comm="], capture_output=True, text=True).stdout
    rows = [l.split(None, 3) for l in out.strip().splitlines()]
    kids = {pid}
    changed = True
    while changed:
        changed = False
        for r in rows:
            if int(r[1]) in kids and int(r[0]) not in kids:
                kids.add(int(r[0])); changed = True
    return sum(int(r[2]) for r in rows if int(r[0]) in kids), len(kids)

time.sleep(5)
rss, n = tree_rss(p.pid)
print(f"after 5s idle: rss={rss/1024:.0f} MB across {n} process(es)")
time.sleep(max(0, idle - 5))
rss, n = tree_rss(p.pid)
print(f"after {idle:.0f}s idle: rss={rss/1024:.0f} MB, alive={p.poll() is None}")
msg = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "Translate into Simplified Chinese: serendipity"}]}}
t0 = time.time()
p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush(); p.stdin.close()
first = None; text = []
for line in p.stdout:
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("type") == "stream_event" and ev["event"].get("type") == "content_block_delta":
        d = ev["event"]["delta"]
        if d.get("type") == "text_delta":
            first = first or time.time() - t0
            text.append(d["text"])
    if ev.get("type") == "result":
        print("result subtype:", ev.get("subtype"), "is_error:", ev.get("is_error"), "cost:", ev.get("total_cost_usd"))
p.wait()
print(f"rc={p.returncode} first_text={first and round(first,2)}s total={time.time()-t0:.2f}s text={''.join(text)!r}")
