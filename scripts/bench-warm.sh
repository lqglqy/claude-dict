#!/bin/bash
# Warm-path latency through the real app code: snapshot mode waits 8s for the spare, then looks up.
# Prints the status line (model, time to first token, total). Run scripts/build.sh first.
set -u
cd "$(dirname "$0")/.."
B=build/ClaudeDict.app/Contents/MacOS/ClaudeDict
OUT="${TMPDIR:-/tmp}/claudedict-bench"
mkdir -p "$OUT"
run() { # action name text
  local line
  line=$("$B" --snapshot "$1" "$OUT/$2.png" --warm-wait 8 "$3" 2>&1 | head -1)
  echo "$1 [$3] -> ${line#*status=}"
}
for i in 1 2 3; do run translate "word$i" "ubiquitous"; done
for i in 1 2; do run translate "sentence$i" "Had I known the meeting would be moved, I would have prepared the slides earlier."; done
for i in 1 2; do run polish "polish$i" "I want discuss with you about the plan in tomorrow meeting."; done
echo "claude spares left running: $(pgrep -f 'engine of ClaudeDict' | wc -l | tr -d ' ')"
echo "snapshots in $OUT"
