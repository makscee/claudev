#!/usr/bin/env bats

setup() {
  TEST_TMP="$BATS_TEST_TMPDIR"
  FIXTURE_DIR="$TEST_TMP/fixture"
  mkdir -p "$FIXTURE_DIR/claudev/proxy"

  # Fixture proxy files (small, deterministic content)
  printf '// gen-ca\n' > "$FIXTURE_DIR/claudev/proxy/gen-ca.js"
  printf '// proxy\n'  > "$FIXTURE_DIR/claudev/proxy/proxy.js"
  printf '// ship\n'   > "$FIXTURE_DIR/claudev/proxy/ship-usage.js"
  printf '// cert\n'   > "$FIXTURE_DIR/claudev/proxy/cert.js"
  printf '// claudev.sh\n' > "$FIXTURE_DIR/claudev/claudev.sh"

  # Compute hashes for manifest
  sha_for() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
  sh_sha=$(sha_for "$FIXTURE_DIR/claudev/claudev.sh")
  ca_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/gen-ca.js")
  px_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/proxy.js")
  sh2_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/ship-usage.js")
  ct_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/cert.js")

  cat > "$FIXTURE_DIR/claudev/version.json" <<EOF
{
  "sha256_sh": "$sh_sha",
  "sha256_proxy_gen_ca": "$ca_sha",
  "sha256_proxy_proxy": "$px_sha",
  "sha256_proxy_ship_usage": "$sh2_sha",
  "sha256_proxy_cert": "$ct_sha"
}
EOF

  # Start python http server on free port; write port to file via inline script
  PORT_FILE="$TEST_TMP/server.port"
  python3 - "$FIXTURE_DIR" "$PORT_FILE" <<'PYEOF' &
import sys, os, http.server, socketserver, pathlib

directory = sys.argv[1]
port_file = sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)
    def log_message(self, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    pathlib.Path(port_file).write_text(str(port))
    httpd.serve_forever()
PYEOF
  SERVER_PID=$!

  # Wait for port file to appear (max 2s)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    [ -f "$PORT_FILE" ] && break
  done
  [ -f "$PORT_FILE" ] || { echo "server failed to start" >&2; return 1; }
  PORT=$(cat "$PORT_FILE")

  export FAKE_HOME="$TEST_TMP/home"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

@test "install.sh fetches proxy files into ~/.local/lib/claudev/proxy/" {
  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="http://127.0.0.1:$PORT" sh "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/gen-ca.js" ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/proxy.js" ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/ship-usage.js" ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/cert.js" ]
  grep -q '// gen-ca' "$FAKE_HOME/.local/lib/claudev/proxy/gen-ca.js"
  grep -q '// proxy'  "$FAKE_HOME/.local/lib/claudev/proxy/proxy.js"
  grep -q '// ship'   "$FAKE_HOME/.local/lib/claudev/proxy/ship-usage.js"
  grep -q '// cert'   "$FAKE_HOME/.local/lib/claudev/proxy/cert.js"
}

@test "install.sh aborts on sha256 mismatch for proxy file" {
  # Corrupt the served gen-ca.js after manifest is written
  printf '// corrupted\n' > "$FIXTURE_DIR/claudev/proxy/gen-ca.js"
  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="http://127.0.0.1:$PORT" sh "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'sha256 mismatch'
}
