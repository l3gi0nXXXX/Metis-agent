import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const metisRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REQUIRED_FILES = Object.freeze([
  'src/gateway/core/gateway_session_store.cj',
  'src/core/prompting/metis_workspace_bootstrap.cj',
  'src/gateway/core/gateway_agent_reply_outcome.cj',
  'src/gateway/core/agent_bridge.cj',
]);

function maskCangjieLexical(source) {
  const output = source.split('');
  let state = 'code';
  let blockDepth = 0;
  let quote = '';
  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1] ?? '';
    const triple = source.slice(index, index + 3);
    if (state === 'line-comment') {
      if (current === '\n') state = 'code';
      else output[index] = ' ';
    } else if (state === 'block-comment') {
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
    } else if (state === 'triple-string') {
      if (triple === quote.repeat(3)) {
        output[index] = output[index + 1] = output[index + 2] = ' ';
        index += 2;
        state = 'code';
      } else if (current !== '\n') {
        output[index] = ' ';
      }
    } else if (state === 'string') {
      output[index] = current === '\n' ? '\n' : ' ';
      if (current === '\\') {
        if (index + 1 < output.length) output[++index] = ' ';
      } else if (current === quote) {
        state = 'code';
      }
    } else if (current === '/' && next === '/') {
      output[index] = output[index + 1] = ' ';
      state = 'line-comment';
      index += 1;
    } else if (current === '/' && next === '*') {
      output[index] = output[index + 1] = ' ';
      state = 'block-comment';
      blockDepth = 1;
      index += 1;
    } else if (triple === '"""' || triple === "'''") {
      output[index] = output[index + 1] = output[index + 2] = ' ';
      quote = current;
      state = 'triple-string';
      index += 2;
    } else if (current === '"' || current === "'") {
      output[index] = ' ';
      quote = current;
      state = 'string';
    }
  }
  return output.join('');
}

function matchingBrace(masked, open) {
  let depth = 1;
  for (let index = open + 1; index < masked.length; index += 1) {
    if (masked[index] === '{') depth += 1;
    else if (masked[index] === '}' && --depth === 0) return index;
  }
  throw new Error('unclosed_function_scope');
}

function uniqueFunctionScope(source, name) {
  const masked = maskCangjieLexical(source);
  const pattern = new RegExp(`\\bfunc\\s+${name}\\s*\\(`, 'g');
  const matches = [...masked.matchAll(pattern)];
  assert.equal(matches.length, 1, `anchor_${name}_count_${matches.length}`);
  const open = masked.indexOf('{', matches[0].index + matches[0][0].length);
  assert.notEqual(open, -1, `anchor_${name}_body_missing`);
  const close = matchingBrace(masked, open);
  return {
    source: source.slice(matches[0].index, close + 1),
    masked: masked.slice(matches[0].index, close + 1),
  };
}

function assertNoFullRead(scope, name) {
  assert.equal(/\bFile\.readFrom\s*\(/.test(scope.masked), false, `${name}_full_read`);
}

function assertAgentCorrectionIsLazy(scope) {
  const calls = [...scope.masked.matchAll(/\btoolExecutionTracker\.correctionContext\s*\(\s*\)/g)];
  assert.equal(calls.length, 1, `agent_correction_context_count_${calls.length}`);
  const builder = scope.masked.indexOf('existingContextBuilder: Some({');
  assert.notEqual(builder, -1, 'agent_builder_anchor_missing');
  const open = scope.masked.indexOf('{', builder);
  const close = matchingBrace(scope.masked, open);
  assert.ok(calls[0].index > open && calls[0].index < close, 'agent_correction_context_eager');
}

export async function scanS2Architecture(root) {
  const session = await readFile(join(root, REQUIRED_FILES[0]), 'utf8');
  const bootstrap = await readFile(join(root, REQUIRED_FILES[1]), 'utf8');
  const outcome = await readFile(join(root, REQUIRED_FILES[2]), 'utf8');
  const agent = await readFile(join(root, REQUIRED_FILES[3]), 'utf8');

  const recent = uniqueFunctionScope(session, 'loadRecentHistoryLines');
  assertNoFullRead(recent, 'recent_history');
  assert.match(recent.masked, /\bFile\s*\(\s*path\s*,\s*OpenMode\.Read\s*\)/, 'recent_history_stream_missing');
  assert.match(recent.masked, /\bframer\.accept\s*\(/, 'recent_history_framer_missing');

  const load = uniqueFunctionScope(bootstrap, 'loadContextFile');
  assertNoFullRead(load, 'bootstrap_load');
  assert.match(load.masked, /\bmetisScanBoundedBootstrapSource\s*\(/, 'bootstrap_stream_missing');
  const resolveUncached = uniqueFunctionScope(bootstrap, 'resolveContextFilesDetailedUncached');
  assertNoFullRead(resolveUncached, 'bootstrap_resolve');
  assert.match(resolveUncached.masked, /\baddLoadedContextFile\s*\(/, 'bootstrap_bounded_loader_missing');

  const correction = uniqueFunctionScope(outcome, 'gatewayRunFinalAnswerCorrection');
  const gate = correction.masked.indexOf('if (!first.recoverable)');
  const earlyReturn = correction.masked.indexOf('return first', gate);
  const builder = correction.masked.indexOf('case Some(builder)');
  assert.ok(gate >= 0 && earlyReturn > gate && builder > earlyReturn, 'correction_builder_before_recoverable_gate');

  assertAgentCorrectionIsLazy(uniqueFunctionScope(agent, 'replyWithOutcome'));
  return true;
}

async function copyCandidate(mutator = (_path, source) => source) {
  const root = await mkdtemp(join(tmpdir(), 'metis-s2-architecture-'));
  for (const relative of REQUIRED_FILES) {
    const destination = join(root, relative);
    await mkdir(dirname(destination), { recursive: true });
    const source = await readFile(join(metisRoot, relative), 'utf8');
    await writeFile(destination, mutator(relative, source));
  }
  return root;
}

async function expectMutationFailure(t, mutator, pattern) {
  const root = await copyCandidate(mutator);
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(scanS2Architecture(root), pattern);
}

test('ARCH-S2-01 current source preserves bounded and lazy scopes', async () => {
  await scanS2Architecture(metisRoot);
});

test('ARCH-S2-01 lexical scope ignores legal outside reads and braces in comments and strings', async (t) => {
  const root = await copyCandidate((relative, source) => {
    if (relative !== REQUIRED_FILES[1]) return source;
    const anchor = 'func loadContextFile(path: Path): MetisBoundedBootstrapSource {';
    const lexical = `${anchor}\n    // 🙂 } File.readFrom(path)\n    /* emoji🙂 { nested /* } */ } */\n    let braceText = "emoji🙂 escaped \\\" { }"\n`;
    return source.replace(anchor, lexical) + '\nfunc legalDebugRead(path: Path): Unit { let _ = File.readFrom(path) }\n';
  });
  t.after(() => rm(root, { recursive: true, force: true }));
  await scanS2Architecture(root);
});

test('ARCH-S2-01 each architecture rule has a discriminating mutation', async (t) => {
  const cases = [
    {
      name: 'recent history rejects a scoped full read',
      pattern: /recent_history_full_read/,
      mutate: (relative, source) => relative === REQUIRED_FILES[0]
        ? source.replace('public func loadRecentHistoryLines(sessionKey: String, maxEntries: Int64): GatewayRecentHistoryLoadResult {',
          'public func loadRecentHistoryLines(sessionKey: String, maxEntries: Int64): GatewayRecentHistoryLoadResult {\nlet _ = File.readFrom(path)')
        : source,
    },
    {
      name: 'bootstrap loader rejects a scoped full read',
      pattern: /bootstrap_load_full_read/,
      mutate: (relative, source) => relative === REQUIRED_FILES[1]
        ? source.replace('func loadContextFile(path: Path): MetisBoundedBootstrapSource {',
          'func loadContextFile(path: Path): MetisBoundedBootstrapSource {\nlet _ = File.readFrom(path)')
        : source,
    },
    {
      name: 'bootstrap resolver rejects a scoped full read',
      pattern: /bootstrap_resolve_full_read/,
      mutate: (relative, source) => relative === REQUIRED_FILES[1]
        ? source.replace('): MetisBootstrapBudgetResult {\n    let files = ArrayList<MetisBoundedBootstrapSource>()',
          '): MetisBootstrapBudgetResult {\n    let _ = File.readFrom(workspaceDir)\n    let files = ArrayList<MetisBoundedBootstrapSource>()')
        : source,
    },
    {
      name: 'bootstrap loader requires its stream anchor',
      pattern: /bootstrap_stream_missing/,
      mutate: (relative, source) => relative === REQUIRED_FILES[1]
        ? source.replace('metisScanBoundedBootstrapSource(', 'removedBoundedBootstrapSource(')
        : source,
    },
    {
      name: 'bootstrap resolver requires its bounded loader anchor',
      pattern: /bootstrap_bounded_loader_missing/,
      mutate: (relative, source) => relative === REQUIRED_FILES[1]
        ? source.replaceAll('addLoadedContextFile(files,', 'removedLoadedContextFile(files,')
        : source,
    },
    {
      name: 'correction builder cannot precede the recoverable gate',
      pattern: /correction_builder_before_recoverable_gate/,
      mutate: (relative, source) => relative === REQUIRED_FILES[2]
        ? source.replace('let firstGuard = normalizeGatewayAssistantFinalReply',
          'case Some(builder) => ()\n    let firstGuard = normalizeGatewayAssistantFinalReply')
        : source,
    },
    {
      name: 'agent rejects eager correction context materialization',
      pattern: /agent_correction_context_count_2|agent_correction_context_eager/,
      mutate: (relative, source) => relative === REQUIRED_FILES[3]
        ? source.replace('let toolExecutionTracker = GatewayToolExecutionTracker()',
          'let toolExecutionTracker = GatewayToolExecutionTracker()\n            let _ = toolExecutionTracker.correctionContext()')
        : source,
    },
    {
      name: 'renamed anchors fail closed',
      pattern: /anchor_loadContextFile_count_0/,
      mutate: (relative, source) => relative === REQUIRED_FILES[1]
        ? source.replace('func loadContextFile(', 'func renamedLoadContextFile(')
        : source,
    },
    {
      name: 'duplicate anchors fail closed',
      pattern: /anchor_loadContextFile_count_2/,
      mutate: (relative, source) => {
        if (relative !== REQUIRED_FILES[1]) return source;
        return `${source}\n${uniqueFunctionScope(source, 'loadContextFile').source}\n`;
      },
    },
  ];
  for (const entry of cases) {
    await t.test(entry.name, async (subtest) => {
      await expectMutationFailure(subtest, entry.mutate, entry.pattern);
    });
  }
});
