import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TEST_WINDOW_MS = 1_800;
const POLL_INTERVAL_MS = 75;
const HEALTH_TIMEOUT_MS = 300;
const MIN_POLL_TICKS = 10;
const LEGACY_SLOT_COUNT = 4;

const fixturePath = fileURLToPath(
  new URL("./gateway-stdio-fake-protocol-child.mjs", import.meta.url),
);

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function readJsonLines(stream, onFrame) {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let pending = "";
  stream.on("data", (chunk) => {
    pending += decoder.decode(chunk, { stream: true });
    while (true) {
      const newline = pending.indexOf("\n");
      if (newline < 0) {
        break;
      }
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (line.length > 0) {
        onFrame(JSON.parse(line));
      }
    }
  });
}

function startFakeChild(scenario) {
  const child = spawn(process.execPath, [fixturePath, `--scenario=${scenario}`], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  return child;
}

async function stopChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  child.stdin.end();
  child.kill("SIGTERM");
  const exited = new Promise((resolve) => child.once("exit", resolve));
  if (await Promise.race([exited.then(() => true), wait(250).then(() => false)])) {
    return;
  }
  child.kill("SIGKILL");
  await exited;
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address());
    });
  });
}

function closeServer(server) {
  return new Promise((resolve) => server.close(() => resolve()));
}

function healthRequest(port, timeoutMs = HEALTH_TIMEOUT_MS) {
  const startedAt = Date.now();
  return new Promise((resolve) => {
    const request = http.get(
      { hostname: "127.0.0.1", port, path: "/healthz", timeout: timeoutMs },
      (response) => {
        response.resume();
        response.once("end", () => {
          resolve({ ok: response.statusCode === 200, latencyMs: Date.now() - startedAt });
        });
      },
    );
    request.once("timeout", () => request.destroy(new Error("health timeout")));
    request.once("error", () => {
      resolve({ ok: false, latencyMs: Date.now() - startedAt });
    });
  });
}

class FixedSlotScheduler {
  constructor(limit) {
    this.limit = limit;
    this.active = 0;
    this.queue = [];
  }

  submit(task) {
    return new Promise((resolve, reject) => {
      this.queue.push({ task, resolve, reject });
      this.#drain();
    });
  }

  #drain() {
    while (this.active < this.limit && this.queue.length > 0) {
      const entry = this.queue.shift();
      this.active += 1;
      Promise.resolve()
        .then(entry.task)
        .then(entry.resolve, entry.reject)
        .finally(() => {
          this.active -= 1;
          this.#drain();
        });
    }
  }
}

async function runResponsiveHarness() {
  const children = [startFakeChild("responsive"), startFakeChild("responsive")];
  const pollTicks = [0, 0];
  const requestIds = [0, 0];
  const timers = [];
  const server = http.createServer((request, response) => {
    if (request.url === "/healthz") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"ok":true}');
      return;
    }
    response.writeHead(404).end();
  });
  try {
    const address = await listen(server);
    children.forEach((child, index) => {
      readJsonLines(child.stdout, (frame) => {
        if (frame.type === "pollResult") {
          pollTicks[index] += 1;
        }
      });
      timers.push(
        setInterval(() => {
          if (child.stdin.writable) {
            requestIds[index] += 1;
            child.stdin.write(`${JSON.stringify({ requestId: `${index}-${requestIds[index]}` })}\n`);
          }
        }, POLL_INTERVAL_MS),
      );
    });
    await wait(TEST_WINDOW_MS);
    const health = await healthRequest(address.port);
    return {
      mode: "production",
      pollTicks: [...pollTicks],
      childPids: children.map((child) => child.pid),
      health,
      starvationSignature: pollTicks.some((count) => count < MIN_POLL_TICKS) || !health.ok,
    };
  } finally {
    timers.forEach(clearInterval);
    await Promise.all(children.map(stopChild));
    if (server.listening) {
      await closeServer(server);
    }
  }
}

async function runLegacyHarness() {
  const children = Array.from({ length: LEGACY_SLOT_COUNT }, () => startFakeChild("hang"));
  const scheduler = new FixedSlotScheduler(LEGACY_SLOT_COUNT);
  const releases = [];
  const pollTicks = [0, 0];
  const server = http.createServer((request, response) => {
    if (request.url !== "/healthz") {
      response.writeHead(404).end();
      return;
    }
    scheduler.submit(() => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"ok":true}');
    });
  });
  try {
    const address = await listen(server);
    for (const child of children) {
      scheduler.submit(
        () =>
          new Promise((resolve) => {
            releases.push(resolve);
          }),
      );
      readJsonLines(child.stdout, () => {});
    }
    const pollTimer = setInterval(() => {
      scheduler.submit(() => {
        pollTicks[0] += 1;
        pollTicks[1] += 1;
      });
    }, POLL_INTERVAL_MS);
    await wait(TEST_WINDOW_MS);
    const health = await healthRequest(address.port);
    clearInterval(pollTimer);
    return {
      mode: "legacy-shape",
      pollTicks: [...pollTicks],
      childPids: children.map((child) => child.pid),
      health,
      starvationSignature: pollTicks.every((count) => count === 0) && !health.ok,
    };
  } finally {
    releases.forEach((release) => release());
    await Promise.all(children.map(stopChild));
    if (server.listening) {
      await closeServer(server);
    }
  }
}

export async function runStarvationReproduction(mode) {
  if (mode !== "legacy-shape" && mode !== "production") {
    throw new Error(`unsupported starvation reproduction mode: ${mode}`);
  }
  const temporaryHome = await mkdtemp(path.join(os.tmpdir(), "metis-stdio-p0-"));
  const previousMetisHome = process.env.METIS_HOME;
  process.env.METIS_HOME = temporaryHome;
  try {
    return mode === "legacy-shape" ? await runLegacyHarness() : await runResponsiveHarness();
  } finally {
    if (previousMetisHome === undefined) {
      delete process.env.METIS_HOME;
    } else {
      process.env.METIS_HOME = previousMetisHome;
    }
    await rm(temporaryHome, { recursive: true, force: true });
  }
}

export const starvationThresholds = Object.freeze({
  testWindowMs: TEST_WINDOW_MS,
  healthTimeoutMs: HEALTH_TIMEOUT_MS,
  minPollTicks: MIN_POLL_TICKS,
});
