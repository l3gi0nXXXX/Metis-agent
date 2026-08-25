#!/usr/bin/env node

import http from 'node:http';
import { existsSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import readline from 'node:readline';

const mode = process.argv[2] ?? 'gcm';
const stderrBurstMatch = /^gcm-stderr-burst-(\d+)$/u.exec(mode);
const gcmMode = mode === 'gcm' || stderrBurstMatch !== null;
const serviceId = process.env.METIS_SERVICE_PLUGIN_ID || 'stdio-service';
const sessionId = process.env.METIS_SERVICE_PLUGIN_SESSION_ID || `${serviceId}-fixture`;
const leasePath = process.env.METIS_SERVICE_PLUGIN_LEASE_PATH || '';
const parentPid = Number(process.env.METIS_SERVICE_PLUGIN_PARENT_PID || 0);
const markerPath = process.env.METIS_STDIO_FIXTURE_MARKER_PATH || '';
const releasePath = process.env.METIS_STDIO_FIXTURE_RELEASE_PATH || '';
const stopFrameMarkerPath = process.env.METIS_STDIO_FIXTURE_STOP_FRAME_MARKER_PATH || '';
const portClosedMarkerPath = process.env.METIS_STDIO_FIXTURE_PORT_CLOSED_MARKER_PATH || '';
const rootPidPath = process.env.METIS_STDIO_FIXTURE_ROOT_PID_PATH || '';
const childPidPath = process.env.METIS_STDIO_FIXTURE_CHILD_PID_PATH || '';

function frame(value, onWritten) {
  process.stdout.write(`${JSON.stringify(value)}\n`, onWritten);
}

function initFrame(onWritten) {
  frame({
    type: 'response', frameId: 'init-1', serviceId, method: 'initialize',
    payload: { ok: true, status: 'ready' },
  }, onWritten);
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
  if (mode === 'ignore-term' || mode === 'ignore-term-tree') return;
  const port = server?.address()?.port ?? 0;
  writeLease('stopped', port);
  server?.close(() => {
    if (portClosedMarkerPath) writeFileSync(portClosedMarkerPath, 'closed\n');
    process.exit(0);
  });
  if (!server) {
    if (portClosedMarkerPath) writeFileSync(portClosedMarkerPath, 'closed\n');
    process.exit(0);
  }
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
  if (mode === 'slow-init') setTimeout(initFrame, 800);
  else if (mode === 'exit-after-init') {
    initFrame(() => {
      writeLease('running');
      if (markerPath) writeFileSync(markerPath, 'ready\n');
      const releaseTimer = setInterval(() => {
        if (!releasePath || !existsSync(releasePath)) return;
        clearInterval(releaseTimer);
        writeLease('stopped');
        process.exit(0);
      }, 1);
    });
  } else initFrame();
  if (mode === 'exit-after-delay') setTimeout(() => process.exit(0), 500);
  if (mode === 'delayed-graceful-stop') writeLease('running');
  if (mode === 'latch-event') {
    const latch = setInterval(() => {
      if (!releasePath || !existsSync(releasePath)) return;
      clearInterval(latch);
      for (let index = 0; index < 9; index += 1) process.stdout.write(`WARN released old owner ${index}\n`);
      setTimeout(() => process.exit(0), 20);
    }, 10);
  }
}

if (mode === 'ignore-term' || mode === 'ignore-term-tree') {
  process.on('SIGTERM', () => {});
  process.on('SIGHUP', () => {});
  setInterval(() => {}, 1000).unref();
} else {
  process.once('SIGTERM', () => {
    if (mode === 'delayed-graceful-stop' && markerPath) writeFileSync(markerPath, 'term\n');
    shutdownFixture();
  });
  process.once('SIGHUP', shutdownFixture);
}

if (mode === 'ignore-term-tree') {
  if (rootPidPath) writeFileSync(rootPidPath, `${process.pid}\n`);
  const child = spawn(process.execPath, ['-e', "process.on('SIGTERM',()=>{});process.on('SIGHUP',()=>{});setInterval(()=>{},1000)"], {
    detached: false,
    stdio: 'ignore',
  });
  if (childPidPath) writeFileSync(childPidPath, `${child.pid}\n`);
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
  if (mode === 'ignore-term' || mode === 'ignore-term-tree') return;
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
    if (stopFrameMarkerPath) {
      writeFileSync(stopFrameMarkerPath, JSON.stringify({
        correlationId: request.correlationId ?? '',
        serviceId: request.serviceId ?? '',
      }));
    }
    if (mode === 'delayed-graceful-stop') {
      setTimeout(() => {
        if (markerPath) writeFileSync(markerPath, 'graceful\n');
        writeLease('stopped');
        process.exit(0);
      }, 150);
      return;
    }
    shutdownFixture();
    return;
  }
  if (gcmMode) {
    const gitCodeEvent = serviceId === 'gitcode-monitor';
    frame({
      type: 'event', frameId: `event-${Date.now()}`, serviceId,
      method: 'emitCapabilityEvent',
      capabilityId: gitCodeEvent ? 'gitcode.event.accepted' : 'stdio.event.accepted',
      payload: gitCodeEvent ? {
        jobId: 'webhook-s3-job', eventId: 's3-event', repo: 'Cangjie/community',
        kind: 'issue', number: '3', title: '停止中文🙂',
        url: 'https://gitcode.com/Cangjie/community/issues/3',
        author: 'fixture-user', content: 'dispatch blocker',
      } : { ok: true, status: 'accepted', text: '事件中文🙂' },
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
