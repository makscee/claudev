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
