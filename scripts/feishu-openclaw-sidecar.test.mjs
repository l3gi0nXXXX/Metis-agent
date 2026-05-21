#!/usr/bin/env node

import assert from "node:assert/strict";
import { once } from "node:events";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const sidecarPath = path.join(import.meta.dirname, "feishu-openclaw-sidecar.mjs");
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

      const callsPath = process.env.METIS_FEISHU_FAKE_SDK_CALLS;
      const behavior = JSON.parse(process.env.METIS_FEISHU_FAKE_SDK_BEHAVIOR || "{}");

      function record(kind, value) {
        if (!callsPath) return;
        fs.appendFileSync(callsPath, JSON.stringify({ kind, value }, (_key, entry) => {
          if (Buffer.isBuffer(entry)) {
            return { bufferLength: entry.length };
          }
          if (entry && entry.type === "Buffer" && Array.isArray(entry.data)) {
            return { bufferLength: entry.data.length };
          }
          if (typeof entry === "function") {
            return "[Function]";
          }
          return entry;
        }) + "\\n");
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
          record("WSClient", options);
        }
        start({ eventDispatcher }) {
          record("WSClient.start", { hasDispatcher: Boolean(eventDispatcher) });
          if (behavior.start === "throw") {
            throw new Error("start failed with " + (behavior.secretEcho || "no secret"));
          }
          if (behavior.start === "never") {
            return new Promise(() => {});
          }
          const events = behavior.events || [];
          for (const [index, event] of events.entries()) {
            setTimeout(() => {
              void eventDispatcher.__emit(event.type, event.payload);
            }, event.delayMs ?? (index + 1));
          }
          return behavior.start === "async" ? new Promise((resolve) => setTimeout(resolve, behavior.startDelayMs ?? 5)) : undefined;
        }
        close() {
          record("WSClient.close", {});
        }
      }

      const responseQueue = Array.isArray(behavior.responses) ? [...behavior.responses] : [];
      function nextResponse(defaultValue) {
        const entry = responseQueue.length > 0 ? responseQueue.shift() : undefined;
        if (entry?.throw) {
          const error = new Error(entry.throw.message || "fake sdk error");
          if (entry.throw.code !== undefined) error.code = entry.throw.code;
          throw error;
        }
        return entry ?? defaultValue;
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
            },
            image: {
              create: async (request) => {
                record("im.image.create", request);
                return nextResponse({ code: 0, data: { image_key: "img_uploaded" } });
              },
              get: async (request) => {
                record("im.image.get", request);
                return nextResponse({ code: 0, data: Buffer.from("image-bytes"), headers: { "content-type": "image/png" } });
              },
            },
            file: {
              create: async (request) => {
                record("im.file.create", request);
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
  const child = spawn(process.execPath, [sidecarPath, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      METIS_FEISHU_SIDECAR_SDK: sdkPath,
      METIS_FEISHU_FAKE_SDK_CALLS: callsPath,
      METIS_FEISHU_FAKE_SDK_BEHAVIOR: JSON.stringify(behavior),
      HOME: fs.mkdtempSync(path.join(os.tmpdir(), "metis-feishu-sidecar-home-")),
      METIS_HOME: fs.mkdtempSync(path.join(os.tmpdir(), "metis-feishu-sidecar-metis-home-")),
      ...env,
    },
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

test("ready initializes the OpenClaw-style SDK model without putting secrets in argv or logs", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      env: { HTTPS_PROXY: "http://127.0.0.1:7897" },
    });
    proc.writeFrame(baseInit({ domain: "lark" }));
    const ready = await proc.waitForFrame((frame) => frame.type === "ready");
    assert.equal(ready.accountId, "acct-1");
    assert.equal(ready.transport, "websocket");

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
      { type: "send", action: "sendMedia", requestId: "image", to: "oc_chat", mediaType: "image", fileName: "a.png", contentBase64: Buffer.from("png").toString("base64") },
      { type: "send", action: "sendMedia", requestId: "audio", to: "oc_chat", mediaType: "audio", fileName: "a.ogg", contentBase64: Buffer.from("ogg").toString("base64"), duration: 123 },
      { type: "send", action: "sendMedia", requestId: "video", to: "oc_chat", mediaType: "video", fileName: "a.mp4", contentBase64: Buffer.from("mp4").toString("base64") },
      { type: "send", action: "sendCard", requestId: "card", to: "oc_chat", card: { elements: [{ tag: "markdown", content: "card" }] } },
      { type: "send", action: "patchCard", requestId: "patch-card", messageId: "om_card", card: { elements: [] } },
      { type: "send", action: "addReaction", requestId: "react-add", messageId: "om_1", emojiType: "THUMBSUP" },
      { type: "send", action: "removeReaction", requestId: "react-remove", messageId: "om_1", reactionId: "reaction_created" },
      { type: "send", action: "deleteMessage", requestId: "delete", messageId: "om_1" },
      { type: "send", action: "downloadImage", requestId: "download-image", imageKey: "img_1" },
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
    assert.equal(callsOf(callsPath, "im.image.create").length, 1);
    assert.equal(callsOf(callsPath, "im.file.create").length, 2);
    assert.equal(callsOf(callsPath, "im.message.patch").length, 1);
    assert.equal(callsOf(callsPath, "im.messageReaction.create")[0].data.reaction_type.emoji_type, "THUMBSUP");
    assert.equal(callsOf(callsPath, "im.messageReaction.delete")[0].path.reaction_id, "reaction_created");
    assert.equal(callsOf(callsPath, "im.message.delete")[0].path.message_id, "om_1");
    assert.equal(callsOf(callsPath, "im.image.get")[0].path.image_key, "img_1");
    assert.deepEqual(callsOf(callsPath, "im.messageResource.get")[0], {
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

test("send errors are redacted and reply fallback follows OpenClaw safety semantics", async () => {
  const root = createTempRoot();
  const { sdkPath, callsPath } = writeFakeSdk(root);
  try {
    const proc = spawnSidecar({
      sdkPath,
      callsPath,
      behavior: {
        responses: [
          { code: 230011, msg: "message was withdrawn" },
          { code: 0, data: { message_id: "om_fallback", chat_id: "oc_chat" } },
          { code: 230011, msg: "message was withdrawn " + secretValues.appSecret },
          { code: 999, msg: "scope missing " + secretValues.appSecret },
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
    assert.equal(apiError.message.includes(secretValues.appSecret), false);
    const result = await proc.close();
    assert.equal(`${result.stdout}${result.stderr}`.includes(secretValues.appSecret), false);
    assert.equal(callsOf(callsPath, "im.message.reply").length, 2);
    assert.equal(callsOf(callsPath, "im.message.create").length, 2);
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
