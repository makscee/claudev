'use strict';

const { execFileSync } = require('child_process');
const { mkdtempSync, writeFileSync, readFileSync, rmSync } = require('fs');
const { join } = require('path');
const { tmpdir } = require('os');

/**
 * Create a self-signed CA certificate.
 * CN=claudev-proxy-ca, CA:TRUE, RSA 2048, 3650 days.
 * @returns {{ cert: string, key: string }} PEM-encoded cert and key
 */
function createCaCert() {
  const tmp = mkdtempSync(join(tmpdir(), 'claudev-ca-'));
  try {
    const keyPath = join(tmp, 'ca-key.pem');
    const certPath = join(tmp, 'ca.pem');

    // Generate RSA 2048 private key
    execFileSync('openssl', [
      'req', '-new', '-x509',
      '-newkey', 'rsa:2048',
      '-nodes',
      '-keyout', keyPath,
      '-out', certPath,
      '-days', '3650',
      '-subj', '/CN=claudev-proxy-ca',
      '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
    ], { stdio: 'pipe' });

    return {
      cert: readFileSync(certPath, 'utf8'),
      key: readFileSync(keyPath, 'utf8'),
    };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

/**
 * Create a server certificate signed by the given CA.
 * @param {string} caCertPem - PEM-encoded CA certificate
 * @param {string} caKeyPem  - PEM-encoded CA private key
 * @param {string} hostname  - hostname for SAN
 * @returns {{ cert: string, key: string }} PEM-encoded cert and key
 */
function createServerCert(caCertPem, caKeyPem, hostname) {
  const tmp = mkdtempSync(join(tmpdir(), 'claudev-srv-'));
  try {
    const caKeyPath = join(tmp, 'ca-key.pem');
    const caCertPath = join(tmp, 'ca.pem');
    const srvKeyPath = join(tmp, 'srv-key.pem');
    const csrPath = join(tmp, 'srv.csr');
    const srvCertPath = join(tmp, 'srv.pem');
    const extPath = join(tmp, 'ext.cnf');

    writeFileSync(caCertPath, caCertPem);
    writeFileSync(caKeyPath, caKeyPem, { mode: 0o600 });

    // Write extensions config for SAN
    writeFileSync(extPath, [
      'basicConstraints=CA:FALSE',
      'keyUsage=critical,digitalSignature,keyEncipherment',
      'extendedKeyUsage=serverAuth',
      `subjectAltName=DNS:${hostname}`,
    ].join('\n') + '\n');

    // Generate server key
    execFileSync('openssl', [
      'genrsa', '-out', srvKeyPath, '2048',
    ], { stdio: 'pipe' });

    // Generate CSR
    execFileSync('openssl', [
      'req', '-new',
      '-key', srvKeyPath,
      '-out', csrPath,
      '-subj', `/CN=${hostname}`,
    ], { stdio: 'pipe' });

    // Sign with CA
    execFileSync('openssl', [
      'x509', '-req',
      '-in', csrPath,
      '-CA', caCertPath,
      '-CAkey', caKeyPath,
      '-CAcreateserial',
      '-out', srvCertPath,
      '-days', '825',
      '-extfile', extPath,
    ], { stdio: 'pipe' });

    return {
      cert: readFileSync(srvCertPath, 'utf8'),
      key: readFileSync(srvKeyPath, 'utf8'),
    };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

module.exports = { createCaCert, createServerCert };
