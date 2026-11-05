import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { closeSync, constants, existsSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync, writeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

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

test('writer failure closes inherited stdin FIFO aliases and preserves an unrelated FIFO', async () => {
  const home = mkdtempSync(join(tmpdir(), 'metis-rr-v3-node-'));
  const paths = Object.fromEntries(['ready', 'fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease', 'holdReleased']
    .map((name) => [name, join(home, name)]));
  const inputPath = join(home, 'stdin.fifo');
  const otherPath = join(home, 'unrelated.fifo');
  const acknowledgement = join(home, 'unrelated-read');
  const preload = join(home, 'sentinel.mjs');
  const descriptors = new Set();
  let child;
  let closed;
  let otherWrite;
  try {
    assert.equal(spawnSync('/usr/bin/mkfifo', [inputPath, otherPath]).status, 0);
    const inputRead = openSync(inputPath, constants.O_RDONLY | constants.O_NONBLOCK);
    descriptors.add(inputRead);
    const inputWrite = openSync(inputPath, constants.O_WRONLY | constants.O_NONBLOCK);
    descriptors.add(inputWrite);
    const otherRead = openSync(otherPath, constants.O_RDONLY | constants.O_NONBLOCK);
    descriptors.add(otherRead);
    otherWrite = openSync(otherPath, constants.O_WRONLY | constants.O_NONBLOCK);
    descriptors.add(otherWrite);
    // One asynchronous read cannot block the proxy event loop. The parent sends
    // its control word after writer_closed, or releases the read in finally.
    writeFileSync(preload, `import { read, writeFileSync } from 'node:fs';
if (process.argv[1] === ${JSON.stringify(proxyPath)}) {
  const buffer = Buffer.alloc(64);
  read(4, buffer, 0, buffer.length, null, (error, count) => {
    writeFileSync(${JSON.stringify(acknowledgement)}, error ? 'read_failed' : buffer.subarray(0, count));
  });
}
`);
    child = spawn(process.execPath, [proxyPath, brokerPath], {
      env: {
        ...process.env,
        NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ''} --import=${pathToFileURL(preload).href}`,
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
      stdio: [inputRead, 'pipe', 'pipe', inputRead, otherRead],
    });
    closed = new Promise((resolve, reject) => {
      child.once('close', (code, signal) => resolve({ code, signal }));
      child.once('error', reject);
    });
    // Leave no parent read endpoint that could itself keep the FIFO writable.
    for (const fd of [inputRead, otherRead]) { closeSync(fd); descriptors.delete(fd); }
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
    await waitUntil(() => existsSync(paths.ready) && stdout.includes('"broker.hello"'), 'FIFO proxy did not become ready');
    const brokerPid = JSON.parse(readFileSync(paths.ready, 'utf8')).brokerPid;
    writeSync(inputWrite, `${JSON.stringify({ type: 'broker.ping', requestId: 'v3-before-failure' })}\n`);
    await waitUntil(() => stdout.includes('"broker.pong"'), 'FIFO input did not carry the pre-failure ping');
    writeFileSync(paths.fail, 'fail\n');
    await waitUntil(() => existsSync(paths.closed) && existsSync(paths.holdEntered), 'FIFO close and broker hold were not acknowledged');
    assert.equal(child.exitCode, null);
    assert.doesNotThrow(() => process.kill(child.pid, 0));
    writeSync(otherWrite, 'unrelated-still-readable');
    await waitUntil(() => existsSync(acknowledgement), 'the unrelated FIFO was not readable after writer_closed');
    assert.equal(readFileSync(acknowledgement, 'utf8'), 'unrelated-still-readable');
    assert.throws(() => writeSync(inputWrite, 'after-physical-close\n'), { code: 'EPIPE' });
    assert.equal(child.exitCode, null, 'the physical failure must precede proxy release');
    writeFileSync(paths.holdRelease, 'release\n');
    await waitUntil(() => child.exitCode !== null || child.signalCode !== null, 'released FIFO proxy did not exit');
    assert.deepEqual(await closed, { code: 0, signal: null });
    assert.equal(stderr, '');
    const frames = stdout.trim().split('\n').map((line) => JSON.parse(line));
    assert.ok(frames.every((frame) => typeof frame.type === 'string' && frame.generation === 1));
    assert.ok(frames.some((frame) => frame.type === 'broker.closed' && frame.ownerCount === 0));
    assert.throws(() => process.kill(brokerPid, 0), { code: 'ESRCH' });
    assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
  } finally {
    if (otherWrite !== undefined) {
      try { writeSync(otherWrite, 'cleanup'); } catch { /* The owned reader may already have exited. */ }
    }
    if (child && child.exitCode === null && child.signalCode === null) {
      writeFileSync(paths.cleanup, 'cleanup\n');
      writeFileSync(paths.holdRelease, 'release\n');
      const ended = await Promise.race([closed.then(() => true), delay(5_000).then(() => false)]);
      if (!ended) { child.kill('SIGKILL'); await closed; }
    }
    for (const fd of descriptors) closeSync(fd);
    rmSync(home, { recursive: true, force: true });
    assert.equal(existsSync(home), false);
  }
});


// Actual attached helper/owner processes; birth files below are an algorithm
// handshake, not native OS birth observations (those remain Cangjie coverage).
function proxyAttachedPresent(pid, group = false) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return true;
  try { process.kill(group ? -pid : pid, 0); return true; }
  catch (error) { if (error?.code === 'ESRCH') return false; throw error; }
}

async function proxyAttachedWithin(check, deadline, fixedFailure) {
  while (Date.now() < deadline) {
    if (check()) return;
    await delay(5);
  }
  assert.fail(fixedFailure);
}

test('F3PX attached dispatch preserves raw bytes and business exit while bypassing framed fault controls', async () => {
  const { lstatSync, mkdirSync, realpathSync, renameSync } = await import('node:fs');
  const { publishRecoveryFact } = await import('./metis-stdio-broker.mjs');
  const parent = '1:99999:0:0:0:0:0:99999:0:1:1:0';
  const payload = Buffer.concat([Buffer.from('中文😀'.repeat(1024)), Buffer.from([0, 255, 254, 128, 195, 40])]);
  for (const code of [0, 7, 125, 126, 127]) {
    const home = mkdtempSync(join(realpathSync(tmpdir()), 'metis-s5-attached-'));
    const directory = join(home, 'inventory'); mkdirSync(directory, { mode: 0o700 });
    const nonce = `proxy-${process.pid}-${code}`;
    const key = 'b-attached';
    const paths = Object.fromEntries(['ready', 'fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease',
      'holdReleased', 'admission', 'dropped', 'business'].map(name => [name, join(home, name)]));
    writeFileSync(join(directory, 'inventory'),
      `managed-recovery-v1\nparent:${parent}\nbinding:${nonce}\ncoverage:broker-v1\n`, { mode: 0o600 });
    publishRecoveryFact(directory, key, 'intent', parent);
    const environment = { ...process.env,
      METIS_PROCESS_RECOVERY_DIRECTORY: directory, METIS_PROCESS_RECOVERY_PARENT: parent,
      METIS_PROCESS_RECOVERY_BROKER_KEY: key,
      METIS_S5_BROKER_PROXY_READY: '',
      METIS_S5_BROKER_PROXY_FAIL: paths.fail, METIS_S5_BROKER_PROXY_WRITER_CLOSED: paths.closed,
      METIS_S5_BROKER_PROXY_CLEANUP: paths.cleanup, METIS_S5_BROKER_PROXY_HOLD_ENTERED: paths.holdEntered,
      METIS_S5_BROKER_PROXY_HOLD_RELEASE: paths.holdRelease, METIS_S5_BROKER_PROXY_HOLD_RELEASED: paths.holdReleased,
      METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID: 'owned-delivery', METIS_S5_BROKER_PROXY_ADMISSION_SEEN: paths.admission,
      METIS_S5_BROKER_PROXY_COMPLETION_DROPPED: paths.dropped,
      METIS_PROCESS_RECOVERY_OWNER_PID: '', METIS_PROCESS_RECOVERY_OWNER_BIRTH: '',
    };
    delete environment.METIS_PROCESS_RECOVERY_OWNER_PID;
    delete environment.METIS_PROCESS_RECOVERY_OWNER_BIRTH;
    const business = `const fs=require('fs');fs.writeFileSync(${JSON.stringify(paths.business)},${JSON.stringify(nonce)});` +
      `const chunks=[];process.stdin.on('data',c=>chunks.push(c));process.stdin.on('end',()=>{` +
      `const bytes=Buffer.concat(chunks);process.stdout.write(bytes);process.stderr.write(bytes);process.exitCode=${code};});`;
    let child, closeReceipt, closeError, failure, ownerSpawnedText = '', ownerPid = 0, formal = false, cleanupTerminal = false;
    const stdout = [], stderr = [], inputErrors = [];
    const born = (sourceKey, pid, pgid) => {
      const text = `managed-recovery-v1\nkey:${sourceKey}\nphase:birth\nparent:${parent}\npid:${pid}\npgid:${pgid}\nbirth:${pid}:1:0\n`;
      const target = join(directory, `${sourceKey}.birth`);
      writeFileSync(`${target}.tmp`, text, { mode: 0o600 }); renameSync(`${target}.tmp`, target);
    };
    const spawned = sourceKey => {
      try {
        const text = readFileSync(join(directory, `${sourceKey}.spawned`), 'utf8');
        const match = /^pid:([0-9]+)$/mu.exec(text); return match ? Number(match[1]) : 0;
      } catch (error) { if (error?.code === 'ENOENT') return 0; throw error; }
    };
    try {
      const deadline = Date.now() + 5_000;
      child = spawn(process.execPath, [proxyPath, brokerPath, '--attached', process.execPath, '-e', business],
        { env: environment, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
      child.once('error', error => { closeError = error; });
      child.once('close', (actualCode, signal) => { closeReceipt = { code: actualCode, signal }; });
      child.stdout.on('data', chunk => stdout.push(chunk)); child.stderr.on('data', chunk => stderr.push(chunk));
      child.stdin.on('error', error => inputErrors.push(error.code));
      await proxyAttachedWithin(() => Boolean(closeError) || spawned(key) === child.pid, deadline, 'attached_helper_not_spawned');
      assert.equal(closeError, undefined);
      assert.equal(proxyAttachedPresent(child.pid), true);
      assert.equal(existsSync(paths.business), false);
      born(key, child.pid, 0);
      await proxyAttachedWithin(() => spawned(`${key}-o-1`) > 1, deadline, 'attached_owner_not_spawned');
      ownerPid = spawned(`${key}-o-1`);
      ownerSpawnedText = readFileSync(join(directory, `${key}-o-1.spawned`), 'utf8');
      assert.equal(ownerSpawnedText, `managed-recovery-v1\nkey:${key}-o-1\nphase:spawned\nparent:${parent}\npid:${ownerPid}\npgid:${ownerPid}\nbirth:\n`);
      assert.equal(existsSync(paths.business), false, 'no business before owner birth ACK');
      assert.equal(proxyAttachedPresent(ownerPid, true), true);
      born(`${key}-o-1`, ownerPid, ownerPid);
      child.stdin.end(payload);
      await proxyAttachedWithin(() => Boolean(closeReceipt), deadline, 'attached_close_not_observed');
      assert.deepEqual(closeReceipt, { code, signal: null });
      assert.equal(inputErrors.length, 0);
      assert.deepEqual(Buffer.concat(stdout), payload); assert.deepEqual(Buffer.concat(stderr), payload);
      assert.equal(readFileSync(paths.business, 'utf8'), nonce);
      for (const name of ['ready', 'fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease', 'holdReleased', 'admission', 'dropped']) {
        assert.equal(existsSync(paths[name]), false, 'attached_fault_sideeffect');
      }
      const spawnedText = readFileSync(join(directory, `${key}.spawned`), 'utf8');
      assert.equal(readFileSync(join(directory, `${key}.terminal`), 'utf8'), spawnedText.replace('phase:spawned\n', 'phase:terminal\n'));
      const checkpointPath = join(directory, `${key}.closed`);
      const checkpointInfo = lstatSync(checkpointPath);
      assert.equal(checkpointInfo.isFile() && !checkpointInfo.isSymbolicLink() && checkpointInfo.size <= 8192, true);
      assert.equal(readFileSync(checkpointPath, 'utf8'),
        `managed-recovery-v1\nparent:${parent}\nbroker:${key}\nissued:1\nranges:1-1\n`);
      assert.equal(proxyAttachedPresent(child.pid), false); assert.equal(proxyAttachedPresent(ownerPid, true), false);
      formal = true;
    } catch (error) { failure = error; } finally {
      const beforeFallback = { nonce, requestedCode: code, formal,
        helperCloseObserved: Boolean(closeReceipt), closeCode: closeReceipt?.code ?? null,
        closeSignal: closeReceipt?.signal ?? null, helperKnown: Boolean(child?.pid), ownerKnown: ownerPid > 1 };
      try {
        try { beforeFallback.helperPresent = child?.pid ? proxyAttachedPresent(child.pid) : null; }
        catch (error) { failure ??= error; }
        try { beforeFallback.ownerGroupPresent = ownerPid > 1 ? proxyAttachedPresent(ownerPid, true) : null; }
        catch (error) { failure ??= error; }
        try { beforeFallback.helperTerminal = existsSync(join(directory, `${key}.terminal`)); }
        catch (error) { failure ??= error; }
        beforeFallback.ownerSpawnedBeforeAck = ownerSpawnedText;
        try { beforeFallback.ownerTerminalFilePresent = existsSync(join(directory, `${key}-o-1.terminal`)); }
        catch (error) { failure ??= error; }
        try { beforeFallback.closedCheckpointRaw = existsSync(join(directory, `${key}.closed`))
          ? readFileSync(join(directory, `${key}.closed`), 'utf8') : null; }
        catch (error) { failure ??= error; }
        try { beforeFallback.helperTerminalRaw = existsSync(join(directory, `${key}.terminal`))
          ? readFileSync(join(directory, `${key}.terminal`), 'utf8') : null; }
        catch (error) { failure ??= error; }
        try { writeFileSync(join(home, 'stdout.bin'), Buffer.concat(stdout), { mode: 0o600 }); }
        catch (error) { failure ??= error; }
        try { writeFileSync(join(home, 'stderr.bin'), Buffer.concat(stderr), { mode: 0o600 }); }
        catch (error) { failure ??= error; }
        try { writeFileSync(join(home, 'formal-before-fallback.json'), JSON.stringify(beforeFallback), { mode: 0o600 }); }
        catch (error) { failure ??= error; }
      } finally {
        const cleanupDeadline = Date.now() + 5_000;
        try {
          if (child && !closeReceipt && !closeError) child.kill('SIGTERM');
          if (child) await proxyAttachedWithin(() => Boolean(closeReceipt) && !proxyAttachedPresent(child.pid) &&
            (ownerPid <= 1 || !proxyAttachedPresent(ownerPid, true)), cleanupDeadline, 'attached_cleanup_pending');
          cleanupTerminal = Boolean(child && closeReceipt) && !proxyAttachedPresent(child.pid) &&
            (ownerPid <= 1 || !proxyAttachedPresent(ownerPid, true)) && Date.now() <= cleanupDeadline;
        } catch (error) { failure ??= error; }
        try { writeFileSync(join(home, 'cleanup-receipt.json'), JSON.stringify({ nonce, cleanupTerminal,
          helperCloseObserved: Boolean(closeReceipt) }), { mode: 0o600 }); }
        catch (error) { failure ??= error; }
        try { assert.equal(cleanupTerminal, true); } catch (error) { failure ??= error; }
        if (!failure && formal && cleanupTerminal) rmSync(home, { recursive: true, force: true });
      }
    }
    if (failure) throw failure;
  }
});


// These are real processes and real protocol/FD observations. Native birth
// capture remains Cangjie coverage; Node supplies the documented algorithm ACK.
test('F7 framed full-context same-PID ownership, physical writer hold and parent-death cleanup', async () => {
  const { mkdirSync, realpathSync, renameSync, lstatSync } = await import('node:fs');
  const { publishRecoveryFact } = await import('./metis-stdio-broker.mjs');
  const parent = '1:99999:0:0:0:0:0:99999:0:1:1:0';
  for (const scenario of ['ping', 'writer', 'wrong-parent', 'malformed-parent', 'parent-death']) {
    const home = mkdtempSync(join(realpathSync(tmpdir()), 'metis-s5-framed-'));
    const directory = join(home, 'inventory'); mkdirSync(directory, { mode: 0o700 });
    const key = 'b-framed', nonce = `framed-${process.pid}-${scenario}`;
    const paths = Object.fromEntries(['ready', 'fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease',
      'holdReleased', 'actor', 'business'].map(name => [name, join(home, name)]));
    writeFileSync(join(directory, 'inventory'),
      `managed-recovery-v1\nparent:${parent}\nbinding:${nonce}\ncoverage:broker-v1\n`, { mode: 0o600 });
    publishRecoveryFact(directory, key, 'intent', parent);
    const held = scenario === 'writer' || scenario === 'parent-death';
    const environment = { ...process.env, METIS_STDIO_BROKER_GENERATION: '1', METIS_STDIO_BROKER_TEST_MODE: '0',
      METIS_PROCESS_RECOVERY_DIRECTORY: directory, METIS_PROCESS_RECOVERY_PARENT: parent,
      METIS_PROCESS_RECOVERY_BROKER_KEY: key, METIS_PROCESS_RECOVERY_OWNER_PID: String(process.pid),
      METIS_PROCESS_RECOVERY_OWNER_BIRTH: `${process.pid}:1:0`,
      METIS_S5_BROKER_PROXY_READY: paths.ready, METIS_S5_BROKER_PROXY_FAIL: paths.fail,
      METIS_S5_BROKER_PROXY_WRITER_CLOSED: paths.closed, METIS_S5_BROKER_PROXY_CLEANUP: paths.cleanup,
      METIS_S5_BROKER_PROXY_HOLD_ENTERED: held ? paths.holdEntered : '',
      METIS_S5_BROKER_PROXY_HOLD_RELEASE: held ? paths.holdRelease : '',
      METIS_S5_BROKER_PROXY_HOLD_RELEASED: held ? paths.holdReleased : '',
      METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID: '', METIS_S5_BROKER_PROXY_ADMISSION_SEEN: '',
      METIS_S5_BROKER_PROXY_COMPLETION_DROPPED: '',
    };
    delete environment.METIS_STDIO_BROKER_DIAGNOSTIC_MARKER;
    delete environment.METIS_TEST_STDIO_BROKER_RECOVERY_DIAGNOSTICS_ONLY;
    if (scenario === 'wrong-parent') environment.METIS_PROCESS_RECOVERY_OWNER_PID = '1';
    if (scenario === 'malformed-parent') environment.METIS_PROCESS_RECOVERY_OWNER_BIRTH = 'invalid';
    let driver, closeReceipt, spawnError, streamError, failure, helperPid = 0, ownerPid = 0, formal = false, cleanupTerminal = false;
    const frames = [], rawOut = [], rawErr = [], inputErrors = [];
    const decoder = new TextDecoder('utf-8', { fatal: true }); let pending = '';
    const born = (sourceKey, pid, pgid) => {
      const path = join(directory, `${sourceKey}.birth`);
      writeFileSync(`${path}.tmp`, `managed-recovery-v1\nkey:${sourceKey}\nphase:birth\nparent:${parent}\npid:${pid}\npgid:${pgid}\nbirth:${pid}:1:0\n`, { mode: 0o600 });
      renameSync(`${path}.tmp`, path);
    };
    const sourcePid = sourceKey => {
      try { return Number(/^pid:([0-9]+)$/mu.exec(readFileSync(join(directory, `${sourceKey}.spawned`), 'utf8'))?.[1] ?? 0); }
      catch (error) { if (error?.code === 'ENOENT') return 0; throw error; }
    };
    const sourceText = name => readFileSync(join(directory, name), 'utf8');
    const sourceTerminal = () => existsSync(join(directory, `${key}.terminal`)) &&
      sourceText(`${key}.terminal`) === sourceText(`${key}.spawned`).replace('phase:spawned\n', 'phase:terminal\n');
    const send = value => driver.stdin.write(JSON.stringify(value) + '\n');
    try {
      const deadline = Date.now() + 5_000;
      if (scenario === 'parent-death') {
        const actor = `const fs=require('fs'),cp=require('child_process');const env={...process.env,` +
          `METIS_PROCESS_RECOVERY_OWNER_PID:String(process.pid),METIS_PROCESS_RECOVERY_OWNER_BIRTH:process.pid+':1:0'};` +
          `const c=cp.spawn(process.execPath,${JSON.stringify([proxyPath, brokerPath])},{env,detached:true,stdio:['pipe','pipe','pipe']});` +
          `fs.writeFileSync(${JSON.stringify(paths.actor)},JSON.stringify({nonce:${JSON.stringify(nonce)},actorPid:process.pid,helperPid:c.pid}));` +
          `process.stdin.pipe(c.stdin);c.stdin.on('error',()=>{});c.stdout.pipe(process.stdout);c.stderr.pipe(process.stderr);` +
          `c.on('close',code=>{process.stdin.destroy();process.exitCode=code;});`;
        driver = spawn(process.execPath, ['-e', actor], { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
      } else driver = spawn(process.execPath, [proxyPath, brokerPath], { env: environment, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
      driver.once('error', error => { spawnError = error; });
      driver.once('close', (code, signal) => { closeReceipt = { code, signal }; });
      driver.stdin.on('error', error => inputErrors.push(error.code));
      driver.stdout.on('data', bytes => {
        rawOut.push(bytes);
        try {
          pending += decoder.decode(bytes, { stream: true });
          for (;;) { const end = pending.indexOf('\n'); if (end < 0) break;
            const line = pending.slice(0, end); pending = pending.slice(end + 1); frames.push(JSON.parse(line)); }
        } catch (error) { streamError ??= error; }
      });
      driver.stderr.on('data', bytes => rawErr.push(bytes));
      await proxyAttachedWithin(() => Boolean(spawnError) || sourcePid(key) > 1 || Boolean(closeReceipt), deadline, 'framed_spawn_missing');
      assert.equal(spawnError, undefined);
      helperPid = sourcePid(key);
      assert(helperPid > 1);
      if (scenario === 'parent-death') {
        await proxyAttachedWithin(() => existsSync(paths.actor), deadline, 'framed_actor_receipt_missing');
        const actualActor = JSON.parse(readFileSync(paths.actor, 'utf8'));
        assert.deepEqual(actualActor, { nonce, actorPid: driver.pid, helperPid });
      } else assert.equal(helperPid, driver.pid);
      if (scenario === 'wrong-parent' || scenario === 'malformed-parent') {
        await proxyAttachedWithin(() => Boolean(closeReceipt), deadline, 'invalid_parent_not_closed');
        assert.equal(frames.some(frame => frame.type === 'broker.hello' || frame.type === 'owner.started'), false);
        assert.equal(existsSync(paths.business), false);
        assert.equal(existsSync(join(directory, `${key}.birth`)), false);
        assert.equal(existsSync(join(directory, `${key}-o-1.intent`)), false);
        assert.equal(proxyAttachedPresent(helperPid), false);
      } else {
        await proxyAttachedWithin(() => frames.some(frame => frame.type === 'broker.hello') && existsSync(paths.ready), deadline, 'framed_hello_missing');
        const hello = frames.find(frame => frame.type === 'broker.hello');
        const ready = JSON.parse(readFileSync(paths.ready, 'utf8'));
        assert.equal(hello.pid, helperPid);
        assert.equal(ready.wrapperPid, helperPid); assert.equal(ready.brokerPid, helperPid); assert.equal(ready.helloBrokerPid, helperPid);
        born(key, helperPid, 0);
        send({ type: 'broker.ping', requestId: 'bound-ping' });
        await proxyAttachedWithin(() => frames.some(frame => frame.type === 'broker.pong' && frame.requestId === 'bound-ping'), deadline, 'bound_ping_missing');
        if (scenario === 'ping') {
          driver.stdin.end();
          await proxyAttachedWithin(() => Boolean(closeReceipt), deadline, 'bound_ping_close_missing');
          assert.deepEqual(closeReceipt, { code: 0, signal: null });
        } else {
          const business = `require('fs').writeFileSync(${JSON.stringify(paths.business)},${JSON.stringify(nonce)});` +
            `process.stdout.write(${JSON.stringify('中文😀\n')});process.on('SIGTERM',()=>{});setInterval(()=>{},1000);`;
          send({ type: 'owner.start', ownerId: 'bound-owner', requestId: 'bound-start', command: process.execPath,
            args: ['-e', business], stdinMode: 'closed', outputMode: 'line', deadlineMs: 0 });
          await proxyAttachedWithin(() => sourcePid(`${key}-o-1`) > 1 && frames.some(frame => frame.type === 'owner.started'), deadline, 'bound_owner_missing');
          ownerPid = sourcePid(`${key}-o-1`);
          assert.equal(existsSync(paths.business), false);
          born(`${key}-o-1`, ownerPid, ownerPid);
          send({ type: 'owner.recovery-commit', ownerId: 'bound-owner', ownerIncarnation: 'bound-start' });
          await proxyAttachedWithin(() => existsSync(paths.business) && frames.some(frame => frame.type === 'owner.stdout' && frame.text.includes('中文😀')), deadline, 'bound_business_missing');
          writeFileSync(paths.fail, 'fail\n');
          await proxyAttachedWithin(() => existsSync(paths.closed) && existsSync(paths.holdEntered), deadline, 'bound_writer_hold_missing');
          assert.equal(closeReceipt, undefined);
          assert.equal(proxyAttachedPresent(helperPid), true, 'logical exit is not an OS close receipt');
          assert.equal(proxyAttachedPresent(ownerPid, true), false);
          assert.equal(sourceTerminal(), true);
          const checkpoint = join(directory, `${key}.closed`), info = lstatSync(checkpoint);
          assert(info.isFile() && !info.isSymbolicLink() && info.size <= 8192);
          assert.equal(sourceText(`${key}.closed`), `managed-recovery-v1\nparent:${parent}\nbroker:${key}\nissued:1\nranges:1-1\n`);
          if (scenario === 'writer') {
            let writeReceipt;
            driver.stdin.write('after-physical-close\n', error => { writeReceipt = { error }; });
            await proxyAttachedWithin(() => Boolean(writeReceipt), deadline, 'bound_write_callback_missing');
            assert.equal(writeReceipt.error?.code, 'EPIPE');
            await proxyAttachedWithin(() => inputErrors.includes('EPIPE'), deadline, 'bound_epipe_missing');
            writeFileSync(paths.holdRelease, 'release\n');
            await proxyAttachedWithin(() => Boolean(closeReceipt), deadline, 'bound_release_close_missing');
            assert.deepEqual(closeReceipt, { code: 0, signal: null });
          } else {
            assert.equal(existsSync(paths.holdRelease), false);
            driver.kill('SIGKILL');
            await proxyAttachedWithin(() => Boolean(closeReceipt) && !proxyAttachedPresent(helperPid) && !proxyAttachedPresent(helperPid, true), deadline, 'bound_parent_death_left_helper');
            assert.deepEqual(closeReceipt, { code: null, signal: 'SIGKILL' });
            assert.equal(existsSync(paths.holdRelease), false, 'parent-death cleanup cannot need release');
          }
        }
        assert.equal(sourceTerminal(), true);
        assert.equal(proxyAttachedPresent(helperPid), false);
        assert.equal(proxyAttachedPresent(helperPid, true), false);
        if (ownerPid) assert.equal(proxyAttachedPresent(ownerPid, true), false);
      }
      assert.equal(streamError, undefined);
      assert.equal(Buffer.concat(rawErr).length, 0);
      formal = true;
    } catch (error) { failure = error; } finally {
      const beforeFallback = { schema: 'metis-px-framed-before-fallback-v1', scenario, nonce, formal,
        driverCloseObserved: Boolean(closeReceipt), driverClose: closeReceipt ?? null,
        helperWaitReceiptDirectObserved: scenario !== 'parent-death' && Boolean(closeReceipt) && helperPid === driver?.pid, helperPid, ownerPid, sources: {} };
      try {
        try { beforeFallback.helperPresent = helperPid > 1 ? proxyAttachedPresent(helperPid) : null; }
        catch (error) { failure ??= error; }
        try { beforeFallback.ownerGroupPresent = ownerPid > 1 ? proxyAttachedPresent(ownerPid, true) : null; }
        catch (error) { failure ??= error; }
        for (const name of ['inventory', `${key}.intent`, `${key}.spawned`, `${key}.birth`, `${key}.terminal`, `${key}.closed`]) {
          try {
            const path = join(directory, name);
            if (!existsSync(path)) { beforeFallback.sources[name] = { present: false }; continue; }
            const bytes = readFileSync(path); assert(bytes.length <= 16384);
            beforeFallback.sources[name] = { present: true, bytesBase64: bytes.toString('base64') };
          } catch (error) { failure ??= error; }
        }
        for (const [name, bytes] of [['stdout.bin', Buffer.concat(rawOut)], ['stderr.bin', Buffer.concat(rawErr)]]) {
          try { writeFileSync(join(home, name), bytes, { mode: 0o600 }); } catch (error) { failure ??= error; }
        }
        try { writeFileSync(join(home, 'formal-before-fallback.json'), JSON.stringify(beforeFallback), { mode: 0o600 }); }
        catch (error) { failure ??= error; }
      } finally {
        const cleanupDeadline = Date.now() + 5_000;
        try { writeFileSync(paths.cleanup, 'cleanup\n'); } catch (error) { failure ??= error; }
        try { writeFileSync(paths.holdRelease, 'release\n'); } catch (error) { failure ??= error; }
        try {
          if (driver && !closeReceipt && !spawnError) driver.kill('SIGTERM');
          if (driver) await proxyAttachedWithin(() => Boolean(closeReceipt) &&
            (helperPid <= 1 || !proxyAttachedPresent(helperPid)) &&
            (ownerPid <= 1 || !proxyAttachedPresent(ownerPid, true)), cleanupDeadline, 'framed_cleanup_pending');
          cleanupTerminal = Boolean(driver && closeReceipt) && helperPid > 1 && !proxyAttachedPresent(helperPid) &&
            (ownerPid <= 1 || !proxyAttachedPresent(ownerPid, true)) && Date.now() <= cleanupDeadline;
        } catch (error) { failure ??= error; }
        try { writeFileSync(join(home, 'cleanup-receipt.json'), JSON.stringify({ nonce, cleanupTerminal,
          driverCloseObserved: Boolean(closeReceipt) }), { mode: 0o600 }); } catch (error) { failure ??= error; }
        try { assert.equal(cleanupTerminal, true); } catch (error) { failure ??= error; }
        if (formal && cleanupTerminal && !failure) rmSync(home, { recursive: true, force: true });
      }
    }
    if (failure) throw failure;
  }
});

test('F13 configured but unarmed writer hold preserves normal discovery and bound broker close', async () => {
  const { lstatSync, mkdirSync, realpathSync, renameSync } = await import('node:fs');
  const { publishRecoveryFact } = await import('./metis-stdio-broker.mjs');
  const parent = '1:99999:0:0:0:0:0:99999:0:1:1:0';
  for (const scenario of ['unbound', 'fullcontext']) {
    const home = mkdtempSync(join(realpathSync(tmpdir()), 'metis-s5-unarmed-'));
    const directory = join(home, 'inventory'), key = 'b-unarmed';
    const nonce = `unarmed-${process.pid}-${scenario}`;
    const paths = Object.fromEntries(['ready', 'fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease',
      'holdReleased'].map(name => [name, join(home, name)]));
    const inventoryText = `managed-recovery-v1\nparent:${parent}\nbinding:${nonce}\ncoverage:broker-v1\n`;
    let child, closeReceipt, spawnError, streamError, failure, helperPid = 0;
    let launchAttempted = false, formal = false, cleanupTerminal = false;
    let closeStartedAt = null, closeObservedAt = null, spawnedText = '';
    const frames = [], stdout = [], stderr = [], inputErrors = [];
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let pending = Buffer.alloc(0);
    const sourceNames = ['inventory', `${key}.intent`, `${key}.spawned`, `${key}.birth`, `${key}.terminal`];
    try {
      writeFileSync(join(home, 'fixture.owner.json'), JSON.stringify({
        schema: 'metis-px-unarmed-owner-v1', nonce, scenario, testPid: process.pid,
      }), { mode: 0o600 });
      const environment = { ...process.env, HOME: home, TMPDIR: home, METIS_HOME: home,
        METIS_STDIO_BROKER_GENERATION: '1', METIS_STDIO_BROKER_TEST_MODE: '0',
        METIS_S5_BROKER_PROXY_READY: paths.ready, METIS_S5_BROKER_PROXY_FAIL: paths.fail,
        METIS_S5_BROKER_PROXY_WRITER_CLOSED: paths.closed, METIS_S5_BROKER_PROXY_CLEANUP: paths.cleanup,
        METIS_S5_BROKER_PROXY_HOLD_ENTERED: paths.holdEntered,
        METIS_S5_BROKER_PROXY_HOLD_RELEASE: paths.holdRelease,
        METIS_S5_BROKER_PROXY_HOLD_RELEASED: paths.holdReleased,
        METIS_S5_BROKER_PROXY_DROP_DELIVERY_ID: '', METIS_S5_BROKER_PROXY_ADMISSION_SEEN: '',
        METIS_S5_BROKER_PROXY_COMPLETION_DROPPED: '',
      };
      for (const name of ['METIS_PROCESS_RECOVERY_DIRECTORY', 'METIS_PROCESS_RECOVERY_PARENT',
        'METIS_PROCESS_RECOVERY_BROKER_KEY', 'METIS_PROCESS_RECOVERY_OWNER_PID',
        'METIS_PROCESS_RECOVERY_OWNER_BIRTH', 'METIS_STDIO_BROKER_DIAGNOSTIC_MARKER',
        'METIS_TEST_STDIO_BROKER_RECOVERY_DIAGNOSTICS_ONLY']) delete environment[name];
      if (scenario === 'fullcontext') {
        mkdirSync(directory, { mode: 0o700 });
        writeFileSync(join(directory, 'inventory'), inventoryText, { mode: 0o600 });
        publishRecoveryFact(directory, key, 'intent', parent);
        Object.assign(environment, { METIS_PROCESS_RECOVERY_DIRECTORY: directory,
          METIS_PROCESS_RECOVERY_PARENT: parent, METIS_PROCESS_RECOVERY_BROKER_KEY: key,
          METIS_PROCESS_RECOVERY_OWNER_PID: String(process.pid),
          METIS_PROCESS_RECOVERY_OWNER_BIRTH: `${process.pid}:1:0` });
      }
      const startupDeadline = Date.now() + 5_000;
      launchAttempted = true;
      child = spawn(process.execPath, [proxyPath, brokerPath],
        { env: environment, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
      child.once('error', error => { spawnError = error; });
      child.once('close', (code, signal) => { closeObservedAt = Date.now(); closeReceipt = { code, signal }; });
      child.stdin.on('error', error => inputErrors.push(error.code));
      child.stdout.on('data', bytes => {
        stdout.push(bytes);
        try {
          pending = Buffer.concat([pending, bytes]);
          for (;;) {
            const end = pending.indexOf(0x0a);
            if (end < 0) break;
            frames.push(JSON.parse(decoder.decode(pending.subarray(0, end))));
            pending = pending.subarray(end + 1);
          }
        } catch (error) { streamError ??= error; }
      });
      child.stderr.on('data', bytes => stderr.push(bytes));
      await proxyAttachedWithin(() => Boolean(spawnError) || Boolean(closeReceipt) ||
        (existsSync(paths.ready) && frames.some(frame => frame.type === 'broker.hello')),
      startupDeadline, 'unarmed_hello_missing');
      assert.equal(spawnError, undefined); assert.equal(streamError, undefined);
      assert.equal(closeReceipt, undefined);
      helperPid = child.pid;
      assert(Number.isSafeInteger(helperPid) && helperPid > 1);
      const ready = JSON.parse(readFileSync(paths.ready, 'utf8'));
      const hello = frames.find(frame => frame.type === 'broker.hello');
      assert.equal(hello.pid, helperPid); assert.equal(hello.generation, 1);
      assert.equal(ready.wrapperPid, helperPid); assert.equal(ready.brokerPid, helperPid);
      assert.equal(ready.helloBrokerPid, helperPid); assert.equal(ready.parentPid, process.pid);
      assert.equal(ready.generation, 1); assert.equal(ready.ownerPid, 0); assert.equal(ready.gcmOwnerPid, 0);
      if (scenario === 'fullcontext') {
        assert.equal(readFileSync(join(directory, 'inventory'), 'utf8'), inventoryText);
        spawnedText = readFileSync(join(directory, `${key}.spawned`), 'utf8');
        assert.equal(spawnedText,
          `managed-recovery-v1\nkey:${key}\nphase:spawned\nparent:${parent}\npid:${helperPid}\npgid:0\nbirth:\n`);
        // Algorithm ACK only; native birth observation remains Cangjie coverage.
        const birthPath = join(directory, `${key}.birth`);
        writeFileSync(`${birthPath}.tmp`,
          `managed-recovery-v1\nkey:${key}\nphase:birth\nparent:${parent}\npid:${helperPid}\npgid:0\nbirth:${helperPid}:1:0\n`, { mode: 0o600 });
        renameSync(`${birthPath}.tmp`, birthPath);
      }
      assert.equal(existsSync(paths.fail), false);
      closeStartedAt = Date.now();
      child.stdin.write(`${JSON.stringify({ type: 'broker.close' })}\n`);
      await proxyAttachedWithin(() => Boolean(closeReceipt), closeStartedAt + 2_000, 'unarmed_actual_close_timeout');
      assert.deepEqual(closeReceipt, { code: 0, signal: null });
      assert(closeObservedAt - closeStartedAt <= 2_000);
      assert.equal(proxyAttachedPresent(helperPid), false); assert.equal(proxyAttachedPresent(helperPid, true), false);
      assert.equal(streamError, undefined); assert.equal(pending.length, 0);
      assert.deepEqual(inputErrors, []); assert.equal(Buffer.concat(stderr).length, 0);
      assert.deepEqual(frames.map(frame => frame.type), ['broker.hello', 'broker.closed']);
      assert(frames.every(frame => frame.generation === 1));
      assert.equal(frames[1].ownerCount, 0);
      for (const name of ['fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease', 'holdReleased']) {
        assert.equal(existsSync(paths[name]), false, 'unarmed_fault_sideeffect');
      }
      if (scenario === 'fullcontext') {
        assert.equal(readFileSync(join(directory, 'inventory'), 'utf8'), inventoryText);
        const terminalPath = join(directory, `${key}.terminal`), info = lstatSync(terminalPath);
        assert(info.isFile() && !info.isSymbolicLink() && info.size <= 16_384);
        assert.equal(readFileSync(terminalPath, 'utf8'), spawnedText.replace('phase:spawned\n', 'phase:terminal\n'));
        assert.equal(existsSync(join(directory, `${key}-o-1.intent`)), false);
      } else assert.equal(existsSync(directory), false);
      formal = true;
    } catch (error) { failure = error; } finally {
      const beforeFallback = { schema: 'metis-px-unarmed-before-fallback-v1', nonce, scenario, formal,
        launchAttempted, helperPid, actualClose: closeReceipt ?? null, closeStartedAt, closeObservedAt,
        helperCloseObserved: Boolean(closeReceipt), sources: {}, markers: {} };
      try {
        try { beforeFallback.helperPresent = helperPid > 1 ? proxyAttachedPresent(helperPid) : null; }
        catch (error) { failure ??= error; }
        try { beforeFallback.helperGroupPresent = helperPid > 1 ? proxyAttachedPresent(helperPid, true) : null; }
        catch (error) { failure ??= error; }
        for (const name of ['fail', 'closed', 'cleanup', 'holdEntered', 'holdRelease', 'holdReleased']) {
          try { beforeFallback.markers[name] = existsSync(paths[name]); } catch (error) { failure ??= error; }
        }
        if (scenario === 'fullcontext') for (const name of sourceNames) {
          try {
            const path = join(directory, name);
            if (!existsSync(path)) { beforeFallback.sources[name] = { present: false }; continue; }
            const info = lstatSync(path); assert(info.isFile() && !info.isSymbolicLink() && info.size <= 16_384);
            beforeFallback.sources[name] = { present: true, bytesBase64: readFileSync(path).toString('base64') };
          } catch (error) { failure ??= error; }
        }
        for (const [name, bytes] of [['stdout.bin', Buffer.concat(stdout)], ['stderr.bin', Buffer.concat(stderr)]]) {
          try { writeFileSync(join(home, name), bytes, { mode: 0o600 }); } catch (error) { failure ??= error; }
        }
        try { writeFileSync(join(home, 'formal-before-fallback.json'), JSON.stringify(beforeFallback), { mode: 0o600 }); }
        catch (error) { failure ??= error; }
      } finally {
        const cleanupDeadline = Date.now() + 5_000;
        if (child && !closeReceipt) {
          try { writeFileSync(paths.cleanup, 'cleanup\n'); } catch (error) { failure ??= error; }
          try { writeFileSync(paths.holdRelease, 'release\n'); } catch (error) { failure ??= error; }
          try { child.kill('SIGTERM'); } catch (error) { failure ??= error; }
          const graceDeadline = Math.min(cleanupDeadline, Date.now() + 250);
          while (!closeReceipt && Date.now() < graceDeadline) await delay(5);
          if (!closeReceipt) { try { child.kill('SIGKILL'); } catch (error) { failure ??= error; } }
        }
        try {
          if (child) await proxyAttachedWithin(() => Boolean(closeReceipt) &&
            !proxyAttachedPresent(child.pid) && !proxyAttachedPresent(child.pid, true),
          cleanupDeadline, 'unarmed_cleanup_pending');
          cleanupTerminal = launchAttempted && Boolean(child && closeReceipt) &&
            !proxyAttachedPresent(child.pid) && !proxyAttachedPresent(child.pid, true) && Date.now() <= cleanupDeadline;
        } catch (error) { failure ??= error; }
        try { writeFileSync(join(home, 'cleanup-receipt.json'), JSON.stringify({ nonce, cleanupTerminal,
          actualClose: closeReceipt ?? null }), { mode: 0o600 }); } catch (error) { failure ??= error; }
        try { assert.equal(cleanupTerminal, true); } catch (error) { failure ??= error; }
        if (formal && cleanupTerminal && !failure) rmSync(home, { recursive: true, force: true });
      }
    }
    if (failure) {
      console.error(`F13 retained basename=${home.split('/').at(-1)};scenario=${scenario};nonce=${nonce}`);
      throw failure;
    }
  }
});
