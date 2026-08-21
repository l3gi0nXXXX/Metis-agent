import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
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

function startBrokerProcess() {
  return spawn(process.execPath, [brokerPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, METIS_STDIO_BROKER_GENERATION: '17', METIS_STDIO_BROKER_TEST_MODE: '1' },
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

test('P1-B1 validates owner specs, hard limit 255/256/257, and writer drain backpressure', () => {
  assert.equal(validateStartFrame(validStart()), true);
  for (const patch of [{ command: '' }, { command: 'x\0y' }, { args: ['x\0y'] }, { requestId: 'bad\nrequest' },
    { env: { 'bad\nkey': 'value' } }, { maxLineBytes: -1 }, { stdinMode: 'bad' }]) {
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
  const bounded = new BrokerWriter(blocked, { maxQueuedBytes: 20, onOverflow: () => { overflowed += 1; } });
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
  broker.handle(validStart('shared-total', { stdinMode: 'line', deadlineMs: 0, maxTotalOutputBytes: 5 }));
  await new Promise((resolve) => setImmediate(resolve));
  children[0].stdout.write('123');
  children[0].stderr.write('456');
  broker.handle({ type: 'owner.write', ownerId: 'shared-total', requestId: 'bad-line', line: 'x\ny' });
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
  broker.handle({ type: 'owner.write', ownerId: 'acks', requestId: 'write-1', line: 'hello' });
  await new Promise((resolve) => setImmediate(resolve));
  broker.handle({ type: 'owner.stop', ownerId: 'acks', requestId: 'stop-1', reason: 'secret-path-must-not-echo' });
  assert.equal(output.frames().find((frame) => frame.type === 'owner.started').requestId, 'start-1');
  assert.equal(output.frames().find((frame) => frame.type === 'owner.written').requestId, 'write-1');
  assert.equal(output.frames().find((frame) => frame.type === 'owner.stopping').requestId, 'stop-1');
  assert.equal(output.frames().find((frame) => frame.type === 'owner.stopping').reason, 'stopped');
  assert.equal(output.text.includes('secret-path-must-not-echo'), false);
  child.emit('close', null, 'SIGTERM');
});

test('P1-N3 test hang is gated and broker stdin has an exact raw byte cap', async () => {
  const output = new CollectingWritable();
  const production = new StdioBroker({ output, testMode: false });
  production.handle({ type: 'broker.test-hang', requestId: 'not-allowed' });
  assert.equal(production.hung, undefined);
  assert.equal(output.frames().at(-1).status, 'unsupported_frame');

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
