#!/usr/bin/env node
'use strict';

const https = require('https');
const { writeFileSync } = require('fs');
const { createCaCert, createServerCert } = require('../../proxy/cert.js');

const readyFile = process.argv[2];
if (!readyFile) {
  console.error('Usage: mock-anthropic.js <ready-file>');
  process.exit(1);
}

// Generate a self-signed CA + server cert for 127.0.0.1
const ca = createCaCert();
const srv = createServerCert(ca.cert, ca.key, '127.0.0.1');

// Write CA cert so callers can find it
writeFileSync(readyFile + '.ca', ca.cert);

const SSE_RESPONSE = [
  'event: message_start',
  'data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":3,"output_tokens":0}}}',
  '',
  'event: content_block_start',
  'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
  '',
  'event: content_block_stop',
  'data: {"type":"content_block_stop","index":0}',
  '',
  'event: message_delta',
  'data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":20}}',
  '',
  'event: message_stop',
  'data: {"type":"message_stop"}',
  '',
].join('\n');

const server = https.createServer({ cert: srv.cert, key: srv.key }, (req, res) => {
  if (req.method === 'POST' && req.url === '/v1/messages') {
    // Collect body (we don't actually need it but must drain)
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'close',
      });
      res.end(SSE_RESPONSE);
    });
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  }
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  writeFileSync(readyFile, String(port));
  console.log(`mock-anthropic listening on 127.0.0.1:${port}`);
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});

process.on('SIGINT', () => {
  server.close(() => process.exit(0));
});
