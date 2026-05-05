#!/usr/bin/env bats

setup() {
  TEST_TMP="$BATS_TEST_TMPDIR"
  FIXTURE_DIR="$TEST_TMP/fixture"
  mkdir -p "$FIXTURE_DIR/claudev/proxy"

  # New-version fixture content (deterministic).
  printf '// gen-ca v2\n' > "$FIXTURE_DIR/claudev/proxy/gen-ca.js"
  printf '// proxy v2\n'  > "$FIXTURE_DIR/claudev/proxy/proxy.js"
  printf '// ship v2\n'   > "$FIXTURE_DIR/claudev/proxy/ship-usage.js"
  printf '// cert v2\n'   > "$FIXTURE_DIR/claudev/proxy/cert.js"

  # Build a v2 claudev.sh that's a no-op shell script (just prints version, exits 0).
  # After self_update mv's it into place and exec's, it must run without erroring.
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
  [ -f "$PORT_FILE" ] || { echo "server failed to start" >&2; return 1; }
  PORT=$(cat "$PORT_FILE")

  # Fake user home with a pinned-old claudev install.
  export FAKE_HOME="$TEST_TMP/home"
  mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/.local/lib/claudev/proxy" \
            "$FAKE_HOME/.local/share/claudev/locales" "$FAKE_HOME/.claudev"
  printf "locale=en\nlast_update_check=0\n" > "$FAKE_HOME/.claudev/config"
  # Seed locale files so load_locale doesn't fail in the fake home.
  cp "$BATS_TEST_DIRNAME/../locales/en.sh" "$FAKE_HOME/.local/share/claudev/locales/en.sh"
  cp "$BATS_TEST_DIRNAME/../locales/ru.sh" "$FAKE_HOME/.local/share/claudev/locales/ru.sh"

  # Copy the real (current) claudev.sh into place and patch CLAUDEV_VERSION to a
  # known-old value so the manifest's "9.9.9" triggers update.
  cp "$BATS_TEST_DIRNAME/../claudev.sh" "$FAKE_HOME/.local/bin/claudev"
  chmod +x "$FAKE_HOME/.local/bin/claudev"
  # Inject a v0.0.1 sentinel: replace whatever CLAUDEV_VERSION line exists.
  sed -i.bak -E 's/^CLAUDEV_VERSION=.*/CLAUDEV_VERSION="0.0.1"/' "$FAKE_HOME/.local/bin/claudev"
  rm -f "$FAKE_HOME/.local/bin/claudev.bak"

  # Seed proxy dir empty (the very bug this task fixes).
  : > "$FAKE_HOME/.local/lib/claudev/proxy/.empty"
  rm -f "$FAKE_HOME/.local/lib/claudev/proxy/.empty"

  CLAUDEV_BIN="$FAKE_HOME/.local/bin/claudev"
  AUTH_HOST="http://127.0.0.1:$PORT"
}

teardown() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

@test "self_update: happy path bumps script + 4 proxy files atomically" {
  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="$AUTH_HOST" CLAUDEV_FORCE_UPDATE=1 \
      sh "$CLAUDEV_BIN" --selftest-self-update </dev/null
  [ "$status" -eq 0 ]
  # Script replaced with v2 stub.
  grep -q 'claudev v2 stub' "$CLAUDEV_BIN"
  # All 4 proxy files now present and matching v2 content.
  grep -q '// gen-ca v2' "$FAKE_HOME/.local/lib/claudev/proxy/gen-ca.js"
  grep -q '// proxy v2'  "$FAKE_HOME/.local/lib/claudev/proxy/proxy.js"
  grep -q '// ship v2'   "$FAKE_HOME/.local/lib/claudev/proxy/ship-usage.js"
  grep -q '// cert v2'   "$FAKE_HOME/.local/lib/claudev/proxy/cert.js"
}

@test "self_update: aborts on proxy sha256 mismatch, leaving install untouched" {
  # Tamper with the served file AFTER the manifest was hashed.
  printf '// tampered\n' > "$FIXTURE_DIR/claudev/proxy/proxy.js"

  pre_script_sha=$(shasum -a 256 "$CLAUDEV_BIN" | awk '{print $1}')

  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="$AUTH_HOST" CLAUDEV_FORCE_UPDATE=1 \
      sh "$CLAUDEV_BIN" --selftest-self-update </dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'sha256 mismatch for proxy/proxy.js'

  # Original script untouched.
  post_script_sha=$(shasum -a 256 "$CLAUDEV_BIN" | awk '{print $1}')
  [ "$pre_script_sha" = "$post_script_sha" ]
  # Proxy dir still empty (we never staged successfully).
  [ ! -f "$FAKE_HOME/.local/lib/claudev/proxy/proxy.js" ]
  [ ! -f "$FAKE_HOME/.local/lib/claudev/proxy/cert.js" ]
}

@test "self_update: aborts on proxy fetch 404, leaving install untouched" {
  rm -f "$FIXTURE_DIR/claudev/proxy/cert.js"
  pre_script_sha=$(shasum -a 256 "$CLAUDEV_BIN" | awk '{print $1}')

  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="$AUTH_HOST" CLAUDEV_FORCE_UPDATE=1 \
      sh "$CLAUDEV_BIN" --selftest-self-update </dev/null
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'failed to fetch proxy/cert.js'

  post_script_sha=$(shasum -a 256 "$CLAUDEV_BIN" | awk '{print $1}')
  [ "$pre_script_sha" = "$post_script_sha" ]
}

@test "self_update: idempotent on version-equal install (FORCE_UPDATE)" {
  # Re-write the served manifest version to match the LOCAL version exactly.
  sha_for() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
  sh_sha=$(sha_for "$FIXTURE_DIR/claudev/claudev.sh")
  ca_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/gen-ca.js")
  px_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/proxy.js")
  sh2_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/ship-usage.js")
  ct_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/cert.js")
  cat > "$FIXTURE_DIR/claudev/version.json" <<EOF
{
  "version": "0.0.1",
  "sha256_sh": "$sh_sha",
  "sha256_proxy_gen_ca": "$ca_sha",
  "sha256_proxy_proxy": "$px_sha",
  "sha256_proxy_ship_usage": "$sh2_sha",
  "sha256_proxy_cert": "$ct_sha"
}
EOF

  pre_script_sha=$(shasum -a 256 "$CLAUDEV_BIN" | awk '{print $1}')
  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="$AUTH_HOST" CLAUDEV_FORCE_UPDATE=1 \
      sh "$CLAUDEV_BIN" --selftest-self-update </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'up to date'
  post_script_sha=$(shasum -a 256 "$CLAUDEV_BIN" | awk '{print $1}')
  [ "$pre_script_sha" = "$post_script_sha" ]
  [ ! -f "$FAKE_HOME/.local/lib/claudev/proxy/gen-ca.js" ]
}
