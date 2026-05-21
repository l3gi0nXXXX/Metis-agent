package metis.gateway.channels.feishu

import std.collection.ArrayList
import std.time.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public const FEISHU_SIDECAR_API_SCHEMA: String = "metis.feishu.sidecar.api.v1"

public interface FeishuSidecarRequestRunner {
    func run(request: JsonObject): JsonObject
}

public class FeishuSidecarNoopRequestRunner <: FeishuSidecarRequestRunner {
    public init() {}

    public func run(request: JsonObject): JsonObject {
        let out = JsonObject()
        out.put("ok", JsonBool(false))
        out.put("status", JsonString("not_configured"))
        out.put("error", JsonString("Feishu sidecar API runner is not configured."))
        out.put("operation", request.get("operation") ?? JsonString(""))
        out
    }
}

public class FeishuSidecarRequestAccount {
    public let accountId: String
    public let appId: String
    public let appSecret: String
    public let domain: String
    public let verificationToken: String
    public let encryptKey: String

    public init(
        accountId!: String = "default",
        appId!: String = "",
        appSecret!: String = "",
        domain!: String = "https://open.feishu.cn",
        verificationToken!: String = "",
        encryptKey!: String = ""
    ) {
        this.accountId = gatewayFeishuNormalizeAccountId(accountId)
        this.appId = appId.trimAscii()
        this.appSecret = appSecret.trimAscii()
        this.domain = if (domain.trimAscii().isEmpty()) { "https://open.feishu.cn" } else { domain.trimAscii() }
        this.verificationToken = verificationToken.trimAscii()
        this.encryptKey = encryptKey.trimAscii()
    }
}

public class FeishuSidecarRequestRunnerOptions {
    public let command: String
    public let args: Array<String>
    public let readyTimeoutMs: Int64
    public let requestTimeoutMs: Int64
    public let readTimeoutMs: Int64
    public let stopTimeoutMs: Int64

    public init(
        command!: String = "node",
        args!: Array<String> = ["scripts/feishu-openclaw-sidecar.mjs"],
        readyTimeoutMs!: Int64 = 10000,
        requestTimeoutMs!: Int64 = 30000,
        readTimeoutMs!: Int64 = 250,
        stopTimeoutMs!: Int64 = 500
    ) {
        this.command = if (command.trimAscii().isEmpty()) { "node" } else { command.trimAscii() }
        this.args = args
        this.readyTimeoutMs = if (readyTimeoutMs > 0) { readyTimeoutMs } else { 10000 }
        this.requestTimeoutMs = if (requestTimeoutMs > 0) { requestTimeoutMs } else { 30000 }
        this.readTimeoutMs = if (readTimeoutMs > 0) { readTimeoutMs } else { 250 }
        this.stopTimeoutMs = if (stopTimeoutMs > 0) { stopTimeoutMs } else { 500 }
    }
}

public class FeishuSidecarProcessRequestRunner <: FeishuSidecarRequestRunner {
    private let account: FeishuSidecarRequestAccount
    private let runner: FeishuSidecarProtocolRunner
    private let options: FeishuSidecarRequestRunnerOptions

    public init(
        account!: FeishuSidecarRequestAccount,
        runner!: FeishuSidecarProtocolRunner = FeishuSidecarStdioRunner(),
        options!: FeishuSidecarRequestRunnerOptions = FeishuSidecarRequestRunnerOptions()
    ) {
        this.account = account
        this.runner = runner
        this.options = options
    }

    public func run(request: JsonObject): JsonObject {
        if (this.account.appId.isEmpty() || this.account.appSecret.isEmpty()) {
            return feishuSidecarProcessFailure("not_configured", "Feishu sidecar API requires appId and appSecret.")
        }
        let spec = FeishuSidecarLaunchSpec(command: this.options.command, args: this.options.args)
        match (this.runner.start(spec)) {
            case FeishuSidecarProtocolStartResult.Failed(reason) =>
                return feishuSidecarProcessFailure(if (reason.contains("not_configured")) { "not_configured" } else { "launch_failed" }, reason)
            case FeishuSidecarProtocolStartResult.Started(proc) =>
                try {
                    proc.writeLine(feishuSidecarCompactJsonLine(this.initFrame().toJsonString()))
                    let ready = this.waitForReady(proc)
                    if (!feishuSidecarJsonBool(ready, "ok", fallback: false)) {
                        return ready
                    }
                    let requestId = "metis-sidecar-api"
                    proc.writeLine(feishuSidecarCompactJsonLine(this.requestFrame(request, requestId).toJsonString()))
                    return this.waitForResponse(proc, requestId)
                } catch (e: Exception) {
                    return feishuSidecarProcessFailure("api_error", e.message)
                } finally {
                    this.stopProcess(proc)
                }
        }
    }

    private func initFrame(): JsonObject {
        let out = JsonObject()
        out.put("type", JsonString("init"))
        out.put("accountId", JsonString(this.account.accountId))
        out.put("appId", JsonString(this.account.appId))
        out.put("appSecret", JsonString(this.account.appSecret))
        out.put("domain", JsonString(this.account.domain))
        out.put("verificationToken", JsonString(this.account.verificationToken))
        out.put("encryptKey", JsonString(this.account.encryptKey))
        out.put("mode", JsonString("websocket"))
        out.put("readyTimeoutMs", JsonInt(this.options.readyTimeoutMs))
        out
    }

    private func requestFrame(request: JsonObject, requestId: String): JsonObject {
        let operation = feishuSidecarJsonString(request, "operation")
        let params = match (request.get("params")) {
            case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
            case None => JsonObject()
        }
        let out = JsonObject()
        out.put("type", JsonString("request"))
        out.put("requestId", JsonString(requestId))
        out.put("accountId", JsonString(feishuSidecarJsonString(request, "accountId", fallback: this.account.accountId)))
        out.put("action", JsonString(this.sidecarAction(operation, params)))
        this.copyFields(params, out)
        this.applyOperationMapping(operation, params, out)
        out
    }

    private func sidecarAction(operation: String, params: JsonObject): String {
        match (operation.trimAscii()) {
            case "message.create" | "message.reply" => "sendText"
            case "card.create" | "card.reply" => "sendCard"
            case "card.patch" => "patchCard"
            case "media.upload" => "uploadMedia"
            case "message.send_media" | "message.reply_media" => "sendMedia"
            case "reaction.add" => "addReaction"
            case "reaction.remove" => "removeReaction"
            case "reaction.list" => "reaction.list"
            case "message.delete" => "deleteMessage"
            case "message.fetch" => "message.fetch"
            case "message.list_merge_forward" => "message.list_merge_forward"
            case "resource.download" =>
                if (feishuSidecarJsonString(params, "resourceType").toAsciiLower() == "image") { "downloadImage" } else { "downloadResource" }
            case "chat.thread_capable" => "chat.thread_capable"
            case _ => operation.trimAscii()
        }
    }

    private func applyOperationMapping(operation: String, params: JsonObject, out: JsonObject): Unit {
        let receiveId = feishuSidecarJsonString(params, "receiveId")
        if (!receiveId.isEmpty()) {
            out.put("to", JsonString(receiveId))
        }
        let messageId = feishuSidecarJsonString(params, "messageId")
        if (!messageId.isEmpty()) {
            out.put("messageId", JsonString(messageId))
        }
        if (operation == "media.upload") {
            out.put("contentBase64", JsonString(feishuSidecarJsonString(params, "bytesBase64")))
        }
        if (operation == "message.send_media" || operation == "message.reply_media") {
            let messageType = feishuSidecarJsonString(params, "messageType").toAsciiLower()
            let mediaKey = feishuSidecarJsonString(params, "mediaKey")
            if (messageType == "image") {
                out.put("mediaType", JsonString("image"))
                out.put("imageKey", JsonString(mediaKey))
            } else {
                out.put("mediaType", JsonString(if (messageType == "audio") { "audio" } else if (messageType == "media") { "video" } else { messageType }))
                out.put("fileKey", JsonString(mediaKey))
            }
        }
        if (operation == "reaction.add" || operation == "reaction.remove") {
            let reactionType = feishuSidecarJsonString(params, "reactionType")
            if (!reactionType.isEmpty()) {
                out.put("emojiType", JsonString(reactionType))
                if (operation == "reaction.remove") {
                    out.put("reactionId", JsonString(reactionType))
                }
            }
        }
        if (operation == "resource.download") {
            let resourceType = feishuSidecarJsonString(params, "resourceType").toAsciiLower()
            let fileKey = feishuSidecarJsonString(params, "fileKey")
            if (resourceType == "image") {
                out.put("imageKey", JsonString(fileKey))
            } else {
                out.put("fileKey", JsonString(fileKey))
            }
        }
    }

    private func waitForReady(proc: FeishuSidecarProtocolProcess): JsonObject {
        let deadline = this.nowMs() + this.options.readyTimeoutMs
        while (this.nowMs() <= deadline) {
            match (proc.readLine(this.options.readTimeoutMs)) {
                case Some(line) =>
                    let frame = this.parseFrame(line)
                    let frameType = feishuSidecarJsonString(frame, "type")
                    if (frameType == "ready") {
                        let out = JsonObject()
                        out.put("ok", JsonBool(true))
                        out.put("status", JsonString("ready"))
                        return out
                    }
                    if (frameType == "error") {
                        return this.errorResult(frame)
                    }
                case None =>
                    if (!proc.isAlive()) {
                        return feishuSidecarProcessFailure("unexpected_exit", "Feishu sidecar exited before ready.")
                    }
            }
        }
        feishuSidecarProcessFailure("ready_timeout", "Feishu sidecar ready timeout.")
    }

    private func waitForResponse(proc: FeishuSidecarProtocolProcess, requestId: String): JsonObject {
        let deadline = this.nowMs() + this.options.requestTimeoutMs
        while (this.nowMs() <= deadline) {
            match (proc.readLine(this.options.readTimeoutMs)) {
                case Some(line) =>
                    let frame = this.parseFrame(line)
                    let frameType = feishuSidecarJsonString(frame, "type")
                    if (frameType == "sendResult" && feishuSidecarJsonString(frame, "requestId") == requestId) {
                        return this.successResult(frame)
                    }
                    if (frameType == "error" && feishuSidecarJsonString(frame, "requestId") == requestId) {
                        return this.errorResult(frame)
                    }
                    if (frameType == "closed") {
                        return feishuSidecarProcessFailure("closed", "Feishu sidecar closed before API response.")
                    }
                case None =>
                    if (!proc.isAlive()) {
                        return feishuSidecarProcessFailure("unexpected_exit", "Feishu sidecar exited before API response.")
                    }
            }
        }
        feishuSidecarProcessFailure("request_timeout", "Feishu sidecar API request timeout.")
    }

    private func parseFrame(line: String): JsonObject {
        try {
            JsonValue.fromStr(line.trimAscii()).asObject()
        } catch (e: Exception) {
            feishuSidecarProcessFailure("protocol_error", "Feishu sidecar protocol parse failed: ${e.message}")
        }
    }

    private func successResult(frame: JsonObject): JsonObject {
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("ok"))
        this.copyFields(frame, out, skipProtocol: true)
        let contentBase64 = feishuSidecarJsonString(frame, "contentBase64")
        if (!contentBase64.isEmpty() && out.get("bytesBase64").isNone()) {
            out.put("bytesBase64", JsonString(contentBase64))
        }
        out
    }

    private func errorResult(frame: JsonObject): JsonObject {
        let status = feishuSidecarJsonString(frame, "status", fallback: "api_error")
        let message = feishuSidecarFirstString(frame, ["message", "error", "detail"], fallback: status)
        feishuSidecarProcessFailure(status, feishuSidecarRedactSensitiveText(message))
    }

    private func copyFields(source: JsonObject, target: JsonObject, skipProtocol!: Bool = false): Unit {
        for (key in source.getFields().keys()) {
            if (skipProtocol && (key == "type" || key == "requestId" || key == "action" || key == "accountId")) {
                continue
            }
            match (source.get(key)) {
                case Some(v) => target.put(key, v)
                case None => ()
            }
        }
    }

    private func stopProcess(proc: FeishuSidecarProtocolProcess): Unit {
        try { proc.writeLine("{\"type\":\"close\",\"reason\":\"api_request_done\"}") } catch (_e: Exception) { () }
        match (proc.wait(this.options.stopTimeoutMs)) {
            case Some(_) => ()
            case None => proc.terminate(true)
        }
    }

    private func nowMs(): Int64 {
        DateTime.now().toUnixTimeStamp().toMilliseconds()
    }
}

public class FeishuSidecarApiClient <: FeishuApiClient {
    private let runner: FeishuSidecarRequestRunner

    public init(runner!: FeishuSidecarRequestRunner = FeishuSidecarNoopRequestRunner()) {
        this.runner = runner
    }

    public func isThreadCapableGroup(chatId: String): Bool {
        let params = JsonObject()
        params.put("chatId", JsonString(chatId.trimAscii()))
        let result = this.invoke("chat.thread_capable", "default", params)
        feishuSidecarJsonBool(result, "capable", fallback: false)
    }

    public func fetchMessage(accountId: String, messageId: String): FeishuMessageFetchResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        let result = this.invoke("message.fetch", accountId, params)
        this.messageFetchResult(result, fallbackMessageId: messageId)
    }

    public func listMergeForwardMessages(accountId: String, messageId: String): FeishuMergeForwardFetchResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        let result = this.invoke("message.list_merge_forward", accountId, params)
        let status = feishuSidecarStatus(result)
        if (!feishuSidecarOk(result)) {
            return FeishuMergeForwardFetchResult(status: status, error: feishuSidecarError(result, status))
        }
        let messages = ArrayList<FeishuMessageFetchResult>()
        let messageRows = feishuSidecarJsonArray(result, "messages")
        for (i in 0..messageRows.size()) {
            let item = messageRows[i]
            try {
                messages.add(this.messageFetchResult(item.asObject()))
            } catch (_e: Exception) {
                ()
            }
        }
        FeishuMergeForwardFetchResult(ok: true, status: status, messages: messages.toArray())
    }

    public func fetchMessageResource(
        accountId: String,
        messageId: String,
        fileKey: String,
        resourceType: String
    ): FeishuResourceDownloadResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        params.put("fileKey", JsonString(fileKey.trimAscii()))
        params.put("resourceType", JsonString(resourceType.trimAscii().toAsciiLower()))
        let result = this.invoke("resource.download", accountId, params)
        let status = feishuSidecarStatus(result)
        if (!feishuSidecarOk(result)) {
            return FeishuResourceDownloadResult(status: status, error: feishuSidecarError(result, status))
        }
        let bytesBase64 = feishuSidecarFirstString(result, ["bytesBase64", "bodyBase64", "dataBase64"])
        let bytesUtf8 = feishuSidecarFirstString(result, ["bytesUtf8", "body", "data"])
        let bytes = if (!bytesBase64.isEmpty()) {
            feishuSidecarDecodeBase64(bytesBase64)
        } else {
            bytesUtf8.toArray()
        }
        FeishuResourceDownloadResult(
            ok: true,
            status: status,
            bytes: bytes,
            contentType: feishuSidecarFirstString(result, ["contentType", "mimeType"]),
            fileName: feishuSidecarFirstString(result, ["fileName", "filename"])
        )
    }

    public func sendTextMessage(
        accountId: String,
        rawPeerId: String,
        receiveId: String,
        receiveIdType: String,
        text: String,
        replyToMessageId: Option<String>,
        replyInThread: Bool
    ): FeishuApiSendResult {
        let params = this.peerParams(rawPeerId, receiveId, receiveIdType, replyInThread)
        params.put("msgType", JsonString("text"))
        params.put("messageType", JsonString("text"))
        params.put("text", JsonString(text))
        match (replyToMessageId) {
            case Some(rawReplyId) =>
                let replyId = rawReplyId.trimAscii()
                if (!replyId.isEmpty()) {
                    params.put("replyToMessageId", JsonString(replyId))
                    let reply = this.sendResult(this.invoke("message.reply", accountId, params))
                    if (reply.ok || !feishuSidecarShouldFallbackReply(reply.status, reply.error)) {
                        return reply
                    }
                    let fallback = this.peerParams(rawPeerId, receiveId, receiveIdType, replyInThread)
                    fallback.put("msgType", JsonString("text"))
                    fallback.put("messageType", JsonString("text"))
                    fallback.put("text", JsonString(text))
                    fallback.put("fallbackFromReplyToMessageId", JsonString(replyId))
                    return this.sendResult(this.invoke("message.create", accountId, fallback))
                }
            case None => ()
        }
        this.sendResult(this.invoke("message.create", accountId, params))
    }

    public func sendInteractiveCard(
        accountId: String,
        rawPeerId: String,
        receiveId: String,
        receiveIdType: String,
        card: FeishuInteractiveCard,
        replyToMessageId: Option<String>,
        replyInThread: Bool
    ): FeishuApiSendResult {
        let params = this.peerParams(rawPeerId, receiveId, receiveIdType, replyInThread)
        params.put("msgType", JsonString("interactive"))
        params.put("messageType", JsonString("interactive"))
        params.put("card", card.toJson())
        match (replyToMessageId) {
            case Some(rawReplyId) =>
                let replyId = rawReplyId.trimAscii()
                if (!replyId.isEmpty()) {
                    params.put("replyToMessageId", JsonString(replyId))
                    return this.sendResult(this.invoke("card.reply", accountId, params))
                }
            case None => ()
        }
        this.sendResult(this.invoke("card.create", accountId, params))
    }

    public func patchInteractiveCard(accountId: String, messageId: String, card: FeishuInteractiveCard): FeishuApiSendResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        params.put("card", card.toJson())
        this.sendResult(this.invoke("card.patch", accountId, params), fallbackMessageId: messageId)
    }

    public func uploadMedia(
        accountId: String,
        mediaType: String,
        localPath: String,
        bytes: Array<Byte>,
        mimeType: String,
        fileName: String
    ): FeishuApiSendResult {
        let params = JsonObject()
        params.put("mediaType", JsonString(mediaType.trimAscii().toAsciiLower()))
        params.put("localPath", JsonString(localPath.trimAscii()))
        params.put("bytesBase64", JsonString(toBase64String(bytes)))
        params.put("byteCount", JsonInt(bytes.size))
        params.put("mimeType", JsonString(mimeType.trimAscii()))
        params.put("fileName", JsonString(fileName.trimAscii()))
        this.sendResult(
            this.invoke("media.upload", accountId, params),
            idKeys: ["mediaKey", "imageKey", "fileKey", "key", "messageId", "message_id"]
        )
    }

    public func sendMediaMessage(
        accountId: String,
        rawPeerId: String,
        receiveId: String,
        receiveIdType: String,
        messageType: String,
        mediaKey: String,
        caption: String,
        replyToMessageId: Option<String>,
        replyInThread: Bool
    ): FeishuApiSendResult {
        let params = this.peerParams(rawPeerId, receiveId, receiveIdType, replyInThread)
        params.put("msgType", JsonString(messageType.trimAscii().toAsciiLower()))
        params.put("messageType", JsonString(messageType.trimAscii().toAsciiLower()))
        params.put("mediaKey", JsonString(mediaKey.trimAscii()))
        params.put("caption", JsonString(caption.trimAscii()))
        match (replyToMessageId) {
            case Some(rawReplyId) =>
                let replyId = rawReplyId.trimAscii()
                if (!replyId.isEmpty()) {
                    params.put("replyToMessageId", JsonString(replyId))
                    return this.sendResult(this.invoke("message.reply_media", accountId, params))
                }
            case None => ()
        }
        this.sendResult(this.invoke("message.send_media", accountId, params))
    }

    public func addMessageReaction(accountId: String, messageId: String, reactionType: String): FeishuApiSendResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        params.put("reactionType", JsonString(reactionType.trimAscii()))
        this.sendResult(this.invoke("reaction.add", accountId, params), fallbackMessageId: messageId)
    }

    public func removeMessageReaction(accountId: String, messageId: String, reactionType: String): FeishuApiSendResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        params.put("reactionType", JsonString(reactionType.trimAscii()))
        this.sendResult(this.invoke("reaction.remove", accountId, params), fallbackMessageId: messageId)
    }

    public func listMessageReactions(accountId: String, messageId: String): Array<String> {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        let result = this.invoke("reaction.list", accountId, params)
        if (!feishuSidecarOk(result)) {
            return []
        }
        let out = ArrayList<String>()
        let reactionRows = feishuSidecarJsonArray(result, "reactions")
        for (i in 0..reactionRows.size()) {
            let item = reactionRows[i]
            try {
                let token = item.asString().getValue().trimAscii()
                if (!token.isEmpty()) {
                    out.add(token)
                }
            } catch (_e1: Exception) {
                try {
                    let obj = item.asObject()
                    let token = feishuSidecarFirstString(obj, ["emojiType", "emoji_type", "reactionType", "reaction_type"])
                    if (!token.isEmpty()) {
                        out.add(token)
                    }
                } catch (_e2: Exception) {
                    ()
                }
            }
        }
        out.toArray()
    }

    public func deleteMessage(accountId: String, messageId: String): FeishuApiSendResult {
        let params = JsonObject()
        params.put("messageId", JsonString(messageId.trimAscii()))
        this.sendResult(this.invoke("message.delete", accountId, params), fallbackMessageId: messageId)
    }

    private func peerParams(rawPeerId: String, receiveId: String, receiveIdType: String, replyInThread: Bool): JsonObject {
        let params = JsonObject()
        params.put("rawPeerId", JsonString(rawPeerId.trimAscii()))
        params.put("receiveId", JsonString(receiveId.trimAscii()))
        params.put("receiveIdType", JsonString(receiveIdType.trimAscii()))
        params.put("replyInThread", JsonBool(replyInThread))
        params
    }

    private func invoke(operation: String, accountId: String, params: JsonObject): JsonObject {
        let request = JsonObject()
        request.put("schema", JsonString(FEISHU_SIDECAR_API_SCHEMA))
        request.put("operation", JsonString(operation.trimAscii()))
        request.put("accountId", JsonString(gatewayFeishuNormalizeAccountId(accountId)))
        request.put("params", params)
        try {
            this.runner.run(request)
        } catch (e: Exception) {
            let out = JsonObject()
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("api_error"))
            out.put("error", JsonString(e.message))
            out
        }
    }

    private func messageFetchResult(result: JsonObject, fallbackMessageId!: String = ""): FeishuMessageFetchResult {
        let status = feishuSidecarStatus(result)
        FeishuMessageFetchResult(
            ok: feishuSidecarOk(result),
            status: status,
            messageId: feishuSidecarFirstString(result, ["messageId", "message_id"], fallback: fallbackMessageId),
            messageType: feishuSidecarFirstString(result, ["messageType", "message_type", "msgType", "msg_type"]),
            content: feishuSidecarFirstString(result, ["content", "text"]),
            raw: feishuSidecarFirstString(result, ["raw", "rawJson"]),
            error: feishuSidecarError(result, status)
        )
    }

    private func sendResult(
        result: JsonObject,
        fallbackMessageId!: String = "",
        idKeys!: Array<String> = ["messageId", "message_id", "openMessageId", "open_message_id"]
    ): FeishuApiSendResult {
        let status = feishuSidecarStatus(result)
        let id = feishuSidecarFirstString(result, idKeys, fallback: fallbackMessageId)
        FeishuApiSendResult(
            ok: feishuSidecarOk(result),
            status: status,
            messageId: id,
            error: feishuSidecarError(result, status)
        )
    }
}

private func feishuSidecarJsonString(obj: JsonObject, key: String, fallback!: String = ""): String {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                v.asString().getValue().trimAscii()
            } catch (_e1: Exception) {
                match (v) {
                    case i: JsonInt => i.getValue().toString()
                    case b: JsonBool => if (b.getValue()) { "true" } else { "false" }
                    case _ => fallback
                }
            }
        case None => fallback
    }
}

private func feishuSidecarJsonBool(obj: JsonObject, key: String, fallback!: Bool = false): Bool {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                v.asBool().getValue()
            } catch (_e: Exception) {
                let text = feishuSidecarJsonString(obj, key).toAsciiLower()
                if (text == "true" || text == "1" || text == "yes") {
                    true
                } else if (text == "false" || text == "0" || text == "no") {
                    false
                } else {
                    fallback
                }
            }
        case None => fallback
    }
}

private func feishuSidecarJsonArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func feishuSidecarFirstString(obj: JsonObject, keys: Array<String>, fallback!: String = ""): String {
    for (key in keys) {
        let value = feishuSidecarJsonString(obj, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    fallback.trimAscii()
}

private func feishuSidecarStatus(result: JsonObject): String {
    let status = feishuSidecarJsonString(result, "status")
    if (!status.isEmpty()) {
        return status
    }
    if (feishuSidecarOk(result)) {
        "ok"
    } else {
        "api_error"
    }
}

private func feishuSidecarOk(result: JsonObject): Bool {
    if (feishuSidecarJsonBool(result, "ok", fallback: false)) {
        return true
    }
    let status = feishuSidecarJsonString(result, "status").toAsciiLower()
    status == "ok" || status == "success"
}

private func feishuSidecarError(result: JsonObject, status: String): String {
    let raw = feishuSidecarFirstString(result, ["error", "reason", "message", "detail"])
    let redacted = feishuSidecarRedactSensitiveText(raw)
    if (!redacted.isEmpty()) {
        return redacted
    }
    if (feishuSidecarOk(result)) {
        return ""
    }
    "Feishu sidecar ${if (status.trimAscii().isEmpty()) { "api_error" } else { status.trimAscii() }}"
}

private func feishuSidecarRedactSensitiveText(raw: String): String {
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return ""
    }
    let lower = text.toAsciiLower()
    if (lower.contains("authorization:") ||
        lower.contains("\"authorization\"") ||
        lower.contains("bearer ") ||
        lower.contains("access_token") ||
        lower.contains("refresh_token") ||
        lower.contains("tenant_secret") ||
        lower.contains("tenant secret") ||
        lower.contains("appsecret") ||
        lower.contains("app_secret") ||
        lower.contains("client_secret") ||
        lower.contains("secret") ||
        lower.contains("token=") ||
        lower.contains("password")) {
        return "[redacted]"
    }
    if (text.startsWith("{") || text.startsWith("[")) {
        return "Feishu sidecar returned structured error."
    }
    text
}

private func feishuSidecarShouldFallbackReply(status: String, error: String): Bool {
    let probe = "${status.trimAscii().toAsciiLower()} ${error.trimAscii().toAsciiLower()}"
    probe.contains("message_unavailable") ||
        probe.contains("not_found") ||
        probe.contains("not found") ||
        probe.contains("deleted") ||
        probe.contains("recalled") ||
        probe.contains("withdrawn")
}

private func feishuSidecarProcessFailure(status: String, error: String): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString(if (status.trimAscii().isEmpty()) { "api_error" } else { status.trimAscii() }))
    out.put("error", JsonString(feishuSidecarRedactSensitiveText(error)))
    out
}

private func feishuSidecarCompactJsonLine(raw: String): String {
    let out = StringBuilder()
    var inString = false
    var escaped = false
    for (ch in raw.toRuneArray()) {
        if (escaped) {
            out.append(ch)
            escaped = false
            continue
        }
        if (inString && ch == r'\\') {
            out.append(ch)
            escaped = true
            continue
        }
        if (ch == r'"') {
            out.append(ch)
            inString = !inString
            continue
        }
        if (!inString && (ch == r' ' || ch == r'\n' || ch == r'\r' || ch == r'\t')) {
            continue
        }
        out.append(ch)
    }
    out.toString()
}

private func feishuSidecarBase64Value(ch: Byte): Int64 {
    if (ch >= UInt8(65) && ch <= UInt8(90)) {
        return Int64(ch - UInt8(65))
    }
    if (ch >= UInt8(97) && ch <= UInt8(122)) {
        return Int64(ch - UInt8(97)) + 26
    }
    if (ch >= UInt8(48) && ch <= UInt8(57)) {
        return Int64(ch - UInt8(48)) + 52
    }
    if (ch == UInt8(43)) {
        return 62
    }
    if (ch == UInt8(47)) {
        return 63
    }
    -1
}

private func feishuSidecarDecodeBase64(data: String): Array<Byte> {
    let out = ArrayList<Byte>()
    var buffer: Int64 = 0
    var bits: Int64 = 0
    for (ch in data.toArray()) {
        if (ch == UInt8(61)) {
            break
        }
        let value = feishuSidecarBase64Value(ch)
        if (value < 0) {
            continue
        }
        buffer = (buffer << 6) | value
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.add(UInt8((buffer >> bits) & 255))
        }
    }
    out.toArray()
}
