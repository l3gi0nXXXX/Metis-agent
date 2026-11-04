import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PassThrough, Writable } from 'node:stream';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  BrokerWriter,
  OWNER_HARD_LIMIT,
  StdioBroker,
  StrictStreamFramer,
  terminationCommandsForPlatform,
  truncateRunes,
  validateStartFrame,
} from './metis-stdio-broker.mjs';

const brokerPath = fileURLToPath(new URL('./metis-stdio-broker.mjs', import.meta.url));
const s5ProxyPath = fileURLToPath(new URL('./metis-s5-broker-writer-failure-proxy.mjs', import.meta.url));

function validStart(ownerId = 'owner-1', extra = {}) {
  return {
    type: 'owner.start',
    ownerId,
    command: process.execPath,
    args: ['-e', 'process.stdout.write("ok\\n")'],
    stdinMode: 'closed',
    outputMode: 'line',
    deadlineMs: 2_000,
    maxLineBytes: 65_536,
    maxBufferedBytes: 131_072,
    maxTotalOutputBytes: 262_144,
    ...extra,
  };
}

function fakeChild(pid) {
  const child = new EventEmitter();
  child.pid = pid;
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.stdin = new PassThrough();
  child.kill = () => true;
  queueMicrotask(() => child.emit('spawn'));
  return child;
}

function fakeTreeRunner() {
  return { terminate: () => {}, alive: () => false };
}

class CollectingWritable extends Writable {
  constructor() {
    super();
    this.text = '';
  }
  _write(chunk, _encoding, callback) {
    this.text += chunk.toString();
    callback();
  }
  frames() {
    return this.text.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  }
}

function startBrokerProcess({ diagnosticDirectory = '' } = {}) {
  return spawn(process.execPath, [brokerPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      METIS_STDIO_BROKER_GENERATION: '17',
      METIS_STDIO_BROKER_TEST_MODE: '1',
      ...(diagnosticDirectory ? { METIS_STDIO_BROKER_DIAGNOSTIC_MARKER: diagnosticDirectory } : {}),
    },
  });
}

function frameCollector(child) {
  const frames = [];
  let pending = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    pending += chunk;
    for (;;) {
      const newline = pending.indexOf('\n');
      if (newline < 0) break;
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (line) frames.push(JSON.parse(line));
    }
  });
  return frames;
}

async function waitFor(predicate, timeoutMs = 4_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error('test timeout');
}

async function waitForChildExit(child, timeoutMs = 4_000) {
  if (child.exitCode !== null || child.signalCode !== null) return [child.exitCode, child.signalCode];
  let timer;
  try {
    return await Promise.race([
      once(child, 'exit'),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('child exit timeout')), timeoutMs); }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function reapTestChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGKILL');
  try { await waitForChildExit(child, 2_000); } catch { /* assertion reports the original failure */ }
}

async function expectInvalidProxyContract(child, label) {
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const stdoutEnded = once(child.stdout, 'end');
  const childClosed = once(child, 'close');
  assert.deepEqual(await waitForChildExit(child), [64, null], label);
  let closeTimer;
  try {
    await Promise.race([
      Promise.all([stdoutEnded, childClosed]),
      new Promise((_, reject) => {
        closeTimer = setTimeout(() => reject(new Error('invalid proxy output drain timeout')), 4_000);
      }),
    ]);
  } finally {
    if (closeTimer) clearTimeout(closeTimer);
  }
  assert.equal(stdout, '', label);
  assert.equal(stderr, 'broker_proxy_invalid_contract\n', label);
}

test('HB-BR-P3 proxy forwards broker.closed and exits after serialized stdout drain', async () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-s5-proxy-close-'));
  const ready = join(root, 'ready.json');
  const fail = join(root, 'fail');
  const closed = join(root, 'closed');
  const cleanup = join(root, 'cleanup');
  const child = spawn(process.execPath, [s5ProxyPath, brokerPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      METIS_STDIO_BROKER_GENERATION: '23',
      METIS_S5_BROKER_PROXY_READY: ready,
      METIS_S5_BROKER_PROXY_FAIL: fail,
      METIS_S5_BROKER_PROXY_WRITER_CLOSED: closed,
      METIS_S5_BROKER_PROXY_CLEANUP: cleanup,
    },
  });
  const frames = frameCollector(child);
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  try {
    await waitFor(() => frames.some((frame) => frame.type === 'broker.hello'));
    const stdoutEnded = once(child.stdout, 'end');
    const childClosed = once(child, 'close');
    child.stdin.write(`${JSON.stringify({ type: 'broker.close' })}\n`);
    const exit = await waitForChildExit(child, 4_000);
    let closeTimer;
    try {
      await Promise.race([
        Promise.all([stdoutEnded, childClosed]),
        new Promise((_, reject) => {
          closeTimer = setTimeout(() => reject(new Error('proxy output drain timeout')), 4_000);
        }),
      ]);
    } finally {
      if (closeTimer) clearTimeout(closeTimer);
    }
    assert.deepEqual(exit, [0, null]);
    assert.equal(frames.filter((frame) => frame.type === 'broker.closed').length, 1);
    assert.equal(stderr, '');
  } finally {
    await reapTestChild(child);
    rmSync(root, { recursive: true, force: true });
  }
});

test('H-HB-FIXTURE-01 proxy hold is opt-in, complete, and releases exactly once', async () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-s5-proxy-hold-'));
  const innerBroker = join(root, 'inner-broker.mjs');
  writeFileSync(innerBroker, `
process.stdout.write(JSON.stringify({type:'broker.hello',generation:29,pid:process.pid})+'\\n');
process.stdin.resume();
process.stdin.on('close',()=>{process.stdout.write(JSON.stringify({type:'broker.closed',generation:29})+'\\n',()=>process.exit(1));});
`);
  const writerEnvironment = (prefix) => ({
    METIS_STDIO_BROKER_GENERATION: '29',
    METIS_S5_BROKER_PROXY_READY: join(root, `${prefix}.ready.json`),
    METIS_S5_BROKER_PROXY_FAIL: join(root, `${prefix}.fail`),
    METIS_S5_BROKER_PROXY_WRITER_CLOSED: join(root, `${prefix}.closed`),
    METIS_S5_BROKER_PROXY_CLEANUP: join(root, `${prefix}.cleanup`),
  });
  const children = [];
  try {
    const defaultChild = spawn(process.execPath, [s5ProxyPath, innerBroker], {
      stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, ...writerEnvironment('default') },
    });
    children.push(defaultChild);
    const defaultFrames = frameCollector(defaultChild);
    await waitFor(() => defaultFrames.some((frame) => frame.type === 'broker.hello'));
    writeFileSync(join(root, 'default.fail'), 'fail\n');
    await waitFor(() => existsSync(join(root, 'default.closed')));
    assert.deepEqual(await waitForChildExit(defaultChild), [1, null]);
    assert.equal(defaultFrames.filter((frame) => frame.type === 'broker.closed').length, 1);

    const invalidChild = spawn(process.execPath, [s5ProxyPath, innerBroker], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env, ...writerEnvironment('invalid'),
        METIS_S5_BROKER_PROXY_HOLD_ENTERED: join(root, 'invalid.entered'),
      },
    });
    children.push(invalidChild);
    await expectInvalidProxyContract(invalidChild, 'partial-hold');

    for (const [name, extra] of [
      ['hold-only', {
        METIS_S5_BROKER_PROXY_READY: join(root, 'hold-only.ready'),
        METIS_S5_BROKER_PROXY_HOLD_ENTERED: join(root, 'hold-only.entered'),
        METIS_S5_BROKER_PROXY_HOLD_RELEASE: join(root, 'hold-only.release'),
        METIS_S5_BROKER_PROXY_HOLD_RELEASED: join(root, 'hold-only.released'),
      }],
      ['hold-drop', {
        ...writerEnvironment('hold-drop'),
        METIS_S5_BROKER_PROXY_HOLD_ENTERED: join(root, 'hold-drop.entered'),
        METIS_S5_BROKER_PROXY_HOLD_RELEASE: join(root, 'hold-drop.release'),
        METIS_S5_BROKER_PROXY_HOLD_RELEASED: join(root, 'hold-drop.released'),
        METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID: 'delivery',
        METIS_S5_BROKER_PROXY_ADMISSION_SEEN: join(root, 'hold-drop.admission'),
        METIS_S5_BROKER_PROXY_COMPLETION_DROPPED: join(root, 'hold-drop.completion'),
      }],
      ['writer-drop', {
        ...writerEnvironment('writer-drop'),
        METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID: 'delivery',
        METIS_S5_BROKER_PROXY_ADMISSION_SEEN: join(root, 'writer-drop.admission'),
        METIS_S5_BROKER_PROXY_COMPLETION_DROPPED: join(root, 'writer-drop.completion'),
      }],
    ]) {
      const child = spawn(process.execPath, [s5ProxyPath, innerBroker], {
        stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, ...extra },
      });
      children.push(child);
      await expectInvalidProxyContract(child, name);
      assert.equal(existsSync(extra.METIS_S5_BROKER_PROXY_READY), false, name);
      if (name === 'writer-drop') {
        assert.equal(existsSync(extra.METIS_S5_BROKER_PROXY_ADMISSION_SEEN), false);
        assert.equal(existsSync(extra.METIS_S5_BROKER_PROXY_COMPLETION_DROPPED), false);
      }
    }

    const holdEntered = join(root, 'hold.entered');
    const holdRelease = join(root, 'hold.release');
    const holdReleased = join(root, 'hold.released');
    const heldChild = spawn(process.execPath, [s5ProxyPath, innerBroker], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env, ...writerEnvironment('held'),
        METIS_S5_BROKER_PROXY_HOLD_ENTERED: holdEntered,
        METIS_S5_BROKER_PROXY_HOLD_RELEASE: holdRelease,
        METIS_S5_BROKER_PROXY_HOLD_RELEASED: holdReleased,
      },
    });
    children.push(heldChild);
    const heldFrames = frameCollector(heldChild);
    await waitFor(() => heldFrames.some((frame) => frame.type === 'broker.hello'));
    writeFileSync(join(root, 'held.fail'), 'fail\n');
    await waitFor(() => existsSync(join(root, 'held.closed')));
    await waitFor(() => existsSync(holdEntered));
    assert.equal(heldChild.exitCode, null);
    writeFileSync(holdRelease, 'release\n');
    await waitFor(() => existsSync(holdReleased));
    assert.deepEqual(await waitForChildExit(heldChild), [1, null]);
    assert.equal(readFileSync(holdEntered, 'utf8'), 'hold_entered\n');
    assert.equal(readFileSync(holdReleased, 'utf8'), 'hold_released\n');
    assert.equal(heldFrames.filter((frame) => frame.type === 'broker.closed').length, 1);
  } finally {
    for (const child of children) await reapTestChild(child);
    rmSync(root, { recursive: true, force: true });
  }
});

test('P1-U1 routes interleaved owner streams and settles once', async () => {
  const output = new CollectingWritable();
  let nextPid = 20_000;
  const children = [];
  const broker = new StdioBroker({ output, treeRunner: fakeTreeRunner(), spawnFn: () => {
    const child = fakeChild(nextPid++);
    children.push(child);
    return child;
  }});
  broker.handle(validStart('a', { stdinMode: 'line', deadlineMs: 0 }));
  broker.handle(validStart('b', { stdinMode: 'line', deadlineMs: 0 }));
  await new Promise((resolve) => setImmediate(resolve));
  children[0].stdout.write('a1\n');
  children[1].stderr.write('b1\n');
  children[0].stdout.write('a2\n');
  children[0].emit('close', 0, null);
  children[0].emit('close', 7, null);
  const frames = output.frames();
  assert.deepEqual(frames.filter((f) => f.type === 'owner.stdout').map((f) => [f.ownerId, f.text]), [['a', 'a1'], ['a', 'a2']]);
  assert.deepEqual(frames.filter((f) => f.type === 'owner.stderr').map((f) => [f.ownerId, f.text]), [['b', 'b1']]);
  assert.equal(frames.filter((f) => f.type === 'owner.exit' && f.ownerId === 'a').length, 1);
  assert.equal(broker.owners.size, 1);
  assert.equal(truncateRunes('中文🙂abc', 3), '中文🙂');
});

test('P1-B1 preserves UTF-8 across chunks, empty lines, trailing text, and rejects invalid bytes', () => {
  const events = [];
  const framer = new StrictStreamFramer({
    mode: 'line', maxLineBytes: 128, maxBufferedBytes: 256, maxTotalOutputBytes: 512,
    emit: (event) => events.push(event),
  });
  const bytes = Buffer.from('中文🙂\n\n尾巴🚀');
  const emoji = bytes.indexOf(Buffer.from('🙂'));
  framer.push(bytes.subarray(0, emoji + 1));
  framer.push(bytes.subarray(emoji + 1));
  framer.finish();
  assert.deepEqual(events.map((event) => event.text), ['中文🙂', '', '尾巴🚀']);
  assert.equal(events.at(-1).final, true);

  const invalid = new StrictStreamFramer({ mode: 'line', maxLineBytes: 32, maxBufferedBytes: 32, maxTotalOutputBytes: 32, emit: () => {} });
  assert.throws(() => invalid.push(Buffer.from([0xc3, 0x28, 0x0a])), /invalid_response_encoding/);
  const tooLong = new StrictStreamFramer({ mode: 'line', maxLineBytes: 3, maxBufferedBytes: 32, maxTotalOutputBytes: 32, emit: () => {} });
  assert.throws(() => tooLong.push(Buffer.from('four')), /line_too_large/);

  const exact = new StrictStreamFramer({ mode: 'line', maxLineBytes: 4, maxBufferedBytes: 4, maxTotalOutputBytes: 4, emit: () => {} });
  exact.push(Buffer.from('1234'));
  assert.throws(() => exact.push(Buffer.from('5')), /output_too_large/);

  const streamEvents = [];
  const stream = new StrictStreamFramer({
    mode: 'stream', maxLineBytes: 128, maxBufferedBytes: 64, maxTotalOutputBytes: 64,
    emit: (event) => streamEvents.push(event),
  });
  const streamBytes = Buffer.from('中🙂\n\n尾');
  for (const byte of streamBytes) stream.push(Buffer.from([byte]));
  stream.finish();
  assert.equal(streamEvents.map((event) => event.text).join(''), '中🙂\n\n尾');
  assert.equal(streamEvents.at(-1).final, true);

  const streamOverflow = new StrictStreamFramer({
    mode: 'stream', maxLineBytes: 128, maxBufferedBytes: 5, maxTotalOutputBytes: 64, emit: () => {},
  });
  streamOverflow.push(Buffer.from('12345'));
  assert.throws(() => streamOverflow.push(Buffer.from('6')), /buffer_capacity_exceeded/);
});

test('HB-BR-U1 broker close waits for the final stdout callback and drain exactly once', async () => {
  const output = new EventEmitter();
  const writes = [];
  output.write = (chunk, callback) => {
    writes.push({ chunk: chunk.toString(), callback });
    return false;
  };
  const exits = [];
  const broker = new StdioBroker({ output, generation: 31, exit: (code) => exits.push(code) });

  broker.closeBroker();
  broker.closeBroker();
  assert.equal(writes.length, 1);
  assert.equal(JSON.parse(writes[0].chunk).type, 'broker.closed');
  assert.deepEqual(exits, []);

  writes[0].callback(null);
  assert.deepEqual(exits, []);
  output.emit('drain');
  assert.deepEqual(exits, []);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(exits, [0]);
  broker.closeBroker();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(exits, [0]);
  assert.equal(writes.filter((item) => JSON.parse(item.chunk).type === 'broker.closed').length, 1);
});

test('HB-BR-N1 final stdout failure is fatal exactly once and never exits zero', async () => {
  const output = new EventEmitter();
  const writes = [];
  output.write = (chunk, callback) => {
    writes.push({ chunk: chunk.toString(), callback });
    return true;
  };
  const exits = [];
  const diagnostics = [];
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk, ..._args) => {
    diagnostics.push(String(chunk));
    return true;
  };
  try {
    const broker = new StdioBroker({ output, generation: 32, exit: (code) => exits.push(code) });
    broker.closeBroker();
    assert.equal(writes.length, 1);
    writes[0].callback(new Error('synthetic output failure'));
    output.emit('error', new Error('duplicate synthetic output failure'));
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(exits, [70]);
    assert.equal(diagnostics.filter((line) => line === 'metis stdio broker protocol writer failed\n').length, 1);
    assert.equal(writes.filter((item) => JSON.parse(item.chunk).type === 'broker.closed').length, 1);
  } finally {
    process.stderr.write = originalWrite;
  }
});

test('HB-BR-N2 classifies bounded writer failures and the post-close callback race', async () => {
  const observed = [];
  const outputError = new EventEmitter();
  outputError.write = () => true;
  new BrokerWriter(outputError, { onFailure: (kind) => observed.push(kind) });
  outputError.emit('error', new Error('synthetic'));

  const callbackError = new EventEmitter();
  let callback;
  callbackError.write = (_chunk, value) => { callback = value; return true; };
  const callbackWriter = new BrokerWriter(callbackError, { onFailure: (kind) => observed.push(kind) });
  callbackWriter.write({ type: 'callback' });
  callback(new Error('synthetic'));

  const blocked = new EventEmitter();
  blocked.write = () => false;
  const bounded = new BrokerWriter(blocked, { maxQueuedBytes: 64, onFailure: (kind) => observed.push(kind) });
  bounded.write({ type: 'one' });
  bounded.write({ type: 'two', text: 'x'.repeat(128) });

  const throwing = new EventEmitter();
  throwing.write = () => { throw new Error('synthetic'); };
  const throwingWriter = new BrokerWriter(throwing, { onFailure: (kind) => observed.push(kind) });
  throwingWriter.write({ type: 'throw' });
  assert.deepEqual(observed, ['output_error', 'callback_error', 'queue_capacity', 'write_exception']);

  const root = mkdtempSync(join(tmpdir(), 'metis-hb-br-n2-'));
  try {
    const raceOutput = new EventEmitter();
    const writes = [];
    raceOutput.write = (chunk, written) => { writes.push({ chunk: String(chunk), written }); return true; };
    const exits = [];
    const broker = new StdioBroker({
      output: raceOutput, generation: 41, testMode: true, diagnosticMarkerDirectory: root,
      exit: (code) => exits.push(code),
    });
    broker.closeBroker();
    writes[0].written(null);
    raceOutput.emit('error', new Error('synthetic post-callback failure'));
    await new Promise((resolve) => setImmediate(resolve));
    const markerPath = join(root, `broker-g41-p${process.pid}.json`);
    const marker = JSON.parse(readFileSync(markerPath, 'utf8'));
    assert.deepEqual(exits, [70]);
    assert.equal(marker.writerFailureKind, 'output_error');
    assert.equal(marker.writerFailurePhase, 'other');
    assert.equal(marker.closeAckCallbackSeen, true);
    assert.equal(marker.closeEntryOwnerCount, 0);
    assert.equal(marker.ownerCount, 0);
    assert.equal(marker.exitScheduledCount, 1);
    assert.equal(marker.lastExitScheduledCode, 70);
    assert.equal(marker.events.filter((event) => event.event === 'exit_scheduled').length, 1);
    assert.equal(statSync(markerPath).mode & 0o777, 0o600);

    const failureBeforeLateSuccess = [];
    const firstFailure = new StdioBroker({
      output: new EventEmitter(), exit: (code) => failureBeforeLateSuccess.push(code),
    });
    firstFailure.scheduleExit(70);
    firstFailure.scheduleExit(0);
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(failureBeforeLateSuccess, [70]);
    assert.equal(firstFailure.exitScheduledCount, 1);
    assert.equal(firstFailure.lastExitScheduledCode, 70);

    const forcedBeforeLateSuccess = [];
    const forced = new StdioBroker({
      output: new EventEmitter(), exit: (code) => forcedBeforeLateSuccess.push(code),
    });
    forced.scheduleExit(71);
    forced.scheduleExit(0);
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(forcedBeforeLateSuccess, [71]);
    assert.equal(forced.exitScheduledCount, 1);
    assert.equal(forced.lastExitScheduledCode, 71);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('HB-BR-D1 retains two broker generations as private bounded UTF-8-safe evidence', () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-hb-br-d1-'));
  try {
    const output = new CollectingWritable();
    let diagnosticPid = 41_000;
    const first = new StdioBroker({
      output, generation: 51, testMode: true, diagnosticMarkerDirectory: root, exit: () => {},
      spawnFn: () => fakeChild(diagnosticPid++), treeRunner: fakeTreeRunner(),
    });
    const second = new StdioBroker({
      output: new CollectingWritable(), generation: 52, testMode: true,
      diagnosticMarkerDirectory: root, exit: () => {},
    });
    first.handle({ type: 'unsupported', text: '中文🙂', authorization: 'private-secret' });
    first.handle(validStart('service-plugin:test:instance:1', { command: '/bin/true', args: [], deadlineMs: 0 }));
    first.handle(validStart('pid-probe', { command: '/bin/sh', args: ['-c', 'kill -0 24626'], deadlineMs: 0 }));
    first.handle(validStart('lsof-probe', {
      command: '/bin/sh', args: ['-c', 'lsof -nP -iTCP:24626 -sTCP:LISTEN -Fp'], deadlineMs: 0,
    }));
    first.handle(validStart('other-probe', { deadlineMs: 0 }));
    second.closeBroker();
    const files = readdirSync(root).filter((name) => name.startsWith('broker-g')).sort();
    assert.deepEqual(files, [`broker-g51-p${process.pid}.json`, `broker-g52-p${process.pid}.json`]);
    const markers = files.map((name) => {
      const path = join(root, name);
      assert.equal(statSync(path).mode & 0o777, 0o600);
      const raw = readFileSync(path, 'utf8');
      assert.equal(raw.includes('中文'), false);
      assert.equal(raw.includes('🙂'), false);
      assert.equal(raw.includes('private-secret'), false);
      return JSON.parse(raw);
    });
    assert.deepEqual(markers.map((marker) => marker.generation), [51, 52]);
    assert.equal(markers.every((marker) => marker.events[0].event === 'broker_started'), true);
    assert.equal(markers.every((marker) => marker.startParentPid === process.ppid), true);
    assert.equal(markers.every((marker) => marker.observedParentPid === process.ppid), true);
    assert.deepEqual(markers[0].ownerStartCounts, {
      service_plugin: 1, pid_probe: 1, lsof_probe: 1, other: 1,
    });
    for (let generation = 53; generation <= 67; generation += 1) {
      new StdioBroker({
        output: new CollectingWritable(), generation, testMode: true,
        diagnosticMarkerDirectory: root, exit: () => {},
      });
    }
    assert.equal(readdirSync(root).filter((name) => name.startsWith('broker-g')).length, 16);
    const overflowPath = join(root, 'overflow.json');
    const overflow = JSON.parse(readFileSync(overflowPath, 'utf8'));
    assert.deepEqual({ overflow: overflow.overflow, capacity: overflow.capacity }, { overflow: true, capacity: 16 });
    assert.equal(statSync(overflowPath).mode & 0o777, 0o600);

    for (const [label, prepare] of [
      ['non-json', (path) => writeFileSync(join(path, 'unexpected.txt'), 'x')],
      ['invalid-utf8', (path) => writeFileSync(join(path, 'broker-g1-p2.json'), Buffer.from([0xff]))],
      ['symlink', (path) => symlinkSync(root, join(path, 'unexpected-link'))],
      ['orphan-slot', (path) => mkdirSync(join(path, '.identity-slot-0'))],
      ['corrupt-overflow', (path) => writeFileSync(join(path, 'overflow.json'), '{')],
      ['invalid-overflow-utf8', (path) => writeFileSync(join(path, 'overflow.json'), Buffer.from([0xff]))],
    ]) {
      const unsafe = join(root, label);
      mkdirSync(unsafe);
      prepare(unsafe);
      new StdioBroker({
        output: new CollectingWritable(), generation: 70, testMode: true,
        diagnosticMarkerDirectory: unsafe, exit: () => {},
      });
      assert.equal(JSON.parse(readFileSync(join(unsafe, 'overflow.json'), 'utf8')).overflow, true);
      assert.equal(readdirSync(unsafe).some((name) => name.startsWith('broker-g70-')), false);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('HB-BR-D2 reparented broker evidence remains schema-valid and preserves its start parent', () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-hb-br-d2-'));
  try {
    let parentPid = 24626;
    const broker = new StdioBroker({
      output: new CollectingWritable(), generation: 61, testMode: true,
      diagnosticMarkerDirectory: root, parentPidProvider: () => parentPid, exit: () => {},
    });
    parentPid = 1;
    broker.closeBroker();
    const marker = JSON.parse(readFileSync(join(root, `broker-g61-p${process.pid}.json`), 'utf8'));
    assert.equal(marker.startParentPid, 24626);
    assert.equal(marker.observedParentPid, 1);
    assert.equal(marker.events[0].event, 'broker_started');
    assert.equal(marker.protocolVersion, '1.0');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('HB-BR-N3 classifies the direct shutdown lsof owner without hiding it as other', () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-hb-br-n3-'));
  try {
    const broker = new StdioBroker({
      output: new CollectingWritable(), generation: 62, testMode: true,
      diagnosticMarkerDirectory: root, exit: () => {},
      spawnFn: () => fakeChild(41_100), treeRunner: fakeTreeRunner(),
    });
    broker.handle(validStart('shell-command-1', {
      command: 'lsof', args: ['-nP', '-iTCP:24626', '-sTCP:LISTEN', '-t'], deadlineMs: 0,
    }));
    const marker = JSON.parse(readFileSync(join(root, `broker-g62-p${process.pid}.json`), 'utf8'));
    assert.deepEqual(marker.ownerStartCounts, {
      service_plugin: 0, pid_probe: 0, lsof_probe: 1, other: 0,
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('HB-BR-B2 broker close settles an ignore-term owner before its acknowledgement', async () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-hb-br-b2-'));
  const child = startBrokerProcess({ diagnosticDirectory: root });
  try {
    const frames = frameCollector(child);
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    await waitFor(() => frames.find((frame) => frame.type === 'broker.hello'));
    child.stdin.write(`${JSON.stringify(validStart('hb-br-b2', {
      args: ['-e', "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], deadlineMs: 0,
    }))}\n`);
    await waitFor(() => frames.find((frame) => frame.type === 'owner.started' && frame.ownerId === 'hb-br-b2'));
    child.stdin.write(`${JSON.stringify({ type: 'broker.close' })}\n`);
    const terminal = await waitFor(() => frames.find((frame) =>
      ['owner.exit', 'owner.error', 'owner.timeout'].includes(frame.type) && frame.ownerId === 'hb-br-b2'));
    const closed = await waitFor(() => frames.find((frame) => frame.type === 'broker.closed'));
    const [code] = await waitForChildExit(child);
    assert.equal(terminal.type, 'owner.exit');
    assert.equal(closed.ownerCount, 0);
    assert.equal(code, 0);
    assert.equal(stderr, '');
    const marker = JSON.parse(readFileSync(join(root, `broker-g17-p${child.pid}.json`), 'utf8'));
    assert.equal(marker.ownerStartCounts.other, 1);
    assert.equal(marker.ownerTerminalCounts.other, 1);
    assert.equal(marker.closeEntryOwnerCount, 1);
    assert.equal(marker.brokerClosedEnqueuedCount, 1);
    assert.equal(marker.brokerClosedCallbackCount, 1);
    assert.equal(marker.lastExitScheduledCode, 0);
  } finally {
    await reapTestChild(child);
    rmSync(root, { recursive: true, force: true });
  }
});

test('HB-BR-P2 terminal owner is removed before acknowledged two-second broker close', async () => {
  const root = mkdtempSync(join(tmpdir(), 'metis-hb-br-p2-'));
  const child = startBrokerProcess({ diagnosticDirectory: root });
  try {
    const frames = frameCollector(child);
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    await waitFor(() => frames.find((frame) => frame.type === 'broker.hello'));
    child.stdin.write(`${JSON.stringify(validStart('hb-br-p2'))}\n`);
    await waitFor(() => frames.find((frame) => frame.type === 'owner.exit' && frame.ownerId === 'hb-br-p2'));
    child.stdin.write(`${JSON.stringify({ type: 'broker.close' })}\n`);
    const closed = await waitFor(() => frames.find((frame) => frame.type === 'broker.closed'), 2_000);
    const [code] = await waitForChildExit(child);
    assert.equal(closed.ownerCount, 0);
    assert.equal(code, 0);
    assert.equal(stderr, '');
    const marker = JSON.parse(readFileSync(join(root, `broker-g17-p${child.pid}.json`), 'utf8'));
    assert.equal(marker.ownerStartCounts.other, 1);
    assert.equal(marker.ownerTerminalCounts.other, 1);
    assert.equal(marker.closeEntryOwnerCount, 0);
    assert.equal(marker.brokerClosedEnqueuedCount, 1);
    assert.equal(marker.brokerClosedCallbackCount, 1);
    assert.equal(marker.lastExitScheduledCode, 0);
  } finally {
    await reapTestChild(child);
    rmSync(root, { recursive: true, force: true });
  }
});

test('P1-B1 validates owner specs, hard limit 255/256/257, and writer drain backpressure', () => {
  assert.equal(validateStartFrame(validStart()), true);
  assert.equal(validateStartFrame(validStart('env-values', {
    env: { ['k'.repeat(256)]: '', '中文😀': '合成值\nquoted' },
  })), true);
  for (const patch of [{ command: '' }, { command: 'x\0y' }, { args: ['x\0y'] }, { requestId: 'bad\nrequest' },
    { env: { 'bad\nkey': 'value' } }, { env: { '': 'value' } }, { env: { 'bad\0key': 'value' } },
    { env: { 'bad=key': 'value' } }, { env: { 'bad\u0001key': 'value' } }, { env: { 'bad\u007fkey': 'value' } },
    { env: { ['k'.repeat(257)]: 'value' } }, { maxLineBytes: -1 }, { stdinMode: 'bad' }]) {
    assert.throws(() => validateStartFrame(validStart('bad', patch)), /invalid_owner_spec/);
  }
  const output = new CollectingWritable();
  let pid = 30_000;
  const broker = new StdioBroker({ output, treeRunner: fakeTreeRunner(), spawnFn: () => fakeChild(pid++), hardLimit: OWNER_HARD_LIMIT });
  for (let i = 0; i < OWNER_HARD_LIMIT; i += 1) broker.handle(validStart(`o-${i}`, { deadlineMs: 0 }));
  assert.equal(broker.owners.size, 256);
  broker.handle(validStart('o-0', { deadlineMs: 0, requestId: 'duplicate' }));
  assert.equal(output.frames().at(-1).status, 'duplicate_owner');
  assert.equal(output.frames().at(-1).requestId, 'duplicate');
  broker.handle(validStart('o-256', { deadlineMs: 0 }));
  assert.equal(broker.owners.size, 256);
  assert.equal(output.frames().at(-1).status, 'broker_capacity_exceeded');

  const fake = new EventEmitter();
  fake.calls = [];
  fake.write = (chunk) => { fake.calls.push(chunk); return fake.calls.length !== 1; };
  const writer = new BrokerWriter(fake);
  writer.write({ type: 'one' });
  writer.write({ type: 'two' });
  assert.equal(fake.calls.length, 1);
  fake.emit('drain');
  assert.equal(fake.calls.length, 2);

  let overflowed = 0;
  const blocked = new EventEmitter();
  blocked.write = () => false;
  const bounded = new BrokerWriter(blocked, { maxQueuedBytes: 20, onFailure: () => { overflowed += 1; } });
  assert.equal(bounded.write({ x: '1234' }), true);
  assert.equal(bounded.write({ x: '5678' }), true);
  assert.equal(bounded.write({ x: 'overflow' }), false);
  assert.equal(overflowed, 1);
});

test('P1-N3 platform runner produces exact POSIX and Windows escalation argv', () => {
  assert.deepEqual(terminationCommandsForPlatform('darwin', 123, false), [['signal-group', ['SIGTERM', '123']]]);
  assert.deepEqual(terminationCommandsForPlatform('darwin', 123, true), [['signal-group', ['SIGKILL', '123']]]);
  assert.deepEqual(terminationCommandsForPlatform('win32', 456, false), [['taskkill', ['/PID', '456', '/T']]]);
  assert.deepEqual(terminationCommandsForPlatform('win32', 456, true), [['taskkill', ['/PID', '456', '/T', '/F']]]);
});

test('P1-P1 real broker handles ping and 32 concurrent owners without loss', async (t) => {
  const child = startBrokerProcess();
  t.after(() => { try { child.kill('SIGKILL'); } catch {} });
  const frames = frameCollector(child);
  await waitFor(() => frames.find((frame) => frame.type === 'broker.hello'));
  child.stdin.write(`${JSON.stringify({ type: 'broker.ping', requestId: 'health-1' })}\n`);
  for (let index = 0; index < 2; index += 1) {
    child.stdin.write(`${JSON.stringify(validStart(`long-${index}`, {
      args: ['-e', 'process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'], deadlineMs: 0,
    }))}\n`);
  }
  await waitFor(() => frames.filter((frame) => frame.type === 'owner.started' && frame.ownerId.startsWith('long-')).length === 2);
  for (let index = 0; index < 32; index += 1) {
    child.stdin.write(`${JSON.stringify(validStart(`cron-${index}`, {
      args: ['-e', 'for(let i=0;i<100;i++)console.log(i)'],
    }))}\n`);
  }
  await waitFor(() => frames.filter((frame) => frame.type === 'owner.exit').length === 32, 12_000);
  assert.equal(frames.filter((frame) => frame.type === 'owner.stdout').length, 3_200);
  assert.equal(frames.filter((frame) => frame.type === 'owner.started').length, 34);
  assert.ok(frames.find((frame) => frame.type === 'broker.pong' && frame.requestId === 'health-1'));
  child.stdin.write(`${JSON.stringify({ type: 'broker.snapshot', requestId: 'baseline' })}\n`);
  assert.equal((await waitFor(() => frames.find((frame) => frame.type === 'broker.snapshot' && frame.requestId === 'baseline'))).ownerCount, 2);
  for (let index = 0; index < 2; index += 1) {
    child.stdin.write(`${JSON.stringify({ type: 'owner.stop', ownerId: `long-${index}`, requestId: `stop-long-${index}`, reason: 'stopped' })}\n`);
  }
  await waitFor(() => frames.filter((frame) => frame.type === 'owner.exit' && frame.ownerId.startsWith('long-')).length === 2);
  child.stdin.write(`${JSON.stringify({ type: 'broker.snapshot', requestId: 'final' })}\n`);
  assert.equal((await waitFor(() => frames.find((frame) => frame.type === 'broker.snapshot' && frame.requestId === 'final'))).ownerCount, 0);
  child.stdin.end();
  await once(child, 'exit');
  assert.equal(child.exitCode, 0);
  assert.equal(frames.every((frame) => frame.generation === 17), true);
});

test('P1-N1 deadline escalates an ignore-TERM process group and leaves no child', async (t) => {
  if (process.platform === 'win32') return t.skip('POSIX process-group assertion');
  const child = startBrokerProcess();
  t.after(() => { try { child.kill('SIGKILL'); } catch {} });
  const frames = frameCollector(child);
  await waitFor(() => frames.find((frame) => frame.type === 'broker.hello'));
  child.stdin.write(`${JSON.stringify(validStart('hung', {
    args: ['-e', 'const {spawn}=require("child_process");const c=spawn(process.execPath,["-e","process.on(\\"SIGTERM\\",()=>{});setInterval(()=>{},1000)"],{stdio:"ignore"});console.log(c.pid);process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],
    deadlineMs: 80,
  }))}\n`);
  const started = await waitFor(() => frames.find((frame) => frame.type === 'owner.started' && frame.ownerId === 'hung'));
  const exited = await waitFor(() => frames.find((frame) => frame.type === 'owner.timeout' && frame.ownerId === 'hung'), 3_000);
  const descendantPid = Number(frames.find((frame) => frame.type === 'owner.stdout' && frame.ownerId === 'hung').text);
  assert.equal(exited.status, 'timed_out');
  assert.equal(frames.filter((frame) => ['owner.timeout', 'owner.error', 'owner.exit'].includes(frame.type) && frame.ownerId === 'hung').length, 1);
  assert.throws(() => process.kill(started.pid, 0), { code: 'ESRCH' });
  assert.throws(() => process.kill(-started.pgid, 0), { code: 'ESRCH' });
  assert.throws(() => process.kill(descendantPid, 0), { code: 'ESRCH' });
  child.stdin.end();
  await once(child, 'exit');
});

test('P1-B1 malformed broker input stays structured and stdout remains JSON-only', async (t) => {
  const child = startBrokerProcess();
  t.after(() => { try { child.kill('SIGKILL'); } catch {} });
  const frames = frameCollector(child);
  await waitFor(() => frames.find((frame) => frame.type === 'broker.hello'));
  child.stdin.write('{bad json}\n');
  const diagnostic = await waitFor(() => frames.find((frame) => frame.type === 'broker.diagnostic'));
  assert.equal(diagnostic.status, 'malformed_json');
  child.stdin.write(Buffer.from([0xc3, 0x28, 0x0a]));
  await waitFor(() => frames.find((frame) => frame.type === 'broker.diagnostic' && frame.status === 'invalid_response_encoding'));
  child.stdin.end();
  await once(child, 'exit');
});

test('P1-B1 two streams share the raw total cap and line writes reject CRLF', async () => {
  const output = new CollectingWritable();
  const children = [];
  const broker = new StdioBroker({ output, treeRunner: fakeTreeRunner(), spawnFn: () => {
    const child = fakeChild(40_000 + children.length);
    children.push(child);
    return child;
  }});
  broker.handle(validStart('shared-total', { requestId: 'shared-start', stdinMode: 'line', deadlineMs: 0, maxTotalOutputBytes: 5 }));
  await new Promise((resolve) => setImmediate(resolve));
  children[0].stdout.write('123');
  children[0].stderr.write('456');
  broker.handle({ type: 'owner.write', ownerId: 'shared-total', ownerIncarnation: 'shared-start', requestId: 'bad-line', line: 'x\ny' });
  await new Promise((resolve) => setImmediate(resolve));
  children[0].emit('close', null, 'SIGTERM');
  const frames = output.frames();
  assert.equal(frames.find((frame) => frame.type === 'owner.write-rejected').status, 'owner_not_writable');
  assert.equal(frames.filter((frame) => ['owner.error', 'owner.exit', 'owner.timeout'].includes(frame.type)).length, 1);
  assert.equal(frames.find((frame) => frame.type === 'owner.error').status, 'output_too_large');
});

test('P1-U1 start/write/stop acknowledgements correlate requestId and started waits for spawn', async () => {
  const output = new CollectingWritable();
  const child = fakeChild(45_000);
  const broker = new StdioBroker({ output, treeRunner: fakeTreeRunner(), spawnFn: () => child });
  broker.handle(validStart('acks', { requestId: 'start-1', stdinMode: 'line', deadlineMs: 0 }));
  assert.equal(output.frames().some((frame) => frame.type === 'owner.started'), false);
  await new Promise((resolve) => setImmediate(resolve));
  broker.handle({ type: 'owner.write', ownerId: 'acks', ownerIncarnation: 'start-1', requestId: 'write-1', line: 'hello' });
  await new Promise((resolve) => setImmediate(resolve));
  broker.handle({ type: 'owner.stop', ownerId: 'acks', requestId: 'stop-1', reason: 'secret-path-must-not-echo' });
  assert.equal(output.frames().find((frame) => frame.type === 'owner.started').requestId, 'start-1');
  assert.equal(output.frames().find((frame) => frame.type === 'owner.written').requestId, 'write-1');
  assert.equal(output.frames().find((frame) => frame.type === 'owner.stopping').requestId, 'stop-1');
  assert.equal(output.frames().find((frame) => frame.type === 'owner.stopping').reason, 'stopped');
  assert.equal(output.text.includes('secret-path-must-not-echo'), false);
  child.emit('close', null, 'SIGTERM');
});

test('write incarnation rejects a stopped owner write after same-id replacement', async () => {
  const output = new CollectingWritable();
  const children = [];
  const broker = new StdioBroker({ output, treeRunner: fakeTreeRunner(), spawnFn: () => {
    const child = fakeChild(45_100 + children.length);
    children.push(child);
    return child;
  }});
  broker.handle(validStart('reused', { requestId: 'start-old', stdinMode: 'line', deadlineMs: 0 }));
  await new Promise((resolve) => setImmediate(resolve));
  let finishOldWrite;
  children[0].stdin.write = (_chunk, callback) => {
    finishOldWrite = callback;
    return true;
  };
  broker.handle({
    type: 'owner.write', ownerId: 'reused', ownerIncarnation: 'start-old', requestId: 'write-late', line: 'old-pending',
  });
  broker.handle({ type: 'owner.stop', ownerId: 'reused', requestId: 'stop-old', reason: 'stopped' });
  children[0].emit('close', 0, null);
  await new Promise((resolve) => setImmediate(resolve));

  broker.handle(validStart('reused', { requestId: 'start-new', stdinMode: 'line', deadlineMs: 0 }));
  await new Promise((resolve) => setImmediate(resolve));
  broker.handle({
    type: 'owner.write', ownerId: 'reused', ownerIncarnation: 'start-old', requestId: 'write-old', line: 'must-not-arrive',
  });
  broker.handle({
    type: 'owner.write', ownerId: 'reused', ownerIncarnation: 'start-new', requestId: 'write-new', line: 'new-only',
  });
  finishOldWrite(null);
  await new Promise((resolve) => setImmediate(resolve));

  const frames = output.frames();
  assert.equal(frames.find((frame) => frame.requestId === 'write-old').status, 'stale_owner_incarnation');
  assert.equal(frames.find((frame) => frame.requestId === 'write-old').ownerIncarnation, 'start-old');
  assert.equal(frames.find((frame) => frame.requestId === 'write-new').type, 'owner.written');
  assert.equal(frames.find((frame) => frame.requestId === 'write-late').ownerIncarnation, 'start-old');
  assert.equal(children[0].stdin.readableLength, 0);
  assert.equal(children[1].stdin.read().toString(), 'new-only\n');
  children[1].emit('close', 0, null);
});

test('P1-N3 test hang is gated and broker stdin has an exact raw byte cap', async () => {
  const output = new CollectingWritable();
  const production = new StdioBroker({ output, testMode: false });
  production.handle({ type: 'broker.test-hang', requestId: 'not-allowed' });
  assert.equal(production.hung, undefined);
  assert.equal(output.frames().at(-1).status, 'unsupported_frame');

  const testOutput = new CollectingWritable();
  const hangChild = fakeChild(46_000);
  const testBroker = new StdioBroker({
    generation: 8, output: testOutput, testMode: true, treeRunner: fakeTreeRunner(), spawnFn: () => hangChild,
  });
  testBroker.handle(validStart('hang-owner', { requestId: 'hang-owner-start', deadlineMs: 20 }));
  await new Promise((resolve) => setImmediate(resolve));
  testBroker.handle({ type: 'broker.test-hang', requestId: 'hang-8-1' });
  await new Promise((resolve) => setImmediate(resolve));
  const hangAck = testOutput.frames().find((frame) => frame.type === 'broker.test-hung');
  assert.equal(hangAck.generation, 8);
  assert.equal(hangAck.requestId, 'hang-8-1');
  assert.equal(testBroker.hung, true);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(testOutput.frames().some((frame) => frame.type === 'owner.timeout'), false);
  hangChild.emit('close', 0, null);

  const input = new PassThrough();
  const cappedOutput = new CollectingWritable();
  const { runBroker } = await import('./metis-stdio-broker.mjs');
  const broker = runBroker({ input, output: cappedOutput, generation: 9, maxInputBytes: 4, installSignalHandlers: false, exit: () => {} });
  input.write(Buffer.from('12345'));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(cappedOutput.frames().find((frame) => frame.status === 'broker_input_too_large').generation, 9);
  broker.writer.close();
  input.destroy();

  const privateOutput = new CollectingWritable();
  const privateBroker = new StdioBroker({
    output: privateOutput,
    spawnFn: () => { throw new Error('token=TEST_SECRET /Users/private/work'); },
  });
  privateBroker.handle(validStart('private-failure', { env: { TEST_TOKEN: 'TEST_SECRET' } }));
  assert.equal(privateOutput.frames().at(-1).status, 'spawn_failed');
  assert.equal(privateOutput.text.includes('TEST_SECRET'), false);
  assert.equal(privateOutput.text.includes('/Users/private/work'), false);
});


test('R-S1-N1 unknown tree probes cannot claim terminal and attached diagnostics avoid fd2', () => {
  for (const code of ['ESRCH', 'EPERM', 'EINVAL', undefined]) {
    const output = new CollectingWritable();
    const broker = new StdioBroker({ output, treeRunner: {
      alive: () => { const error = new Error('fixture'); error.code = code; throw error; }, terminate: () => {},
    }, exit: () => {} });
    const owner = { id: 'unknown-probe', child: { pid: 543210 }, spawned: true, closed: true, settled: false };
    assert.equal(broker.treeAlive(owner), code !== 'ESRCH');
    if (code !== 'ESRCH') {
      broker.settleAfterTreeGone(owner, 'owner.exit', { exitCode: 0 });
      assert.equal(owner.settled, false);
      assert.equal(output.frames().some(frame => frame.type === 'owner.exit'), false);
      clearTimeout(owner.reapTimer);
    }
    broker.writer.close();
  }
  const output = new CollectingWritable();
  const broker = new StdioBroker({ output, attachedStdio: true, exit: () => {} });
  const original = process.stderr.write;
  let writes = 0;
  process.stderr.write = () => { writes += 1; return true; };
  try {
    broker.stderrDiagnostic('fixed diagnostic\n', 'recovery_persistence_failed');
    assert.equal(writes, 0);
    assert.equal(output.frames().at(-1).status, 'recovery_persistence_failed');
    broker.attachedStdio = false;
    broker.stderrDiagnostic('fixed diagnostic\n', 'recovery_persistence_failed');
    assert.equal(writes, 1);
  } finally { process.stderr.write = original; broker.writer.close(); }
});
