import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const EXPECTED_ALLOWLIST = Object.freeze([
  {
    file: 'src/process/managed_stdio_broker.cj',
    functions: ['ensureBrokerRunning', 'readBrokerOutput'],
    factId: 'BROKER_BOUNDARY',
  },
  {
    file: 'src/core/tools/gateway_sessions_toolset.cj',
    functions: ['launchManagedAcpRun', 'launchManagedSubagentRun'],
    factId: 'MT-22',
  },
  {
    file: 'src/lsp/json_rpc_client.cj',
    functions: ['init', 'doReceiving', 'readLine', 'readContent', 'close'],
    factId: 'MT-22',
  },
  {
    file: 'src/sandbox/sandbox_docker.cj',
    functions: ['imageExists', 'pullImage'],
    factId: 'MT-22',
  },
]);

function stripCommentsAndStrings(source) {
  const output = [...source];
  let state = 'code';
  let quote = '';
  let blockDepth = 0;
  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1] ?? '';
    if (state === 'line-comment') {
      if (current === '\n') state = 'code';
      else output[index] = ' ';
      continue;
    }
    if (state === 'block-comment') {
      if (current === '/' && next === '*') {
        output[index] = output[index + 1] = ' ';
        blockDepth += 1;
        index += 1;
      } else if (current === '*' && next === '/') {
        output[index] = output[index + 1] = ' ';
        blockDepth -= 1;
        index += 1;
        if (blockDepth === 0) state = 'code';
      } else if (current !== '\n') {
        output[index] = ' ';
      }
      continue;
    }
    if (state === 'string') {
      if (current === '\\') {
        output[index] = ' ';
        if (index + 1 < output.length && source[index + 1] !== '\n') output[index + 1] = ' ';
        index += 1;
      } else if (current === quote) {
        output[index] = ' ';
        state = 'code';
      } else if (current !== '\n') {
        output[index] = ' ';
      }
      continue;
    }
    if (current === '/' && next === '/') {
      output[index] = output[index + 1] = ' ';
      state = 'line-comment';
      index += 1;
    } else if (current === '/' && next === '*') {
      output[index] = output[index + 1] = ' ';
      state = 'block-comment';
      blockDepth = 1;
      index += 1;
    } else if (current === '"' || current === "'") {
      output[index] = ' ';
      state = 'string';
      quote = current;
    }
  }
  return output.join('');
}

function lineNumberAt(source, index) {
  let line = 1;
  for (let offset = 0; offset < index; offset += 1) {
    if (source[offset] === '\n') line += 1;
  }
  return line;
}

function functionRanges(source) {
  const starts = [];
  const declaration = /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(|\binit\s*\(/g;
  for (const match of source.matchAll(declaration)) {
    const name = match[1] ?? 'init';
    const brace = source.indexOf('{', match.index + match[0].length);
    if (brace < 0) continue;
    let depth = 1;
    let end = source.length;
    for (let index = brace + 1; index < source.length; index += 1) {
      if (source[index] === '{') depth += 1;
      else if (source[index] === '}') depth -= 1;
      if (depth === 0) {
        end = index + 1;
        break;
      }
    }
    starts.push({ name, start: match.index, end });
  }
  return starts;
}

function ownerFunction(ranges, index) {
  let owner = null;
  for (const range of ranges) {
    if (range.start <= index && index < range.end && (!owner || range.start > owner.start)) owner = range;
  }
  return owner?.name ?? '<top-level>';
}

function collectPatternHits(source, pattern, kind, ranges, file) {
  const hits = [];
  for (const match of source.matchAll(pattern)) {
    hits.push({ file, function: ownerFunction(ranges, match.index), line: lineNumberAt(source, match.index), kind });
  }
  return hits;
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

export function validateFactAllowlist(entries = EXPECTED_ALLOWLIST) {
  const normalize = (entry) => `${entry.file}|${entry.functions.join(',')}|${entry.factId}`;
  for (const entry of entries) {
    assert.equal(entry.file.includes('*'), false, `wildcard allowlist file: ${entry.file}`);
    assert.equal(entry.functions.some((name) => name.includes('*')), false, `wildcard allowlist function: ${entry.file}`);
    assert.ok(entry.factId === 'MT-22' || entry.factId === 'BROKER_BOUNDARY', `missing Fact ID: ${entry.file}`);
  }
  assert.deepEqual(entries.map(normalize), EXPECTED_ALLOWLIST.map(normalize), 'pipe allowlist drifted');
  return true;
}

export async function scanProductionPipeInventory(root = projectRoot, allowlist = EXPECTED_ALLOWLIST) {
  validateFactAllowlist(allowlist);
  const allowByFile = new Map(allowlist.map((entry) => [entry.file, entry]));
  const inventory = [];
  const declarations = new Map();
  for (const absolutePath of await productionFiles(root)) {
    const file = relative(root, absolutePath).split('\\').join('/');
    const stripped = stripCommentsAndStrings(await readFile(absolutePath, 'utf8'));
    const ranges = functionRanges(stripped);
    declarations.set(file, new Set(ranges.map((range) => range.name)));
    const hasChildPipe = /ProcessRedirect\.Pipe|(^|[^A-Za-z0-9_.])Pipe(?![A-Za-z0-9_])|\.(?:stdOutPipe|stdErrPipe)\b/m.test(stripped);
    inventory.push(...collectPatternHits(stripped, /ProcessRedirect\.Pipe/g, 'qualified_pipe', ranges, file));
    inventory.push(...collectPatternHits(stripped, /(^|[^A-Za-z0-9_.])Pipe(?![A-Za-z0-9_])/gm, 'unqualified_pipe', ranges, file));
    inventory.push(...collectPatternHits(stripped, /\.(?:stdOutPipe|stdErrPipe)\b/g, 'child_pipe_reader', ranges, file));
    if (hasChildPipe) {
      inventory.push(...collectPatternHits(stripped, /\.(?:readln|readToEnd)\s*\(/g, 'blocking_child_reader', ranges, file));
    }
  }

  for (const entry of allowlist) {
    const declared = declarations.get(entry.file);
    assert.ok(declared, `allowlisted file missing: ${entry.file}`);
    for (const name of entry.functions) assert.ok(declared.has(name), `allowlisted function missing: ${entry.file}::${name}`);
  }
  for (const hit of inventory) {
    const entry = allowByFile.get(hit.file);
    assert.ok(entry, `unknown direct child pipe: ${hit.file}:${hit.line} ${hit.function} ${hit.kind}`);
    assert.ok(entry.functions.includes(hit.function), `direct child pipe moved outside allowlist: ${hit.file}:${hit.line} ${hit.function}`);
  }
  return inventory;
}

async function fixtureRoot(files) {
  const root = await mkdtemp(join(tmpdir(), 'metis-pipe-boundary-'));
  for (const [file, source] of Object.entries(files)) {
    const target = join(root, file);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, source);
  }
  return root;
}

test('P3-P6 production pipe inventory has one broker boundary and exact MT-22 facts', async (t) => {
  const inventory = await scanProductionPipeInventory();
  t.diagnostic(inventory.map((hit) => `${hit.file}:${hit.line} ${hit.function} ${hit.kind}`).join('\n'));
  assert.ok(inventory.some((hit) => hit.file === 'src/process/managed_stdio_broker.cj'));
  assert.deepEqual(
    [...new Set(inventory.filter((hit) => hit.file !== 'src/process/managed_stdio_broker.cj').map((hit) => hit.file))].sort(),
    EXPECTED_ALLOWLIST.filter((entry) => entry.factId === 'MT-22').map((entry) => entry.file).sort(),
  );
});

test('P3-N6 comments, strings, HTTP bodies, and file readers are not child-pipe hits', async (t) => {
  const root = await fixtureRoot({
    'src/process/managed_stdio_broker.cj': 'func ensureBrokerRunning() { launch("node", [], stdOut: ProcessRedirect.Pipe) }\nfunc readBrokerOutput() { process.stdOutPipe.readln() }',
    'src/core/tools/gateway_sessions_toolset.cj': 'func launchManagedAcpRun() {}\nfunc launchManagedSubagentRun() {}',
    'src/lsp/json_rpc_client.cj': 'class X { init() {} func doReceiving() {} func readLine() {} func readContent() {} func close() {} }',
    'src/sandbox/sandbox_docker.cj': 'func imageExists() {}\nfunc pullImage() {}',
    'src/false_positive.cj': 'func readHttp() { let text = "ProcessRedirect.Pipe spawn { reader.readToEnd() }"; /* Pipe */ // process.stdOutPipe\n file.readln() }',
    'src/ignored_test.cj': 'func testFixture() { launch("x", [], stdOut: ProcessRedirect.Pipe) }',
  });
  t.after(() => rm(root, { recursive: true, force: true }));
  const inventory = await scanProductionPipeInventory(root);
  assert.equal(inventory.some((hit) => hit.file === 'src/false_positive.cj'), false);
});

test('P3-N6 rejects unknown qualified, unqualified, and blocking child-reader shapes', async (t) => {
  for (const source of [
    'func rogue() { launch("x", [], stdOut: ProcessRedirect.Pipe) }',
    'func rogue() { launch("x", [], stdOut: Pipe) }',
    'func rogue() { let child = launch("x", [], stdOut: ProcessRedirect.Pipe); spawn { child.stdOutPipe.readToEnd() } }',
  ]) {
    const root = await fixtureRoot({
      'src/process/managed_stdio_broker.cj': 'func ensureBrokerRunning() {}\nfunc readBrokerOutput() {}',
      'src/core/tools/gateway_sessions_toolset.cj': 'func launchManagedAcpRun() {}\nfunc launchManagedSubagentRun() {}',
      'src/lsp/json_rpc_client.cj': 'class X { init() {} func doReceiving() {} func readLine() {} func readContent() {} func close() {} }',
      'src/sandbox/sandbox_docker.cj': 'func imageExists() {}\nfunc pullImage() {}',
      'src/rogue.cj': source,
    });
    t.after(() => rm(root, { recursive: true, force: true }));
    await assert.rejects(scanProductionPipeInventory(root), /unknown direct child pipe/);
  }
});

test('P3-N6 rejects allowlist drift, missing Fact IDs, wildcards, and function migration', async (t) => {
  assert.throws(() => validateFactAllowlist([...EXPECTED_ALLOWLIST, { file: 'src/new.cj', functions: ['run'], factId: 'MT-22' }]), /drifted/);
  assert.throws(() => validateFactAllowlist([{ file: 'src/**', functions: ['*'], factId: '' }]), /wildcard/);
  assert.throws(
    () => validateFactAllowlist(EXPECTED_ALLOWLIST.map((entry, index) => index === 1 ? { ...entry, factId: '' } : entry)),
    /missing Fact ID/,
  );
  const root = await fixtureRoot({
    'src/process/managed_stdio_broker.cj': 'func ensureBrokerRunning() {}\nfunc readBrokerOutput() {}',
    'src/core/tools/gateway_sessions_toolset.cj': 'func launchManagedAcpRun() {}\nfunc launchManagedSubagentRun() {}\nfunc moved() { launch("x", [], stdOut: ProcessRedirect.Pipe) }',
    'src/lsp/json_rpc_client.cj': 'class X { init() {} func doReceiving() {} func readLine() {} func readContent() {} func close() {} }',
    'src/sandbox/sandbox_docker.cj': 'func imageExists() {}\nfunc pullImage() {}',
  });
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(scanProductionPipeInventory(root), /moved outside allowlist/);
});
