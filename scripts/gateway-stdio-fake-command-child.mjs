import { spawn } from 'node:child_process';
import { appendFileSync, existsSync, writeFileSync } from 'node:fs';

const [mode = 'unicode', ...args] = process.argv.slice(2);

function writeRepeated(stream, byte, size) {
  const chunk = Buffer.alloc(Math.min(64 * 1024, size), byte);
  let remaining = size;
  while (remaining > 0) {
    const length = Math.min(chunk.length, remaining);
    stream.write(chunk.subarray(0, length));
    remaining -= length;
  }
}

function ignoreTermination() {
  process.on('SIGTERM', () => {});
  process.on('SIGINT', () => {});
}

switch (mode) {
  case 'unicode':
    process.stdout.write('中文🙂stdout');
    process.stderr.write('中文🚀stderr');
    break;
  case 'burst': {
    const size = Number.parseInt(args[0] ?? '262144', 10);
    writeRepeated(process.stdout, 0x6f, size);
    writeRepeated(process.stderr, 0x65, size);
    break;
  }
  case 'tagged-burst': {
    const tag = args[0] ?? 'missing-tag';
    const size = Number.parseInt(args[1] ?? '262144', 10);
    process.stdout.write(`stdout-${tag}-中文🙂:`);
    writeRepeated(process.stdout, 0x6f, size);
    process.stderr.write(`stderr-${tag}-中文🚀:`);
    writeRepeated(process.stderr, 0x65, size);
    break;
  }
  case 'bytes': {
    const size = Number.parseInt(args[0] ?? '0', 10);
    writeRepeated(process.stdout, 0x78, size);
    break;
  }
  case 'invalid-stdout':
    process.stdout.write(Buffer.from([0x66, 0x6f, 0x80]));
    break;
  case 'invalid-stderr':
    process.stderr.write(Buffer.from([0x65, 0x72, 0x80]));
    break;
  case 'delay': {
    const delayMs = Number.parseInt(args[0] ?? '1000', 10);
    setTimeout(() => process.stdout.write('late'), delayMs);
    break;
  }
  case 'wait-release': {
    const [readyPath, releasePath] = args;
    if (!readyPath || !releasePath) throw new Error('ready and release paths are required');
    appendFileSync(readyPath, `${process.pid}\n`, { mode: 0o600 });
    const timer = setInterval(() => {
      if (!existsSync(releasePath)) return;
      clearInterval(timer);
      process.stdout.write('released-中文🙂');
      process.stderr.write('released-诊断🚀');
    }, 5);
    break;
  }
  case 'ignore-term':
    ignoreTermination();
    setInterval(() => {}, 1000);
    break;
  case 'ignore-term-tree': {
    const pidPath = args[0];
    if (!pidPath) throw new Error('pid path is required');
    if (args[1]) appendFileSync(args[1], 'x', { mode: 0o600 });
    ignoreTermination();
    const descendant = spawn(process.execPath, [new URL(import.meta.url).pathname, 'ignore-term'], {
      detached: false,
      stdio: ['ignore', 'inherit', 'inherit'],
    });
    writeFileSync(pidPath, `${process.pid}\n${descendant.pid}\n`, { mode: 0o600 });
    setInterval(() => {}, 1000);
    break;
  }
  case 'exit':
    process.stdout.write(args[1] ?? '');
    process.stderr.write(args[2] ?? '');
    process.exitCode = Number.parseInt(args[0] ?? '0', 10);
    break;
  case 'tts-output':
    if (!args[1]) throw new Error('tts output path is required');
    writeFileSync(args[1], args[0] ?? '', { mode: 0o600 });
    break;
  case 'lifecycle.health':
    process.stdout.write(JSON.stringify({ ok: true, status: 'ready', text: '中文🙂sidecar' }));
    break;
  case '--input':
    process.stdout.write(JSON.stringify({
      ok: true,
      status: 'ok',
      text: '中文🙂pdf',
      pageCount: 1,
      selectedPages: [1],
      images: [],
      warnings: [],
    }));
    break;
  default:
    process.stderr.write('unknown fake command mode');
    process.exitCode = 64;
}
