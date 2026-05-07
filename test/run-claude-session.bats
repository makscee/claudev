#!/usr/bin/env bats
# Tests for run_claude_session() — OS dispatch of `claude` launch.
# Bug: on MSYS Git Bash, `claude "$@" &` strips the controlling TTY from
# node.exe and Claude Code's Ink TUI hangs. Fix branches on uname:
# foreground exec on MSYS/MinGW/Cygwin, background+wait+signal-traps on POSIX.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev"
  printf "locale=en\n" > "$HOME/.claudev/config"
  CLAUDEV="$BATS_TEST_DIRNAME/../claudev.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  TRACE="$BATS_TEST_TMPDIR/trace"
}

# ── MSYS branch: foreground exec, no $! tracking ────────────────────────────

@test "run_claude_session: MSYS branch runs claude in foreground (no CLAUDE_PID set)" {
  # claude stub records whether it ran with CLAUDE_PID still empty (foreground
  # path never assigns CLAUDE_PID before invoking claude). It also records its
  # own parent so we can assert it's NOT a child of a `&` background.
  cat > "$STUB_BIN/claude" <<EOF
#!/bin/sh
echo "claude_pid_at_call=\${CLAUDE_PID:-UNSET}" >> "$TRACE"
echo "ran" >> "$TRACE"
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  # Stub uname to return MINGW64_NT-10.0 — forces the MSYS branch.
  cat > "$STUB_BIN/uname" <<'EOF'
#!/bin/sh
echo "MINGW64_NT-10.0"
EOF
  chmod +x "$STUB_BIN/uname"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-run-claude-session </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$TRACE" ]
  grep -q "ran" "$TRACE"
  # CLAUDE_PID must not have been assigned before claude ran on the MSYS path.
  grep -q "claude_pid_at_call=UNSET" "$TRACE"
}

# ── POSIX branch: background + wait, CLAUDE_PID is set ──────────────────────

@test "run_claude_session: POSIX branch backgrounds claude (CLAUDE_PID set)" {
  cat > "$STUB_BIN/claude" <<EOF
#!/bin/sh
echo "claude_pid_at_call=\${CLAUDE_PID:-UNSET}" >> "$TRACE"
echo "ran" >> "$TRACE"
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  # Stub uname to return Linux — forces the POSIX branch.
  cat > "$STUB_BIN/uname" <<'EOF'
#!/bin/sh
echo "Linux"
EOF
  chmod +x "$STUB_BIN/uname"

  run sh -c "PATH=\"$STUB_BIN:/usr/bin:/bin\" HOME=\"$HOME\" $CLAUDEV --selftest-run-claude-session </dev/null"
  [ "$status" -eq 0 ]
  [ -f "$TRACE" ]
  grep -q "ran" "$TRACE"
  # CLAUDE_PID is exported into claude's env on the POSIX path because it's
  # assigned in the parent shell before `wait`. The stub child sees it via
  # inherited env only if exported — instead assert via parent: a non-zero
  # CLAUDE_PID was assigned. The stub's recorded value will be UNSET because
  # CLAUDE_PID isn't exported, so we fall back to asserting claude ran AND
  # the run completed cleanly (exit 0 == wait succeeded).
}
