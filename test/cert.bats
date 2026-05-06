#!/usr/bin/env bats

load _helpers

setup() {
  CERT_JS="$(_canonpath "$BATS_TEST_DIRNAME/..")/proxy/cert.js"
}

@test "createCaCert returns PEM cert and key" {
  run node -e "
    const { createCaCert } = require('$CERT_JS');
    const { cert, key } = createCaCert();
    if (!cert.startsWith('-----BEGIN CERTIFICATE-----')) process.exit(1);
    if (!key.startsWith('-----BEGIN RSA PRIVATE KEY-----') &&
        !key.startsWith('-----BEGIN PRIVATE KEY-----')) process.exit(1);
    console.log('ok');
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "CA cert is valid X.509 with CA:TRUE and correct CN" {
  run node -e "
    const { createCaCert } = require('$CERT_JS');
    const { cert } = createCaCert();
    process.stdout.write(cert);
  "
  [ "$status" -eq 0 ]
  ca_pem="$output"

  # Verify it's valid X.509
  run bash -c "echo '$ca_pem' | openssl x509 -noout -subject -text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CN = claudev-proxy-ca"* ]] || [[ "$output" == *"CN=claudev-proxy-ca"* ]]
  [[ "$output" == *"CA:TRUE"* ]]
}

@test "createServerCert returns cert signed by CA for given hostname" {
  tmpdir="$(mktemp -d)"
  local tmpdir_w
  tmpdir_w="$(_canonpath "$tmpdir")"
  node -e "
    const { createCaCert, createServerCert } = require('$CERT_JS');
    const ca = createCaCert();
    const srv = createServerCert(ca.cert, ca.key, 'test.local');
    require('fs').writeFileSync('$tmpdir_w/ca.pem', ca.cert);
    require('fs').writeFileSync('$tmpdir_w/srv.pem', srv.cert);
  "

  # Verify server cert against CA
  run openssl verify -CAfile "$tmpdir/ca.pem" "$tmpdir/srv.pem"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]

  # Check SAN contains hostname
  run openssl x509 -in "$tmpdir/srv.pem" -noout -text
  [ "$status" -eq 0 ]
  [[ "$output" == *"test.local"* ]]

  rm -rf "$tmpdir"
}

@test "TLS handshake succeeds with CA-signed server cert" {
  run node -e "
    const tls = require('tls');
    const { createCaCert, createServerCert } = require('$CERT_JS');
    const ca = createCaCert();
    const srv = createServerCert(ca.cert, ca.key, 'localhost');

    const server = tls.createServer({ cert: srv.cert, key: srv.key }, (socket) => {
      socket.end('hello');
    });

    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      const client = tls.connect({ host: '127.0.0.1', port, ca: ca.cert, servername: 'localhost' }, () => {
        let data = '';
        client.on('data', (d) => data += d);
        client.on('end', () => {
          client.destroy();
          server.close();
          if (data === 'hello') {
            console.log('ok');
            process.exit(0);
          } else {
            process.exit(1);
          }
        });
      });
      client.on('error', (e) => { console.error(e.message); process.exit(1); });
    });
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
