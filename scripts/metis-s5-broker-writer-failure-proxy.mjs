#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { existsSync, renameSync, writeFileSync } from 'node:fs';

const brokerScript = process.argv[2] ?? '';
const readyPath = process.env.METIS_S5_BROKER_PROXY_READY ?? '';
const failPath = process.env.METIS_S5_BROKER_PROXY_FAIL ?? '';
const closedPath = process.env.METIS_S5_BROKER_PROXY_WRITER_CLOSED ?? '';
const cleanupPath = process.env.METIS_S5_BROKER_PROXY_CLEANUP ?? '';

function writeAtomic(path, value) {
  if (!path) return;
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, value, { encoding: 'utf8', mode: 0o600 });
  renameSync(temporary, path);
}

if (!brokerScript || !readyPath || !failPath || !closedPath || !cleanupPath) {
  process.stderr.write('broker_proxy_invalid_contract\n');
  process.exit(64);
}

const broker = spawn(process.execPath, [brokerScript], {
  env: process.env,
  stdio: ['pipe', 'pipe', 'ignore'],
});
let writerClosed = false;
let settled = false;

broker.stdin.on('error', () => {
  // Closing the proxy writer is the injected failure contract.
});
process.stdout.on('error', () => {
  // The production owner may close its reader while the broker settles.
});

broker.stdout.on('data', (chunk) => {
  if (!process.stdout.destroyed) process.stdout.write(chunk);
});
process.stdin.on('data', (chunk) => {
  if (!writerClosed && !broker.stdin.destroyed) broker.stdin.write(chunk);
});
process.stdin.on('end', () => {
  if (!broker.stdin.destroyed) broker.stdin.end();
});

writeAtomic(readyPath, JSON.stringify({
  wrapperPid: process.pid,
  brokerPid: broker.pid ?? 0,
  parentPid: process.ppid,
}));

const watcher = setInterval(() => {
  if (!writerClosed && existsSync(failPath)) {
    writerClosed = true;
    process.stdin.destroy();
    broker.stdin.destroy();
    writeAtomic(closedPath, 'writer_closed\n');
  }
  if (existsSync(cleanupPath) && broker.exitCode === null && broker.signalCode === null) {
    broker.kill('SIGKILL');
  }
}, 5);

broker.on('exit', (code, signal) => {
  if (settled) return;
  settled = true;
  clearInterval(watcher);
  if (!process.stdout.destroyed) process.stdout.end();
  process.exitCode = Number.isInteger(code) ? code : signal ? 1 : 0;
});

process.on('SIGTERM', () => {
  if (broker.exitCode === null && broker.signalCode === null) broker.kill('SIGTERM');
});
