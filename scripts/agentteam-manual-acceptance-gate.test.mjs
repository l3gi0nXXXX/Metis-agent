import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const gateScript = path.join(root, "scripts", "agentteam-manual-acceptance-gate.sh");

function runGate(extraEnv = {}) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "metis-agentteam-gate-test-"));
  const metisHome = path.join(tempRoot, "home");
  const reportDir = path.join(tempRoot, "report");
  fs.mkdirSync(metisHome, { recursive: true });
  const result = spawnSync("bash", [gateScript], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      METIS_AGENTTEAM_SKIP_ENVSETUP: "1",
      METIS_HOME: metisHome,
      METIS_AGENTTEAM_REPORT_DIR: reportDir,
      ...extraEnv,
    },
  });
  return { ...result, tempRoot, reportDir };
}

function readReport(reportDir) {
  return JSON.parse(fs.readFileSync(path.join(reportDir, "report.json"), "utf8"));
}

test("Telegram live opt-in without external resources is a structured skip, not a failed gate", () => {
  const result = runGate({
    METIS_AGENTTEAM_LIVE_TELEGRAM: "1",
    METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID: "",
    METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID: "",
  });

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const telegram = readReport(result.reportDir).liveGates.telegram;
  assert.equal(telegram.status, "skipped");
  assert.equal(telegram.reason, "external-resource-required");
  assert.deepEqual(
    telegram.manualChecks.map((check) => `${check.id}:${check.status}:${check.reason}`),
    [
      "account-route:skipped:external-resource-required",
      "group-topic-session-isolation:skipped:external-resource-required",
      "alias-route:skipped:external-resource-required",
      "broadcast-aggregate:skipped:external-resource-required",
    ],
  );
});

test("writes a phase0-9 and GAP-numbered acceptance checklist with local/external evidence states", () => {
  const result = runGate();

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const report = readReport(result.reportDir);
  assert.equal(report.series, "19");
  assert.equal(report.phases, "0-9");
  assert.equal(report.acceptance.statuses.localPass, "local-pass");
  assert.equal(report.acceptance.statuses.externalResourceRequired, "external-resource-required");

  const phases = report.acceptance.phases.map((phase) => phase.id);
  assert.deepEqual(phases, [
    "phase0",
    "phase1",
    "phase2",
    "phase3",
    "phase4",
    "phase5",
    "phase6",
    "phase7",
    "phase8",
    "phase9",
  ]);

  const phase2 = report.acceptance.phases.find((phase) => phase.id === "phase2");
  assert.equal(phase2.status, "local-pass");
  assert(phase2.gaps.includes("G02"));
  assert(phase2.gaps.includes("G05"));
  assert(phase2.checklist.some((item) => item.id === "M07" && item.status === "local-pass"));
  assert(phase2.checklist.some((item) => item.id === "M09" && item.status === "local-pass"));

  const gapById = new Map(report.acceptance.gaps.map((gap) => [gap.id, gap]));
  assert.equal(gapById.get("G01").status, "local-pass");
  assert.equal(gapById.get("G11").status, "external-resource-required");
  assert.equal(gapById.get("G18").status, "external-resource-required");
  assert.equal(gapById.get("G24").status, "local-pass");
  assert.equal(gapById.get("G25").status, "local-pass");

  const template = fs.readFileSync(path.join(result.reportDir, "manual-acceptance-template.md"), "utf8");
  assert.match(template, /## Phase 2 Agent Isolation Acceptance/);
  assert.match(template, /\| G02 \|/);
  assert.match(template, /\| G11 \| external-resource-required \|/);
  assert.match(template, /\| G25 \| local-pass \|/);
});
