#!/usr/bin/env python3
"""Measure claude -p startup, time-to-first-token and total time for one prompt."""
import json, os, subprocess, sys, time

CLAUDE = os.path.expanduser(os.environ.get("CLAUDE_BIN", "~/.local/bin/claude"))
model = sys.argv[1] if len(sys.argv) > 1 else "haiku"
extra = sys.argv[2:]
env = dict(os.environ)
for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
    env.pop(k, None)

args = [CLAUDE, "-p", "--model", model,
        "--system-prompt", "You translate English into natural Simplified Chinese. Output only the translation.",
        "--tools", "", "--no-session-persistence",
        "--output-format", "stream-json", "--include-partial-messages", "--verbose", *extra,
        "The quick brown fox jumps over the lazy dog, but the dog couldn't care less."]
t0 = time.time()
p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                     cwd=os.environ.get("PROBE_CWD", os.getcwd()))
first_line = first_delta = None
text = []
types = {}
for line in p.stdout:
    now = time.time() - t0
    if first_line is None:
        first_line = now
    try:
        ev = json.loads(line)
    except Exception:
        continue
    key = ev.get("type", "?") + ("/" + ev["event"]["type"] if ev.get("type") == "stream_event" else "")
    types[key] = types.get(key, 0) + 1
    if ev.get("type") == "stream_event":
        e = ev["event"]
        if e.get("type") == "content_block_delta" and e["delta"].get("type") == "text_delta":
            if first_delta is None:
                first_delta = now
            text.append(e["delta"]["text"])
    if ev.get("type") == "result":
        result = ev
p.wait()
total = time.time() - t0
err = p.stderr.read()
print(f"model={model} extra={extra} rc={p.returncode}")
print(f"first_line={first_line:.2f}s first_text_delta={first_delta if first_delta is None else round(first_delta,2)}s total={total:.2f}s")
print("text:", "".join(text))
print("event types:", types)
if err.strip():
    print("stderr:", err.strip()[:500])
