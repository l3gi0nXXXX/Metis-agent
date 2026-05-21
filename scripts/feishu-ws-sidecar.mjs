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

function readPositiveInteger(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

export function buildRuntimeConfig(args, initFrame) {
  const secretArgFlags = ["app-secret", "verification-token", "encrypt-key"];
  const presentSecretFlag = secretArgFlags.find((key) => readTrimmed(args[key]));
  if (presentSecretFlag) {
    throw new Error("secret argv flags are not supported; send credentials in the stdin init frame");
  }
  if (initFrame?.type !== "init") {
    throw new Error("missing stdin init frame");
  }
  const appId = readTrimmed(args["app-id"]);
  const appSecret = readTrimmed(initFrame.appSecret);
  if (!appId || !appSecret) {
    throw new Error("missing --app-id / stdin appSecret");
  }
  return {
    sdkRoot: path.resolve(
      readTrimmed(args["sdk-root"]) ||
        path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "tools", "feishu-official-sdk"),
    ),
    appId,
    appSecret,
    verificationToken: readTrimmed(initFrame.verificationToken),
    encryptKey: readTrimmed(initFrame.encryptKey),
    accountId: readTrimmed(args["account-id"]),
    domain: readTrimmed(args.domain),
    initTimeoutMs: readPositiveInteger(args["init-timeout-ms"], 2000),
    startTimeoutMs: readPositiveInteger(args["start-timeout-ms"], 15000),
  };
}

export async function readInitialInitFrame(rl, { timeoutMs = 2000 } = {}) {
  return await new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      rl.off("line", onLine);
      rl.off("close", onClose);
      reject(new Error("init-timeout"));
    }, timeoutMs);
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      rl.off("line", onLine);
      rl.off("close", onClose);
      fn(value);
    };
    const onLine = (line) => {
      try {
        finish(resolve, JSON.parse(String(line ?? "").trim()));
      } catch (err) {
        finish(reject, new Error(`invalid-init-frame: ${String(err)}`));
      }
    };
    const onClose = () => finish(reject, new Error("init-stdin-closed"));
    rl.once("line", onLine);
    rl.once("close", onClose);
  });
}

export async function startWsClientWithReadiness(wsClient, { eventDispatcher }, { timeoutMs = 15000 } = {}) {
  let timer;
  try {
    await Promise.race([
      Promise.resolve().then(() => wsClient.start({ eventDispatcher })),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("starting-timeout")), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  const initFrame = await readInitialInitFrame(rl, { timeoutMs: readPositiveInteger(args["init-timeout-ms"], 2000) });
  const config = buildRuntimeConfig(args, initFrame);
  configureKnownSecrets([config.appSecret, config.verificationToken, config.encryptKey, args.token]);
  installConsoleStderrPatch({ prefix: "feishu-monitor" });

  const requireFromSdkRoot = createRequire(path.join(config.sdkRoot, "package.json"));
  const Lark = requireFromSdkRoot("@larksuiteoapi/node-sdk");

  const wsClient = new Lark.WSClient({
    appId: config.appId,
    appSecret: config.appSecret,
    domain: resolveDomain(Lark, config.domain),
    loggerLevel: Lark.LoggerLevel.error,
  });
  const eventDispatcher = new Lark.EventDispatcher({
    verificationToken: config.verificationToken,
    encryptKey: config.encryptKey,
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
      writeProtocol(buildEventFrame("im.message.receive_v1", data, config.accountId));
    },
    "im.chat.member.bot.added_v1": async (data) => {
      writeProtocol({ type: "log", level: "info", message: "bot-added", payload: data });
    },
    "im.chat.member.bot.deleted_v1": async (data) => {
      writeProtocol({ type: "log", level: "info", message: "bot-deleted", payload: data });
    },
  });

  writeDiagnostic("info", "starting", { sdkRoot: config.sdkRoot, accountId: config.accountId, pid: process.pid }, { prefix: "feishu-monitor" });
  await startWsClientWithReadiness(wsClient, { eventDispatcher }, { timeoutMs: config.startTimeoutMs });
  writeProtocol({ type: "ready" });
  await new Promise(() => {});
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  await main().catch((err) => {
    writeProtocol({ type: "error", message: `fatal: ${String(err)}` });
    process.exit(1);
  });
}
