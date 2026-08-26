import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const metisRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const gcmRootText = process.env.METIS_S5_GCM_ROOT ?? '';
const gcmRoot = resolve(gcmRootText);
const EMPTY_ALLOWLIST = Object.freeze([]);

function maskComments(source) {
  const output = [...source];
  let state = 'code';
  let depth = 0;
  let quote = '';
  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1] ?? '';
    if (state === 'line') {
      if (current === '\n') state = 'code';
      else output[index] = ' ';
    } else if (state === 'block') {
      if (current === '/' && next === '*') {
        output[index] = output[index + 1] = ' ';
        depth += 1;
        index += 1;
      } else if (current === '*' && next === '/') {
        output[index] = output[index + 1] = ' ';
        depth -= 1;
        index += 1;
        if (depth === 0) state = 'code';
      } else if (current !== '\n') output[index] = ' ';
    } else if (state === 'string') {
      if (current === '\\') index += 1;
      else if (current === quote) state = 'code';
    } else if (current === '/' && next === '/') {
      output[index] = output[index + 1] = ' ';
      state = 'line';
      index += 1;
    } else if (current === '/' && next === '*') {
      output[index] = output[index + 1] = ' ';
      state = 'block';
      depth = 1;
      index += 1;
    } else if (current === '"' || current === "'") {
      state = 'string';
      quote = current;
    }
  }
  return output.join('');
}

function maskCommentsAndStrings(source) {
  const commentsMasked = maskComments(source);
  const output = [...commentsMasked];
  let quote = '';
  for (let index = 0; index < commentsMasked.length; index += 1) {
    const current = commentsMasked[index];
    if (quote) {
      if (current === '\\') {
        output[index] = ' ';
        if (index + 1 < output.length) output[index + 1] = ' ';
        index += 1;
      } else if (current === quote) {
        output[index] = ' ';
        quote = '';
      } else if (current !== '\n') output[index] = ' ';
    } else if (current === '"' || current === "'") {
      output[index] = ' ';
      quote = current;
    }
  }
  return output.join('');
}

function stringLiterals(source) {
  const masked = maskComments(source);
  const values = [];
  for (let index = 0; index < masked.length; index += 1) {
    const quote = masked[index];
    if (quote !== '"' && quote !== "'") continue;
    let value = '';
    for (index += 1; index < masked.length; index += 1) {
      const current = masked[index];
      if (current === '\\') {
        value += current;
        if (index + 1 < masked.length) value += masked[++index];
      } else if (current === quote) {
        break;
      } else {
        value += current;
      }
    }
    values.push(value);
  }
  return values;
}

function callArguments(source, names) {
  const calls = [];
  const code = maskComments(source);
  const pattern = new RegExp(`\\b(?:${names.join('|')})\\s*\\(`, 'g');
  for (const match of code.matchAll(pattern)) {
    let depth = 1;
    let quote = '';
    let end = match.index + match[0].length;
    for (; end < code.length; end += 1) {
      const current = code[end];
      if (quote) {
        if (current === '\\') end += 1;
        else if (current === quote) quote = '';
      } else if (current === '"' || current === "'") quote = current;
      else if (current === '(') depth += 1;
      else if (current === ')' && --depth === 0) break;
    }
    calls.push(code.slice(match.index, end + 1));
  }
  return calls;
}

async function productionFiles(root) {
  const files = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile() && entry.name.endsWith('.cj') && !entry.name.endsWith('_test.cj')) files.push(path);
    }
  }
  await visit(join(root, 'src'));
  return files.sort();
}

export async function scanS5Architecture(metis, gcm, allowlist = EMPTY_ALLOWLIST) {
  assert.deepEqual(allowlist, EMPTY_ALLOWLIST, 'S5 architecture allowlist drifted');
  const hits = [];
  for (const [project, root] of [['metis', metis], ['gcm', gcm]]) {
    for (const path of await productionFiles(root)) {
      const file = `${project}:${relative(root, path).split('\\').join('/')}`;
      const source = await readFile(path, 'utf8');
      const code = maskCommentsAndStrings(source);
      const literals = stringLiterals(source);
      if (project === 'gcm' && /\b(?:import|package)\s+metis\.gateway\b/.test(code)) hits.push(`${file}:metis_gateway_dependency`);
      if (/\b18080\b/.test(code)) hits.push(`${file}:fixed_18080`);
      for (const literal of literals) {
        if (/\/Users\/[^\s]+\/Metis(?:\/|$)/.test(literal)) hits.push(`${file}:private_metis_path`);
        if (/fake-s5-(?:openai-key|gitcode-token|webhook-token)|123456:FAKE-S5/.test(literal)) hits.push(`${file}:embedded_s5_secret`);
      }
      if (project === 'metis') {
        for (const call of callArguments(source, ['File\\.readFrom', 'readLines', 'executeWithOutput'])) {
          const joined = stringLiterals(call).join(' ').toLowerCase();
          if (/(?:gcm|gitcodemonitor|gitcode-monitor)/.test(joined) && /(?:\.log|stdout|stderr|business[-_ ]?log)/.test(joined)) {
            hits.push(`${file}:gcm_business_log_reader`);
          }
        }
      }
    }
  }
  assert.deepEqual(hits, [], `S5 architecture boundary drifted:\n${hits.join('\n')}`);
  return true;
}

async function fixtureRoot(files) {
  const root = await mkdtemp(join(tmpdir(), 'metis-s5-architecture-'));
  for (const [file, source] of Object.entries(files)) {
    const path = join(root, 'src', file);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, source);
  }
  return root;
}

test('S5-U1 both production trees preserve the architecture boundary', async () => {
  assert.notEqual(gcmRootText.trim(), '');
  await scanS5Architecture(metisRoot, gcmRoot);
});

test('S5-U1 rejects a GCM dependency on Metis gateway code', async (t) => {
  const metis = await fixtureRoot({ 'ok.cj': 'package sample\n' });
  const gcm = await fixtureRoot({ 'bad.cj': 'package sample\nimport metis.gateway.runtime.runGatewayCli\n' });
  t.after(() => Promise.all([rm(metis, { recursive: true, force: true }), rm(gcm, { recursive: true, force: true })]));
  await assert.rejects(scanS5Architecture(metis, gcm), /metis_gateway_dependency/);
});

test('S5-U1 rejects Metis readers of GCM business logs without substring false positives', async (t) => {
  const metis = await fixtureRoot({
    'bad.cj': 'func bad() { let x = File.readFrom(Path("gitcodemonitor-business.log")) }',
    'comment.cj': '// File.readFrom(Path("gcm.log"))\nfunc ok() { let x = "gitcodemonitor.log" }',
  });
  const gcm = await fixtureRoot({ 'ok.cj': 'package sample\n' });
  t.after(() => Promise.all([rm(metis, { recursive: true, force: true }), rm(gcm, { recursive: true, force: true })]));
  await assert.rejects(scanS5Architecture(metis, gcm), /gcm_business_log_reader/);
});

test('S5-U1 rejects production fixed port, private path, secret, and allowlist drift', async (t) => {
  const metis = await fixtureRoot({ 'bad.cj': 'let port = 18080\nlet token = "fake-s5-openai-key"\n' });
  const gcm = await fixtureRoot({ 'bad.cj': 'let root = "/Users/example/Metis/src"\n' });
  t.after(() => Promise.all([rm(metis, { recursive: true, force: true }), rm(gcm, { recursive: true, force: true })]));
  await assert.rejects(scanS5Architecture(metis, gcm), /fixed_18080|embedded_s5_secret|private_metis_path/);
  await assert.rejects(scanS5Architecture(metis, gcm, ['wildcard']), /allowlist drifted/);
});
