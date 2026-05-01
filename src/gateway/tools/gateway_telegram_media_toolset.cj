package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.gatewayCurrentToolRuntimeContext
import metis.core.{renderGatewayAudioText, renderGatewayDocumentText, renderGatewayPhotoText, renderGatewayVideoNoteText, renderGatewayVideoText, renderGatewayVoiceText}
import metis.core.config.{CliConfig, MetisPaths}
import metis.io.PrintUtils

import std.collection.ArrayList
import std.fs.{Directory, File, Path, copy, exists}
import std.process.executeWithOutput
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private func telegramMediaToolString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func telegramMediaToolBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func telegramMediaToolInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_e: Exception) { 0 }
        case None => 0
    }
}

private func telegramMediaToolRecords(): JsonArray {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) =>
            match (ctx.mediaContext.get("records")) {
                case Some(v) => try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
                case None => JsonArray([])
            }
        case None => JsonArray([])
    }
}

private func telegramMediaToolRecordMatches(
    obj: JsonObject,
    mediaId: String,
    messageId: String,
    relation: String
): Bool {
    if (!mediaId.isEmpty() && telegramMediaToolString(obj, "mediaId") != mediaId) {
        return false
    }
    if (!messageId.isEmpty() && telegramMediaToolString(obj, "messageId") != messageId) {
        return false
    }
    if (!relation.isEmpty() && telegramMediaToolString(obj, "relation").toAsciiLower() != relation.toAsciiLower()) {
        return false
    }
    true
}

private func telegramMediaToolRecordByTarget(
    mediaId: String,
    index: Int64,
    messageId!: String = "",
    relation!: String = ""
): Option<JsonObject> {
    let records = telegramMediaToolRecords()
    var i: Int64 = 0
    for (item in records.getItems()) {
        let obj = try { item.asObject() } catch (_e: Exception) { JsonObject() }
        if (telegramMediaToolRecordMatches(obj, mediaId, messageId, relation)) {
            if (!mediaId.isEmpty() || !messageId.isEmpty() || !relation.isEmpty()) {
                return Some(obj)
            }
            if (i == index) {
                return Some(obj)
            }
        }
        i += 1
    }
    None<JsonObject>
}

private func telegramMediaError(action: String, message: String): String {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString("error"))
    out.put("action", JsonString(action))
    out.put("error", JsonString(message))
    out.toJsonString()
}

private func telegramMediaToolReadableMime(mimeType: String, fileName: String): Bool {
    let mime = mimeType.trimAscii().toAsciiLower()
    let name = fileName.trimAscii().toAsciiLower()
    if (mime.startsWith("text/") || mime == "application/json" || mime == "application/xml") {
        return true
    }
    name.endsWith(".txt") || name.endsWith(".md") || name.endsWith(".json") || name.endsWith(".xml") ||
        name.endsWith(".csv") || name.endsWith(".cj") || name.endsWith(".ts") || name.endsWith(".js") ||
        name.endsWith(".py") || name.endsWith(".log")
}

private func telegramMediaToolSafePreview(text: String, maxChars: Int64): (String, Bool) {
    let limit = if (maxChars <= 0) { 8192 } else { maxChars }
    if (text.size <= limit) {
        return (text, false)
    }
    (text[0..limit], true)
}

private func telegramMediaToolFileExtension(name: String): String {
    let trimmed = name.trimAscii()
    var dot: Int64 = -1
    for (i in 0..trimmed.size) {
        if (trimmed[i] == UInt8(46)) {
            dot = i
        }
    }
    if (dot >= 0 && dot < trimmed.size - 1) {
        return trimmed[dot..]
    }
    ""
}

private func telegramMediaToolExtensionFromMime(mimeType: String): String {
    let mime = mimeType.trimAscii().toAsciiLower()
    if (mime == "image/jpeg") { return ".jpg" }
    if (mime == "image/png") { return ".png" }
    if (mime == "image/gif") { return ".gif" }
    if (mime == "image/webp") { return ".webp" }
    if (mime == "audio/ogg") { return ".ogg" }
    if (mime == "audio/mpeg") { return ".mp3" }
    if (mime == "audio/mp4") { return ".m4a" }
    if (mime == "video/mp4") { return ".mp4" }
    if (mime == "application/pdf") { return ".pdf" }
    if (mime == "application/json") { return ".json" }
    if (mime.startsWith("text/")) { return ".txt" }
    ""
}

private func telegramMediaToolDestinationLooksProtected(raw: String): Bool {
    let value = raw.trimAscii()
    let low = value.toAsciiLower()
    value.isEmpty() ||
        value.contains("\u{0}") ||
        low.contains("/.metis/") ||
        low.endsWith("/metis.json") ||
        low == "metis.json" ||
        low.startsWith("/etc/") ||
        low.startsWith("/private/etc/") ||
        low.startsWith("/system/") ||
        low.startsWith("/bin/") ||
        low.startsWith("/sbin/") ||
        low.startsWith("/usr/bin/") ||
        low.startsWith("/var/db/")
}

private func telegramMediaToolResolveDestination(destination: String, record: JsonObject): (Bool, Path, String) {
    let raw = destination.trimAscii()
    if (telegramMediaToolDestinationLooksProtected(raw)) {
        return (false, Path(raw), "destination path is protected or empty")
    }
    var dest = Path(raw)
    if (!dest.isAbsolute()) {
        dest = CliConfig.cwd.join(raw)
    }
    let originalName = telegramMediaToolString(record, "originalFileName")
    let fileName = if (originalName.isEmpty()) { telegramMediaToolString(record, "fileName") } else { originalName }
    let inferredExt = if (!telegramMediaToolFileExtension(dest.toString()).isEmpty()) {
        ""
    } else {
        let fromName = telegramMediaToolFileExtension(fileName)
        if (!fromName.isEmpty()) { fromName } else { telegramMediaToolExtensionFromMime(telegramMediaToolString(record, "mimeType")) }
    }
    if (!inferredExt.isEmpty()) {
        dest = Path(dest.toString() + inferredExt)
    }
    (true, dest, "")
}

private func telegramMediaToolAudioTranscript(record: JsonObject): String {
    let sourcePath = telegramMediaToolString(record, "localPath")
    if (sourcePath.isEmpty()) {
        return ""
    }
    for (suffix in [".transcript.txt", ".txt", ".transcript"]) {
        let path = Path(sourcePath + suffix)
        if (exists(path)) {
            return try { String.fromUtf8(File.readFrom(path)).trimAscii() } catch (_e: Exception) { "" }
        }
    }
    ""
}

private func telegramMediaToolImageAnalysis(record: JsonObject): String {
    let sourcePath = telegramMediaToolString(record, "localPath")
    if (sourcePath.isEmpty()) {
        return ""
    }
    for (suffix in [".analysis.txt", ".vision.txt", ".description.txt"]) {
        let path = Path(sourcePath + suffix)
        if (exists(path)) {
            return try { String.fromUtf8(File.readFrom(path)).trimAscii() } catch (_e: Exception) { "" }
        }
    }
    ""
}

private func telegramMediaToolGatewayBinaryCommand(): (String, Option<Path>) {
    match (MetisPaths.projectRoot()) {
        case Some(root) =>
            let devBinary = root.join("target").join("release").join("bin").join("metis")
            if (exists(devBinary)) {
                return (devBinary.toString(), Some(root))
            }
            return ("metis", Some(root))
        case None => ("metis", None<Path>)
    }
}

private func telegramMediaToolInvokeGatewayCall(method: String, params!: Option<JsonObject> = None<JsonObject>): JsonObject {
    let (command, workDir) = telegramMediaToolGatewayBinaryCommand()
    let args = match (params) {
        case Some(obj) => ["gateway", "call", method, obj.toJsonString()]
        case None => ["gateway", "call", method]
    }
    let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput(command, args, workingDirectory: workDir)
    let stdout = try { String.fromUtf8(stdoutBytes).trimAscii() } catch (_: Exception) { "" }
    let stderr = try { String.fromUtf8(stderrBytes).trimAscii() } catch (_: Exception) { "" }
    if (!stdout.isEmpty()) {
        try {
            let obj = JsonValue.fromStr(stdout).asObject()
            obj.put("exitCode", exitCode.toJsonValue())
            if (!stderr.isEmpty()) {
                obj.put("stderr", JsonString(stderr))
            }
            return obj
        } catch (_: Exception) {
            ()
        }
    }
    let out = JsonObject()
    out.put("ok", JsonBool(exitCode == 0))
    out.put("exitCode", exitCode.toJsonValue())
    out.put("stdout", JsonString(stdout))
    out.put("stderr", JsonString(stderr))
    out
}

private func telegramMediaToolCurrentTarget(): (String, String, String) {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) =>
            let channel = if (ctx.channelName.isEmpty()) { ctx.sourceLabel } else { ctx.channelName }
            let sessionKey = ctx.sessionKey.trimAscii()
            if (channel == "telegram" && sessionKey.startsWith("telegram:direct:")) {
                return ("telegram", sessionKey["telegram:direct:".size..], ctx.sessionKey)
            }
            if (channel == "telegram" && sessionKey.startsWith("telegram:group:")) {
                return ("telegram", sessionKey["telegram:group:".size..], ctx.sessionKey)
            }
            return (channel, "", sessionKey)
        case None => ("", "", "")
    }
}

private func telegramMediaToolBuildMediaText(kind: String, media: String, caption: String): String {
    let normalized = kind.trimAscii().toAsciiLower()
    if (normalized == "photo" || normalized == "image") {
        return renderGatewayPhotoText(media, caption: caption)
    }
    if (normalized == "audio") {
        return renderGatewayAudioText(media, caption: caption)
    }
    if (normalized == "voice") {
        return renderGatewayVoiceText(media, caption: caption)
    }
    if (normalized == "video") {
        return renderGatewayVideoText(media, caption: caption)
    }
    if (normalized == "video-note" || normalized == "video_note" || normalized == "videonote") {
        return renderGatewayVideoNoteText(media)
    }
    renderGatewayDocumentText(media, caption: caption)
}

@toolset
public class GatewayTelegramMediaToolset {
    public func debugTelegramMediaListForTest(): String {
        this.renderTelegramMediaList()
    }

    public func debugTelegramMediaSaveForTest(destination: String, mediaId: Option<String>, index: Option<Int64>): String {
        this.saveTelegramMedia(destination, mediaId, index)
    }

    public func debugTelegramMediaGetForTest(mediaId: Option<String>, index: Option<Int64>, messageId: Option<String>, relation: Option<String>): String {
        this.getTelegramMedia(mediaId, index, messageId, relation)
    }

    public func debugTelegramMediaReadForTest(mediaId: Option<String>, index: Option<Int64>, maxBytes: Option<Int64>): String {
        this.readTelegramMedia(mediaId, index, maxBytes)
    }

    public func debugTelegramImageAnalyzeForTest(mediaId: Option<String>, index: Option<Int64>, prompt: Option<String>): String {
        this.analyzeTelegramImage(mediaId, index, prompt)
    }

    public func debugTelegramAudioTranscribeForTest(mediaId: Option<String>, index: Option<Int64>): String {
        this.transcribeTelegramAudio(mediaId, index)
    }

    public func debugTelegramTargetListFromAuditForTest(auditEnvelope: JsonObject): String {
        this.renderTelegramTargetListFromAudit(auditEnvelope)
    }

    public func debugTelegramDoctorFromEnvelopeForTest(doctorEnvelope: JsonObject): String {
        this.renderTelegramDoctorFromEnvelope(doctorEnvelope)
    }

    private func renderTelegramMediaList(): String {
        let records = telegramMediaToolRecords()
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("ok"))
        out.put("count", records.size().toJsonValue())
        out.put("records", records)
        out.toJsonString()
    }

    private func getTelegramMedia(mediaId: Option<String>, index: Option<Int64>, messageId: Option<String>, relation: Option<String>): String {
        let targetMediaId = match (mediaId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetIndex = match (index) {
            case Some(v) => v
            case None => 0
        }
        let targetMessageId = match (messageId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetRelation = match (relation) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let out = JsonObject()
        match (telegramMediaToolRecordByTarget(targetMediaId, targetIndex, messageId: targetMessageId, relation: targetRelation)) {
            case Some(record) =>
                out.put("ok", JsonBool(true))
                out.put("status", JsonString("ok"))
                out.put("media", record)
            case None =>
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("media resource not found in current session turn"))
                if (!targetMediaId.isEmpty()) { out.put("mediaId", JsonString(targetMediaId)) }
                if (!targetMessageId.isEmpty()) { out.put("messageId", JsonString(targetMessageId)) }
                if (!targetRelation.isEmpty()) { out.put("relation", JsonString(targetRelation)) }
        }
        out.toJsonString()
    }

    private func saveTelegramMedia(destination: String, mediaId: Option<String>, index: Option<Int64>): String {
        let targetPathText = destination.trimAscii()
        let targetMediaId = match (mediaId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetIndex = match (index) {
            case Some(v) => v
            case None => 0
        }
        let out = JsonObject()
        if (targetPathText.isEmpty()) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("error"))
            out.put("error", JsonString("destination is required"))
            return out.toJsonString()
        }
        let record = match (telegramMediaToolRecordByTarget(targetMediaId, targetIndex)) {
            case Some(v) => v
            case None =>
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("media resource not found in current session turn"))
                return out.toJsonString()
        }
        let sourcePath = telegramMediaToolString(record, "localPath")
        if (sourcePath.isEmpty() || !telegramMediaToolBool(record, "downloaded") || !exists(Path(sourcePath))) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("error"))
            out.put("error", JsonString("media resource has no downloaded localPath"))
            out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
            return out.toJsonString()
        }
        let (allowed, dest, reason) = telegramMediaToolResolveDestination(targetPathText, record)
        if (!allowed) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("denied"))
            out.put("error", JsonString(reason))
            out.put("destination", JsonString(targetPathText))
            return out.toJsonString()
        }
        let parent = dest.parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        copy(Path(sourcePath), to: dest, overwrite: true)
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("saved"))
        out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
        out.put("mediaKind", JsonString(telegramMediaToolString(record, "mediaKind")))
        out.put("sourcePath", JsonString(sourcePath))
        out.put("destination", JsonString(dest.toString()))
        out.put("savedAtMs", DateTime.now().toUnixTimeStamp().toMilliseconds().toJsonValue())
        out.toJsonString()
    }

    private func readTelegramMedia(mediaId: Option<String>, index: Option<Int64>, maxBytes: Option<Int64>): String {
        let targetMediaId = match (mediaId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetIndex = match (index) {
            case Some(v) => v
            case None => 0
        }
        let limit = match (maxBytes) {
            case Some(v) => if (v <= 0) { 8192 } else { v }
            case None => 8192
        }
        let out = JsonObject()
        let record = match (telegramMediaToolRecordByTarget(targetMediaId, targetIndex)) {
            case Some(v) => v
            case None =>
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("media resource not found in current session turn"))
                return out.toJsonString()
        }
        let sourcePath = telegramMediaToolString(record, "localPath")
        let fileName = if (!telegramMediaToolString(record, "fileName").isEmpty()) {
            telegramMediaToolString(record, "fileName")
        } else {
            telegramMediaToolString(record, "originalFileName")
        }
        let mimeType = telegramMediaToolString(record, "mimeType")
        out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
        out.put("mediaKind", JsonString(telegramMediaToolString(record, "mediaKind")))
        out.put("mimeType", JsonString(mimeType))
        out.put("fileName", JsonString(fileName))
        if (sourcePath.isEmpty() || !exists(Path(sourcePath))) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("error"))
            out.put("readable", JsonBool(false))
            out.put("error", JsonString("media resource has no downloaded localPath"))
            return out.toJsonString()
        }
        if (!telegramMediaToolReadableMime(mimeType, fileName)) {
            out.put("ok", JsonBool(true))
            out.put("status", JsonString("ok"))
            out.put("readable", JsonBool(false))
            out.put("reason", JsonString("media is not a text-readable file"))
            return out.toJsonString()
        }
        let text = try { String.fromUtf8(File.readFrom(Path(sourcePath))) } catch (_e: Exception) { "" }
        let (preview, truncated) = telegramMediaToolSafePreview(text, limit)
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("ok"))
        out.put("readable", JsonBool(true))
        out.put("content", JsonString(preview))
        out.put("truncated", JsonBool(truncated))
        out.put("maxBytes", limit.toJsonValue())
        out.toJsonString()
    }

    private func analyzeTelegramImage(mediaId: Option<String>, index: Option<Int64>, prompt: Option<String>): String {
        let targetMediaId = match (mediaId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetIndex = match (index) {
            case Some(v) => v
            case None => 0
        }
        let out = JsonObject()
        let record = match (telegramMediaToolRecordByTarget(targetMediaId, targetIndex)) {
            case Some(v) => v
            case None =>
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("media resource not found in current session turn"))
                return out.toJsonString()
        }
        let kind = telegramMediaToolString(record, "mediaKind").toAsciiLower()
        let mime = telegramMediaToolString(record, "mimeType").toAsciiLower()
        if (!(kind == "photo" || kind == "image" || kind == "sticker" || mime.startsWith("image/"))) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("unsupported"))
            out.put("error", JsonString("selected media is not image-like"))
            return out.toJsonString()
        }
        let analysis = telegramMediaToolImageAnalysis(record)
        out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
        match (prompt) {
            case Some(v) =>
                let p = v.trimAscii()
                if (!p.isEmpty()) { out.put("prompt", JsonString(p)) }
            case None => ()
        }
        if (analysis.isEmpty()) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("unsupported"))
            out.put("error", JsonString("vision adapter is not configured for this Telegram media resource"))
            out.put("fallback", JsonString("Use localPath from telegram_media_get with a model/runtime that supports vision."))
        } else {
            out.put("ok", JsonBool(true))
            out.put("status", JsonString("ok"))
            out.put("analysis", JsonString(analysis))
        }
        out.toJsonString()
    }

    private func transcribeTelegramAudio(mediaId: Option<String>, index: Option<Int64>): String {
        let targetMediaId = match (mediaId) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let targetIndex = match (index) {
            case Some(v) => v
            case None => 0
        }
        let out = JsonObject()
        let record = match (telegramMediaToolRecordByTarget(targetMediaId, targetIndex)) {
            case Some(v) => v
            case None =>
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("error"))
                out.put("error", JsonString("media resource not found in current session turn"))
                return out.toJsonString()
        }
        let kind = telegramMediaToolString(record, "mediaKind").toAsciiLower()
        let mime = telegramMediaToolString(record, "mimeType").toAsciiLower()
        if (!(kind == "voice" || kind == "audio" || mime.startsWith("audio/"))) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("unsupported"))
            out.put("error", JsonString("selected media is not audio-like"))
            return out.toJsonString()
        }
        let transcript = telegramMediaToolAudioTranscript(record)
        out.put("mediaId", JsonString(telegramMediaToolString(record, "mediaId")))
        if (transcript.isEmpty()) {
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("unsupported"))
            out.put("ASRStatus", JsonString("not_configured"))
            out.put("error", JsonString("ASR adapter is not configured and no transcript sidecar exists"))
        } else {
            out.put("ok", JsonBool(true))
            out.put("status", JsonString("ok"))
            out.put("transcript", JsonString(transcript))
        }
        out.toJsonString()
    }

    private func sendTelegramMedia(pathOrUrl: String, caption: Option<String>, kind: Option<String>, forceDocument: Option<Bool>): String {
        let media = pathOrUrl.trimAscii()
        if (media.isEmpty()) {
            return telegramMediaError("telegram_media_send", "pathOrUrl is required")
        }
        let (channel, target, sessionKey) = telegramMediaToolCurrentTarget()
        if (channel != "telegram" || target.isEmpty()) {
            return telegramMediaError("telegram_media_send", "telegram_media_send requires a current Telegram session delivery target")
        }
        let cap = match (caption) {
            case Some(v) => v.trimAscii()
            case None => ""
        }
        let requestedKind = match (kind) {
            case Some(v) => v.trimAscii().toAsciiLower()
            case None => "document"
        }
        let actualKind = match (forceDocument) {
            case Some(v) => if (v) { "document" } else { requestedKind }
            case None => requestedKind
        }
        let payload = JsonObject()
        payload.put("id", JsonString("telegram"))
        payload.put("channel", JsonString("telegram"))
        payload.put("peerId", JsonString(target))
        payload.put("to", JsonString(target))
        payload.put("text", JsonString(telegramMediaToolBuildMediaText(actualKind, media, cap)))
        payload.put("message", payload.get("text").getOrThrow())
        let sent = telegramMediaToolInvokeGatewayCall("channels.send", params: Some(payload))
        let result = JsonObject()
        result.put("ok", sent.get("ok") ?? JsonBool(false))
        result.put("status", JsonString(if (try { (sent.get("ok").getOrThrow().asBool().getValue()) } catch (_e: Exception) { false }) { "accepted" } else { "error" }))
        result.put("action", JsonString("telegram_media_send"))
        result.put("channel", JsonString("telegram"))
        result.put("to", JsonString(target))
        result.put("sessionKey", JsonString(sessionKey))
        result.put("kind", JsonString(actualKind))
        result.put("media", JsonString(media))
        result.put("gateway", sent)
        result.toJsonString()
    }

    private func renderTelegramTargetListFromAudit(auditEnvelope: JsonObject): String {
        let rows = try {
            auditEnvelope.get("audit").getOrThrow().asObject().get("telegram").getOrThrow().asObject()
                .get("directory").getOrThrow().asObject().get("rows").getOrThrow().asArray()
        } catch (_e: Exception) {
            try {
                auditEnvelope.get("telegram").getOrThrow().asObject().get("directory").getOrThrow().asObject()
                    .get("rows").getOrThrow().asArray()
            } catch (_e2: Exception) {
                JsonArray([])
            }
        }
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("ok"))
        out.put("count", rows.size().toJsonValue())
        out.put("targets", rows)
        out.toJsonString()
    }

    private func renderTelegramTargetResolveFromAudit(target: String, auditEnvelope: JsonObject): String {
        let normalizedTarget = target.trimAscii()
        let list = JsonValue.fromStr(this.renderTelegramTargetListFromAudit(auditEnvelope)).asObject()
        let rows = try { list.get("targets").getOrThrow().asArray() } catch (_e: Exception) { JsonArray([]) }
        let out = JsonObject()
        for (item in rows.getItems()) {
            let row = try { item.asObject() } catch (_e: Exception) { JsonObject() }
            if (telegramMediaToolString(row, "id") == normalizedTarget ||
                telegramMediaToolString(row, "displayName") == normalizedTarget ||
                telegramMediaToolString(row, "sessionKey") == normalizedTarget) {
                out.put("ok", JsonBool(true))
                out.put("status", JsonString("ok"))
                out.put("target", row)
                return out.toJsonString()
            }
        }
        out.put("ok", JsonBool(false))
        out.put("status", JsonString("error"))
        out.put("target", JsonString(normalizedTarget))
        out.put("error", JsonString("Unknown or unauthorized Telegram target"))
        out.toJsonString()
    }

    private func renderTelegramDoctorFromEnvelope(doctorEnvelope: JsonObject): String {
        let telegram = try {
            doctorEnvelope.get("doctor").getOrThrow().asObject().get("telegramDiagnostics").getOrThrow().asObject()
        } catch (_e: Exception) {
            try { doctorEnvelope.get("telegramDiagnostics").getOrThrow().asObject() } catch (_e2: Exception) { JsonObject() }
        }
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("ok"))
        out.put("telegramDiagnostics", telegram)
        let summary = telegram.get("summary") ?? JsonObject()
        out.put("summary", summary)
        out.toJsonString()
    }

    @tool[
        description: "List structured Telegram media resources attached to the current Gateway session turn. Use this before saving or inspecting an image, file, voice, audio, or reply target media sent by the user.",
        parameters: {}
    ]
    public func telegram_media_list(): String {
        PrintUtils.printTool("telegram_media_list", shortMessage: "current")
        let text = this.renderTelegramMediaList()
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Save one Telegram media resource from the current Gateway session turn to a destination path. Select by mediaId or zero-based index; defaults to index 0.",
        parameters: {
            destination: "Absolute or relative destination file path to write.",
            mediaId: "Optional mediaId returned by telegram_media_list.",
            index: "Optional zero-based media index. Defaults to 0 when mediaId is omitted."
        }
    ]
    public func telegram_media_save(destination: String, mediaId: Option<String>, index: Option<Int64>): String {
        PrintUtils.printTool("telegram_media_save", shortMessage: "current")
        let text = this.saveTelegramMedia(destination, mediaId, index)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Get one structured Telegram media resource from the current Gateway session turn. Select by mediaId, messageId, relation, or zero-based index.",
        parameters: {
            mediaId: "Optional mediaId returned by telegram_media_list.",
            index: "Optional zero-based media index. Defaults to 0 when other selectors are omitted.",
            messageId: "Optional Telegram source message id.",
            relation: "Optional media relation, such as current or replyTarget."
        }
    ]
    public func telegram_media_get(mediaId: Option<String>, index: Option<Int64>, messageId: Option<String>, relation: Option<String>): String {
        PrintUtils.printTool("telegram_media_get", shortMessage: "current")
        let text = this.getTelegramMedia(mediaId, index, messageId, relation)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Read a text-like Telegram media file from the current Gateway session turn. Binary files return a readable=false result with a clear reason.",
        parameters: {
            mediaId: "Optional mediaId returned by telegram_media_list.",
            index: "Optional zero-based media index. Defaults to 0 when mediaId is omitted.",
            maxBytes: "Optional maximum preview bytes/chars. Defaults to 8192."
        }
    ]
    public func telegram_media_read(mediaId: Option<String>, index: Option<Int64>, maxBytes: Option<Int64>): String {
        PrintUtils.printTool("telegram_media_read", shortMessage: "current")
        let text = this.readTelegramMedia(mediaId, index, maxBytes)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Analyze an image-like Telegram media resource from the current turn. Uses configured/mock vision sidecar when available; otherwise returns unsupported instead of guessing.",
        parameters: {
            mediaId: "Optional mediaId returned by telegram_media_list.",
            index: "Optional zero-based media index.",
            prompt: "Optional analysis prompt."
        }
    ]
    public func telegram_image_analyze(mediaId: Option<String>, index: Option<Int64>, prompt: Option<String>): String {
        PrintUtils.printTool("telegram_image_analyze", shortMessage: "current")
        let text = this.analyzeTelegramImage(mediaId, index, prompt)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Transcribe a voice/audio Telegram media resource from the current turn. Reads transcript sidecar when present; otherwise returns ASRStatus=not_configured.",
        parameters: {
            mediaId: "Optional mediaId returned by telegram_media_list.",
            index: "Optional zero-based media index."
        }
    ]
    public func telegram_audio_transcribe(mediaId: Option<String>, index: Option<Int64>): String {
        PrintUtils.printTool("telegram_audio_transcribe", shortMessage: "current")
        let text = this.transcribeTelegramAudio(mediaId, index)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Send a local file, Telegram file_id, or controlled URL as Telegram media to the current Telegram session through Gateway channels.send.",
        parameters: {
            pathOrUrl: "Local path, Telegram file_id, or controlled URL to send.",
            caption: "Optional caption.",
            kind: "Optional media kind: photo, document, audio, voice, video, or video-note.",
            forceDocument: "Optional. When true, send as document."
        }
    ]
    public func telegram_media_send(pathOrUrl: String, caption: Option<String>, kind: Option<String>, forceDocument: Option<Bool>): String {
        PrintUtils.printTool("telegram_media_send", shortMessage: "current")
        let text = this.sendTelegramMedia(pathOrUrl, caption, kind, forceDocument)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "List known Telegram targets from Gateway channels.audit. This is read-only and does not expand permissions.",
        parameters: {}
    ]
    public func telegram_target_list(): String {
        PrintUtils.printTool("telegram_target_list", shortMessage: "audit")
        let params = JsonObject()
        params.put("channelId", JsonString("telegram"))
        let audit = telegramMediaToolInvokeGatewayCall("channels.audit", params: Some(params))
        let text = this.renderTelegramTargetListFromAudit(audit)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Resolve one known Telegram target from Gateway channels.audit. Unknown or unauthorized targets are rejected.",
        parameters: {
            target: "Target id, display name, or session key from telegram_target_list."
        }
    ]
    public func telegram_target_resolve(target: String): String {
        PrintUtils.printTool("telegram_target_resolve", shortMessage: target)
        let params = JsonObject()
        params.put("channelId", JsonString("telegram"))
        let audit = telegramMediaToolInvokeGatewayCall("channels.audit", params: Some(params))
        let text = this.renderTelegramTargetResolveFromAudit(target, audit)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Send a text message to a known Telegram target through Gateway channels.send. This does not write back target configuration.",
        parameters: {
            target: "Target id from telegram_target_list.",
            message: "Message text to send."
        }
    ]
    public func telegram_send_to_target(target: String, message: String): String {
        PrintUtils.printTool("telegram_send_to_target", shortMessage: target)
        let targetText = target.trimAscii()
        let msg = message.trimAscii()
        if (targetText.isEmpty() || msg.isEmpty()) {
            let err = telegramMediaError("telegram_send_to_target", "target and message are required")
            PrintUtils.printToolResult(err)
            return err
        }
        let payload = JsonObject()
        payload.put("id", JsonString("telegram"))
        payload.put("channel", JsonString("telegram"))
        payload.put("peerId", JsonString(targetText))
        payload.put("to", JsonString(targetText))
        payload.put("text", JsonString(msg))
        payload.put("message", JsonString(msg))
        let sent = telegramMediaToolInvokeGatewayCall("channels.send", params: Some(payload))
        let out = JsonObject()
        out.put("ok", sent.get("ok") ?? JsonBool(false))
        out.put("status", JsonString(if (try { sent.get("ok").getOrThrow().asBool().getValue() } catch (_e: Exception) { false }) { "accepted" } else { "error" }))
        out.put("action", JsonString("telegram_send_to_target"))
        out.put("target", JsonString(targetText))
        out.put("gateway", sent)
        let text = out.toJsonString()
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Read Telegram-specific Gateway doctor diagnostics. This is read-only and never changes metis.json.",
        parameters: {
            liveProbe: "Optional. When true, request Gateway doctor/runtime live probe where supported."
        }
    ]
    public func telegram_doctor(liveProbe: Option<Bool>): String {
        PrintUtils.printTool("telegram_doctor", shortMessage: "read-only")
        let doctor = telegramMediaToolInvokeGatewayCall("doctor")
        let text = this.renderTelegramDoctorFromEnvelope(doctor)
        PrintUtils.printToolResult(text)
        return text
    }

    @tool[
        description: "Explain effective Telegram configuration through Gateway channels.audit without exposing token or proxy credentials.",
        parameters: {}
    ]
    public func telegram_config_explain(): String {
        PrintUtils.printTool("telegram_config_explain", shortMessage: "audit")
        let params = JsonObject()
        params.put("channelId", JsonString("telegram"))
        let audit = telegramMediaToolInvokeGatewayCall("channels.audit", params: Some(params))
        PrintUtils.printToolResult(audit.toJsonString())
        return audit.toJsonString()
    }

    @tool[
        description: "Audit Telegram targets, allowlist, pairing, and directory state through Gateway channels.audit. Read-only.",
        parameters: {}
    ]
    public func telegram_audit_targets(): String {
        PrintUtils.printTool("telegram_audit_targets", shortMessage: "audit")
        let params = JsonObject()
        params.put("channelId", JsonString("telegram"))
        let audit = telegramMediaToolInvokeGatewayCall("channels.audit", params: Some(params))
        let text = this.renderTelegramTargetListFromAudit(audit)
        PrintUtils.printToolResult(text)
        return text
    }
}
