#!/usr/bin/env node
'use strict';

const { existsSync, mkdirSync, writeFileSync } = require('fs');
const { join } = require('path');
const { homedir } = require('os');
const { createCaCert } = require('./cert.js');

const caDir = join(homedir(), '.claudev', 'proxy-ca');
const certPath = join(caDir, 'ca.pem');
const keyPath = join(caDir, 'ca-key.pem');

// Idempotent: if both files exist, exit early
if (existsSync(certPath) && existsSync(keyPath)) {
  process.exit(0);
}

// Generate new CA keypair
const { cert, key } = createCaCert();

mkdirSync(caDir, { recursive: true });
writeFileSync(certPath, cert, { mode: 0o644 });
writeFileSync(keyPath, key, { mode: 0o600 });
