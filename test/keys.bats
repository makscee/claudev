#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  printf "validtoken" > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

@test "fetch_key prints key on 200 with sk-ant-oat shape" {
  body='{"token":"sk-ant-oat-XYZ","keyId":"k1","keyName":"pool-prod-01","expiresAt":"2026-12-31T00:00:00Z"}'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-fetch-key"
  [ "$status" -eq 0 ]
  [ "$output" = "sk-ant-oat-XYZ" ]
}

@test "fetch_key prints key on 200 with sk-ant-oat01 shape" {
  body='{"token":"sk-ant-oat01-ABC123","keyId":"k1","keyName":"pool-prod-01","expiresAt":"2026-12-31T00:00:00Z"}'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-fetch-key"
  [ "$status" -eq 0 ]
  [ "$output" = "sk-ant-oat01-ABC123" ]
}

@test "fetch_key exits 3 on non-OAuth shape" {
  body='{"token":"sk-ant-api03-XYZ","keyId":"k1","keyName":"pool-prod-01","expiresAt":"2026-12-31T00:00:00Z"}'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-fetch-key"
  [ "$status" -eq 3 ]
  echo "$output" | grep -qi "non-OAuth"
}

@test "fetch_key exits 1 on 503 no_keys_available" {
  body='{"error":"no_keys_available"}'
  printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-fetch-key"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "exhaust"
}

@test "fetch_key exits 4 on HTTP 500 server error" {
  body='{"error":"internal"}'
  printf 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-fetch-key"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "server error (HTTP 500)"
  echo "$output" | grep -q "127.0.0.1:$MOCK_PORT"
  ! echo "$output" | grep -qi "network error"
}

@test "fetch_key wipes token on 401" {
  body=''
  printf 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n' > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-fetch-key"
  # Exits non-zero with REPROMPT signal; token file removed.
  [ "$status" -ne 0 ]
  [ ! -f "$HOME/.claudev/token" ]
}
