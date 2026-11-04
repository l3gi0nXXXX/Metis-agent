#!/usr/bin/env node
import { constants as osConstants } from 'node:os';

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync, lstatSync, fstatSync, openSync, writeSync, fsyncSync, fchmodSync, closeSync, unlinkSync, accessSync, constants } from "node:fs";
import { join, dirname } from "node:path";
import { TextDecoder } from "node:util";
import { Writable } from "node:stream";
import { fileURLToPath, pathToFileURL } from "node:url";

export const OWNER_HARD_LIMIT = 256;
const DEFAULT_MAX_LINE_BYTES = 1024 * 1024;
const DEFAULT_MAX_BUFFERED_BYTES = 4 * 1024 * 1024;
const DEFAULT_TERM_GRACE_MS = 250;
const DEFAULT_WRITER_QUEUE_BYTES = 8 * 1024 * 1024;
const DEFAULT_BROKER_INPUT_BYTES = 1024 * 1024;
const DIAGNOSTIC_IDENTITY_LIMIT = 16;
const DIAGNOSTIC_FILE_PATTERN = /^broker-g[1-9][0-9]*-p[1-9][0-9]*\.json$/u;
const DIAGNOSTIC_TEMP_PATTERN = /^broker-g[1-9][0-9]*-p[1-9][0-9]*\.json\.tmp-[1-9][0-9]*$/u;
const DIAGNOSTIC_SLOT_PATTERN = /^\.identity-slot-(?:[0-9]|1[0-5])$/u;

const recoveryKey = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{1,256}$/u.test(value);

/** Immutable source facts: a late parent birth observation cannot overwrite a terminal fact. */
export function publishRecoveryFact(directory, key, phase, parent, pid = 0, pgid = 0) {
  if (!directory) return;
  if (!recoveryKey(key) || (!['intent', 'spawned', 'terminal', 'not_spawned'].includes(phase) ||
      (phase === 'not_spawned' && (pid !== 0 || pgid !== 0))) ||
      !/^1(?::[0-9]+){11}$/u.test(parent)) throw new Error('recovery_record_invalid');
  let current = directory;
  for (;;) {
    if (lstatSync(current).isSymbolicLink()) throw new Error('recovery_path_unsafe');
    const next = dirname(current);
    if (next === current) break;
    current = next;
  }
  const text = `managed-recovery-v1\nkey:${key}\nphase:${phase}\nparent:${parent}\npid:${pid}\npgid:${pgid}\nbirth:\n`;
  const path = join(directory, `${key}.${phase}`);
  let fd;
  try {
    fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    fchmodSync(fd, 0o600);
    const bytes = Buffer.from(text);
    let used = 0;
    while (used < bytes.length) used += writeSync(fd, bytes, used, bytes.length - used);
    fsyncSync(fd);
  } catch (error) {
    if (error?.code !== 'EEXIST' || lstatSync(path).isSymbolicLink() || readFileSync(path, 'utf8') !== text) throw error;
  } finally { if (fd !== undefined) closeSync(fd); }
  const directoryFd = openSync(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
  try { fsyncSync(directoryFd); } finally { closeSync(directoryFd); }
}

/** Internal artifact only: no command PATH or public environment override. */
function resolveNativeExecGate() {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const source = join(root, 'src', 'process', 'managed_exec_gate.c');
  const development = existsSync(join(root, 'src'));
  const asset = development ? join(root, 'target', 'native', 'metis-exec-gate-v1') :
    join(root, 'libexec', 'metis-exec-gate-v1');
  let current = asset;
  for (;;) {
    const info = lstatSync(current);
    if (info.isSymbolicLink()) throw new Error('exec_gate_asset_invalid');
    if (current === asset && (!info.isFile() || (info.mode & 0o111) === 0 || (info.mode & 0o022) !== 0)) {
      throw new Error('exec_gate_asset_invalid');
    }
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  accessSync(asset, constants.X_OK);
  if (development) {
    const built = lstatSync(asset).mtimeMs;
    for (const input of [source, join(root, 'build.cj')]) {
      const info = lstatSync(input);
      if (info.isSymbolicLink() || !info.isFile() || info.mtimeMs > built) throw new Error('exec_gate_asset_stale');
    }
  }
  return asset;
}

function readRecoverySource(directory, name, limit = 8192) {
  const path = join(directory, name);
  const before = lstatSync(path);
  if (!before.isFile() || before.isSymbolicLink() || before.size > limit) throw new Error('recovery_record_invalid');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = fstatSync(fd);
    if (!info.isFile() || info.size > limit) throw new Error('recovery_record_invalid');
    const bytes = readFileSync(fd);
    if (bytes.length > limit) throw new Error('recovery_record_invalid');
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } finally { closeSync(fd); }
}

function recoveryBinding(directory, parent) {
  const text = readRecoverySource(directory, 'inventory');
  const prefix = `managed-recovery-v1\nparent:${parent}\nbinding:`;
  const suffix = '\ncoverage:broker-v1\n';
  if (!text.startsWith(prefix) || !text.endsWith(suffix)) throw new Error('recovery_record_invalid');
  const binding = text.slice(prefix.length, -suffix.length);
  if (!binding || Buffer.byteLength(binding) > 4096 || /[\r\n\0]/u.test(binding)) throw new Error('recovery_record_invalid');
  return binding;
}

function originalRecoveryBirth(directory, key, parent, pid, pgid) {
  let birth = '';
  for (const phase of ['intent', 'spawned', 'birth']) {
    const text = readRecoverySource(directory, `${key}.${phase}`);
    if (phase === 'birth') {
      const match = /\nbirth:([1-9][0-9]*:[1-9][0-9]*:(?:0|[1-9][0-9]{0,5}))\n$/u.exec(text);
      if (!match || match[1].split(':')[0] !== String(pid) ||
          !Number.isSafeInteger(Number(match[1].split(':')[1])) || Number(match[1].split(':')[2]) >= 1000000) {
        throw new Error('recovery_record_invalid');
      }
      birth = match[1];
    }
    const expected = `managed-recovery-v1\nkey:${key}\nphase:${phase}\nparent:${parent}\npid:${phase === 'intent' ? 0 : pid}\npgid:${phase === 'intent' ? 0 : pgid}\nbirth:${phase === 'birth' ? birth : ''}\n`;
    if (text !== expected) throw new Error('recovery_record_invalid');
  }
  return birth;
}

function publishExecError(broker, owner) {
  let current = broker.recoveryDirectory;
  for (;;) {
    const info = lstatSync(current);
    if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('recovery_path_unsafe');
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  if (recoveryBinding(broker.recoveryDirectory, broker.recoveryParent) !== broker.recoveryBinding) {
    throw new Error('recovery_record_invalid');
  }
  const { phase, error } = owner.gateOutcome;
  const pid = phase === 'spawn' ? 0 : Number(owner.child.pid);
  const helperBirth = originalRecoveryBirth(broker.recoveryDirectory, broker.recoveryKey, broker.recoveryParent, process.pid, 0);
  let ownerBirth = '';
  if (phase === 'spawn') {
    if (!owner.spawnFailure || owner.spawned || owner.child.pid !== undefined || !owner.closed) {
      throw new Error('recovery_record_invalid');
    }
    const intent = `managed-recovery-v1\nkey:${owner.journalKey}\nphase:intent\nparent:${broker.recoveryParent}\npid:0\npgid:0\nbirth:\n`;
    if (readRecoverySource(broker.recoveryDirectory, `${owner.journalKey}.intent`) !== intent ||
        readRecoverySource(broker.recoveryDirectory, `${owner.journalKey}.not_spawned`) !== intent.replace('phase:intent\n', 'phase:not_spawned\n')) {
      throw new Error('recovery_record_invalid');
    }
    const names = readdirSync(broker.recoveryDirectory);
    if (['spawned', 'birth', 'terminal'].some((name) => names.includes(`${owner.journalKey}.${name}`))) {
      throw new Error('recovery_record_invalid');
    }
  } else ownerBirth = originalRecoveryBirth(broker.recoveryDirectory, owner.journalKey, broker.recoveryParent, pid, pid);
  const text = `managed-exec-error-v1\nkey:${owner.journalKey}\nparent:${broker.recoveryParent}\nbinding:${broker.recoveryBinding}\nhelper_key:${broker.recoveryKey}\nhelper_pid:${process.pid}\nhelper_birth:${helperBirth}\nowner_pid:${pid}\nowner_pgid:${pid}\nowner_birth:${ownerBirth}\nphase:${phase}\nerrno:${error}\n`;
  if (owner.execErrorPublished) {
    if (readRecoverySource(broker.recoveryDirectory, `${owner.journalKey}.exec_error`) !== text) {
      throw new Error('recovery_record_invalid');
    }
    return;
  }
  const path = join(broker.recoveryDirectory, `${owner.journalKey}.exec_error`);
  let fd;
  try {
    fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    fchmodSync(fd, 0o600);
    const bytes = Buffer.from(text);
    let offset = 0;
    while (offset < bytes.length) {
      let count;
      try { count = writeSync(fd, bytes, offset, bytes.length - offset); }
      catch (error) { if (error?.code === 'EINTR') continue; throw error; }
      if (count <= 0) throw new Error('recovery_write_failed');
      offset += count;
    }
    fsyncSync(fd);
  } finally { if (fd !== undefined) closeSync(fd); }
  const directoryFd = openSync(broker.recoveryDirectory, constants.O_RDONLY | constants.O_NOFOLLOW);
  try { fsyncSync(directoryFd); } finally { closeSync(directoryFd); }
  owner.execErrorPublished = true;
}

function recoveryBirthMatches(directory, key, parent, pid, pgid) {
  try {
    const path = join(directory, `${key}.birth`);
    const info = lstatSync(path);
    if (info.isSymbolicLink() || !info.isFile() || info.size > 8192) return false;
    const text = new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(path));
    const lines = text.split('\n');
    if (lines.shift() !== 'managed-recovery-v1') return false;
    const fields = new Map();
    for (const line of lines) {
      if (!line) continue;
      const colon = line.indexOf(':');
      const name = line.slice(0, colon);
      if (colon < 1 || fields.has(name)) return false;
      fields.set(name, line.slice(colon + 1));
    }
    const birth = fields.get('birth')?.split(':');
    const seconds = Number(birth?.[1]);
    const micros = Number(birth?.[2]);
    return fields.size === 6 && fields.get('key') === key && fields.get('parent') === parent && fields.get('phase') === 'birth' &&
      fields.get('pid') === String(pid) && fields.get('pgid') === String(pgid) && birth?.length === 3 && birth[0] === String(pid) &&
      Number.isSafeInteger(seconds) && seconds > 0 && String(seconds) === birth[1] &&
      Number.isSafeInteger(micros) && micros >= 0 && micros < 1000000 && String(micros) === birth[2];
  } catch { return false; }
}

export function mergeClosedSequence(ranges, sequence) {
  if (!Number.isSafeInteger(sequence) || sequence <= 0) throw new Error('recovery_sequence_invalid');
  const out = [];
  let low = sequence, high = sequence, inserted = false;
  for (const [start, end] of ranges) {
    if (end + 1 < low) out.push([start, end]);
    else if (high + 1 < start) { if (!inserted) { out.push([low, high]); inserted = true; } out.push([start, end]); }
    else { low = Math.min(low, start); high = Math.max(high, end); }
  }
  if (!inserted) out.push([low, high]);
  return out;
}

export function publishClosedCheckpoint(directory, key, parent, issued, ranges) {
  if (!recoveryKey(key) || !Number.isSafeInteger(issued) || issued <= 0 || ranges.length > OWNER_HARD_LIMIT + 1) throw new Error('recovery_checkpoint_invalid');
  let previous = 0;
  for (const [start, end] of ranges) {
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start <= previous || start <= 0 || end < start || end > issued) {
      throw new Error('recovery_checkpoint_invalid');
    }
    previous = end;
  }
  const target = join(directory, `${key}.closed`);
  const temporary = `${target}.tmp-${process.pid}`;
  const text = `managed-recovery-v1\nparent:${parent}\nbroker:${key}\nissued:${issued}\nranges:${ranges.map(([a, b]) => `${a}-${b}`).join(',')}\n`;
  let fd;
  try {
    fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
    fchmodSync(fd, 0o600);
    const data = Buffer.from(text);
    let used = 0;
    while (used < data.length) used += writeSync(fd, data, used, data.length - used);
    fsyncSync(fd); closeSync(fd); fd = undefined;
    if (existsSync(target) && lstatSync(target).isSymbolicLink()) throw new Error('recovery_path_unsafe');
    renameSync(temporary, target);
    const directoryFd = openSync(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { fsyncSync(directoryFd); } finally { closeSync(directoryFd); }
  } finally { if (fd !== undefined) closeSync(fd); }
}

function diagnosticDirectoryState(path) {
  let slotCount = 0;
  let identityCount = 0;
  try {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      if (entry.isDirectory() && DIAGNOSTIC_SLOT_PATTERN.test(entry.name)) {
        slotCount += 1;
        continue;
      }
      if (entry.isFile() && DIAGNOSTIC_TEMP_PATTERN.test(entry.name)) continue;
      if (entry.isFile() && entry.name === 'overflow.json') {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(join(path, entry.name)));
        const value = JSON.parse(text);
        if (value?.protocolVersion === '1.0' && value.overflow === true &&
            value.capacity === DIAGNOSTIC_IDENTITY_LIMIT) continue;
        return { unsafe: true, slotCount, identityCount };
      }
      if (entry.isFile() && DIAGNOSTIC_FILE_PATTERN.test(entry.name)) {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(join(path, entry.name)));
        const value = JSON.parse(text);
        if (value?.protocolVersion === '1.0' && Number.isSafeInteger(value.generation) && value.generation > 0 &&
            Number.isSafeInteger(value.brokerPid) && value.brokerPid > 1 &&
            entry.name === `broker-g${value.generation}-p${value.brokerPid}.json`) {
          identityCount += 1;
          continue;
        }
      }
      return { unsafe: true, slotCount, identityCount };
    }
    return { unsafe: false, slotCount, identityCount };
  } catch {
    return { unsafe: true, slotCount, identityCount };
  }
}

function brokerFramePhase(frame) {
  if (frame?.type === 'broker.closed') return 'broker_closed';
  if (['owner.exit', 'owner.error', 'owner.timeout'].includes(frame?.type)) return 'owner_terminal';
  return 'other';
}

function ownerDiagnosticClass(frame) {
  if (typeof frame?.ownerId === 'string' && frame.ownerId.startsWith('service-plugin:')) return 'service_plugin';
  if (frame?.command === '/bin/sh' && Array.isArray(frame.args) && frame.args.length === 2 &&
      frame.args[0] === '-c' && /^kill -0 [1-9][0-9]*$/u.test(frame.args[1])) return 'pid_probe';
  if (frame?.command === '/bin/sh' && Array.isArray(frame.args) && frame.args.length === 2 &&
      frame.args[0] === '-c' && (
        /^lsof -nP -iTCP:[1-9][0-9]* -sTCP:LISTEN -Fp$/u.test(frame.args[1]) ||
        /^lsof -nP -iTCP:[1-9][0-9]* -sTCP:LISTEN -t$/u.test(frame.args[1])
      )) {
    return 'lsof_probe';
  }
  if (frame?.command === 'lsof' && Array.isArray(frame.args) && frame.args.length === 4 &&
      frame.args[0] === '-nP' && /^-iTCP:[1-9][0-9]*$/u.test(frame.args[1]) &&
      frame.args[2] === '-sTCP:LISTEN' && (frame.args[3] === '-Fp' || frame.args[3] === '-t')) {
    return 'lsof_probe';
  }
  return 'other';
}

function integer(value, fallback, { minimum = 0 } = {}) {
  if (value === undefined) return fallback;
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error("invalid_owner_spec");
  return value;
}

function safeIdentifier(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256 &&
    ![...value].some((character) => character.codePointAt(0) < 0x20 || character.codePointAt(0) === 0x7f);
}

function safeRequestId(value) {
  return value === undefined || (typeof value === 'string' && value.length <= 256 &&
    ![...value].some((character) => character.codePointAt(0) < 0x20 || character.codePointAt(0) === 0x7f));
}

export function truncateRunes(text, maxRunes) {
  if (!Number.isSafeInteger(maxRunes) || maxRunes < 0) return '';
  const runes = Array.from(String(text));
  return runes.length <= maxRunes ? runes.join('') : runes.slice(0, maxRunes).join('');
}

function normalizeStopReason(value) {
  const reason = typeof value === 'string' ? value : 'stopped';
  return ['stopped', 'broker_closed', 'timed_out', 'buffer_capacity_exceeded', 'start_timeout'].includes(reason) ? reason : 'stopped';
}

function stableOwnerError(value) {
  return ['invalid_owner_spec', 'broker_closing', 'duplicate_owner', 'broker_capacity_exceeded'].includes(value)
    ? value : 'spawn_failed';
}

export function validateStartFrame(frame) {
  if (!frame || frame.type !== "owner.start" || !safeIdentifier(frame.ownerId)) {
    throw new Error("invalid_owner_spec");
  }
  if (typeof frame.command !== "string" || frame.command.length === 0 || frame.command.includes("\0")) {
    throw new Error("invalid_owner_spec");
  }
  if (!Array.isArray(frame.args) || frame.args.some((arg) => typeof arg !== "string" || arg.includes("\0"))) {
    throw new Error("invalid_owner_spec");
  }
  if (!safeRequestId(frame.requestId)) throw new Error('invalid_owner_spec');
  if (frame.cwd !== undefined && (typeof frame.cwd !== "string" || frame.cwd.includes("\0"))) {
    throw new Error("invalid_owner_spec");
  }
  if (frame.env !== undefined && (frame.env === null || Array.isArray(frame.env) || typeof frame.env !== "object" ||
      Object.entries(frame.env).some(([key, value]) => !safeIdentifier(key) || key.includes('=') || typeof value !== "string" || value.includes("\0")))) {
    throw new Error("invalid_owner_spec");
  }
  if (!['line', 'closed'].includes(frame.stdinMode ?? 'line') || !['line', 'stream'].includes(frame.outputMode ?? 'line')) {
    throw new Error("invalid_owner_spec");
  }
  integer(frame.deadlineMs, 0);
  integer(frame.maxLineBytes, DEFAULT_MAX_LINE_BYTES, { minimum: 1 });
  integer(frame.maxBufferedBytes, DEFAULT_MAX_BUFFERED_BYTES, { minimum: 1 });
  integer(frame.maxTotalOutputBytes, 0);
  return true;
}

export function normalizedOwnerSpawnOptions(frame, platform = process.platform) {
  validateStartFrame(frame);
  return {
    cwd: frame.cwd || undefined,
    env: frame.env ? { ...process.env, ...frame.env } : process.env,
    stdio: ['pipe', 'pipe', 'pipe'],
    detached: platform !== 'win32',
    windowsHide: true,
  };
}

// CoreFoundation may mutate Node's native environment before JavaScript starts.
// This witness is supplied only by the existing attached Cangjie launcher.
export function attachedBusinessEnvironment(environment, platform = process.platform) {
  const result = { ...environment };
  const marker = 'METIS_STDIO_ATTACHED_CF_ENV_V1';
  if (platform !== 'darwin' || !Object.hasOwn(environment, marker)) return result;
  let witness;
  try { witness = JSON.parse(environment[marker]); }
  catch { throw new Error('attached_environment_invalid'); }
  if (!Array.isArray(witness) || witness.length !== 5 || witness[0] !== 1 ||
      typeof witness[1] !== 'boolean' || typeof witness[3] !== 'boolean' ||
      typeof witness[2] !== 'string' || typeof witness[4] !== 'string' ||
      witness[2].includes('\0') || witness[4].includes('\0') ||
      Buffer.from(witness[2], 'utf8').toString('utf8') !== witness[2] ||
      Buffer.from(witness[4], 'utf8').toString('utf8') !== witness[4] ||
      (!witness[1] && witness[2] !== '') || (!witness[3] && witness[4] !== '')) {
    throw new Error('attached_environment_invalid');
  }
  if (witness[1]) result.__CF_USER_TEXT_ENCODING = witness[2];
  else delete result.__CF_USER_TEXT_ENCODING;
  if (witness[3]) result[marker] = witness[4];
  else delete result[marker];
  return result;
}

export function recoveryGateShell(environment, platform = process.platform) {
  const gate = 'IFS= read -r metis_gate <&3 || exit 125; exec 3<&-; ';
  if (platform !== 'darwin') return { script: `${gate}exec "$@"`, env: environment };
  // Protected macOS shells strip DYLD_* on entry. Keep values in env, then
  // restore them after the ownership ACK without inserting values into code.
  const env = { ...environment };
  let restore = '', sequence = 0;
  for (const name of Object.keys(environment)) {
    if (!/^DYLD_[A-Za-z0-9_]*$/u.test(name)) continue;
    let shadow;
    do { shadow = `METIS_GATE_DYLD_${sequence++}`; } while (Object.hasOwn(env, shadow));
    env[shadow] = environment[name];
    restore += `${name}="\${${shadow}}"; export ${name}; unset ${shadow}; `;
  }
  return { script: `${gate}${restore}exec "$@"`, env };
}

export function terminationCommandsForPlatform(platform, pid, force = false) {
  if (platform === 'win32') {
    return [['taskkill', ['/PID', String(pid), '/T', ...(force ? ['/F'] : [])]]];
  }
  return [['signal-group', [force ? 'SIGKILL' : 'SIGTERM', String(pid)]]];
}

export class BrokerWriter {
  constructor(output, { maxQueuedBytes = DEFAULT_WRITER_QUEUE_BYTES, onFailure = () => {} } = {}) {
    this.output = output;
    this.queue = [];
    this.queuedBytes = 0;
    this.maxQueuedBytes = maxQueuedBytes;
    this.onFailure = onFailure;
    this.writing = false;
    this.pendingWrites = 0;
    this.inflightPhases = new Map();
    this.closed = false;
    this.idleCallbacks = [];
    output.once?.('error', () => this.fail('output_error', this.singleInflightPhase()));
  }

  write(frame, onWritten = () => {}, framePhase = 'other') {
    if (this.closed) return false;
    const encoded = `${JSON.stringify(frame)}\n`;
    const bytes = Buffer.byteLength(encoded);
    if (this.queuedBytes + bytes > this.maxQueuedBytes) {
      this.fail('queue_capacity', framePhase);
      return false;
    }
    this.queue.push({ encoded, onWritten, framePhase });
    this.queuedBytes += bytes;
    this.flush();
    return true;
  }

  flush() {
    if (this.writing || this.closed) return;
    while (this.queue.length > 0) {
      const item = this.queue.shift();
      const chunk = item.encoded;
      this.queuedBytes -= Buffer.byteLength(chunk);
      let accepted = false;
      this.pendingWrites += 1;
      this.inflightPhases.set(item.framePhase, (this.inflightPhases.get(item.framePhase) ?? 0) + 1);
      try {
        accepted = this.output.write(chunk, (error) => {
          this.pendingWrites = Math.max(0, this.pendingWrites - 1);
          this.releaseInflightPhase(item.framePhase);
          if (error) this.fail('callback_error', item.framePhase);
          else {
            item.onWritten();
            this.notifyIdle();
          }
        });
      } catch {
        this.pendingWrites = Math.max(0, this.pendingWrites - 1);
        this.releaseInflightPhase(item.framePhase);
        this.fail('write_exception', item.framePhase);
        return;
      }
      if (!accepted) {
        this.writing = true;
        this.output.once('drain', () => {
          this.writing = false;
          this.flush();
        });
        return;
      }
    }
    this.notifyIdle();
  }

  whenDrained(callback) {
    if (!this.writing && this.queue.length === 0 && this.pendingWrites === 0) callback();
    else this.idleCallbacks.push(callback);
  }

  notifyIdle() {
    if (this.writing || this.queue.length > 0 || this.pendingWrites > 0) return;
    const callbacks = this.idleCallbacks.splice(0);
    for (const callback of callbacks) callback();
  }

  releaseInflightPhase(phase) {
    const remaining = (this.inflightPhases.get(phase) ?? 1) - 1;
    if (remaining <= 0) this.inflightPhases.delete(phase);
    else this.inflightPhases.set(phase, remaining);
  }

  singleInflightPhase() {
    return this.inflightPhases.size === 1 ? [...this.inflightPhases.keys()][0] : 'other';
  }

  fail(kind, framePhase = 'other') {
    if (this.closed) return;
    this.closed = true;
    this.queue.length = 0;
    this.queuedBytes = 0;
    this.idleCallbacks.length = 0;
    this.onFailure(kind, ['owner_terminal', 'broker_closed', 'other'].includes(framePhase) ? framePhase : 'other');
  }

  close() {
    this.closed = true;
    this.queue.length = 0;
    this.queuedBytes = 0;
  }
}

export class StrictStreamFramer {
  constructor({ mode, maxLineBytes, maxBufferedBytes, maxTotalOutputBytes = 0, budget, emit }) {
    this.mode = mode;
    this.maxLineBytes = maxLineBytes;
    this.maxBufferedBytes = maxBufferedBytes;
    this.budget = budget ?? { bytes: 0, max: maxBufferedBytes };
    this.maxTotalOutputBytes = maxTotalOutputBytes;
    this.emit = emit;
    this.decoder = new TextDecoder('utf-8', { fatal: true });
    this.pending = Buffer.alloc(0);
    this.totalBytes = 0;
    this.seq = 0;
    this.streamPending = Buffer.alloc(0);
  }

  reserve(bytes) {
    this.budget.bytes += bytes;
    if (this.budget.bytes > this.budget.max) throw new Error('buffer_capacity_exceeded');
  }

  emitTracked(event, rawBytes) {
    this.emit({ ...event, onWritten: () => { this.budget.bytes = Math.max(0, this.budget.bytes - rawBytes); } });
  }

  push(chunk) {
    this.totalBytes += chunk.length;
    if (this.maxTotalOutputBytes > 0 && this.totalBytes > this.maxTotalOutputBytes) throw new Error('output_too_large');
    this.reserve(chunk.length);
    if (this.mode === 'stream') {
      this.streamPending = Buffer.concat([this.streamPending, chunk], this.streamPending.length + chunk.length);
      this.emitStreamPrefix();
      return;
    }
    this.pending = Buffer.concat([this.pending, chunk], this.pending.length + chunk.length);
    this.drainLines();
    if (this.pending.length > this.maxBufferedBytes) throw new Error('buffer_capacity_exceeded');
  }

  emitStreamPrefix() {
    const maxTrailing = Math.min(3, this.streamPending.length);
    for (let trailing = 0; trailing <= maxTrailing; trailing += 1) {
      const prefixLength = this.streamPending.length - trailing;
      try {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(this.streamPending.subarray(0, prefixLength));
        if (prefixLength > 0) {
          this.emitTracked({ text, seq: this.seq++, final: false }, prefixLength);
          this.streamPending = this.streamPending.subarray(prefixLength);
        }
        return;
      } catch { /* try retaining up to three bytes at the UTF-8 boundary */ }
    }
    throw new Error('invalid_response_encoding');
  }

  drainLines() {
    for (;;) {
      const newline = this.pending.indexOf(0x0a);
      if (newline < 0) break;
      let line = this.pending.subarray(0, newline);
      if (line.length > 0 && line.at(-1) === 0x0d) line = line.subarray(0, line.length - 1);
      if (line.length > this.maxLineBytes) throw new Error('line_too_large');
      this.pending = this.pending.subarray(newline + 1);
      let text;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(line); }
      catch { throw new Error('invalid_response_encoding'); }
      this.emitTracked({ text, seq: this.seq++, final: false }, newline + 1);
    }
    if (this.pending.length > this.maxLineBytes) throw new Error('line_too_large');
  }

  finish() {
    if (this.mode === 'stream') {
      let tail;
      try { tail = new TextDecoder('utf-8', { fatal: true }).decode(this.streamPending); }
      catch { throw new Error('invalid_response_encoding'); }
      if (tail.length > 0) {
        const rawBytes = this.streamPending.length;
        this.streamPending = Buffer.alloc(0);
        this.emitTracked({ text: tail, seq: this.seq++, final: false }, rawBytes);
      }
      this.emitTracked({ text: '', seq: this.seq++, final: true }, this.streamPending.length);
      this.streamPending = Buffer.alloc(0);
      return;
    }
    this.drainLines();
    if (this.pending.length > 0) {
      let text;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(this.pending); }
      catch { throw new Error('invalid_response_encoding'); }
      const rawBytes = this.pending.length;
      this.emitTracked({ text, seq: this.seq++, final: true }, rawBytes);
      this.pending = Buffer.alloc(0);
    }
  }
}

export class StdioBroker {
  constructor({ generation = 1, platform = process.platform, output = process.stdout, spawnFn = spawn,
    treeKillerSpawnFn = spawn, hardLimit = OWNER_HARD_LIMIT, termGraceMs = DEFAULT_TERM_GRACE_MS,
    treeRunner,
    testMode = process.env.METIS_STDIO_BROKER_TEST_MODE === '1',
    exit = (code) => process.exit(code),
    parentPidProvider = () => process.ppid,
    attachedStdio = false,
    diagnosticMarkerDirectory = testMode ? process.env.METIS_STDIO_BROKER_DIAGNOSTIC_MARKER ?? '' : '' } = {}) {
    this.generation = generation;
    this.attachedStdio = attachedStdio;
    this.attachedBusinessEnv = attachedStdio ? attachedBusinessEnvironment(process.env, platform) : null;
    this.recoveryDirectory = process.env.METIS_PROCESS_RECOVERY_DIRECTORY ?? '';
    this.recoveryParent = process.env.METIS_PROCESS_RECOVERY_PARENT ?? '';
    this.recoveryKey = process.env.METIS_PROCESS_RECOVERY_BROKER_KEY ?? '';
    this.recoveryBinding = this.recoveryDirectory ? recoveryBinding(this.recoveryDirectory, this.recoveryParent) : '';
    this.recoveryPersistenceFailed = false;
    this.recoveryOwnerSequence = 0;
    this.recoveryClosedRanges = [];
    if (this.recoveryDirectory) {
      publishRecoveryFact(this.recoveryDirectory, this.recoveryKey, 'spawned', this.recoveryParent, process.pid, 0);
    }
    this.platform = platform;
    this.writer = new BrokerWriter(output, { onFailure: (kind, phase) => this.abortForWriterFailure(kind, phase) });
    this.spawnFn = spawnFn;
    this.treeKillerSpawnFn = treeKillerSpawnFn;
    this.treeRunner = treeRunner;
    this.hardLimit = Math.max(1, Math.min(OWNER_HARD_LIMIT, hardLimit));
    this.termGraceMs = termGraceMs;
    this.exit = exit;
    this.parentPidProvider = parentPidProvider;
    this.startParentPid = (() => {
      try {
        const value = this.parentPidProvider();
        return Number.isSafeInteger(value) && value >= 1 ? value : 1;
      } catch { return 1; }
    })();
    this.owners = new Map();
    this.closing = false;
    this.closeFinished = false;
    this.closeAckCallbackSeen = false;
    this.closeEntryCount = 0;
    this.brokerClosedCallbackCount = 0;
    this.ownerTerminalCount = 0;
    this.ownerStartCounts = { service_plugin: 0, pid_probe: 0, lsof_probe: 0, other: 0 };
    this.ownerTerminalCounts = { service_plugin: 0, pid_probe: 0, lsof_probe: 0, other: 0 };
    this.brokerClosedEnqueuedCount = 0;
    this.exitScheduledCount = 0;
    this.lastExitScheduledCode = -1;
    this.pendingExitCode = -1;
    this.exitDispatchPending = false;
    this.exitCommitted = false;
    this.diagnosticSequence = 0;
    this.diagnosticEvents = [];
    this.writerFailureKind = '';
    this.writerFailurePhase = '';
    this.testMode = testMode;
    this.diagnosticMarkerDirectory = this.testMode && typeof diagnosticMarkerDirectory === 'string' &&
      diagnosticMarkerDirectory.length > 0 && diagnosticMarkerDirectory.length <= 4096 &&
      !/[\0\r\n]/u.test(diagnosticMarkerDirectory) ? diagnosticMarkerDirectory : '';
    this.diagnosticMarkerPath = this.diagnosticMarkerDirectory ?
      join(this.diagnosticMarkerDirectory, `broker-g${this.generation}-p${process.pid}.json`) : '';
    this.diagnosticOverflow = false;
    this.diagnosticSlotClaimed = false;
    this.diagnosticEvent('broker_started');
  }

  frame(type, fields = {}, onWritten = () => {}) {
    const value = { type, generation: this.generation, ...fields };
    return this.writer.write(value, onWritten, brokerFramePhase(value));
  }

  diagnostic(status, requestId) {
    this.frame('broker.diagnostic', { status, ...(requestId ? { requestId } : {}) });
  }

  stderrDiagnostic(text, status) {
    if (this.attachedStdio) {
      this.diagnosticEvent(status);
      if (!this.writerFailed) this.diagnostic(status);
      return;
    }
    try { process.stderr.write(text); } catch { /* unavailable */ }
  }

  diagnosticEvent(event) {
    if (!this.diagnosticMarkerPath) return;
    this.diagnosticSequence += 1;
    this.diagnosticEvents.push({ sequence: this.diagnosticSequence, event });
    if (this.diagnosticEvents.length > 16) this.diagnosticEvents.splice(1, 1);
    const observedParentPid = (() => {
      try {
        const value = this.parentPidProvider();
        return Number.isSafeInteger(value) && value >= 1 ? value : 1;
      } catch { return 1; }
    })();
    const value = {
      protocolVersion: '1.0', generation: this.generation, brokerPid: process.pid,
      startParentPid: this.startParentPid, observedParentPid,
      sequence: this.diagnosticSequence, events: this.diagnosticEvents,
      closeEntryCount: this.closeEntryCount,
      closeEntryOwnerCount: this.closeEntryOwnerCount ?? -1,
      ownerTerminalCount: this.ownerTerminalCount, closeAckCallbackSeen: this.closeAckCallbackSeen,
      ownerStartCounts: this.ownerStartCounts, ownerTerminalCounts: this.ownerTerminalCounts,
      brokerClosedEnqueuedCount: this.brokerClosedEnqueuedCount,
      brokerClosedCallbackCount: this.brokerClosedCallbackCount,
      writerFailureKind: this.writerFailureKind, writerFailurePhase: this.writerFailurePhase,
      exitScheduledCount: this.exitScheduledCount, lastExitScheduledCode: this.lastExitScheduledCode,
      closing: this.closing, closeFinished: this.closeFinished, ownerCount: this.owners.size,
    };
    const temporary = `${this.diagnosticMarkerPath}.tmp-${process.pid}`;
    try {
      if (!this.diagnosticSlotClaimed) {
        const state = diagnosticDirectoryState(this.diagnosticMarkerDirectory);
        if (state.unsafe || state.slotCount !== state.identityCount ||
            state.identityCount > DIAGNOSTIC_IDENTITY_LIMIT || existsSync(this.diagnosticMarkerPath)) {
          this.diagnosticOverflow = true;
        } else {
          for (let slot = 0; slot < DIAGNOSTIC_IDENTITY_LIMIT; slot += 1) {
            try {
              mkdirSync(join(this.diagnosticMarkerDirectory, `.identity-slot-${slot}`), { mode: 0o700 });
              this.diagnosticSlotClaimed = true;
              break;
            } catch { /* another broker retained this evidence slot */ }
          }
          if (!this.diagnosticSlotClaimed) this.diagnosticOverflow = true;
        }
      }
      if (this.diagnosticOverflow) {
        const overflowPath = join(this.diagnosticMarkerDirectory, 'overflow.json');
        const overflowTemporary = `${overflowPath}.tmp-${process.pid}`;
        writeFileSync(overflowTemporary, `${JSON.stringify({
          protocolVersion: '1.0', overflow: true, capacity: DIAGNOSTIC_IDENTITY_LIMIT,
          generation: this.generation, brokerPid: process.pid,
          startParentPid: this.startParentPid, observedParentPid,
        })}\n`, { mode: 0o600 });
        renameSync(overflowTemporary, overflowPath);
        return;
      }
      writeFileSync(temporary, `${JSON.stringify(value)}\n`, { mode: 0o600 });
      renameSync(temporary, this.diagnosticMarkerPath);
    } catch { /* test-only diagnostics are non-fatal */ }
  }

  abortForWriterFailure(kind, framePhase = 'other') {
    if (this.writerFailed) return;
    this.writerFailed = true;
    this.writerFailureKind = ['output_error', 'callback_error', 'queue_capacity', 'write_exception'].includes(kind)
      ? kind : 'write_exception';
    this.writerFailurePhase = ['owner_terminal', 'broker_closed', 'other'].includes(framePhase) ? framePhase : 'other';
    this.diagnosticEvent('writer_failure');
    for (const owner of [...this.owners.values()]) this.signalTree(owner, true);
    this.stderrDiagnostic('metis stdio broker protocol writer failed\n', 'protocol_writer_failed');
    this.waitForAllTreesGoneThenExit(70);
  }

  waitForAllTreesGoneThenExit(code, attempt = 0) {
    const live = [...this.owners.values()].filter((owner) => this.treeAlive(owner));
    if (live.length === 0 || attempt >= 160) {
      if (live.length === 0) {
        for (const owner of this.owners.values()) this.publishOwnerTerminal(owner);
        this.publishBrokerTerminal();
      }
      this.scheduleExit(code);
      return;
    }
    for (const owner of live) this.signalTree(owner, true);
    const timer = setTimeout(() => this.waitForAllTreesGoneThenExit(code, attempt + 1), 25);
    timer.unref?.();
  }

  scheduleExit(code) {
    if (this.exitCommitted) return;
    if (this.pendingExitCode < 0 || (this.pendingExitCode === 0 && code !== 0)) {
      this.pendingExitCode = code;
    }
    if (this.exitDispatchPending) return;
    this.exitDispatchPending = true;
    setImmediate(() => {
      if (this.exitCommitted) return;
      this.exitDispatchPending = false;
      this.exitCommitted = true;
      const selected = this.pendingExitCode;
      this.exitScheduledCount += 1;
      this.lastExitScheduledCode = selected;
      this.diagnosticEvent('exit_scheduled');
      this.exit(selected);
    });
  }

  handle(frame) {
    if (!frame || typeof frame !== 'object' || typeof frame.type !== 'string') {
      this.diagnostic('malformed_json');
      return;
    }
    if (frame.type === 'broker.ping') {
      if (!safeRequestId(frame.requestId)) this.diagnostic('invalid_control_frame');
      else this.frame('broker.pong', { requestId: frame.requestId ?? '' });
    } else if (frame.type === 'broker.snapshot') {
      if (!safeRequestId(frame.requestId)) this.diagnostic('invalid_control_frame');
      else this.frame('broker.snapshot', { requestId: frame.requestId ?? '', ownerCount: this.owners.size });
    } else if (frame.type === 'owner.start') {
      this.startOwner(frame);
    } else if (frame.type === 'owner.write') {
      this.writeOwner(frame);
    } else if (frame.type === 'owner.recovery-commit') {
      const owner = this.owners.get(frame.ownerId);
      if (!this.recoveryDirectory || !owner || owner.requestId !== frame.ownerIncarnation || owner.recoveryCommitted) {
        this.diagnostic('invalid_control_frame');
      } else {
        try {
          const pid = Number(owner.child.pid);
          if (!recoveryBirthMatches(this.recoveryDirectory, owner.journalKey, this.recoveryParent, pid,
            this.platform === 'win32' ? 0 : pid)) throw new Error('recovery_record_invalid');
          owner.recoveryCommitted = true;
          if (owner.nativeGate) this.commitNativeGate(owner);
          else {
            owner.child.stdio[3].end('commit\n');
            this.frame('owner.recovery-ready', { ownerId: owner.id, requestId: owner.requestId });
          }
        } catch { this.failOwner(owner, 'recovery_write_failed'); }
      }
    } else if (frame.type === 'owner.stop') {
      if (!safeIdentifier(frame.ownerId) || !safeRequestId(frame.requestId)) this.diagnostic('invalid_control_frame');
      else this.stopOwner(frame.ownerId, normalizeStopReason(frame.reason), frame.requestId);
    } else if (frame.type === 'broker.close') {
      this.closeBroker();
    } else if (frame.type === 'broker.test-hang') {
      if (this.testMode && safeRequestId(frame.requestId)) {
        this.frame('broker.test-hung', { requestId: frame.requestId }, () => {
          for (const owner of this.owners.values()) {
            if (owner.timer) clearTimeout(owner.timer);
            owner.timer = null;
          }
          this.hung = true;
        });
      } else if (this.testMode) this.diagnostic('invalid_control_frame');
      else this.diagnostic('unsupported_frame', frame.requestId);
    } else {
      this.diagnostic('unsupported_frame', frame.requestId);
    }
  }

  startOwner(frame) {
    let reservedKey = '';
    try {
      validateStartFrame(frame);
      if (this.closing) throw new Error('broker_closing');
      if (this.owners.has(frame.ownerId)) throw new Error('duplicate_owner');
      if (this.owners.size >= this.hardLimit) throw new Error('broker_capacity_exceeded');
      const nativeAsset = this.recoveryDirectory && this.platform === 'darwin' ? resolveNativeExecGate() : '';
      const journalKey = `${this.recoveryKey}-o-${++this.recoveryOwnerSequence}`;
      if (this.recoveryDirectory) {
        publishRecoveryFact(this.recoveryDirectory, journalKey, 'intent', this.recoveryParent);
        reservedKey = journalKey;
      }
      const options = normalizedOwnerSpawnOptions(frame, this.platform);
      const gated = Boolean(this.recoveryDirectory);
      if (gated && this.platform === 'win32') throw new Error('recovery_platform_unsupported');
      if (gated) options.stdio.push('pipe');
      if (this.attachedStdio) {
        options.stdio = ['inherit', 'inherit', 'inherit', 'pipe'];
        options.env = { ...this.attachedBusinessEnv };
      }
      const gate = gated && !nativeAsset ? recoveryGateShell(options.env, this.platform) : null;
      if (gate) options.env = gate.env;
      const child = nativeAsset ? this.spawnFn(nativeAsset, [frame.command, ...(frame.args ?? [])], options) : gated ? this.spawnFn('/bin/sh', ['-c',
        gate.script, 'metis-process-gate', frame.command, ...(frame.args ?? [])], options) :
        this.spawnFn(frame.command, frame.args, options);
      const owner = {
        id: frame.ownerId,
        requestId: typeof frame.requestId === 'string' ? frame.requestId : '',
        child,
        journalKey,
        journalSequence: this.recoveryOwnerSequence,
        recoveryCommitted: !gated,
        nativeGate: Boolean(nativeAsset),
        nativeAsset,
        spawnFailure: false,
        gateBuffer: Buffer.alloc(0),
        gateChallenge: '',
        gateAckWritten: false,
        gateEnded: !nativeAsset,
        gateOutcome: null,
        execErrorPublished: false,
        outcomeWriteFailed: false,
        settled: false,
        closed: false,
        spawned: false,
        failureStatus: '',
        stopReason: '',
        timer: null,
        killTimer: null,
        reapTimer: null,
        stdout: null,
        stderr: null,
        totalOutputBytes: 0,
        maxTotalOutputBytes: integer(frame.maxTotalOutputBytes, 0),
        maxBufferedBytes: integer(frame.maxBufferedBytes, DEFAULT_MAX_BUFFERED_BYTES, { minimum: 1 }),
        stdinQueue: [],
        stdinQueuedBytes: 0,
        stdinWriting: false,
        outputBudget: { bytes: 0, max: integer(frame.maxBufferedBytes, DEFAULT_MAX_BUFFERED_BYTES, { minimum: 1 }) },
        diagnosticClass: ownerDiagnosticClass(frame),
      };
      const makeFramer = (stream) => new StrictStreamFramer({
        mode: frame.outputMode ?? 'line',
        maxLineBytes: integer(frame.maxLineBytes, DEFAULT_MAX_LINE_BYTES, { minimum: 1 }),
        maxBufferedBytes: integer(frame.maxBufferedBytes, DEFAULT_MAX_BUFFERED_BYTES, { minimum: 1 }),
        maxTotalOutputBytes: 0,
        budget: owner.outputBudget,
        emit: ({ text, seq, final, onWritten }) => this.frame(`owner.${stream}`, { ownerId: owner.id, text, seq, final }, onWritten),
      });
      owner.stdout = makeFramer('stdout');
      owner.stderr = makeFramer('stderr');
      this.owners.set(owner.id, owner);
      this.ownerStartCounts[owner.diagnosticClass] += 1;
      this.diagnosticEvent('owner_started');
      child.stdout?.on('data', (chunk) => this.consume(owner, owner.stdout, chunk));
      child.stderr?.on('data', (chunk) => this.consume(owner, owner.stderr, chunk));
      child.once('error', (error) => {
        if (owner.nativeGate && !owner.spawned && child.pid === undefined && error instanceof Error &&
            typeof error.code === 'string' && Object.hasOwn(osConstants.errno, error.code)) {
          const number = osConstants.errno[error.code];
          if (Number.isSafeInteger(number) && number > 0 && number <= 2147483647 &&
              error.errno === -number && error.syscall === `spawn ${owner.nativeAsset}`) {
            owner.spawnFailure = true;
            owner.gateOutcome = { phase: 'spawn', error: number };
            owner.failureStatus = 'spawn_failed';
          }
        }
        this.failOwner(owner, 'spawn_failed');
      });
      child.once('close', (code, signal) => {
        owner.closed = true;
        this.finishOwner(owner, code, signal);
      });
      child.once('spawn', () => {
        if (owner.settled) return;
        owner.spawned = true;
        if (this.attachedStdio) {
          // The real child now owns its inherited copies. Keeping our unused copies
          // would hide that child's stdin EPIPE and stdout/stderr EOF from its caller.
          for (const fd of [0, 1, 2]) {
            try { closeSync(fd); } catch (error) {
              if (error?.code !== 'EBADF') { this.failOwner(owner, 'attached_stdio_close_failed'); return; }
            }
          }
        }
        if ((frame.stdinMode ?? 'line') === 'closed') child.stdin?.end();
        const pid = Number(child.pid ?? 0);
        try {
          if (this.recoveryDirectory) publishRecoveryFact(this.recoveryDirectory, owner.journalKey, 'spawned', this.recoveryParent,
            pid, this.platform === 'win32' ? 0 : pid);
        } catch { this.failOwner(owner, 'recovery_write_failed'); return; }
        this.frame('owner.started', {
          ownerId: owner.id, requestId: owner.requestId, pid, pgid: this.platform === 'win32' ? 0 : pid,
          ...(this.recoveryDirectory ? { recoveryKey: owner.journalKey } : {}),
        });
      });
      if (owner.nativeGate) this.observeNativeGate(owner);
      else if (gated) child.stdio[3].on('error', () => this.failOwner(owner, 'recovery_gate_failed'));
      if (frame.deadlineMs > 0) {
        owner.timer = setTimeout(() => this.terminateOwner(owner, 'timed_out'), frame.deadlineMs);
        owner.timer.unref?.();
      }
    } catch (error) {
      // A synchronous factory/setup throw has no libuv no-child receipt.
      if (reservedKey) {
        this.recoveryPersistenceFailed = true;
        const owned = this.owners.get(frame.ownerId);
        if (owned) this.failOwner(owned, 'exec_outcome_unknown');
      }
      const status = stableOwnerError(error instanceof Error ? error.message : 'spawn_failed');
      this.frame('owner.error', {
        ownerId: typeof frame?.ownerId === 'string' ? frame.ownerId : '',
        requestId: typeof frame?.requestId === 'string' ? frame.requestId : '', status,
      });
    }
  }

  commitNativeGate(owner) {
    if (!owner.recoveryCommitted || !owner.gateChallenge || owner.gateAckWritten || owner.gateOutcome || owner.settled) return;
    owner.gateAckWritten = true;
    owner.child.stdio[3].end(`METIS-EXEC-ACK:1:${owner.gateChallenge}\n`, (error) => {
      if (error) {
        owner.gateOutcome = { phase: 'channel', error: 0 };
        this.failOwner(owner, 'exec_outcome_unknown');
      } else this.frame('owner.recovery-ready', { ownerId: owner.id, requestId: owner.requestId });
    });
  }

  isRequestedPreAckStop(owner) {
    return owner.nativeGate && owner.spawned && !owner.spawnFailure &&
      ['broker_closed', 'stopped', 'timed_out'].includes(owner.stopReason) &&
      !owner.recoveryCommitted && !owner.gateAckWritten && !owner.gateOutcome &&
      owner.gateBuffer.length === 0 && ['', 'timed_out'].includes(owner.failureStatus);
  }

  observeNativeGate(owner) {
    const channel = owner.child.stdio[3];
    const unknown = (transportEnd = false) => {
      if (owner.spawnFailure || (transportEnd === true && this.isRequestedPreAckStop(owner))) return;
      owner.gateOutcome = { phase: 'channel', error: 0 };
      this.failOwner(owner, 'exec_outcome_unknown');
    };
    channel.on('data', (chunk) => {
      if (owner.gateEnded || owner.gateOutcome || chunk.some((byte) => byte > 0x7f || byte === 0)) { unknown(); return; }
      owner.gateBuffer = Buffer.concat([owner.gateBuffer, chunk]);
      if (owner.gateBuffer.length > 512) { unknown(); return; }
      for (;;) {
        const newline = owner.gateBuffer.indexOf(10);
        if (newline < 0) break;
        const line = owner.gateBuffer.subarray(0, newline).toString('ascii');
        owner.gateBuffer = owner.gateBuffer.subarray(newline + 1);
        const hello = /^METIS-EXEC-GATE:1:([0-9a-f]{32})$/u.exec(line);
        if (hello && !owner.gateChallenge) {
          owner.gateChallenge = hello[1];
          this.commitNativeGate(owner);
          continue;
        }
        const failed = /^METIS-EXEC-ERROR:1:([0-9a-f]{32}):(exec|setup|protocol):([1-9][0-9]*)$/u.exec(line);
        if (!failed || failed[1] !== (owner.gateChallenge || '00000000000000000000000000000000') ||
            (failed[2] === 'exec' && !owner.gateAckWritten) || !Number.isSafeInteger(Number(failed[3])) ||
            Number(failed[3]) > 2147483647) { unknown(); return; }
        owner.gateOutcome = { phase: failed[2], error: Number(failed[3]) };
        if (owner.gateBuffer.length !== 0) { unknown(); return; }
        break;
      }
    });
    channel.once('end', () => {
      owner.gateEnded = true;
      if (owner.gateBuffer.length !== 0 || (!owner.gateOutcome && (!owner.gateChallenge || !owner.gateAckWritten))) unknown(true);
    });
    channel.once('error', () => unknown());
    channel.once('close', () => { if (!owner.gateEnded) { owner.gateEnded = true; unknown(true); } });
  }

  consume(owner, framer, chunk) {
    if (owner.settled) return;
    try {
      owner.totalOutputBytes += chunk.length;
      if (owner.maxTotalOutputBytes > 0 && owner.totalOutputBytes > owner.maxTotalOutputBytes) {
        throw new Error('output_too_large');
      }
      framer.push(chunk);
    } catch (error) {
      this.failOwner(owner, error instanceof Error ? error.message : 'stream_error');
    }
  }

  writeOwner(frame) {
    const owner = this.owners.get(frame.ownerId);
    const validControl = safeIdentifier(frame.ownerId) && safeRequestId(frame.requestId) &&
      safeIdentifier(frame.ownerIncarnation);
    const requestId = validControl ? (frame.requestId ?? '') : '';
    const ownerIncarnation = validControl ? frame.ownerIncarnation : '';
    if (validControl && owner && frame.ownerIncarnation !== owner.requestId) {
      this.frame('owner.write-rejected', {
        ownerId: frame.ownerId, ownerIncarnation, requestId, status: 'stale_owner_incarnation',
      });
      return;
    }
    if (!validControl || !owner || owner.settled || !owner.spawned || typeof frame.line !== 'string' || /[\0\r\n]/u.test(frame.line)) {
      this.frame('owner.write-rejected', {
        ownerId: validControl ? frame.ownerId : '', ownerIncarnation, requestId, status: 'owner_not_writable',
      });
      return;
    }
    const encoded = `${frame.line}\n`;
    const bytes = Buffer.byteLength(encoded);
    if (owner.stdinQueuedBytes + bytes > owner.maxBufferedBytes) {
      this.frame('owner.write-rejected', {
        ownerId: owner.id, ownerIncarnation: owner.requestId, requestId, status: 'stdin_backpressure_exceeded',
      });
      return;
    }
    owner.stdinQueue.push({ encoded, bytes, requestId, ownerIncarnation: owner.requestId });
    owner.stdinQueuedBytes += bytes;
    this.pumpOwnerStdin(owner);
  }

  pumpOwnerStdin(owner) {
    if (owner.stdinWriting || owner.settled || owner.stdinQueue.length === 0) return;
    owner.stdinWriting = true;
    const item = owner.stdinQueue[0];
    try {
      owner.child.stdin.write(item.encoded, (error) => {
        owner.stdinWriting = false;
        owner.stdinQueue.shift();
        owner.stdinQueuedBytes -= item.bytes;
        if (error) this.failOwner(owner, 'stdin_write_failed');
        else this.frame('owner.written', {
          ownerId: owner.id, ownerIncarnation: item.ownerIncarnation, requestId: item.requestId,
        });
        this.pumpOwnerStdin(owner);
      });
    } catch {
      owner.stdinWriting = false;
      this.failOwner(owner, 'stdin_write_failed');
    }
  }

  finishOwner(owner, code, signal) {
    if (owner.settled) return;
    if (owner.nativeGate && !owner.gateEnded) {
      if (!this.isRequestedPreAckStop(owner)) owner.gateOutcome = { phase: 'channel', error: 0 };
      owner.gateEnded = true;
    }
    if (owner.nativeGate && owner.gateOutcome && (owner.spawned || owner.spawnFailure)) {
      try {
        if (owner.spawnFailure) publishRecoveryFact(this.recoveryDirectory, owner.journalKey, 'not_spawned', this.recoveryParent);
        publishExecError(this, owner);
      }
      catch { owner.outcomeWriteFailed = true; this.recoveryPersistenceFailed = true; }
      owner.failureStatus = ['exec', 'spawn'].includes(owner.gateOutcome.phase) && owner.execErrorPublished ? 'spawn_failed' : 'exec_outcome_unknown';
    }
    try { owner.stdout.finish(); owner.stderr.finish(); }
    catch (error) { owner.failureStatus ||= error instanceof Error ? error.message : 'stream_error'; }
    // The owner is a process group, so a root exit must not leave detached descendants behind.
    this.signalTree(owner, true);
    if (owner.failureStatus === 'timed_out') {
      this.settleAfterTreeGone(owner, 'owner.timeout', { status: 'timed_out', reason: owner.stopReason, exitCode: Number.isInteger(code) ? code : -1 });
    } else if (owner.failureStatus) {
      this.settleAfterTreeGone(owner, 'owner.error', { status: owner.failureStatus, reason: owner.stopReason });
    } else {
      this.settleAfterTreeGone(owner, 'owner.exit', { exitCode: Number.isInteger(code) ? code : -1, signal: signal ?? '' });
    }
  }

  failOwner(owner, status) {
    if (owner.settled) return;
    owner.failureStatus ||= status;
    this.terminateOwner(owner, status);
  }

  stopOwner(ownerId, reason, requestId = '') {
    const owner = this.owners.get(ownerId);
    if (!owner) {
      this.frame('owner.stop-rejected', { ownerId: typeof ownerId === 'string' ? ownerId : '', requestId: String(requestId ?? ''), status: 'owner_not_found' });
      return;
    }
    this.frame('owner.stopping', { ownerId, requestId: String(requestId ?? ''), reason: String(reason) });
    this.terminateOwner(owner, reason);
  }

  terminateOwner(owner, reason) {
    if (owner.settled) return;
    owner.stopReason ||= String(reason);
    if (reason === 'timed_out') owner.failureStatus = 'timed_out';
    else if (!['stopped', 'broker_closed'].includes(reason)) owner.failureStatus ||= String(reason);
    this.signalTree(owner, false);
    owner.killTimer ??= setTimeout(() => {
      if (!owner.settled) {
        this.signalTree(owner, true);
        const type = owner.failureStatus === 'timed_out' ? 'owner.timeout' : owner.failureStatus ? 'owner.error' : 'owner.exit';
        this.settleAfterTreeGone(owner, type, {
          status: owner.failureStatus || 'killed', reason: owner.stopReason, exitCode: -1, signal: 'SIGKILL',
        });
      }
    }, this.termGraceMs);
    owner.killTimer.unref?.();
  }

  signalTree(owner, force) {
    const pid = Number(owner.child.pid ?? 0);
    if (pid <= 0) return;
    if (this.treeRunner) {
      this.treeRunner.terminate(pid, force);
      return;
    }
    try {
      if (this.platform === 'win32') {
        const [command, args] = terminationCommandsForPlatform(this.platform, pid, force)[0];
        const killer = this.treeKillerSpawnFn(command, args, { stdio: 'ignore', windowsHide: true });
        killer.once('error', () => {});
        killer.once('close', () => {});
      } else {
        process.kill(-pid, force ? 'SIGKILL' : 'SIGTERM');
      }
    } catch {
      try { owner.child.kill(force ? 'SIGKILL' : 'SIGTERM'); } catch { /* already gone */ }
    }
  }

  treeAlive(owner) {
    const pid = Number(owner.child.pid ?? 0);
    if (pid <= 0) return Boolean(owner.spawned);
    try {
      if (this.treeRunner) return this.treeRunner.alive(pid);
      process.kill(this.platform === 'win32' ? pid : -pid, 0);
      return true;
    } catch (error) {
      return error?.code !== 'ESRCH';
    }
  }

  settleAfterTreeGone(owner, type, fields, attempt = 0) {
    if (owner.settled) return;
    if (!this.treeAlive(owner) && owner.closed) {
      this.settleOwnerOnce(owner, type, fields);
      return;
    }
    if (attempt >= 160) {
      // Let the Cangjie client observe broker EOF and perform its independent cached-PGID reap.
      this.stderrDiagnostic('metis stdio broker owner reap failed\n', 'owner_reap_failed');
      this.scheduleExit(71);
      return;
    }
    if (attempt % 10 === 0) this.signalTree(owner, true);
    owner.reapTimer = setTimeout(() => this.settleAfterTreeGone(owner, type, fields, attempt + 1), 25);
    owner.reapTimer.unref?.();
  }

  settleOwnerOnce(owner, type, fields) {
    if (owner.settled) return;
    const retainedOutcome = owner.execErrorPublished;
    this.publishOwnerTerminal(owner, !retainedOutcome);
    owner.settled = true;
    if (owner.timer) clearTimeout(owner.timer);
    if (owner.killTimer) clearTimeout(owner.killTimer);
    if (owner.reapTimer) clearTimeout(owner.reapTimer);
    owner.child.stdout?.removeAllListeners();
    owner.child.stderr?.removeAllListeners();
    owner.child.removeAllListeners();
    try { owner.child.stdin.destroy(); } catch { /* closed */ }
    owner.stdinQueue.length = 0;
    owner.stdinQueuedBytes = 0;
    this.owners.delete(owner.id);
    this.ownerTerminalCount += 1;
    this.ownerTerminalCounts[owner.diagnosticClass] += 1;
    this.diagnosticEvent('owner_terminal');
    this.frame(type, { ownerId: owner.id, ...fields }, () => {
      if (retainedOutcome && !this.attachedStdio) this.publishOwnerTerminal(owner, true);
    });
    if (this.closing && this.owners.size === 0) this.finishClose();
  }

  closeBroker() {
    if (this.closing) return;
    this.closing = true;
    this.closeEntryCount += 1;
    this.closeEntryOwnerCount = this.owners.size;
    this.diagnosticEvent('close_entered');
    for (const owner of [...this.owners.values()]) this.terminateOwner(owner, 'broker_closed');
    if (this.owners.size === 0) this.finishClose();
  }

  finishClose() {
    if (this.closeFinished) return;
    this.closeFinished = true;
    this.brokerClosedEnqueuedCount += 1;
    this.diagnosticEvent('broker_closed_enqueued');
    this.frame('broker.closed', { ownerCount: 0 }, () => {
      // Earlier terminal write callbacks finish metadata retirement first.
      this.publishBrokerTerminal();
      this.closeAckCallbackSeen = true;
      this.brokerClosedCallbackCount += 1;
      this.diagnosticEvent('broker_closed_callback');
      this.writer.whenDrained(() => this.scheduleExit(0));
    });
  }

  publishOwnerTerminal(owner, compact = !owner.execErrorPublished) {
    if (!this.recoveryDirectory || owner.outcomeWriteFailed) return;
    try {
      const pid = Number(owner.child.pid ?? 0);
      const closed = this.recoveryClosedRanges.some(([a, b]) => a <= owner.journalSequence && owner.journalSequence <= b);
      if (!closed) {
        if (owner.spawned) publishRecoveryFact(this.recoveryDirectory, owner.journalKey, 'terminal', this.recoveryParent,
          pid, this.platform === 'win32' ? 0 : pid);
        else if (!owner.closed) return;
        else publishRecoveryFact(this.recoveryDirectory, owner.journalKey, 'not_spawned', this.recoveryParent);
        if (!compact) return;
        if (owner.execErrorPublished) publishExecError(this, owner);
        const ranges = mergeClosedSequence(this.recoveryClosedRanges, owner.journalSequence);
        publishClosedCheckpoint(this.recoveryDirectory, this.recoveryKey, this.recoveryParent, this.recoveryOwnerSequence, ranges);
        this.recoveryClosedRanges = ranges;
      }
      if (owner.execErrorPublished) publishExecError(this, owner);
      this.removeClosedOwnerFacts(owner.journalKey);
      if (owner.journalSequence % 32 === 0) this.removeCoveredRecoveryResiduals();
    } catch { this.recoveryPersistenceFailed = true; this.stderrDiagnostic('metis process recovery persistence failed\n', 'recovery_persistence_failed'); }
  }

  removeClosedOwnerFacts(key) {
    let errorRemoved = false;
    const outcome = join(this.recoveryDirectory, `${key}.exec_error`);
    try {
      if (!lstatSync(outcome).isFile() || lstatSync(outcome).isSymbolicLink()) throw new Error('recovery_path_unsafe');
      unlinkSync(outcome); errorRemoved = true;
    } catch (error) { if (error?.code !== 'ENOENT') throw error; }
    if (errorRemoved) {
      const fd = openSync(this.recoveryDirectory, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { fsyncSync(fd); } finally { closeSync(fd); }
    }
    for (const phase of ['intent', 'spawned', 'birth', 'terminal', 'not_spawned']) {
      const path = join(this.recoveryDirectory, `${key}.${phase}`);
      try { if (lstatSync(path).isSymbolicLink()) throw new Error('recovery_path_unsafe'); unlinkSync(path); }
      catch (error) { if (error?.code !== 'ENOENT') throw error; }
    }
  }

  removeCoveredRecoveryResiduals() {
    const prefix = `${this.recoveryKey}-o-`;
    for (const name of readdirSync(this.recoveryDirectory)) {
      if (!name.startsWith(prefix)) continue;
      const match = /^([1-9][0-9]*)\.(intent|spawned|birth|terminal|not_spawned)$/u.exec(name.slice(prefix.length));
      if (!match) continue;
      const sequence = Number(match[1]);
      if (Number.isSafeInteger(sequence) && this.recoveryClosedRanges.some(([a, b]) => a <= sequence && sequence <= b)) {
        if (readdirSync(this.recoveryDirectory).includes(`${prefix}${sequence}.exec_error`)) continue;
        this.removeClosedOwnerFacts(`${prefix}${sequence}`);
      }
    }
  }

  publishBrokerTerminal() {
    if (!this.recoveryDirectory || this.recoveryPersistenceFailed) return;
    try { publishRecoveryFact(this.recoveryDirectory, this.recoveryKey, 'terminal', this.recoveryParent, process.pid, 0); }
    catch { this.stderrDiagnostic('metis process recovery persistence failed\n', 'recovery_persistence_failed'); }
  }
}

export function runBroker({ input = process.stdin, output = process.stdout,
  generation = Number(process.env.METIS_STDIO_BROKER_GENERATION ?? 1), maxInputBytes = DEFAULT_BROKER_INPUT_BYTES,
  installSignalHandlers = true, exit } = {}) {
  const broker = new StdioBroker({ generation, output, ...(exit ? { exit } : {}) });
  const owner = helperParentBinding();
  if (!owner.matches()) { broker.closeBroker(); return broker; }
  const watcher = setInterval(() => { if (!owner.matches()) broker.closeBroker(); }, 20);
  watcher.unref();
  process.once('exit', () => clearInterval(watcher));
  broker.frame('broker.hello', { pid: process.pid, ownerLimit: OWNER_HARD_LIMIT });
  let pending = Buffer.alloc(0);
  const handleLine = (bytes) => {
    let line;
    try { line = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
    catch { broker.diagnostic('invalid_response_encoding'); return; }
    if (line.length === 0) return;
    try { broker.handle(JSON.parse(line)); } catch { broker.diagnostic('malformed_json'); }
  };
  input.on('data', (chunk) => {
    if (broker.hung) return;
    pending = Buffer.concat([pending, chunk], pending.length + chunk.length);
    if (pending.length > maxInputBytes) {
      broker.diagnostic('broker_input_too_large');
      pending = Buffer.alloc(0);
      return;
    }
    for (;;) {
      const newline = pending.indexOf(0x0a);
      if (newline < 0) break;
      const line = pending.subarray(0, newline);
      pending = pending.subarray(newline + 1);
      handleLine(line);
      if (broker.hung) {
        pending = Buffer.alloc(0);
        break;
      }
    }
  });
  input.once('end', () => {
    if (pending.length > 0) {
      try { new TextDecoder('utf-8', { fatal: true }).decode(pending); broker.diagnostic('malformed_json'); }
      catch { broker.diagnostic('invalid_response_encoding'); }
      pending = Buffer.alloc(0);
    }
    broker.closeBroker();
  });
  input.once('error', () => broker.closeBroker());
  if (installSignalHandlers) {
    process.once('SIGTERM', () => broker.closeBroker());
    process.once('SIGINT', () => broker.closeBroker());
  }
  return broker;
}

/** Original parent raw byte/terminal streams; no protocol frame reaches those descriptors. */
function helperParentBinding() {
  const declared = process.env.METIS_PROCESS_RECOVERY_OWNER_PID;
  const birth = process.env.METIS_PROCESS_RECOVERY_OWNER_BIRTH;
  const expected = declared === undefined ? process.ppid : Number(declared);
  const valid = Number.isSafeInteger(expected) && expected > 1 &&
    (declared === undefined || (String(expected) === declared &&
      typeof birth === 'string' && new RegExp(`^${expected}:[1-9][0-9]*:(?:0|[1-9][0-9]{0,5})$`, 'u').test(birth)));
  return { matches: () => valid && process.ppid === expected };
}

export function runAttachedBroker(command, args) {
  if (!process.env.METIS_PROCESS_RECOVERY_DIRECTORY || !command) throw new Error('recovery_context_missing');
  let broker;
  let resultCode = 125;
  let ownerStarted = false;
  let pendingOwner = false;
  const sink = new Writable({ write(chunk, _encoding, done) {
    // Consume one bounded broker frame immediately; never retain output or decode business bytes.
    try {
      const frame = JSON.parse(String(chunk));
      if (frame.type === 'owner.started') pendingOwner = true;
      if (['owner.exit', 'owner.error', 'owner.timeout'].includes(frame.type)) {
        const signalCode = typeof frame.signal === 'string' ? osConstants.signals[frame.signal] : undefined;
        resultCode = Number.isSafeInteger(frame.exitCode) && frame.exitCode >= 0 && frame.exitCode <= 255
          ? frame.exitCode : Number.isSafeInteger(signalCode) ? signalCode : 125;
        broker.closeBroker();
      }
    } catch { /* the private protocol sink has no business output */ }
    done();
  }});
  broker = new StdioBroker({ generation: 1, output: sink, attachedStdio: true,
    exit: (code) => process.exit(code === 0 ? resultCode : code) });
  const owner = helperParentBinding();
  if (!owner.matches()) { broker.closeBroker(); return broker; }
  const hasBirth = (key, pid, pgid) => recoveryBirthMatches(broker.recoveryDirectory, key, broker.recoveryParent, pid, pgid);
  const watcher = setInterval(() => {
    if (!owner.matches()) { broker.closeBroker(); return; }
    if (broker.closing) return;
    if (!ownerStarted && hasBirth(broker.recoveryKey, process.pid, 0)) {
      ownerStarted = true;
      broker.startOwner({ type: 'owner.start', ownerId: 'attached', requestId: 'attached-start', command, args });
    }
    const childPid = Number(broker.owners.get('attached')?.child.pid ?? 0);
    if (pendingOwner && hasBirth(`${broker.recoveryKey}-o-1`, childPid, childPid)) {
      pendingOwner = false;
      broker.handle({ type: 'owner.recovery-commit', ownerId: 'attached', ownerIncarnation: 'attached-start' });
    }
  }, 20);
  process.once('SIGTERM', () => broker.closeBroker());
  process.once('SIGINT', () => broker.closeBroker());
  process.once('exit', () => clearInterval(watcher));
  return broker;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === '--attached') runAttachedBroker(process.argv[3], process.argv.slice(4));
  else runBroker();
}
