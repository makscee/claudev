#!/usr/bin/env bats

load _helpers

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  GEN_CA="$(_canonpath "$BATS_TEST_DIRNAME/..")/proxy/gen-ca.js"
}

@test "gen-ca creates ca.pem and ca-key.pem with correct perms" {
  run node "$GEN_CA"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claudev/proxy-ca/ca.pem" ]
  [ -f "$HOME/.claudev/proxy-ca/ca-key.pem" ]

  # Check key file has mode 600
  if [[ "$(uname)" == "Darwin" ]]; then
    perms=$(stat -f '%Lp' "$HOME/.claudev/proxy-ca/ca-key.pem")
  else
    perms=$(stat -c '%a' "$HOME/.claudev/proxy-ca/ca-key.pem")
  fi
  [ "$perms" = "600" ]
}

@test "gen-ca is idempotent — second run preserves existing files" {
  run node "$GEN_CA"
  [ "$status" -eq 0 ]

  cp "$HOME/.claudev/proxy-ca/ca.pem" "$BATS_TEST_TMPDIR/ca1.pem"
  cp "$HOME/.claudev/proxy-ca/ca-key.pem" "$BATS_TEST_TMPDIR/ca1-key.pem"

  run node "$GEN_CA"
  [ "$status" -eq 0 ]

  diff "$BATS_TEST_TMPDIR/ca1.pem" "$HOME/.claudev/proxy-ca/ca.pem"
  diff "$BATS_TEST_TMPDIR/ca1-key.pem" "$HOME/.claudev/proxy-ca/ca-key.pem"
}

@test "gen-ca output is valid X.509" {
  run node "$GEN_CA"
  [ "$status" -eq 0 ]

  run openssl x509 -in "$HOME/.claudev/proxy-ca/ca.pem" -noout -subject
  [ "$status" -eq 0 ]
  [[ "$output" == *"claudev-proxy-ca"* ]]
}
