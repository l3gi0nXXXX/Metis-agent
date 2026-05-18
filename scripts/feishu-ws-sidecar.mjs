#!/usr/bin/env node

import process from "node:process";
import path from "node:path";
import readline from "node:readline";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

import {
  configureKnownSecrets,
  installConsoleStderrPatch,
  writeDiagnostic,
  writeProtocol,
} from "./lib/metis-sidecar-logger.mjs";

export function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      out._.push(token);
      continue;
    }
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next == null || next.startsWith("--")) {
      out[key] = "true";
      continue;
    }
    out[key] = next;
    i += 1;
  }
  return out;
}

export function readTrimmed(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function resolveDomain(Lark, raw) {
  const value = readTrimmed(raw).toLowerCase();
  if (!value || value === "feishu" || value === "https://open.feishu.cn") {
    return Lark.Domain.Feishu;
  }
  if (value === "lark" || value === "https://open.larksuite.com") {
    return Lark.Domain.Lark;
  }
  return readTrimmed(raw).replace(/\/+$/, "");
}

export function buildEventFrame(eventType, data, accountId) {
  const header = { event_type: eventType };
  const normalizedAccountId = readTrimmed(accountId);
  if (normalizedAccountId) {
    header.account_id = normalizedAccountId;
  }
  return {
    type: "event",
    payload: {
      header,
      event: data,
    },
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const sdkRoot = path.resolve(
    readTrimmed(args["sdk-root"]) ||
      path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "tools", "feishu-official-sdk"),
  );
  const appId = readTrimmed(args["app-id"]);
  const appSecret = readTrimmed(args["app-secret"]);
  const verificationToken = readTrimmed(args["verification-token"]);
  const encryptKey = readTrimmed(args["encrypt-key"]);
  const accountId = readTrimmed(args["account-id"]);
  configureKnownSecrets([appSecret, verificationToken, encryptKey, args["token"]]);
  installConsoleStderrPatch({ prefix: "feishu-monitor" });
  if (!appId || !appSecret) {
    throw new Error("missing --app-id / --app-secret");
  }

  const requireFromSdkRoot = createRequire(path.join(sdkRoot, "package.json"));
  const Lark = requireFromSdkRoot("@larksuiteoapi/node-sdk");

  const wsClient = new Lark.WSClient({
    appId,
    appSecret,
    domain: resolveDomain(Lark, args["domain"]),
    loggerLevel: Lark.LoggerLevel.error,
  });
  const eventDispatcher = new Lark.EventDispatcher({
    verificationToken,
    encryptKey,
  });

  let shuttingDown = false;

  const cleanup = (reason) => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    try {
      wsClient.close();
    } catch (_err) {
      // best effort
    }
    writeProtocol({ type: "closed", reason });
  };

  process.on("SIGTERM", () => {
    cleanup("sigterm");
    process.exit(0);
  });
  process.on("SIGINT", () => {
    cleanup("sigint");
    process.exit(0);
  });
  process.on("uncaughtException", (err) => {
    writeProtocol({ type: "error", message: `uncaughtException: ${String(err)}` });
    cleanup("uncaught-exception");
    process.exit(1);
  });
  process.on("unhandledRejection", (err) => {
    writeProtocol({ type: "error", message: `unhandledRejection: ${String(err)}` });
  });

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on("line", (line) => {
    const trimmed = String(line ?? "").trim();
    if (!trimmed) return;
    try {
      const msg = JSON.parse(trimmed);
      if (msg?.type === "stop") {
        cleanup("stop");
        process.exit(0);
      }
    } catch (err) {
      writeProtocol({ type: "error", message: `invalid-control-frame: ${String(err)}` });
    }
  });

  eventDispatcher.register({
    "im.message.receive_v1": async (data) => {
      writeProtocol(buildEventFrame("im.message.receive_v1", data, accountId));
    },
    "im.chat.member.bot.added_v1": async (data) => {
      writeProtocol({ type: "log", level: "info", message: "bot-added", payload: data });
    },
    "im.chat.member.bot.deleted_v1": async (data) => {
      writeProtocol({ type: "log", level: "info", message: "bot-deleted", payload: data });
    },
  });

  writeDiagnostic("info", "starting", { sdkRoot, accountId, pid: process.pid }, { prefix: "feishu-monitor" });
  wsClient.start({ eventDispatcher });
  writeProtocol({ type: "ready" });
  await new Promise(() => {});
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  await main().catch((err) => {
    writeProtocol({ type: "error", message: `fatal: ${String(err)}` });
    process.exit(1);
  });
}
