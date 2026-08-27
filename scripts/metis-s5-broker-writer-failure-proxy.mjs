#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { existsSync, renameSync, writeFileSync } from 'node:fs';
import { TextDecoder } from 'node:util';

const brokerScript = process.argv[2] ?? '';
const readyPath = process.env.METIS_S5_BROKER_PROXY_READY ?? '';
const failPath = process.env.METIS_S5_BROKER_PROXY_FAIL ?? '';
const closedPath = process.env.METIS_S5_BROKER_PROXY_WRITER_CLOSED ?? '';
const cleanupPath = process.env.METIS_S5_BROKER_PROXY_CLEANUP ?? '';
const dropDeliveryId = process.env.METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID ?? '';
const admissionSeenPath = process.env.METIS_S5_BROKER_PROXY_ADMISSION_SEEN ?? '';
const completionDroppedPath = process.env.METIS_S5_BROKER_PROXY_COMPLETION_DROPPED ?? '';
const expectedGeneration = Number.parseInt(process.env.METIS_STDIO_BROKER_GENERATION ?? '', 10);
const writerInputs = [failPath, closedPath, cleanupPath];
const dropInputs = [dropDeliveryId, admissionSeenPath, completionDroppedPath];
const writerMode = writerInputs.some((value) => value.length > 0);
const dropMode = dropInputs.some((value) => value.length > 0);

function writeAtomic(path, value) {
  if (!path) return;
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, value, { encoding: 'utf8', mode: 0o600 });
  renameSync(temporary, path);
}

function invalidContract() {
  process.stderr.write('broker_proxy_invalid_contract\n');
  process.exit(64);
}

if (
  !brokerScript ||
  !readyPath ||
  (!writerMode && !dropMode) ||
  (writerMode && !writerInputs.every((value) => value.length > 0)) ||
  (dropMode && (!dropInputs.every((value) => value.length > 0) || !Number.isSafeInteger(expectedGeneration) || expectedGeneration <= 0))
) {
  invalidContract();
}

const broker = spawn(process.execPath, [brokerScript], {
  env: process.env,
  stdio: ['pipe', 'pipe', 'ignore'],
});
let writerClosed = false;
let settled = false;
let inputPending = Buffer.alloc(0);
let brokerOutputPending = Buffer.alloc(0);
let brokerGeneration = 0;
let brokerHelloPid = 0;
let ownerPid = 0;
let ownerId = '';
let boundAttemptToken = '';
let boundEventId = '';
let boundOwnerId = '';
let pendingAdmission = null;
let completionDropped = false;
let markerSequence = 0;
const outputQueue = [];
let outputWriting = false;
let outputEndRequested = false;
const fatalUtf8Decoder = new TextDecoder('utf-8', { fatal: true });

function publishReady() {
  writeAtomic(readyPath, JSON.stringify({
    wrapperPid: process.pid,
    brokerPid: broker.pid ?? 0,
    parentPid: process.ppid,
    generation: brokerGeneration,
    helloBrokerPid: brokerHelloPid,
    ownerPid,
    ownerId,
  }));
}

function finishOutputIfReady() {
  if (outputEndRequested && !outputWriting && outputQueue.length === 0 && !process.stdout.destroyed) {
    process.stdout.end();
  }
}

function flushOutput() {
  if (outputWriting || process.stdout.destroyed) return;
  const next = outputQueue.shift();
  if (next === undefined) {
    finishOutputIfReady();
    return;
  }
  outputWriting = true;
  process.stdout.write(next.bytes, (error) => {
    outputWriting = false;
    if (error) {
      outputQueue.length = 0;
      return;
    }
    try { next.onWritten(); } catch { /* The marker assertion reports an injection failure. */ }
    flushOutput();
  });
}

function enqueueOutput(bytes, onWritten = () => {}) {
  if (process.stdout.destroyed) return;
  outputQueue.push({ bytes, onWritten });
  flushOutput();
}

function parseJsonLine(bytes) {
  try {
    return JSON.parse(fatalUtf8Decoder.decode(bytes));
  } catch {
    return null;
  }
}

function safeProtocolString(value) {
  return typeof value === 'string' && value.length > 0 && !/[\0\r\n]/u.test(value);
}

function durableAckFromOwnerWrite(frame) {
  if (
    !dropMode ||
    frame === null ||
    typeof frame !== 'object' ||
    Array.isArray(frame) ||
    frame.type !== 'owner.write' ||
    !safeProtocolString(frame.ownerId) ||
    !safeProtocolString(frame.requestId) ||
    !safeProtocolString(frame.line)
  ) {
    return null;
  }
  try {
    const serviceFrame = JSON.parse(frame.line);
    if (
      serviceFrame === null ||
      typeof serviceFrame !== 'object' ||
      Array.isArray(serviceFrame) ||
      !safeProtocolString(serviceFrame.frameId) ||
      serviceFrame.serviceId !== 'gitcode-monitor' ||
      serviceFrame.method !== 'emitCapabilityEvent' ||
      serviceFrame.capabilityId !== 'gitcode.event.accepted' ||
      !safeProtocolString(serviceFrame.correlationId) ||
      serviceFrame.payload === null ||
      typeof serviceFrame.payload !== 'object' ||
      Array.isArray(serviceFrame.payload)
    ) {
      return null;
    }
    const payload = serviceFrame.payload;
    if (
      payload.protocolVersion !== '1.0' ||
      payload.deliveryId !== dropDeliveryId ||
      !safeProtocolString(payload.eventId) ||
      !safeProtocolString(payload.attemptToken) ||
      !safeProtocolString(payload.phase) ||
      !safeProtocolString(payload.status)
    ) {
      return null;
    }
    if (
      serviceFrame.type === 'response' &&
      payload.phase === 'admission' &&
      payload.status === 'accepted' &&
      serviceFrame.correlationId === payload.attemptToken
    ) {
      return { phase: 'admission', ownerId: frame.ownerId, requestId: frame.requestId, eventId: payload.eventId, attemptToken: payload.attemptToken };
    }
    if (
      serviceFrame.type === 'request' &&
      payload.phase === 'completion' &&
      payload.status === 'completed' &&
      serviceFrame.correlationId !== payload.attemptToken
    ) {
      return { phase: 'completion', ownerId: frame.ownerId, requestId: frame.requestId, eventId: payload.eventId, attemptToken: payload.attemptToken };
    }
    return null;
  } catch {
    return null;
  }
}

function writeAckMarker(path, status, ack) {
  markerSequence += 1;
  writeAtomic(path, `${JSON.stringify({
    sequence: markerSequence,
    status,
    generation: brokerGeneration,
    ownerId: ack.ownerId,
    requestId: ack.requestId,
    deliveryId: dropDeliveryId,
    eventId: ack.eventId,
    attemptToken: ack.attemptToken,
  })}\n`);
}

function forwardInputLine(lineWithNewline) {
  const line = lineWithNewline.subarray(0, lineWithNewline.length - 1);
  const frame = parseJsonLine(line);
  const ack = durableAckFromOwnerWrite(frame);
  if (ack?.phase === 'admission' && boundAttemptToken.length === 0 && pendingAdmission === null) {
    pendingAdmission = ack;
  }
  if (
    ack?.phase === 'completion' &&
    boundAttemptToken.length > 0 &&
    ack.attemptToken === boundAttemptToken &&
    ack.eventId === boundEventId &&
    ack.ownerId === boundOwnerId &&
    !completionDropped
  ) {
    if (brokerGeneration !== expectedGeneration || brokerHelloPid !== (broker.pid ?? 0)) {
      invalidContract();
    }
    completionDropped = true;
    enqueueOutput(Buffer.from(`${JSON.stringify({
      type: 'owner.written',
      generation: brokerGeneration,
      ownerId: ack.ownerId,
      requestId: ack.requestId,
    })}\n`, 'utf8'), () => {
      writeAckMarker(completionDroppedPath, 'owner_written_synthesized', ack);
    });
    return;
  }
  if (!writerClosed && !broker.stdin.destroyed) broker.stdin.write(lineWithNewline);
}

function observeBrokerLine(lineWithNewline) {
  const frame = parseJsonLine(lineWithNewline.subarray(0, lineWithNewline.length - 1));
  if (frame !== null && typeof frame === 'object' && !Array.isArray(frame)) {
    if (frame.type === 'broker.hello') {
      const generation = Number(frame.generation ?? 0);
      const pid = Number(frame.pid ?? 0);
      if (
        !Number.isSafeInteger(generation) ||
        generation <= 0 ||
        (dropMode && generation !== expectedGeneration) ||
        !Number.isSafeInteger(pid) ||
        pid <= 0 ||
        pid !== (broker.pid ?? 0)
      ) {
        invalidContract();
      }
      brokerGeneration = generation;
      brokerHelloPid = pid;
      publishReady();
    } else if (frame.type === 'owner.started') {
      const pid = Number(frame.pid ?? 0);
      if (typeof frame.ownerId === 'string' && frame.ownerId.length > 0 && Number.isSafeInteger(pid) && pid > 0) {
        ownerId = frame.ownerId;
        ownerPid = pid;
        publishReady();
      }
    } else if (
      pendingAdmission !== null &&
      frame.type === 'owner.written' &&
      frame.generation === brokerGeneration &&
      frame.ownerId === pendingAdmission.ownerId &&
      frame.requestId === pendingAdmission.requestId
    ) {
      boundAttemptToken = pendingAdmission.attemptToken;
      boundEventId = pendingAdmission.eventId;
      boundOwnerId = pendingAdmission.ownerId;
      writeAckMarker(admissionSeenPath, 'broker_written', pendingAdmission);
      pendingAdmission = null;
    }
  }
  enqueueOutput(lineWithNewline);
}

function drainLines(pending, consume) {
  let current = pending;
  while (true) {
    const newline = current.indexOf(0x0a);
    if (newline < 0) break;
    const line = current.subarray(0, newline + 1);
    current = current.subarray(newline + 1);
    consume(line);
  }
  return current;
}

broker.stdin.on('error', () => {
  // Closing the proxy writer is the injected failure contract.
});
process.stdout.on('error', () => {
  // The production owner may close its reader while the broker settles.
});

broker.stdout.on('data', (chunk) => {
  brokerOutputPending = Buffer.concat([brokerOutputPending, chunk]);
  brokerOutputPending = drainLines(brokerOutputPending, observeBrokerLine);
});
process.stdin.on('data', (chunk) => {
  inputPending = Buffer.concat([inputPending, chunk]);
  inputPending = drainLines(inputPending, forwardInputLine);
});
process.stdin.on('end', () => {
  if (inputPending.length > 0 && !writerClosed && !broker.stdin.destroyed) broker.stdin.write(inputPending);
  inputPending = Buffer.alloc(0);
  if (!broker.stdin.destroyed) broker.stdin.end();
});

publishReady();

const watcher = setInterval(() => {
  if (writerMode && !writerClosed && existsSync(failPath)) {
    writerClosed = true;
    process.stdin.destroy();
    broker.stdin.destroy();
    writeAtomic(closedPath, 'writer_closed\n');
  }
  if (writerMode && existsSync(cleanupPath) && broker.exitCode === null && broker.signalCode === null) {
    broker.kill('SIGKILL');
  }
}, 5);

broker.on('exit', (code, signal) => {
  if (settled) return;
  settled = true;
  clearInterval(watcher);
  if (brokerOutputPending.length > 0) enqueueOutput(brokerOutputPending);
  brokerOutputPending = Buffer.alloc(0);
  outputEndRequested = true;
  finishOutputIfReady();
  process.exitCode = Number.isInteger(code) ? code : signal ? 1 : 0;
});

process.on('SIGTERM', () => {
  if (broker.exitCode === null && broker.signalCode === null) broker.kill('SIGTERM');
});
