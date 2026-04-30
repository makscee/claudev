#!/usr/bin/env bats
# Tests for token storage / ensure_token (v0.2.0: load-from-file only).
# The prompt-and-validate flow has moved to cmd_login (see login.bats).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
}

@test "ensure_token: exits 1 and prints revoked when no token file" {
  rm -f "$HOME/.claudev/token"
  run sh -c "$CLAUDEV --selftest-ensure-token"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "session revoked" ]]
}

@test "ensure_token: exits 0 and sets TOKEN when token file present" {
  printf 'sk-test-stored' > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  # --selftest-ensure-token calls ensure_token; on success it exits 0 (no output).
  run sh -c "$CLAUDEV --selftest-ensure-token"
  [ "$status" -eq 0 ]
}
