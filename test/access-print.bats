#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  printf "tok" > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

_resp() {
  # _resp STATUS_CODE BODY — write full HTTP response to $BATS_TEST_TMPDIR/resp
  local code="$1" body="$2"
  printf 'HTTP/1.1 %s OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s' \
    "$code" "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
}

@test "prints unlimited when claudevGrant.unlimited=true" {
  body='{"userId":"u","role":"customer","sessionId":"s","expiresAt":9999999999,"claudevEnabled":true,"claudevGrant":{"expiresAt":null,"expired":false,"unlimited":true}}'
  _resp 200 "$body"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-print-access-status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Access: unlimited"
}

@test "prints days left for bounded future grant" {
  # Use 8 days out so integer division always yields ≥7 regardless of second boundaries
  future=$(( $(date +%s) + 8 * 86400 ))
  body="{\"userId\":\"u\",\"role\":\"customer\",\"sessionId\":\"s\",\"expiresAt\":9999999999,\"claudevEnabled\":true,\"claudevGrant\":{\"expiresAt\":$future,\"expired\":false,\"unlimited\":false}}"
  _resp 200 "$body"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-print-access-status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "[0-9]+d left"
}

@test "prints expired N days ago for past grant" {
  # Use 6 days back so integer division always yields ≥5 regardless of second boundaries
  past=$(( $(date +%s) - 6 * 86400 ))
  body="{\"userId\":\"u\",\"role\":\"customer\",\"sessionId\":\"s\",\"expiresAt\":9999999999,\"claudevEnabled\":true,\"claudevGrant\":{\"expiresAt\":$past,\"expired\":true,\"unlimited\":false}}"
  _resp 200 "$body"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-print-access-status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "expired [0-9]+d ago"
}

@test "prints no grant when claudevGrant is null" {
  body='{"userId":"u","role":"customer","sessionId":"s","expiresAt":9999999999,"claudevEnabled":false,"claudevGrant":null}'
  _resp 200 "$body"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT $CLAUDEV --selftest-print-access-status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no grant"
}

@test "prints status unavailable on network failure" {
  # Start and immediately stop the mock so the port is not listening.
  mock_start "$BATS_TEST_TMPDIR/resp" 2>/dev/null || true
  saved_port=$MOCK_PORT
  mock_stop
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$saved_port $CLAUDEV --selftest-print-access-status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "status unavailable"
}
