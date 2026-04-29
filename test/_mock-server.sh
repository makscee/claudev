#!/bin/sh
# Tiny HTTP mock for tests. Listens on a localhost port; serves canned response
# from $MOCK_RESPONSE_FILE on each connection. Loops until mock_stop is called.
#
# Usage:
#   . _mock-server.sh
#   mock_start /path/to/response.http       → exports MOCK_PORT
#   mock_stop
#
# Response file is the full HTTP response (status line + headers + blank + body).
mock_start() {
  MOCK_PORT=$(awk 'BEGIN { srand(); print 30000 + int(rand()*30000) }')
  MOCK_RESPONSE_FILE="$1"
  MOCK_LOOP_FLAG=$(mktemp)
  MOCK_PIDFILE=$(mktemp)
  # Background loop: spawn nc one-shot; capture its pid; wait it; loop. Killing
  # nc by PID guarantees we don't leak it (vs. killing only the parent shell).
  (
    while [ -f "$MOCK_LOOP_FLAG" ]; do
      nc -l "$MOCK_PORT" < "$MOCK_RESPONSE_FILE" >/dev/null 2>&1 &
      nc_pid=$!
      echo "$nc_pid" > "$MOCK_PIDFILE"
      wait "$nc_pid" 2>/dev/null || true
    done
  ) &
  MOCK_LOOP_PID=$!
  # Wait until port is listening (max ~2s).
  i=0
  while [ $i -lt 20 ]; do
    if nc -z 127.0.0.1 "$MOCK_PORT" 2>/dev/null; then return 0; fi
    sleep 0.1
    i=$((i+1))
  done
  echo "mock_start: port $MOCK_PORT never came up" >&2
  return 1
}
mock_stop() {
  # Drop the loop flag so the supervisor exits after current nc dies.
  [ -n "${MOCK_LOOP_FLAG:-}" ] && rm -f "$MOCK_LOOP_FLAG"
  # Kill current nc child (if any).
  if [ -n "${MOCK_PIDFILE:-}" ] && [ -f "$MOCK_PIDFILE" ]; then
    nc_pid=$(cat "$MOCK_PIDFILE" 2>/dev/null || echo "")
    [ -n "$nc_pid" ] && kill "$nc_pid" 2>/dev/null || true
    rm -f "$MOCK_PIDFILE"
  fi
  # Kill loop supervisor.
  [ -n "${MOCK_LOOP_PID:-}" ] && kill "$MOCK_LOOP_PID" 2>/dev/null || true
  wait "${MOCK_LOOP_PID:-}" 2>/dev/null || true
}
