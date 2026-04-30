#!/usr/bin/env bats
# Tests for the access-code exchange login flow (v0.2.0+).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

# Helper: build a canned HTTP response file.
make_resp() {
  status_line="$1"   # e.g. "200 OK"
  body="$2"
  printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' \
    "$status_line" "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
}

@test "login: valid code → token written, mode 0600" {
  make_resp "200 OK" '{"token":"sk-test-abc","userId":"u1"}'
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT; export CLAUDEV_AUTH_HOST; echo 'K7M2-X9PR' | $CLAUDEV login"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Code accepted" ]]
  [ "$(cat "$HOME/.claudev/token")" = "sk-test-abc" ]
  perm=$(stat -f '%p' "$HOME/.claudev/token" 2>/dev/null || stat -c '%a' "$HOME/.claudev/token")
  echo "$perm" | grep -qE '600$'
}

@test "login: 410 consumed/expired → re-prompt + fail after 3 attempts" {
  make_resp "410 Gone" '{"error":"consumed"}'
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT; export CLAUDEV_AUTH_HOST; printf 'AAAA-BBBB\nCCCC-DDDD\nEEEE-FFFF\n' | $CLAUDEV login"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Code expired or already used" ]]
}

@test "login: invalid format client-side → re-prompt + fail" {
  # No mock server needed — rejected before network hit.
  run sh -c "printf 'short\nstill-bad\nnope-code\n' | $CLAUDEV login"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Invalid code format" ]]
}

@test "login: lowercase input is upcased before network send (200 accepted)" {
  make_resp "200 OK" '{"token":"sk-lower-ok","userId":"u2"}'
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT; export CLAUDEV_AUTH_HOST; echo 'k7m2-x9pr' | $CLAUDEV login"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Code accepted" ]]
  [ "$(cat "$HOME/.claudev/token")" = "sk-lower-ok" ]
}

@test "login: unknown code (410 not found) → fail after 3 attempts" {
  make_resp "410 Gone" '{"error":"not found"}'
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT; export CLAUDEV_AUTH_HOST; printf 'AAAA-BBBB\nCCCC-DDDD\nEEEE-FFFF\n' | $CLAUDEV login"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Code expired or already used" ]]
}
