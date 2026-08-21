import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  runStarvationReproduction,
  starvationThresholds,
} from "./gateway-stdio-starvation-reproduction.mjs";

const fixturePath = fileURLToPath(
  new URL("./gateway-stdio-fake-protocol-child.mjs", import.meta.url),
);

async function runFixture(scenario) {
  const child = spawn(process.execPath, [fixturePath, `--scenario=${scenario}`], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  const [exitCode, signal] = await once(child, "exit");
  return { exitCode, signal, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) };
}

function decodeJsonLines(bytes) {
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return text
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

test("P0-U1 fake protocol child emits ready, frame, and clean exit in order", async () => {
  const result = await runFixture("sequence");

  assert.equal(result.exitCode, 0);
  assert.equal(result.signal, null);
  assert.deepEqual(decodeJsonLines(result.stdout), [
    { type: "ready", child: "fake" },
    { type: "frame", value: "ok" },
  ]);
  assert.equal(result.stderr.length, 0);
});

test("P0-B1 fixture preserves blank lines, long CJK, emoji, and chunked JSON", async () => {
  const result = await runFixture("utf8-boundary");
  const decoded = new TextDecoder("utf-8", { fatal: true }).decode(result.stdout);
  const lines = decoded.split("\n");

  assert.equal(result.exitCode, 0);
  assert.equal(lines[0], "");
  const frames = lines.filter((line) => line.length > 0).map((line) => JSON.parse(line));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].type, "frame");
  assert.equal(frames[0].value, `${"中文🙂".repeat(4096)}末尾🚀`);
  assert.equal(frames[0].value.endsWith("末尾🚀"), true);
});

test("P0-B1 fixture can emit invalid UTF-8 for downstream negative tests", async () => {
  const result = await runFixture("malformed-bytes");

  assert.equal(result.exitCode, 0);
  assert.throws(
    () => new TextDecoder("utf-8", { fatal: true }).decode(result.stdout),
    { name: "TypeError" },
  );
});

test("P0-P1 two responsive fake channels keep polling and health remains live", async () => {
  const result = await runStarvationReproduction("production");

  assert.equal(result.mode, "production");
  assert.equal(result.health.ok, true);
  assert.ok(result.health.latencyMs <= starvationThresholds.healthTimeoutMs);
  assert.equal(result.pollTicks.length, 2);
  for (const count of result.pollTicks) {
    assert.ok(count >= starvationThresholds.minPollTicks, `poll count ${count} is below threshold`);
  }
  assert.equal(result.starvationSignature, false);
  assert.equal(result.childPids.every((pid) => Number.isInteger(pid) && pid > 0), true);
});

test("P0-N1 legacy reader shape deterministically exposes starvation signature", async () => {
  const expectation = process.env.METIS_STARVATION_EXPECT ?? "legacy-signature";
  assert.equal(
    expectation,
    "legacy-signature",
    "P0 only accepts legacy-signature; responsive production proof belongs to P5",
  );

  const result = await runStarvationReproduction("legacy-shape");

  assert.equal(result.mode, "legacy-shape");
  assert.deepEqual(result.pollTicks, [0, 0]);
  assert.equal(result.health.ok, false);
  assert.ok(result.health.latencyMs >= starvationThresholds.healthTimeoutMs);
  assert.equal(result.starvationSignature, true);
  assert.equal(result.childPids.every((pid) => Number.isInteger(pid) && pid > 0), true);
});
