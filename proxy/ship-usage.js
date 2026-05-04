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

module.exports = { parseJsonl, chunkEvents, BATCH_SIZE, SWEEP_CAP, STALE_MTIME_MS };
