#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

@test "validate_token returns 0 on 200" {
  printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-validate xyz"
  [ "$status" -eq 0 ]
}

@test "validate_token returns 1 on 401" {
  printf 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 4\r\n\r\nnope' > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-validate bad"
  [ "$status" -eq 1 ]
}

@test "ensure_token saves token after one valid paste" {
  printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "export CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT; echo 'goodtoken' | $CLAUDEV --selftest-ensure-token"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claudev/token" ]
  grep -q goodtoken "$HOME/.claudev/token"
  perm=$(stat -f '%p' "$HOME/.claudev/token" 2>/dev/null || stat -c '%a' "$HOME/.claudev/token")
  echo "$perm" | grep -qE '600$'
}

@test "ensure_token aborts after 3 invalid pastes" {
  printf 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n' > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "export CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT; printf 'a\nb\nc\n' | $CLAUDEV --selftest-ensure-token"
  [ "$status" -eq 1 ]
  [ ! -f "$HOME/.claudev/token" ]
  echo "$output" | grep -q "too many"
}
