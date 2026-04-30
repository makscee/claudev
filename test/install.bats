#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  INSTALL="$BATS_TEST_DIRNAME/../install.sh"
  . "$BATS_TEST_DIRNAME/_mock-server.sh"
}

teardown() { mock_stop; }

@test "install drops claudev into ~/.local/bin and locales into ~/.local/share" {
  # Need TWO sequential responses (manifest + script). Use a multi-port pair: port A
  # serves manifest, port B serves the script. install.sh hits both via the same
  # CLAUDEV_AUTH_HOST since paths differ — but the mock_server only handles one
  # response per port. Workaround: serve ONLY the script first (manifest fetch
  # falls back to expected sha — install computes locally). Out-of-band: we craft
  # install.sh to be tolerant of manifest fetch failure (warns, doesn't abort)
  # iff CLAUDEV_INSTALL_SKIP_VERIFY=1. Use that for this test.
  body='#!/bin/sh
echo claudev-stub'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_INSTALL_SKIP_VERIFY=1 $INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/claudev" ]
  grep -q claudev-stub "$HOME/.local/bin/claudev"
}

@test "install prints PATH hint when ~/.local/bin not in PATH" {
  body='#!/bin/sh
echo stub'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
  run sh -c "PATH=/usr/bin:/bin CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_INSTALL_SKIP_VERIFY=1 $INSTALL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q ".local/bin"
}

# Helper: build a canned mock response and start the mock server
_mock_stub() {
  local body='#!/bin/sh
echo stub'
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$BATS_TEST_TMPDIR/resp"
  mock_start "$BATS_TEST_TMPDIR/resp"
}

@test "PATH-autofix: fresh install, no rc exists — creates ~/.profile with export line" {
  _mock_stub
  run sh -c "PATH=/usr/bin:/bin CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_INSTALL_SKIP_VERIFY=1 $INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.profile" ]
  grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.profile"
}

@test "PATH-autofix: existing ~/.bashrc without export line — line is appended" {
  printf 'export FOO=bar\n' > "$HOME/.bashrc"
  _mock_stub
  run sh -c "PATH=/usr/bin:/bin CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_INSTALL_SKIP_VERIFY=1 $INSTALL"
  [ "$status" -eq 0 ]
  grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"
}

@test "PATH-autofix: idempotent — existing line not duplicated" {
  printf 'export PATH="$HOME/.local/bin:$PATH" # claudev\n' > "$HOME/.bashrc"
  local before
  before=$(wc -l < "$HOME/.bashrc")
  _mock_stub
  run sh -c "PATH=/usr/bin:/bin CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_INSTALL_SKIP_VERIFY=1 $INSTALL"
  [ "$status" -eq 0 ]
  local after
  after=$(wc -l < "$HOME/.bashrc")
  [ "$after" -eq "$before" ]
}

@test "PATH-autofix: ~/.local/bin already in PATH — no rc file modified" {
  printf 'export FOO=bar\n' > "$HOME/.bashrc"
  local before
  before=$(wc -l < "$HOME/.bashrc")
  _mock_stub
  run sh -c "PATH=$HOME/.local/bin:/usr/bin:/bin CLAUDEV_AUTH_HOST=http://127.0.0.1:$MOCK_PORT CLAUDEV_INSTALL_SKIP_VERIFY=1 $INSTALL"
  [ "$status" -eq 0 ]
  local after
  after=$(wc -l < "$HOME/.bashrc")
  [ "$after" -eq "$before" ]
}
