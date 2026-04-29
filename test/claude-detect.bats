#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev" "$HOME/bin"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
}

@test "ensure_claude returns 0 when claude on PATH" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/bin/claude"
  chmod +x "$HOME/bin/claude"
  run sh -c "PATH=\"$HOME/bin:\$PATH\" $CLAUDEV --selftest-ensure-claude </dev/null"
  [ "$status" -eq 0 ]
}

@test "ensure_claude exits 1 when claude missing and user declines install" {
  # Constrain PATH for the claudev invocation (not just for `echo`) so `command -v claude`
  # cannot find a host install. /usr/bin:/bin gives us awk/grep/mkdir but no claude.
  run sh -c "echo n | PATH=/usr/bin:/bin HOME=\"$HOME\" $CLAUDEV --selftest-ensure-claude"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "claude code"
}
