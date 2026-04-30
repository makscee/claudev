#!/usr/bin/env bats
# Tests for token storage / ensure_token (v0.2.0: load-from-file only).
# The prompt-and-validate flow has moved to cmd_login (see login.bats).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
}

@test "ensure_token: drops into cmd_login when no token file (v0.2.1+)" {
  # v0.2.1: ensure_token no longer just exits — it inlines cmd_login so the
  # user doesn't need to know to run `claudev login`. With closed stdin the
  # login loop bails on first `read` and exits via L_TOO_MANY_ATTEMPTS.
  rm -f "$HOME/.claudev/token"
  run sh -c "$CLAUDEV --selftest-ensure-token < /dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "access code" ]] || [[ "$output" =~ "код доступа" ]] || [[ "$output" =~ "Too many" ]]
}

@test "ensure_token: exits 0 and sets TOKEN when token file present" {
  printf 'sk-test-stored' > "$HOME/.claudev/token"
  chmod 600 "$HOME/.claudev/token"
  # --selftest-ensure-token calls ensure_token; on success it exits 0 (no output).
  run sh -c "$CLAUDEV --selftest-ensure-token"
  [ "$status" -eq 0 ]
}
