#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claudev/proxy-ca" "$HOME/.claudev/usage"

  PROXY_JS="$BATS_TEST_DIRNAME/../proxy/proxy.js"
  MOCK_JS="$BATS_TEST_DIRNAME/helpers/mock-anthropic.js"
  GEN_CA="$BATS_TEST_DIRNAME/../proxy/gen-ca.js"

  # Generate CA for the proxy
  node "$GEN_CA"

  PIDS=()
}

teardown() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

start_mock() {
  local ready_file="$BATS_TEST_TMPDIR/mock-ready"
  node "$MOCK_JS" "$ready_file" &
  PIDS+=($!)
  # Wait for ready file
  for i in $(seq 1 50); do
    [ -f "$ready_file" ] && break
    sleep 0.1
  done
  [ -f "$ready_file" ] || return 1
  MOCK_PORT=$(cat "$ready_file")
  MOCK_CA="$ready_file.ca"
}

start_proxy() {
  local session_id="${1:-test-session}"
  local ready_file="$BATS_TEST_TMPDIR/proxy-ready-${session_id}"
  CLAUDEV_SESSION_ID="$session_id" \
  CLAUDEV_PROXY_TARGET_HOST=127.0.0.1 \
  CLAUDEV_PROXY_TARGET_PORT="$MOCK_PORT" \
  NODE_TLS_REJECT_UNAUTHORIZED=0 \
    node "$PROXY_JS" "$ready_file" &
  PIDS+=($!)
  # Wait for ready file
  for i in $(seq 1 50); do
    [ -f "$ready_file" ] && break
    sleep 0.1
  done
  [ -f "$ready_file" ] || return 1
  eval "PROXY_PORT_${session_id//-/_}=$(cat "$ready_file")"
  PROXY_PORT=$(cat "$ready_file")
}

# Helper: send a CONNECT + POST /v1/messages through the proxy
send_request() {
  local proxy_port="$1"
  local auth_key="${2:-sk-ant-test-key-1234}"
  local model="${3:-claude-sonnet-4-20250514}"

  node -e "
    const http = require('http');
    const tls = require('tls');
    const fs = require('fs');

    const caCert = fs.readFileSync('$HOME/.claudev/proxy-ca/ca.pem');
    const body = JSON.stringify({ model: '$model', max_tokens: 100, messages: [{ role: 'user', content: 'hi' }] });

    const req = http.request({
      host: '127.0.0.1',
      port: $proxy_port,
      method: 'CONNECT',
      path: 'api.anthropic.com:443',
    });

    req.on('connect', (res, socket) => {
      if (res.statusCode !== 200) {
        console.error('CONNECT failed:', res.statusCode);
        process.exit(1);
      }

      const tlsSock = tls.connect({
        socket: socket,
        servername: 'api.anthropic.com',
        ca: caCert,
      }, () => {
        const httpReq = [
          'POST /v1/messages HTTP/1.1',
          'Host: api.anthropic.com',
          'Authorization: Bearer $auth_key',
          'Content-Type: application/json',
          'Content-Length: ' + Buffer.byteLength(body),
          '',
          body,
        ].join('\r\n');

        tlsSock.write(httpReq);

        let data = '';
        tlsSock.on('data', (chunk) => { data += chunk; });
        tlsSock.on('end', () => {
          console.log(data);
          process.exit(0);
        });
      });

      tlsSock.on('error', (e) => {
        console.error('TLS error:', e.message);
        process.exit(1);
      });
    });

    req.on('error', (e) => {
      console.error('Request error:', e.message);
      process.exit(1);
    });

    req.end();
  "
}

@test "proxy writes ready-file with port and accepts connections" {
  start_mock
  start_proxy

  # Port should be numeric
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]

  # nc -z should connect
  run nc -z 127.0.0.1 "$PROXY_PORT"
  [ "$status" -eq 0 ]
}

@test "proxy intercepts api.anthropic.com and writes JSONL with correct usage" {
  start_mock
  start_proxy "usage-test"

  run send_request "$PROXY_PORT" "sk-ant-test-key-5678" "claude-sonnet-4-20250514"
  [ "$status" -eq 0 ]

  # Wait briefly for file write
  sleep 0.5

  # JSONL file should exist
  local jsonl_file="$HOME/.claudev/usage/session-usage-test.jsonl"
  [ -f "$jsonl_file" ]

  # Read and validate the JSONL
  run cat "$jsonl_file"
  [ "$status" -eq 0 ]

  # Parse and verify fields
  run node -e "
    const line = require('fs').readFileSync('$jsonl_file', 'utf8').trim();
    const row = JSON.parse(line);
    const checks = [
      ['session_id', row.session_id === 'usage-test'],
      ['model', row.model === 'claude-sonnet-4-20250514'],
      ['input_tokens', row.input_tokens === 10],
      ['output_tokens', row.output_tokens === 20],
      ['cache_creation_tokens', row.cache_creation_tokens === 5],
      ['cache_read_tokens', row.cache_read_tokens === 3],
      ['token_fingerprint exists', typeof row.token_fingerprint === 'string' && row.token_fingerprint.length === 12],
      ['ts exists', typeof row.ts === 'string' && row.ts.length > 0],
    ];
    let ok = true;
    for (const [name, passed] of checks) {
      if (!passed) { console.log('FAIL: ' + name + ' = ' + JSON.stringify(row[name])); ok = false; }
    }
    if (ok) console.log('all checks passed');
    else process.exit(1);
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "proxy tunnels non-target hosts transparently (no MITM)" {
  start_mock
  start_proxy "tunnel-test"

  # CONNECT to a non-anthropic host — proxy should respond 200
  run node -e "
    const http = require('http');
    const req = http.request({
      host: '127.0.0.1',
      port: $PROXY_PORT,
      method: 'CONNECT',
      path: 'example.com:443',
    });
    req.on('connect', (res, socket) => {
      console.log('status:' + res.statusCode);
      socket.destroy();
      process.exit(res.statusCode === 200 ? 0 : 1);
    });
    req.on('error', (e) => {
      console.error(e.message);
      process.exit(1);
    });
    req.end();
    setTimeout(() => { console.error('timeout'); process.exit(1); }, 5000);
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"status:200"* ]]
}

@test "multi-session: separate JSONL files, no corruption" {
  start_mock

  # Start two proxy instances with different session IDs
  start_proxy "session-a"
  local PORT_A="$PROXY_PORT"

  start_proxy "session-b"
  local PORT_B="$PROXY_PORT"

  # Send one request to each
  run send_request "$PORT_A" "sk-ant-key-aaa" "claude-sonnet-4-20250514"
  [ "$status" -eq 0 ]
  run send_request "$PORT_B" "sk-ant-key-bbb" "claude-sonnet-4-20250514"
  [ "$status" -eq 0 ]

  sleep 0.5

  # Each session file should exist and have exactly 1 line
  local file_a="$HOME/.claudev/usage/session-session-a.jsonl"
  local file_b="$HOME/.claudev/usage/session-session-b.jsonl"

  [ -f "$file_a" ]
  [ -f "$file_b" ]

  run wc -l < "$file_a"
  [[ "${output// /}" == "1" ]]

  run wc -l < "$file_b"
  [[ "${output// /}" == "1" ]]

  # Verify different token fingerprints
  run node -e "
    const fs = require('fs');
    const a = JSON.parse(fs.readFileSync('$file_a', 'utf8').trim());
    const b = JSON.parse(fs.readFileSync('$file_b', 'utf8').trim());
    if (a.session_id !== 'session-a') { console.log('FAIL: a.session_id'); process.exit(1); }
    if (b.session_id !== 'session-b') { console.log('FAIL: b.session_id'); process.exit(1); }
    if (a.token_fingerprint === b.token_fingerprint) { console.log('FAIL: same fingerprint'); process.exit(1); }
    console.log('ok');
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
