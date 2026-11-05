// Owned native-gate fixture. The Cangjie test observes native births before ACK.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdirSync, writeFileSync, readFileSync, statSync, existsSync, chmodSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const [gateArgument, homeArgument, mode] = process.argv.slice(2);
assert(gateArgument && homeArgument && ['positive', 'negative'].includes(mode), 'fixture_arguments_invalid');
const gate = realpathSync(gateArgument), home = realpathSync(homeArgument);
assert(home.startsWith('/private/tmp/'), 'fixture_home_invalid');
const expectedOwner = 'native-exec-gate-fixture-v1\n';
assert.equal(readFileSync(join(home, 'owner'), 'utf8'), expectedOwner);
const gateInfo = statSync(gate);
assert(gateInfo.isFile() && (gateInfo.mode & 0o111) !== 0 && (gateInfo.mode & 0o022) === 0);
const project = fileURLToPath(new URL('../../../../', import.meta.url));
for (const source of ['src/process/managed_exec_gate.c', 'build.cj']) {
  assert(gateInfo.mtimeMs >= statSync(join(project, source)).mtimeMs, 'native_gate_stale');
}
writeFileSync(join(home, 'artifact.json'), JSON.stringify({
  gateSha256: createHash('sha256').update(readFileSync(gate)).digest('hex'),
  sourceSha256: createHash('sha256').update(readFileSync(join(project, 'src/process/managed_exec_gate.c'))).digest('hex'),
  buildSha256: createHash('sha256').update(readFileSync(join(project, 'build.cj'))).digest('hex'),
  gateMtimeMs: gateInfo.mtimeMs, abi: 1,
}));

const helloPattern = /^METIS-EXEC-GATE:1:([0-9a-f]{32})\n$/;
const input = Buffer.concat([Buffer.from('原始输入中文😀\n'), Buffer.from([0, 255, 128, 254])]);
const payload = '中文😀\n\'"$() `literal`'.repeat(4096);
const body = 'for fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do ' +
  'if [ -e "/dev/fd/$fd" ]; then printf "inherited_fd=%s\\n" "$fd" >&2; exit 91; fi; done; ' +
  'printf started > "$3"; printf "%s\\n%s" "$PWD" "$NATIVE_SYNTHETIC" > "$4"; ' +
  'printf "BIRTH_PID=%s\\n" "$$"; /bin/cat; printf "%s" "$1"; printf "\\377\\000\\376"; ' +
  'printf "%s" "$1" >&2; printf "\\200\\000" >&2; exit "$2"';
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const pause = ms => new Promise(resolvePromise => setTimeout(resolvePromise, ms));
const commands = [], waiters = [];
const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  let value;
  try { value = JSON.parse(line); } catch { value = { action: 'invalid' }; }
  const waiter = waiters.shift();
  if (waiter) waiter(value); else commands.push(value);
});
function nextCommand() { return commands.length ? Promise.resolve(commands.shift()) : new Promise(resolvePromise => waiters.push(resolvePromise)); }
function groupGone(pid) { try { process.kill(-pid, 0); return false; } catch (error) { return error.code === 'ESRCH'; } }
const rows = [];
let current = null, interrupted = false;
process.on('SIGTERM', () => {
  interrupted = true;
  while (waiters.length) waiters.shift()({ action: 'interrupted' });
  if (current && current.exitCode === null && current.signalCode === null) {
    try { process.kill(-current.pid, 'SIGTERM'); } catch { /* same owned handle only */ }
    setTimeout(() => { if (current && current.exitCode === null && current.signalCode === null) {
      try { process.kill(-current.pid, 'SIGKILL'); } catch { /* same owned handle only */ }
    } }, 250).unref();
  }
});

async function one(name, command, arguments_, options = {}) {
  const directory = join(home, name); mkdirSync(directory, { mode: 0o700 });
  const marker = join(directory, 'business.marker'), metadata = join(directory, 'business.meta');
  const env = { PATH: '/usr/bin:/bin', HOME: directory, TMPDIR: directory, LANG: 'en_US.UTF-8', NATIVE_SYNTHETIC: '环境值中文😀' };
  for (const key of ['CANGJIE_HOME', 'DYLD_LIBRARY_PATH']) if (process.env[key] !== undefined) env[key] = process.env[key];
  if (options.markerDirectory) mkdirSync(join(directory, 'exec-failure'));
  else writeFileSync(join(directory, 'exec-failure'), 'original-marker');
  const oldMarker = options.markerDirectory ? null : readFileSync(join(directory, 'exec-failure'));
  env.METIS_EXEC_FAILURE_FILE = join(directory, 'exec-failure');
  const business = options.business || options.textBusiness;
  const argv = options.business ? ['-c', body, 'business', payload, String(options.code), marker, metadata] : arguments_;
  const child = spawn(gate, [command, ...argv], { cwd: directory, env, detached: true,
    stdio: options.missingFd ? ['pipe', 'pipe', 'pipe'] : ['pipe', 'pipe', 'pipe', 'pipe'] });
  current = child;
  const stdout = [], stderr = [], control = [];
  let result = null, formal = false, timedOut = false, gateBirth = null, businessObserved = false;
  let hello = '', challenge = '';
  let resolveHello, resolveBusiness;
  const helloSeen = new Promise(resolvePromise => { resolveHello = resolvePromise; });
  const businessSeen = new Promise(resolvePromise => { resolveBusiness = resolvePromise; });
  child.stdin.on('error', () => {});
  child.stdout.on('data', bytes => {
    stdout.push(bytes);
    if (Buffer.concat(stdout).includes(10)) resolveBusiness();
  });
  child.stderr.on('data', bytes => stderr.push(bytes));
  child.stdio[3]?.on('data', bytes => { control.push(bytes); if (Buffer.concat(control).includes(10)) resolveHello(); });
  child.stdio[3]?.on('error', () => {});
  const exited = new Promise(resolvePromise => child.once('close', (code, signal) => resolvePromise({ code, signal })));
  const timer = setTimeout(() => {
    timedOut = true;
    while (waiters.length) waiters.shift()({ action: 'actor_timed_out' });
    if (child.exitCode === null && child.signalCode === null) try { process.kill(-child.pid, 'SIGKILL'); } catch { /* owned child */ }
    resolveHello(); resolveBusiness();
  }, 5000);
  try {
    if (!options.missingFd) {
      await Promise.race([helloSeen, exited]);
      assert(Buffer.concat(control).every(byte => byte < 128));
      hello = Buffer.concat(control).toString('ascii');
      const parsedHello = helloPattern.exec(hello); assert(parsedHello); challenge = parsedHello[1];
      const ack = `METIS-EXEC-ACK:1:${challenge}\n`;
      emit({ event: 'gate', name, pid: child.pid });
      const observed = await nextCommand();
      assert.equal(observed.action, 'gate-observed'); assert.equal(observed.pid, child.pid);
      assert.match(observed.birth, /^[1-9][0-9]*:[1-9][0-9]*:[0-9]+$/); gateBirth = observed.birth;
      await pause(25);
      assert(!existsSync(marker)); assert.equal(Buffer.concat(stdout).length, 0); assert.equal(Buffer.concat(stderr).length, 0);
      const message = typeof options.ack === 'function' ? options.ack(ack) : options.ack ?? ack;
      if (options.brokenControl) {
        await new Promise((resolvePromise, reject) => child.stdio[3].write(message, error => error ? reject(error) : resolvePromise()));
        child.stdio[3].destroy();
      } else child.stdio[3].end(message);
    }
    if (business) {
      await Promise.race([businessSeen, exited]);
      assert(Buffer.concat(stdout).subarray(0, Buffer.byteLength(`BIRTH_PID=${child.pid}\n`)).equals(Buffer.from(`BIRTH_PID=${child.pid}\n`)));
      emit({ event: 'business', name, pid: child.pid });
      const observed = await nextCommand();
      assert.equal(observed.action, 'business-observed'); assert.equal(observed.pid, child.pid);
      businessObserved = true; child.stdin.end(input);
    } else child.stdin.end();
    result = await exited;
    assert(!timedOut && !interrupted); assert(groupGone(child.pid));
    assert(Buffer.concat(control).every(byte => byte < 128));
    const privateText = Buffer.concat(control).toString('ascii');
    const expectedPhase = options.expectedPhase;
    if (!options.missingFd && !options.brokenControl) {
      if (expectedPhase) {
        const suffix = privateText.slice(hello.length);
        const expectedChallenge = challenge;
        assert.match(suffix, new RegExp(`^METIS-EXEC-ERROR:1:${expectedChallenge}:${expectedPhase}:[1-9][0-9]*\\n$`));
      } else assert.equal(privateText, hello);
    }
    if (business) {
      assert.equal(result.code, options.code);
      assert.deepEqual(Buffer.concat(stdout), Buffer.concat([Buffer.from(`BIRTH_PID=${child.pid}\n`), input, Buffer.from(payload), Buffer.from([255, 0, 254])]));
      assert.deepEqual(Buffer.concat(stderr), Buffer.concat([Buffer.from(payload), Buffer.from([128, 0])]));
      assert.equal(readFileSync(metadata, 'utf8'), directory + '\n' + env.NATIVE_SYNTHETIC);
      assert(existsSync(marker));
    } else {
      assert.equal(result.code, 125); assert.equal(Buffer.concat(stdout).length, 0); assert.equal(Buffer.concat(stderr).length, 0); assert(!existsSync(marker));
    }
    if (oldMarker) assert.deepEqual(readFileSync(join(directory, 'exec-failure')), oldMarker);
    else assert(statSync(join(directory, 'exec-failure')).isDirectory());
    assert(child.stdio.every(stream => stream?.destroyed ?? true));
    formal = true;
    const row = { event: 'case', name, formal, ...result, pid: child.pid, childReaped: true, groupGone: true, streamsClosed: true,
      gateBirth, businessObserved, timedOut, execFailureFact: expectedPhase === 'exec' && !options.brokenControl,
      classification: options.brokenControl ? 'unknown' : expectedPhase ?? 'business', recordedBeforeFallback: true };
    rows.push(row); writeFileSync(join(directory, 'formal-before-fallback.json'), JSON.stringify(row)); emit(row);
  } finally {
    clearTimeout(timer);
    writeFileSync(join(directory, 'stdout'), Buffer.concat(stdout)); writeFileSync(join(directory, 'stderr'), Buffer.concat(stderr)); writeFileSync(join(directory, 'private-control'), Buffer.concat(control));
    if (!formal) writeFileSync(join(directory, 'formal-before-fallback.json'), JSON.stringify({ formal: false, result, pid: child.pid,
      timedOut, gateBirth, businessObserved, groupGone: groupGone(child.pid), recordedBeforeFallback: true }));
    if (child.exitCode === null && child.signalCode === null) {
      try { process.kill(-child.pid, 'SIGTERM'); } catch { /* owned child */ }
      const kill = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 250);
      await exited; clearTimeout(kill);
    }
    current = null;
  }
}

let formal = false;
try {
  if (mode === 'positive') {
    for (const code of [7, 126, 127]) await one(`binary-${code}`, '/bin/sh', [], { business: true, code });
    const denied = join(home, 'not-executable'); writeFileSync(denied, 'exit 7\n'); chmodSync(denied, 0o600);
    for (const [name, command] of [['absolute-missing', join(home, 'missing')], ['bare-missing', 'metis_native_missing_7ecd94b32e'], ['permission', denied]])
      await one(name, command, [], { expectedPhase: 'exec' });
    for (const code of [7, 126, 127]) {
      const script = join(home, `text-${code}`); writeFileSync(script, body + '\n'); chmodSync(script, 0o700);
      await one(`enoexec-${code}`, script, [payload, String(code), join(home, `enoexec-${code}`, 'business.marker'), join(home, `enoexec-${code}`, 'business.meta')], { business: false, textBusiness: true, code });
    }
    await one('gate-eof', '/usr/bin/touch', [join(home, 'unexpected')], { ack: '', expectedPhase: 'protocol' });
    await one('file-error-observed', join(home, 'missing'), [], { expectedPhase: 'exec' });
    await one('file-error-unwritable', join(home, 'missing'), [], { expectedPhase: 'exec', markerDirectory: true });
    await one('pipe-error-broken', join(home, 'missing'), [], { brokenControl: true });
  } else {
    for (const [name, message] of [['eof', ''], ['version', value => value.replace('ACK:1:', 'ACK:2:')], ['challenge', value => value.replace(/([0-9a-f]{32})/, found => (found[0] === '0' ? '1' : '0') + found.slice(1))],
      ['partial', value => value.slice(0, -1)], ['oversized', 'X'.repeat(128) + '\n']])
      await one(name, '/usr/bin/touch', [join(home, 'unexpected')], { ack: message, expectedPhase: 'protocol' });
    await one('missing-fd', '/usr/bin/touch', [join(home, 'unexpected')], { missingFd: true });
    await one('broken-control', join(home, 'missing'), [], { brokenControl: true });
  }
  assert.equal(rows.length, mode === 'positive' ? 13 : 7); assert(!existsSync(join(home, 'unexpected')));
  formal = true; emit({ event: 'done', formal, count: rows.length });
} catch (error) {
  writeFileSync(join(home, 'driver-error.txt'), String(error)); emit({ event: 'failure', status: 'native_gate_fixture_failed' }); process.exitCode = 1;
} finally {
  writeFileSync(join(home, 'driver-formal.json'), JSON.stringify({ formal, rows, recordedBeforeFallback: true })); lines.close(); process.stdin.destroy();
}
