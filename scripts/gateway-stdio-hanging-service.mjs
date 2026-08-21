#!/usr/bin/env node

import http from 'node:http';
import { writeFileSync } from 'node:fs';
import readline from 'node:readline';

const mode = process.argv[2] ?? 'gcm';
const stderrBurstMatch = /^gcm-stderr-burst-(\d+)$/u.exec(mode);
const gcmMode = mode === 'gcm' || stderrBurstMatch !== null;
const serviceId = process.env.METIS_SERVICE_PLUGIN_ID || 'stdio-service';
const sessionId = process.env.METIS_SERVICE_PLUGIN_SESSION_ID || `${serviceId}-fixture`;
const leasePath = process.env.METIS_SERVICE_PLUGIN_LEASE_PATH || '';
const parentPid = Number(process.env.METIS_SERVICE_PLUGIN_PARENT_PID || 0);

function frame(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function initFrame() {
  frame({
    type: 'response', frameId: 'init-1', serviceId, method: 'initialize',
    payload: { ok: true, status: 'ready' },
  });
}

function writeLease(state, port = 0) {
  if (!leasePath) return;
  writeFileSync(leasePath, JSON.stringify({
    state, status: state, pluginId: serviceId, sessionId,
    pid: process.pid, parentPid, bindHost: '127.0.0.1', port,
    startedAtMs: Date.now(), lastHeartbeatMs: Date.now(),
  }));
}

let server;
function shutdownFixture() {
  if (mode === 'ignore-term') return;
  const port = server?.address()?.port ?? 0;
  writeLease('stopped', port);
  server?.close(() => process.exit(0));
  if (!server) process.exit(0);
}

if (gcmMode) {
  server = http.createServer((request, response) => {
    request.resume();
    request.once('end', () => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{"ok":true}');
    });
  });
  server.listen(0, '127.0.0.1', () => writeLease('running', server.address().port));
  if (stderrBurstMatch !== null) {
    const stderrBurstLines = Number(stderrBurstMatch[1]);
    for (let index = 0; index < stderrBurstLines; index += 1) {
      process.stderr.write(`fixture diagnostic ${index} 中文🙂\n`);
    }
  }
  initFrame();
} else {
  initFrame();
  if (mode === 'exit-after-init') setTimeout(() => process.exit(0), 5);
  if (mode === 'exit-after-delay') setTimeout(() => process.exit(0), 500);
}

if (mode === 'ignore-term') {
  process.on('SIGTERM', () => {});
  process.on('SIGHUP', () => {});
  setInterval(() => {}, 1000).unref();
} else {
  process.once('SIGTERM', shutdownFixture);
  process.once('SIGHUP', shutdownFixture);
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', (line) => {
  let request;
  try { request = JSON.parse(line); }
  catch { return; }
  if (mode === 'invalid-utf8') {
    process.stdout.write(Buffer.from([0xc3, 0x28, 0x0a]));
    return;
  }
  if (mode === 'crash') {
    process.exit(7);
  }
  if (mode === 'ignore-term') return;
  if (mode === 'malformed') {
    for (let index = 0; index < 9; index += 1) {
      process.stdout.write(`{malformed-json-${index}\n`);
    }
  }
  if (mode.startsWith('noise-')) {
    const count = Number(mode.slice('noise-'.length));
    for (let index = 0; index < count; index += 1) {
      process.stdout.write(`WARN fixture stdout noise ${index}\n`);
    }
  }
  if (request.method === 'stop') {
    shutdownFixture();
    return;
  }
  if (gcmMode) {
    frame({
      type: 'event', frameId: `event-${Date.now()}`, serviceId,
      method: 'emitCapabilityEvent', capabilityId: 'stdio.event.accepted',
      payload: { ok: true, status: 'accepted', text: '事件中文🙂' },
    });
  }
  frame({
    type: 'response', frameId: `response-${Date.now()}`, serviceId,
    method: request.method || 'invokeCapability',
    capabilityId: request.capabilityId || '', correlationId: request.correlationId || '',
    payload: { ok: true, status: 'ok', text: '中文🙂' },
  });
});

input.once('close', () => {
  shutdownFixture();
});
