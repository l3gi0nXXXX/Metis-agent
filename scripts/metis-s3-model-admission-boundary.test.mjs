import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const metisRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FILES = Object.freeze({
  turn: 'src/gateway/core/gateway_session_turn_runner.cj',
  cronBridge: 'src/gateway/runtime/cron_bridge_reply.cj',
  cronRunner: 'src/gateway/runtime/cron_runner.cj',
  cronNext: 'src/cron/cron_job_next.cj',
  service: 'src/gateway/core/gateway_service.cj',
  dispatcher: 'src/gateway/service_plugin/service_plugin_event_dispatcher.cj',
  agent: 'src/gateway/core/agent_bridge.cj',
  http: 'src/gateway/runtime/gateway_http_surface.cj',
  coreFixture: 'src/gateway/core/gateway_model_memory_admission_package_test.cj',
  runtimeFixture: 'src/gateway/runtime/gateway_model_memory_admission_package_test.cj',
  config: 'cjpm.toml',
});
const REQUIRED_FILES = Object.freeze(Object.values(FILES));

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
      if (current === '\n') state = 'code'; else output[index] = ' ';
    } else if (state === 'block-comment') {
      if (current === '/' && next === '*') {
        output[index] = output[index + 1] = ' '; blockDepth += 1; index += 1;
      } else if (current === '*' && next === '/') {
        output[index] = output[index + 1] = ' '; blockDepth -= 1; index += 1;
        if (blockDepth === 0) state = 'code';
      } else if (current !== '\n') output[index] = ' ';
    } else if (state === 'triple-string') {
      if (triple === quote.repeat(3)) {
        output[index] = output[index + 1] = output[index + 2] = ' '; index += 2; state = 'code';
      } else if (current !== '\n') output[index] = ' ';
    } else if (state === 'string') {
      output[index] = current === '\n' ? '\n' : ' ';
      if (current === '\\') {
        if (index + 1 < output.length) output[++index] = ' ';
      } else if (current === quote) state = 'code';
    } else if (current === '/' && next === '/') {
      output[index] = output[index + 1] = ' '; state = 'line-comment'; index += 1;
    } else if (current === '/' && next === '*') {
      output[index] = output[index + 1] = ' '; state = 'block-comment'; blockDepth = 1; index += 1;
    } else if (triple === '"""' || triple === "'''") {
      output[index] = output[index + 1] = output[index + 2] = ' '; quote = current; state = 'triple-string'; index += 2;
    } else if (current === '"' || current === "'") {
      output[index] = ' '; quote = current; state = 'string';
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

function matchingParen(masked, open) {
  let depth = 1;
  for (let index = open + 1; index < masked.length; index += 1) {
    if (masked[index] === '(') depth += 1;
    else if (masked[index] === ')' && --depth === 0) return index;
  }
  throw new Error('unclosed_function_parameters');
}

function uniqueCallableScope(source, pattern, label) {
  const masked = maskCangjieLexical(source);
  const matches = [...masked.matchAll(pattern)];
  assert.equal(matches.length, 1, `anchor_${label}_count_${matches.length}`);
  const parameterOpen = matches[0].index + matches[0][0].lastIndexOf('(');
  const parameterClose = matchingParen(masked, parameterOpen);
  const open = masked.indexOf('{', parameterClose + 1);
  assert.notEqual(open, -1, `anchor_${label}_body_missing`);
  const close = matchingBrace(masked, open);
  return { source: source.slice(matches[0].index, close + 1), masked: masked.slice(matches[0].index, close + 1) };
}

function uniqueFunctionScope(source, name) {
  return uniqueCallableScope(source, new RegExp(`\\bfunc\\s+${name}\\s*\\(`, 'g'), name);
}

function ordered(scope, anchors, label) {
  let previous = -1;
  for (const anchor of anchors) {
    const current = scope.masked.indexOf(anchor);
    assert.ok(current > previous, `${label}_${anchor.replaceAll(' ', '_')}_order`);
    previous = current;
  }
}

function uniqueCodeLiteralOffset(scope, pattern, codePrefix, label) {
  const matches = [...scope.source.matchAll(pattern)]
    .filter((match) => scope.masked.slice(match.index, match.index + codePrefix.length) === codePrefix);
  assert.equal(matches.length, 1, `${label}_count`);
  return matches[0].index;
}

function assertTurnGate(scope, label) {
  const acquire = scope.masked.indexOf('gatewayTryAcquireModelMemoryAdmission(');
  const body = scope.masked.slice(scope.masked.indexOf('{') + 1);
  assert.match(body, /^\s*let\s+permit\s*=\s*gatewayTryAcquireModelMemoryAdmission\s*\(/,
    `${label}_gate_not_first_statement`);
  assert.match(body, /^\s*let\s+permit\s*=\s*gatewayTryAcquireModelMemoryAdmission\s*\([^\n]*\)\s*\n\s*try\s*{/,
    `${label}_gate_not_immediately_guarded`);
  const finallyMatches = [...scope.masked.matchAll(/}\s*finally\s*{/g)];
  assert.equal(finallyMatches.length, 1, `${label}_finally_count`);
  const finallyBlock = finallyMatches[0].index;
  const finallyOpen = scope.masked.indexOf('{', finallyBlock);
  const finallyClose = matchingBrace(scope.masked, finallyOpen);
  const release = scope.masked.indexOf('permit.release()', finallyOpen);
  assert.ok(acquire >= 0 && finallyBlock > acquire && release > finallyOpen && release < finallyClose,
    `${label}_gate_or_release_missing`);
  assert.equal([...scope.masked.matchAll(/permit\.release\s*\(\s*\)/g)].length, 1, `${label}_release_count`);
}

function assertFixture(source, label) {
  const masked = maskCangjieLexical(source);
  assert.match(masked, /const\s+\w*GIB\w*:\s*Int64\s*=\s*1024\s*\*\s*1024\s*\*\s*1024/,
    `${label}_gib_constant_missing`);
  assert.match(masked, /GatewayRuntimeHeapSnapshot\s*\(\s*2\s*\*\s*\w*GIB\w*/,
    `${label}_max_heap_fixture_missing`);
  assert.match(masked, /GatewayRuntimeHeapSnapshot\s*\([\s\S]*?\w*GIB\w*\s*,\s*\w*GIB\w*\s*,\s*50\s*,/,
    `${label}_available_fixture_missing`);
  assert.equal(/\b(getVariable|setVariable|File\.|Directory\.|ShellUtils\.|Process\b|canonicalize\s*\(|exists\s*\(|remove\s*\(|println?\s*\(|gatewayLog)\b/.test(masked), false,
    `${label}_fixture_has_io_env_or_log`);
  assert.equal(/@BeforeAll\b/.test(masked), false, `${label}_fixture_before_all_forbidden`);
}

function assertServiceGenerator(source, name) {
  const scope = uniqueFunctionScope(source, name);
  const call = scope.masked.indexOf('gatewayExecuteSessionRequestTurnForUser(');
  const sourceIndex = scope.masked.indexOf('admissionSource: GatewayModelMemoryAdmissionSource.ServicePlugin', call);
  const pressure = scope.masked.indexOf('catch (_: GatewayModelMemoryPressureException)', call);
  const codex = scope.masked.indexOf('catch (e: CodexResponsesException)', pressure);
  const generic = scope.masked.indexOf('catch (e: Exception)', pressure);
  assert.ok(call >= 0 && sourceIndex > call && pressure > sourceIndex && codex > pressure && generic > codex,
    `${name}_source_or_catch_order`);
}

export async function scanS3Architecture(root) {
  const sources = Object.fromEntries(await Promise.all(REQUIRED_FILES.map(async (relative) =>
    [relative, await readFile(join(root, relative), 'utf8')])));

  for (const name of ['gatewayExecutePlannedSessionRequestTurnForUser', 'gatewayExecuteSessionRequestTurn', 'gatewayExecuteSessionRequestTurnForUser']) {
    assertTurnGate(uniqueFunctionScope(sources[FILES.turn], name), name);
  }

  const cronBridge = uniqueFunctionScope(sources[FILES.cronBridge], 'cronBridgeReply');
  assert.match(cronBridge.masked, /admissionSource:\s*GatewayModelMemoryAdmissionSource\.Cron/, 'cron_source_missing');

  const fire = uniqueFunctionScope(sources[FILES.cronRunner], 'fireSingleJob');
  const pressureHeaders = [...fire.masked.matchAll(/catch\s*\(_:\s*GatewayModelMemoryPressureException\s*\)\s*{/g)];
  assert.equal(pressureHeaders.length, 1, 'cron_pressure_catch_count');
  const pressure = pressureHeaders[0].index;
  const pressureOpen = fire.masked.indexOf('{', pressure);
  const pressureClose = matchingBrace(fire.masked, pressureOpen);
  const pressureBody = {
    masked: fire.masked.slice(pressureOpen + 1, pressureClose),
    source: fire.source.slice(pressureOpen + 1, pressureClose),
  };
  ordered(pressureBody, ['modelMemoryPressure = true', 'break'], 'cron_pressure');
  const generic = fire.masked.indexOf('catch (e: Exception)', pressureClose);
  const commonFinalize = fire.masked.indexOf('this.finalizeError(j, startedAtMs, afterRun, errMsg)', generic);
  assert.ok(generic > pressure && commonFinalize > generic, 'cron_pressure_common_finalize_missing');
  assert.equal(/finalizeError|appendRunLogIsolated/.test(fire.masked.slice(pressure, generic)), false,
    'cron_pressure_has_private_finalize');
  assert.match(fire.masked.slice(commonFinalize), /!modelMemoryPressure/, 'cron_pressure_alert_suppression_missing');

  const transient = uniqueFunctionScope(sources[FILES.cronNext], 'isTransientCronError');
  const rawMatches = [...transient.source.matchAll(/message\s*==\s*"model_memory_pressure"/g)]
    .filter((match) => transient.masked.slice(match.index, match.index + 'message'.length) === 'message');
  assert.equal(rawMatches.length, 1, 'cron_transient_raw_exact_count');
  const raw = rawMatches[0].index;
  const lower = transient.masked.indexOf('toAsciiLower()');
  assert.ok(raw >= 0 && lower > raw, 'cron_transient_raw_exact_order');

  assertServiceGenerator(sources[FILES.service], 'servicePluginGenerateGitCodeReplyDraft');
  assertServiceGenerator(sources[FILES.service], 'servicePluginGenerateGitCodeWebhookReplyDraft');

  const dispatch = uniqueFunctionScope(sources[FILES.dispatcher], 'recordGitCodeAcceptedEventForFutureReply');
  const pendingPressure = uniqueCodeLiteralOffset(dispatch,
    /rawGenerated\.status\s*==\s*"model_memory_pressure"/g, 'rawGenerated.status', 'pending_pressure_guard');
  const pendingCancel = dispatch.masked.indexOf('servicePluginGeneratedReplyDedupe.cancel', pendingPressure);
  const pendingNormalize = dispatch.masked.indexOf('normalizeServicePluginGeneratedReplyResult', pendingPressure);
  const pendingWriteback = dispatch.masked.indexOf('servicePluginApplyGeneratedReplyWriteback', pendingPressure);
  assert.ok(pendingPressure >= 0 && pendingCancel > pendingPressure && pendingNormalize > pendingCancel && pendingWriteback > pendingNormalize,
    'pending_dispatch_pressure_cancel_order');
  const webhook = uniqueFunctionScope(sources[FILES.dispatcher], 'dispatchGitCodeWebhookAcceptedEvent');
  const webhookPressure = uniqueCodeLiteralOffset(webhook,
    /rawGenerated\.status\s*==\s*"model_memory_pressure"/g, 'rawGenerated.status', 'webhook_pressure_guard');
  const webhookCancel = webhook.masked.indexOf('servicePluginWebhookDispatchDedupe.cancel', webhookPressure);
  const webhookAbandon = webhook.masked.indexOf('servicePluginAbandonWebhookReceipt', webhookPressure);
  const webhookNormalize = webhook.masked.indexOf('normalizeServicePluginGeneratedReplyResult', webhookPressure);
  const webhookWriteback = webhook.masked.indexOf('servicePluginApplyGeneratedReplyWriteback', webhookPressure);
  assert.ok(webhookPressure >= 0 && webhookCancel > webhookPressure && webhookAbandon > webhookCancel &&
    webhookNormalize > webhookAbandon && webhookWriteback > webhookNormalize, 'webhook_dispatch_pressure_cancel_abandon_order');

  assertTurnGate(uniqueFunctionScope(sources[FILES.agent], 'gatewayAgentBridgeGitCodeModelJson'), 'gitcode_model');
  const invokeScope = uniqueCallableScope(sources[FILES.agent],
    /\bpublic\s+func\s+invoke\s*\(\s*toolName\s*:\s*String\s*,\s*args\s*:\s*JsonObject\s*\)/g,
    'gitcode_adapter_invoke');
  assert.equal([...invokeScope.masked.matchAll(/gatewayAgentBridgeGitCodeModelJson\s*\(/g)].length, 1,
    'gitcode_adapter_model_call_count');
  assert.equal([...maskCangjieLexical(sources[FILES.http]).matchAll(/GatewayAgentBridgeGitCodeMcpAdapter\s*\(\s*\)/g)].length, 1,
    'gitcode_http_adapter_callsite_count');

  assertFixture(sources[FILES.coreFixture], 'core');
  assertFixture(sources[FILES.runtimeFixture], 'runtime');
  assert.match(sources[FILES.config], /\[profile\.test\][\s\S]*?parallel\s*=\s*1/, 'test_parallel_must_be_one');
  return true;
}

async function copyCandidate(mutator = (_path, source) => source) {
  const root = await mkdtemp(join(tmpdir(), 'metis-s3-architecture-'));
  for (const relative of REQUIRED_FILES) {
    const destination = join(root, relative);
    await mkdir(dirname(destination), { recursive: true });
    await writeFile(destination, mutator(relative, await readFile(join(metisRoot, relative), 'utf8')));
  }
  return root;
}

async function expectMutationFailure(t, mutate, pattern) {
  const root = await copyCandidate(mutate);
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(scanS3Architecture(root), pattern);
}

function replaceNth(source, from, to, occurrence) {
  let start = -1;
  for (let index = 0; index < occurrence; index += 1) {
    start = source.indexOf(from, start + 1);
    assert.notEqual(start, -1, `mutation_anchor_${occurrence}_missing`);
  }
  return source.slice(0, start) + to + source.slice(start + from.length);
}

test('ARCH-S3-01 current source preserves model admission boundaries', async () => {
  await scanS3Architecture(metisRoot);
});

test('ARCH-S3-01 lexical scope ignores legal outside references and emoji braces', async (t) => {
  const root = await copyCandidate((relative, source) => relative === FILES.turn
    ? `${source}\n// 🙂 { gatewayTryAcquireModelMemoryAdmission(ignored) }\nfunc legalDebugRead(): Unit { let text = "🙂 escaped \\\" { }" }\n`
    : source);
  t.after(() => rm(root, { recursive: true, force: true }));
  await scanS3Architecture(root);
});

test('ARCH-S3-01 each architecture rule has a discriminating mutation', async (t) => {
  const cases = [
    ['planned central gate is first', /gatewayExecutePlannedSessionRequestTurnForUser_gate_not_first_statement/, FILES.turn,
      ['    let permit = gatewayTryAcquireModelMemoryAdmission(admissionSource)', '    let _ = gatewayBridgeForSessionRequest(user, request)\n    let permit = gatewayTryAcquireModelMemoryAdmission(admissionSource)']],
    ['bridge central gate is first', /gatewayExecuteSessionRequestTurn_gate_not_first_statement/, FILES.turn,
      ['__SECOND_ADMISSION__', '    let _early = AgentBridge\n    let permit = gatewayTryAcquireModelMemoryAdmission(admissionSource)']],
    ['user central gate is first', /gatewayExecuteSessionRequestTurnForUser_gate_not_first_statement/, FILES.turn,
      ['__THIRD_ADMISSION__', '    let _early = AgentBridge\n    let permit = gatewayTryAcquireModelMemoryAdmission(admissionSource)']],
    ['central release removed', /gate_or_release_missing|release_count/, FILES.turn, ['permit.release()', 'removedPermitRelease()']],
    ['bridge release removed', /gatewayExecuteSessionRequestTurn_gate_or_release_missing|gatewayExecuteSessionRequestTurn_release_count/, FILES.turn, ['__SECOND_RELEASE__', 'removedPermitRelease()']],
    ['user release removed', /gatewayExecuteSessionRequestTurnForUser_gate_or_release_missing|gatewayExecuteSessionRequestTurnForUser_release_count/, FILES.turn, ['__THIRD_RELEASE__', 'removedPermitRelease()']],
    ['planned release moved outside finally', /gatewayExecutePlannedSessionRequestTurnForUser_gate_or_release_missing/, FILES.turn,
      ['    } finally {\n        let _ = permit.release()\n    }', '        let _ = permit.release()\n    } finally {\n        ()\n    }']],
    ['planned business moved before try', /gatewayExecutePlannedSessionRequestTurnForUser_gate_not_immediately_guarded/, FILES.turn,
      ['    try {\n        let bridge', '    let _early = AgentBridge\n    try {\n        let bridge']],
    ['bridge has wrong extra finally', /gatewayExecuteSessionRequestTurn_finally_count/, FILES.turn,
      ['__SECOND_TRY__', '    try { () } finally { () }\n    try {']],
    ['cron source removed', /cron_source_missing/, FILES.cronBridge, ['GatewayModelMemoryAdmissionSource.Cron', 'GatewayModelMemoryAdmissionSource.Ordinary']],
    ['cron pressure bypasses common finalize', /cron_pressure_common_finalize_missing|cron_pressure_has_private_finalize/, FILES.cronRunner,
      ['                        modelMemoryPressure = true', '                        this.finalizeError(j, startedAtMs, epochMs(), errMsg)\n                        modelMemoryPressure = true']],
    ['cron pressure break removed', /cron_pressure_break_order/, FILES.cronRunner,
      ['__PRESSURE_BREAK__', '']],
    ['cron pressure must suppress failure alert', /cron_pressure_alert_suppression_missing/, FILES.cronRunner,
      ['!modelMemoryPressure', 'modelMemoryPressure']],
    ['cron transient token lowercased first', /cron_transient_raw_exact_order/, FILES.cronNext,
      ['__CRON_TRANSIENT_LITERAL__', '']],
    ['pending service source removed', /servicePluginGenerateGitCodeReplyDraft_source_or_catch_order/, FILES.service,
      ['admissionSource: GatewayModelMemoryAdmissionSource.ServicePlugin', 'admissionSource: GatewayModelMemoryAdmissionSource.Ordinary']],
    ['webhook service source removed', /servicePluginGenerateGitCodeWebhookReplyDraft_source_or_catch_order/, FILES.service,
      ['__SECOND_SERVICE_SOURCE__', 'admissionSource: GatewayModelMemoryAdmissionSource.Ordinary']],
    ['pending typed catch removed', /servicePluginGenerateGitCodeReplyDraft_source_or_catch_order/, FILES.service,
      ['catch (_: GatewayModelMemoryPressureException)', 'catch (_: GatewayModelMemoryPressureRemovedException)']],
    ['webhook typed catch removed', /servicePluginGenerateGitCodeWebhookReplyDraft_source_or_catch_order/, FILES.service,
      ['__SECOND_PRESSURE_CATCH__', 'catch (_: GatewayModelMemoryPressureRemovedException)']],
    ['pending pressure must cancel dedupe', /pending_dispatch_pressure_cancel_order/, FILES.dispatcher,
      ['__PENDING_CANCEL__', '']],
    ['pending parameter lambda fake anchor cannot replace body anchor', /pending_pressure_guard_count/, FILES.dispatcher,
      ['__PENDING_LAMBDA_FAKE__', '']],
    ['webhook pressure must cancel and abandon', /webhook_dispatch_pressure_cancel_abandon_order/, FILES.dispatcher,
      ['__WEBHOOK_CANCEL__', '']],
    ['gitcode eager work before gate', /gitcode_model_gate_not_first_statement/, FILES.agent,
      ['    let permit = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)', '    let _ = AgentBridge(sessionStore: GatewaySessionStore(Path("."), enabled: false))\n    let permit = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)']],
    ['gitcode duplicate production callsite', /gitcode_http_adapter_callsite_count/, FILES.http,
      ['GatewayAgentBridgeGitCodeMcpAdapter()', 'GatewayAgentBridgeGitCodeMcpAdapter(); let _duplicate = GatewayAgentBridgeGitCodeMcpAdapter()']],
    ['gitcode adapter invoke signature renamed', /anchor_gitcode_adapter_invoke_count_0/, FILES.agent,
      ['__GITCODE_INVOKE_RENAME__', '']],
    ['gitcode adapter invoke signature duplicated', /anchor_gitcode_adapter_invoke_count_2/, FILES.agent,
      ['__GITCODE_INVOKE_DUPLICATE__', '']],
    ['core baseline may not use env', /core_fixture_has_io_env_or_log/, FILES.coreFixture,
      ['private func gatewayInstallModelMemoryHealthyPackageBaseline(): Bool {', 'private func gatewayInstallModelMemoryHealthyPackageBaseline(): Bool {\n    let _ = getVariable("FORBIDDEN")']],
    ['core baseline may not create directories', /core_fixture_has_io_env_or_log/, FILES.coreFixture,
      ['private func gatewayInstallModelMemoryHealthyPackageBaseline(): Bool {', 'private func gatewayInstallModelMemoryHealthyPackageBaseline(): Bool {\n    Directory.create(Path("forbidden"))']],
    ['runtime baseline may not invoke shell', /runtime_fixture_has_io_env_or_log/, FILES.runtimeFixture,
      ['__RUNTIME_BASELINE__', 'private func gatewayInstallRuntimeModelMemoryHealthyPackageBaseline(): Bool {\n    let _ = ShellUtils.execute(["false"])']],
    ['core baseline may not use BeforeAll', /core_fixture_before_all_forbidden/, FILES.coreFixture,
      ['@Test', '@BeforeAll\n@Test']],
    ['runtime baseline capacity removed', /runtime_max_heap_fixture_missing/, FILES.runtimeFixture,
      ['__RUNTIME_BASELINE_CAPACITY__', '']],
    ['parallel gate changed', /test_parallel_must_be_one/, FILES.config, ['parallel = 1', 'parallel = 2']],
    ['renamed anchor fails closed', /anchor_cronBridgeReply_count_0/, FILES.cronBridge, ['func cronBridgeReply(', 'func renamedCronBridgeReply(']],
    ['duplicate anchor fails closed', /anchor_cronBridgeReply_count_2/, FILES.cronBridge, ['func cronBridgeReply(', 'func cronBridgeReply(a: Int64): Unit {}\npublic func cronBridgeReply(']],
  ];
  for (const [name, pattern, file, [from, to]] of cases) {
    await t.test(name, async (subtest) => expectMutationFailure(subtest,
      (relative, source) => {
        if (relative !== file) return source;
        if (from === '__SECOND_ADMISSION__') {
          return replaceNth(source, '    let permit = gatewayTryAcquireModelMemoryAdmission(admissionSource)', to, 2);
        }
        if (from === '__THIRD_ADMISSION__') {
          return replaceNth(source, '    let permit = gatewayTryAcquireModelMemoryAdmission(admissionSource)', to, 3);
        }
        if (from === '__SECOND_SERVICE_SOURCE__') {
          return replaceNth(source, 'admissionSource: GatewayModelMemoryAdmissionSource.ServicePlugin', to, 2);
        }
        if (from === '__SECOND_RELEASE__') {
          return replaceNth(source, 'permit.release()', to, 2);
        }
        if (from === '__THIRD_RELEASE__') {
          return replaceNth(source, 'permit.release()', to, 3);
        }
        if (from === '__SECOND_TRY__') {
          const scope = uniqueFunctionScope(source, 'gatewayExecuteSessionRequestTurn');
          return source.replace(scope.source, scope.source.replace('    try {', to));
        }
        if (from === '__SECOND_PRESSURE_CATCH__') {
          return replaceNth(source, 'catch (_: GatewayModelMemoryPressureException)', to, 2);
        }
        if (from === '__RUNTIME_BASELINE__') {
          return replaceNth(source, 'private func gatewayInstallRuntimeModelMemoryHealthyPackageBaseline(): Bool {', to, 1);
        }
        if (from === '__RUNTIME_BASELINE_CAPACITY__') {
          const scope = uniqueFunctionScope(source, 'gatewayInstallRuntimeModelMemoryHealthyPackageBaseline');
          const changedScope = replaceNth(scope.source, '2 * GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB',
            '3 * GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB', 1);
          return source.replace(scope.source, changedScope);
        }
        if (from === '__PRESSURE_BREAK__') {
          const scope = uniqueFunctionScope(source, 'fireSingleJob');
          const header = 'catch (_: GatewayModelMemoryPressureException) {';
          const start = scope.source.indexOf(header);
          assert.notEqual(start, -1, 'mutation_pressure_catch_missing');
          const open = scope.masked.indexOf('{', start);
          const close = matchingBrace(scope.masked, open);
          const body = scope.source.slice(open + 1, close);
          const changedBody = replaceNth(body, '                        break', '                        removedPressureBreak()', 1);
          const changedScope = scope.source.slice(0, open + 1) + changedBody + scope.source.slice(close);
          return source.replace(scope.source, changedScope);
        }
        if (from === '__CRON_TRANSIENT_LITERAL__') {
          return replaceNth(source,
            '    if (message == "model_memory_pressure") {\n        return true\n    }\n    let m = message.toAsciiLower()',
            '    let m = message.toAsciiLower()\n    if (message == "model_memory_pressure") {\n        return true\n    }', 1);
        }
        if (from === '__PENDING_CANCEL__') {
          const scope = uniqueFunctionScope(source, 'recordGitCodeAcceptedEventForFutureReply');
          const changedScope = replaceNth(scope.source,
            '        servicePluginGeneratedReplyDedupe.cancel(key)\n        return servicePluginDispatchResult(frame, false, "dispatch_retry", eventId: event.eventId)',
            '        return servicePluginDispatchResult(frame, false, "dispatch_retry", eventId: event.eventId)', 1);
          return source.replace(scope.source, changedScope);
        }
        if (from === '__PENDING_LAMBDA_FAKE__') {
          let changed = replaceNth(source, 'dispatchAllowed!: () -> Bool = { => true }',
            'dispatchAllowed!: () -> Bool = { => rawGenerated.status == "model_memory_pressure" }', 1);
          const scope = uniqueFunctionScope(changed, 'recordGitCodeAcceptedEventForFutureReply');
          const changedScope = replaceNth(scope.source, 'if (rawGenerated.status == "model_memory_pressure") {',
            'if (rawGenerated.status == "removed_pressure") {', 1);
          changed = changed.replace(scope.source, changedScope);
          return changed;
        }
        if (from === '__WEBHOOK_CANCEL__') {
          const scope = uniqueFunctionScope(source, 'dispatchGitCodeWebhookAcceptedEvent');
          const changedScope = replaceNth(scope.source,
            '        servicePluginWebhookDispatchDedupe.cancel(key)\n        let abandoned = servicePluginAbandonWebhookReceipt(frame, event, receiptStore, receiptIdentity)',
            '        let abandoned = servicePluginAbandonWebhookReceipt(frame, event, receiptStore, receiptIdentity)', 1);
          return source.replace(scope.source, changedScope);
        }
        if (from === '__GITCODE_INVOKE_RENAME__') {
          return replaceNth(source, '    public func invoke(toolName: String, args: JsonObject): JsonObject {',
            '    public func renamedGitCodeInvoke(toolName: String, args: JsonObject): JsonObject {', 1);
        }
        if (from === '__GITCODE_INVOKE_DUPLICATE__') {
          return replaceNth(source, '    public func invoke(toolName: String, args: JsonObject): JsonObject {',
            '    public func invoke(toolName: String, args: JsonObject): JsonObject { JsonObject() }\n\n' +
              '    public func invoke(toolName: String, args: JsonObject): JsonObject {', 1);
        }
        return source.replace(from, to);
      }, pattern));
  }
});
