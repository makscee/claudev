// proxy/test/ship-usage.test.js
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

const { parseJsonl, chunkEvents } = require('../ship-usage.js');

describe('parseJsonl', () => {
  it('parses valid JSONL lines', () => {
    const content = '{"ts":"2026-01-01","input_tokens":10}\n{"ts":"2026-01-02","input_tokens":20}\n';
    const events = parseJsonl(content);
    assert.equal(events.length, 2);
    assert.equal(events[0].input_tokens, 10);
    assert.equal(events[1].input_tokens, 20);
  });

  it('skips malformed lines', () => {
    const content = '{"valid":true}\nNOT JSON\n{"also_valid":true}\n';
    const events = parseJsonl(content);
    assert.equal(events.length, 2);
    assert.equal(events[0].valid, true);
    assert.equal(events[1].also_valid, true);
  });

  it('returns empty array for empty file', () => {
    assert.deepEqual(parseJsonl(''), []);
  });

  it('handles no trailing newline', () => {
    const content = '{"a":1}\n{"b":2}';
    const events = parseJsonl(content);
    assert.equal(events.length, 2);
  });
});

describe('chunkEvents', () => {
  it('returns empty array for empty input', () => {
    assert.deepEqual(chunkEvents([], 1000), []);
  });

  it('returns single batch for < batchSize events', () => {
    const events = Array.from({ length: 999 }, (_, i) => ({ i }));
    const chunks = chunkEvents(events, 1000);
    assert.equal(chunks.length, 1);
    assert.equal(chunks[0].length, 999);
  });

  it('returns single batch for exactly batchSize events', () => {
    const events = Array.from({ length: 1000 }, (_, i) => ({ i }));
    const chunks = chunkEvents(events, 1000);
    assert.equal(chunks.length, 1);
    assert.equal(chunks[0].length, 1000);
  });

  it('splits into multiple batches for > batchSize events', () => {
    const events = Array.from({ length: 1001 }, (_, i) => ({ i }));
    const chunks = chunkEvents(events, 1000);
    assert.equal(chunks.length, 2);
    assert.equal(chunks[0].length, 1000);
    assert.equal(chunks[1].length, 1);
  });
});

const http = require('node:http');
const { mkdtempSync, writeFileSync, readFileSync, existsSync, unlinkSync, mkdirSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');

function makeTmpDir() {
  return mkdtempSync(join(tmpdir(), 'ship-usage-test-'));
}

function startMockServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      resolve({ server, port, url: `http://127.0.0.1:${port}/v1/usage/batch` });
    });
  });
}

function stopServer(server) {
  return new Promise((resolve) => server.close(resolve));
}

describe('postBatch', () => {
  it('sends events with correct auth and body', async () => {
    let received = null;
    const { server, port, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        received = {
          method: req.method,
          path: req.url,
          auth: req.headers.authorization,
          contentType: req.headers['content-type'],
          body: JSON.parse(body),
        };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ inserted: 2, skipped: 0 }));
      });
    });

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    const { postBatch } = require('../ship-usage.js');

    const events = [{ ts: '2026-01-01', input_tokens: 10 }, { ts: '2026-01-02', input_tokens: 20 }];
    const result = await postBatch('test-token-123', events);

    assert.equal(received.method, 'POST');
    assert.equal(received.path, '/v1/usage/batch');
    assert.equal(received.auth, 'Bearer test-token-123');
    assert.equal(received.contentType, 'application/json');
    assert.deepEqual(received.body, { events });
    assert.deepEqual(result, { inserted: 2, skipped: 0 });

    await stopServer(server);
    delete process.env.CLAUDEV_USAGE_API;
  });

  it('rejects on non-200 response', async () => {
    const { server, port, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        res.writeHead(401, { 'Content-Type': 'text/plain' });
        res.end('Unauthorized');
      });
    });

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    const { postBatch } = require('../ship-usage.js');

    await assert.rejects(
      () => postBatch('bad-token', [{ ts: '2026-01-01' }]),
      /HTTP 401/
    );

    await stopServer(server);
    delete process.env.CLAUDEV_USAGE_API;
  });
});

describe('offset sidecar', () => {
  it('resumes from offset after partial failure', async () => {
    let callCount = 0;
    let failOnCall = 2;
    const { server, port, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        callCount++;
        if (callCount === failOnCall) {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end('Internal Server Error');
        } else {
          const parsed = JSON.parse(body);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ inserted: parsed.events.length, skipped: 0 }));
        }
      });
    });

    const tmp = makeTmpDir();
    const tokenPath = join(tmp, 'token');
    const jsonlPath = join(tmp, 'session-99999.jsonl');
    writeFileSync(tokenPath, 'my-token\n');

    // Create 2500 events → 3 batches of 1000, 1000, 500
    const lines = Array.from({ length: 2500 }, (_, i) =>
      JSON.stringify({ ts: `2026-01-01T00:00:${String(i).padStart(2, '0')}`, input_tokens: i })
    ).join('\n') + '\n';
    writeFileSync(jsonlPath, lines);

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    process.env.CLAUDEV_TOKEN_PATH = tokenPath;
    const mod = require('../ship-usage.js');

    // First attempt: batch 1 succeeds (offset=1000), batch 2 fails (500)
    await assert.rejects(() => mod.shipFile(jsonlPath), /HTTP 500/);

    // File should still exist
    assert.equal(existsSync(jsonlPath), true);
    // Offset sidecar should record 1000
    const offsetContent = readFileSync(jsonlPath + '.offset', 'utf8');
    assert.equal(offsetContent.trim(), '1000');

    // Reset mock — now all succeed
    callCount = 0;
    failOnCall = -1;

    // Second attempt: should resume from offset 1000
    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    process.env.CLAUDEV_TOKEN_PATH = tokenPath;
    const mod2 = require('../ship-usage.js');

    const result = await mod2.shipFile(jsonlPath);
    assert.equal(result.shipped, 2500);
    assert.equal(existsSync(jsonlPath), false);
    assert.equal(existsSync(jsonlPath + '.offset'), false);

    await stopServer(server);
    delete process.env.CLAUDEV_USAGE_API;
    delete process.env.CLAUDEV_TOKEN_PATH;
  });

  it('cleans up offset sidecar on full success', async () => {
    const { server, port, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ inserted: 1, skipped: 0 }));
      });
    });

    const tmp = makeTmpDir();
    const tokenPath = join(tmp, 'token');
    const jsonlPath = join(tmp, 'session-99999.jsonl');
    writeFileSync(tokenPath, 'my-token\n');
    writeFileSync(jsonlPath, '{"ts":"2026-01-01","input_tokens":1}\n');
    // Pre-existing stale offset
    writeFileSync(jsonlPath + '.offset', '0');

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    process.env.CLAUDEV_TOKEN_PATH = tokenPath;
    const { shipFile } = require('../ship-usage.js');

    await shipFile(jsonlPath);
    assert.equal(existsSync(jsonlPath), false);
    assert.equal(existsSync(jsonlPath + '.offset'), false);

    await stopServer(server);
    delete process.env.CLAUDEV_USAGE_API;
    delete process.env.CLAUDEV_TOKEN_PATH;
  });
});

const fs = require('node:fs');

describe('isOrphan', () => {
  it('returns true for dead PID', () => {
    delete require.cache[require.resolve('../ship-usage.js')];
    const { isOrphan } = require('../ship-usage.js');

    const tmp = makeTmpDir();
    // PID 99999999 almost certainly doesn't exist
    const filePath = join(tmp, 'session-99999999.jsonl');
    writeFileSync(filePath, '{"ts":"2026-01-01"}\n');

    assert.equal(isOrphan(filePath), true);
  });

  it('returns false for alive PID with fresh mtime', () => {
    delete require.cache[require.resolve('../ship-usage.js')];
    const { isOrphan } = require('../ship-usage.js');

    const tmp = makeTmpDir();
    const filePath = join(tmp, `session-${process.pid}.jsonl`);
    writeFileSync(filePath, '{"ts":"2026-01-01"}\n');

    assert.equal(isOrphan(filePath), false);
  });

  it('returns true for alive PID with stale mtime (>60s)', () => {
    delete require.cache[require.resolve('../ship-usage.js')];
    const { isOrphan } = require('../ship-usage.js');

    const tmp = makeTmpDir();
    const filePath = join(tmp, `session-${process.pid}.jsonl`);
    writeFileSync(filePath, '{"ts":"2026-01-01"}\n');
    // Backdate mtime by 120 seconds
    const past = new Date(Date.now() - 120_000);
    fs.utimesSync(filePath, past, past);

    assert.equal(isOrphan(filePath), true);
  });

  it('returns false for non-numeric PID in filename', () => {
    delete require.cache[require.resolve('../ship-usage.js')];
    const { isOrphan } = require('../ship-usage.js');

    const tmp = makeTmpDir();
    const filePath = join(tmp, 'session-abc.jsonl');
    writeFileSync(filePath, '{"ts":"2026-01-01"}\n');

    assert.equal(isOrphan(filePath), false);
  });
});

describe('sweep', () => {
  it('ships orphaned files and respects cap', async () => {
    let shipped = [];
    const { server, port, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        shipped.push(JSON.parse(body));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ inserted: 1, skipped: 0 }));
      });
    });

    const tmp = makeTmpDir();
    const usageDir = join(tmp, 'usage');
    mkdirSync(usageDir, { recursive: true });
    const tokenPath = join(tmp, 'token');
    writeFileSync(tokenPath, 'my-token\n');

    // Create 3 orphan files with dead PIDs
    for (let i = 0; i < 3; i++) {
      const f = join(usageDir, `session-${99999990 + i}.jsonl`);
      writeFileSync(f, `{"ts":"2026-01-0${i + 1}","input_tokens":${i}}\n`);
    }

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    process.env.CLAUDEV_TOKEN_PATH = tokenPath;
    process.env.CLAUDEV_USAGE_DIR = usageDir;
    const { sweep } = require('../ship-usage.js');

    await sweep();

    assert.equal(shipped.length, 3);
    // All files should be deleted
    const remaining = fs.readdirSync(usageDir).filter(f => f.endsWith('.jsonl'));
    assert.equal(remaining.length, 0);

    await stopServer(server);
    delete process.env.CLAUDEV_USAGE_API;
    delete process.env.CLAUDEV_TOKEN_PATH;
    delete process.env.CLAUDEV_USAGE_DIR;
  });

  it('skips files belonging to alive processes', async () => {
    const tmp = makeTmpDir();
    const usageDir = join(tmp, 'usage');
    mkdirSync(usageDir, { recursive: true });

    const f = join(usageDir, `session-${process.pid}.jsonl`);
    writeFileSync(f, '{"ts":"2026-01-01"}\n');

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_DIR = usageDir;
    const { sweep } = require('../ship-usage.js');

    await sweep();

    assert.equal(existsSync(f), true);

    delete process.env.CLAUDEV_USAGE_DIR;
  });
});

describe('shipFile', () => {
  it('ships events and deletes file on success', async () => {
    let batches = [];
    const { server, port, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => body += c);
      req.on('end', () => {
        batches.push(JSON.parse(body));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ inserted: JSON.parse(body).events.length, skipped: 0 }));
      });
    });

    const tmp = makeTmpDir();
    const tokenPath = join(tmp, 'token');
    const jsonlPath = join(tmp, 'session-99999.jsonl');
    writeFileSync(tokenPath, 'my-token\n');
    writeFileSync(jsonlPath, '{"ts":"2026-01-01","input_tokens":10}\n{"ts":"2026-01-02","input_tokens":20}\n');

    delete require.cache[require.resolve('../ship-usage.js')];
    process.env.CLAUDEV_USAGE_API = url;
    process.env.CLAUDEV_TOKEN_PATH = tokenPath;
    const { shipFile } = require('../ship-usage.js');

    const result = await shipFile(jsonlPath);
    assert.equal(result.shipped, 2);
    assert.equal(existsSync(jsonlPath), false);
    assert.equal(batches.length, 1);
    assert.equal(batches[0].events.length, 2);

    await stopServer(server);
    delete process.env.CLAUDEV_USAGE_API;
    delete process.env.CLAUDEV_TOKEN_PATH;
  });

  it('deletes empty file without posting', async () => {
    const tmp = makeTmpDir();
    const jsonlPath = join(tmp, 'session-99999.jsonl');
    writeFileSync(jsonlPath, '');

    delete require.cache[require.resolve('../ship-usage.js')];
    const { shipFile } = require('../ship-usage.js');

    const result = await shipFile(jsonlPath);
    assert.equal(result.shipped, 0);
    assert.equal(existsSync(jsonlPath), false);
  });
});

describe('shipOne', () => {
  it('POSTs a single-event batch with the bearer token from CLAUDEV_TOKEN_PATH', async () => {
    // Arrange: tmp token file
    const tmp = makeTmpDir();
    const tokenFile = join(tmp, `claudev-shipone-token-${process.pid}`);
    writeFileSync(tokenFile, 'test-token-xyz');
    process.env.CLAUDEV_TOKEN_PATH = tokenFile;

    // Arrange: capture-server replacing void-keys
    let captured = null;
    const { server, url } = await startMockServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        captured = {
          method: req.method,
          path: req.url,
          authHeader: req.headers['authorization'],
          body: JSON.parse(body),
        };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ accepted: 1 }));
      });
    });
    process.env.CLAUDEV_USAGE_API = url;

    // Re-require ship-usage so module-load-time constants pick up env
    delete require.cache[require.resolve('../ship-usage.js')];
    const { shipOne } = require('../ship-usage.js');

    const event = {
      ts: '2026-05-06T12:00:00.000Z',
      session_id: 12345,
      token_fingerprint: 'fp',
      model: 'claude-opus-4-7',
      input_tokens: 100,
      output_tokens: 50,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
    };

    // Act
    await shipOne(event);

    // Assert
    assert.equal(captured.method, 'POST');
    assert.equal(captured.path, '/v1/usage/batch');
    assert.equal(captured.authHeader, 'Bearer test-token-xyz');
    assert.deepEqual(captured.body, { events: [event] });

    // Cleanup
    await stopServer(server);
    unlinkSync(tokenFile);
    delete process.env.CLAUDEV_TOKEN_PATH;
    delete process.env.CLAUDEV_USAGE_API;
  });
});
