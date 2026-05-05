#!/usr/bin/env node
'use strict';

const http = require('http');
const net = require('net');
const tls = require('tls');
const crypto = require('crypto');
const { readFileSync, writeFileSync, mkdirSync, appendFileSync } = require('fs');
const { join } = require('path');
const { homedir } = require('os');
const { createServerCert } = require('./cert.js');

const TARGET_HOST = process.env.CLAUDEV_PROXY_TARGET_HOST || 'api.anthropic.com';
const TARGET_PORT = parseInt(process.env.CLAUDEV_PROXY_TARGET_PORT || '443', 10);
const SESSION_ID = process.env.CLAUDEV_SESSION_ID || String(process.ppid);
const INTERCEPT_HOST = 'api.anthropic.com';

const readyFile = process.argv[2];
if (!readyFile) {
  console.error('Usage: proxy.js <ready-file>');
  process.exit(1);
}

// Load CA certs
const caDir = join(homedir(), '.claudev', 'proxy-ca');
const caCert = readFileSync(join(caDir, 'ca.pem'), 'utf8');
const caKey = readFileSync(join(caDir, 'ca-key.pem'), 'utf8');

// Pre-generate server cert for the intercept host
const serverCert = createServerCert(caCert, caKey, INTERCEPT_HOST);

// Ensure usage directory exists
const usageDir = join(homedir(), '.claudev', 'usage');
mkdirSync(usageDir, { recursive: true });

const server = http.createServer((req, res) => {
  res.writeHead(400);
  res.end('This is a CONNECT proxy');
});

server.on('connect', (req, clientSocket, head) => {
  const [host, portStr] = req.url.split(':');
  const port = parseInt(portStr || '443', 10);
  if (host === INTERCEPT_HOST) {
    handleMitm(clientSocket, head, host, port);
  } else {
    handleTunnel(clientSocket, head, host, port);
  }
});

function handleTunnel(clientSocket, head, host, port) {
  const upstream = net.connect(port, host, () => {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head.length > 0) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstream.destroy());
}

function handleMitm(clientSocket, head, host, port) {
  clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');

  // Wrap client socket in TLS server
  const tlsServer = new tls.TLSSocket(clientSocket, {
    isServer: true,
    cert: serverCert.cert,
    key: serverCert.key,
    ALPNProtocols: ['http/1.1'],
  });

  tlsServer.once('secure', () => {
    if (head.length > 0) tlsServer.unshift(head);
  });

  // Buffer the full HTTP request from client
  let requestData = Buffer.alloc(0);
  let headersParsed = false;
  let contentLength = 0;
  let headerEnd = -1;
  let tokenFingerprint = '';
  let model = '';

  tlsServer.on('data', (chunk) => {
    requestData = Buffer.concat([requestData, chunk]);

    if (!headersParsed) {
      headerEnd = requestData.indexOf('\r\n\r\n');
      if (headerEnd === -1) return;
      headersParsed = true;

      const headersStr = requestData.slice(0, headerEnd).toString();
      const lines = headersStr.split('\r\n');

      // Extract path from request line
      const requestLine = lines[0] || '';
      const requestPath = requestLine.split(' ')[1] || '';

      // Extract Authorization header
      for (const line of lines) {
        const lower = line.toLowerCase();
        if (lower.startsWith('authorization:')) {
          const val = line.slice('authorization:'.length).trim();
          // void-keys stores sha256(rawToken); strip the "Bearer " scheme so
          // fingerprints round-trip across proxy ingest and key registration.
          const raw = val.replace(/^Bearer\s+/i, '');
          tokenFingerprint = crypto.createHash('sha256').update(raw).digest('hex');
        }
        if (lower.startsWith('content-length:')) {
          contentLength = parseInt(line.slice('content-length:'.length).trim(), 10);
        }
      }

      tlsServer._requestPath = requestPath;
    }

    // Check if we have the full request
    if (headersParsed) {
      const bodyStart = headerEnd + 4;
      const bodyReceived = requestData.length - bodyStart;

      if (bodyReceived >= contentLength) {
        // Extract model from body
        const body = requestData.slice(bodyStart, bodyStart + contentLength).toString();
        try {
          const parsed = JSON.parse(body);
          model = parsed.model || '';
        } catch (e) {
          // Try regex fallback
          const m = body.match(/"model"\s*:\s*"([^"]+)"/);
          if (m) model = m[1];
        }

        // Forward to upstream
        forwardToUpstream(tlsServer, requestData, tlsServer._requestPath, tokenFingerprint, model);
        requestData = Buffer.alloc(0);
        headersParsed = false;
      }
    }
  });

  tlsServer.on('error', () => { clientSocket.destroy(); });
}

function forwardToUpstream(tlsClient, requestData, requestPath, tokenFingerprint, model) {
  const upstream = tls.connect({
    host: TARGET_HOST,
    port: TARGET_PORT,
    servername: INTERCEPT_HOST,
    rejectUnauthorized: process.env.NODE_TLS_REJECT_UNAUTHORIZED !== '0',
  }, () => {
    if (isMessagesEndpoint) {
      const headerEnd = requestData.indexOf('\r\n\r\n');
      const headers = requestData.slice(0, headerEnd).toString().replace(/\r\nAccept-Encoding:[^\r\n]*/i, '');
      upstream.write(Buffer.concat([Buffer.from(headers), requestData.slice(headerEnd)]));
    } else {
      upstream.write(requestData);
    }
  });

  const isMessagesEndpoint = /\/(v1\/messages|api\/chat|api\/claude_code\/chat|messages)/.test(requestPath);
  let headersDone = false;
  let responseBuf = '';
  let sseLineBuf = '';
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheCreationTokens = 0;
  let cacheReadTokens = 0;
  let usageFound = false;

  upstream.on('data', (chunk) => {
    tlsClient.write(chunk);
    if (!isMessagesEndpoint) return;

    if (!headersDone) {
      responseBuf += chunk.toString();
      const idx = responseBuf.indexOf('\r\n\r\n');
      if (idx === -1) return;
      headersDone = true;
      sseLineBuf = responseBuf.slice(idx + 4);
      responseBuf = '';
    } else {
      sseLineBuf += chunk.toString();
    }

    const lines = sseLineBuf.split('\n');
    sseLineBuf = lines.pop();
    for (const line of lines) {
      if (!line.startsWith('data: ')) continue;
      const dataStr = line.slice(6).trim();
      if (dataStr === '[DONE]') {
        if (usageFound) writeUsage(tokenFingerprint, model, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens);
        usageFound = false;
        continue;
      }
      try {
        const data = JSON.parse(dataStr);
        if (data.type === 'message_start' && data.message && data.message.usage) {
          const u = data.message.usage;
          inputTokens = u.input_tokens || 0;
          cacheCreationTokens = u.cache_creation_input_tokens || 0;
          cacheReadTokens = u.cache_read_input_tokens || 0;
          usageFound = true;
        }
        if (data.type === 'message_delta' && data.usage) {
          outputTokens = data.usage.output_tokens || 0;
          usageFound = true;
        }
        if (data.type === 'message_stop' && usageFound) {
          writeUsage(tokenFingerprint, model, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens);
          usageFound = false;
        }
      } catch (e) {}
    }
  });

  upstream.on('end', () => tlsClient.end());
  upstream.on('error', () => { tlsClient.destroy(); });
  tlsClient.on('error', () => { upstream.destroy(); });
}

function writeUsage(tokenFingerprint, model, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens) {
  const row = JSON.stringify({
    ts: new Date().toISOString(),
    session_id: SESSION_ID,
    token_fingerprint: tokenFingerprint,
    model: model,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_creation_tokens: cacheCreationTokens,
    cache_read_tokens: cacheReadTokens,
  });
  const filePath = join(usageDir, `session-${SESSION_ID}.jsonl`);
  appendFileSync(filePath, row + '\n');
}

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  writeFileSync(readyFile, String(port));
  console.log(`claudev-proxy listening on 127.0.0.1:${port}`);
});

function gracefulExit() {
  // server.close() waits for in-flight connections to drain. With keep-alive
  // sockets from a now-dead claude process those never close, so force-drop
  // active sockets and arm a hard deadline so the parent shell's `wait` returns.
  try { server.closeAllConnections?.(); } catch {}
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500).unref();
}

process.on('SIGTERM', gracefulExit);
process.on('SIGINT', gracefulExit);
