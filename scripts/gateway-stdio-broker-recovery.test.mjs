import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, realpathSync, readFileSync, writeFileSync, existsSync, readdirSync, rmSync, renameSync, mkdirSync, symlinkSync, chmodSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EventEmitter } from 'node:events';
import { Writable, PassThrough, Duplex } from 'node:stream';
import { StdioBroker, publishRecoveryFact as publishSourceFact, mergeClosedSequence, publishClosedCheckpoint, recoveryGateShell } from './metis-stdio-broker.mjs';

const script = fileURLToPath(new URL('./metis-stdio-broker.mjs', import.meta.url));
const parent = '1:99999:0:0:0:0:0:99999:0:1:1:0';
// Synthetic-source tests use a canonical header; real OS births remain Cj test coverage.
function publishRecoveryFact(directory, key, phase, identity, ...values) {
  publishSourceFact(directory, key, phase, identity, ...values);
  const header = join(directory, 'inventory');
  if (!existsSync(header)) writeFileSync(header,
    `managed-recovery-v1\nparent:${identity}\nbinding:node-algorithm-fixture\ncoverage:broker-v1\n`, { mode: 0o600 });
}
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate, timeout = 5000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (predicate()) return true; await pause(10); }
  return false;
}
function birth(directory, key, pid, pgid) {
  // Algorithm fixture: native birth capture/probe is tested in Cangjie, never replaced in production.
  const text = `managed-recovery-v1\nkey:${key}\nphase:birth\nparent:${parent}\npid:${pid}\npgid:${pgid}\nbirth:${pid}:1:0\n`;
  writeFileSync(join(directory, `${key}.birth.tmp`), text, { mode: 0o600 });
  renameSync(join(directory, `${key}.birth.tmp`), join(directory, `${key}.birth`));
}
function spawnedPid(directory, key) {
  try { return Number(/^pid:([0-9]+)$/mu.exec(readFileSync(join(directory, `${key}.spawned`), 'utf8'))[1]); }
  catch { return 0; }
}

test('R-GATE-DYLD-N1 gate values stay in env and shadow collisions preserve originals', () => {
  const value = '空 格😀\n\'"$() `literal`';
  const env = { DYLD_TEST_VALUE: value, DYLD_TEST_EMPTY: '', METIS_GATE_DYLD_0: 'original',
    'DYLD_INVALID-NAME': 'existing-shell-limit' };
  const gate = recoveryGateShell(env, 'darwin');
  assert(!gate.script.includes(value));
  assert(!gate.script.includes('existing-shell-limit'));
  assert(!gate.script.includes('DYLD_INVALID-NAME'));
  assert.equal(gate.env.METIS_GATE_DYLD_0, 'original');
  assert.equal(gate.env.METIS_GATE_DYLD_1, value);
  assert.equal(gate.env.METIS_GATE_DYLD_2, '');
  assert.deepEqual(env, { DYLD_TEST_VALUE: value, DYLD_TEST_EMPTY: '', METIS_GATE_DYLD_0: 'original',
    'DYLD_INVALID-NAME': 'existing-shell-limit' });
  const plain = recoveryGateShell(env, 'linux');
  assert.equal(plain.env, env);
  assert.equal(plain.script, 'IFS= read -r metis_gate <&3 || exit 125; exec 3<&-; exec "$@"');
});

test('R-GATE-DYLD-P1 framed and attached ACK gates preserve exact loader environment', { skip: process.platform !== 'darwin' }, async () => {
  for (const attached of [false, true]) {
    const home = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-dyld-'));
    const directory = join(home, 'inventory'); mkdirSync(directory);
    const sentinel = join(home, 'sideeffect'), receipt = join(home, 'receipt');
    const key = 'b-dyld';
    const expected = { DYLD_METIS_QUOTES: `空 格中文😀\n'" $(touch ${sentinel}) \`touch ${sentinel}\``,
      DYLD_METIS_EMPTY: '', METIS_GATE_DYLD_0: 'original-zero', METIS_GATE_DYLD_1: 'original-one' };
    if (Object.hasOwn(process.env, 'DYLD_LIBRARY_PATH')) expected.DYLD_LIBRARY_PATH = process.env.DYLD_LIBRARY_PATH;
    const environment = { ...process.env, ...expected, METIS_DYLD_EXPECTED: JSON.stringify(expected),
      METIS_DYLD_RECEIPT: receipt, METIS_PROCESS_RECOVERY_DIRECTORY: directory,
      METIS_PROCESS_RECOVERY_PARENT: parent, METIS_PROCESS_RECOVERY_BROKER_KEY: key };
    delete environment.DYLD_METIS_ABSENT;
    const business = `const fs=require('fs');const expected=JSON.parse(process.env.METIS_DYLD_EXPECTED);` +
      `const exact=Object.entries(expected).every(([k,v])=>process.env[k]===v);` +
      `const shadows=Object.keys(process.env).filter(k=>k.startsWith('METIS_GATE_DYLD_')).sort();` +
      `fs.writeFileSync(process.env.METIS_DYLD_RECEIPT,JSON.stringify({exact,absent:!Object.hasOwn(process.env,'DYLD_METIS_ABSENT'),` +
      `shadows:JSON.stringify(shadows)===JSON.stringify(['METIS_GATE_DYLD_0','METIS_GATE_DYLD_1'])}));` +
      `process.stdout.write('中文😀');process.exitCode=7;`;
    publishRecoveryFact(directory, key, 'intent', parent);
    const child = spawn(process.execPath, [script, ...(attached ? ['--attached', process.execPath, '-e', business] : [])], {
      detached: true, env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
    const frames = [], raw = []; let pending = '', stderrBytes = 0;
    child.stdout.on('data', chunk => {
      raw.push(chunk);
      if (!attached) {
        pending += chunk.toString('utf8');
        for (;;) { const end = pending.indexOf('\n'); if (end < 0) break;
          frames.push(JSON.parse(pending.slice(0, end))); pending = pending.slice(end + 1); }
      }
    });
    child.stderr.on('data', chunk => { stderrBytes += chunk.length; });
    const exited = new Promise(resolve => child.once('close', code => resolve(code)));
    let owner = 0, formalPassed = false;
    try {
      assert(await until(() => spawnedPid(directory, key) === child.pid));
      birth(directory, key, child.pid, 0);
      if (!attached) {
        assert(await until(() => frames.some(frame => frame.type === 'broker.hello')));
        child.stdin.write(JSON.stringify({ type: 'owner.start', ownerId: 'dyld-owner', requestId: 'dyld-start',
          command: process.execPath, args: ['-e', business], env: expected }) + '\n');
      }
      assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0));
      owner = spawnedPid(directory, `${key}-o-1`);
      assert(!existsSync(receipt), 'business must remain behind ownership ACK');
      birth(directory, `${key}-o-1`, owner, owner);
      if (!attached) {
        assert(await until(() => frames.some(frame => frame.type === 'owner.started')));
        child.stdin.write(JSON.stringify({ type: 'owner.recovery-commit', ownerId: 'dyld-owner', ownerIncarnation: 'dyld-start' }) + '\n');
        assert(await until(() => frames.some(frame => frame.type === 'owner.exit')));
        assert.equal(frames.find(frame => frame.type === 'owner.exit').exitCode, 7);
        assert.equal(frames.filter(frame => frame.type === 'owner.stdout').map(frame => frame.text).join(''), '中文😀');
        child.stdin.end();
      }
      assert.equal(await exited, attached ? 7 : 0);
      assert.deepEqual(JSON.parse(readFileSync(receipt, 'utf8')), { exact: true, absent: true, shadows: true });
      assert(!existsSync(sentinel)); assert.equal(stderrBytes, 0);
      if (attached) assert.deepEqual(Buffer.concat(raw), Buffer.from('中文😀'));
      assert(!groupPresent(owner)); assert(!pidPresent(child.pid));
      assert(existsSync(join(directory, `${key}.terminal`)));
      formalPassed = true;
    } finally {
      if (!formalPassed) console.log(`node_dyld_formal attached=${attached} receipt=${existsSync(receipt)} sentinel=${existsSync(sentinel)} helperAlive=${pidPresent(child.pid)} ownerAlive=${owner ? groupPresent(owner) : false}`);
      if (child.exitCode === null && child.signalCode === null) { child.kill('SIGTERM'); await exited; }
      if (formalPassed) rmSync(home, { recursive: true, force: true });
    }
  }
});

test('R-S1-U1 immutable source facts refuse replacement and preserve non-payload ownership', () => {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-facts-'));
  try {
    publishRecoveryFact(directory, 'b-test', 'intent', parent);
    publishRecoveryFact(directory, 'b-test', 'intent', parent);
    assert.throws(() => publishRecoveryFact(directory, '../unsafe', 'intent', parent));
    assert.throws(() => publishRecoveryFact(directory, 'b-test', 'intent', parent, 42));
    mkdirSync(join(directory, 'target'));
    symlinkSync(join(directory, 'target'), join(directory, 'linked'));
    assert.throws(() => publishRecoveryFact(join(directory, 'linked'), 'b-test', 'intent', parent));
    assert.equal(readdirSync(join(directory, 'target')).length, 0);
    writeFileSync(join(directory, 'not-directory'), 'fixture');
    assert.throws(() => publishRecoveryFact(join(directory, 'not-directory'), 'b-test', 'terminal', parent, 2, 0));
    const text = readFileSync(join(directory, 'b-test.intent'), 'utf8');
    assert(!text.includes('token')); assert(!text.includes('argv')); assert(!text.includes('payload'));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('R-S1-C1 10000 completions compact with an active gap and reject invalid ranges', () => {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-ranges-'));
  try {
    let ranges = [];
    for (let sequence = 2; sequence <= 10001; sequence += 1) ranges = mergeClosedSequence(ranges, sequence);
    assert.deepEqual(ranges, [[2, 10001]]);
    publishClosedCheckpoint(directory, 'b-test', parent, 10001, ranges);
    assert.equal(readdirSync(directory).length, 1);
    assert(readFileSync(join(directory, 'b-test.closed'), 'utf8').includes('ranges:2-10001'));
    ranges = mergeClosedSequence(ranges, 1);
    assert.deepEqual(ranges, [[1, 10001]]);
    publishClosedCheckpoint(directory, 'b-test', parent, 10001, ranges);
    assert.throws(() => publishClosedCheckpoint(directory, 'b-test', parent, 5, [[1, 6]]));
    assert.throws(() => publishClosedCheckpoint(directory, 'b-test', parent, 5, [[2, 4], [3, 5]]));
    assert.throws(() => publishClosedCheckpoint(directory, 'b-test', parent, Number.MAX_SAFE_INTEGER + 1, [[1, 2]]));
    assert.throws(() => publishClosedCheckpoint(directory, 'b-test', parent, 5, [[3, 4], [1, 2]]));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('R-S1-P1 attached helper preserves raw binary/Chinese output and emits no frames', async () => {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-attached-'));
  const key = 'b-attached';
  publishRecoveryFact(directory, key, 'intent', parent);
  const expected = Buffer.concat([Buffer.from('中文😀\n'), Buffer.from([0xff, 0, 0xfe, 0x80])]);
  const child = spawn(process.execPath, [script, '--attached', process.execPath, '-e',
    'process.stdout.write(Buffer.concat([Buffer.from("中文😀\\n"),Buffer.from([255,0,254,128])]));process.exitCode=7'], {
    env: { ...process.env, METIS_PROCESS_RECOVERY_DIRECTORY: directory, METIS_PROCESS_RECOVERY_PARENT: parent,
      METIS_PROCESS_RECOVERY_BROKER_KEY: key }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdout = [], stderr = [];
  child.stdout.on('data', (chunk) => stdout.push(chunk)); child.stderr.on('data', (chunk) => stderr.push(chunk));
  const exited = new Promise((resolve) => child.once('close', (code) => resolve(code)));
  try {
    assert(await until(() => spawnedPid(directory, key) > 0));
    birth(directory, key, child.pid, 0);
    assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0));
    const pid = spawnedPid(directory, `${key}-o-1`);
    assert.equal(stdout.length, 0, 'business must remain gated before its birth is committed');
    birth(directory, `${key}-o-1`, pid, pid);
    assert.equal(await exited, 7);
    assert.deepEqual(Buffer.concat(stdout), expected);
    assert.equal(Buffer.concat(stderr).length, 0);
    assert(existsSync(join(directory, `${key}.terminal`)));
    assert(existsSync(join(directory, `${key}.closed`)));
    assert(readdirSync(directory).length <= 6);
  } finally {
    if (child.exitCode === null && child.signalCode === null) { child.kill('SIGTERM'); await exited; }
    rmSync(directory, { recursive: true, force: true });
  }
});

test('R-S1-N1 malformed UTF8 birth never opens attached business gate', async () => {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-bad-birth-'));
  const key = 'b-bad-birth';
  const marker = join(directory, 'business-marker');
  publishRecoveryFact(directory, key, 'intent', parent);
  const child = spawn(process.execPath, [script, '--attached', process.execPath, '-e',
    `require('fs').writeFileSync(${JSON.stringify(marker)},'unexpected')`], {
    env: { ...process.env, METIS_PROCESS_RECOVERY_DIRECTORY: directory, METIS_PROCESS_RECOVERY_PARENT: parent,
      METIS_PROCESS_RECOVERY_BROKER_KEY: key }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdout = [];
  child.stdout.on('data', (chunk) => stdout.push(chunk)); child.stderr.resume();
  const exited = new Promise((resolve) => child.once('close', resolve));
  try {
    assert(await until(() => spawnedPid(directory, key) > 0));
    birth(directory, key, child.pid, 0);
    assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0));
    const pid = spawnedPid(directory, `${key}-o-1`);
    const path = join(directory, `${key}-o-1.birth`);
    const invalid = `managed-recovery-v1\nkey:${key}-o-1\nphase:birth\nparent:${parent}\npid:${pid}\npgid:${pid}\nbirth:${pid}:1:0\n`;
    writeFileSync(path, Buffer.concat([Buffer.from(invalid), Buffer.from([0xff])]));
    await pause(100);
    assert(!existsSync(marker)); assert.equal(Buffer.concat(stdout).length, 0);
    for (const malformedBirth of [`${pid}:9007199254740992:0`, `${pid}:1:00`, `${pid}:1:1000000`]) {
      writeFileSync(path, invalid.replace(`${pid}:1:0`, malformedBirth));
      await pause(50);
      assert(!existsSync(marker)); assert.equal(Buffer.concat(stdout).length, 0);
    }
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await exited;
    rmSync(directory, { recursive: true, force: true });
  }
});

async function sourceOwnerCycles(total, { fake = false, holdGap = false } = {}) {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-cycles-'));
  const variables = ['METIS_PROCESS_RECOVERY_DIRECTORY', 'METIS_PROCESS_RECOVERY_PARENT', 'METIS_PROCESS_RECOVERY_BROKER_KEY'];
  const previous = variables.map((name) => process.env[name]);
  process.env[variables[0]] = directory; process.env[variables[1]] = parent; process.env[variables[2]] = 'b-cycles';
  publishRecoveryFact(directory, 'b-cycles', 'intent', parent);
  const pending = new Map(), texts = new Map(), children = new Map();
  let broker, closeResolve, heldGapChild, nextPid = 5000000;
  let closeObserved = false, closeCode, formal = false, bodyFailure;
  const closed = new Promise((resolve) => { closeResolve = (code) => { closeObserved = true; closeCode = code; resolve(code); }; });
  const bounded = async (promise, complete) => {
    await Promise.race([promise, until(complete).then((done) => assert(done, 'source_cycles_wait_timeout'))]);
    return promise;
  };
  const output = new Writable({ write(chunk, _encoding, done) {
    const frame = JSON.parse(String(chunk));
    if (frame.type === 'owner.started') {
      birth(directory, frame.recoveryKey, frame.pid, frame.pgid);
      broker.handle({ type: 'owner.recovery-commit', ownerId: frame.ownerId, ownerIncarnation: frame.requestId });
    }
    if (frame.type === 'owner.stdout') texts.set(frame.ownerId, (texts.get(frame.ownerId) ?? '') + frame.text);
    if (['owner.exit', 'owner.error', 'owner.timeout'].includes(frame.type)) {
      pending.get(frame.ownerId)?.(frame); pending.delete(frame.ownerId);
    }
    done();
  }});
  const fakeSpawn = (command) => {
    const child = new EventEmitter();
    child.pid = ++nextPid; child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    const native = command.endsWith('/metis-exec-gate-v1');
    if (holdGap && heldGapChild === undefined) heldGapChild = child;
    const admit = () => { if (child !== heldGapChild) queueMicrotask(child.finish); };
    const channel = native ? new Duplex({ read() {}, write(bytes, _encoding, done) {
      assert.equal(bytes.toString('ascii'), 'METIS-EXEC-ACK:1:11111111111111111111111111111111\n');
      admit(); done();
    } }) : new PassThrough();
    child.stdio = [child.stdin, child.stdout, child.stderr, channel]; child.closed = false;
    child.finish = () => {
      if (child.closed) return;
      child.closed = true; child.stdout.write('中文😀'); child.stdout.end(); child.stderr.end();
      if (native) channel.push(null);
      setImmediate(() => { child.emit('close', 0, null); children.delete(child.pid); });
    };
    child.kill = () => { child.finish(); return true; };
    if (!native) channel.once('data', admit);
    children.set(child.pid, child);
    queueMicrotask(() => {
      child.emit('spawn');
      if (native) channel.push('METIS-EXEC-GATE:1:11111111111111111111111111111111\n');
    });
    return child;
  };
  try {
    broker = new StdioBroker({ output, exit: (code) => closeResolve(code),
      ...(fake ? { spawnFn: fakeSpawn, treeRunner: { alive: (pid) => !children.get(pid)?.closed,
        terminate: (pid) => children.get(pid)?.finish() } } : {}) });
    birth(directory, 'b-cycles', process.pid, 0);
    const start = (sequence) => {
      const ownerId = `cycle-${sequence}`;
      const ended = new Promise((resolve) => pending.set(ownerId, resolve));
      broker.startOwner({ type: 'owner.start', ownerId, requestId: `start-${sequence}`,
        command: fake ? '/fixture/true' : process.execPath, args: fake ? [] : ['-e', 'process.stdout.write("中文😀")'] });
      return ended;
    };
    let held;
    if (holdGap) { held = start(0); assert(await until(() => children.size === 1)); }
    for (let sequence = 1; sequence <= total; sequence += 1) {
      const ended = await bounded(start(sequence), () => !pending.has(`cycle-${sequence}`));
      assert.equal(ended.type, 'owner.exit'); assert.equal(ended.exitCode, 0);
      assert.equal(texts.get(`cycle-${sequence}`), '中文😀');
      texts.delete(`cycle-${sequence}`);
    }
    assert(readdirSync(directory).length <= (holdGap ? 10 : 6));
    if (holdGap) {
      assert(readFileSync(join(directory, 'b-cycles.closed'), 'utf8').includes(`ranges:2-${total + 1}`));
      assert(heldGapChild && children.get(heldGapChild.pid) === heldGapChild && !heldGapChild.closed);
      assert(pending.has('cycle-0'));
      heldGapChild.finish();
      const ended = await bounded(held, () => !pending.has('cycle-0'));
      assert.equal(ended.type, 'owner.exit'); assert.equal(ended.exitCode, 0);
      assert.equal(texts.get('cycle-0'), '中文😀'); texts.delete('cycle-0');
    }
    broker.closeBroker(); assert.equal(await bounded(closed, () => closeObserved), 0);
    assert.equal(broker.owners.size, 0);
    assert(readdirSync(directory).length <= 6);
    assert.equal(pending.size, 0);
    if (fake) assert.equal(children.size, 0);
    if (holdGap) assert(readFileSync(join(directory, 'b-cycles.closed'), 'utf8').includes(`ranges:1-${total + 1}`));
    formal = true;
    return { count: total, files: readdirSync(directory).length };
  } catch (error) { bodyFailure = error; throw error; }
  finally {
    let cleanupFailure, terminal = false;
    try {
      if (broker && !closeObserved) { broker.closeBroker(); await bounded(closed, () => closeObserved); }
      terminal = Boolean(broker && closeObserved && closeCode === 0 && broker.owners.size === 0 &&
        pending.size === 0 && (!fake || children.size === 0));
      assert(terminal, 'source_cycles_cleanup_pending');
    } catch (error) { cleanupFailure = error; }
    finally {
      try {
        if (!formal || !terminal || cleanupFailure) {
          writeFileSync(join(directory, 'cleanup-result.json'), JSON.stringify({ formal, terminal,
            bodyFailed: Boolean(bodyFailure), cleanupFailed: Boolean(cleanupFailure),
            closeObserved, closeCode: closeCode ?? null, pending: pending.size,
            owners: broker?.owners.size ?? null, fakeChildren: children.size }));
        }
      } catch (error) { cleanupFailure ??= error; }
      finally {
        for (let index = 0; index < variables.length; index += 1) {
          if (previous[index] === undefined) delete process.env[variables[index]]; else process.env[variables[index]] = previous[index];
        }
      }
    }
    if (formal && terminal && !bodyFailure && !cleanupFailure) rmSync(directory, { recursive: true, force: true });
    if (!bodyFailure && cleanupFailure) throw cleanupFailure;
  }
}

test('R-S1-P1 100 real gated owners return terminal and bounded source records', async () => {
  const result = await sourceOwnerCycles(100);
  assert.equal(result.count, 100);
});

test('R-S1-C1 10000 source lifecycle closures retain a live gap without evidence growth', async () => {
  // Real journal/publisher/owner-state path; OS spawn/group probes are fixture doubles.
  const result = await sourceOwnerCycles(10000, { fake: true, holdGap: true });
  assert.equal(result.count, 10000);
});

function pidPresent(pid) { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; if (error.code === 'EPERM') return true; throw error; } }
function groupPresent(pid) { try { process.kill(-pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; if (error.code === 'EPERM') return true; throw error; } }

test('R-S1-B2 nested outer group kill must not outrun the attached helper tree reap', async () => {
  const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-nested-group-'));
  const key = 'b-nested-group';
  publishRecoveryFact(directory, key, 'intent', parent);
  const business = join(directory, 'business');
  const grandchildCode = `process.on('SIGTERM',()=>{});setInterval(()=>{},1000)`;
  const ownerCode = `process.on('SIGTERM',()=>{});const c=require('child_process').spawn(process.execPath,['-e',${JSON.stringify(grandchildCode)}],{stdio:'ignore'});require('fs').writeFileSync(${JSON.stringify(business)},String(c.pid));setInterval(()=>{},1000)`;
  // Node detached models the production posix_spawn SETPGROUP applied before exec.
  // The Cangjie launcher has separate native getpgid/stdio coverage.
  const actorCode = `process.on('SIGTERM',()=>{});require('child_process').spawn(process.execPath,${JSON.stringify([script, '--attached', process.execPath, '-e', ownerCode])},{detached:true,stdio:'ignore',env:process.env});setInterval(()=>{},1000)`;
  const actor = spawn(process.execPath, ['-e', actorCode], { detached: true, stdio: 'ignore', env: { ...process.env,
    METIS_PROCESS_RECOVERY_DIRECTORY: directory, METIS_PROCESS_RECOVERY_PARENT: parent, METIS_PROCESS_RECOVERY_BROKER_KEY: key } });
  const exited = new Promise((resolve) => actor.once('close', resolve));
  let helper = 0, owner = 0, provedBeforeFallback = false;
  try {
    assert(await until(() => spawnedPid(directory, key) > 0)); helper = spawnedPid(directory, key);
    birth(directory, key, helper, 0);
    assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0)); owner = spawnedPid(directory, `${key}-o-1`);
    birth(directory, `${key}-o-1`, owner, owner);
    assert(await until(() => existsSync(business)));
    process.kill(-actor.pid, 'SIGTERM');
    await pause(250);
    if (groupPresent(actor.pid)) process.kill(-actor.pid, 'SIGKILL');
    await exited;
    provedBeforeFallback = await until(() => !pidPresent(helper) && !groupPresent(owner) && existsSync(join(directory, `${key}.terminal`)), 2000);
    assert(provedBeforeFallback, `nested cleanup left businessGroupActive=${groupPresent(owner)}; helperPresent=${pidPresent(helper)}; terminal=${existsSync(join(directory, `${key}.terminal`))}`);
  } finally {
    if (groupPresent(actor.pid)) process.kill(-actor.pid, 'SIGKILL');
    await exited;
    if (!provedBeforeFallback && owner && groupPresent(owner)) process.kill(-owner, 'SIGKILL');
    if (!provedBeforeFallback && helper && pidPresent(helper)) process.kill(helper, 'SIGTERM');
    await until(() => (!helper || !pidPresent(helper)) && (!owner || !groupPresent(owner)), 5000);
    rmSync(directory, { recursive: true, force: true });
  }
});

for (const barrier of ['helper-spawn', 'owner-spawn', 'business-gate']) {
  test(`R-S1-B1 parent SIGKILL at ${barrier} independently reaps owned groups`, async () => {
    const home = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-parentkill-'));
    const directory = join(home, 'inventory'); mkdirSync(directory);
    const diagnostics = join(home, 'diagnostics'); mkdirSync(diagnostics);
    const evidence = join(home, 'evidence'); mkdirSync(evidence);
    const key = 'b-parentkill';
    publishRecoveryFact(directory, key, 'intent', parent);
    const business = join(directory, 'business');
    const ownerCode = `const c=require('child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});require('fs').writeFileSync(${JSON.stringify(business)},String(c.pid));setInterval(()=>{},1000)`;
    const parentSource = `const c=require('child_process').spawn(process.execPath,${JSON.stringify([script, '--attached', process.execPath, '-e', ownerCode])},{stdio:'ignore',env:process.env});require('fs').writeFileSync(${JSON.stringify(join(directory, 'helper-pid'))},String(c.pid));setInterval(()=>{},1000)`;
    const actor = spawn(process.execPath, ['-e', parentSource], { env: { ...process.env,
      METIS_PROCESS_RECOVERY_DIRECTORY: directory, METIS_PROCESS_RECOVERY_PARENT: parent,
      METIS_PROCESS_RECOVERY_BROKER_KEY: key, METIS_STDIO_BROKER_TEST_MODE: '1',
      METIS_STDIO_BROKER_DIAGNOSTIC_MARKER: diagnostics }, stdio: 'ignore' });
    let actorCloseObserved = false;
    const actorClosed = new Promise((resolve) => actor.once('close', () => { actorCloseObserved = true; resolve(); }));
    let helperPid = 0, ownerPid = 0;
    let provedCleanBeforeFallback = false, formalPassed = false, beforeFallbackSaved = false;
    let failed = false, failure;
    const snapshot = (phase) => {
      const sources = {};
      for (const sourceKey of [key, `${key}-o-1`]) {
        for (const fact of ['intent', 'spawned', 'birth', 'terminal', 'not_spawned', 'exec_error', 'closed']) {
          const name = `${sourceKey}.${fact}`;
          sources[name] = existsSync(join(directory, name));
          if (sources[name]) {
            const bytes = readFileSync(join(directory, name));
            assert(bytes.length <= 1024 * 1024, 'fixture_source_too_large');
            writeFileSync(join(evidence, `${phase}-${name}`), bytes, { mode: 0o600 });
          }
        }
      }
      const header = readFileSync(join(directory, 'inventory'));
      writeFileSync(join(evidence, `${phase}-inventory`), header, { mode: 0o600 });
      const marker = join(diagnostics, `broker-g1-p${helperPid}.json`);
      const markerPresent = helperPid > 0 && existsSync(marker);
      if (markerPresent) {
        const bytes = readFileSync(marker);
        assert(bytes.length <= 1024 * 1024, 'fixture_diagnostic_too_large');
        writeFileSync(join(evidence, `${phase}-broker.json`), bytes, { mode: 0o600 });
      }
      const flags = { barrier, phase, helperPid, ownerPid,
        actorClosed: actorCloseObserved,
        helperPresent: helperPid > 0 ? pidPresent(helperPid) : null,
        ownerPresent: ownerPid > 0 ? pidPresent(ownerPid) : null,
        ownerGroupPresent: ownerPid > 0 ? groupPresent(ownerPid) : null,
        businessPresent: existsSync(business), sources, markerPresent,
        recoveryPersistenceFailed: 'NOT_OBSERVED', outcomeWriteFailed: 'NOT_OBSERVED',
        provedCleanBeforeFallback };
      writeFileSync(join(evidence, `${phase}-flags.json`), `${JSON.stringify(flags)}\n`, { mode: 0o600 });
    };
    try {
      assert(await until(() => spawnedPid(directory, key) > 0)); helperPid = spawnedPid(directory, key);
      if (barrier !== 'helper-spawn') {
        birth(directory, key, helperPid, 0);
        assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0)); ownerPid = spawnedPid(directory, `${key}-o-1`);
      }
      if (barrier === 'business-gate') { birth(directory, `${key}-o-1`, ownerPid, ownerPid); assert(await until(() => existsSync(business))); }
      else assert(!existsSync(business));
      snapshot('barrier');
      actor.kill('SIGKILL'); await actorClosed;
      provedCleanBeforeFallback = await until(() => {
        if (existsSync(join(directory, `${key}.terminal`)) && ownerPid > 0) assert(!groupPresent(ownerPid), 'source terminal must follow actual group disappearance');
        return !pidPresent(helperPid) && (ownerPid === 0 || !groupPresent(ownerPid)) && existsSync(join(directory, `${key}.terminal`));
      }, 10000);
      snapshot('before-fallback'); beforeFallbackSaved = true;
      assert(provedCleanBeforeFallback);
      assert(!pidPresent(helperPid)); if (ownerPid) assert(!groupPresent(ownerPid));
      formalPassed = true;
    } catch (error) {
      failed = true; failure = error;
    } finally {
      // A failed diagnostic must not skip actual returned-actor cleanup or mask the main error.
      const cleanupStep = async (action) => {
        try { await action(); } catch (error) { if (!failed) { failed = true; failure = error; } }
      };
      if (!beforeFallbackSaved) await cleanupStep(async () => {
        snapshot('before-fallback'); beforeFallbackSaved = true;
      });
      await cleanupStep(async () => {
        if (actor.exitCode === null && actor.signalCode === null) actor.kill('SIGKILL');
        await actorClosed;
      });
      // Fallback is excluded from the truth above and only touches this fixture's recorded group.
      await cleanupStep(async () => {
        if (!provedCleanBeforeFallback && helperPid && pidPresent(helperPid)) process.kill(helperPid, 'SIGTERM');
      });
      await cleanupStep(async () => {
        if (!provedCleanBeforeFallback && ownerPid && groupPresent(ownerPid)) process.kill(-ownerPid, 'SIGKILL');
      });
      let cleanupComplete = false;
      await cleanupStep(async () => {
        cleanupComplete = await until(() =>
          actorCloseObserved &&
          (!helperPid || !pidPresent(helperPid)) && (!ownerPid || !groupPresent(ownerPid)), 5000);
        assert(cleanupComplete, 'fixture_cleanup_pending');
        snapshot('after-fallback');
      });
      if (formalPassed && beforeFallbackSaved && cleanupComplete && !failed) {
        await cleanupStep(async () => rmSync(home, { recursive: true, force: true }));
      }
      if (!formalPassed || !beforeFallbackSaved || !cleanupComplete || failed) {
        // Only owned temporary basename and fixed fixture labels reach the runner output.
        try { console.error(`R-S1-B1 fixture=${home.split('/').pop()};barrier=${barrier};formal=${formalPassed};proof=${beforeFallbackSaved};cleanup=${cleanupComplete}`); } catch { /* main error retains priority */ }
      }
    }
    if (failed) throw failure;
  });
}


test('R-S1-U2 Node normal and attached metadata survives owned umask777', async () => {
  const parentMask = process.umask();
  const moduleUrl = new URL('./metis-stdio-broker.mjs', import.meta.url).href;
  for (const attached of [false, true]) {
    const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-node-mode-'));
    chmodSync(directory, 0o700);
    const key = attached ? 'b-umask-attached' : 'b-umask-normal';
    publishRecoveryFact(directory, key, 'intent', parent);
    const actor = `process.umask(0o777);import(${JSON.stringify(moduleUrl)}).then(m=>${attached
      ? `m.runAttachedBroker(process.execPath,${JSON.stringify(['-e', 'process.stdout.write("中文😀");process.exitCode=7'])})`
      : 'm.runBroker()'})`;
    const child = spawn(process.execPath, ['--input-type=commonjs', '-e', actor], {
      detached: true, env: { ...process.env, METIS_PROCESS_RECOVERY_DIRECTORY: directory,
        METIS_PROCESS_RECOVERY_PARENT: parent, METIS_PROCESS_RECOVERY_BROKER_KEY: key },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const output = []; const frames = []; let pending = ''; let formalPassed = false;
    child.stderr.resume();
    child.stdout.on('data', chunk => {
      output.push(chunk);
      if (!attached) {
        pending += chunk.toString('utf8');
        for (;;) { const newline = pending.indexOf('\n'); if (newline < 0) break;
          frames.push(JSON.parse(pending.slice(0, newline))); pending = pending.slice(newline + 1); }
      }
    });
    const exited = new Promise(resolve => child.once('close', code => resolve(code)));
    const checkFiles = () => {
      for (const file of readdirSync(directory)) {
        assert.equal(statSync(join(directory, file)).mode & 0o777, 0o600);
        assert(readFileSync(join(directory, file)).length > 0);
      }
    };
    try {
      assert(await until(() => spawnedPid(directory, key) === child.pid));
      birth(directory, key, child.pid, 0);
      checkFiles();
      if (!attached) {
        assert(await until(() => frames.some(f => f.type === 'broker.hello')));
        child.stdin.write(JSON.stringify({ type: 'owner.start', ownerId: 'umask-owner', requestId: 'umask-start',
          command: process.execPath, args: ['-e', 'process.stdout.write("中文😀")'] }) + '\n');
      }
      assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0));
      const ownerPid = spawnedPid(directory, `${key}-o-1`);
      birth(directory, `${key}-o-1`, ownerPid, ownerPid);
      checkFiles();
      if (!attached) {
        assert(await until(() => frames.some(f => f.type === 'owner.started')));
        child.stdin.write(JSON.stringify({ type: 'owner.recovery-commit', ownerId: 'umask-owner', ownerIncarnation: 'umask-start' }) + '\n');
        assert(await until(() => frames.some(f => f.type === 'owner.exit')));
        child.stdin.end();
      }
      assert.equal(await exited, attached ? 7 : 0);
      if (attached) assert.deepEqual(Buffer.concat(output), Buffer.from('中文😀'));
      assert(existsSync(join(directory, `${key}.terminal`)));
      assert(existsSync(join(directory, `${key}.closed`)));
      checkFiles();
      assert.throws(() => process.kill(ownerPid, 0), { code: 'ESRCH' });
      formalPassed = true;
    } finally {
      if (!formalPassed) {
        const allowed = new Set(['spawn_failed', 'recovery_write_failed', 'invalid_owner_spec', 'malformed_json',
          'invalid_response_encoding', 'recovery_gate_failed', 'recovery_record_invalid']);
        const frameSummary = frames.map(frame => `${String(frame.type).replace(/[^a-z.-]/gu, '')}:${allowed.has(frame.status) ? frame.status : 'other'}`).join(',');
        const files = readdirSync(directory);
        console.log(`node_umask_formal attached=${attached} helperAlive=${pidPresent(child.pid)} intentCount=${files.filter(name => name.endsWith('.intent')).length} spawnedCount=${files.filter(name => name.endsWith('.spawned')).length} terminalCount=${files.filter(name => name.endsWith('.terminal')).length} frames=${frameSummary}`);
      }
      if (child.exitCode === null && child.signalCode === null) { child.kill('SIGTERM'); await exited; }
      if (formalPassed) rmSync(directory, { recursive: true, force: true });
    }
  }
  assert.equal(process.umask(), parentMask);
});


for (const descriptor of [0, 1]) {
  test(`R-S1-P1 attached business closes fd${descriptor} while alive without helper retaining it`, async () => {
    const directory = mkdtempSync(join(realpathSync(tmpdir()), 'metis-recovery-raw-eof-'));
    const key = `b-raw-close-${descriptor}`;
    const ready = join(directory, 'business-ready');
    publishRecoveryFact(directory, key, 'intent', parent);
    const code = `const fs=require('fs');fs.closeSync(${descriptor});fs.writeFileSync(${JSON.stringify(ready)},String(process.pid));setInterval(()=>{},1000)`;
    const child = spawn(process.execPath, [script, '--attached', process.execPath, '-e', code], {
      detached: true, env: { ...process.env, METIS_PROCESS_RECOVERY_DIRECTORY: directory,
        METIS_PROCESS_RECOVERY_PARENT: parent, METIS_PROCESS_RECOVERY_BROKER_KEY: key },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdoutEnded = false;
    child.stdout.on('end', () => { stdoutEnded = true; }); child.stdout.resume(); child.stderr.resume();
    child.stdin.on('error', () => {});
    const exited = new Promise(resolve => child.once('close', code => resolve(code)));
    let owner = 0, terminal = false;
    try {
      assert(await until(() => spawnedPid(directory, key) === child.pid));
      birth(directory, key, child.pid, 0);
      assert(await until(() => spawnedPid(directory, `${key}-o-1`) > 0));
      owner = spawnedPid(directory, `${key}-o-1`);
      birth(directory, `${key}-o-1`, owner, owner);
      assert(await until(() => existsSync(ready)));
      assert(pidPresent(owner)); assert(pidPresent(child.pid));
      if (descriptor === 1) {
        assert(await until(() => stdoutEnded), 'host must receive stdout EOF before business exit');
      } else {
        const writeError = await new Promise(resolve => child.stdin.write(Buffer.from('owned-input'), error => resolve(error)));
        assert.equal(writeError?.code, 'EPIPE', 'host must observe closed business stdin while business remains alive');
      }
      assert(pidPresent(owner)); assert(pidPresent(child.pid));
      child.kill('SIGTERM');
      assert(await until(() => child.exitCode !== null || child.signalCode !== null));
      await exited;
      terminal = await until(() => !groupPresent(owner) && existsSync(join(directory, `${key}.terminal`)));
      assert(terminal, 'source terminal must follow actual business group disappearance');
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
      const settled = await until(() => !pidPresent(child.pid) && (!owner || !groupPresent(owner)), 10000);
      if (settled) { await exited; rmSync(directory, { recursive: true, force: true }); }
      assert(settled, 'owned helper cleanup must settle; retain evidence on failure');
    }
  });
}


// This exercises the historical test wrapper, not a second broker implementation.
// Birth files below reuse this suite's explicitly algorithm-only birth() helper;
// actual OS identity verification remains the Cangjie formal cases' responsibility.
async function historicalWrapperMode(mode, businessExit = 0) {
  const home = mkdtempSync(join(realpathSync(tmpdir()), 'metis-hr-broker-mode-'));
  const nonce = `${process.pid}-${Date.now()}-${home.split('/').at(-1)}`;
  const directory = join(home, 'inventory'), key = 'b-historical-mode';
  const wrapper = fileURLToPath(new URL('./gateway-historical-recovery-broker-nonzero.mjs', import.meta.url));
  const marker = join(home, 'business-marker');
  writeFileSync(join(home, 'test-owned'), `historical-broker-mode-v1\n${nonce}\n`);
  const bound = mode === 'bound-framed' || mode === 'attached';
  const attached = mode === 'attached' || mode === 'unbound-attached';
  const expectedOut = Buffer.concat([Buffer.from('中文😀\n'.repeat(8192)), Buffer.from([0, 255, 195, 40])]);
  const expectedErr = Buffer.concat([Buffer.from('错误中文🙂\n'.repeat(8192)), Buffer.from([0, 254, 128])]);
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) {
    const upper = name.toUpperCase();
    if (name.startsWith('METIS_PROCESS_RECOVERY_') || upper.includes('TOKEN') || upper.includes('CREDENTIAL') ||
        upper.includes('PROXY') || upper.endsWith('_API_KEY') || upper.endsWith('_ACCESS_KEY_ID') ||
        ['NODE_OPTIONS', 'NODE_PATH', 'BASH_ENV', 'ENV'].includes(name)) delete environment[name];
  }
  environment.METIS_HR_REAL_BROKER = script;
  if (bound) {
    mkdirSync(directory);
    publishRecoveryFact(directory, key, 'intent', parent);
    Object.assign(environment, { METIS_PROCESS_RECOVERY_DIRECTORY: directory,
      METIS_PROCESS_RECOVERY_PARENT: parent, METIS_PROCESS_RECOVERY_BROKER_KEY: key });
  }
  const business = 'const fs=require("fs");fs.writeFileSync(process.argv[1],String(process.pid));' +
    'process.stdout.write(Buffer.concat([Buffer.from("中文😀\\n".repeat(8192)),Buffer.from([0,255,195,40])]));' +
    'process.stderr.write(Buffer.concat([Buffer.from("错误中文🙂\\n".repeat(8192)),Buffer.from([0,254,128])]));' +
    `process.exitCode=${businessExit};`;
  let child, owner = 0, launchPending = false, observedClose = false, code = null, signal = null;
  let formal = false, proofSaved = false, bodyFailure;
  const stdout = [], stderr = [], frames = [];
  let pending = Buffer.alloc(0), protocolError = '';
  const deadline = Date.now() + 5000;
  const wait = async predicate => {
    const remaining = deadline - Date.now();
    return remaining > 0 && await until(predicate, remaining);
  };
  try {
    launchPending = true;
    child = spawn(process.execPath, [wrapper, ...(attached ? ['--attached', process.execPath, '-e', business, marker] : [])], {
      detached: true, env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
    launchPending = false;
    child.once('error', () => { protocolError = 'wrapper_spawn_failed'; });
    child.once('close', (exit, stoppedSignal) => { code = exit; signal = stoppedSignal; observedClose = true; });
    child.stdin.on('error', () => {});
    child.stdout.on('data', chunk => {
      stdout.push(chunk);
      if (attached) return;
      pending = Buffer.concat([pending, chunk]);
      for (;;) {
        const newline = pending.indexOf(10);
        if (newline < 0) break;
        const line = pending.subarray(0, newline); pending = pending.subarray(newline + 1);
        try { frames.push(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line))); }
        catch { protocolError = 'wrapper_frame_invalid'; }
      }
    });
    child.stderr.on('data', chunk => { stderr.push(chunk); });
    if (bound) {
      assert(await wait(() => spawnedPid(directory, key) === child.pid), 'wrapper_spawn_not_observed');
      birth(directory, key, child.pid, 0);
    }
    if (!attached) {
      assert(await wait(() => frames.some(frame => frame.type === 'broker.hello')), 'wrapper_hello_missing');
      child.stdin.end();
    } else if (bound) {
      assert(await wait(() => spawnedPid(directory, `${key}-o-1`) > 0), 'wrapper_owner_not_observed');
      owner = spawnedPid(directory, `${key}-o-1`);
      assert(!existsSync(marker), 'wrapper_business_before_ack');
      birth(directory, `${key}-o-1`, owner, owner);
    }
    assert(await wait(() => observedClose), 'wrapper_close_timeout');
    assert.equal(protocolError, ''); assert.equal(signal, null);
    assert.equal(code, mode === 'bound-framed' ? 70 : mode === 'unbound-attached' ? 64 : attached ? businessExit : 0);
    if (!attached) {
      assert.equal(frames.filter(frame => frame.type === 'broker.hello').length, 1);
      assert.equal(frames.filter(frame => frame.type === 'broker.closed').length, 1);
      assert.equal(frames.find(frame => frame.type === 'broker.hello').pid, child.pid);
      assert.equal(frames.find(frame => frame.type === 'broker.closed').ownerCount, 0);
      assert.equal(pending.length, 0); assert.equal(Buffer.concat(stderr).length, 0);
      assert(!existsSync(marker));
    } else if (bound) {
      assert.deepEqual(Buffer.concat(stdout), expectedOut);
      assert.deepEqual(Buffer.concat(stderr), expectedErr);
      assert.equal(Number(readFileSync(marker, 'utf8')), owner);
      assert(!groupPresent(owner));
    } else {
      assert.equal(Buffer.concat(stdout).length, 0);
      assert.equal(Buffer.concat(stderr).toString('utf8'), 'historical broker fixture initialization failed\n');
      assert(!existsSync(marker)); assert(!existsSync(directory));
    }
    if (bound) assert(existsSync(join(directory, `${key}.terminal`)), 'wrapper_terminal_missing');
    assert(!pidPresent(child.pid)); assert(!groupPresent(child.pid));
    assert(Date.now() <= deadline, 'wrapper_body_deadline_exceeded');
    formal = true;
  } catch (error) { bodyFailure = error; }
  finally {
    try {
      writeFileSync(join(home, 'stdout.bin'), Buffer.concat(stdout));
      writeFileSync(join(home, 'stderr.bin'), Buffer.concat(stderr));
      writeFileSync(join(home, 'formal-before-fallback.json'), JSON.stringify({ nonce, mode, businessExit,
        formal, bodyFailure: Boolean(bodyFailure), launchPending, observedClose, helperPid: child?.pid ?? 0,
        ownerPid: owner, code, signal, algorithmBirthOnly: true }) + '\n');
      proofSaved = true;
    } catch (error) { bodyFailure ??= error; }
    finally {
      const cleanupDeadline = Date.now() + 5000;
      try {
        if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
      } catch (error) { bodyFailure ??= error; }
      try {
        const remaining = cleanupDeadline - Date.now();
        assert(remaining > 0 && await until(() => !launchPending && observedClose && Boolean(child?.pid) &&
          !pidPresent(child.pid) && !groupPresent(child.pid) && (!owner || !groupPresent(owner)), remaining),
          'wrapper_cleanup_pending');
        assert(Date.now() <= cleanupDeadline, 'wrapper_cleanup_deadline_exceeded');
      } catch (error) { bodyFailure ??= error; }
      // Never erase a failed input or let fallback supply formal truth.
      console.log(`historical_wrapper_registry=${home.split('/').at(-1)};mode=${mode};formal=${formal};proofSaved=${proofSaved}`);
    }
  }
  if (bodyFailure) throw bodyFailure;
  assert(formal && proofSaved);
}

test('R-HR-FIXTURE-U1 unbound framed discovery preserves clean exit0', async () => {
  await historicalWrapperMode('unbound-framed');
});
test('R-HR-FIXTURE-B1 fully bound framed close injects actual exit70', { skip: process.platform !== 'darwin' }, async () => {
  await historicalWrapperMode('bound-framed');
});
test('R-HR-FIXTURE-P1 attached wrapper preserves raw bytes and genuine exit0 7 127', { skip: process.platform !== 'darwin' }, async () => {
  for (const code of [0, 7, 127]) await historicalWrapperMode('attached', code);
});
test('R-HR-FIXTURE-N1 attached without recovery context cannot run business', async () => {
  await historicalWrapperMode('unbound-attached');
});
