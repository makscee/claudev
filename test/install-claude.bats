#!/usr/bin/env bats
# Tests for install_claude() — npm-first path (no curl fallback)

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"

  # Bin dir for stubs — prepended to PATH in each test
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
}

# ── Case (a): npm present, install succeeds ─────────────────────────────────

@test "install_claude: npm present and succeeds — have_claude true + onboarding skipped" {
  # npm stub: writes a stub claude binary that prints a version string
  cat > "$STUB_BIN/npm" <<'EOF'
#!/bin/sh
printf '#!/bin/sh\necho "2.1.123 (Claude Code)"\n' > "$(dirname "$0")/claude"
chmod +x "$(dirname "$0")/claude"
exit 0
EOF
  chmod +x "$STUB_BIN/npm"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-install-claude </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude.json" ]
  grep -q '"hasCompletedOnboarding": true' "$HOME/.claude.json"
  grep -q '"lastOnboardingVersion": "2.1.123"' "$HOME/.claude.json"
}

# ── Case (b): npm absent — returns non-zero, prints L_CLAUDE_NEEDS_NODE ─────

@test "install_claude: npm absent — exits non-zero and prints needs-node message" {
  # PATH has no npm
  run sh -c "echo y | PATH=/usr/bin:/bin HOME=\"$HOME\" $CLAUDEV --selftest-install-claude"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "node"
}

# ── Case (c): npm present but fails — ensure_claude prints install-failed ───

@test "install_claude: npm present but exits 1 — propagates non-zero" {
  # npm stub: exits 1, does NOT write claude
  cat > "$STUB_BIN/npm" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$STUB_BIN/npm"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-install-claude </dev/null"
  [ "$status" -ne 0 ]
}

# ── Case (d): pre-existing ~/.claude.json — merge preserves keys ────────────

@test "install_claude: merges with existing ~/.claude.json (preserves installMethod + userID)" {
  # npm stub: writes a stub claude binary that prints a version string
  cat > "$STUB_BIN/npm" <<'EOF'
#!/bin/sh
printf '#!/bin/sh\necho "2.1.123 (Claude Code)"\n' > "$(dirname "$0")/claude"
chmod +x "$(dirname "$0")/claude"
exit 0
EOF
  chmod +x "$STUB_BIN/npm"

  # Pre-seed ~/.claude.json with caller-set keys that must survive the merge
  printf '{"installMethod":"native","userID":"abc"}\n' > "$HOME/.claude.json"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-install-claude </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude.json" ]

  # Assert via grep on file text — works on Win Git Bash (no jq, MS-Store python3
  # shim that fails sanity probe) just as well as on macOS/Linux. Tolerates the
  # spacing variations our three writer tiers produce (`"k": v` and `"k":v`).
  merged=$(cat "$HOME/.claude.json")
  printf '%s' "$merged" | grep -Eq '"installMethod"[[:space:]]*:[[:space:]]*"native"'
  printf '%s' "$merged" | grep -Eq '"userID"[[:space:]]*:[[:space:]]*"abc"'
  printf '%s' "$merged" | grep -Eq '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true'
  printf '%s' "$merged" | grep -Eq '"lastOnboardingVersion"[[:space:]]*:[[:space:]]*"[^"]+"'
}

# ── Case (e): pure-shell fallback (no jq, no python3) — exercised on all OSes ─

@test "install_claude: merges via pure-shell fallback when jq + python3 absent" {
  # npm stub installs working `claude`.
  cat > "$STUB_BIN/npm" <<'EOF'
#!/bin/sh
printf '#!/bin/sh\necho "2.1.123 (Claude Code)"\n' > "$(dirname "$0")/claude"
chmod +x "$(dirname "$0")/claude"
exit 0
EOF
  chmod +x "$STUB_BIN/npm"

  # python3 stub that mimics the Windows MS-Store launcher: any invocation
  # exits non-zero with a 'not found'-style message. Sanity probe must reject it.
  cat > "$STUB_BIN/python3" <<'EOF'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store" >&2
exit 9009
EOF
  chmod +x "$STUB_BIN/python3"

  # Pre-seed file to force the merge branch.
  printf '{"installMethod":"native","userID":"abc"}\n' > "$HOME/.claude.json"

  # PATH lacks jq (we don't add it to STUB_BIN) and python3 stub fails sanity
  # probe → tier 3 (pure shell) must run.
  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-install-claude </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude.json" ]

  merged=$(cat "$HOME/.claude.json")
  printf '%s' "$merged" | grep -Eq '"installMethod"[[:space:]]*:[[:space:]]*"native"'
  printf '%s' "$merged" | grep -Eq '"userID"[[:space:]]*:[[:space:]]*"abc"'
  printf '%s' "$merged" | grep -Eq '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true'
  printf '%s' "$merged" | grep -Eq '"lastOnboardingVersion"[[:space:]]*:[[:space:]]*"[^"]+"'
  # No CRLF leakage from the shell-merge path.
  ! printf '%s' "$merged" | grep -q $'\r'
}
