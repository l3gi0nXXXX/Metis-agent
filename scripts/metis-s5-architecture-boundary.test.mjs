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
  let gcmDurableQueueOwner = false;
  let gcmDurableQueueStatuses = false;
  let gcmStdoutFrameSink = false;
  for (const [project, root] of [['metis', metis], ['gcm', gcm]]) {
    for (const path of await productionFiles(root)) {
      const relativePath = relative(root, path).split('\\').join('/');
      const file = `${project}:${relativePath}`;
      const source = await readFile(path, 'utf8');
      const code = maskCommentsAndStrings(source);
      const literals = stringLiterals(source);
      if (project === 'gcm' && /\b(?:import|package)\s+metis\.gateway\b/.test(code)) hits.push(`${file}:metis_gateway_dependency`);
      if (project === 'gcm' && /\b(?:import|package)\s+[^\n]*(?:telegram|feishu)\b/i.test(code)) hits.push(`${file}:metis_im_dependency`);
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
        for (const call of callArguments(source, ['File\\.writeTo', 'Directory\\.create', 'rename'])) {
          const joined = stringLiterals(call).join(' ').toLowerCase();
          if (/(?:gitcodemonitor|gitcode-monitor)/.test(joined) &&
              /(?:awaiting-host|host-frame|webhook-queue|\/pending|\/processed)/.test(joined)) {
            hits.push(`${file}:gcm_spool_owner`);
          }
        }
      } else {
        if (relativePath === 'src/webhook_queue.cj') {
          gcmDurableQueueOwner = /\bclass\s+WebhookQueue\b/.test(code);
          gcmDurableQueueStatuses = ['pending', 'awaiting-host', 'processed', 'host-frame']
            .every((status) => literals.includes(status));
        }
        const outputCalls = code.match(/\b(?:stdout\.(?:write|writeln)|print|println)\s*\(/g) ?? [];
        if (relativePath === 'src/main.cj') {
          const uncommented = maskComments(source);
          const pluginReturn = /if\s*\(\s*commandArgs\.size\s*>\s*0\s*&&\s*commandArgs\[0\]\s*==\s*["']plugin-stdio["']\s*\)\s*\{\s*return\s+gcmPluginMain\s*\(/.exec(uncommented);
          const firstOutput = /\b(?:stdout\.(?:write|writeln)|print|println)\s*\(/.exec(code);
          const directStdout = code.match(/\bstdout\.(?:write|writeln)\s*\(/g) ?? [];
          if (directStdout.length > 0) hits.push(`${file}:main_direct_stdout`);
          if (!pluginReturn || (firstOutput && pluginReturn.index >= firstOutput.index)) {
            hits.push(`${file}:main_plugin_stdout_guard_missing`);
          }
        } else if (outputCalls.length > 0 && relativePath !== 'src/plugin_runtime.cj') {
          hits.push(`${file}:stdout_outside_frame_sink`);
        }
        if (relativePath === 'src/plugin_runtime.cj') {
          const canonicalCalls = code.match(/\bstdout\.writeln\s*\(\s*line\s*\)/g) ?? [];
          gcmStdoutFrameSink = /\bclass\s+GcmStdoutLineSink\b/.test(code) &&
            outputCalls.length === 1 && canonicalCalls.length === 1;
          if (outputCalls.length !== 1 || canonicalCalls.length !== 1) {
            hits.push(`${file}:stdout_frame_sink_not_unique`);
          }
        }
      }
    }
  }
  if (!gcmDurableQueueOwner) hits.push('gcm:src/webhook_queue.cj:durable_queue_owner_missing');
  if (!gcmDurableQueueStatuses) hits.push('gcm:src/webhook_queue.cj:durable_queue_statuses_missing');
  if (!gcmStdoutFrameSink) hits.push('gcm:src/plugin_runtime.cj:stdout_frame_sink_missing');
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

function validGcmFixture(extra = {}) {
  return {
    'webhook_queue.cj': 'class WebhookQueue { let states = ["pending", "awaiting-host", "processed", "host-frame"] }\n',
    'plugin_runtime.cj': 'class GcmStdoutLineSink { func send(line: String) { stdout.writeln(line) } }\n',
    ...extra,
  };
}

async function expectArchitectureTag(t, metisFiles, gcmFiles, tag) {
  const metis = await fixtureRoot(metisFiles);
  const gcm = await fixtureRoot(gcmFiles);
  t.after(() => Promise.all([rm(metis, { recursive: true, force: true }), rm(gcm, { recursive: true, force: true })]));
  await assert.rejects(scanS5Architecture(metis, gcm), (error) => {
    assert.ok(error.message.includes(tag), `missing architecture tag ${tag}: ${error.message}`);
    return true;
  });
}

test('S5-U1 both production trees preserve the architecture boundary', async () => {
  assert.notEqual(gcmRootText.trim(), '');
  await scanS5Architecture(metisRoot, gcmRoot);
});

test('S5-U1 rejects a GCM dependency on Metis gateway code', async (t) => {
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    validGcmFixture({ 'bad.cj': 'package sample\nimport metis.gateway.runtime.runGatewayCli\n' }),
    'metis_gateway_dependency',
  );
});

test('S5-U1 rejects a GCM dependency on Metis IM implementations', async (t) => {
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    validGcmFixture({ 'bad.cj': 'package sample\nimport sample.telegram.Client\n' }),
    'metis_im_dependency',
  );
});

test('S5-U1 rejects Metis readers of GCM business logs without substring false positives', async (t) => {
  await expectArchitectureTag(
    t,
    {
      'bad.cj': 'func bad() { let x = File.readFrom(Path("gitcodemonitor-business.log")) }',
      'comment.cj': '// File.readFrom(Path("gcm.log"))\nfunc ok() { let x = "gitcodemonitor.log" }',
    },
    validGcmFixture(),
    'gcm_business_log_reader',
  );
});

test('S5-U1 rejects Metis ownership of the GCM durable spool', async (t) => {
  await expectArchitectureTag(
    t,
    { 'spool.cj': 'func badSpool() { Directory.create(Path("gitcode-monitor/awaiting-host")) }' },
    validGcmFixture(),
    'gcm_spool_owner',
  );
});

test('S5-U1 rejects production fixed port, private path, secret, and allowlist drift', async (t) => {
  const metis = await fixtureRoot({ 'bad.cj': 'let port = 18080\nlet token = "fake-s5-openai-key"\n' });
  const gcm = await fixtureRoot(validGcmFixture({ 'bad.cj': 'let root = "/Users/example/Metis/src"\n' }));
  t.after(() => Promise.all([rm(metis, { recursive: true, force: true }), rm(gcm, { recursive: true, force: true })]));
  await assert.rejects(scanS5Architecture(metis, gcm), /fixed_18080|embedded_s5_secret|private_metis_path/);
  await assert.rejects(scanS5Architecture(metis, gcm, ['wildcard']), /allowlist drifted/);
});

test('S5-U1 requires GCM durable queue ownership and statuses', async (t) => {
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    { 'plugin_runtime.cj': validGcmFixture()['plugin_runtime.cj'] },
    'durable_queue_owner_missing',
  );
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    validGcmFixture({ 'webhook_queue.cj': 'class WebhookQueue { let states = ["pending"] }\n' }),
    'durable_queue_statuses_missing',
  );
});

test('S5-U1 permits exactly one canonical stdout frame sink call', async (t) => {
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    validGcmFixture({ 'rogue_stdout.cj': 'func bad(line: String) { stdout.writeln(line) }\n' }),
    'stdout_outside_frame_sink',
  );
  for (const rogueCall of ['stdout.write(line)', 'stdout.writeln(line)', 'print(line)', 'println(line)']) {
    await expectArchitectureTag(
      t,
      { 'ok.cj': 'package sample\n' },
      validGcmFixture({
        'plugin_runtime.cj': `class GcmStdoutLineSink { func send(line: String) { stdout.writeln(line) } func rogue(line: String) { ${rogueCall} } }\n`,
      }),
      'stdout_frame_sink_not_unique',
    );
  }
});

test('S5-U1 requires main to enter plugin stdio before any CLI output', async (t) => {
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    validGcmFixture({
      'main.cj': 'main(args: Array<String>): Int64 { println("too early"); if (args.size > 0 && args[0] == "plugin-stdio") { return gcmPluginMain([]) }; return 0 }\n',
    }),
    'main_plugin_stdout_guard_missing',
  );
  await expectArchitectureTag(
    t,
    { 'ok.cj': 'package sample\n' },
    validGcmFixture({
      'main.cj': 'main(args: Array<String>): Int64 { if (args.size > 0 && args[0] == "plugin-stdio") { return gcmPluginMain([]) }; stdout.writeln("cli"); return 0 }\n',
    }),
    'main_direct_stdout',
  );
});
