#!/usr/bin/env bats
# Verifies that claudev forwards --mcp-config <path> to the underlying claude
# binary without modification. Uses a PATH-injected fake `claude` to capture
# argv and CLAUDEV_OFFLINE=1 (VOS-77 T2) to skip self_update / token / proxy
# so the test is fully offline and key-free.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  ARGV_FILE="$BATS_TEST_TMPDIR/argv.txt"
  export ARGV_FILE

  # Fake `claude` that records argv (one arg per line) and exits 0.
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
: >"$ARGV_FILE"
for a in "$@"; do
  printf '%s\n' "$a" >>"$ARGV_FILE"
done
exit 0
EOF
  chmod +x "$STUB_BIN/claude"
}

@test "claudev forwards --mcp-config <path> -p <prompt> to claude argv verbatim" {
  run env -i HOME="$HOME" PATH="$STUB_BIN:/usr/bin:/bin" \
    ARGV_FILE="$ARGV_FILE" CLAUDEV_OFFLINE=1 \
    sh "$CLAUDEV" --mcp-config /tmp/foo.json -p hi

  [ "$status" -eq 0 ]
  [ -f "$ARGV_FILE" ]
  expected="--mcp-config
/tmp/foo.json
-p
hi"
  actual="$(cat "$ARGV_FILE")"
  [ "$actual" = "$expected" ]
}
