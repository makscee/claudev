#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const BATCH_SIZE = 1000;
const SWEEP_CAP = 50;
const STALE_MTIME_MS = 60 * 1000;

const USAGE_DIR = process.env.CLAUDEV_USAGE_DIR || path.join(os.homedir(), '.claudev', 'usage');
const TOKEN_PATH = process.env.CLAUDEV_TOKEN_PATH || path.join(os.homedir(), '.claudev', 'token');
const API_URL = process.env.CLAUDEV_USAGE_API || 'https://keys.makscee.ru/v1/usage/batch';

function parseJsonl(content) {
  const events = [];
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    try {
      events.push(JSON.parse(line));
    } catch (e) {
      process.stderr.write(`ship-usage: skipping malformed line ${i + 1}: ${e.message}\n`);
    }
  }
  return events;
}

function chunkEvents(events, size) {
  const chunks = [];
  for (let i = 0; i < events.length; i += size) {
    chunks.push(events.slice(i, i + size));
  }
  return chunks;
}

function postBatch(token, events) {
  const url = new URL(API_URL);
  const httpModule = url.protocol === 'https:' ? require('https') : require('http');
  const body = JSON.stringify({ events });

  return new Promise((resolve, reject) => {
    const req = httpModule.request({
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        if (res.statusCode === 200) {
          try {
            resolve(JSON.parse(data));
          } catch (e) {
            reject(new Error(`Invalid JSON in 200 response: ${data.slice(0, 200)}`));
          }
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${data}`));
        }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function shipOne(event) {
  const token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
  await postBatch(token, [event]);
}

function readOffset(filePath) {
  try {
    return parseInt(fs.readFileSync(filePath + '.offset', 'utf8').trim(), 10) || 0;
  } catch {
    return 0;
  }
}

function writeOffset(filePath, offset) {
  fs.writeFileSync(filePath + '.offset', String(offset));
}

function deleteOffset(filePath) {
  try { fs.unlinkSync(filePath + '.offset'); } catch {}
}

async function shipFile(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const allEvents = parseJsonl(content);

  if (allEvents.length === 0) {
    fs.unlinkSync(filePath);
    deleteOffset(filePath);
    return { shipped: 0 };
  }

  let token;
  try {
    token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
  } catch (e) {
    process.stderr.write(`ship-usage: token file missing: ${e.message}\n`);
    process.exitCode = 1;
    throw e;
  }

  const offset = readOffset(filePath);
  const events = allEvents.slice(offset);

  if (events.length === 0) {
    fs.unlinkSync(filePath);
    deleteOffset(filePath);
    return { shipped: allEvents.length };
  }

  const batches = chunkEvents(events, BATCH_SIZE);
  let shipped = offset;

  for (const batch of batches) {
    await postBatch(token, batch);
    shipped += batch.length;
    writeOffset(filePath, shipped);
  }

  fs.unlinkSync(filePath);
  deleteOffset(filePath);
  process.stderr.write(`ship-usage: shipped ${shipped} events\n`);
  return { shipped };
}

function isOrphan(filePath) {
  const basename = path.basename(filePath);
  const match = basename.match(/^session-(\d+)\.jsonl$/);
  if (!match) return false;

  const pid = parseInt(match[1], 10);

  try {
    process.kill(pid, 0);
    // PID alive — check mtime for zombie/stale
    const stat = fs.statSync(filePath);
    return (Date.now() - stat.mtimeMs) > STALE_MTIME_MS;
  } catch {
    return true;
  }
}

async function sweep() {
  if (!fs.existsSync(USAGE_DIR)) return;

  const files = fs.readdirSync(USAGE_DIR)
    .filter((f) => /^session-.*\.jsonl$/.test(f))
    .map((f) => {
      const full = path.join(USAGE_DIR, f);
      const stat = fs.statSync(full);
      return { path: full, mtimeMs: stat.mtimeMs };
    })
    .sort((a, b) => a.mtimeMs - b.mtimeMs)
    .slice(0, SWEEP_CAP);

  for (const file of files) {
    if (!isOrphan(file.path)) continue;
    try {
      await shipFile(file.path);
    } catch (e) {
      process.stderr.write(`ship-usage: sweep failed for ${path.basename(file.path)}: ${e.message}\n`);
    }
  }
}

async function main() {
  const args = process.argv.slice(2);

  if (args[0] === '--sweep') {
    await sweep();
    process.exit(0);
  }

  if (args.length !== 1) {
    process.stderr.write('Usage: ship-usage.js <path-to-jsonl> | --sweep\n');
    process.exit(1);
  }

  const filePath = args[0];
  if (!fs.existsSync(filePath)) {
    process.exit(0);
  }

  await shipFile(filePath);
}

if (require.main === module) {
  main().catch((e) => {
    process.stderr.write(`ship-usage: ${e.message}\n`);
    process.exit(1);
  });
}

module.exports = {
  parseJsonl, chunkEvents, postBatch, shipFile, shipOne,
  readOffset, writeOffset, deleteOffset,
  isOrphan, sweep,
  BATCH_SIZE, SWEEP_CAP, STALE_MTIME_MS,
};
