#!/usr/bin/env node

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import readline from "node:readline";
import { execFileSync, spawn } from "node:child_process";

const args = process.argv.slice(2);
const childMode = args[0] === "--child";

function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temp, text, "utf8");
  fs.renameSync(temp, file);
}

function listen(port, ready) {
  const server = net.createServer((socket) => socket.end("ok\n"));
  server.listen(port, "127.0.0.1", ready);
  return server;
}

if (childMode) {
  const mode = args[1];
  const port = Number(args[2]);
  const readyPath = args[3];
  const server = listen(port, () => writeAtomic(readyPath, `${process.pid}\n${server.address().port}\n`));
  if (mode === "ignore-term") {
    process.on("SIGTERM", () => {});
    process.on("SIGHUP", () => {});
  } else {
    process.once("SIGTERM", () => server.close(() => process.exit(0)));
    process.once("SIGHUP", () => server.close(() => process.exit(0)));
  }
} else {
  const mode = args[0] ?? "graceful";
  const rootPort = Number(args[1]);
  const childPort = Number(args[2]);
  const readyPath = args[3];
  const childReadyPath = `${readyPath}.child`;
  const serviceId = process.env.METIS_SERVICE_PLUGIN_ID || "gateway-stop-fixture";
  const sessionId = process.env.METIS_SERVICE_PLUGIN_SESSION_ID || "gateway-stop-session";
  const leasePath = process.env.METIS_SERVICE_PLUGIN_LEASE_PATH || "";
  const configuredParentPid = (process.env.METIS_SERVICE_PLUGIN_PARENT_PID || "").trim();
  const parsedParentPid = /^[1-9][0-9]*$/.test(configuredParentPid) ? Number(configuredParentPid) : 0;
  const leaseParentPid = Number.isSafeInteger(parsedParentPid) && parsedParentPid > 0 ? parsedParentPid : process.ppid;
  const child = spawn(process.execPath, [process.argv[1], "--child", mode, String(childPort), childReadyPath], {
    detached: false,
    stdio: "ignore",
  });
  let childPid = 0;
  let childBoundPort = 0;

  function writeLease(state, port) {
    if (!leasePath) return;
    writeAtomic(leasePath, JSON.stringify({
      state, status: state, pluginId: serviceId, sessionId,
      pid: process.pid, parentPid: leaseParentPid, bindHost: "127.0.0.1", port,
      startedAtMs: Date.now(), lastHeartbeatMs: Date.now(),
    }));
  }

  const childReadyTimer = setInterval(() => {
    if (!fs.existsSync(childReadyPath)) return;
    const lines = fs.readFileSync(childReadyPath, "utf8").trim().split("\n");
    childPid = Number(lines[0]);
    childBoundPort = Number(lines[1]);
    clearInterval(childReadyTimer);
    const pgid = Number(execFileSync("/bin/ps", ["-o", "pgid=", "-p", String(process.pid)], { encoding: "utf8" }).trim());
    writeAtomic(readyPath, `${process.pid}\n${childPid}\n${pgid}\n${server.address().port}\n${childBoundPort}\n${leasePath}\n`);
  }, 5);

  const server = listen(rootPort, () => {
    writeLease("running", server.address().port);
    process.stdout.write(`${JSON.stringify({
      type: "response", frameId: "init-1", serviceId, method: "initialize",
      payload: { ok: true, status: "ready" },
    })}\n`);
  });

  var stopping = false;
  function stopGracefully() {
    if (stopping || mode === "ignore-term") return;
    stopping = true;
    child.kill("SIGTERM");
    child.once("exit", () => {
      server.close(() => {
        writeLease("stopped", rootPort);
        process.exit(0);
      });
    });
  }

  if (mode === "ignore-term") {
    process.on("SIGTERM", () => {});
    process.on("SIGHUP", () => {});
  } else {
    process.once("SIGTERM", stopGracefully);
    process.once("SIGHUP", stopGracefully);
  }

  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on("line", (line) => {
    let request;
    try { request = JSON.parse(line); } catch { return; }
    if (request.method === "stop") stopGracefully();
  });
  input.once("close", stopGracefully);
}
