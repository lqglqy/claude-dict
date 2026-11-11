#!/bin/bash
# Fake `claude` CLI for engine tests. Speaks the same stream-json protocol as `claude -p`.
# FAKE_CLAUDE_MODE: ok (default) | error | crash | slow | noresult
# FAKE_CLAUDE_CAPTURE: file that receives the stdin message line.
if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi

model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift ;;
  esac
  shift
done

# "dieearly": fails at start-up before any message arrives (like a logged-out CLI).
if [ "${FAKE_CLAUDE_MODE:-}" = "dieearly" ]; then
  echo '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}'
  exit 1
fi

# "stubborn": ignores SIGTERM and lingers after stdin closes, like a slow shutdown.
if [ "${FAKE_CLAUDE_MODE:-}" = "stubborn" ]; then
  trap '' TERM
  IFS= read -r line
  sleep 5
  exit 0
fi

# Like the real CLI: stdin closed before any message means exit quietly.
IFS= read -r line || exit 0
if [ -n "$FAKE_CLAUDE_CAPTURE" ]; then printf '%s\n' "$line" > "$FAKE_CLAUDE_CAPTURE"; fi

echo '{"type":"system","subtype":"init","model":"fake-'"$model"'","tools":[]}'
case "${FAKE_CLAUDE_MODE:-ok}" in
  ok)
    echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}}'
    sleep 0.05
    echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"你好, world"}]}}'
    echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"你好, world","duration_ms":12,"total_cost_usd":0.0001}'
    ;;
  error)
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Model not found: no-such-model"}]},"error":"model_not_found"}'
    echo '{"type":"result","subtype":"success","is_error":true,"result":"Model not found: no-such-model","api_error_status":404}'
    exit 1
    ;;
  crash)
    echo "boom: fake crash" >&2
    exit 3
    ;;
  slow)
    for i in 1 2 3 4 5 6 7 8 9 10; do
      echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}'
      sleep 0.3
    done
    echo '{"type":"result","subtype":"success","is_error":false,"result":"xxxxxxxxxx"}'
    ;;
  noresult)
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"only assistant"}]}}'
    ;;
esac
