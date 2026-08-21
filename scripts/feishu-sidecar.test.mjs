#!/usr/bin/env node

import assert from "node:assert/strict";
import { once } from "node:events";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const sidecarPath = path.join(import.meta.dirname, "feishu-sidecar.mjs");
const secretValues = {
  appSecret: "fixture-app-secret-0123456789",
  verificationToken: "fixture-verification-token-0123456789",
  encryptKey: "fixture-encrypt-key-0123456789",
};

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "metis-feishu-sidecar-test-"));
}

function writeFakeSdk(root, options = {}) {
  const callsPath = path.join(root, "fake-sdk-calls.jsonl");
  const sdkPath = path.join(root, `fake-sdk-${Math.random().toString(36).slice(2)}.mjs`);
  fs.writeFileSync(
    sdkPath,
    `
      import fs from "node:fs";
      import { Readable } from "node:stream";

      const callsPath = process.env.METIS_FEISHU_FAKE_SDK_CALLS;
      const behavior = JSON.parse(process.env.METIS_FEISHU_FAKE_SDK_BEHAVIOR || "{}");

      function activeBehavior(appId) {
        const perApp = behavior.byAppId && behavior.byAppId[appId] ? behavior.byAppId[appId] : {};
        return { ...behavior, ...perApp };
      }

      function record(kind, value) {
        if (!callsPath) return;
        fs.appendFileSync(callsPath, JSON.stringify({ kind, value }, (_key, entry) => {
          if (Buffer.isBuffer(entry)) {
            return { bufferLength: entry.length };
          }
          if (entry && entry.type === "Buffer" && Array.isArray(entry.data)) {
            return { bufferLength: entry.data.length };
          }
          if (entry && typeof entry === "object" && typeof entry.pipe === "function") {
            return {
              streamLike: true,
              readable: entry.readable !== false,
              constructorName: entry.constructor?.name ?? "",
            };
          }
          if (typeof entry === "function") {
            return "[Function]";
          }
          return entry;
        }) + "\\n");
      }

      function closeUploadStreams(request) {
        for (const value of [request?.data?.image, request?.data?.file]) {
          if (value && typeof value.destroy === "function") {
            value.destroy();
          }
        }
      }

      export const AppType = { SelfBuild: "SelfBuild" };
      export const Domain = { Feishu: "https://open.feishu.cn", Lark: "https://open.larksuite.com" };
      export const LoggerLevel = { info: "info" };
      export const defaultHttpInstance = {};

      export class HttpsProxyAgent {
        constructor(url) {
          this.url = url;
          record("proxyAgent", { url });
        }
      }

      export class EventDispatcher {
        constructor(options) {
          this.options = options;
          this.handlers = {};
          record("EventDispatcher", options);
        }
        register(handlers) {
          Object.assign(this.handlers, handlers);
          record("EventDispatcher.register", Object.keys(handlers));
        }
        async __emit(type, payload) {
          const handler = this.handlers[type];
          if (handler) {
            await handler(payload);
          }
        }
      }

      export class WSClient {
        constructor(options) {
          this.options = options;
          this.behavior = activeBehavior(options.appId);
          this.listeners = {};
          record("WSClient", options);
        }
        on(event, handler) {
          this.listeners[event] = handler;
          record("WSClient.on", { event });
          return this;
        }
        once(event, handler) {
          this.listeners[event] = handler;
          record("WSClient.once", { event });
          return this;
        }
        start({ eventDispatcher }) {
          record("WSClient.start", { hasDispatcher: Boolean(eventDispatcher) });
          const behavior = this.behavior;
          if (behavior.start === "throw") {
            throw new Error("start failed with " + (behavior.secretEcho || "no secret"));
          }
          if (behavior.start === "never") {
            return new Promise(() => {});
          }
          if (behavior.start !== "noReady") {
            setTimeout(() => {
              this.options.onReady?.();
            }, behavior.readyDelayMs ?? 0);
          }
          const events = behavior.events || [];
          for (const [index, event] of events.entries()) {
            setTimeout(() => {
              void eventDispatcher.__emit(event.type, event.payload);
            }, event.delayMs ?? (index + 1));
          }
          if (behavior.backgroundCloseMs !== undefined) {
            setTimeout(() => {
              const handler = this.listeners.close || this.listeners.closed || this.listeners.error;
              if (handler) handler(new Error("fake background close " + (behavior.secretEcho || "")));
            }, behavior.backgroundCloseMs);
          }
          if (behavior.backgroundErrorMs !== undefined) {
            setTimeout(() => {
              this.options.onError?.(new Error("fake background error " + (behavior.secretEcho || "")));
            }, behavior.backgroundErrorMs);
          }
          return behavior.start === "async" ? new Promise((resolve) => setTimeout(resolve, behavior.startDelayMs ?? 5)) : undefined;
        }
        close() {
          record("WSClient.close", { appId: this.options.appId });
        }
      }

      const responseQueue = Array.isArray(behavior.responses) ? [...behavior.responses] : [];
      function bufferFromFixture(value) {
        if (Buffer.isBuffer(value)) return value;
        if (value?.type === "Buffer" && Array.isArray(value.data)) return Buffer.from(value.data);
        return Buffer.from(String(value ?? ""));
      }
      function materializeResponse(entry) {
        if (entry?.writeFileBytes !== undefined) {
          const buffer = bufferFromFixture(entry.writeFileBytes);
          return {
            headers: entry.headers ?? {},
            file_name: entry.file_name,
            fileName: entry.fileName,
            writeFile: async (targetPath) => {
              fs.writeFileSync(targetPath, buffer);
            },
            getReadableStream: () => {
              return Readable.from([buffer]);
            },
          };
        }
        return entry;
      }
      function nextResponse(defaultValue) {
        const entry = responseQueue.length > 0 ? responseQueue.shift() : undefined;
        if (entry?.never === true) {
          return new Promise(() => {});
        }
        if (Number.isFinite(entry?.delayMs) && entry.delayMs >= 0) {
          return new Promise((resolve) => setTimeout(
            () => resolve(materializeResponse(entry.value ?? defaultValue)),
            entry.delayMs,
          ));
        }
        if (entry?.throw) {
          const error = new Error(entry.throw.message || "fake sdk error");
          if (entry.throw.code !== undefined) error.code = entry.throw.code;
          if (entry.throw.response !== undefined) {
            error.response = entry.throw.response;
          } else if (entry.throw.responseStatus !== undefined || entry.throw.responseData !== undefined) {
            error.response = {
              status: entry.throw.responseStatus,
              data: entry.throw.responseData,
            };
          }
          throw error;
        }
        return materializeResponse(entry ?? defaultValue);
      }

      export class Client {
        constructor(options) {
          this.options = options;
          record("Client", options);
          this.im = {
            message: {
              create: async (request) => {
                record("im.message.create", request);
                return nextResponse({ code: 0, data: { message_id: "om_created", chat_id: request.data.receive_id } });
              },
              reply: async (request) => {
                record("im.message.reply", request);
                return nextResponse({ code: 0, data: { message_id: "om_reply" } });
              },
              patch: async (request) => {
                record("im.message.patch", request);
                return nextResponse({ code: 0, data: { message_id: request.path.message_id } });
              },
              delete: async (request) => {
                record("im.message.delete", request);
                return nextResponse({ code: 0, data: { message_id: request.path.message_id } });
              },
              get: async (request) => {
                record("im.message.get", request);
                return nextResponse({
                  code: 0,
                  data: {
                    items: [
                      {
                        message_id: request.path.message_id,
                        msg_type: "text",
                        body: { content: JSON.stringify({ text: "fetched" }) },
                      },
                    ],
                  },
                });
              },
            },
            image: {
              create: async (request) => {
                record("im.image.create", request);
                closeUploadStreams(request);
                return nextResponse({ code: 0, data: { image_key: "img_uploaded" } });
              },
              get: async (request) => {
                record("im.image.get", request);
                return nextResponse({ code: 0, data: Buffer.from("image-bytes"), file_name: "image.png", headers: { "content-type": "image/png" } });
              },
            },
            file: {
              create: async (request) => {
                record("im.file.create", request);
                closeUploadStreams(request);
                return nextResponse({ code: 0, data: { file_key: "file_uploaded" } });
              },
            },
            messageResource: {
              get: async (request) => {
                record("im.messageResource.get", request);
                return nextResponse({ code: 0, data: Buffer.from("resource-bytes"), file_name: "resource.bin", headers: { "content-type": "application/octet-stream" } });
              },
            },
            messageReaction: {
              create: async (request) => {
                record("im.messageReaction.create", request);
                return nextResponse({ code: 0, data: { reaction_id: "reaction_created" } });
              },
              delete: async (request) => {
                record("im.messageReaction.delete", request);
                return nextResponse({ code: 0 });
              },
              list: async (request) => {
                record("im.messageReaction.list", request);
                return nextResponse({
                  code: 0,
                  data: {
                    items: [
                      {
                        reaction_id: "reaction_created",
                        reaction_type: { emoji_type: request.params?.reaction_type ?? "THUMBSUP" },
                        operator_type: "app",
                        operator_id: { open_id: "ou_bot" },
                      },
                    ],
                  },
                });
              },
            },
            chat: {
              get: async (request) => {
                record("im.chat.get", request);
                return nextResponse({ code: 0, data: { chat_id: request.path.chat_id, chat_type: "group" } });
              },
            },
          };
        }
      }
    `,
  );
  if (options.behavior) {
    fs.writeFileSync(path.join(root, "behavior.json"), JSON.stringify(options.behavior));
  }
  return { sdkPath, callsPath };
}

function writeFakeRuntimeRoot(root, options = {}) {
  const runtimeRoot = path.join(root, "runtime");
  const sdkRoot = path.join(runtimeRoot, "node_modules", "@larksuiteoapi", "node-sdk");
  const proxyRoot = path.join(runtimeRoot, "node_modules", "https-proxy-agent");
  const callsPath = path.join(root, "fake-runtime-calls.jsonl");
  fs.mkdirSync(runtimeRoot, { recursive: true });
  fs.writeFileSync(
    path.join(runtimeRoot, "package.json"),
    JSON.stringify({ name: "fake-runtime", private: true, type: "module", dependencies: {} }),
  );

  if (options.sdk !== false) {
    fs.mkdirSync(sdkRoot, { recursive: true });
    fs.writeFileSync(
      path.join(sdkRoot, "package.json"),
      JSON.stringify({ name: "@larksuiteoapi/node-sdk", version: "0.0.0-test", main: "index.cjs" }),
    );
    fs.writeFileSync(
      path.join(sdkRoot, "index.cjs"),
      `
        const fs = require("node:fs");
        const callsPath = process.env.METIS_FEISHU_FAKE_SDK_CALLS;
        function record(kind, value) {
          if (!callsPath) return;
          fs.appendFileSync(callsPath, JSON.stringify({ kind, value }, (_key, entry) => {
            if (typeof entry === "function") return "[Function]";
            return entry;
          }) + "\\n");
        }
        exports.AppType = { SelfBuild: "SelfBuild" };
        exports.Domain = { Feishu: "https://open.feishu.cn", Lark: "https://open.larksuite.com" };
        exports.LoggerLevel = { info: "info" };
        ${options.sdkProxyAgent === false ? "" : `
        exports.HttpsProxyAgent = class HttpsProxyAgent {
          constructor(url) {
            this.url = url;
            record("sdk.proxyAgent", { url });
          }
        };`}
        exports.EventDispatcher = class EventDispatcher {
          constructor(options) {
            this.options = options;
            this.handlers = {};
            record("EventDispatcher", options);
          }
          register(handlers) {
            Object.assign(this.handlers, handlers);
            record("EventDispatcher.register", Object.keys(handlers));
          }
        };
        exports.WSClient = class WSClient {
          constructor(options) {
            this.options = options;
            record("WSClient", options);
          }
          start({ eventDispatcher }) {
            record("WSClient.start", { hasDispatcher: Boolean(eventDispatcher) });
            setTimeout(() => {
              this.options.onReady?.();
            }, 0);
          }
          close() {
            record("WSClient.close", {});
          }
        };
        exports.Client = class Client {
          constructor(options) {
            this.options = options;
            record("Client", options);
            this.im = {
              message: {
                create: async (request) => {
                  record("im.message.create", request);
                  return { code: 0, data: { message_id: "om_created", chat_id: request.data.receive_id } };
                },
              },
            };
          }
        };
      `,
    );
  }

  if (options.proxyAgent !== false) {
    fs.mkdirSync(proxyRoot, { recursive: true });
    fs.writeFileSync(
      path.join(proxyRoot, "package.json"),
      JSON.stringify({ name: "https-proxy-agent", version: "0.0.0-test", main: "index.cjs" }),
    );
    fs.writeFileSync(
      path.join(proxyRoot, "index.cjs"),
      `
        const fs = require("node:fs");
        const callsPath = process.env.METIS_FEISHU_FAKE_SDK_CALLS;
        function record(kind, value) {
          if (!callsPath) return;
          fs.appendFileSync(callsPath, JSON.stringify({ kind, value }) + "\\n");
        }
        exports.HttpsProxyAgent = class HttpsProxyAgent {
          constructor(url) {
            this.url = url;
            record("runtime.proxyAgent", { url });
          }
        };
      `,
    );
  }

  return { runtimeRoot, callsPath };
}

function baseInit(overrides = {}) {
  return {
    type: "init",
    accountId: "acct-1",
    appId: "cli_fixture",
    appSecret: secretValues.appSecret,
    verificationToken: secretValues.verificationToken,
    encryptKey: secretValues.encryptKey,
    domain: "feishu",
    readyTimeoutMs: 250,
    ...overrides,
  };
}

function spawnSidecar({ sdkPath, callsPath, behavior = {}, env = {}, args = [] } = {}) {
  const childEnv = {
    ...process.env,
    METIS_FEISHU_FAKE_SDK_CALLS: callsPath,
    METIS_FEISHU_FAKE_SDK_BEHAVIOR: JSON.stringify(behavior),
    HOME: fs.mkdtempSync(path.join(os.tmpdir(), "metis-feishu-sidecar-home-")),
    METIS_HOME: fs.mkdtempSync(path.join(os.tmpdir(), "metis-feishu-sidecar-metis-home-")),
    ...env,
  };
  if (sdkPath) {
    childEnv.METIS_FEISHU_SIDECAR_SDK = sdkPath;
  } else {
    delete childEnv.METIS_FEISHU_SIDECAR_SDK;
  }
  const child = spawn(process.execPath, [sidecarPath, ...args], {
    encoding: "utf8",
    env: childEnv,
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  const frames = [];
  const stdoutLines = [];
  const stderrLines = [];
  let stdoutBuffer = "";
  let stderrBuffer = "";

  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    const parts = stdoutBuffer.split("\n");
    stdoutBuffer = parts.pop() ?? "";
    for (const line of parts) {
      if (!line.trim()) continue;
      stdoutLines.push(line);
      frames.push(JSON.parse(line));
    }
  });
  child.stderr.on("data", (chunk) => {
    stderrBuffer += chunk;
    const parts = stderrBuffer.split("\n");
    stderrBuffer = parts.pop() ?? "";
    for (const line of parts) {
      if (!line.trim()) continue;
      stderrLines.push(line);
    }
  });

  const writeFrame = (frame) => child.stdin.write(`${JSON.stringify(frame)}\n`);
  const writeRaw = (line) => child.stdin.write(`${line}\n`);
  const waitForFrame = async (predicate, timeoutMs = 1000) => {
    const existing = frames.find(predicate);
    if (existing) return existing;
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      await new Promise((resolve) => setTimeout(resolve, 5));
      const found = frames.find(predicate);
      if (found) return found;
    }
    assert.fail(`timed out waiting for frame; frames=${JSON.stringify(frames)} stderr=${stderrLines.join("\n")}`);
  };
  const waitForExit = async () => {
    if (child.exitCode != null || child.signalCode != null) {
      return;
    }
    await once(child, "exit");
  };
  const close = async () => {
    if (!child.killed && child.exitCode == null) {
      writeFrame({ type: "close", reason: "test" });
      child.stdin.end();
      await waitForExit();
    }
    return {
      status: child.exitCode,
      signal: child.signalCode,
      frames,
      stdout: stdoutLines.join("\n") + (stdoutLines.length ? "\n" : ""),
      stderr: stderrLines.join("\n") + (stderrLines.length ? "\n" : ""),
    };
  };

  return { child, frames, stdoutLines, stderrLines, writeFrame, writeRaw, waitForFrame, waitForExit, close };
}

function readCalls(callsPath) {
  if (!fs.existsSync(callsPath)) {
    return [];
  }
  return fs.readFileSync(callsPath, "utf8").trim().split(/\n+/).filter(Boolean).map((line) => JSON.parse(line));
}

function callsOf(callsPath, kind) {
  return readCalls(callsPath).filter((call) => call.kind === kind).map((call) => call.value);
}

function makeUploadFrame(overrides = {}) {
  return {
    type: "send",
    action: "uploadMedia",
    requestId: "upload-local",
    mediaType: "file",
    fileName: "upload.bin",
    sourceKind: "localPath",
    ...overrides,
  };
}

test("legacy init frame still works", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit({ type: "init", accountId: undefined }));
    const ready = await proc.waitForFrame((frame) => frame.type === "ready");
    assert.equal(ready.accountId, "default");

    proc.writeFrame({ type: "send", action: "sendText", requestId: "legacy-send", to: "oc_chat", text: "legacy" });
    const sent = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "legacy-send");
    assert.equal(sent.accountId, "default");
    assert.equal(sent.ok, true);

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("two initAccount frames create two independent accounts", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "acct-a", appId: "app-a" }));
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "acct-b", appId: "app-b" }));

    const readyA = await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "acct-a");
    const readyB = await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "acct-b");
    assert.equal(readyA.transport, "websocket");
    assert.equal(readyB.transport, "websocket");

    proc.writeFrame({ type: "send", accountId: "acct-a", action: "sendText", requestId: "send-a", to: "oc_a", text: "a" });
    proc.writeFrame({ type: "request", accountId: "acct-b", action: "sendText", requestId: "send-b", to: "oc_b", text: "b" });
    const sentA = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "send-a");
    const sentB = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "send-b");
    assert.equal(sentA.accountId, "acct-a");
    assert.equal(sentB.accountId, "acct-b");
    assert.deepEqual(callsOf(callsPath, "Client").map((call) => call.appId), ["app-a", "app-b"]);

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("P2-U1/P2-P1 interleaved multi-account requests stay correlated while stdin keeps moving", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        responses: [
          { delayMs: 80, value: { code: 0, data: { message_id: "om_slow" } } },
          { code: 0, data: { message_id: "om_fast" } },
        ],
      },
    });
    for (let index = 0; index < 5; index += 1) {
      proc.writeFrame(baseInit({ type: "initAccount", accountId: `acct-${index}`, appId: `app-${index}` }));
    }
    for (let index = 0; index < 5; index += 1) {
      await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === `acct-${index}`);
    }

    proc.writeFrame({ type: "request", accountId: "acct-0", requestId: "same-id", action: "sendText", to: "oc_slow", text: "慢🙂" });
    proc.writeFrame({ type: "request", accountId: "acct-1", requestId: "same-id", action: "sendText", to: "oc_fast", text: "快🚀" });
    const fast = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.accountId === "acct-1" && frame.requestId === "same-id", 50);
    assert.equal(fast.messageId, "om_fast");
    const slow = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.accountId === "acct-0" && frame.requestId === "same-id", 500);
    assert.equal(slow.messageId, "om_slow");
    assert.equal(proc.frames.filter((frame) => frame.type === "sendResult" && frame.requestId === "same-id").length, 2);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("P2-P1 five accounts complete 100 API operations and inbound during a slow operation", async () => {
  const root = createTempRoot();
  const responses = Array.from({ length: 100 }, (_, index) => ({
    ...(index === 0 ? { delayMs: 80, value: { code: 0, data: { message_id: "om_0" } } } : { code: 0, data: { message_id: `om_${index}` } }),
  }));
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        responses,
        events: [{
          delayMs: 20,
          type: "im.message.receive_v1",
          payload: {
            event_id: "event-during-slow",
            sender: { sender_id: { open_id: "ou_sender" }, sender_type: "user" },
            message: { message_id: "om_inbound", chat_id: "oc_chat", chat_type: "group", message_type: "text", content: JSON.stringify({ text: "入站🙂" }) },
          },
        }],
      },
    });
    for (let index = 0; index < 5; index += 1) {
      proc.writeFrame(baseInit({ type: "initAccount", accountId: `bulk-${index}`, appId: `bulk-app-${index}` }));
    }
    for (let index = 0; index < 5; index += 1) {
      await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === `bulk-${index}`);
    }
    for (let batch = 0; batch < 10; batch += 1) {
      for (let offset = 0; offset < 10; offset += 1) {
        const index = batch * 10 + offset;
        proc.writeFrame({
          type: "request",
          accountId: `bulk-${index % 5}`,
          requestId: `bulk-request-${index}`,
          action: "sendText",
          to: `oc_${index}`,
          text: `消息-${index}-🚀`,
        });
      }
      await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === `bulk-request-${batch * 10 + 9}`, 1000);
    }
    const inbound = await proc.waitForFrame((frame) => frame.type === "inbound" && frame.event?.message?.message_id === "om_inbound", 200);
    assert.equal(inbound.accountId.startsWith("bulk-"), true);
    await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "bulk-request-0", 1000);
    const results = proc.frames.filter((frame) => frame.type === "sendResult" && String(frame.requestId).startsWith("bulk-request-"));
    assert.equal(results.length, 100);
    assert.equal(new Set(results.map((frame) => `${frame.accountId}:${frame.requestId}`)).size, 100);
    assert.equal(callsOf(callsPath, "Client").length, 5);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("P2-B1 request deadline settles once and drops the late SDK result", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { responses: [{ delayMs: 80, value: { code: 0, data: { message_id: "om_too_late" } } }] },
    });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "deadline", appId: "deadline-app" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "deadline");
    proc.writeFrame({
      type: "request",
      accountId: "deadline",
      requestId: "deadline-request",
      action: "sendText",
      to: "oc_deadline",
      text: "超时🙂",
      operationTimeoutMs: 10,
    });
    const timeout = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "deadline-request");
    assert.equal(timeout.status, "request_timeout");
    const late = await proc.waitForFrame(
      (frame) => frame.type === "diagnostic" && frame.status === "late_result_dropped" && frame.accountId === "deadline",
      500,
    );
    assert.equal(late.accountId, "deadline");
    assert.equal(proc.frames.some((frame) => frame.type === "sendResult" && frame.requestId === "deadline-request"), false);
    assert.equal(proc.frames.filter((frame) => frame.type === "error" && frame.requestId === "deadline-request").length, 1);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("P2-B1 init deadline drops a late ready terminal frame", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath, behavior: { readyDelayMs: 80 } });
    proc.writeFrame(baseInit({
      type: "initAccount",
      accountId: "late-ready",
      appId: "late-ready-app",
      readyTimeoutMs: 200,
      operationTimeoutMs: 10,
    }));
    const timeout = await proc.waitForFrame((frame) => frame.type === "error" && frame.accountId === "late-ready");
    assert.equal(timeout.status, "ready_timeout");
    await proc.waitForFrame(
      (frame) => frame.type === "diagnostic" && frame.accountId === "late-ready" && frame.status === "late_result_dropped",
      500,
    );
    assert.equal(proc.frames.some((frame) => frame.type === "ready" && frame.accountId === "late-ready"), false);
    assert.equal(proc.frames.filter((frame) => frame.type === "error" && frame.accountId === "late-ready").length, 1);
    proc.writeFrame(baseInit({
      type: "initAccount",
      accountId: "late-ready",
      appId: "late-ready-app-retry",
      readyTimeoutMs: 200,
    }));
    const retryReady = await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "late-ready", 500);
    assert.equal(retryReady.transport, "websocket");
    assert.equal(proc.frames.some((frame) => frame.type === "error" && frame.accountId === "late-ready" && frame.status === "conflict"), false);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("P2-N1 timed-out SDK orphans remain quota-bound and request one recycle", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath, behavior: { responses: Array.from({ length: 16 }, () => ({ never: true })) } });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "orphan", appId: "orphan-app" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "orphan");
    for (let index = 0; index < 16; index += 1) {
      proc.writeFrame({
        type: "request",
        accountId: "orphan",
        requestId: `hung-${index}`,
        action: "sendText",
        to: "oc_orphan",
        text: "永久挂起",
        operationTimeoutMs: 10,
      });
    }
    for (let index = 0; index < 16; index += 1) {
      await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === `hung-${index}` && frame.status === "request_timeout");
    }
    proc.writeFrame({ type: "request", accountId: "orphan", requestId: "over-limit", action: "sendText", to: "oc", text: "busy" });
    const busy = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "over-limit");
    assert.equal(busy.status, "sidecar_busy");
    assert.equal(proc.frames.filter((frame) => frame.type === "diagnostic" && frame.status === "recycle_required").length, 1);
    assert.equal(proc.frames.some((frame) => frame.type === "sendResult" && String(frame.requestId).startsWith("hung-")), false);
    for (const secret of Object.values(secretValues)) {
      assert.equal(`${proc.stdoutLines.join("\n")}${proc.stderrLines.join("\n")}`.includes(secret), false);
    }
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("duplicate initAccount returns conflict", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "dup", appId: "first-app" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "dup");

    proc.writeFrame(baseInit({ type: "initAccount", accountId: "dup", appId: "second-app" }));
    const error = await proc.waitForFrame((frame) => frame.type === "error" && frame.accountId === "dup");
    assert.equal(error.phase, "initAccount");
    assert.equal(error.status, "conflict");
    assert.equal(callsOf(callsPath, "Client").length, 1);

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("unknown account frame is logged/error and dropped", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "known", appId: "known-app" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "known");

    proc.writeFrame({ type: "send", accountId: "missing-send", action: "sendText", requestId: "missing-send", to: "oc_x", text: "x" });
    proc.writeFrame({ type: "request", accountId: "missing-request", action: "sendText", requestId: "missing-request", to: "oc_x", text: "x" });
    proc.writeFrame({ type: "closeAccount", accountId: "missing-close", reason: "test" });

    const sendError = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "missing-send");
    const requestError = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "missing-request");
    const closeError = await proc.waitForFrame((frame) => frame.type === "error" && frame.accountId === "missing-close");
    assert.equal(sendError.accountId, "missing-send");
    assert.equal(requestError.accountId, "missing-request");
    assert.equal(closeError.accountId, "missing-close");
    assert.equal(sendError.status, "unknown_account");
    assert.equal(requestError.status, "unknown_account");
    assert.equal(closeError.status, "unknown_account");
    assert.equal(callsOf(callsPath, "im.message.create").length, 0);

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("one account init failure does not fail another account", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        byAppId: {
          bad_app: { start: "throw", secretEcho: secretValues.appSecret },
        },
      },
    });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "acct-ok", appId: "good_app" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "acct-ok");

    proc.writeFrame(baseInit({ type: "initAccount", accountId: "acct-bad", appId: "bad_app" }));
    const initError = await proc.waitForFrame((frame) => frame.type === "error" && frame.accountId === "acct-bad");
    assert.equal(initError.phase, "websocket.start");
    assert.equal(initError.message.includes(secretValues.appSecret), false);

    proc.writeFrame({ type: "send", accountId: "acct-ok", action: "sendText", requestId: "after-bad-init", to: "oc_ok", text: "still works" });
    const sent = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "after-bad-init");
    assert.equal(sent.accountId, "acct-ok");
    assert.equal(sent.ok, true);
    assert.equal(proc.child.exitCode, null);

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("closeAccount closes only target account", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "stay-open", appId: "stay-app" }));
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "close-me", appId: "close-app" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "stay-open");
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "close-me");

    proc.writeFrame({ type: "closeAccount", accountId: "close-me", reason: "targeted-test" });
    const closed = await proc.waitForFrame((frame) => frame.type === "closed" && frame.accountId === "close-me");
    assert.equal(closed.reason, "targeted-test");
    assert.deepEqual(callsOf(callsPath, "WSClient.close").map((call) => call.appId), ["close-app"]);

    proc.writeFrame({ type: "send", accountId: "stay-open", action: "sendText", requestId: "after-close-account", to: "oc_ok", text: "ok" });
    const sent = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "after-close-account");
    assert.equal(sent.accountId, "stay-open");
    assert.equal(sent.ok, true);

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("global close closes all accounts", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "global-a", appId: "global-app-a" }));
    proc.writeFrame(baseInit({ type: "initAccount", accountId: "global-b", appId: "global-app-b" }));
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "global-a");
    await proc.waitForFrame((frame) => frame.type === "ready" && frame.accountId === "global-b");

    proc.writeFrame({ type: "close", reason: "global-test" });
    proc.child.stdin.end();
    await proc.waitForExit();
    assert.equal(proc.child.exitCode, 0, proc.stderrLines.join("\n"));
    const closed = proc.frames.filter((frame) => frame.type === "closed" && frame.reason === "global-test");
    assert.deepEqual(closed.map((frame) => frame.accountId).sort(), ["global-a", "global-b"]);
    assert.deepEqual(callsOf(callsPath, "WSClient.close").map((call) => call.appId).sort(), ["global-app-a", "global-app-b"]);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("feishu sidecar resolves sdk from runtime root without METIS_FEISHU_SIDECAR_SDK", async () => {
  const root = createTempRoot();
  const { runtimeRoot, callsPath } = writeFakeRuntimeRoot(root);
  try {
    const proc = spawnSidecar({ callsPath });
    proc.writeFrame(baseInit({ runtimeRoot }));
    const preflight = await proc.waitForFrame((frame) => frame.type === "diagnostic" && frame.phase === "dependency.preflight");
    assert.equal(preflight.status, "ok");
    assert.equal(preflight.runtimeRoot, runtimeRoot);
    const ready = await proc.waitForFrame((frame) => frame.type === "ready");
    assert.equal(ready.accountId, "acct-1");
    assert.equal(callsOf(callsPath, "WSClient.start")[0].hasDispatcher, true);
    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("api mode initializes REST client without opening a websocket connection", async () => {
  const root = createTempRoot();
  const { runtimeRoot, callsPath } = writeFakeRuntimeRoot(root);
  let proc;
  try {
    proc = spawnSidecar({ callsPath });
    proc.writeFrame(baseInit({ mode: "api", runtimeRoot }));
    const ready = await proc.waitForFrame((frame) => frame.type === "ready");
    assert.equal(ready.transport, "api");
    proc.writeFrame({ type: "request", action: "sendText", requestId: "api-text", to: "oc_chat", text: "hello" });
    const resultFrame = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "api-text");
    assert.equal(resultFrame.ok, true);
    assert.equal(resultFrame.messageId, "om_created");
    assert.equal(callsOf(callsPath, "Client").length, 1);
    assert.equal(callsOf(callsPath, "im.message.create").length, 1);
    assert.equal(callsOf(callsPath, "EventDispatcher").length, 0);
    assert.equal(callsOf(callsPath, "WSClient").length, 0);
    assert.equal(callsOf(callsPath, "WSClient.start").length, 0);
    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
  } finally {
    if (proc && proc.child.exitCode == null && !proc.child.killed) {
      await proc.close();
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("feishu sidecar does not emit ready until SDK reports websocket ready", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { start: "noReady" },
    });
    proc.writeFrame(baseInit({ readyTimeoutMs: 30 }));
    const error = await proc.waitForFrame((frame) => frame.type === "error" && frame.phase === "websocket.start", 1000);
    assert.equal(error.status, "ready_timeout");
    assert.equal(proc.frames.some((frame) => frame.type === "ready"), false);
    proc.child.stdin.end();
    await proc.waitForExit();
    assert.notEqual(proc.child.exitCode, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("feishu sidecar dependency preflight reports missing runtime package json", async () => {
  const root = createTempRoot();
  const runtimeRoot = path.join(root, "missing-runtime");
  try {
    const proc = spawnSidecar({});
    proc.writeFrame(baseInit({ runtimeRoot }));
    const error = await proc.waitForFrame((frame) => frame.type === "error" && frame.phase === "dependency.preflight");
    assert.equal(error.status, "missing_dependency");
    assert.match(error.message, /package\.json/);
    assert.match(error.message, new RegExp(runtimeRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    for (const secret of Object.values(secretValues)) {
      assert.equal(`${proc.stdoutLines.join("\n")}${proc.stderrLines.join("\n")}`.includes(secret), false);
    }
    proc.child.stdin.end();
    await proc.waitForExit();
    assert.notEqual(proc.child.exitCode, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("feishu sidecar dependency preflight reports missing @larksuiteoapi/node-sdk", async () => {
  const root = createTempRoot();
  const { runtimeRoot } = writeFakeRuntimeRoot(root, { sdk: false });
  try {
    const proc = spawnSidecar({});
    proc.writeFrame(baseInit({ runtimeRoot }));
    const error = await proc.waitForFrame((frame) => frame.type === "error" && frame.phase === "dependency.preflight");
    assert.equal(error.status, "missing_dependency");
    assert.match(error.message, /@larksuiteoapi\/node-sdk/);
    assert.equal(error.message.includes("Cannot find module"), false);
    proc.child.stdin.end();
    await proc.waitForExit();
    assert.notEqual(proc.child.exitCode, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("feishu sidecar dependency preflight reports missing https-proxy-agent", async () => {
  const root = createTempRoot();
  const { runtimeRoot } = writeFakeRuntimeRoot(root, { proxyAgent: false });
  try {
    const proc = spawnSidecar({});
    proc.writeFrame(baseInit({ runtimeRoot }));
    const error = await proc.waitForFrame((frame) => frame.type === "error" && frame.phase === "dependency.preflight");
    assert.equal(error.status, "missing_dependency");
    assert.match(error.message, /https-proxy-agent/);
    assert.equal(error.message.includes("Require stack"), false);
    proc.child.stdin.end();
    await proc.waitForExit();
    assert.notEqual(proc.child.exitCode, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("feishu sidecar creates proxy agent from runtime root when SDK does not export one", async () => {
  const root = createTempRoot();
  const { runtimeRoot, callsPath } = writeFakeRuntimeRoot(root, { sdkProxyAgent: false });
  try {
    const proc = spawnSidecar({
      callsPath,
      env: {
        https_proxy: "http://127.0.0.1:7897",
        HTTPS_PROXY: "http://127.0.0.1:7898",
        http_proxy: "http://127.0.0.1:7899",
        HTTP_PROXY: "http://127.0.0.1:7900",
      },
    });
    proc.writeFrame(baseInit({ runtimeRoot }));
    await proc.waitForFrame((frame) => frame.type === "ready");
    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(callsOf(callsPath, "runtime.proxyAgent")[0].url, "http://127.0.0.1:7897");
    assert.equal(callsOf(callsPath, "sdk.proxyAgent").length, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("sdk background error emits diagnostic failure after ready without leaking secrets", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { backgroundErrorMs: 10, secretEcho: secretValues.appSecret },
    });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");
    const diagnostic = await proc.waitForFrame(
      (frame) => frame.type === "diagnostic" && frame.level === "error" && frame.phase === "websocket.error",
      1000,
    );
    assert.equal(diagnostic.status, "failed");
    assert.match(diagnostic.message, /fake background error/);
    assert.equal(`${proc.stdoutLines.join("\n")}${proc.stderrLines.join("\n")}`.includes(secretValues.appSecret), false);
    proc.child.stdin.end();
    await proc.waitForExit();
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("sdk background close emits closed frame after ready without leaking secrets", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { backgroundCloseMs: 10, secretEcho: secretValues.appSecret },
    });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");
    const closed = await proc.waitForFrame((frame) => frame.type === "closed" && frame.reason === "sdk_close", 1000);
    assert.equal(closed.accountId, "acct-1");
    assert.equal(`${proc.stdoutLines.join("\n")}${proc.stderrLines.join("\n")}`.includes(secretValues.appSecret), false);
    proc.child.stdin.end();
    await proc.waitForExit();
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("ready initializes the vendor SDK model without putting secrets in argv or logs", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  const runtimeRoot = path.join(root, "runtime-root-for-ready-frame");
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      env: { HTTPS_PROXY: "http://127.0.0.1:7897" },
    });
    proc.writeFrame(baseInit({ domain: "lark", runtimeRoot }));
    const ready = await proc.waitForFrame((frame) => frame.type === "ready");
    assert.equal(ready.accountId, "acct-1");
    assert.equal(ready.transport, "websocket");
    assert.equal(ready.runtimeRoot, runtimeRoot);
    assert.equal(ready.sdk, "@larksuiteoapi/node-sdk");
    assert.deepEqual(ready.proxy, {
      configured: true,
      source: "HTTPS_PROXY",
      scheme: "http",
    });

    const result = await proc.close();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.frames.some((frame) => frame.type === "closed" && frame.reason === "test"), true);
    for (const secret of Object.values(secretValues)) {
      assert.equal(`${result.stdout}${result.stderr}`.includes(secret), false);
      assert.equal(proc.child.spawnargs.join(" ").includes(secret), false);
    }
    for (const line of result.stdout.trim().split(/\n+/).filter(Boolean)) {
      assert.doesNotThrow(() => JSON.parse(line));
    }
    for (const line of result.stderr.trim().split(/\n+/).filter(Boolean)) {
      assert.throws(() => JSON.parse(line));
    }

    assert.deepEqual(callsOf(callsPath, "EventDispatcher")[0], {
      encryptKey: secretValues.encryptKey,
      verificationToken: secretValues.verificationToken,
    });
    assert.equal(callsOf(callsPath, "WSClient")[0].domain, "https://open.larksuite.com");
    assert.equal(callsOf(callsPath, "WSClient.start")[0].hasDispatcher, true);
    assert.equal(callsOf(callsPath, "proxyAgent")[0].url, "http://127.0.0.1:7897");
    assert.equal(callsOf(callsPath, "WSClient.close").length, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("start throw, never-ready, non-json stdin, and forbidden secret argv produce protocol errors", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const throwing = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { start: "throw", secretEcho: secretValues.appSecret },
    });
    throwing.writeFrame(baseInit());
    const throwError = await throwing.waitForFrame((frame) => frame.type === "error");
    assert.equal(throwError.phase, "websocket.start");
    assert.equal(throwError.message.includes(secretValues.appSecret), false);
    throwing.child.stdin.end();
    await throwing.waitForExit();
    assert.notEqual(throwing.child.exitCode, 0);

    const never = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { start: "never" },
    });
    never.writeFrame(baseInit({ readyTimeoutMs: 30 }));
    const timeoutError = await never.waitForFrame((frame) => frame.type === "error", 1000);
    assert.equal(timeoutError.status, "ready_timeout");
    never.child.stdin.end();
    await never.waitForExit();
    assert.notEqual(never.child.exitCode, 0);

    const nonJson = spawnSidecar({ sdkPath, callsPath });
    nonJson.writeRaw("not-json");
    const invalid = await nonJson.waitForFrame((frame) => frame.type === "error");
    assert.equal(invalid.status, "invalid_json");
    nonJson.child.stdin.end();
    await nonJson.waitForExit();
    assert.notEqual(nonJson.child.exitCode, 0);

    const forbiddenArgv = spawnSidecar({
      sdkPath,
      callsPath,
      args: ["--appSecret", secretValues.appSecret],
    });
    const argvError = await forbiddenArgv.waitForFrame((frame) => frame.type === "error");
    assert.equal(argvError.status, "secret_in_argv");
    forbiddenArgv.child.stdin.end();
    await forbiddenArgv.waitForExit();
    assert.notEqual(forbiddenArgv.child.exitCode, 0);
    for (const line of forbiddenArgv.stdoutLines) {
      assert.equal(line.includes(secretValues.appSecret), false);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("inbound text, post, image, file, audio, video, and sticker events become protocol frames", async () => {
  const root = createTempRoot();
  const inboundEvents = [
    feishuMessageEvent("msg-text", "text", { text: "hello" }),
    feishuMessageEvent("msg-post", "post", {
      zh_cn: { content: [[{ tag: "text", text: "rich" }, { tag: "md", text: " post" }]] },
    }),
    feishuMessageEvent("msg-image", "image", { image_key: "img_1" }),
    feishuMessageEvent("msg-file", "file", { file_key: "file_1", file_name: "report.pdf", file_size: 12 }),
    feishuMessageEvent("msg-audio", "audio", { file_key: "aud_1", duration: 1000 }),
    feishuMessageEvent("msg-video", "media", { file_key: "vid_1", file_name: "clip.mp4" }),
    feishuMessageEvent("msg-sticker", "sticker", { sticker_key: "sticker_1" }),
    feishuMessageEvent("msg-text", "text", { text: "duplicate" }),
    { type: "im.message.receive_v1", payload: { event: { broken: true } } },
  ];
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: { events: inboundEvents },
    });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");
    await proc.waitForFrame((frame) => frame.type === "diagnostic" && frame.phase === "event.malformed");
    const result = await proc.close();
    const inbound = result.frames.filter((frame) => frame.type === "inbound");
    assert.deepEqual(
      inbound.map((frame) => frame.messageType),
      ["text", "post", "image", "file", "audio", "media", "sticker"],
    );
    assert.equal(inbound.find((frame) => frame.messageType === "text").message.text, "hello");
    assert.equal(inbound.find((frame) => frame.messageType === "post").message.text, "rich post");
    assert.deepEqual(inbound.find((frame) => frame.messageType === "image").media, {
      kind: "image",
      imageKey: "img_1",
    });
    assert.equal(inbound.find((frame) => frame.messageType === "file").media.fileName, "report.pdf");
    assert.equal(inbound.find((frame) => frame.messageType === "audio").media.kind, "audio");
    assert.equal(inbound.find((frame) => frame.messageType === "media").media.kind, "video");
    assert.equal(inbound.find((frame) => frame.messageType === "sticker").media.kind, "sticker");
    assert.equal(inbound.filter((frame) => frame.message.messageId === "msg-text").length, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("send text, media, card, reaction, delete, and download requests route to SDK calls", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    const requests = [
      { type: "send", action: "sendText", requestId: "text-create", to: "oc_chat", text: "hello" },
      { type: "send", action: "sendText", requestId: "text-reply", to: "oc_chat", text: "reply", replyToMessageId: "om_parent", replyInThread: true },
      { type: "send", action: "uploadMedia", requestId: "upload-image", mediaType: "image", fileName: "upload.png", contentBase64: Buffer.from("png").toString("base64") },
      { type: "send", action: "sendMedia", requestId: "image", to: "oc_chat", mediaType: "image", fileName: "a.png", contentBase64: Buffer.from("png").toString("base64") },
      { type: "send", action: "sendMedia", requestId: "audio", to: "oc_chat", mediaType: "audio", fileName: "a.ogg", contentBase64: Buffer.from("ogg").toString("base64"), duration: 123 },
      { type: "send", action: "sendMedia", requestId: "video", to: "oc_chat", mediaType: "video", fileName: "a.mp4", contentBase64: Buffer.from("mp4").toString("base64") },
      { type: "send", action: "sendCard", requestId: "card", to: "oc_chat", card: { elements: [{ tag: "markdown", content: "card" }] } },
      { type: "send", action: "patchCard", requestId: "patch-card", messageId: "om_card", card: { elements: [] } },
      { type: "send", action: "addReaction", requestId: "react-add", messageId: "om_1", emojiType: "THUMBSUP" },
      { type: "send", action: "removeReaction", requestId: "react-remove", messageId: "om_1", reactionId: "reaction_created" },
      { type: "send", action: "reaction.list", requestId: "react-list", messageId: "om_1", emojiType: "THUMBSUP" },
      { type: "send", action: "deleteMessage", requestId: "delete", messageId: "om_1" },
      { type: "send", action: "message.fetch", requestId: "fetch", messageId: "om_1" },
      { type: "send", action: "message.list_merge_forward", requestId: "merge", messageId: "om_merge" },
      { type: "send", action: "chat.thread_capable", requestId: "thread", chatId: "oc_chat" },
      { type: "send", action: "downloadResource", requestId: "download-image", messageId: "om_img", fileKey: "img_1", resourceType: "image" },
      { type: "send", action: "downloadResource", requestId: "download-resource", messageId: "om_1", fileKey: "file_1", resourceType: "file" },
    ];
    for (const request of requests) {
      proc.writeFrame(request);
      const result = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === request.requestId);
      assert.equal(result.ok, true, request.requestId);
    }
    await proc.close();

    assert.equal(callsOf(callsPath, "im.message.create").length, 5);
    assert.equal(callsOf(callsPath, "im.message.reply").length, 1);
    assert.equal(callsOf(callsPath, "im.image.create").length, 2);
    assert.equal(callsOf(callsPath, "im.file.create").length, 2);
    assert.equal(callsOf(callsPath, "im.message.patch").length, 1);
    assert.equal(callsOf(callsPath, "im.messageReaction.create")[0].data.reaction_type.emoji_type, "THUMBSUP");
    assert.equal(callsOf(callsPath, "im.messageReaction.delete")[0].path.reaction_id, "reaction_created");
    assert.equal(callsOf(callsPath, "im.messageReaction.list")[0].params.reaction_type, "THUMBSUP");
    assert.equal(callsOf(callsPath, "im.message.delete")[0].path.message_id, "om_1");
    assert.equal(callsOf(callsPath, "im.message.get").length, 2);
    assert.equal(callsOf(callsPath, "im.chat.get")[0].path.chat_id, "oc_chat");
    assert.equal(callsOf(callsPath, "im.image.get").length, 0);
    assert.deepEqual(callsOf(callsPath, "im.messageResource.get")[0], {
      path: { message_id: "om_img", file_key: "img_1" },
      params: { type: "image" },
    });
    assert.deepEqual(callsOf(callsPath, "im.messageResource.get")[1], {
      path: { message_id: "om_1", file_key: "file_1" },
      params: { type: "file" },
    });
    const postCreate = callsOf(callsPath, "im.message.create")[0];
    assert.equal(postCreate.params.receive_id_type, "chat_id");
    assert.equal(postCreate.data.msg_type, "post");
    assert.match(postCreate.data.content, /hello/);
    const audioUpload = callsOf(callsPath, "im.file.create").find((call) => call.data.file_name === "a.ogg");
    assert.equal(audioUpload.data.file_type, "opus");
    assert.equal(audioUpload.data.duration, 123);
    const videoSend = callsOf(callsPath, "im.message.create").find((call) => call.data.msg_type === "media");
    assert.match(videoSend.data.content, /file_uploaded/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("send media maps Feishu file_type and msg_type from media kind and extension", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    const requests = [
      { requestId: "image-kind", mediaType: "image", fileName: "no-extension" },
      { requestId: "audio-kind", mediaType: "audio", fileName: "voice.bin" },
      { requestId: "opus-kind", mediaType: "opus", fileName: "voice.bin" },
      { requestId: "ogg-kind", mediaType: "ogg", fileName: "voice.bin" },
      { requestId: "mp4-kind", mediaType: "mp4", fileName: "clip.bin" },
      { requestId: "mov-kind", mediaType: "mov", fileName: "clip.bin" },
      { requestId: "avi-kind", mediaType: "avi", fileName: "clip.bin" },
      { requestId: "file-kind", mediaType: "archive", fileName: "archive.bin" },
    ];
    for (const request of requests) {
      proc.writeFrame({
        type: "send",
        action: "sendMedia",
        to: "oc_chat",
        contentBase64: Buffer.from(request.requestId).toString("base64"),
        ...request,
      });
      const result = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === request.requestId);
      assert.equal(result.ok, true, request.requestId);
    }
    await proc.close();

    const creates = callsOf(callsPath, "im.message.create");
    const uploads = callsOf(callsPath, "im.file.create");
    assert.equal(callsOf(callsPath, "im.image.create").length, 1);
    assert.equal(creates.find((call) => call.data.msg_type === "image").data.msg_type, "image");
    assert.deepEqual(
      uploads.map((call) => call.data.file_type),
      ["opus", "opus", "opus", "mp4", "mp4", "mp4", "stream"],
    );
    assert.deepEqual(
      creates.filter((call) => call.data.msg_type !== "image").map((call) => call.data.msg_type),
      ["audio", "audio", "audio", "media", "media", "media", "file"],
    );
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("localPath uploads images, files, audio, and video as SDK streams", async () => {
  const root = createTempRoot();
  const mediaRoot = path.join(root, "media");
  fs.mkdirSync(mediaRoot);
  const fixtures = [
    { requestId: "local-image", mediaType: "image", fileName: "image.png", bytes: "image-from-file" },
    { requestId: "local-file", mediaType: "file", fileName: "report.pdf", bytes: "file-from-disk" },
    { requestId: "local-audio", mediaType: "audio", fileName: "voice.ogg", bytes: "audio-from-disk" },
    { requestId: "local-video", mediaType: "video", fileName: "clip.mp4", bytes: "video-from-disk" },
  ];
  for (const fixture of fixtures) {
    const fixturePath = path.join(mediaRoot, fixture.fileName);
    fs.writeFileSync(fixturePath, fixture.bytes);
    fixture.localPath = fixturePath;
    fixture.byteCount = Buffer.byteLength(fixture.bytes);
  }
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    for (const fixture of fixtures) {
      proc.writeFrame(makeUploadFrame({
        requestId: fixture.requestId,
        mediaType: fixture.mediaType,
        fileName: fixture.fileName,
        localPath: fixture.localPath,
        allowedLocalRoots: [mediaRoot],
        byteCount: fixture.byteCount,
        contentBase64: Buffer.from("must-not-be-used").toString("base64"),
      }));
      const result = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === fixture.requestId);
      assert.equal(result.ok, true, fixture.requestId);
    }
    await proc.close();

    const imageUploads = callsOf(callsPath, "im.image.create");
    const fileUploads = callsOf(callsPath, "im.file.create");
    assert.equal(imageUploads.length, 1);
    assert.equal(imageUploads[0].data.image.streamLike, true);
    assert.equal(imageUploads[0].data.image.bufferLength, undefined);
    assert.equal(imageUploads[0].data.image_type, "message");
    assert.deepEqual(
      fileUploads.map((call) => [call.data.file_name, call.data.file_type, call.data.file.streamLike, call.data.file.bufferLength]),
      [
        ["report.pdf", "pdf", true, undefined],
        ["voice.ogg", "opus", true, undefined],
        ["clip.mp4", "mp4", true, undefined],
      ],
    );
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("localPath upload rejects unsafe or invalid filesystem inputs without exposing full paths", async () => {
  const root = createTempRoot();
  const allowedRoot = path.join(root, "allowed");
  const outsideRoot = path.join(root, "outside");
  fs.mkdirSync(allowedRoot);
  fs.mkdirSync(outsideRoot);
  const insideFile = path.join(allowedRoot, "inside.bin");
  const outsideFile = path.join(outsideRoot, "outside.bin");
  const directoryPath = path.join(allowedRoot, "directory.bin");
  const symlinkPath = path.join(allowedRoot, "link.bin");
  const missingPath = path.join(allowedRoot, "missing.bin");
  fs.writeFileSync(insideFile, "inside");
  fs.writeFileSync(outsideFile, "outside");
  fs.mkdirSync(directoryPath);
  fs.symlinkSync(outsideFile, symlinkPath);

  const invalidFrames = [
    makeUploadFrame({ requestId: "empty-roots", localPath: insideFile, allowedLocalRoots: [] }),
    makeUploadFrame({ requestId: "filesystem-root", localPath: insideFile, allowedLocalRoots: [path.parse(insideFile).root] }),
    makeUploadFrame({ requestId: "path-outside", localPath: outsideFile, allowedLocalRoots: [allowedRoot] }),
    makeUploadFrame({ requestId: "symlink-outside", localPath: symlinkPath, allowedLocalRoots: [allowedRoot] }),
    makeUploadFrame({ requestId: "directory-path", localPath: directoryPath, allowedLocalRoots: [allowedRoot] }),
    makeUploadFrame({ requestId: "byte-count-mismatch", localPath: insideFile, allowedLocalRoots: [allowedRoot], byteCount: 999 }),
    makeUploadFrame({ requestId: "missing-file", localPath: missingPath, allowedLocalRoots: [allowedRoot] }),
    makeUploadFrame({ requestId: "relative-path", localPath: "relative.bin", allowedLocalRoots: [allowedRoot] }),
  ];

  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({ sdkPath, callsPath });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    for (const frame of invalidFrames) {
      proc.writeFrame(frame);
      const error = await proc.waitForFrame((entry) => entry.type === "error" && entry.requestId === frame.requestId);
      assert.equal(error.status, "api_error", frame.requestId);
      assert.equal(error.message.includes(root), false, `${frame.requestId} leaked temp root in ${error.message}`);
      assert.equal(error.message.includes(frame.localPath), false, `${frame.requestId} leaked localPath in ${error.message}`);
    }
    await proc.close();

    assert.equal(callsOf(callsPath, "im.image.create").length, 0);
    assert.equal(callsOf(callsPath, "im.file.create").length, 0);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("download image and resource return byte metadata and reject empty buffers without secrets", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        responses: [
          { code: 0, data: Buffer.from("image-bytes"), file_name: "image.png", headers: { "content-type": "image/png" } },
          { code: 0, data: Buffer.from("resource-bytes"), file_name: "resource.bin", headers: { "content-type": "application/octet-stream" } },
          { code: 0, data: Buffer.alloc(0), msg: secretValues.appSecret },
          { code: 230001, msg: "download denied " + secretValues.appSecret },
        ],
      },
    });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    proc.writeFrame({ type: "send", action: "downloadImage", requestId: "image", imageKey: "img_1" });
    const image = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "image");
    assert.equal(image.contentBase64, Buffer.from("image-bytes").toString("base64"));
    assert.equal(image.bytesBase64, image.contentBase64);
    assert.equal(image.contentType, "image/png");
    assert.equal(image.fileName, "image.png");
    assert.equal(image.size, Buffer.byteLength("image-bytes"));

    proc.writeFrame({ type: "send", action: "downloadResource", requestId: "resource", messageId: "om_1", fileKey: "file_1", resourceType: "file" });
    const resource = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "resource");
    assert.equal(resource.contentBase64, Buffer.from("resource-bytes").toString("base64"));
    assert.equal(resource.bytesBase64, resource.contentBase64);
    assert.equal(resource.contentType, "application/octet-stream");
    assert.equal(resource.fileName, "resource.bin");
    assert.equal(resource.size, Buffer.byteLength("resource-bytes"));

    proc.writeFrame({ type: "send", action: "downloadImage", requestId: "empty", imageKey: "img_empty" });
    const empty = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "empty");
    assert.equal(empty.status, "api_error");
    assert.equal(empty.errorKind, "api_error");
    assert.match(empty.message, /empty/i);
    assert.equal(empty.message.includes(secretValues.appSecret), false);

    proc.writeFrame({ type: "send", action: "downloadResource", requestId: "api-error", messageId: "om_1", fileKey: "file_1", resourceType: "file" });
    const apiError = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "api-error");
    assert.equal(apiError.status, "api_error");
    assert.equal(apiError.message.includes(secretValues.appSecret), false);

    const result = await proc.close();
    assert.equal(`${result.stdout}${result.stderr}`.includes(secretValues.appSecret), false);
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("message resource downloads read Feishu SDK writeFile responses", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  let proc;
  try {
    proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        responses: [
          {
            writeFileBytes: "image-resource-bytes",
            fileName: "resource-image.png",
            headers: { "content-type": "image/png" },
          },
        ],
      },
    });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    proc.writeFrame({
      type: "send",
      action: "downloadResource",
      requestId: "resource-write-file",
      messageId: "om_img",
      fileKey: "img_1",
      resourceType: "image",
    });
    const resource = await proc.waitForFrame((frame) => frame.requestId === "resource-write-file");

    assert.equal(resource.type, "sendResult");
    assert.equal(resource.contentBase64, Buffer.from("image-resource-bytes").toString("base64"));
    assert.equal(resource.bytesBase64, resource.contentBase64);
    assert.equal(resource.contentType, "image/png");
    assert.equal(resource.fileName, "resource-image.png");
    assert.deepEqual(callsOf(callsPath, "im.messageResource.get")[0], {
      path: { message_id: "om_img", file_key: "img_1" },
      params: { type: "image" },
    });
  } finally {
    await proc?.close?.();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("send errors are redacted and reply fallback follows sidecar safety semantics", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        responses: [
          {
            throw: {
              message: "Request failed with status code 400",
              responseStatus: 400,
              responseData: { code: 230042, msg: "reply failed: message unavailable" },
            },
          },
          { code: 0, data: { message_id: "om_fallback", chat_id: "oc_chat" } },
          { code: 230011, msg: "message was withdrawn " + secretValues.appSecret },
          { code: 999, msg: "scope missing " + secretValues.appSecret },
          {
            throw: {
              message: "Request failed with status code 400 " + secretValues.appSecret,
              responseStatus: 400,
              responseData: { code: 99991663, msg: "auth failed " + secretValues.appSecret },
            },
          },
        ],
      },
    });
    proc.writeFrame(baseInit());
    await proc.waitForFrame((frame) => frame.type === "ready");

    proc.writeFrame({
      type: "send",
      action: "sendText",
      requestId: "fallback",
      to: "oc_chat",
      text: "fallback",
      replyToMessageId: "withdrawn",
    });
    const fallback = await proc.waitForFrame((frame) => frame.type === "sendResult" && frame.requestId === "fallback");
    assert.equal(fallback.messageId, "om_fallback");
    assert.equal(fallback.ok, true);

    proc.writeFrame({
      type: "send",
      action: "sendText",
      requestId: "thread-no-fallback",
      to: "oc_chat",
      text: "thread",
      replyToMessageId: "withdrawn",
      replyInThread: true,
    });
    const threadError = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "thread-no-fallback");
    assert.equal(threadError.message.includes(secretValues.appSecret), false);

    proc.writeFrame({
      type: "send",
      action: "sendText",
      requestId: "api-error",
      to: "oc_chat",
      text: "api",
    });
    const apiError = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "api-error");
    assert.equal(apiError.status, "api_error");
    assert.equal(apiError.errorKind, "scope_missing");
    assert.equal(apiError.feishuCode, 999);
    assert.equal(apiError.feishuMsgClass, "scope_auth");
    assert.equal(apiError.message.includes(secretValues.appSecret), false);

    proc.writeFrame({
      type: "send",
      action: "sendText",
      requestId: "http-auth-error",
      to: "oc_chat",
      text: "auth",
    });
    const httpAuthError = await proc.waitForFrame((frame) => frame.type === "error" && frame.requestId === "http-auth-error");
    assert.equal(httpAuthError.status, "api_error");
    assert.equal(httpAuthError.errorKind, "scope_missing");
    assert.equal(httpAuthError.httpStatus, 400);
    assert.equal(httpAuthError.feishuCode, 99991663);
    assert.equal(httpAuthError.feishuMsgClass, "scope_auth");
    assert.equal(httpAuthError.message.includes(secretValues.appSecret), false);
    const result = await proc.close();
    assert.equal(`${result.stdout}${result.stderr}`.includes(secretValues.appSecret), false);
    assert.equal(callsOf(callsPath, "im.message.reply").length, 2);
    assert.equal(callsOf(callsPath, "im.message.create").length, 3);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function feishuMessageEvent(messageId, messageType, content) {
  return {
    type: "im.message.receive_v1",
    payload: {
      event_id: `event-${messageId}`,
      sender: {
        sender_id: { open_id: "ou_sender", user_id: "u_sender", union_id: "on_sender" },
        sender_type: "user",
      },
      message: {
        message_id: messageId,
        root_id: "root-1",
        parent_id: "parent-1",
        chat_id: "oc_chat",
        chat_type: "group",
        message_type: messageType,
        content: JSON.stringify(content),
        mentions: [{ key: "@_user_1", id: { open_id: "ou_mentioned" }, name: "Mentioned" }],
      },
    },
  };
}
