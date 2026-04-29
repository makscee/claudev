#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\nlast_update_check=99999999999\n" > "$HOME/.claudev/config"
  printf "stale-token" > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
}

@test "claudev logout removes token file" {
  run sh -c "$CLAUDEV logout"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claudev/token" ]
}

@test "claudev logout is idempotent" {
  rm -f "$HOME/.claudev/token"
  run sh -c "$CLAUDEV logout"
  [ "$status" -eq 0 ]
}

@test "claudev --help prints usage and exits 0" {
  run sh -c "$CLAUDEV --help"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q "login"
  echo "$output" | grep -q "logout"
  echo "$output" | grep -q "update"
}
