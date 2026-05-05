#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev" "$HOME/bin"
  printf "locale=en\nlast_update_check=99999999999\n" > "$HOME/.claudev/config"
  printf "validtoken" > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  # stub claude binary that records env vars
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
echo "TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" > "$HOME/.claudev/exec-marker"
echo "HTTPS_PROXY=$HTTPS_PROXY" >> "$HOME/.claudev/exec-marker"
echo "NODE_EXTRA_CA_CERTS=$NODE_EXTRA_CA_CERTS" >> "$HOME/.claudev/exec-marker"
echo "ARGS=$*" >> "$HOME/.claudev/exec-marker"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$HOME/bin/claude"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() {
  mock_stop
  pkill -f "node.*proxy.js.*$BATS_TEST_TMPDIR" 2>/dev/null || true
}

mock_keys_200() {
  body='{"token":"sk-ant-oat-EXEC","keyId":"k","keyName":"n","expiresAt":"2026-12-31T00:00:00Z"}'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
}

@test "proxy lifecycle: spawns proxy, sets env, runs claude, cleans up" {
  mock_keys_200
  run sh -c "PATH=$HOME/bin:\$PATH CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --print hello"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claudev/exec-marker" ]
  # HTTPS_PROXY should be set to a localhost address
  grep -q 'HTTPS_PROXY=http://127.0.0.1:' "$HOME/.claudev/exec-marker"
  # NODE_EXTRA_CA_CERTS should point to ca.pem
  grep -q 'NODE_EXTRA_CA_CERTS=.*proxy-ca/ca.pem' "$HOME/.claudev/exec-marker"
  # Proxy process should be dead after claudev exits
  ! pgrep -f "node.*proxy.js.*$BATS_TEST_TMPDIR" >/dev/null 2>&1
}

@test "CLAUDEV_NO_PROXY=1 skips proxy, runs claude directly" {
  mock_keys_200
  run sh -c "PATH=$HOME/bin:\$PATH CLAUDEV_NO_PROXY=1 CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --print hello"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claudev/exec-marker" ]
  # HTTPS_PROXY should be empty
  grep -q 'HTTPS_PROXY=$' "$HOME/.claudev/exec-marker"
}

@test "claude exit code propagates through proxy lifecycle" {
  mock_keys_200
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
exit 42
STUB
  chmod +x "$HOME/bin/claude"
  run sh -c "PATH=$HOME/bin:\$PATH CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --print hello"
  [ "$status" -eq 42 ]
}

@test "periodic shipper: fires during session, reaped on exit" {
  mock_keys_200

  ship_marker="$HOME/.claudev/ship-marker"
  real_node="$(command -v node)"

  # Stub node: intercept ship-usage.js calls (record tick), delegate everything else
  # to the real node so proxy.js and gen-ca.js work normally.
  cat > "$HOME/bin/node" <<STUB
#!/bin/sh
case "\$*" in
  *ship-usage.js*)
    printf 'tick\n' >> "$ship_marker"
    exit 0
    ;;
  *)
    exec "$real_node" "\$@"
    ;;
esac
STUB
  chmod +x "$HOME/bin/node"

  # claude stub: create session file (so shipper's [ -f ] guard passes),
  # then sleep long enough for >=2 SHIP_INTERVAL=1 ticks (t=1s, t=2s).
  # $PPID inside the stub = claudev.sh's PID = the $$ used in session_file path.
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
mkdir -p "$HOME/.claudev/usage"
printf '{"event":"stub"}\n' > "$HOME/.claudev/usage/session-$PPID.jsonl"
sleep 3
STUB
  chmod +x "$HOME/bin/claude"

  run sh -c "PATH=$HOME/bin:\$PATH SHIP_INTERVAL=1 \
    CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT \
    $CLAUDEV --print hello"
  [ "$status" -eq 0 ]

  # Assert >=2 periodic ticks fired
  [ -f "$ship_marker" ]
  ticks=$(wc -l < "$ship_marker" | tr -d ' ')
  [ "$ticks" -ge 2 ]

  # Assert no ship-usage.js node process survives (shipper reaped)
  ! pgrep -f "ship-usage.js" >/dev/null 2>&1
}

@test "orphan sweep counts dead-PID JSONL files" {
  mock_keys_200
  mkdir -p "$HOME/.claudev/usage"
  # Use PIDs that are certainly not running
  printf '{"t":"x"}\n' > "$HOME/.claudev/usage/session-99999.jsonl"
  printf '{"t":"y"}\n' > "$HOME/.claudev/usage/session-99998.jsonl"
  run sh -c "PATH=$HOME/bin:\$PATH CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --print hello 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2 orphaned usage file"
}
