#!/usr/bin/env node

import { AsyncLocalStorage } from "node:async_hooks";
import { Buffer } from "node:buffer";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  addKnownSecrets,
  installConsoleStderrPatch,
  writeDiagnostic,
  writeProtocol,
} from "./lib/metis-sidecar-logger.mjs";

const PREFIX = "feishu-sidecar";
const DEFAULT_READY_TIMEOUT_MS = 15_000;
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.dirname(SCRIPT_DIR);
const DEFAULT_RUNTIME_ROOT = path.join(PROJECT_ROOT, "tools", "feishu-sidecar");
const WITHDRAWN_REPLY_ERROR_CODES = new Set([230011, 231003]);
const SENSITIVE_ARG = /^(?:--)?(?:app[-_]?secret|verification[-_]?token|encrypt[-_]?key)$/i;
const DEFAULT_OPERATION_TIMEOUT_MS = 30_000;
const MAX_ACTIVE_OPERATIONS = 64;
const MAX_ACTIVE_OPERATIONS_PER_ACCOUNT = 16;
const ORPHAN_RECYCLE_THRESHOLD = 8;
const CLOSE_DRAIN_TIMEOUT_MS = 500;

let state = {
  closing: false,
  accounts: new Map(),
  protocolPending: new Map(),
  activeSdkOperations: new Map(),
  activeSdkOperationsByAccount: new Map(),
  recycleRequiredEmitted: false,
};
const accountContext = new AsyncLocalStorage();

installConsoleStderrPatch({ prefix: PREFIX });

function normalizeAccountId(value) {
  return String(value ?? "default").trim() || "default";
}

function createAccountState(accountId, frame = {}) {
  return {
    accountId,
    appId: String(frame.appId ?? ""),
    sdk: null,
    runtimeRoot: "",
    client: null,
    wsClient: null,
    eventDispatcher: null,
    seenEventIds: new Set(),
    ready: false,
    connected: false,
    lastError: null,
    closing: false,
  };
}

function currentAccount() {
  return accountContext.getStore() ?? onlyAccount();
}

function withAccount(account, fn) {
  return accountContext.run(account, fn);
}

function hasReadyAccount() {
  return [...state.accounts.values()].some((account) => account.ready);
}

function onlyAccount() {
  return state.accounts.size === 1 ? state.accounts.values().next().value : null;
}

function resolveFrameAccountId(frame) {
  if (frame && Object.prototype.hasOwnProperty.call(frame, "accountId")) {
    return normalizeAccountId(frame.accountId);
  }
  return onlyAccount()?.accountId ?? "default";
}

function accountIdOf(accountOrId) {
  if (accountOrId && typeof accountOrId === "object") {
    return normalizeAccountId(accountOrId.accountId);
  }
  return normalizeAccountId(accountOrId);
}

for (const key of ["sdk", "runtimeRoot", "client", "wsClient", "eventDispatcher", "seenEventIds"]) {
  Object.defineProperty(state, key, {
    get() {
      return currentAccount()?.[key] ?? (key === "seenEventIds" ? new Set() : null);
    },
    set(value) {
      const account = currentAccount();
      if (account) {
        account[key] = value;
      }
    },
  });
}

Object.defineProperty(state, "accountId", {
  get() {
    return currentAccount()?.accountId ?? "default";
  },
});

Object.defineProperty(state, "initialized", {
  get() {
    return Boolean(currentAccount()?.ready);
  },
  set(value) {
    const account = currentAccount();
    if (account) {
      account.ready = Boolean(value);
    }
  },
});

function emitProtocol(frame) {
  writeProtocol(frame);
}

function emitDiagnostic(accountOrId, level, phase, message, meta = {}) {
  if (["debug", "info", "warn", "error"].includes(String(accountOrId))) {
    meta = message ?? {};
    message = phase;
    phase = level;
    level = accountOrId;
    accountOrId = currentAccount() ?? "default";
  }
  const accountId = accountIdOf(accountOrId);
  const frame = {
    type: "diagnostic",
    level,
    phase,
    accountId,
    message,
    ...meta,
  };
  emitProtocol(frame);
  writeDiagnostic(level, message, { phase, accountId, ...meta }, { prefix: PREFIX });
}

function emitError(accountOrId, params) {
  if (params === undefined) {
    params = accountOrId;
    accountOrId = currentAccount() ?? "default";
  }
  emitProtocol({
    type: "error",
    accountId: accountIdOf(accountOrId),
    phase: params.phase,
    status: params.status ?? "error",
    errorKind: params.errorKind,
    requestId: params.requestId,
    message: String(params.message ?? "Feishu sidecar error"),
    ...(params.httpStatus !== undefined ? { httpStatus: params.httpStatus } : {}),
    ...(params.feishuCode !== undefined ? { feishuCode: params.feishuCode } : {}),
    ...(params.feishuMsgClass ? { feishuMsgClass: params.feishuMsgClass } : {}),
    ...(params.runtimeRoot ? { runtimeRoot: params.runtimeRoot } : {}),
    ...(params.missingPackage ? { missingPackage: params.missingPackage } : {}),
  });
}

function exitSoon(code) {
  process.exitCode = code;
  setTimeout(() => process.exit(code), 5).unref();
}

function findForbiddenArgv(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (SENSITIVE_ARG.test(token)) {
      return token;
    }
    const [key] = token.split("=", 1);
    if (SENSITIVE_ARG.test(key)) {
      return key;
    }
  }
  return "";
}

async function loadSdk() {
  const injected = process.env.METIS_FEISHU_SIDECAR_SDK?.trim();
  if (injected) {
    return import(pathToFileURL(injected).href);
  }
  return loadRuntimeModules(resolveSidecarRuntimeRoot()).sdk;
}

class DependencyPreflightError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.phase = "dependency.preflight";
    this.status = "missing_dependency";
    this.runtimeRoot = options.runtimeRoot;
    this.missingPackage = options.missingPackage;
  }
}

function resolveSidecarRuntimeRoot(frame = {}) {
  const raw = String(
    frame.runtimeRoot ??
      process.env.METIS_FEISHU_SIDECAR_RUNTIME_ROOT ??
      process.env.METIS_FEISHU_LEGACY_SIDECAR_RUNTIME_ROOT ??
      DEFAULT_RUNTIME_ROOT,
  ).trim();
  return raw ? path.resolve(raw) : DEFAULT_RUNTIME_ROOT;
}

function requireRuntimePackage(runtimeRequire, runtimeRoot, packageName) {
  try {
    return runtimeRequire(packageName);
  } catch {
    throw new DependencyPreflightError(
      `Feishu sidecar dependency missing: ${packageName} under ${runtimeRoot}`,
      { runtimeRoot, missingPackage: packageName },
    );
  }
}

function loadRuntimeModules(runtimeRoot) {
  const packageJson = path.join(runtimeRoot, "package.json");
  if (!fs.existsSync(packageJson)) {
    throw new DependencyPreflightError(
      `Feishu sidecar runtime package.json missing under ${runtimeRoot}`,
      { runtimeRoot, missingPackage: "package.json" },
    );
  }

  const runtimeRequire = createRequire(packageJson);
  const sdk = requireRuntimePackage(runtimeRequire, runtimeRoot, "@larksuiteoapi/node-sdk");
  const proxyAgentModule = requireRuntimePackage(runtimeRequire, runtimeRoot, "https-proxy-agent");
  return { sdk, proxyAgentModule, runtimeRoot };
}

async function createProxyAgent(sdk, proxyUrl, runtimeRoot) {
  if (!proxyUrl) {
    return undefined;
  }
  if (typeof sdk.HttpsProxyAgent === "function") {
    return new sdk.HttpsProxyAgent(proxyUrl);
  }
  const mod = loadRuntimeModules(runtimeRoot).proxyAgentModule;
  return new mod.HttpsProxyAgent(proxyUrl);
}

function getProxyConfig() {
  for (const source of ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"]) {
    const url = String(process.env[source] ?? "").trim();
    if (!url) {
      continue;
    }
    let scheme = "";
    try {
      scheme = new URL(url).protocol.replace(/:$/, "");
    } catch {
      scheme = "";
    }
    return { url, summary: { configured: true, source, scheme } };
  }
  return { url: "", summary: { configured: false, source: "", scheme: "" } };
}

function resolveDomain(sdk, domain) {
  const value = String(domain ?? "feishu").trim();
  if (!value || value === "feishu") {
    return sdk.Domain?.Feishu ?? "feishu";
  }
  if (value === "lark") {
    return sdk.Domain?.Lark ?? "lark";
  }
  return value.replace(/\/+$/, "");
}

function readyTimeoutMs(frame) {
  const raw = Number(frame.readyTimeoutMs);
  if (Number.isFinite(raw) && raw > 0) {
    return Math.min(Math.floor(raw), 300_000);
  }
  return DEFAULT_READY_TIMEOUT_MS;
}

async function withTimeout(promise, timeoutMs) {
  let timeout;
  try {
    return await Promise.race([
      Promise.resolve(promise),
      new Promise((_, reject) => {
        timeout = setTimeout(() => {
          const err = new Error(`Feishu sidecar did not become ready within ${timeoutMs}ms`);
          err.status = "ready_timeout";
          reject(err);
        }, timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function sidecarErrorMessage(error, fallback = "Feishu WebSocket error") {
  const message = error?.message ?? (error ? String(error) : fallback);
  return String(message || fallback);
}

function websocketStatusMeta() {
  try {
    const status = state.wsClient?.getConnectionStatus?.();
    if (!status || typeof status !== "object") {
      return {};
    }
    return {
      wsState: String(status.state ?? ""),
      reconnectAttempts: Number.isFinite(Number(status.reconnectAttempts)) ? Number(status.reconnectAttempts) : 0,
      ...(status.lastConnectTime ? { lastConnectTime: status.lastConnectTime } : {}),
      ...(status.nextConnectTime ? { nextConnectTime: status.nextConnectTime } : {}),
    };
  } catch {
    return {};
  }
}

async function initialize(frame, options = {}) {
  const legacy = options.legacy === true;
  const operation = options.operation;
  const phase = legacy ? "init" : "initAccount";
  const accountId = normalizeAccountId(frame.accountId);
  if (state.accounts.has(accountId)) {
    emitInitError(operation, accountId, {
      phase,
      status: legacy ? "already_initialized" : "conflict",
      message: `Feishu sidecar account ${accountId} is already initialized`,
    });
    return;
  }

  const account = createAccountState(accountId, frame);
  state.accounts.set(accountId, account);
  addKnownSecrets([frame.appSecret, frame.verificationToken, frame.encryptKey]);
  const mode = String(frame.mode ?? "websocket").trim().toLowerCase();
  const apiMode = mode === "api" || mode === "rest" || mode === "request";
  if (!frame.appId || !frame.appSecret) {
    emitInitError(operation, account, { phase, status: "invalid_init", message: "Feishu init requires appId and appSecret" });
    state.accounts.delete(accountId);
    if (legacy) {
      exitSoon(1);
    }
    return;
  }
  return withAccount(account, async () => {
    try {
      account.runtimeRoot = resolveSidecarRuntimeRoot(frame);
      const sdk = process.env.METIS_FEISHU_SIDECAR_SDK?.trim()
        ? await loadSdk()
        : loadRuntimeModules(account.runtimeRoot).sdk;
      account.sdk = sdk;
      const domain = resolveDomain(sdk, frame.domain);
      const proxy = getProxyConfig();
      const proxyAgent = await createProxyAgent(sdk, proxy.url, account.runtimeRoot);

      emitDiagnostic("info", "dependency.preflight", "Feishu sidecar dependencies resolved", {
        status: "ok",
        runtimeRoot: account.runtimeRoot,
        sdk: "@larksuiteoapi/node-sdk",
        proxyAgent: "https-proxy-agent",
      });

      let readySettled = false;
      let resolveReady;
      let rejectReady;
      const readyPromise = new Promise((resolve, reject) => {
        resolveReady = resolve;
        rejectReady = reject;
      });
      const resolveReadyOnce = () => {
        if (readySettled) {
          return;
        }
        readySettled = true;
        resolveReady();
      };
      const rejectReadyOnce = (error) => {
        if (readySettled) {
          return;
        }
        readySettled = true;
        rejectReady(error);
      };
      const lifecycle = {
        onReady: () => withAccount(account, () => {
          account.connected = true;
          emitDiagnostic("info", "websocket.open", "Feishu WebSocket client connected", {
            status: "connected",
            ...websocketStatusMeta(),
          });
          resolveReadyOnce();
        }),
        onError: (error) => withAccount(account, () => {
          const message = sidecarErrorMessage(error);
          account.connected = false;
          account.lastError = error;
          emitDiagnostic("error", "websocket.error", message, {
            status: "failed",
            ...websocketStatusMeta(),
          });
          rejectReadyOnce(error instanceof Error ? error : new Error(message));
        }),
        onReconnecting: () => withAccount(account, () => {
          account.connected = false;
          emitDiagnostic("warn", "websocket.reconnecting", "Feishu WebSocket client reconnecting", {
            status: "reconnecting",
            ...websocketStatusMeta(),
          });
        }),
        onReconnected: () => withAccount(account, () => {
          account.connected = true;
          emitDiagnostic("info", "websocket.reconnected", "Feishu WebSocket client reconnected", {
            status: "connected",
            ...websocketStatusMeta(),
          });
        }),
      };

      account.client = new sdk.Client({
        appId: frame.appId,
        appSecret: frame.appSecret,
        appType: sdk.AppType?.SelfBuild,
        domain,
      });
      if (apiMode) {
        account.ready = true;
        account.connected = true;
        emitDiagnostic("info", "api.start", "Feishu REST API client ready", {
          status: "ok",
        });
        emitInitProtocol(operation, {
          type: "ready",
          accountId,
          transport: "api",
          sdk: "@larksuiteoapi/node-sdk",
          runtimeRoot: account.runtimeRoot,
          proxy: proxy.summary,
          domain: String(frame.domain ?? "feishu"),
        });
        if (operation?.timedOut) {
          await closeAccountState(account, "late_init", { remove: true, emitClosed: false });
        }
        return;
      }
      account.eventDispatcher = new sdk.EventDispatcher({
        encryptKey: frame.encryptKey,
        verificationToken: frame.verificationToken,
      });
      registerEventHandlers(account, account.eventDispatcher);
      account.wsClient = new sdk.WSClient({
        appId: frame.appId,
        appSecret: frame.appSecret,
        domain,
        loggerLevel: sdk.LoggerLevel?.info,
        ...lifecycle,
        ...(proxyAgent ? { agent: proxyAgent } : {}),
      });
      attachWsLifecycleHandlers(account, account.wsClient);

      const startResult = account.wsClient.start({ eventDispatcher: account.eventDispatcher });
      if (startResult && typeof startResult.then === "function") {
        startResult.catch((error) => rejectReadyOnce(error));
      }
      await withTimeout(readyPromise, readyTimeoutMs(frame));
      account.ready = true;
      emitDiagnostic("info", "websocket.start", "Feishu WebSocket client started", {
        status: "ok",
        ...websocketStatusMeta(),
      });
      emitInitProtocol(operation, {
        type: "ready",
        accountId,
        transport: "websocket",
        sdk: "@larksuiteoapi/node-sdk",
        runtimeRoot: account.runtimeRoot,
        proxy: proxy.summary,
        domain: String(frame.domain ?? "feishu"),
      });
      if (operation?.timedOut) {
        await closeAccountState(account, "late_init", { remove: true, emitClosed: false });
      }
    } catch (error) {
      account.lastError = error;
      if (error?.phase === "dependency.preflight") {
        emitInitError(operation, account, {
          phase: "dependency.preflight",
          status: error.status ?? "missing_dependency",
          message: error.message,
          runtimeRoot: error.runtimeRoot,
          missingPackage: error.missingPackage,
        });
        state.accounts.delete(accountId);
        if (legacy) {
          exitSoon(1);
        }
        return;
      }
      const status = error?.status ?? "start_failed";
      emitInitError(operation, account, {
        phase: "websocket.start",
        status,
        message: error?.message ?? String(error),
      });
      if (operation?.timedOut) {
        await closeAccountState(account, status, { remove: true, emitClosed: false });
      } else {
        await closeSidecar(status);
      }
      state.accounts.delete(accountId);
      if (legacy) {
        exitSoon(1);
      }
    }
  });
}

function attachWsLifecycleHandlers(account, wsClient) {
  if (!wsClient || typeof wsClient !== "object") {
    return;
  }
  const on = typeof wsClient.on === "function" ? wsClient.on.bind(wsClient) : undefined;
  const once = typeof wsClient.once === "function" ? wsClient.once.bind(wsClient) : on;
  if (!once) {
    return;
  }
  const handleClose = (error) => {
    void withAccount(account, async () => {
      const message = error?.message ?? (error ? String(error) : "Feishu WebSocket client closed");
      account.connected = false;
      account.lastError = error;
      emitDiagnostic("error", "websocket.closed", message, { status: "closed" });
      await closeSidecar("sdk_close");
    });
  };
  try {
    once("close", handleClose);
    once("closed", handleClose);
    once("error", handleClose);
  } catch (error) {
    emitDiagnostic(account, "warn", "websocket.lifecycle", "Unable to attach Feishu WebSocket lifecycle handlers", {
      status: "handler_attach_failed",
      message: error?.message ?? String(error),
    });
  }
}

function registerEventHandlers(account, eventDispatcher) {
  const handlers = {};
  for (const eventType of [
    "im.message.receive_v1",
    "im.message.message_read_v1",
    "im.chat.member.bot.added_v1",
    "im.chat.member.bot.deleted_v1",
    "drive.notice.comment_add_v1",
    "drive.file.comment.created_v1",
    "im.message.reaction.created_v1",
    "im.message.reaction.deleted_v1",
    "application.bot.menu_v6",
    "card.action.trigger",
    "vc.meeting.invited_v1",
    "bitable.field.changed_v1",
  ]) {
    handlers[eventType] = async (data) => withAccount(account, () => handleSdkEvent(eventType, data));
  }
  eventDispatcher.register(handlers);
}

async function handleSdkEvent(eventType, data) {
  try {
    if (eventType === "im.message.message_read_v1") {
      emitDiagnostic("debug", "event.ignored", "Ignoring Feishu read receipt", { eventType });
      return;
    }

    const event = extractEvent(data);
    const eventId = resolveEventId(eventType, event);
    if (eventId && state.seenEventIds.has(eventId)) {
      emitDiagnostic("debug", "event.duplicate", "Dropping duplicate Feishu event", { eventType, eventId });
      return;
    }
    if (eventId) {
      state.seenEventIds.add(eventId);
    }

    if (eventType === "im.message.receive_v1") {
      const inbound = buildMessageInbound(eventType, event);
      if (!inbound) {
        emitDiagnostic("warn", "event.malformed", "Ignoring malformed Feishu message event", { eventType });
        return;
      }
      emitProtocol(inbound);
      return;
    }

    emitProtocol({
      type: "inbound",
      accountId: state.accountId,
      eventType,
      event,
    });
  } catch (error) {
    emitError({ phase: "event.dispatch", status: "handler_error", message: error?.message ?? String(error) });
  }
}

function extractEvent(data) {
  if (data?.event && typeof data.event === "object") {
    return data.event;
  }
  if (data?.schema && data?.header && data?.event) {
    return data.event;
  }
  return data;
}

function resolveEventId(eventType, event) {
  const messageId = event?.message?.message_id;
  return (
    event?.event_id ??
    event?.header?.event_id ??
    event?.uuid ??
    (eventType === "im.message.receive_v1" && typeof messageId === "string" ? `message:${messageId}` : "")
  );
}

function parseJsonObject(raw) {
  if (!raw || typeof raw !== "string") {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function parseMessageText(messageType, content) {
  if (messageType === "text") {
    return typeof content.text === "string" ? content.text : "";
  }
  if (messageType === "post") {
    return flattenPostContent(content);
  }
  if (typeof content.text === "string") {
    return content.text;
  }
  if (typeof content.title === "string") {
    return content.title;
  }
  return "";
}

function flattenPostContent(content) {
  const locales = ["zh_cn", "en_us", "ja_jp"];
  const pieces = [];
  for (const locale of locales) {
    const blocks = content?.[locale]?.content;
    if (!Array.isArray(blocks)) {
      continue;
    }
    for (const line of blocks) {
      if (!Array.isArray(line)) {
        continue;
      }
      for (const item of line) {
        if (typeof item?.text === "string") {
          pieces.push(item.text);
        } else if (typeof item?.content === "string") {
          pieces.push(item.content);
        }
      }
      pieces.push("\n");
    }
    if (pieces.length > 0) {
      break;
    }
  }
  return pieces.join("").trim();
}

function buildMediaDescriptor(messageType, content) {
  if (messageType === "image") {
    return { kind: "image", imageKey: content.image_key ?? content.imageKey ?? "" };
  }
  if (messageType === "file") {
    return {
      kind: "file",
      fileKey: content.file_key ?? content.fileKey ?? "",
      fileName: content.file_name ?? content.fileName,
      fileSize: content.file_size ?? content.fileSize,
    };
  }
  if (messageType === "audio") {
    return {
      kind: "audio",
      fileKey: content.file_key ?? content.fileKey ?? "",
      duration: content.duration,
    };
  }
  if (messageType === "media" || messageType === "video") {
    return {
      kind: "video",
      fileKey: content.file_key ?? content.fileKey ?? "",
      fileName: content.file_name ?? content.fileName,
    };
  }
  if (messageType === "sticker") {
    return {
      kind: "sticker",
      stickerKey: content.sticker_key ?? content.stickerKey ?? "",
      imageKey: content.image_key ?? content.imageKey,
      fileKey: content.file_key ?? content.fileKey,
    };
  }
  return undefined;
}

function resolveSenderId(sender) {
  return (
    sender?.sender_id?.open_id ??
    sender?.sender_id?.user_id ??
    sender?.sender_id?.union_id ??
    sender?.sender_id?.id ??
    ""
  );
}

function buildMessageInbound(eventType, event) {
  const message = event?.message;
  if (!message || typeof message !== "object") {
    return null;
  }
  const messageType = String(message.message_type ?? message.msg_type ?? "unknown");
  const content = parseJsonObject(message.content);
  const media = buildMediaDescriptor(messageType, content);
  return {
    type: "inbound",
    accountId: state.accountId,
    eventType,
    messageType,
    message: {
      messageId: message.message_id ?? "",
      chatId: message.chat_id ?? "",
      chatType: message.chat_type,
      rootId: message.root_id,
      parentId: message.parent_id,
      threadId: message.thread_id,
      senderId: resolveSenderId(event.sender),
      senderType: event.sender?.sender_type,
      text: parseMessageText(messageType, content),
      rawContent: message.content ?? "",
      mentions: message.mentions,
    },
    ...(media ? { media } : {}),
    event,
  };
}

function resolveReceiveId(frame) {
  return String(frame.to ?? frame.receiveId ?? frame.chatId ?? "").trim();
}

function resolveReceiveIdType(frame) {
  return String(frame.receiveIdType ?? "chat_id").trim() || "chat_id";
}

function buildPostContent(text) {
  return JSON.stringify({
    zh_cn: {
      content: [
        [
          {
            tag: "md",
            text: String(text ?? ""),
          },
        ],
      ],
    },
  });
}

function isWithdrawnReplyResponse(response) {
  return isSafeReplyFallbackError(response);
}

function apiHttpStatus(errorOrResponse) {
  const raw =
    errorOrResponse?.response?.status ??
    errorOrResponse?.status ??
    errorOrResponse?.statusCode ??
    errorOrResponse?.httpStatus;
  const value = Number(raw);
  return Number.isFinite(value) && value > 0 ? value : undefined;
}

function apiFeishuCode(errorOrResponse) {
  const raw = errorOrResponse?.response?.data?.code ?? errorOrResponse?.data?.code ?? errorOrResponse?.code;
  return typeof raw === "number" ? raw : undefined;
}

function apiFeishuMessage(errorOrResponse) {
  return String(
    errorOrResponse?.response?.data?.msg ??
      errorOrResponse?.response?.data?.message ??
      errorOrResponse?.data?.msg ??
      errorOrResponse?.data?.message ??
      errorOrResponse?.msg ??
      errorOrResponse?.message ??
      "",
  );
}

function feishuMsgClass(errorOrResponse) {
  const msg = apiFeishuMessage(errorOrResponse).toLowerCase();
  if (msg.includes("scope") || msg.includes("permission") || msg.includes("auth") || msg.includes("unauthorized") || msg.includes("forbidden")) {
    return "scope_auth";
  }
  if (isSafeReplyFallbackError(errorOrResponse)) {
    return "reply_target_unavailable";
  }
  return "api_error";
}

function isScopeAuthError(errorOrResponse) {
  const code = apiFeishuCode(errorOrResponse);
  if (code === 99991663 || code === 99991664) {
    return true;
  }
  const msg = apiFeishuMessage(errorOrResponse).toLowerCase();
  return msg.includes("scope") || msg.includes("permission") || msg.includes("auth") || msg.includes("unauthorized") || msg.includes("forbidden");
}

function isSafeReplyFallbackError(error) {
  if (isScopeAuthError(error)) {
    return false;
  }
  const code = apiFeishuCode(error);
  if (typeof code === "number" && WITHDRAWN_REPLY_ERROR_CODES.has(code)) {
    return true;
  }
  const msg = apiFeishuMessage(error).toLowerCase();
  const targetUnavailable =
    msg.includes("message_unavailable") ||
    msg.includes("not_found") ||
    msg.includes("not found") ||
    msg.includes("unavailable") ||
    msg.includes("reply target") ||
    msg.includes("deleted") ||
    msg.includes("recalled") ||
    msg.includes("withdrawn");
  if (targetUnavailable) {
    return true;
  }
  const status = apiHttpStatus(error);
  return status === 400 && msg.includes("reply failed");
}

function isWithdrawnReplyError(error) {
  return isSafeReplyFallbackError(error);
}

function classifyApiError(errorOrResponse) {
  const code = apiFeishuCode(errorOrResponse);
  if (isScopeAuthError(errorOrResponse)) {
    return "scope_missing";
  }
  return "api_error";
}

function assertApiSuccess(response, errorPrefix) {
  if (response?.code !== undefined && response.code !== 0) {
    const error = new Error(`${errorPrefix}: ${response.msg || `code ${response.code}`}`);
    error.code = response.code;
    error.response = { data: response };
    throw error;
  }
}

function toSendResult(response, fallbackChatId = "") {
  return {
    messageId: response?.data?.message_id ?? response?.message_id ?? "",
    chatId: response?.data?.chat_id ?? response?.chat_id ?? fallbackChatId,
  };
}

async function sendCreate(params) {
  const response = await state.client.im.message.create({
    params: { receive_id_type: params.receiveIdType },
    data: {
      receive_id: params.receiveId,
      content: params.content,
      msg_type: params.msgType,
    },
  });
  assertApiSuccess(response, params.errorPrefix);
  return toSendResult(response, params.receiveId);
}

async function sendReplyOrCreate(params) {
  if (!params.replyToMessageId) {
    return sendCreate(params.direct);
  }
  const noThreadFallback = new Error(
    "Feishu thread reply failed: reply target is unavailable and cannot safely fall back to a top-level send.",
  );
  let response;
  try {
    response = await state.client.im.message.reply({
      path: { message_id: params.replyToMessageId },
      data: {
        content: params.content,
        msg_type: params.msgType,
        ...(params.replyInThread ? { reply_in_thread: true } : {}),
      },
    });
  } catch (error) {
    if (!isWithdrawnReplyError(error)) {
      throw error;
    }
    if (params.replyInThread) {
      throw noThreadFallback;
    }
    return sendCreate(params.direct);
  }
  if (isWithdrawnReplyResponse(response)) {
    if (params.replyInThread) {
      throw noThreadFallback;
    }
    return sendCreate(params.direct);
  }
  assertApiSuccess(response, params.replyErrorPrefix);
  return toSendResult(response, params.direct.receiveId);
}

async function handleSend(frame) {
  if (!state.initialized || !state.client) {
    emitError({
      phase: "send",
      status: "not_ready",
      requestId: frame.requestId,
      message: "Feishu sidecar is not ready",
    });
    return;
  }
  try {
    const result = await dispatchSend(frame);
    emitProtocol({
      type: "sendResult",
      accountId: state.accountId,
      requestId: frame.requestId,
      action: frame.action,
      ok: true,
      ...result,
    });
  } catch (error) {
    const httpStatus = apiHttpStatus(error);
    const feishuCode = apiFeishuCode(error);
    emitError({
      phase: `send.${frame.action ?? "unknown"}`,
      status: "api_error",
      errorKind: classifyApiError(error),
      requestId: frame.requestId,
      message: error?.message ?? String(error),
      ...(httpStatus !== undefined ? { httpStatus } : {}),
      ...(feishuCode !== undefined ? { feishuCode } : {}),
      feishuMsgClass: feishuMsgClass(error),
    });
  }
}

async function dispatchSend(frame) {
  const action = String(frame.action ?? "").trim();
  switch (action) {
    case "sendText":
    case "text":
      return sendText(frame);
    case "sendMedia":
    case "media":
      return sendMedia(frame);
    case "uploadMedia":
    case "media.upload":
      return uploadMediaOnly(frame);
    case "sendCard":
    case "card":
      return sendCard(frame);
    case "patchCard":
    case "updateCard":
    case "card.patch":
    case "card.finalize":
    case "card.abort":
      return patchCard(frame);
    case "addReaction":
    case "reaction.add":
      return addReaction(frame);
    case "removeReaction":
    case "reaction.remove":
      return removeReaction(frame);
    case "listReactions":
    case "reaction.list":
      return listReactions(frame);
    case "deleteMessage":
    case "delete":
      return deleteMessage(frame);
    case "fetchMessage":
    case "message.fetch":
      return fetchMessage(frame);
    case "listMergeForward":
    case "message.list_merge_forward":
      return listMergeForwardMessages(frame);
    case "chat.thread_capable":
      return chatThreadCapable(frame);
    case "downloadImage":
      return downloadImage(frame);
    case "downloadResource":
      return downloadResource(frame);
    default:
      throw new Error(`Unsupported Feishu sidecar send action: ${action || "missing"}`);
  }
}

async function uploadMediaOnly(frame) {
  const mediaType = String(frame.mediaType ?? "").trim().toLowerCase();
  if (mediaType === "image" || frame.imageKey) {
    const imageKey = await uploadImage(frame);
    return { imageKey, mediaKey: imageKey };
  }
  const fileType = String(frame.fileType ?? detectFileType(frame.fileName, mediaType));
  const fileKey = await uploadFile(frame, fileType);
  return { fileKey, mediaKey: fileKey, fileType };
}

async function sendText(frame) {
  const receiveId = resolveReceiveId(frame);
  const receiveIdType = resolveReceiveIdType(frame);
  const msgType = frame.msgType === "text" ? "text" : "post";
  const content =
    msgType === "text" ? JSON.stringify({ text: String(frame.text ?? "") }) : buildPostContent(frame.text);
  return sendReplyOrCreate({
    replyToMessageId: frame.replyToMessageId,
    replyInThread: frame.replyInThread === true,
    content,
    msgType,
    replyErrorPrefix: "Feishu reply failed",
    direct: {
      receiveId,
      receiveIdType,
      content,
      msgType,
      errorPrefix: "Feishu send failed",
    },
  });
}

function detectFileType(fileName, mediaType) {
  const name = String(fileName ?? "").toLowerCase();
  if (mediaType === "audio" || mediaType === "opus" || mediaType === "ogg" || name.endsWith(".opus") || name.endsWith(".ogg")) {
    return "opus";
  }
  if (
    mediaType === "video" ||
    mediaType === "media" ||
    mediaType === "mp4" ||
    mediaType === "mov" ||
    mediaType === "avi" ||
    name.endsWith(".mp4") ||
    name.endsWith(".mov") ||
    name.endsWith(".avi")
  ) {
    return "mp4";
  }
  if (name.endsWith(".pdf")) return "pdf";
  if (name.endsWith(".doc") || name.endsWith(".docx")) return "doc";
  if (name.endsWith(".xls") || name.endsWith(".xlsx")) return "xls";
  if (name.endsWith(".ppt") || name.endsWith(".pptx")) return "ppt";
  return "stream";
}

function msgTypeForMedia(fileType, mediaType) {
  if (mediaType === "image") return "image";
  if (mediaType === "audio" || mediaType === "opus" || mediaType === "ogg" || fileType === "opus") return "audio";
  if (
    mediaType === "video" ||
    mediaType === "media" ||
    mediaType === "mp4" ||
    mediaType === "mov" ||
    mediaType === "avi" ||
    fileType === "mp4"
  ) {
    return "media";
  }
  return "file";
}

function decodeContentBuffer(frame) {
  if (typeof frame.contentBase64 === "string") {
    return Buffer.from(frame.contentBase64, "base64");
  }
  if (typeof frame.content === "string") {
    return Buffer.from(frame.content);
  }
  return Buffer.alloc(0);
}

function isFilesystemRoot(candidate) {
  const normalized = path.resolve(candidate);
  return normalized === path.parse(normalized).root;
}

function isPathWithinRoot(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function resolveAllowedLocalRoots(frame) {
  const rawRoots = Array.isArray(frame.allowedLocalRoots)
    ? frame.allowedLocalRoots
    : typeof frame.allowedLocalRoots === "string"
      ? [frame.allowedLocalRoots]
      : [];
  const roots = rawRoots.map((entry) => String(entry ?? "").trim()).filter(Boolean);
  if (roots.length === 0) {
    throw new Error("localPath upload requires non-empty allowed roots");
  }
  return roots.map((root) => {
    if (!path.isAbsolute(root)) {
      throw new Error("configured localPath root is not allowed");
    }
    let realRoot;
    try {
      realRoot = fs.realpathSync(root);
    } catch {
      throw new Error("configured localPath root is unavailable");
    }
    if (isFilesystemRoot(realRoot)) {
      throw new Error("configured localPath root is not allowed");
    }
    return realRoot;
  });
}

function assertLocalPathUploadAllowed(localPath, allowedRoots) {
  const rawPath = String(localPath ?? "").trim();
  if (!rawPath || !path.isAbsolute(rawPath)) {
    throw new Error("localPath upload requires an absolute path");
  }

  let realPath;
  try {
    realPath = fs.realpathSync(rawPath);
  } catch {
    throw new Error("localPath file is unavailable");
  }
  if (!allowedRoots.some((root) => isPathWithinRoot(realPath, root))) {
    throw new Error("path outside configured roots");
  }

  let stat;
  try {
    stat = fs.statSync(realPath);
  } catch {
    throw new Error("localPath file is unavailable");
  }
  if (!stat.isFile()) {
    throw new Error("localPath target is not a regular file");
  }
  return { realPath, stat };
}

function resolveUploadContent(frame) {
  if (String(frame.sourceKind ?? "").trim() !== "localPath") {
    return decodeContentBuffer(frame);
  }
  const allowedRoots = resolveAllowedLocalRoots(frame);
  const { realPath, stat } = assertLocalPathUploadAllowed(frame.localPath, allowedRoots);
  if (frame.byteCount !== undefined && frame.byteCount !== null) {
    const expected = Number(frame.byteCount);
    if (!Number.isSafeInteger(expected) || expected < 0 || expected !== stat.size) {
      throw new Error("localPath byte count mismatch");
    }
  }
  return fs.createReadStream(realPath);
}

async function uploadImage(frame) {
  if (frame.imageKey) {
    return String(frame.imageKey);
  }
  const response = await state.client.im.image.create({
    data: {
      image_type: frame.imageType ?? "message",
      image: resolveUploadContent(frame),
    },
  });
  assertApiSuccess(response, "Feishu image upload failed");
  const imageKey = response?.data?.image_key ?? response?.image_key;
  if (!imageKey) {
    throw new Error("Feishu image upload failed: no image_key returned");
  }
  return imageKey;
}

async function uploadFile(frame, fileType) {
  if (frame.fileKey) {
    return String(frame.fileKey);
  }
  const response = await state.client.im.file.create({
    data: {
      file_type: fileType,
      file_name: String(frame.fileName ?? "file").replace(/[\x00-\x1F\x7F\r\n"\\]/g, "_"),
      file: resolveUploadContent(frame),
      ...(frame.duration !== undefined ? { duration: frame.duration } : {}),
    },
  });
  assertApiSuccess(response, "Feishu file upload failed");
  const fileKey = response?.data?.file_key ?? response?.file_key;
  if (!fileKey) {
    throw new Error("Feishu file upload failed: no file_key returned");
  }
  return fileKey;
}

async function sendMedia(frame) {
  const mediaType = String(frame.mediaType ?? "").trim().toLowerCase();
  const receiveId = resolveReceiveId(frame);
  const receiveIdType = resolveReceiveIdType(frame);
  let content;
  let msgType;
  if (mediaType === "image" || frame.imageKey) {
    const imageKey = await uploadImage(frame);
    content = JSON.stringify({ image_key: imageKey });
    msgType = "image";
  } else {
    const fileType = String(frame.fileType ?? detectFileType(frame.fileName, mediaType));
    const fileKey = await uploadFile(frame, fileType);
    content = JSON.stringify({ file_key: fileKey });
    msgType = msgTypeForMedia(fileType, mediaType);
  }
  return sendReplyOrCreate({
    replyToMessageId: frame.replyToMessageId,
    replyInThread: frame.replyInThread === true,
    content,
    msgType,
    replyErrorPrefix: "Feishu media reply failed",
    direct: {
      receiveId,
      receiveIdType,
      content,
      msgType,
      errorPrefix: "Feishu media send failed",
    },
  });
}

async function sendCard(frame) {
  const receiveId = resolveReceiveId(frame);
  const receiveIdType = resolveReceiveIdType(frame);
  const content = JSON.stringify(frame.card ?? {});
  const msgType = "interactive";
  return sendReplyOrCreate({
    replyToMessageId: frame.replyToMessageId,
    replyInThread: frame.replyInThread === true,
    content,
    msgType,
    replyErrorPrefix: "Feishu card reply failed",
    direct: {
      receiveId,
      receiveIdType,
      content,
      msgType,
      errorPrefix: "Feishu card send failed",
    },
  });
}

async function patchCard(frame) {
  const messageId = String(frame.messageId ?? "").trim();
  if (!messageId) {
    throw new Error("Feishu card patch requires messageId");
  }
  const response = await state.client.im.message.patch({
    path: { message_id: messageId },
    data: { content: JSON.stringify(frame.card ?? {}) },
  });
  assertApiSuccess(response, "Feishu card update failed");
  return { messageId };
}

async function addReaction(frame) {
  const response = await state.client.im.messageReaction.create({
    path: { message_id: frame.messageId },
    data: {
      reaction_type: {
        emoji_type: frame.emojiType,
      },
    },
  });
  assertApiSuccess(response, "Feishu add reaction failed");
  return { reactionId: response?.data?.reaction_id ?? response?.reaction_id ?? "" };
}

async function removeReaction(frame) {
  let reactionId = String(frame.reactionId ?? "").trim();
  if (!reactionId && frame.emojiType) {
    const matches = await listReactions({
      ...frame,
      reactionType: frame.emojiType,
    });
    reactionId = matches.reactions.find((entry) => entry.emojiType === frame.emojiType)?.reactionId ?? "";
  }
  if (!reactionId) {
    throw new Error("Feishu remove reaction requires reactionId");
  }
  const response = await state.client.im.messageReaction.delete({
    path: {
      message_id: frame.messageId,
      reaction_id: reactionId,
    },
  });
  assertApiSuccess(response, "Feishu remove reaction failed");
  return { messageId: frame.messageId, reactionId };
}

async function listReactions(frame) {
  const reactionType = String(frame.reactionType ?? frame.emojiType ?? "").trim();
  const response = await state.client.im.messageReaction.list({
    path: { message_id: frame.messageId },
    ...(reactionType ? { params: { reaction_type: reactionType } } : {}),
  });
  assertApiSuccess(response, "Feishu list reactions failed");
  const items = response?.data?.items ?? response?.items ?? [];
  return {
    messageId: frame.messageId,
    reactions: items.map((item) => ({
      reactionId: item.reaction_id ?? item.reactionId ?? "",
      emojiType: item.reaction_type?.emoji_type ?? item.emojiType ?? "",
      operatorType: item.operator_type ?? item.operatorType ?? "",
      operatorId:
        item.operator_id?.open_id ??
        item.operator_id?.user_id ??
        item.operator_id?.union_id ??
        item.operatorId ??
        "",
    })),
  };
}

async function deleteMessage(frame) {
  const messageId = String(frame.messageId ?? "").trim();
  if (!messageId) {
    throw new Error("Feishu delete requires messageId");
  }
  const response = await state.client.im.message.delete({
    path: { message_id: messageId },
  });
  assertApiSuccess(response, "Feishu delete failed");
  return { messageId };
}

function normalizeMessageItem(item, fallbackMessageId = "") {
  const body = item?.body && typeof item.body === "object" ? item.body : {};
  const content = item?.content ?? body.content ?? "";
  const normalizedContent = typeof content === "string" ? content : JSON.stringify(content ?? {});
  return {
    messageId: item?.message_id ?? item?.messageId ?? fallbackMessageId,
    messageType: item?.message_type ?? item?.msg_type ?? item?.messageType ?? "",
    content: normalizedContent,
    raw: JSON.stringify(item ?? {}),
  };
}

async function fetchMessage(frame) {
  const messageId = String(frame.messageId ?? "").trim();
  if (!messageId) {
    throw new Error("Feishu message fetch requires messageId");
  }
  const response = await state.client.im.message.get({
    path: { message_id: messageId },
  });
  assertApiSuccess(response, "Feishu message fetch failed");
  const data = response?.data ?? response ?? {};
  const item = Array.isArray(data.items) ? data.items[0] : data.message ?? data;
  return normalizeMessageItem(item ?? {}, messageId);
}

async function listMergeForwardMessages(frame) {
  const messageId = String(frame.messageId ?? "").trim();
  if (!messageId) {
    throw new Error("Feishu merge_forward fetch requires messageId");
  }
  const response = await state.client.im.message.get({
    path: { message_id: messageId },
  });
  assertApiSuccess(response, "Feishu merge_forward fetch failed");
  const items = response?.data?.items ?? response?.items ?? [];
  return {
    messageId,
    messages: items.map((item) => normalizeMessageItem(item, item?.message_id ?? "")),
  };
}

async function chatThreadCapable(frame) {
  const chatId = String(frame.chatId ?? frame.receiveId ?? frame.to ?? "").trim();
  if (!chatId || !state.client.im.chat?.get) {
    return { chatId, capable: Boolean(chatId) };
  }
  const response = await state.client.im.chat.get({
    path: { chat_id: chatId },
  });
  assertApiSuccess(response, "Feishu chat fetch failed");
  const data = response?.data ?? {};
  return {
    chatId,
    capable: data.chat_mode === "thread" || data.thread_mode === true || data.chat_type === "group",
  };
}

async function readStreamBuffer(stream) {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

async function withTempDownloadPath(prefix, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  try {
    const target = path.join(dir, "download");
    return await fn(target);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function responseBuffer(response) {
  if (Buffer.isBuffer(response)) {
    return response;
  }
  if (response instanceof ArrayBuffer) {
    return Buffer.from(response);
  }
  if (Buffer.isBuffer(response?.data)) {
    return response.data;
  }
  if (response?.data?.type === "Buffer" && Array.isArray(response.data.data)) {
    return Buffer.from(response.data.data);
  }
  if (response?.data instanceof ArrayBuffer) {
    return Buffer.from(response.data);
  }
  if (typeof response?.getReadableStream === "function") {
    return await readStreamBuffer(response.getReadableStream());
  }
  if (typeof response?.writeFile === "function") {
    return await withTempDownloadPath("metis-feishu-sidecar-download-", async (target) => {
      await response.writeFile(target);
      return fs.readFileSync(target);
    });
  }
  if (typeof response?.[Symbol.asyncIterator] === "function") {
    return await readStreamBuffer(response);
  }
  if (typeof response?.pipe === "function" || typeof response?.read === "function") {
    return await readStreamBuffer(response);
  }
  return Buffer.alloc(0);
}

function contentTypeOf(response) {
  return response?.headers?.["content-type"] ?? response?.header?.["content-type"] ?? response?.contentType;
}

function fileNameOf(response) {
  return response?.file_name ?? response?.fileName ?? response?.data?.file_name ?? response?.data?.fileName;
}

async function nonEmptyDownloadBuffer(response, errorPrefix) {
  const buffer = await responseBuffer(response);
  if (buffer.length <= 0) {
    throw new Error(`${errorPrefix}: empty response buffer`);
  }
  return buffer;
}

async function downloadImage(frame) {
  const response = await state.client.im.image.get({
    path: { image_key: frame.imageKey },
  });
  assertApiSuccess(response, "Feishu image download failed");
  const buffer = await nonEmptyDownloadBuffer(response, "Feishu image download failed");
  return {
    contentBase64: buffer.toString("base64"),
    bytesBase64: buffer.toString("base64"),
    contentType: contentTypeOf(response),
    fileName: fileNameOf(response),
    size: buffer.length,
  };
}

async function downloadResource(frame) {
  const response = await state.client.im.messageResource.get({
    path: { message_id: frame.messageId, file_key: frame.fileKey },
    params: { type: frame.resourceType === "image" ? "image" : "file" },
  });
  assertApiSuccess(response, "Feishu message resource download failed");
  const buffer = await nonEmptyDownloadBuffer(response, "Feishu message resource download failed");
  return {
    contentBase64: buffer.toString("base64"),
    bytesBase64: buffer.toString("base64"),
    contentType: contentTypeOf(response),
    fileName: fileNameOf(response),
    size: buffer.length,
  };
}

async function closeAccountState(account, reason = "stop", options = {}) {
  if (!account || account.closing) {
    return;
  }
  account.closing = true;
  account.ready = false;
  account.connected = false;
  try {
    account.wsClient?.close?.();
  } catch (error) {
    writeDiagnostic("warn", `error closing Feishu WS client: ${error?.message ?? String(error)}`, undefined, {
      prefix: PREFIX,
    });
  }
  if (options.emitClosed !== false) {
    emitProtocol({
      type: "closed",
      accountId: account.accountId,
      reason,
    });
  }
  if (options.remove) {
    state.accounts.delete(account.accountId);
  }
}

async function closeSidecar(reason = "stop") {
  const account = currentAccount();
  if (!account) {
    return;
  }
  await closeAccountState(account, reason);
}

async function closeAllAccounts(reason = "stop") {
  if (state.closing) {
    return;
  }
  state.closing = true;
  await drainOperations(CLOSE_DRAIN_TIMEOUT_MS);
  for (const account of [...state.accounts.values()]) {
    await withAccount(account, () => closeAccountState(account, reason));
  }
}

function operationKey(accountId, requestId) {
  return JSON.stringify([normalizeAccountId(accountId), String(requestId ?? "")]);
}

function emitInitProtocol(operation, frame) {
  if (operation) {
    settleOperation(operation, frame);
  } else {
    emitProtocol(frame);
  }
}

function emitInitError(operation, accountOrId, params) {
  const frame = {
    type: "error",
    accountId: accountIdOf(accountOrId),
    phase: params.phase,
    status: params.status ?? "error",
    errorKind: params.errorKind,
    requestId: params.requestId,
    message: String(params.message ?? "Feishu sidecar error"),
    ...(params.httpStatus !== undefined ? { httpStatus: params.httpStatus } : {}),
    ...(params.feishuCode !== undefined ? { feishuCode: params.feishuCode } : {}),
    ...(params.feishuMsgClass ? { feishuMsgClass: params.feishuMsgClass } : {}),
    ...(params.runtimeRoot ? { runtimeRoot: params.runtimeRoot } : {}),
    ...(params.missingPackage ? { missingPackage: params.missingPackage } : {}),
  };
  emitInitProtocol(operation, frame);
}

function operationTimeoutMs(frame) {
  const configured = Number(frame?.operationTimeoutMs ?? frame?.requestTimeoutMs ?? DEFAULT_OPERATION_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0 ? Math.floor(configured) : DEFAULT_OPERATION_TIMEOUT_MS;
}

function reserveOperation(accountId, requestId, kind = "request") {
  const normalizedAccountId = normalizeAccountId(accountId);
  const normalizedRequestId = String(requestId ?? (kind === "init" ? "init" : ""));
  const key = operationKey(normalizedAccountId, normalizedRequestId);
  const accountActive = state.activeSdkOperationsByAccount.get(normalizedAccountId) ?? 0;
  if (state.activeSdkOperations.has(key) || state.protocolPending.has(key)) {
    return { ok: false, status: "duplicate_request", key, accountId: normalizedAccountId, requestId: normalizedRequestId };
  }
  if (state.activeSdkOperations.size >= MAX_ACTIVE_OPERATIONS || accountActive >= MAX_ACTIVE_OPERATIONS_PER_ACCOUNT) {
    return { ok: false, status: "sidecar_busy", key, accountId: normalizedAccountId, requestId: normalizedRequestId };
  }
  const operation = {
    ok: true,
    key,
    kind,
    accountId: normalizedAccountId,
    requestId: normalizedRequestId,
    protocolSettled: false,
    sdkSettled: false,
    timedOut: false,
  };
  state.protocolPending.set(key, operation);
  state.activeSdkOperations.set(key, operation);
  state.activeSdkOperationsByAccount.set(normalizedAccountId, accountActive + 1);
  return operation;
}

function releaseProtocolPending(operation) {
  if (!operation || operation.protocolSettled) {
    return false;
  }
  operation.protocolSettled = true;
  state.protocolPending.delete(operation.key);
  return true;
}

function releaseSdkOperation(operation) {
  if (!operation || operation.sdkSettled) {
    return;
  }
  operation.sdkSettled = true;
  state.activeSdkOperations.delete(operation.key);
  const remaining = Math.max(0, (state.activeSdkOperationsByAccount.get(operation.accountId) ?? 1) - 1);
  if (remaining === 0) {
    state.activeSdkOperationsByAccount.delete(operation.accountId);
  } else {
    state.activeSdkOperationsByAccount.set(operation.accountId, remaining);
  }
}

function settleOperation(operation, frame) {
  if (!releaseProtocolPending(operation)) {
    emitLateResultDropped(operation);
    return false;
  }
  if (frame) {
    emitProtocol(frame);
  }
  return true;
}

function emitLateResultDropped(operation) {
  emitDiagnostic(operation.accountId, "warn", "operation.late_result", "Dropped late Feishu sidecar operation result", {
    status: "late_result_dropped",
    operationKind: operation.kind,
  });
}

function emitRecycleRequired() {
  if (state.recycleRequiredEmitted) {
    return;
  }
  const orphaned = [...state.activeSdkOperations.values()].filter((operation) => operation.timedOut).length;
  if (orphaned < ORPHAN_RECYCLE_THRESHOLD) {
    return;
  }
  state.recycleRequiredEmitted = true;
  emitDiagnostic("default", "warn", "operation.lifecycle", "Feishu sidecar recycle required after timed-out SDK operations", {
    status: "recycle_required",
    orphanedOperations: orphaned,
  });
}

async function runWithOperationDeadline(operation, timeoutMs, sdkOperation, reportLateResult = true) {
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ timedOut: true }), timeoutMs);
  });
  const sdkPromise = Promise.resolve().then(sdkOperation);
  if (reportLateResult) {
    sdkPromise.then(
      () => { if (operation.timedOut) emitLateResultDropped(operation); },
      () => { if (operation.timedOut) emitLateResultDropped(operation); },
    );
  }
  sdkPromise.catch(() => {}).finally(() => releaseSdkOperation(operation));
  const outcome = await Promise.race([
    sdkPromise.then((value) => ({ value }), (error) => ({ error })),
    timeout,
  ]);
  clearTimeout(timer);
  if (outcome.timedOut) {
    operation.timedOut = true;
    settleOperation(operation, {
      type: "error",
      accountId: operation.accountId,
      phase: operation.kind,
      status: operation.kind === "init" ? "ready_timeout" : "request_timeout",
      requestId: operation.kind === "request" ? operation.requestId : undefined,
      message: `Feishu sidecar ${operation.kind} operation timed out`,
    });
    emitRecycleRequired();
    return { timedOut: true };
  }
  return outcome;
}

async function dispatchInitAccount(frame, options = {}) {
  const accountId = normalizeAccountId(frame.accountId);
  const operation = reserveOperation(accountId, "init", "init");
  if (!operation.ok) {
    emitError(accountId, {
      phase: frame.type === "init" ? "init" : "initAccount",
      status: operation.status,
      message: "Feishu sidecar operation capacity is exhausted",
    });
    return;
  }
  const outcome = await runWithOperationDeadline(
    operation,
    operationTimeoutMs(frame),
    () => initialize(frame, { ...options, operation }),
    false,
  );
  if (!outcome.timedOut) {
    releaseProtocolPending(operation);
  }
}

async function dispatchRequest(frame) {
  const accountId = resolveFrameAccountId(frame);
  const account = state.accounts.get(accountId);
  if (!account) {
    emitError(accountId, {
      phase: frame.type,
      status: "unknown_account",
      requestId: frame.requestId,
      message: `Unknown Feishu sidecar account: ${accountId}`,
    });
    return;
  }
  const operation = reserveOperation(accountId, frame.requestId, "request");
  if (!operation.ok) {
    emitError(accountId, {
      phase: frame.type,
      status: operation.status,
      requestId: frame.requestId,
      message: operation.status === "sidecar_busy" ? "Feishu sidecar operation capacity is exhausted" : "Duplicate Feishu sidecar request",
    });
    return;
  }
  const outcome = await runWithOperationDeadline(operation, operationTimeoutMs(frame), () =>
    withAccount(account, () => dispatchSend(frame)),
  );
  if (outcome.timedOut) {
    return;
  }
  if (outcome.error) {
    const error = outcome.error;
    const httpStatus = apiHttpStatus(error);
    const feishuCode = apiFeishuCode(error);
    settleOperation(operation, {
      type: "error",
      accountId,
      phase: `send.${frame.action ?? "unknown"}`,
      status: "api_error",
      errorKind: classifyApiError(error),
      requestId: frame.requestId,
      message: error?.message ?? String(error),
      ...(httpStatus !== undefined ? { httpStatus } : {}),
      ...(feishuCode !== undefined ? { feishuCode } : {}),
      feishuMsgClass: feishuMsgClass(error),
    });
    return;
  }
  settleOperation(operation, {
    type: "sendResult",
    accountId,
    requestId: frame.requestId,
    action: frame.action,
    ok: true,
    ...outcome.value,
  });
}

async function drainOperations(deadlineMs) {
  const deadline = Date.now() + Math.max(0, deadlineMs);
  while (state.activeSdkOperations.size > 0 && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  for (const operation of [...state.protocolPending.values()]) {
    settleOperation(operation, {
      type: "error",
      accountId: operation.accountId,
      phase: "close",
      status: "closed",
      requestId: operation.kind === "request" ? operation.requestId : undefined,
      message: "Feishu sidecar closed before operation completed",
    });
  }
}

async function handleFrame(frame) {
  if (!frame || typeof frame !== "object" || Array.isArray(frame)) {
    emitError({ phase: "stdin", status: "invalid_frame", message: "Protocol frame must be a JSON object" });
    return;
  }
  switch (frame.type) {
    case "init":
      void dispatchInitAccount(frame, { legacy: true });
      return;
    case "initAccount":
      void dispatchInitAccount(frame);
      return;
    case "send":
    case "request":
      {
        const accountId = resolveFrameAccountId(frame);
        const account = state.accounts.get(accountId);
        if (!account) {
          emitError(accountId, {
            phase: frame.type,
            status: "unknown_account",
            requestId: frame.requestId,
            message: `Unknown Feishu sidecar account: ${accountId}`,
          });
          return;
        }
        void dispatchRequest(frame);
      }
      return;
    case "closeAccount":
      {
        const accountId = resolveFrameAccountId(frame);
        const account = state.accounts.get(accountId);
        if (!account) {
          emitError(accountId, {
            phase: "closeAccount",
            status: "unknown_account",
            message: `Unknown Feishu sidecar account: ${accountId}`,
          });
          return;
        }
        await withAccount(account, () => closeAccountState(account, frame.reason ?? "stop", { remove: true }));
      }
      return;
    case "close":
      await closeAllAccounts(frame.reason ?? "stop");
      process.exitCode = 0;
      process.exit(0);
      return;
    default:
      emitError(resolveFrameAccountId(frame), {
        phase: "stdin",
        status: "unknown_frame",
        message: `Unknown Feishu sidecar frame type: ${frame.type}`,
      });
  }
}

async function main() {
  const forbiddenArg = findForbiddenArgv(process.argv.slice(2));
  if (forbiddenArg) {
    emitError({
      phase: "argv",
      status: "secret_in_argv",
      message: `Refusing secret-bearing argv option ${forbiddenArg}; Feishu secrets must arrive in stdin init frame`,
    });
    exitSoon(1);
    return;
  }

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });
  let sawFrame = false;
  for await (const line of rl) {
    if (!line.trim()) {
      continue;
    }
    sawFrame = true;
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      emitError({ phase: "stdin", status: "invalid_json", message: "Invalid JSON protocol frame" });
      if (!hasReadyAccount()) {
        exitSoon(1);
        return;
      }
      continue;
    }
    await handleFrame(frame);
  }
  if (!sawFrame) {
    emitError({ phase: "stdin", status: "missing_init", message: "Feishu sidecar expected an init frame" });
    exitSoon(1);
    return;
  }
  if (hasReadyAccount() && !state.closing) {
    await closeAllAccounts("stdin_eof");
  }
}

process.on("SIGTERM", () => {
  void closeAllAccounts("sigterm").finally(() => process.exit(0));
});

process.on("SIGINT", () => {
  void closeAllAccounts("sigint").finally(() => process.exit(0));
});

void main().catch((error) => {
  emitError({ phase: "fatal", status: "exception", message: error?.message ?? String(error) });
  exitSoon(1);
});
