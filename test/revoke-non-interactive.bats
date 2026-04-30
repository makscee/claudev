#!/usr/bin/env bats
# revoke-non-interactive.bats
# Regression test: claudev must exit non-zero when keys.me returns 401 (session
# revoked) and stdin is non-interactive (empty), so ensure_token cannot reprompt.
# Bug: before fix, execution fell through to `exec claude` with empty token, exit 0.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev" "$HOME/bin"
  printf "locale=en\nlast_update_check=99999999999\n" > "$HOME/.claudev/config"
  printf "validtoken" > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"

  # Stub `claude` so exec never actually runs a real binary; if we reach this
  # stub the bug is present (main() fell through instead of exiting).
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/sh
echo "BUG: exec reached with token=$CLAUDE_CODE_OAUTH_TOKEN" >&2
exit 0
STUB
  chmod +x "$HOME/bin/claude"

  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

@test "revoke + non-interactive reprompt: main exits 1, emits session revoked" {
  # keys.me returns 401 → triggers TOKEN_FORCE_REPROMPT + ensure_token reprompt.
  # stdin is /dev/null (non-interactive), ensure_token returns 1 after 3 empty reads.
  printf 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n' > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "PATH=$HOME/bin:\$PATH CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --print 'hello' </dev/null"
  # Must exit non-zero (1).
  [ "$status" -ne 0 ]
  # Must emit the localized session-revoked message (en: "session revoked").
  echo "$output" | grep -qi "session revoked"
}
