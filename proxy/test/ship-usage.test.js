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
