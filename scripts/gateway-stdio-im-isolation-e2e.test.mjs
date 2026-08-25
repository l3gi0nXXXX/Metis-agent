import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function safeTail(raw) {
  const redacted = String(raw ?? "")
    .replace(/Authorization:\s*Bearer\s+\S+/gi, "Authorization: Bearer [redacted]")
    .replace(/(?:token|password|secret)\s*[=:]\s*\S+/gi, "$1=[redacted]")
    .replace(/\/Users\/[^\s]+/g, "/Users/[redacted]");
  return Array.from(redacted).slice(-4000).join("");
}

function execute(command, args, timeout = 120_000) {
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  return spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    timeout,
    maxBuffer: 16 * 1024 * 1024,
  });
}

function run(command, args, timeout = 120_000) {
  const result = execute(command, args, timeout);
  assert.equal(
    result.status,
    0,
    `${command} failed (status=${result.status}, signal=${result.signal})\n${safeTail(result.stdout)}\n${safeTail(result.stderr)}`,
  );
  return `${result.stdout}\n${result.stderr}`;
}

function runCase(packagePath, filter) {
  const common = [
    "test",
    packagePath,
    "-j",
    "1",
    "--parallel",
    "1",
    "--no-color",
    "--filter",
    filter,
  ];
  let result = execute("cjpm", [...common.slice(0, 2), "--skip-build", ...common.slice(2)]);
  if (result.status !== 0 && `${result.stdout}\n${result.stderr}`.includes("failed to show unittest result")) {
    result = execute("cjpm", common);
  }
  assert.equal(
    result.status,
    0,
    `cjpm failed (status=${result.status}, signal=${result.signal})\n${safeTail(result.stdout)}\n${safeTail(result.stderr)}`,
  );
  const output = `${result.stdout}\n${result.stderr}`;
  for (const name of filter.split(",")) {
    assert.match(output, new RegExp(`\\[ PASSED \\] CASE: ${name.split(".").at(-1)}`));
  }
}

test("E2E-01 formal Codex and compatibility children keep double-IM poll and health responsive", { concurrency: false }, () => {
  runCase(
    "src/gateway/runtime",
    "GatewayShellNonblockingE2eTest.p3IP2P3FormalChildrenOverlapDoubleImPollAndRealHealthz",
  );
});

test("E2E-02 service-plugin health event and response preserve PID and lease", { concurrency: false }, () => {
  runCase(
    "src/gateway/service_plugin",
    "ServicePluginHostTest.p3P1FakeGcmHealthEventResponseKeepsPidAndLease",
  );
});

test("E2E-03 formal Gateway shell owners overlap IM poll and real healthz", { concurrency: false }, () => {
  runCase(
    "src/gateway/runtime",
    "GatewayShellNonblockingE2eTest.p3P5FormalGatewayShellLoadKeepsImPollAndRealHealthzResponsive",
  );
});

test("E2E-04 managed ACP and subagent timeout cleanup remain owner-scoped", { concurrency: false }, () => {
  runCase(
    "src/gateway/tools",
    [
      "GatewayManagedSessionsToolsetTest.managedAcpBrokerTimeoutAndKillOnlyStopTargetOwner",
      "GatewayManagedSessionsToolsetTest.managedSubagentBrokerRunsFakeChildAndCleansWorktreeOnSuccessAndCancel",
    ].join(","),
  );
});

test("E2E-05 broker unresponsive readiness reaps the old generation and recovers", { concurrency: false }, () => {
  runCase(
    "src/gateway/runtime",
    "GatewayServerMethodsStatusTest.p5P1BrokerUnresponsiveReadinessAndGenerationRecoveryAreExact",
  );
});

test("E2E-06 pipe inventory stays allowlisted and P5 fake processes leave no residue", { concurrency: false }, () => {
  const scanner = run("node", ["--test", "scripts/gateway-stdio-pipe-boundary.test.mjs"]);
  assert.match(scanner, /pass 4/);
  assert.match(scanner, /fail 0/);

  const processes = run("ps", ["-axo", "pid=,command="]);
  const residue = processes
    .split("\n")
    .filter((line) => line.includes(root))
    .filter((line) => /metis-stdio-broker|gateway-stdio-fake-|gateway-stdio-p3b-fake-child/.test(line))
    .filter((line) => !line.includes("gateway-stdio-im-isolation-e2e.test.mjs"));
  assert.deepEqual(residue, []);
});
