import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const proxyPath = fileURLToPath(new URL('./metis-s5-broker-writer-failure-proxy.mjs', import.meta.url));
const brokerPath = fileURLToPath(new URL('./metis-stdio-broker.mjs', import.meta.url));
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitUntil(check, message) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (check()) return;
    await delay(5);
  }
  assert.fail(message);
}

test('writer_closed proves physical EPIPE while the real proxy holds its real broker exit', async () => {
  const home = mkdtempSync(join(tmpdir(), 'metis-rr-v2-node-'));
  const paths = Object.fromEntries(['ready', 'fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease', 'holdReleased']
    .map((name) => [name, join(home, name)]));
  const child = spawn(process.execPath, [proxyPath, brokerPath], {
    env: {
      ...process.env,
      METIS_STDIO_BROKER_GENERATION: '1',
      METIS_S5_BROKER_PROXY_READY: paths.ready,
      METIS_S5_BROKER_PROXY_FAIL: paths.fail,
      METIS_S5_BROKER_PROXY_WRITER_CLOSED: paths.closed,
      METIS_S5_BROKER_PROXY_CLEANUP: paths.cleanup,
      METIS_S5_BROKER_PROXY_HOLD_ENTERED: paths.holdEntered,
      METIS_S5_BROKER_PROXY_HOLD_RELEASE: paths.holdRelease,
      METIS_S5_BROKER_PROXY_HOLD_RELEASED: paths.holdReleased,
      METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID: '',
      METIS_S5_BROKER_PROXY_ADMISSION_SEEN: '',
      METIS_S5_BROKER_PROXY_COMPLETION_DROPPED: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const closed = new Promise((resolve, reject) => {
    child.once('close', (code, signal) => resolve({ code, signal }));
    child.once('error', reject);
  });
  let stdout = '';
  let stderr = '';
  const inputErrors = [];
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  child.stdin.on('error', (error) => inputErrors.push(error.code));
  try {
    await waitUntil(() => existsSync(paths.ready) && stdout.includes('"broker.hello"'), 'real broker did not become ready');
    const brokerPid = JSON.parse(readFileSync(paths.ready, 'utf8')).brokerPid;
    assert.ok(brokerPid > 1);
    child.stdin.write(`${JSON.stringify({ type: 'broker.ping', requestId: 'v2-before-failure' })}\n`);
    await waitUntil(() => stdout.includes('"broker.pong"'), 'pre-failure ping did not traverse the real proxy');
    writeFileSync(paths.fail, 'fail\n');
    await waitUntil(() => existsSync(paths.closed) && existsSync(paths.holdEntered), 'physical close and held broker exit were not acknowledged');
    assert.equal(child.exitCode, null);
    assert.equal(child.signalCode, null);
    assert.doesNotThrow(() => process.kill(child.pid, 0));
    const writeError = await new Promise((resolve) => child.stdin.write('"after-physical-close"\n', resolve));
    assert.equal(writeError?.code, 'EPIPE');
    await waitUntil(() => inputErrors.includes('EPIPE'), 'the parent pipe did not report EPIPE');
    assert.equal(child.exitCode, null, 'EPIPE must be observed before releasing the held proxy');
    writeFileSync(paths.holdRelease, 'release\n');
    const result = await closed;
    assert.deepEqual(result, { code: 0, signal: null });
    assert.equal(existsSync(paths.holdReleased), true);
    assert.equal(stderr, '');
    const frames = stdout.trim().split('\n').map((line) => JSON.parse(line));
    assert.ok(frames.every((frame) => typeof frame.type === 'string' && frame.generation === 1));
    assert.ok(frames.some((frame) => frame.type === 'broker.pong' && frame.requestId === 'v2-before-failure'));
    assert.ok(frames.some((frame) => frame.type === 'broker.closed' && frame.ownerCount === 0));
    assert.throws(() => process.kill(brokerPid, 0), { code: 'ESRCH' });
    assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      writeFileSync(paths.cleanup, 'cleanup\n');
      writeFileSync(paths.holdRelease, 'release\n');
      const ended = await Promise.race([closed.then(() => true), delay(5_000).then(() => false)]);
      if (!ended) { child.kill('SIGKILL'); await closed; }
    }
    rmSync(home, { recursive: true, force: true });
    assert.equal(existsSync(home), false);
  }
});
