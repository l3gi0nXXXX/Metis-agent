import { appendFileSync, existsSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';

const mode = process.argv[2] ?? 'success';

function integerArg(index, fallback = 0) {
  const value = Number.parseInt(process.argv[index] ?? '', 10);
  return Number.isFinite(value) ? value : fallback;
}

function ignoreTerm() {
  process.on('SIGTERM', () => {});
}

if (mode === 'success') {
  process.stdout.write('cron-stdout-中文🙂');
  process.stderr.write('cron-stderr-中文🙂');
} else if (mode === 'nonzero') {
  process.stderr.write('cron-failure-中文🙂');
  process.exitCode = integerArg(3, 7);
} else if (mode === 'bytes') {
  process.stdout.write(Buffer.alloc(integerArg(3), 0x61));
} else if (mode === 'dual-burst') {
  const count = integerArg(3, 32);
  const tag = process.argv[4] ?? 'untagged';
  for (let index = 0; index < count; index += 1) {
    process.stdout.write(`${tag}-out-${index}-中文🙂\n`);
    process.stderr.write(`${tag}-err-${index}-中文🙂\n`);
  }
} else if (mode === 'sensitive') {
  process.stdout.write('TOKEN=cron-secret-value /Users/private-cron-user/jobs/task 中文🙂');
  process.stderr.write('Authorization: Bearer cron-secret-authorization-value');
} else if (mode === 'invalid-utf8') {
  process.stdout.write(Buffer.from([0xc3, 0x28]));
} else if (mode === 'wait-release') {
  const readyPath = process.argv[3];
  const releasePath = process.argv[4];
  writeFileSync(readyPath, `${process.pid}\n`);
  const timer = setInterval(() => {
    if (existsSync(releasePath)) {
      clearInterval(timer);
      process.stdout.write('released-中文🙂');
    }
  }, 5);
} else if (mode === 'hang-tree-child') {
  ignoreTerm();
  appendFileSync(process.argv[3], `child=${process.pid},pgid=${process.env.METIS_FAKE_CRON_PGID ?? ''}\n`);
  setInterval(() => {}, 1000);
} else if (mode === 'hang-tree') {
  ignoreTerm();
  const pidPath = process.argv[3];
  const lateMarkerPath = process.argv[4];
  writeFileSync(pidPath, `root=${process.pid},pgid=${process.pid}\n`);
  spawn(process.execPath, [new URL(import.meta.url).pathname, 'hang-tree-child', pidPath], {
    stdio: ['ignore', 'inherit', 'inherit'],
    env: { ...process.env, METIS_FAKE_CRON_PGID: String(process.pid) },
  });
  if (lateMarkerPath) {
    setTimeout(() => writeFileSync(lateMarkerPath, 'late-owner-replayed\n'), 5000);
  }
  setInterval(() => {}, 1000);
} else {
  process.stderr.write('unknown fake cron mode');
  process.exitCode = 64;
}
