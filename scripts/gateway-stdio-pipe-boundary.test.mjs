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
    functions: ['ensureBrokerRunning', 'readBrokerOutput', 'ManagedStdioBrokerClient.ensureBrokerStarted'],
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
    expectsPipe: false,
  },
  // G1 R-S1-L-U1/U3 and Magic M-U1/N1/P2: neutral provider/capture owns these pipes.
  {
    file: 'src/process/managed_magic_process.cj',
    functions: ['ManagedMagicLaunchProvider.launch', 'ManagedMagicOwnedHandle.stdOutPipe.get', 'ManagedMagicOwnedHandle.stdErrPipe.get'],
    factId: 'OWNED_PROCESS_BOUNDARY',
  },
  {
    file: 'src/process/managed_owned_child.cj',
    functions: [
      'ManagedSdkChild.init', 'ManagedSdkChild.stdOutPipe.get', 'ManagedSdkChild.stdErrPipe.get',
      'ManagedNoContextChild.init', 'managedNativeLaunch',
      'ManagedRecoveryChild.stdOutPipe.get', 'ManagedRecoveryChild.stdErrPipe.get',
      'managedCaptureWithoutContext', 'managedRecoveryExecuteWithOutput',
      'managedRecoveryExecuteHandoffWithOutput', 'managedOwnedCapture',
    ],
    factId: 'OWNED_PROCESS_BOUNDARY',
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

function blockRange(source, start, afterDeclaration) {
  const brace = source.indexOf('{', afterDeclaration);
  if (brace < 0) return null;
  let depth = 1;
  for (let index = brace + 1; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    else if (source[index] === '}') depth -= 1;
    if (depth === 0) return { start, brace, end: index + 1 };
  }
  return null;
}

function functionRanges(source) {
  const classes = [];
  for (const match of source.matchAll(/\bclass\s+([A-Za-z_][A-Za-z0-9_]*)/g)) {
    const range = blockRange(source, match.index, match.index + match[0].length);
    if (range) classes.push({ ...range, name: match[1] });
  }
  const classAt = (index) => classes.filter((range) => range.start <= index && index < range.end)
    .sort((left, right) => right.start - left.start)[0];
  const starts = [];
  const declaration = /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(|\binit\s*\(/g;
  for (const match of source.matchAll(declaration)) {
    const range = blockRange(source, match.index, match.index + match[0].length);
    if (!range) continue;
    const name = match[1] ?? 'init';
    const owner = classAt(match.index);
    starts.push({ ...range, name, scope: owner ? `${owner.name}.${name}` : name });
  }
  // A property get is a distinct owner, never the generic name "get" or top-level.
  for (const match of source.matchAll(/\bprop\s+([A-Za-z_][A-Za-z0-9_]*)\s*:/g)) {
    const property = blockRange(source, match.index, match.index + match[0].length);
    if (!property) continue;
    const owner = classAt(match.index);
    if (!owner) continue;
    const body = source.slice(property.brace + 1, property.end - 1);
    for (const getter of body.matchAll(/\bget\s*\(/g)) {
      const start = property.brace + 1 + getter.index;
      const range = blockRange(source, start, start + getter[0].length);
      if (range && range.end <= property.end) {
        const name = `${match[1]}.get`;
        starts.push({ ...range, name, scope: `${owner.name}.${name}` });
      }
    }
  }
  return starts;
}

function ownerFunction(ranges, index) {
  let owner = null;
  for (const range of ranges) {
    if (range.start <= index && index < range.end && (!owner || range.start > owner.start)) owner = range;
  }
  return owner ?? { name: '<top-level>', scope: '<top-level>' };
}

function collectPatternHits(source, pattern, kind, ranges, file) {
  const hits = [];
  for (const match of source.matchAll(pattern)) {
    const owner = ownerFunction(ranges, match.index);
    hits.push({ file, function: owner.name, scope: owner.scope, line: lineNumberAt(source, match.index), kind });
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
  const normalize = (entry) => `${entry.file}|${entry.functions.join(',')}|${entry.factId}|${entry.expectsPipe !== false}`;
  for (const entry of entries) {
    assert.equal(entry.file.includes('*'), false, `wildcard allowlist file: ${entry.file}`);
    assert.equal(entry.functions.some((name) => name.includes('*')), false, `wildcard allowlist function: ${entry.file}`);
    assert.ok(entry.factId === 'MT-22' || entry.factId === 'BROKER_BOUNDARY' || entry.factId === 'OWNED_PROCESS_BOUNDARY', `missing Fact ID: ${entry.file}`);
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
    declarations.set(file, {
      names: new Set(ranges.map((range) => range.name)),
      scopes: new Set(ranges.map((range) => range.scope)),
    });
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
    for (const name of entry.functions) {
      const present = entry.factId === 'OWNED_PROCESS_BOUNDARY' || name.includes('.')
        ? declared.scopes.has(name) : declared.names.has(name);
      assert.ok(present, `allowlisted function missing: ${entry.file}::${name}`);
    }
  }
  for (const hit of inventory) {
    const entry = allowByFile.get(hit.file);
    assert.ok(entry, `unknown direct child pipe: ${hit.file}:${hit.line} ${hit.function} ${hit.kind}`);
    const permitted = entry.functions.includes(hit.scope) ||
      (entry.factId !== 'OWNED_PROCESS_BOUNDARY' && entry.functions.includes(hit.function));
    assert.ok(permitted, `direct child pipe moved outside allowlist: ${hit.file}:${hit.line} ${hit.scope}`);
  }
  return inventory;
}

function neutralOwnershipFixtureFiles() {
  return {
    'src/process/managed_magic_process.cj': [
      'class ManagedMagicOwnedHandle {',
      'prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } }',
      'prop stdErrPipe: InputStream { get() { this.child.stdErrPipe } }',
      '}',
      'class ManagedMagicLaunchProvider { func launch() { launch("x", [], stdOut: ProcessRedirect.Pipe) } }',
    ].join('\n'),
    'src/process/managed_owned_child.cj': [
      'class ManagedSdkChild { init() {} prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } } prop stdErrPipe: InputStream { get() { this.child.stdErrPipe } } }',
      'class ManagedNoContextChild { init() {} }',
      'class ManagedRecoveryChild { prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } } prop stdErrPipe: InputStream { get() { this.child.stdErrPipe } } }',
      'func managedNativeLaunch() {}',
      'func managedCaptureWithoutContext() {}',
      'func managedRecoveryExecuteWithOutput() {}',
      'func managedRecoveryExecuteHandoffWithOutput() {}',
      'func managedOwnedCapture() { child.stdOutPipe.readToEnd() }',
    ].join('\n'),
  };
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
    EXPECTED_ALLOWLIST.filter((entry) => entry.file !== 'src/process/managed_stdio_broker.cj' && entry.expectsPipe !== false).map((entry) => entry.file).sort(),
  );
});

test('P3-N6 comments, strings, HTTP bodies, and file readers are not child-pipe hits', async (t) => {
  const root = await fixtureRoot({
    ...neutralOwnershipFixtureFiles(),
    'src/process/managed_stdio_broker.cj': 'class ManagedStdioBrokerClient { func ensureBrokerStarted() { launch("node", [], stdOut: ProcessRedirect.Pipe) } }\nfunc ensureBrokerRunning() { launch("node", [], stdOut: ProcessRedirect.Pipe) }\nfunc readBrokerOutput() { process.stdOutPipe.readln() }',
    'src/core/tools/gateway_sessions_toolset.cj': 'func launchManagedAcpRun() {}\nfunc launchManagedSubagentRun() {}',
    'src/lsp/json_rpc_client.cj': 'class X { init() {} func doReceiving() {} func readLine() {} func readContent() {} func close() {} }',
    'src/sandbox/sandbox_docker.cj': 'func imageExists() {}\nfunc pullImage() {}',
    'src/false_positive.cj': 'func readHttp() { let text = "ProcessRedirect.Pipe spawn { reader.readToEnd() }"; /* Pipe */ // process.stdOutPipe\n file.readln() }',
    'src/ignored_test.cj': 'func testFixture() { launch("x", [], stdOut: ProcessRedirect.Pipe) }',
  });
  t.after(() => rm(root, { recursive: true, force: true }));
  const inventory = await scanProductionPipeInventory(root);
  assert.equal(inventory.some((hit) => hit.file === 'src/false_positive.cj'), false);
  assert.ok(inventory.some((hit) => hit.scope === 'ManagedMagicOwnedHandle.stdOutPipe.get'));
  assert.ok(inventory.some((hit) => hit.scope === 'ManagedMagicLaunchProvider.launch'));
  assert.ok(inventory.some((hit) => hit.scope === 'ManagedStdioBrokerClient.ensureBrokerStarted'));
  assert.equal(inventory.some((hit) => hit.scope === '<top-level>'), false);
});

test('P3-N6 rejects unknown qualified, unqualified, and blocking child-reader shapes', async (t) => {
  for (const source of [
    'func rogue() { launch("x", [], stdOut: ProcessRedirect.Pipe) }',
    'func rogue() { launch("x", [], stdOut: Pipe) }',
    'func rogue() { let child = launch("x", [], stdOut: ProcessRedirect.Pipe); spawn { child.stdOutPipe.readToEnd() } }',
  ]) {
    const root = await fixtureRoot({
      ...neutralOwnershipFixtureFiles(),
      'src/process/managed_stdio_broker.cj': 'class ManagedStdioBrokerClient { func ensureBrokerStarted() { launch("node", [], stdOut: ProcessRedirect.Pipe) } }\nfunc ensureBrokerRunning() {}\nfunc readBrokerOutput() {}',
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
    ...neutralOwnershipFixtureFiles(),
    'src/process/managed_stdio_broker.cj': 'class ManagedStdioBrokerClient { func ensureBrokerStarted() { launch("node", [], stdOut: ProcessRedirect.Pipe) } }\nfunc ensureBrokerRunning() {}\nfunc readBrokerOutput() {}',
    'src/core/tools/gateway_sessions_toolset.cj': 'func launchManagedAcpRun() {}\nfunc launchManagedSubagentRun() {}\nfunc moved() { launch("x", [], stdOut: ProcessRedirect.Pipe) }',
    'src/lsp/json_rpc_client.cj': 'class X { init() {} func doReceiving() {} func readLine() {} func readContent() {} func close() {} }',
    'src/sandbox/sandbox_docker.cj': 'func imageExists() {}\nfunc pullImage() {}',
  });
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(scanProductionPipeInventory(root), /moved outside allowlist/);

  assert.throws(
    () => validateFactAllowlist(EXPECTED_ALLOWLIST.map((entry) => entry.expectsPipe === false ? { ...entry, expectsPipe: true } : entry)),
    /drifted/,
  );
  const neutral = neutralOwnershipFixtureFiles();
  const magicFile = 'src/process/managed_magic_process.cj';
  const ownedFile = 'src/process/managed_owned_child.cj';
  const brokerFile = 'src/process/managed_stdio_broker.cj';
  const brokerSource = 'class ManagedStdioBrokerClient { func ensureBrokerStarted() {} }\nfunc ensureBrokerRunning() {}\nfunc readBrokerOutput() {}';
  const mutants = [
    [brokerFile, `${brokerSource}\nclass ForeignBroker { func ensureBrokerStarted() { launch("x", [], stdOut: ProcessRedirect.Pipe) } }`, /moved outside allowlist/],
    [brokerFile, brokerSource.replace('class ManagedStdioBrokerClient', 'class MissingBroker'), /allowlisted function missing/],
    [magicFile, `${neutral[magicFile]}\nclass ForeignProvider { func launch() { launch("x", [], stdOut: ProcessRedirect.Pipe) } }`, /moved outside allowlist/],
    [ownedFile, `${neutral[ownedFile]}\nclass ForeignChild { init() { launch("x", [], stdOut: ProcessRedirect.Pipe) } }`, /moved outside allowlist/],
    [magicFile, `${neutral[magicFile]}\nclass ForeignHandle { prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } } }`, /moved outside allowlist/],
    [magicFile, neutral[magicFile].replace('class ManagedMagicOwnedHandle {', 'class ManagedMagicOwnedHandle { prop other: InputStream { get() { this.child.stdOutPipe } }'), /moved outside allowlist/],
    [magicFile, `${neutral[magicFile]}\nlet rogue = child.stdOutPipe`, /moved outside allowlist/],
    [ownedFile, `${neutral[ownedFile]}\nclass ForeignNative { func managedNativeLaunch() { launch("x", [], stdOut: ProcessRedirect.Pipe) } }`, /moved outside allowlist/],
    [magicFile, `${neutral[magicFile]}\nfunc get() { child.stdOutPipe }`, /moved outside allowlist/],
    [ownedFile, `${neutral[ownedFile]}\nfunc movedCapture() { child.stdOutPipe.readToEnd() }`, /moved outside allowlist/],
    [ownedFile, neutral[ownedFile].replace('func managedNativeLaunch() {}', 'class ForeignNative { func managedNativeLaunch() {} }'), /allowlisted function missing/],
    [magicFile, neutral[magicFile].replace('func launch()', 'func missingLaunch()'), /allowlisted function missing/],
    [magicFile, neutral[magicFile].replace('prop stdOutPipe:', 'prop missingPipe:'), /allowlisted function missing/],
  ];
  for (const [file, source, expected] of mutants) {
    const mutatedRoot = await fixtureRoot({
      ...neutral,
      'src/process/managed_stdio_broker.cj': 'class ManagedStdioBrokerClient { func ensureBrokerStarted() { launch("node", [], stdOut: ProcessRedirect.Pipe) } }\nfunc ensureBrokerRunning() {}\nfunc readBrokerOutput() {}',
      'src/core/tools/gateway_sessions_toolset.cj': 'func launchManagedAcpRun() {}\nfunc launchManagedSubagentRun() {}',
      'src/lsp/json_rpc_client.cj': 'class X { init() {} func doReceiving() {} func readLine() {} func readContent() {} func close() {} }',
      'src/sandbox/sandbox_docker.cj': 'func imageExists() {}\nfunc pullImage() {}',
      [file]: source,
    });
    t.after(() => rm(mutatedRoot, { recursive: true, force: true }));
    await assert.rejects(scanProductionPipeInventory(mutatedRoot), expected);
  }
});
