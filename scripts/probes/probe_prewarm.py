#!/usr/bin/env python3
"""Spawn claude -p with stream-json input, idle for a while, then send one message.
Measures latency from the moment the message is written (what a pre-warmed spare would give)."""
import json, os, subprocess, sys, time

CLAUDE = os.path.expanduser(os.environ.get("CLAUDE_BIN", "~/.local/bin/claude"))
model = sys.argv[1] if len(sys.argv) > 1 else "haiku"
idle = float(sys.argv[2]) if len(sys.argv) > 2 else 6
extra = sys.argv[3:]
env = dict(os.environ)
for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
    env.pop(k, None)

args = [CLAUDE, "-p", "--model", model,
        "--system-prompt", "You are an English assistant. Follow the task in the user message. Output only the result.",
        "--tools", "", "--no-session-persistence", "--safe-mode",
        "--input-format", "stream-json",
        "--output-format", "stream-json", "--include-partial-messages", "--verbose", *extra]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                     env=env, cwd=os.environ.get("PROBE_CWD", os.getcwd()))
time.sleep(idle)
msg = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text":
       "Translate into Simplified Chinese: The quick brown fox jumps over the lazy dog, but the dog couldn't care less."}]}}
t0 = time.time()
p.stdin.write(json.dumps(msg) + "\n")
p.stdin.flush()
p.stdin.close()
first_delta = None
text = []
for line in p.stdout:
    now = time.time() - t0
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("type") == "stream_event":
        e = ev["event"]
        if e.get("type") == "content_block_delta" and e["delta"].get("type") == "text_delta":
            if first_delta is None:
                first_delta = now
            text.append(e["delta"]["text"])
p.wait()
total = time.time() - t0
print(f"model={model} idle={idle}s extra={extra} rc={p.returncode} first_text_after_write={first_delta if first_delta is None else round(first_delta,2)}s total_after_write={total:.2f}s")
print("text:", "".join(text))
err = p.stderr.read().strip()
if err:
    print("stderr:", err[:400])
