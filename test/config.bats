#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
}

@test "first run prompts for locale and writes config" {
  run sh -c "echo 1 | $CLAUDEV --selftest-locale"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claudev/config" ]
  grep -q '^locale=en$' "$HOME/.claudev/config"
}

@test "second run reads locale and skips prompt" {
  mkdir -p "$HOME/.claudev"
  printf "locale=ru\nlast_update_check=0\n" > "$HOME/.claudev/config"
  run sh -c "$CLAUDEV --selftest-locale </dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ru$"
}

@test "config_get returns empty for unset key" {
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  run sh -c "$CLAUDEV --selftest-config-get nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "config_set creates dir and updates existing key" {
  run sh -c "$CLAUDEV --selftest-config-set last_update_check 12345"
  [ "$status" -eq 0 ]
  grep -q '^last_update_check=12345$' "$HOME/.claudev/config"
}

@test "header prints version and locale" {
  mkdir -p "$HOME/.claudev"
  printf "locale=en\nlast_update_check=0\n" > "$HOME/.claudev/config"
  run sh -c "$CLAUDEV --selftest-header"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "claudev v[0-9]+\.[0-9]+\.[0-9]+ · en"
}
