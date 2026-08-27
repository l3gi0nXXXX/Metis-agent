#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";

const [
  readyPath,
  eventsPath,
  replyMarker = "s5-p1-exact-once",
  processorEnteredPath = "",
  processorReleasePath = "",
  modelEnteredPath = "",
  modelReleasePath = "",
  modelMetricsPath = "",
] = process.argv.slice(2);
if (!readyPath || !eventsPath) {
  process.exitCode = 2;
} else {
  let nextMessageId = 500;
  let processorBlocked = false;
  let modelActive = 0;
  let modelEntered = 0;
  let modelMaxActive = 0;
  const deliveryByIid = new Map();
  const appendEvent = (event) => {
    fs.appendFileSync(eventsPath, `${JSON.stringify(event)}\n`, "utf8");
  };
  const sendJson = (response, statusCode, value) => {
    const body = JSON.stringify(value);
    response.writeHead(statusCode, {
      "content-type": "application/json; charset=utf-8",
      "content-length": Buffer.byteLength(body),
      connection: "close",
    });
    response.end(body);
  };
  const readBody = (request) => new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > 1024 * 1024) {
        reject(new Error("request_too_large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
  const deliveryFrom = (text) => text.match(/s5-p1-[0-9]{4}-end/)?.[0] ?? "";
  const iidFrom = (text) => text.match(/(?:issues\/|issue:)([0-9]+)/)?.[1] ?? "";
  const writeModelMetrics = () => {
    if (modelMetricsPath) {
      fs.writeFileSync(modelMetricsPath, JSON.stringify({ entered: modelEntered, active: modelActive, maxActive: modelMaxActive }), "utf8");
    }
  };
  const enterModelGate = async (body) => {
    const deliveryId = deliveryFrom(body) || (replyMarker && body.includes(replyMarker) ? replyMarker : "");
    const iid = iidFrom(body);
    modelEntered += 1;
    modelActive += 1;
    modelMaxActive = Math.max(modelMaxActive, modelActive);
    try {
      writeModelMetrics();
      if (modelEnteredPath) fs.writeFileSync(modelEnteredPath, `${modelEntered}\n`, "utf8");
      while (modelReleasePath && !fs.existsSync(modelReleasePath)) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      if (deliveryId && iid) deliveryByIid.set(iid, deliveryId);
      return deliveryId;
    } catch (error) {
      modelActive -= 1;
      try { writeModelMetrics(); } catch {}
      throw error;
    }
  };
  const leaveModelGate = () => {
    modelActive -= 1;
    writeModelMetrics();
  };

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    try {
      if (url.pathname === "/healthz") {
        response.writeHead(200, { "content-type": "text/plain; charset=utf-8", connection: "close" });
        response.end("ok");
        return;
      }
      if (url.pathname.endsWith("/getMe")) {
        sendJson(response, 200, { ok: true, result: { id: 42, is_bot: true, first_name: "S5", username: "s5_fake_bot" } });
        return;
      }
      if (url.pathname.endsWith("/getWebhookInfo")) {
        sendJson(response, 200, { ok: true, result: { url: "", pending_update_count: 0 } });
        return;
      }
      if (url.pathname.endsWith("/deleteWebhook") || url.pathname.endsWith("/setMyCommands")) {
        sendJson(response, 200, { ok: true, result: true });
        return;
      }
      if (url.pathname.endsWith("/getUpdates")) {
        setTimeout(() => sendJson(response, 200, { ok: true, result: [] }), 50);
        return;
      }
      if (url.pathname.endsWith("/sendMessage")) {
        const body = await readBody(request);
        let parsed = {};
        try { parsed = JSON.parse(body); } catch { parsed = {}; }
        nextMessageId += 1;
        const text = `${parsed.text ?? ""}`;
        appendEvent({ kind: "telegram_send", deliveryId: deliveryFrom(text), chatId: `${parsed.chat_id ?? ""}`, text, messageId: nextMessageId });
        sendJson(response, 200, { ok: true, result: { message_id: nextMessageId, chat: { id: parsed.chat_id ?? 0 }, text: parsed.text ?? "" } });
        return;
      }
      if (url.pathname.endsWith("/responses")) {
        const body = await readBody(request);
        const deliveryId = await enterModelGate(body);
        try {
          appendEvent({ kind: "model_response", deliveryId, stream: false, responseMode: "json", requestBytes: Buffer.byteLength(body) });
          sendJson(response, 200, {
            id: "resp_s5_fake",
            object: "response",
            status: "completed",
            model: "gpt-5.4",
            output_text: JSON.stringify({
              header: { taskKind: "issue-comment-reply" },
              result: { replyBody: `S5 本地模型回复 中文🙂 ${deliveryId}` },
              needsHumanReview: false,
            }),
            output: [],
            usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
          });
        } finally {
          leaveModelGate();
        }
        return;
      }
      if (url.pathname.endsWith("/chat/completions")) {
        const body = await readBody(request);
        let requestBody = {};
        try { requestBody = JSON.parse(body); } catch { requestBody = {}; }
        const streaming = requestBody.stream === true;
        const deliveryId = await enterModelGate(body);
        try {
          appendEvent({ kind: "model_response", deliveryId, stream: streaming, responseMode: streaming ? "sse" : "json", requestBytes: Buffer.byteLength(body) });
          const content = `S5 本地模型回复 中文🙂 ${deliveryId}`;
          if (streaming) {
            const chunk = JSON.stringify({
              id: "chatcmpl_s5_fake",
              object: "chat.completion.chunk",
              created: 0,
              model: "gpt-5.4",
              choices: [{
                index: 0,
                delta: { role: "assistant", content, reasoning_content: null },
                finish_reason: "stop",
              }],
              usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
            });
            response.writeHead(200, {
              "content-type": "text/event-stream; charset=utf-8",
              connection: "close",
            });
            response.end(`data: ${chunk}\n\ndata: [DONE]\n\n`);
          } else {
            sendJson(response, 200, {
              id: "chatcmpl_s5_fake",
              object: "chat.completion",
              created: 0,
              model: "gpt-5.4",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: "",
                  reasoning_content: null,
                  tool_calls: [{
                    id: "call_s5_answer",
                    type: "function",
                    function: {
                      name: "_answer_",
                      arguments: JSON.stringify({ result: content }),
                    },
                  }],
                },
                finish_reason: "tool_calls",
              }],
              usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
            });
          }
        } finally {
          leaveModelGate();
        }
        return;
      }
      if (url.pathname === "/open-apis/auth/v3/tenant_access_token/internal") {
        await readBody(request);
        sendJson(response, 200, { code: 0, msg: "ok", tenant_access_token: "fake-s5-feishu-token", expire: 7200 });
        return;
      }
      if (request.method === "POST" && url.pathname === "/open-apis/im/v1/messages") {
        const body = await readBody(request);
        let parsed = {};
        try { parsed = JSON.parse(body); } catch { parsed = {}; }
        const content = `${parsed.content ?? ""}`;
        const deliveryId = deliveryFrom(content);
        appendEvent({ kind: "feishu_send", deliveryId, receiveId: `${parsed.receive_id ?? ""}`, msgType: `${parsed.msg_type ?? ""}` });
        sendJson(response, 200, { code: 0, msg: "ok", data: { message_id: `fm_${deliveryId}` } });
        return;
      }
      if (url.pathname.startsWith("/api/v5/")) {
        const writeback = request.method === "POST" && url.pathname.match(/^\/api\/v5\/repos\/cangjie\/compiler\/issues\/([0-9]+)\/comments$/);
        if (writeback) {
          await readBody(request);
          const iid = writeback[1];
          appendEvent({ kind: "gitcode_writeback", deliveryId: deliveryByIid.get(iid) ?? "", iid });
          sendJson(response, 201, { id: Number(iid), body: "accepted" });
          return;
        }
        if (request.method === "GET") {
          appendEvent({ kind: "gitcode_get", deliveryId: "", path: url.pathname });
        }
        if (processorEnteredPath && processorReleasePath && !processorBlocked) {
          processorBlocked = true;
          fs.writeFileSync(processorEnteredPath, "1\n", { encoding: "utf8", mode: 0o600 });
          while (!fs.existsSync(processorReleasePath)) {
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
        }
        sendJson(response, 404, { message: "not_found" });
        return;
      }
      sendJson(response, 404, { status: "not_found" });
    } catch {
      if (!response.headersSent) {
        sendJson(response, 500, { status: "fixture_error" });
      } else {
        response.end();
      }
    }
  });

  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    if (!address || typeof address === "string") {
      process.exitCode = 3;
      server.close();
      return;
    }
    fs.writeFileSync(readyPath, JSON.stringify({ port: address.port }), "utf8");
  });

  const stop = () => server.close(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
