import test from 'node:test';
import { EventEmitter } from 'node:events';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { constants as osConstants, tmpdir } from 'node:os';
import { syncBuiltinESMExports } from 'node:module';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Writable } from 'node:stream';
import { createHash } from 'node:crypto';

const project = dirname(dirname(fileURLToPath(import.meta.url)));
const parent = '1:99999:0:0:0:0:0:99999:0:1:1:0';
const binding = 'native-outcome-fixture-中文😀';
let suiteHome;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(condition, millis = 5000) {
  const deadline = Date.now() + millis;
  while (Date.now() < deadline) { if (condition()) return true; await pause(5); }
  return condition();
}
function groupGone(pid) {
  try { process.kill(-pid, 0); return false; }
  catch (error) { return error?.code === 'ESRCH'; }
}
function source(directory, key, phase, pid = 0, pgid = 0) {
  // Algorithm-only helper birth: actual native identities are the Cj matrix's responsibility.
  return `managed-recovery-v1
key:${key}
phase:${phase}
parent:${parent}
pid:${pid}
pgid:${pgid}
birth:${phase === 'birth' ? `${pid}:1:0` : ''}
`;
}
function writeBirth(directory, key, pid, pgid) {
  fs.writeFileSync(join(directory, `${key}.birth`), source(directory, key, 'birth', pid, pgid), { mode: 0o600 });
}
async function fixture() {
  const originalAsset = join(project, 'target/native/metis-exec-gate-v1');
  const assetInfo = fs.lstatSync(originalAsset);
  assert(assetInfo.isFile() && !assetInfo.isSymbolicLink() && (assetInfo.mode & 0o111) !== 0 && (assetInfo.mode & 0o022) === 0);
  for (const path of ['src/process/managed_exec_gate.c', 'build.cj']) assert(fs.statSync(join(project, path)).mtimeMs <= assetInfo.mtimeMs);
  if (!suiteHome) {
    suiteHome = fs.mkdtempSync(join(fs.realpathSync(tmpdir()), 'metis-native-outcome-suite-'));
    fs.writeFileSync(join(suiteHome, 'owner.json'), JSON.stringify({ schema: 'native-outcome-suite-v1', pid: process.pid,
      source: createHash('sha256').update(fs.readFileSync(fileURLToPath(import.meta.url))).digest('hex') }) + '\n');
    console.log(`native_outcome_registry=${basename(suiteHome)}`);
  }
  const home = fs.mkdtempSync(join(suiteHome, 'case-'));
  fs.appendFileSync(join(suiteHome, 'cases.jsonl'), JSON.stringify({ home: basename(home) }) + '\n');
  fs.writeFileSync(join(home, 'owner'), 'native-outcome-node-v1\n');
  for (const path of ['scripts', 'src/process', 'target/native']) fs.mkdirSync(join(home, path), { recursive: true });
  for (const path of ['scripts/metis-stdio-broker.mjs', 'src/process/managed_exec_gate.c', 'build.cj']) {
    fs.copyFileSync(join(project, path), join(home, path));
  }
  const asset = join(home, 'target/native/metis-exec-gate-v1');
  fs.copyFileSync(originalAsset, asset);
  const inputs = {};
  for (const path of ['scripts/metis-stdio-broker.mjs', 'src/process/managed_exec_gate.c', 'build.cj', 'target/native/metis-exec-gate-v1']) {
    inputs[path] = createHash('sha256').update(fs.readFileSync(join(project, path))).digest('hex');
  }
  fs.writeFileSync(join(home, 'inputs.json'), JSON.stringify(inputs) + '\n');
  fs.chmodSync(asset, 0o755);
  // Copy last so the fixture's source freshness proof uses actual filesystem times.
  const directory = join(home, 'inventory'); fs.mkdirSync(directory);
  fs.writeFileSync(join(directory, 'inventory'), `managed-recovery-v1
parent:${parent}
binding:${binding}
coverage:broker-v1
`, { mode: 0o600 });
  const key = 'r-1';
  for (const phase of ['intent', 'spawned', 'birth']) {
    fs.writeFileSync(join(directory, `${key}.${phase}`), source(directory, key, phase, phase === 'intent' ? 0 : process.pid, 0), { mode: 0o600 });
  }
  const { StdioBroker } = await import(pathToFileURL(join(home, 'scripts/metis-stdio-broker.mjs')).href);
  return { home, directory, key, asset, StdioBroker };
}
async function runOwner(mode, command, args = []) {
  const own = await fixture();
  if (mode === 'permission') {
    command = join(own.home, 'permission');
    fs.writeFileSync(command, 'exit 0\n', { mode: 0o600 });
  }
  const names = ['METIS_PROCESS_RECOVERY_DIRECTORY', 'METIS_PROCESS_RECOVERY_PARENT', 'METIS_PROCESS_RECOVERY_BROKER_KEY'];
  const previous = names.map(name => process.env[name]);
  names.forEach((name, i) => { process.env[name] = [own.directory, parent, own.key][i]; });
  let broker, held, terminalFrame, failure, proofSaved = false, injected = 0;
  const children = [], frames = [];
  const originalFsync = fs.fsyncSync, originalOpen = fs.openSync, originalUnlink = fs.unlinkSync;
  const descriptorPaths = new Map();
  let errorDeleted = false;
  const operations = [];
  if (['fsync', 'dirsync'].includes(mode)) {
    fs.openSync = (...parameters) => {
      const fd = originalOpen(...parameters);
      descriptorPaths.set(fd, String(parameters[0]));
      return fd;
    };
    fs.fsyncSync = fd => {
      if ((mode === 'fsync' && descriptorPaths.get(fd)?.endsWith('.exec_error')) ||
          (mode === 'dirsync' && errorDeleted && descriptorPaths.get(fd) === own.directory)) {
        operations.push('injected_sync_failure'); injected += 1;
        throw Object.assign(new Error('injected_fsync'), { code: 'EIO' });
      }
      return originalFsync(fd);
    };
    fs.unlinkSync = path => {
      if (String(path).endsWith('.exec_error')) { errorDeleted = true; operations.push('unlink_error'); }
      else operations.push('unlink_source');
      return originalUnlink(path);
    };
    syncBuiltinESMExports();
  }
  try {
    if (mode === 'version') {
      fs.writeFileSync(own.asset, '#!/bin/sh\nprintf "METIS-EXEC-GATE:9:00000000000000000000000000000000\\n" >&3\nIFS= read -r ack <&3\nexit 125\n');
      fs.chmodSync(own.asset, 0o755);
    }
    const output = new Writable({ write(chunk, _encoding, done) {
      const frame = JSON.parse(String(chunk)); frames.push(frame);
      if (frame.type === 'owner.started') {
        writeBirth(own.directory, frame.recoveryKey, frame.pid, frame.pgid);
        broker.handle({ type: 'owner.recovery-commit', ownerId: 'fixture', ownerIncarnation: 'start-1' });
      }
      if (['owner.exit', 'owner.error', 'owner.timeout'].includes(frame.type)) {
        terminalFrame = frame; held = done;
      } else done();
    }});
    broker = new own.StdioBroker({ output, exit: () => {}, spawnFn: (...parameters) => {
      if (mode === 'unlink') fs.unlinkSync(own.asset);
      if (mode === 'sync') throw new Error('synthetic_factory_throw');
      const child = spawn(...parameters);
      const observed = { child, spawned: false, closed: false, error: null, control: [], stdout: [], stderr: [] };
      child.stdio[3].on('data', bytes => observed.control.push(Buffer.from(bytes)));
      child.stdout.on('data', bytes => observed.stdout.push(Buffer.from(bytes)));
      child.stderr.on('data', bytes => observed.stderr.push(Buffer.from(bytes)));
      children.push(observed);
      child.once('spawn', () => { observed.spawned = true; });
      child.once('error', error => { observed.error = error; });
      child.once('close', () => { observed.closed = true; });
      if (mode === 'broken') child.stdio[3].destroy();
      return child;
    }});
    if (mode === 'asset-missing') fs.unlinkSync(own.asset);
    if (mode === 'asset-symlink') {
      fs.renameSync(own.asset, `${own.asset}.original`); fs.symlinkSync(`${own.asset}.original`, own.asset);
    }
    if (mode === 'asset-directory') { fs.unlinkSync(own.asset); fs.mkdirSync(own.asset); }
    if (mode === 'asset-writable') fs.chmodSync(own.asset, 0o777);
    if (mode === 'asset-stale') {
      const future = new Date(Date.now() + 5000); fs.utimesSync(join(own.home, 'src/process/managed_exec_gate.c'), future, future);
    }
    if (mode === 'path') fs.mkdirSync(join(own.directory, 'r-1-o-1.exec_error'));
    if (mode === 'existing') fs.writeFileSync(join(own.directory, 'r-1-o-1.exec_error'), 'partial-prior-publication');
    broker.startOwner({ type: 'owner.start', ownerId: 'fixture', requestId: 'start-1', command, args });
    assert(await until(() => terminalFrame));
    broker.closeBroker();
    if (mode === 'dirsync') {
      fs.copyFileSync(join(own.directory, 'r-1-o-1.exec_error'), join(own.home, 'exec-error-before-delete.bin'));
      held(); held = undefined;
      assert(await until(() => broker.recoveryPersistenceFailed));
    }
    const files = fs.readdirSync(own.directory);
    const path = join(own.directory, 'r-1-o-1.exec_error');
    const info = files.includes('r-1-o-1.exec_error') ? fs.lstatSync(path) : null;
    const bytes = info?.isFile() ? fs.readFileSync(path) : Buffer.alloc(0);
    const text = bytes.toString('utf8');
    const fact = Object.fromEntries(text.split('\n').slice(1).filter(Boolean).map(line => {
      const colon = line.indexOf(':'); return [line.slice(0, colon), line.slice(colon + 1)];
    }));
    const childClosed = children.every(child => child.closed);
    const groupsGone = children.every(({ child }) => child.pid === undefined || groupGone(child.pid));
    assert(childClosed && groupsGone);
    if (mode.startsWith('asset-')) {
      assert.equal(children.length, 0);
      assert.equal(broker.recoveryOwnerSequence, 0);
      assert.equal(broker.recoveryPersistenceFailed, false);
      assert(!files.some(name => name.startsWith('r-1-o-')));
      assert.equal(terminalFrame.type, 'owner.error');
    } else if (mode === 'sync') {
      assert.equal(children.length, 0);
      assert(broker.recoveryPersistenceFailed);
      assert(!files.includes('r-1.terminal'));
      assert(!files.includes('r-1-o-1.not_spawned'));
      assert(!files.includes('r-1.closed'));
    } else if (mode === 'dirsync') {
      assert.equal(terminalFrame.status, 'spawn_failed');
      assert(errorDeleted && injected > 0);
      assert.deepEqual(operations, ['unlink_error', 'injected_sync_failure']);
      assert(!files.includes('r-1-o-1.exec_error'));
      assert(files.includes('r-1-o-1.birth')); assert(files.includes('r-1-o-1.intent'));
      assert(!files.includes('r-1.terminal'));
    } else if (['fsync', 'path', 'existing'].includes(mode)) {
      assert.equal(terminalFrame.type, 'owner.error');
      assert.equal(terminalFrame.status, 'exec_outcome_unknown');
      assert(broker.recoveryPersistenceFailed);
      assert(!files.includes('r-1.terminal'));
      assert(!files.includes('r-1.closed'));
      assert(files.includes('r-1-o-1.birth'));
      if (mode === 'fsync') { assert(injected > 0); assert(bytes.length > 0); }
      if (mode === 'existing') assert.equal(text, 'partial-prior-publication');
    } else if (['version', 'broken'].includes(mode)) {
      assert.equal(terminalFrame.type, 'owner.error');
      assert.equal(terminalFrame.status, 'exec_outcome_unknown');
      assert.equal(fact.phase, 'channel');
      assert.equal(fact.errno, '0');
      assert.equal(fact.binding, binding);
      assert(files.includes('r-1-o-1.birth'));
    } else if (mode === 'unlink') {
      assert.equal(terminalFrame.type, 'owner.error');
      assert.equal(terminalFrame.status, 'spawn_failed');
      assert.equal(children[0].spawned, false);
      assert.equal(children[0].child.pid, undefined);
      assert.equal(children[0].error?.code, 'ENOENT');
      assert.equal(fact.phase, 'spawn'); assert.equal(fact.errno, String(osConstants.errno.ENOENT));
      assert.equal(fact.owner_pid, '0'); assert.equal(fact.owner_pgid, '0'); assert.equal(fact.owner_birth, '');
      assert(files.includes('r-1-o-1.not_spawned'));
      assert(!files.some(name => /^r-1-o-1\.(spawned|birth|terminal)$/u.test(name)));
    } else if (mode === 'exec' || mode === 'permission') {
      assert.equal(terminalFrame.type, 'owner.error'); assert.equal(terminalFrame.status, 'spawn_failed');
      assert.equal(fact.phase, 'exec'); assert.equal(fact.binding, binding);
      assert.equal(fact.errno, String(command.endsWith('missing') ? osConstants.errno.ENOENT : osConstants.errno.EACCES));
      assert.equal(text.split('\n').length, 13); assert.equal(Object.keys(fact).length, 11);
      assert(files.includes('r-1-o-1.birth')); assert(files.includes('r-1-o-1.terminal'));
    } else {
      assert.equal(terminalFrame.type, 'owner.exit'); assert.equal(terminalFrame.exitCode, Number(args[1].split(' ').at(-1)));
      assert.equal(bytes.length, 0);
    }
    fs.writeFileSync(join(own.home, 'formal.json'), JSON.stringify({ formal: true, beforeFallback: true,
      mode, childClosed, groupsGone, injectedFsync: injected, spawned: children.map(x => x.spawned),
      errno: fact.errno ?? null, phase: fact.phase ?? null, operations }) + '\n');
    proofSaved = true;
  } catch (error) { failure = error; }
  finally {
    fs.fsyncSync = originalFsync; fs.openSync = originalOpen; fs.unlinkSync = originalUnlink; syncBuiltinESMExports();
    if (!proofSaved) fs.writeFileSync(join(own.home, 'formal.json'), JSON.stringify({ formal: false, beforeFallback: true, mode }) + '\n');
    fs.writeFileSync(join(own.home, 'frames.json'), JSON.stringify(frames) + '\n');
    fs.writeFileSync(join(own.home, 'operations.json'), JSON.stringify(operations) + '\n');
    children.forEach((child, index) => {
      for (const kind of ['control', 'stdout', 'stderr']) fs.writeFileSync(join(own.home, `${index}-${kind}.bin`), Buffer.concat(child[kind]));
    });
    if (held) held();
    if (broker) broker.closeBroker();
    for (const observed of children) {
      const child = observed.child;
      const deadline = Date.now() + 5000;
      if (!observed.closed && child.exitCode === null && child.signalCode === null) {
        child.kill('SIGTERM');
        if (!await until(() => observed.closed, 250) && child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      }
      assert(await until(() => observed.closed, Math.max(1, deadline - Date.now())));
    }
    names.forEach((name, i) => { if (previous[i] === undefined) delete process.env[name]; else process.env[name] = previous[i]; });
    // Keep every raw/fact/proof home for root's archive + ownership cleanup.
    console.log(`native_outcome mode=${mode};formal=${proofSaved};childCount=${children.length};injectedFsync=${injected}`);
  }
  if (failure) throw failure;
}

test('R-NG-PRODUCER-P1 exact exec errors and business125/126/127 remain distinct', { skip: process.platform !== 'darwin' }, async () => {
  for (const code of [125, 126, 127]) await runOwner('business', '/bin/sh', ['-c', `exit ${code}`]);
  await runOwner('exec', '/native-outcome-fixture-missing');
  await runOwner('permission', '');
});
test('R-NG-PRODUCER-N1 invalid version and broken control are valid unknown', { skip: process.platform !== 'darwin' }, async () => {
  for (const mode of ['version', 'broken']) await runOwner(mode, '/bin/true');
});
test('R-NG-PUBLISH-N1 injected fsync and actual path rejection retain original facts', { skip: process.platform !== 'darwin' }, async () => {
  for (const mode of ['fsync', 'dirsync', 'path', 'existing']) await runOwner(mode, '/native-outcome-fixture-missing');
});
test('R-NG-SPAWN-N1 actual post-resolve unlink is no-child; sync throw is not', { skip: process.platform !== 'darwin' }, async () => {
  await runOwner('unlink', '/bin/true');
  await runOwner('sync', '/bin/true');
});

test('R-NG-ASSET-N1 missing unsafe and stale assets reserve no owner intent', { skip: process.platform !== 'darwin' }, async () => {
  for (const mode of ['asset-missing', 'asset-symlink', 'asset-directory', 'asset-writable', 'asset-stale']) {
    await runOwner(mode, '/bin/true');
  }
});


async function runUncommittedStop(mode) {
  const own = await fixture();
  const names = ['METIS_PROCESS_RECOVERY_DIRECTORY', 'METIS_PROCESS_RECOVERY_PARENT', 'METIS_PROCESS_RECOVERY_BROKER_KEY'];
  const previous = names.map(name => process.env[name]);
  const children = [], frames = [];
  const business = join(own.home, 'business');
  let broker, terminalFrame, exitCode, failed = false, failure, proofSaved = false;
  const remember = error => { if (!failed) { failed = true; failure = error; } };
  try {
    names.forEach((name, i) => { process.env[name] = [own.directory, parent, own.key][i]; });
    const output = new Writable({ write(chunk, _encoding, done) {
      const frame = JSON.parse(String(chunk)); frames.push(frame);
      if (['owner.exit', 'owner.error', 'owner.timeout'].includes(frame.type)) terminalFrame = frame;
      done();
    }});
    broker = new own.StdioBroker({ output, exit: code => { exitCode = code; }, spawnFn: (...parameters) => {
      const child = spawn(...parameters);
      const observed = { child, closed: false, stdout: [], stderr: [] };
      children.push(observed);
      child.stdout.on('data', bytes => observed.stdout.push(Buffer.from(bytes)));
      child.stderr.on('data', bytes => observed.stderr.push(Buffer.from(bytes)));
      child.once('close', () => { observed.closed = true; });
      return child;
    }});
    broker.startOwner({ type: 'owner.start', ownerId: 'fixture', requestId: 'start-1',
      command: process.execPath, args: ['-e', `require('fs').writeFileSync(${JSON.stringify(business)},'unexpected')`],
      ...(mode === 'timed_out' ? { deadlineMs: 100 } : {}) });
    assert(await until(() => frames.some(frame => frame.type === 'owner.started')));
    assert.equal(children.length, 1);
    if (mode !== 'timed_out') {
      assert(await until(() => Boolean(broker.owners.get('fixture')?.gateChallenge)));
      if (mode === 'broker_closed') broker.closeBroker();
      else if (mode === 'stopped') broker.stopOwner('fixture', 'stopped');
      else { assert.equal(mode, 'unsolicited'); children[0].child.kill('SIGTERM'); }
    }
    assert(await until(() => terminalFrame));
    broker.closeBroker();
    assert(await until(() => exitCode !== undefined));
    const child = children[0], files = fs.readdirSync(own.directory);
    const childClosed = child.closed, groupsGone = groupGone(child.child.pid);
    assert(childClosed && groupsGone);
    assert.equal(fs.existsSync(business), false);
    assert.equal(Buffer.concat(child.stdout).length, 0);
    assert.equal(Buffer.concat(child.stderr).length, 0);
    assert.equal(broker.owners.size, 0);
    assert.equal(broker.ownerTerminalCount, 1);
    assert.equal(broker.closeAckCallbackSeen, true);
    assert.equal(exitCode, 0);
    assert(!files.includes('r-1-o-1.birth'));
    assert(!files.includes('r-1-o-1.not_spawned'));
    assert(!files.includes('r-1-o-1.exec_error'));
    if (mode === 'unsolicited') {
      assert.equal(terminalFrame.type, 'owner.error');
      assert.equal(terminalFrame.status, 'exec_outcome_unknown');
      assert.equal(broker.recoveryPersistenceFailed, true);
      assert(files.includes('r-1-o-1.intent') && files.includes('r-1-o-1.spawned'));
      assert(!files.includes('r-1-o-1.terminal') && !files.includes('r-1.terminal') && !files.includes('r-1.closed'));
    } else {
      assert.equal(broker.recoveryPersistenceFailed, false);
      assert.equal(terminalFrame.type, mode === 'timed_out' ? 'owner.timeout' : 'owner.exit');
      if (mode === 'timed_out') assert.equal(terminalFrame.status, 'timed_out');
      else assert(['SIGTERM', 'SIGKILL'].includes(terminalFrame.signal));
      assert.equal(fs.readFileSync(join(own.directory, 'r-1.terminal'), 'utf8'), source(own.directory, 'r-1', 'terminal', process.pid, 0));
      assert.equal(fs.readFileSync(join(own.directory, 'r-1.closed'), 'utf8'),
        `managed-recovery-v1
parent:${parent}
broker:r-1
issued:1
ranges:1-1
`);
      assert(!files.some(name => name.startsWith('r-1-o-')));
    }
    fs.writeFileSync(join(own.home, 'formal.json'), JSON.stringify({ formal: true, beforeFallback: true,
      mode, childClosed, groupsGone, businessPresent: false, recoveryPersistenceFailed: broker.recoveryPersistenceFailed,
      terminalType: terminalFrame.type, status: terminalFrame.status ?? null, exitCode, files }) + '\n');
    proofSaved = true;
  } catch (error) { remember(error); }
  finally {
    const step = async action => { try { await action(); } catch (error) { remember(error); } };
    await step(async () => {
      if (!proofSaved) fs.writeFileSync(join(own.home, 'formal.json'), JSON.stringify({ formal: false, beforeFallback: true, mode }) + '\n');
      fs.writeFileSync(join(own.home, 'frames.json'), JSON.stringify(frames) + '\n');
    });
    await step(async () => { if (broker) broker.closeBroker(); });
    const deadline = Date.now() + 5000;
    for (const observed of children) await step(async () => {
      const child = observed.child;
      if (!observed.closed && child.exitCode === null && child.signalCode === null) {
        child.kill('SIGTERM');
        if (!await until(() => observed.closed, Math.min(250, Math.max(0, deadline - Date.now()))) &&
            child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      }
      assert(await until(() => observed.closed && groupGone(child.pid), Math.max(0, deadline - Date.now())));
    });
    await step(async () => { assert(Date.now() <= deadline, 'fixture_cleanup_deadline_exceeded'); });
    for (let i = 0; i < names.length; i += 1) await step(async () => {
      if (previous[i] === undefined) delete process.env[names[i]]; else process.env[names[i]] = previous[i];
    });
    try { console.log(`native_cancel mode=${mode};formal=${proofSaved};childCount=${children.length};failed=${failed}`); }
    catch { /* original error retains priority */ }
    // Retain every proof/input home, exactly as the existing native producer fixture does.
  }
  if (failed) throw failure;
}

test('R-NG-CANCEL-P1 requested pre-ACK close stop and deadline reap without invented exec error', { skip: process.platform !== 'darwin' }, async () => {
  for (const mode of ['broker_closed', 'stopped', 'timed_out']) await runUncommittedStop(mode);
});
test('R-NG-CANCEL-N2 unsolicited pre-ACK owner exit remains unknown and pending', { skip: process.platform !== 'darwin' }, async () => {
  await runUncommittedStop('unsolicited');
});

test('R-NG-CANCEL-N1 only pure requested pre-ACK transport end is eligible', async () => {
  const { StdioBroker } = await import('./metis-stdio-broker.mjs');
  const challenge = '11111111111111111111111111111111';
  const observe = ({ stop = 'stopped', ending = 'end', hello = false, patch = {}, data, error = false }) => {
    const channel = new EventEmitter(), statuses = [];
    const owner = { nativeGate: true, spawned: true, spawnFailure: false, stopReason: stop,
      recoveryCommitted: false, gateAckWritten: false, gateOutcome: null, gateBuffer: Buffer.alloc(0),
      gateChallenge: '', gateEnded: false, failureStatus: '', child: { stdio: [null, null, null, channel] }, ...patch };
    const broker = Object.create(StdioBroker.prototype);
    broker.commitNativeGate = () => {};
    broker.failOwner = (target, status) => { target.failureStatus ||= status; statuses.push(status); };
    broker.observeNativeGate(owner);
    if (hello) channel.emit('data', Buffer.from(`METIS-EXEC-GATE:1:${challenge}\n`));
    if (data !== undefined) channel.emit('data', data);
    if (error) channel.emit('error', new Error('fixture_control_failure'));
    channel.emit(ending);
    return { owner, statuses };
  };
  for (const stop of ['broker_closed', 'stopped', 'timed_out']) {
    for (const ending of ['end', 'close']) for (const hello of [false, true]) {
      const result = observe({ stop, ending, hello, patch: { failureStatus: stop === 'timed_out' ? 'timed_out' : '' } });
      assert.equal(result.owner.gateOutcome, null);
      assert.deepEqual(result.statuses, []);
    }
  }
  const negatives = [
    { stop: '' }, { stop: 'exec_outcome_unknown' }, { patch: { spawned: false } },
    { patch: { recoveryCommitted: true } }, { patch: { gateAckWritten: true } },
    { hello: true, ending: 'close', patch: { recoveryCommitted: true, gateAckWritten: true } },
    { patch: { failureStatus: 'stdin_write_failed' } }, { error: true },
    { data: Buffer.from('METIS-EXEC-GATE:1:partial') }, { data: Buffer.from([0xff]) },
    { data: Buffer.from(`METIS-EXEC-GATE:9:${challenge}\n`) },
    { hello: true, data: Buffer.from(`METIS-EXEC-ERROR:1:${challenge}:exec:2\n`) },
  ];
  for (const input of negatives) {
    const result = observe(input);
    assert.deepEqual(result.owner.gateOutcome, { phase: 'channel', error: 0 });
    assert(result.statuses.includes('exec_outcome_unknown'));
  }
  // Clean EOF after a valid ACK is the existing exec-success witness, not cancellation.
  const executed = observe({ hello: true, patch: { recoveryCommitted: true, gateAckWritten: true } });
  assert.equal(executed.owner.gateOutcome, null);
  assert.deepEqual(executed.statuses, []);
  for (const phase of ['setup', 'protocol', 'exec']) {
    const result = observe({ hello: true, patch: phase === 'exec' ? { recoveryCommitted: true, gateAckWritten: true } : {},
      data: Buffer.from(`METIS-EXEC-ERROR:1:${challenge}:${phase}:22\n`) });
    assert.deepEqual(result.owner.gateOutcome, { phase, error: 22 });
  }
  const unknown = observe({ patch: { gateOutcome: { phase: 'channel', error: 0 }, failureStatus: 'exec_outcome_unknown' } });
  assert.deepEqual(unknown.owner.gateOutcome, { phase: 'channel', error: 0 });
  assert.equal(unknown.owner.failureStatus, 'exec_outcome_unknown');
  const spawned = observe({ patch: { spawnFailure: true, gateOutcome: { phase: 'spawn', error: 2 } } });
  assert.deepEqual(spawned.owner.gateOutcome, { phase: 'spawn', error: 2 });
});
