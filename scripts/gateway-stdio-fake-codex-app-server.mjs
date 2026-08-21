#!/usr/bin/env node

import { spawn } from "node:child_process";
import { basename } from "node:path";
import { createInterface } from "node:readline";

if (process.argv[2] !== "app-server") process.exit(2);

const mode = process.env.METIS_CODEX_FAKE_MODE ?? "session";
const label = process.env.METIS_CODEX_FAKE_LABEL ?? "fake";
let runtimeLabel = label;
const pidFile = process.env.METIS_CODEX_FAKE_PID_FILE;
const childPidFile = process.env.METIS_CODEX_FAKE_CHILD_PID_FILE;

if (pidFile) await import("node:fs/promises").then(({ writeFile }) => writeFile(pidFile, `${process.pid}\n`));

if (mode === "hang-tree") {
  process.on("SIGTERM", () => {});
  const child = spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], {
    detached: false,
    stdio: "ignore",
  });
  if (childPidFile) await import("node:fs/promises").then(({ writeFile }) => writeFile(childPidFile, `${child.pid}\n`));
  process.stderr.write("startup diagnostic 中文🙂 access_token=secret-codex-token path=/Users/fake/private error(/private/tmp/fake) json={cwd:C:\\Users\\fake\\repo}\n");
  setInterval(() => {}, 1000);
} else if (mode === "invalid-utf8") {
  process.stdout.write(Buffer.from([0xff, 0xfe, 0x0a]));
  setInterval(() => {}, 1000);
} else if (mode === "long-line") {
  process.stdout.write(`${"中".repeat(400_000)}\n`);
  setInterval(() => {}, 1000);
} else if (mode === "malformed-json") {
  process.stdout.write('{"id":1,"result": 中文🙂\n');
  setInterval(() => {}, 1000);
} else {
  const send = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
  const sendChunked = (value, afterWrite = () => {}) => {
    const bytes = Buffer.from(`${JSON.stringify(value)}\n`);
    const marker = Buffer.from("🙂");
    const markerAt = bytes.indexOf(marker);
    const splitAt = markerAt >= 0 ? markerAt + 2 : Math.max(1, Math.floor(bytes.length / 2));
    process.stdout.write(bytes.subarray(0, splitAt));
    setTimeout(() => process.stdout.write(bytes.subarray(splitAt), afterWrite), 2);
  };

  createInterface({ input: process.stdin, crlfDelay: Infinity }).on("line", (line) => {
    let request;
    try { request = JSON.parse(line); }
    catch { process.stderr.write("malformed_json\n"); return; }
    if (!Object.hasOwn(request, "id")) return;
    if (typeof request.method !== "string") return;
    if (mode === "no-response") return;
    if (request.method === "initialize") {
      process.stderr.write(`diagnostic ${label} 中文🙂 access_token=secret-codex-token path=/Users/fake/private error(/private/tmp/fake) json={cwd:C:\\Users\\fake\\repo}\n`);
      send({ id: 9000, method: "permissions/request", params: {} });
      const respond = () => send({ id: request.id, result: { label, text: "中文🙂" } });
      sendChunked({ method: "fake/notification", params: { label, text: "中文🙂" } }, () => {
        if (mode === "delayed-response") {
          setTimeout(respond, Number(process.env.METIS_CODEX_FAKE_DELAY_MS ?? 0));
        } else {
          respond();
        }
      });
      return;
    }
    if (request.method === "thread/start") {
      runtimeLabel = basename(request.params?.cwd ?? "") || label;
      send({ id: request.id, result: { thread: { id: `thread-${runtimeLabel}` } } });
      return;
    }
    if (request.method === "turn/start") {
      send({ id: request.id, result: { turnId: `turn-${runtimeLabel}` } });
      send({ method: "thread/tokenUsage/updated", params: { tokenUsage: { last: {
        inputTokens: 12, cachedInputTokens: 3, outputTokens: 7, reasoningTokens: 2, totalTokens: 19,
      } } } });
      send({ method: "item/completed", params: { item: { type: "agentMessage", text: `answer-${runtimeLabel}-中文🙂` } } });
      send({ method: "turn/completed", params: {} });
      return;
    }
    send({ id: request.id, result: {} });
  });
}
