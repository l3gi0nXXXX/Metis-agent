import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./metis-s5-loopback-dependencies.mjs", import.meta.url));
const pause = () => new Promise((resolve) => setTimeout(resolve, 10));
async function until(predicate, deadline) {
  while (performance.now() < deadline) {
    if (predicate()) return true;
    await pause();
  }
  return predicate();
}
async function bounded(promise, deadline) {
  const remaining = deadline - performance.now();
  if (remaining <= 0) throw new Error("fixture_operation_deadline");
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("fixture_operation_deadline")), remaining);
    })]);
  } finally { clearTimeout(timer); }
}
function json(file) { return JSON.parse(fs.readFileSync(file, "utf8")); }
function row(file) { return fs.existsSync(file) ? json(file).accounts["0"] : undefined; }

async function fixture(mode, body, outerDeadline = performance.now() + 10000) {
  const home = fs.mkdtempSync(path.join(tmpdir(), "metis-tg-poll-discriminator-"));
  const ready = path.join(home, "ready.json");
  const events = path.join(home, "events.jsonl");
  const metrics = path.join(home, "metrics.json");
  const release = path.join(home, "poll.release");
  const gate = path.join(home, "gate.json");
  const nonce = path.basename(home);
  const config = { metricsPath: metrics, releasePath: path.join(home, "confirm.release"),
    confirmMode: "success", pollDelayMs: 0 };
  if (mode === "hold") Object.assign(config, { pollMode: "hold", pollReleasePath: release });
  if (mode !== "ungated") fs.writeFileSync(gate, JSON.stringify(config));
  fs.writeFileSync(path.join(home, "owner.json"), JSON.stringify({ nonce, mode }));
  const args = [script, ready, events, "", "", "", "", "", "", mode === "ungated" ? "" : gate];
  const errorFd = fs.openSync(path.join(home, "stderr"), "w", 0o600);
  let child;
  let exit;
  let exitResult;
  let errorClosed = false;
  let pendingLaunch = true;
  let bodyError;
  let formal = false;
  let proofSaved = false;
  let reaped = false;
  let terminal = false;
  const requests = [];
  try {
    child = spawn(process.execPath, args, { cwd: home,
      env: { PATH: path.dirname(process.execPath), HOME: home, TMPDIR: home, LANG: "C.UTF-8" },
      stdio: ["ignore", "ignore", errorFd] });
    exit = new Promise((resolve) => {
      child.once("error", () => { exitResult = { error: true }; resolve(exitResult); });
      child.once("close", (code, signal) => { exitResult = { code, signal }; resolve(exitResult); });
    });
    pendingLaunch = false;
    fs.closeSync(errorFd); errorClosed = true;
    const deadline = Math.min(outerDeadline - 3000, performance.now() + 7000);
    let port;
    assert.equal(await until(() => {
      if (exitResult) return true;
      if (!fs.existsSync(ready)) return false;
      try { port = json(ready).port; return Number.isInteger(port) && port > 0; }
      catch { return false; }
    }, deadline), true);
    assert.equal(exitResult, undefined);
    assert.ok(Number.isInteger(port) && port > 0);
    const issue = () => {
      const payload = JSON.stringify({ timeout: 30, offset: 43 });
      let responseSeen = false;
      let settle;
      const finished = new Promise((resolve) => { settle = resolve; });
      const request = http.request({ host: "127.0.0.1", port, method: "POST",
        path: "/bot100000:FAKE-TGSTOP-0/getUpdates", agent: false,
        headers: { "content-type": "application/json", "content-length": Buffer.byteLength(payload) } }, (response) => {
        responseSeen = true;
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.once("end", () => settle({ status: response.statusCode, bytes: Buffer.concat(chunks) }));
        response.once("error", () => settle({ error: true }));
      });
      request.once("error", () => settle({ error: true }));
      request.end(payload);
      const closed = new Promise((resolve) => request.once("close", resolve));
      requests.push({ request, closed });
      return { request, finished, responseSeen: () => responseSeen };
    };
    await body({ home, metrics, events, release, deadline, issue });
    formal = true;
  } catch (error) { bodyError = error; }
  finally {
    try {
      fs.writeFileSync(path.join(home, "formal-before-fallback.json"), JSON.stringify({
        nonce, mode, formal, pendingLaunch, pollReleasePresent: fs.existsSync(release),
        metrics: fs.existsSync(metrics) ? json(metrics) : null,
      }));
      proofSaved = true;
    } catch (error) { bodyError ??= error; }
    finally {
      const deadline = Math.min(outerDeadline, performance.now() + 3000);
      try { fs.writeFileSync(release, "release\n"); } catch (error) { bodyError ??= error; }
      for (const entry of requests) entry.request.destroy();
      try { await bounded(Promise.all(requests.map((entry) => entry.closed)), deadline); }
      catch (error) { bodyError ??= error; }
      try {
        if (child && !exitResult) child.kill("SIGTERM");
        if (child && !await until(() => exitResult !== undefined, Math.min(deadline, performance.now() + 1000))) {
          child.kill("SIGKILL");
          bodyError ??= new Error("fixture_forced_cleanup");
        }
        if (child) {
          reaped = await until(() => exitResult !== undefined, deadline);
          if (reaped) {
            await exit;
            if (exitResult.code !== 0 || exitResult.signal) bodyError ??= new Error("fixture_driver_exit_failed");
          }
        }
        terminal = !pendingLaunch && Number.isInteger(child?.pid) && child.pid > 1 && reaped && performance.now() <= deadline;
      } catch (error) { bodyError ??= error; }
      finally {
        try { if (!errorClosed) { fs.closeSync(errorFd); errorClosed = true; } } catch (error) { bodyError ??= error; }
        try { fs.writeFileSync(path.join(home, "cleanup.json"), JSON.stringify({ nonce, terminal, reaped, proofSaved })); }
        catch (error) { bodyError ??= error; }
      }
      if (!terminal && !bodyError) bodyError = new Error("fixture_cleanup_pending");
      if (formal && proofSaved && terminal && !bodyError) fs.rmSync(home, { recursive: true });
      else process.stderr.write(`TG-FIXTURE retained=${nonce};mode=${mode};formal=${formal};terminal=${terminal}\n`);
    }
  }
  if (bodyError) throw bodyError;
  assert.equal(formal && proofSaved && terminal, true);
}

test("TG-FIXTURE-P1 held poll closes only when client disconnects", { timeout: 10000 }, async () => {
  await fixture("hold", async ({ metrics, release, deadline, issue }) => {
    const call = issue();
    assert.equal(await until(() => row(metrics)?.pollActive === 1, deadline), true);
    assert.equal(call.responseSeen(), false);
    assert.equal(fs.existsSync(release), false);
    call.request.destroy();
    assert.equal(await until(() => row(metrics)?.pollPeerClosed === 1 && row(metrics)?.pollActive === 0, deadline), true);
    assert.equal(row(metrics).pollCompleted, 0);
    assert.equal(row(metrics).peerClosed, 1);
    assert.equal(row(metrics).maxPollElapsedMs < row(metrics).pollExpectedReadTimeoutMs, true);
  });
});

test("TG-FIXTURE-N1 normally released response never counts as peer close", { timeout: 10000 }, async () => {
  await fixture("hold", async ({ metrics, release, deadline, issue }) => {
    const call = issue();
    assert.equal(await until(() => row(metrics)?.pollActive === 1, deadline), true);
    fs.writeFileSync(release, "release\n");
    const result = await bounded(call.finished, deadline);
    assert.equal(result.status, 200);
    assert.deepEqual(JSON.parse(result.bytes.toString("utf8")), { ok: true, result: [] });
    assert.equal(await until(() => row(metrics)?.pollCompleted === 1 && row(metrics)?.pollActive === 0, deadline), true);
    assert.equal(row(metrics).pollPeerClosed, 0);
    assert.equal(row(metrics).peerClosed, 0);
  });
});

test("TG-FIXTURE-H1 absent hold mode preserves gated and ungated completion", { timeout: 10000 }, async () => {
  const deadline = performance.now() + 10000;
  for (const mode of ["default", "ungated"]) {
    await fixture(mode, async ({ metrics, release, deadline, issue }) => {
      const result = await bounded(issue().finished, deadline);
      assert.equal(result.status, 200);
      assert.deepEqual(JSON.parse(result.bytes.toString("utf8")), { ok: true, result: [] });
      assert.equal(fs.existsSync(release), false);
      if (mode === "default") {
        assert.equal(await until(() => row(metrics)?.pollCompleted === 1, deadline), true);
        assert.equal(row(metrics).pollPeerClosed, 0);
      } else assert.equal(fs.existsSync(metrics), false);
    }, deadline);
  }
});
