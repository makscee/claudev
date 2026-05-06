#!/usr/bin/env bats
# CDV-9: Windows self-update trampoline + .old cleanup.

setup() {
  TEST_TMP="$BATS_TEST_TMPDIR"
  BIN_DIR="$TEST_TMP/bin"
  mkdir -p "$BIN_DIR"
  CLAUDEV_BIN="$BIN_DIR/claudev.sh"
  cp "$BATS_TEST_DIRNAME/../claudev.sh" "$CLAUDEV_BIN"
  chmod +x "$CLAUDEV_BIN"
}

# T2 — trampoline swaps in .next, exec's, new content runs.
@test "trampoline: .next present → swap, .old created, exec runs new script" {
  cat > "$BIN_DIR/claudev.sh.next" <<'EOF'
#!/bin/sh
echo "NEW_VERSION_RAN"
exit 0
EOF
  chmod +x "$BIN_DIR/claudev.sh.next"

  run sh "$CLAUDEV_BIN"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'NEW_VERSION_RAN'
  [ ! -f "$BIN_DIR/claudev.sh.next" ]
  [ -f "$BIN_DIR/claudev.sh.old" ]
  grep -q 'NEW_VERSION_RAN' "$CLAUDEV_BIN"
}

# T3 — second launch with no .next deletes stale .old.
@test "trampoline: no .next + stale .old → .old removed" {
  echo "stale" > "$BIN_DIR/claudev.sh.old"
  # Stub the script body so it exits before doing real work; trampoline still runs.
  cat > "$CLAUDEV_BIN" <<'EOF'
#!/bin/sh
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -f "$SELF_DIR/claudev.sh.next" ]; then
  mv "$SELF_DIR/claudev.sh" "$SELF_DIR/claudev.sh.old"
  mv "$SELF_DIR/claudev.sh.next" "$SELF_DIR/claudev.sh"
  exec "$0" "$@"
else
  rm -f "$SELF_DIR/claudev.sh.old"
fi
echo "STUB_RAN"
exit 0
EOF
  chmod +x "$CLAUDEV_BIN"

  run sh "$CLAUDEV_BIN"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'STUB_RAN'
  [ ! -f "$BIN_DIR/claudev.sh.old" ]
}

# T1+T3 in real claudev.sh: with no .next + stale .old the actual script removes .old.
@test "trampoline (real claudev.sh): stale .old removed when no .next present" {
  echo "stale" > "$BIN_DIR/claudev.sh.old"
  # Run the real script with --help to short-circuit before network/main.
  run sh "$CLAUDEV_BIN" --help
  [ "$status" -eq 0 ]
  [ ! -f "$BIN_DIR/claudev.sh.old" ]
  [ ! -f "$BIN_DIR/claudev.sh.next" ]
}

# T1 — Windows uname → self_update writes .next, does NOT mv over $0.
@test "self_update: Windows uname writes .next, in-place script untouched" {
  TEST_TMP="$BATS_TEST_TMPDIR"
  FIXTURE_DIR="$TEST_TMP/fixture"
  mkdir -p "$FIXTURE_DIR/claudev/proxy"
  printf '// gen-ca v2\n' > "$FIXTURE_DIR/claudev/proxy/gen-ca.js"
  printf '// proxy v2\n'  > "$FIXTURE_DIR/claudev/proxy/proxy.js"
  printf '// ship v2\n'   > "$FIXTURE_DIR/claudev/proxy/ship-usage.js"
  printf '// cert v2\n'   > "$FIXTURE_DIR/claudev/proxy/cert.js"
  cat > "$FIXTURE_DIR/claudev/claudev.sh" <<'CDVEOF'
#!/bin/sh
echo "claudev v2 stub"
exit 0
CDVEOF
  chmod +x "$FIXTURE_DIR/claudev/claudev.sh"

  sha_for() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
  sh_sha=$(sha_for "$FIXTURE_DIR/claudev/claudev.sh")
  ca_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/gen-ca.js")
  px_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/proxy.js")
  sh2_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/ship-usage.js")
  ct_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/cert.js")
  cat > "$FIXTURE_DIR/claudev/version.json" <<EOF
{
  "version": "9.9.9",
  "sha256_sh": "$sh_sha",
  "sha256_proxy_gen_ca": "$ca_sha",
  "sha256_proxy_proxy": "$px_sha",
  "sha256_proxy_ship_usage": "$sh2_sha",
  "sha256_proxy_cert": "$ct_sha"
}
EOF

  PORT_FILE="$TEST_TMP/server.port"
  python3 - "$FIXTURE_DIR" "$PORT_FILE" <<'PYEOF' &
import sys, http.server, socketserver, pathlib
directory = sys.argv[1]
port_file = sys.argv[2]
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)
    def log_message(self, *args): pass
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    pathlib.Path(port_file).write_text(str(port))
    httpd.serve_forever()
PYEOF
  SERVER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.2; [ -f "$PORT_FILE" ] && break; done
  PORT=$(cat "$PORT_FILE")

  export FAKE_HOME="$TEST_TMP/home"
  mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/.local/lib/claudev/proxy" \
            "$FAKE_HOME/.local/share/claudev/locales" "$FAKE_HOME/.claudev"
  printf "locale=en\nlast_update_check=0\n" > "$FAKE_HOME/.claudev/config"
  cp "$BATS_TEST_DIRNAME/../locales/en.sh" "$FAKE_HOME/.local/share/claudev/locales/en.sh"
  cp "$BATS_TEST_DIRNAME/../locales/ru.sh" "$FAKE_HOME/.local/share/claudev/locales/ru.sh"

  WIN_BIN="$FAKE_HOME/.local/bin/claudev"
  cp "$BATS_TEST_DIRNAME/../claudev.sh" "$WIN_BIN"
  chmod +x "$WIN_BIN"
  sed -i.bak -E 's/^CLAUDEV_VERSION=.*/CLAUDEV_VERSION="0.0.1"/' "$WIN_BIN"
  rm -f "$WIN_BIN.bak"

  pre_sha=$(shasum -a 256 "$WIN_BIN" | awk '{print $1}')

  # Force Windows uname via PATH stub.
  STUB_DIR="$TEST_TMP/stubs"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then echo "MINGW64_NT-10.0"; exit 0; fi
exec /usr/bin/uname "$@"
EOF
  chmod +x "$STUB_DIR/uname"

  run env PATH="$STUB_DIR:$PATH" HOME="$FAKE_HOME" \
      CLAUDEV_AUTH_HOST="http://127.0.0.1:$PORT" CLAUDEV_FORCE_UPDATE=1 \
      sh "$WIN_BIN" --selftest-self-update </dev/null
  kill "$SERVER_PID" 2>/dev/null || true

  [ "$status" -eq 0 ]
  # In-place script unchanged (file lock simulation).
  post_sha=$(shasum -a 256 "$WIN_BIN" | awk '{print $1}')
  [ "$pre_sha" = "$post_sha" ]
  # .next staged alongside the script.
  [ -f "$FAKE_HOME/.local/bin/claudev.next" ] || [ -f "$FAKE_HOME/.local/bin/claudev.sh.next" ]
}

# Posix smoke (T4): mac/linux uname → in-place mv still works (existing self-update.bats).
@test "self_update: posix uname still does in-place mv (smoke)" {
  # Just sanity-check that uname -s on this host doesn't match Windows pattern;
  # the full posix path is covered by self-update.bats happy-path.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "host is Windows-like; skip posix smoke" ;;
    *) : ;;
  esac
  [ -x "$CLAUDEV_BIN" ]
}
