#!/usr/bin/env bats
# Tests for CLAUDEV_OFFLINE=1 short-circuit (VOS-77).
# When set, main() must skip self_update / ensure_claude / ensure_token /
# fetch_key / start_proxy and `exec claude "$@"` directly with caller's argv.
# This lets bats tests prove flag forwarding without hitting void-auth /
# void-keys / Anthropic.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"

  # Fake `claude` that just echoes its argv. If the guard works, this is what
  # runs. If the guard is broken, self_update / ensure_token network calls
  # would either hang or fail well before reaching exec.
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
printf 'offline-claude argv:'
for a in "$@"; do
  printf ' [%s]' "$a"
done
printf '\n'
EOF
  chmod +x "$STUB_BIN/claude"
}

@test "CLAUDEV_OFFLINE=1: execs claude directly with no args" {
  run env -i HOME="$HOME" PATH="$STUB_BIN:/usr/bin:/bin" CLAUDEV_OFFLINE=1 sh "$CLAUDEV"
  [ "$status" -eq 0 ]
  [ "$output" = "offline-claude argv:" ]
}

@test "CLAUDEV_OFFLINE=1: forwards multi-arg argv verbatim to claude" {
  run env -i HOME="$HOME" PATH="$STUB_BIN:/usr/bin:/bin" CLAUDEV_OFFLINE=1 \
    sh "$CLAUDEV" --mcp-config /tmp/x.json -p hi
  [ "$status" -eq 0 ]
  [ "$output" = "offline-claude argv: [--mcp-config] [/tmp/x.json] [-p] [hi]" ]
}

@test "CLAUDEV_OFFLINE=1: short-circuits before self_update / ensure_token" {
  # No void-auth / void-keys hosts reachable in this env. If the guard is
  # missing, claudev.sh would try self_update (curl) and ensure_token
  # (interactive prompt) and either hang or fail. With the guard, exec
  # happens before any of that, so the run is fast and clean.
  run env -i HOME="$HOME" PATH="$STUB_BIN:/usr/bin:/bin" CLAUDEV_OFFLINE=1 \
    sh "$CLAUDEV" --version
  [ "$status" -eq 0 ]
  [ "$output" = "offline-claude argv: [--version]" ]
}

@test "CLAUDEV_OFFLINE unset: guard does NOT trigger (subcommand still works)" {
  # `claudev --help` is handled by dispatch() before main() runs, so it
  # exercises the non-offline path without needing network. Proves the
  # guard's absence-case doesn't accidentally activate.
  run env -i HOME="$HOME" PATH="$STUB_BIN:/usr/bin:/bin" sh "$CLAUDEV" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage: claudev"
}
