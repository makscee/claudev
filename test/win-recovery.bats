#!/usr/bin/env bats
#
# Windows half-trampoline recovery (claudev.sh _recover_claude_msys + ensure_claude).
#
# Scenario: claude-code's own self-update on Windows leaves bin/claude.exe
# missing while parking the previous binary as claude.exe.old.<epoch-ms>.
# `command -v claude` still resolves the npm shim, so have_claude passes,
# but exec fails. ensure_claude must restore the newest .old.<ts> on MSYS
# and probe `claude --version`; on persistent failure surface the manual
# reinstall hint + exit 1.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"

  # Fake npm global root that the script will probe.
  NPM_ROOT="$BATS_TEST_TMPDIR/npm-root"
  CLAUDE_BIN_DIR="$NPM_ROOT/@anthropic-ai/claude-code/bin"
  mkdir -p "$CLAUDE_BIN_DIR"

  # `npm` stub: only `npm root -g` is needed for the recovery path. Other
  # invocations are no-ops.
  cat > "$STUB_BIN/npm" <<EOF
#!/bin/sh
if [ "\$1" = "root" ] && [ "\$2" = "-g" ]; then
  printf '%s\n' "$NPM_ROOT"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUB_BIN/npm"

  # `uname` stub — pretends we're on Git Bash / MSYS.
  cat > "$STUB_BIN/uname" <<'EOF'
#!/bin/sh
# Pass-through for any flag we don't override.
case "$1" in
  -s) printf '%s\n' "MINGW64_NT-10.0-22631"; exit 0 ;;
esac
exec /usr/bin/uname "$@"
EOF
  chmod +x "$STUB_BIN/uname"
}

# ── Case 1: recovery happy path ────────────────────────────────────────────
@test "_recover_claude_msys: missing claude.exe + .old.<ts> present — restored, probe passes" {
  # Stage the parked backup; no live claude.exe.
  printf '#!/bin/sh\necho "2.1.42 (Claude Code)"\n' > "$CLAUDE_BIN_DIR/claude.exe.old.1778163661537"
  chmod +x "$CLAUDE_BIN_DIR/claude.exe.old.1778163661537"

  # Stub `claude` on PATH so `command -v claude` succeeds AND `claude --version`
  # exits 0 (probe).
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
echo "2.1.42 (Claude Code)"
EOF
  chmod +x "$STUB_BIN/claude"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-ensure-claude </dev/null"
  [ "$status" -eq 0 ]

  # Backup is gone, claude.exe is restored.
  [ -f "$CLAUDE_BIN_DIR/claude.exe" ]
  [ ! -e "$CLAUDE_BIN_DIR/claude.exe.old.1778163661537" ]

  # Recovery notice surfaced.
  echo "$output" | grep -q "recovered from claude.exe.old.1778163661537"
}

# ── Case 2: fatal — no backup, probe fails ─────────────────────────────────
@test "_recover_claude_msys: no .old.* + probe fails — exits 1 with reinstall hint" {
  # No claude.exe, no .old.* — directory exists but empty.

  # `claude` shim resolves on PATH so have_claude passes, but `claude --version`
  # exits non-zero — simulating the broken trampoline.
  cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "claude.exe: No such file or directory" >&2
  exit 127
fi
exit 127
EOF
  chmod +x "$STUB_BIN/claude"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-ensure-claude </dev/null"
  [ "$status" -eq 1 ]

  # Surface the manual recovery command from the locale-keyed fatal message.
  echo "$output" | grep -q "npm install -g --include=optional --force @anthropic-ai/claude-code"
}
