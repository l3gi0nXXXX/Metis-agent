#!/usr/bin/env node

import { Buffer } from "node:buffer";
import process from "node:process";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

import {
  addKnownSecrets,
  installConsoleStderrPatch,
  writeDiagnostic,
  writeProtocol,
} from "./lib/metis-sidecar-logger.mjs";

const PREFIX = "feishu-openclaw-sidecar";
const DEFAULT_READY_TIMEOUT_MS = 15_000;
const WITHDRAWN_REPLY_ERROR_CODES = new Set([230011, 231003]);
const SENSITIVE_ARG = /^(?:--)?(?:app[-_]?secret|verification[-_]?token|encrypt[-_]?key)$/i;

let state = {
  initialized: false,
  closing: false,
  accountId: "default",
  sdk: null,
  client: null,
  wsClient: null,
  eventDispatcher: null,
  seenEventIds: new Set(),
};

installConsoleStderrPatch({ prefix: PREFIX });

function emitProtocol(frame) {
  writeProtocol(frame);
}

function emitDiagnostic(level, phase, message, meta = {}) {
  const frame = {
    type: "diagnostic",
    level,
    phase,
    accountId: state.accountId,
    message,
    ...meta,
  };
  emitProtocol(frame);
  writeDiagnostic(level, message, { phase, accountId: state.accountId, ...meta }, { prefix: PREFIX });
}

function emitError(params) {
  emitProtocol({
    type: "error",
    accountId: state.accountId,
    phase: params.phase,
    status: params.status ?? "error",
    errorKind: params.errorKind,
    requestId: params.requestId,
    message: String(params.message ?? "Feishu sidecar error"),
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
  return import("@larksuiteoapi/node-sdk");
}

async function createProxyAgent(sdk, proxyUrl) {
  if (!proxyUrl) {
    return undefined;
  }
  if (typeof sdk.HttpsProxyAgent === "function") {
    return new sdk.HttpsProxyAgent(proxyUrl);
  }
  const mod = await import("https-proxy-agent");
  return new mod.HttpsProxyAgent(proxyUrl);
}

function getProxyUrl() {
  return (
    process.env.https_proxy ||
    process.env.HTTPS_PROXY ||
    process.env.http_proxy ||
    process.env.HTTP_PROXY ||
    ""
  ).trim();
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

async function initialize(frame) {
  if (state.initialized) {
    emitError({ phase: "init", status: "already_initialized", message: "Feishu sidecar is already initialized" });
    return;
  }
  state.accountId = String(frame.accountId ?? "default").trim() || "default";
  addKnownSecrets([frame.appSecret, frame.verificationToken, frame.encryptKey]);
  if (!frame.appId || !frame.appSecret) {
    emitError({ phase: "init", status: "invalid_init", message: "Feishu init requires appId and appSecret" });
    exitSoon(1);
    return;
  }
  try {
    const sdk = await loadSdk();
    state.sdk = sdk;
    const domain = resolveDomain(sdk, frame.domain);
    const proxyAgent = await createProxyAgent(sdk, getProxyUrl());

    state.eventDispatcher = new sdk.EventDispatcher({
      encryptKey: frame.encryptKey,
      verificationToken: frame.verificationToken,
    });
    registerEventHandlers(state.eventDispatcher);

    state.client = new sdk.Client({
      appId: frame.appId,
      appSecret: frame.appSecret,
      appType: sdk.AppType?.SelfBuild,
      domain,
    });
    state.wsClient = new sdk.WSClient({
      appId: frame.appId,
      appSecret: frame.appSecret,
      domain,
      loggerLevel: sdk.LoggerLevel?.info,
      ...(proxyAgent ? { agent: proxyAgent } : {}),
    });

    await withTimeout(
      state.wsClient.start({ eventDispatcher: state.eventDispatcher }),
      readyTimeoutMs(frame),
    );
    state.initialized = true;
    emitDiagnostic("info", "websocket.start", "Feishu WebSocket client started", { status: "ok" });
    emitProtocol({
      type: "ready",
      accountId: state.accountId,
      transport: "websocket",
      sdk: "@larksuiteoapi/node-sdk",
      domain: String(frame.domain ?? "feishu"),
    });
  } catch (error) {
    const status = error?.status ?? "start_failed";
    emitError({
      phase: "websocket.start",
      status,
      message: error?.message ?? String(error),
    });
    await closeSidecar(status);
    exitSoon(1);
  }
}

function registerEventHandlers(eventDispatcher) {
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
    handlers[eventType] = async (data) => handleSdkEvent(eventType, data);
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
  if (response?.code !== undefined && WITHDRAWN_REPLY_ERROR_CODES.has(response.code)) {
    return true;
  }
  const msg = String(response?.msg ?? "").toLowerCase();
  return msg.includes("withdrawn") || msg.includes("not found");
}

function isWithdrawnReplyError(error) {
  if (typeof error?.code === "number" && WITHDRAWN_REPLY_ERROR_CODES.has(error.code)) {
    return true;
  }
  const code = error?.response?.data?.code;
  if (typeof code === "number" && WITHDRAWN_REPLY_ERROR_CODES.has(code)) {
    return true;
  }
  const msg = String(error?.message ?? "").toLowerCase();
  return msg.includes("withdrawn") || msg.includes("not found");
}

function classifyApiError(errorOrResponse) {
  const code = errorOrResponse?.code ?? errorOrResponse?.response?.data?.code;
  const msg = String(errorOrResponse?.msg ?? errorOrResponse?.message ?? errorOrResponse?.response?.data?.msg ?? "");
  const lower = msg.toLowerCase();
  if (lower.includes("scope") || lower.includes("permission") || lower.includes("auth")) {
    return "scope_missing";
  }
  if (code === 99991663 || code === 99991664) {
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
    emitError({
      phase: `send.${frame.action ?? "unknown"}`,
      status: "api_error",
      errorKind: classifyApiError(error),
      requestId: frame.requestId,
      message: error?.message ?? String(error),
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
  if (mediaType === "audio" || name.endsWith(".opus") || name.endsWith(".ogg")) {
    return "opus";
  }
  if (mediaType === "video" || name.endsWith(".mp4") || name.endsWith(".mov") || name.endsWith(".avi")) {
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
  if (mediaType === "audio" || fileType === "opus") return "audio";
  if (mediaType === "video" || fileType === "mp4") return "media";
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

async function uploadImage(frame) {
  if (frame.imageKey) {
    return String(frame.imageKey);
  }
  const response = await state.client.im.image.create({
    data: {
      image_type: frame.imageType ?? "message",
      image: decodeContentBuffer(frame),
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
      file: decodeContentBuffer(frame),
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

function responseBuffer(response) {
  if (Buffer.isBuffer(response)) {
    return response;
  }
  if (Buffer.isBuffer(response?.data)) {
    return response.data;
  }
  if (response?.data instanceof ArrayBuffer) {
    return Buffer.from(response.data);
  }
  return Buffer.alloc(0);
}

function contentTypeOf(response) {
  return response?.headers?.["content-type"] ?? response?.header?.["content-type"] ?? response?.contentType;
}

async function downloadImage(frame) {
  const response = await state.client.im.image.get({
    path: { image_key: frame.imageKey },
  });
  assertApiSuccess(response, "Feishu image download failed");
  const buffer = responseBuffer(response);
  return {
    contentBase64: buffer.toString("base64"),
    bytesBase64: buffer.toString("base64"),
    contentType: contentTypeOf(response),
    size: buffer.length,
  };
}

async function downloadResource(frame) {
  const response = await state.client.im.messageResource.get({
    path: { message_id: frame.messageId, file_key: frame.fileKey },
    params: { type: frame.resourceType === "image" ? "image" : "file" },
  });
  assertApiSuccess(response, "Feishu message resource download failed");
  const buffer = responseBuffer(response);
  return {
    contentBase64: buffer.toString("base64"),
    bytesBase64: buffer.toString("base64"),
    contentType: contentTypeOf(response),
    fileName: response?.file_name ?? response?.fileName ?? response?.data?.file_name,
    size: buffer.length,
  };
}

async function closeSidecar(reason = "stop") {
  if (state.closing) {
    return;
  }
  state.closing = true;
  try {
    state.wsClient?.close?.();
  } catch (error) {
    writeDiagnostic("warn", `error closing Feishu WS client: ${error?.message ?? String(error)}`, undefined, {
      prefix: PREFIX,
    });
  }
  emitProtocol({
    type: "closed",
    accountId: state.accountId,
    reason,
  });
}

async function handleFrame(frame) {
  if (!frame || typeof frame !== "object" || Array.isArray(frame)) {
    emitError({ phase: "stdin", status: "invalid_frame", message: "Protocol frame must be a JSON object" });
    return;
  }
  switch (frame.type) {
    case "init":
      await initialize(frame);
      return;
    case "send":
    case "request":
      await handleSend(frame);
      return;
    case "close":
      await closeSidecar(frame.reason ?? "stop");
      process.exitCode = 0;
      process.exit(0);
      return;
    default:
      emitError({ phase: "stdin", status: "unknown_frame", message: `Unknown Feishu sidecar frame type: ${frame.type}` });
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
      if (!state.initialized) {
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
  if (state.initialized && !state.closing) {
    await closeSidecar("stdin_eof");
  }
}

process.on("SIGTERM", () => {
  void closeSidecar("sigterm").finally(() => process.exit(0));
});

process.on("SIGINT", () => {
  void closeSidecar("sigint").finally(() => process.exit(0));
});

void main().catch((error) => {
  emitError({ phase: "fatal", status: "exception", message: error?.message ?? String(error) });
  exitSoon(1);
});
