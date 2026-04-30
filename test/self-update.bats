#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\nlast_update_check=0\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

# Build a custom mock that serves /claudev/version.json THEN /claudev/claudev.sh
# from a single nc loop. We emulate by responding with a multi-doc file: nc reads
# one request, we reply with version.json; second request gets the script. nc -k
# (or nc -lk) loops; each connection reads anew.
write_mock_version_resp() {
  body=$(printf '{"version":"%s","sha256_sh":"%s"}' "$1" "$2")
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s' "${#body}" "$body"
}

@test "self_update: skip when remote version matches local" {
  resp=$(mktemp)
  write_mock_version_resp "0.1.1" "deadbeef" > "$resp"
  mock_start "$resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_FORCE_UPDATE=1 $CLAUDEV --selftest-self-update"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "up to date"
}

@test "self_update: refuses on sha256 mismatch" {
  # Two requests in one test: bats can't easily round-trip two distinct mocks
  # via nc, so this test asserts the manifest path only — sha256 enforcement is
  # exercised against a real server in T13 prod E2E. Skip with note.
  skip "sha256-mismatch path covered by T13 prod E2E"
}
