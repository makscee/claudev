#!/usr/bin/env bats
# Tests for bootstrap_node() — OS branching + skip path.
# Covers CDV-10 T1: detect OS, dispatch to _bootstrap_node_{macos,linux,windows};
# return 0 without installing if node OR claude is already usable.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  TRACE="$BATS_TEST_TMPDIR/trace"
}

# ── Skip path: command -v node succeeds ─────────────────────────────────────

@test "bootstrap_node: skip when node already on PATH" {
  cat > "$STUB_BIN/node" <<'EOF'
#!/bin/sh
echo "v22.0.0"
EOF
  chmod +x "$STUB_BIN/node"
  # No brew/apt/etc on PATH — if skip fails, the function would fall through to
  # `return 1`, so a successful exit proves the skip path triggered.

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already" || echo "$output" | grep -qi "skip"
}

# ── Skip-guard: node < 18 falls through to installer ───────────────────────

@test "bootstrap_node: node 14 falls through to installer (does NOT skip)" {
  # Stub node v14 — below Claude Code minimum of 18.
  cat > "$STUB_BIN/node" <<'EOF'
#!/bin/sh
echo "v14.21.3"
EOF
  chmod +x "$STUB_BIN/node"

  # Provide a brew stub so the macOS dispatch path resolves and we can detect
  # that the function fell through to the installer rather than skipping.
  cat > "$STUB_BIN/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "$TRACE"
cat > "$STUB_BIN/npm" <<'NPMEOF'
#!/bin/sh
exit 0
NPMEOF
chmod +x "$STUB_BIN/npm"
exit 0
EOF
  chmod +x "$STUB_BIN/brew"

  run sh -c "OSTYPE=darwin23 PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -eq 0 ]
  # Skip path would NOT touch brew; fall-through must invoke it.
  [ -f "$TRACE" ]
  grep -q "brew install" "$TRACE"
}

# ── Skip path: claude --version succeeds ────────────────────────────────────

@test "bootstrap_node: skip when claude --version succeeds (even without node)" {
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
echo "2.1.0 (Claude Code)"
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -eq 0 ]
}

# ── macOS path → brew ───────────────────────────────────────────────────────

@test "bootstrap_node: macOS dispatches to _bootstrap_node_macos (calls brew)" {
  # brew stub records invocation; also drop an npm stub so post-install check passes.
  cat > "$STUB_BIN/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "$TRACE"
# Simulate brew install side-effect: provide npm.
cat > "$STUB_BIN/npm" <<'NPMEOF'
#!/bin/sh
exit 0
NPMEOF
chmod +x "$STUB_BIN/npm"
exit 0
EOF
  chmod +x "$STUB_BIN/brew"

  run sh -c "OSTYPE=darwin23 PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$TRACE" ]
  grep -q "brew install" "$TRACE"
}

# ── Linux path → apt-get (NodeSource setup script + apt install) ────────────

@test "bootstrap_node: Linux dispatches to _bootstrap_node_linux (calls apt-get)" {
  cat > "$STUB_BIN/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$*" >> "$TRACE"
# Simulate post-install npm presence.
cat > "$STUB_BIN/npm" <<'NPMEOF'
#!/bin/sh
exit 0
NPMEOF
chmod +x "$STUB_BIN/npm"
exit 0
EOF
  chmod +x "$STUB_BIN/apt-get"

  # bash + curl needed because the linux branch pipes the NodeSource script
  # through bash; stub them as no-ops so the dispatch reaches apt-get.
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/curl"
  cat > "$STUB_BIN/bash" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$STUB_BIN/bash"

  run sh -c "OSTYPE=linux-gnu PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$TRACE" ]
  grep -q "apt-get install" "$TRACE"
}

# ── Windows path → _bootstrap_node_windows stub ─────────────────────────────

@test "bootstrap_node: Windows OSTYPE (msys) routes to _bootstrap_node_windows stub" {
  run sh -c "OSTYPE=msys PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  # T1 stub returns 1 — assert non-zero AND the windows-marker log line.
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "windows"
}

@test "bootstrap_node: Windows OSTYPE (cygwin) routes to _bootstrap_node_windows stub" {
  run sh -c "OSTYPE=cygwin PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "windows"
}

@test "bootstrap_node: Windows OSTYPE (mingw) routes to _bootstrap_node_windows stub" {
  run sh -c "OSTYPE=mingw64 PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-bootstrap-node </dev/null"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "windows"
}
