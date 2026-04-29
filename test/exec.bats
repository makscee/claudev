#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev" "$HOME/bin"
  printf "locale=en\nlast_update_check=99999999999\n" > "$HOME/.claudev/config"
  printf "validtoken" > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"

  # Stub `claude` that echoes its env + args to a marker file.
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
echo "TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" > "$HOME/.claudev/exec-marker"
echo "ARGS=$*" >> "$HOME/.claudev/exec-marker"
STUB
  chmod +x "$HOME/bin/claude"

  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

@test "main passthrough: keys.me 200 → claude run with token + args" {
  body='{"token":"sk-ant-oat-EXEC","keyId":"k","keyName":"n","expiresAt":"2026-12-31T00:00:00Z"}'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "PATH=$HOME/bin:\$PATH CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --print 'hello'"
  [ "$status" -eq 0 ]
  grep -q '^TOKEN=sk-ant-oat-EXEC$' "$HOME/.claudev/exec-marker"
  grep -q "^ARGS=--print hello$" "$HOME/.claudev/exec-marker"
}
