package metis.gateway.core

import metis.core.{GatewayToolRuntimeContext, MediaDiagnosticEvent, emitGatewayMediaDiagnostic, gatewayMediaUnderstandingFirstText, gatewayMediaUnderstandingForRecordWithSettings}
import metis.core.config.{CliSettingManager, GatewayUserSettings}
import metis.gateway.session.{GatewaySessionContext, GatewaySessionRequest, GatewayTurnContext}
import std.collection.ArrayList
import std.convert.Parsable
import std.fs.{Path, exists}
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private func gatewayJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func gatewayJsonBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func gatewaySessionTurnInvokeDeliverHook(
    send: (String, String, String, String, Option<String>, Bool) -> String,
    method: String,
    params: JsonObject
): JsonObject {
    let out = JsonObject()
    if (method.trimAscii() != "channels.send") {
        out.put("ok", JsonBool(false))
        out.put("status", JsonString("error"))
        out.put("code", JsonString("unsupported_method"))
        out.put("method", JsonString(method.trimAscii()))
        return out
    }
    let channel = if (!gatewayJsonString(params, "channel").isEmpty()) {
        gatewayJsonString(params, "channel")
    } else {
        gatewayJsonString(params, "id")
    }
    let peerId = if (!gatewayJsonString(params, "peerId").isEmpty()) {
        gatewayJsonString(params, "peerId")
    } else {
        gatewayJsonString(params, "to")
    }
    let text = if (!gatewayJsonString(params, "text").isEmpty()) {
        gatewayJsonString(params, "text")
    } else {
        gatewayJsonString(params, "message")
    }
    if (channel.isEmpty() || peerId.isEmpty() || text.isEmpty()) {
        out.put("ok", JsonBool(false))
        out.put("status", JsonString("error"))
        out.put("code", JsonString("invalid_request"))
        return out
    }
    let replyTo = if (!gatewayJsonString(params, "replyToMessageId").isEmpty()) {
        gatewayJsonString(params, "replyToMessageId")
    } else {
        gatewayJsonString(params, "replyTo")
    }
    let replyToOption = if (replyTo.isEmpty()) { None<String> } else { Some(replyTo) }
    try {
        let messageId = send(
            channel,
            gatewayJsonString(params, "accountId"),
            peerId,
            text,
            replyToOption,
            gatewayJsonBool(params, "replyInThread")
        )
        out.put("ok", JsonBool(true))
        out.put("status", JsonString("accepted"))
        out.put("messageId", JsonString(messageId))
    } catch (e: Exception) {
        out.put("ok", JsonBool(false))
        out.put("status", JsonString("error"))
        out.put("error", JsonString(e.message))
    }
    out
}

private func gatewaySessionTurnGatewayCallHookFromDeliverHook(
    deliverHook: Option<(String, String, String, String, Option<String>, Bool) -> String>
): Option<(String, JsonObject) -> JsonObject> {
    match (deliverHook) {
        case Some(send) => Some({ method: String, params: JsonObject =>
            gatewaySessionTurnInvokeDeliverHook(send, method, params)
        })
        case None => None<(String, JsonObject) -> JsonObject>
    }
}

private func gatewayMemorySearchPolicyFromScope(scope: JsonObject): JsonObject {
    match (scope.get("memorySearchPolicy")) {
        case Some(policyValue) =>
            try {
                let policy = policyValue.asObject()
                match (policy.get("raw")) {
                    case Some(rawValue) => return rawValue.asObject()
                    case None => ()
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    match (scope.get("raw")) {
        case Some(rawValue) =>
            try {
                let raw = rawValue.asObject()
                match (raw.get("memorySearch")) {
                    case Some(memorySearchValue) => return memorySearchValue.asObject()
                    case None => ()
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    JsonObject()
}

private func gatewayJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                v.asInt().getValue()
            } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func gatewayMediaRecords(mediaContext: JsonObject): JsonArray {
    match (mediaContext.get("records")) {
        case Some(v) => try { v.asArray() } catch (_e: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func gatewayMediaReadableTextMime(mime: String, fileName: String): Bool {
    let normalizedMime = mime.trimAscii().toAsciiLower()
    let normalizedName = fileName.trimAscii().toAsciiLower()
    if (normalizedMime.startsWith("text/") || normalizedMime == "application/json" || normalizedMime == "application/xml") {
        return true
    }
    normalizedName.endsWith(".txt") ||
        normalizedName.endsWith(".md") ||
        normalizedName.endsWith(".json") ||
        normalizedName.endsWith(".xml") ||
        normalizedName.endsWith(".csv") ||
        normalizedName.endsWith(".cj") ||
        normalizedName.endsWith(".ts") ||
        normalizedName.endsWith(".js") ||
    normalizedName.endsWith(".py")
}

private func gatewayMediaPromptFirstString(record: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        let value = gatewayJsonString(record, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    ""
}

private func gatewayMediaPromptCapabilityForRecord(kind: String, mime: String): String {
    let normalizedKind = kind.trimAscii().toAsciiLower()
    let normalizedMime = mime.trimAscii().toAsciiLower()
    if (normalizedKind == "voice" || normalizedKind == "audio" || normalizedMime.startsWith("audio/")) {
        return "audio"
    }
    if (normalizedKind == "video" || normalizedKind == "video-note" || normalizedKind == "video_note" || normalizedMime.startsWith("video/")) {
        return "video"
    }
    if (normalizedKind == "photo" || normalizedKind == "image" || normalizedMime.startsWith("image/")) {
        return "image"
    }
    if (normalizedKind == "sticker") {
        return "sticker"
    }
    if (normalizedKind == "document" || !normalizedMime.isEmpty()) {
        return "document"
    }
    "unknown"
}

private func gatewayMediaPromptNormalizeStatus(raw: String): String {
    let normalized = raw.trimAscii().toAsciiLower()
    match (normalized) {
        case "analyzed" | "transcribed" => "ok"
        case "metadata-only" => "metadata_only"
        case _ => normalized
    }
}

private func gatewayMediaPromptTerminalStatus(status: String): Bool {
    let normalized = gatewayMediaPromptNormalizeStatus(status)
    normalized == "ok" ||
        normalized == "provider_error" ||
        normalized == "not_configured" ||
        normalized == "unsupported" ||
        normalized == "too_large" ||
        normalized == "timeout" ||
        normalized == "disabled" ||
        normalized == "not_found" ||
        normalized == "metadata_only" ||
        normalized == "runtime_unavailable" ||
        normalized == "extractor_error" ||
        normalized == "extractor_failed" ||
        normalized == "extractor_timeout" ||
        normalized == "extractor_invalid_output" ||
        normalized == "extractor_output_too_large" ||
        normalized == "unsupported_images"
}

private func gatewayMediaPromptRecordStatus(record: JsonObject, capability: String): String {
    let direct = gatewayMediaPromptNormalizeStatus(gatewayMediaPromptFirstString(record, ["mediaUnderstandingStatus", "understandingStatus"]))
    if (!direct.isEmpty() && direct != "downloaded") {
        return direct
    }
    match (capability) {
        case "audio" => return gatewayMediaPromptNormalizeStatus(gatewayMediaPromptFirstString(record, ["asrStatus", "ASRStatus"]))
        case "image" | "sticker" => return gatewayMediaPromptNormalizeStatus(gatewayMediaPromptFirstString(record, ["visionStatus"]))
        case "video" => return gatewayMediaPromptNormalizeStatus(gatewayMediaPromptFirstString(record, ["videoUnderstandingStatus"]))
        case "document" => return gatewayMediaPromptNormalizeStatus(gatewayMediaPromptFirstString(record, ["documentExtractStatus"]))
        case _ => ()
    }
    if (direct == "downloaded") {
        return ""
    }
    direct
}

private func gatewayMediaPromptCachedText(record: JsonObject, capability: String): String {
    match (capability) {
        case "audio" => return gatewayMediaPromptFirstString(record, ["transcript", "asrTranscript", "audioTranscript"])
        case "image" => return gatewayMediaPromptFirstString(record, ["analysis", "description", "imageDescription"])
        case "sticker" => return gatewayMediaPromptFirstString(record, ["stickerDescription", "analysis", "description"])
        case "video" => return gatewayMediaPromptFirstString(record, ["videoDescription", "description", "analysis"])
        case "document" => return gatewayMediaPromptFirstString(record, ["documentTextPreview", "documentPreview", "preview", "filePreview"])
        case _ => return gatewayMediaPromptFirstString(record, ["analysis", "description", "transcript", "documentTextPreview", "preview"])
    }
}

private func gatewayMediaPromptCachedOutputKind(capability: String): String {
    match (capability) {
        case "audio" => "audio.transcription"
        case "sticker" => "sticker.description"
        case "image" => "image.description"
        case "video" => "video.description"
        case "document" => "document.text"
        case _ => "media.description"
    }
}

private func gatewayMediaPromptCopyFields(source: JsonObject, target: JsonObject, keys: Array<String>): Unit {
    for (key in keys) {
        match (source.get(key)) {
            case Some(v) => target.put(key, v)
            case None => ()
        }
    }
}

private func gatewayMediaPromptCachedUnderstanding(record: JsonObject, kind: String, mime: String): JsonObject {
    let capability = gatewayMediaPromptFirstString(record, ["mediaUnderstandingCapability", "understandingCapability"])
    let resolvedCapability = if (capability.isEmpty()) { gatewayMediaPromptCapabilityForRecord(kind, mime) } else { capability.toAsciiLower() }
    let status = gatewayMediaPromptRecordStatus(record, resolvedCapability)
    let text = gatewayMediaPromptCachedText(record, resolvedCapability)
    if (status.isEmpty() && text.isEmpty()) {
        return JsonObject()
    }
    if (!status.isEmpty() && !gatewayMediaPromptTerminalStatus(status) && text.isEmpty()) {
        return JsonObject()
    }
    let out = JsonObject()
    let effectiveStatus = if (!text.isEmpty() && (status.isEmpty() || status == "analyzed" || status == "transcribed")) { "ok" } else { status }
    out.put("status", JsonString(if (effectiveStatus.isEmpty()) { "ok" } else { effectiveStatus }))
    out.put("capability", JsonString(resolvedCapability))
    if (!text.isEmpty()) {
        let item = JsonObject()
        item.put("kind", JsonString(gatewayMediaPromptCachedOutputKind(resolvedCapability)))
        item.put("text", JsonString(text))
        item.put("source", JsonString("media_record_cache"))
        out.put("outputs", JsonArray([item]))
        match (resolvedCapability) {
            case "audio" => out.put("transcript", JsonString(text))
            case "sticker" => out.put("stickerDescription", JsonString(text))
            case "image" => out.put("imageDescription", JsonString(text))
            case "video" => out.put("videoDescription", JsonString(text))
            case "document" => out.put("documentTextPreview", JsonString(text))
            case _ => out.put("analysis", JsonString(text))
        }
    }
    let error = gatewayMediaPromptFirstString(record, ["mediaUnderstandingError", "understandingError", "error"])
    if (!error.isEmpty()) {
        out.put("error", JsonString(error))
    }
    gatewayMediaPromptCopyFields(record, out, [
        "fileBytes",
        "limitBytes",
        "mediaFileBytes",
        "mediaLimitBytes",
        "mediaLimitSource",
        "mediaUnderstandingStage",
        "mediaUnderstandingFileBytes",
        "mediaUnderstandingLimitBytes",
        "provider",
        "model",
        "attempts"
    ])
    out
}

private func gatewayMediaPromptEffectiveMaxBytes(record: JsonObject): Int64 {
    for (key in ["mediaUnderstandingLimitBytes", "mediaLimitBytes", "mediaMaxBytes", "limitBytes", "maxBytes"]) {
        let value = gatewayJsonInt(record, key, -1)
        if (value > 0) {
            return value
        }
    }
    -1
}

private func gatewayMediaPromptUnderstandingForRecord(record: JsonObject, user: GatewayUserSettings, kind: String, mime: String, downloaded: Bool, localPath: String): JsonObject {
    let cached = gatewayMediaPromptCachedUnderstanding(record, kind, mime)
    if (cached.size() > 0) {
        return cached
    }
    if (!(downloaded && !localPath.isEmpty() && exists(Path(localPath)))) {
        return JsonObject()
    }
    let maxBytes = gatewayMediaPromptEffectiveMaxBytes(record)
    if (maxBytes > 0) {
        return gatewayMediaUnderstandingForRecordWithSettings(record, user, maxBytes: maxBytes)
    }
    gatewayMediaUnderstandingForRecordWithSettings(record, user)
}

private func gatewayMediaContextStructuredSummary(mediaContext: JsonObject): String {
    let ctx = match (mediaContext.get("context")) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
    if (ctx.size() == 0) {
        return ""
    }
    let lines = ArrayList<String>()
    match (ctx.get("replyTo")) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_e: Exception) { JsonObject() }
            lines.add("ReplyTo=${obj.toJsonString()}")
        case None => ()
    }
    match (ctx.get("forwarded")) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_e: Exception) { JsonObject() }
            lines.add("Forwarded=${obj.toJsonString()}")
        case None => ()
    }
    match (ctx.get("location")) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_e: Exception) { JsonObject() }
            lines.add("Location=${obj.toJsonString()}")
        case None => ()
    }
    match (ctx.get("venue")) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_e: Exception) { JsonObject() }
            lines.add("Venue=${obj.toJsonString()}")
        case None => ()
    }
    match (ctx.get("contact")) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_e: Exception) { JsonObject() }
            lines.add("Contact=${obj.toJsonString()}")
        case None => ()
    }
    match (ctx.get("telegramRoute")) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_e: Exception) { JsonObject() }
            lines.add("TelegramRoute=${obj.toJsonString()}")
        case None => ()
    }
    String.join(lines.toArray(), delimiter: "\n")
}

public func gatewayBuildMediaContextPrompt(mediaContext: JsonObject): String {
    gatewayBuildMediaContextPromptForUser(mediaContext, CliSettingManager.readGatewaySettings())
}

public func gatewayBuildMediaContextPromptForUser(mediaContext: JsonObject, user: GatewayUserSettings): String {
    let records = gatewayMediaRecords(mediaContext)
    let structuredSummary = gatewayMediaContextStructuredSummary(mediaContext)
    if (records.size() == 0 && structuredSummary.isEmpty()) {
        return ""
    }
    let lines = ArrayList<String>()
    let paths = ArrayList<String>()
    let types = ArrayList<String>()
    lines.add("## Current Message Media")
    lines.add("The current inbound message has structured media resources from the gateway. Use these local paths when the user asks to save, inspect, transcribe, or reason about the attached media. Do not parse media out of the visible chat text.")
    lines.add("For image/photo/sticker understanding requests, call telegram_image_analyze before answering. Do not claim that the image cannot be seen when downloaded=true and a MediaPath is present; if no vision model is configured, say that explicitly and keep the saved path available.")
    lines.add("For voice/audio requests, use AudioTranscript when present; otherwise call telegram_audio_transcribe before answering. If ASRStatus=not_configured, say that transcription is unavailable instead of guessing.")
    lines.add("For video/video-note understanding requests, use VideoDescription when present; otherwise call telegram_video_describe before answering. Do not claim that video understanding is unconfigured unless VideoUnderstandingStatus is not_configured.")
    if (!structuredSummary.isEmpty()) {
        lines.add("StructuredTelegramContext:")
        lines.add(structuredSummary)
    }
    for (item in records.getItems()) {
        let record = try { item.asObject() } catch (_e: Exception) { JsonObject() }
        let mediaId = gatewayJsonString(record, "mediaId")
        let kind = gatewayJsonString(record, "mediaKind")
        let mime = gatewayJsonString(record, "mimeType")
        let localPath = gatewayJsonString(record, "localPath")
        let fileName = gatewayJsonString(record, "originalFileName")
        let relation = gatewayJsonString(record, "relation")
        let downloaded = gatewayJsonBool(record, "downloaded")
        let skipped = gatewayJsonString(record, "skippedReason")
        let understanding = gatewayMediaPromptUnderstandingForRecord(record, user, kind, mime, downloaded, localPath)
        let understandingStatus = gatewayJsonString(understanding, "status")
        let understandingCapability = gatewayJsonString(understanding, "capability")
        if (!understandingStatus.isEmpty()) {
            record.put("mediaUnderstandingStatus", JsonString(understandingStatus))
        }
        if (!understandingCapability.isEmpty()) {
            record.put("mediaUnderstandingCapability", JsonString(understandingCapability))
        }
        let understandingError = gatewayJsonString(understanding, "error")
        if (!understandingError.isEmpty()) {
            record.put("mediaUnderstandingError", JsonString(understandingError))
        }
        gatewayMediaPromptCopyFields(understanding, record, [
            "fileBytes",
            "limitBytes",
            "mediaFileBytes",
            "mediaLimitBytes",
            "mediaLimitSource",
            "mediaUnderstandingStage",
            "mediaUnderstandingFileBytes",
            "mediaUnderstandingLimitBytes",
            "provider",
            "model",
            "attempts"
        ])
        let understandingText = gatewayMediaUnderstandingFirstText(understanding)
        let transcript = if (understandingCapability == "audio") { understandingText } else { "" }
        let imageDescription = if (understandingCapability == "image") { understandingText } else { "" }
        let stickerDescription = if (understandingCapability == "sticker") { understandingText } else { "" }
        let videoDescription = if (understandingCapability == "video") { understandingText } else { "" }
        let filePreview = if (understandingCapability == "document") { understandingText } else { "" }
        if (!localPath.isEmpty()) {
            paths.add(localPath)
        }
        if (!kind.isEmpty()) {
            types.add(kind)
        }
        let row = ArrayList<String>()
        if (!mediaId.isEmpty()) { row.add("mediaId=${mediaId}") }
        if (!kind.isEmpty()) { row.add("MediaType=${kind}") }
        if (!mime.isEmpty()) { row.add("mimeType=${mime}") }
        if (!fileName.isEmpty()) { row.add("fileName=${fileName}") }
        if (!relation.isEmpty()) { row.add("relation=${relation}") }
        if (!localPath.isEmpty()) { row.add("MediaPath=${localPath}") }
        row.add("downloaded=${downloaded}")
        if (!skipped.isEmpty()) { row.add("skippedReason=${skipped}") }
        if (!understandingStatus.isEmpty()) { row.add("MediaUnderstandingStatus=${understandingStatus}") }
        if (!understandingCapability.isEmpty()) { row.add("MediaUnderstandingCapability=${understandingCapability}") }
        if (!transcript.isEmpty()) {
            row.add("AudioTranscript=${transcript}")
        } else if ((kind == "voice" || kind == "audio") && downloaded) {
            row.add("ASRStatus=not_configured")
            row.add("ASRAction=use telegram_audio_transcribe")
        }
        if ((kind == "photo" || kind == "image" || kind == "sticker" || mime.startsWith("image/")) && downloaded) {
            row.add("visionInputReady=true")
            row.add("visionRuntimeAvailable=unknown")
            row.add("visionAction=use telegram_image_analyze")
            if (!imageDescription.isEmpty()) {
                row.add("ImageDescription=${imageDescription}")
            }
            if (!stickerDescription.isEmpty()) {
                row.add("StickerDescription=${stickerDescription}")
            }
        }
        if ((kind == "video" || kind == "video-note" || kind == "video_note" || mime.startsWith("video/")) && downloaded) {
            if (!videoDescription.isEmpty()) {
                row.add("VideoDescription=${videoDescription}")
            } else {
                let videoStatus = if (understandingStatus.isEmpty()) { "not_configured" } else { understandingStatus }
                row.add("VideoUnderstandingStatus=${videoStatus}")
                if (videoStatus == "not_configured") {
                    row.add("VideoAction=use telegram_video_describe")
                }
            }
        }
        if (!filePreview.isEmpty()) {
            row.add("FileContentPreview=${filePreview}")
        } else if (kind == "document" && downloaded) {
            row.add("DocumentExtractStatus=metadata_only")
            row.add("DocumentAction=use telegram_document_extract")
        }
        lines.add("- " + String.join(row.toArray(), delimiter: "; "))
    }
    if (paths.size > 0) {
        lines.add("MediaPaths=${String.join(paths.toArray(), delimiter: ", ")}")
    }
    if (types.size > 0) {
        lines.add("MediaTypes=${String.join(types.toArray(), delimiter: ", ")}")
    }
    String.join(lines.toArray(), delimiter: "\n")
}

public class GatewayResolvedSessionTurnResult {
    public let context: GatewaySessionContext
    public let execution: GatewaySessionExecutionResult

    public init(context: GatewaySessionContext, execution: GatewaySessionExecutionResult) {
        this.context = context
        this.execution = execution
    }
}

public func gatewayStreamingEnabledForUserChannel(user: GatewayUserSettings, channelName: String): Bool {
    let normalized = channelName.trimAscii().toAsciiLower()
    if (normalized == "telegram" || normalized == "feishu" || normalized == "qq") {
        let (mode, blocked) = if (normalized == "telegram") {
            (user.telegram.streaming.trimAscii().toAsciiLower(), user.telegram.blockStreaming)
        } else if (normalized == "feishu") {
            (user.feishu.streaming.trimAscii().toAsciiLower(), user.feishu.blockStreaming)
        } else {
            (user.qq.streaming.trimAscii().toAsciiLower(), user.qq.blockStreaming)
        }
        if (blocked) {
            return false
        }
        return !(mode.isEmpty() || mode == "off" || mode == "false" || mode == "disabled" || mode == "none")
    }
    return normalized == "control-ui" || normalized == "dashboard" || normalized == "cli"
}

public func gatewayBridgeForSessionRequest(user: GatewayUserSettings, request: GatewaySessionRequest): AgentBridge {
    let store = gatewaySessionStoreForResolvedRequest(user, request)
    AgentBridge(sessionStore: store)
}

public func gatewayExecuteSessionRequestTurn(
    bridge: AgentBridge,
    request: GatewaySessionRequest,
    prompt: String,
    deliver!: Bool = false,
    extraSystemPrompt!: String = "",
    timeoutSeconds!: Int64 = 0,
    bestEffortDeliver!: Bool = false,
    replyToMessageId!: Option<String> = None,
    replyInThread!: Bool = false,
    deliverHook!: Option<(String, String, String, String, Option<String>, Bool) -> String> = None<(String, String, String, String, Option<String>, Bool) -> String>,
    transcriptHook!: Option<(GatewaySessionContext, Int64, String, String) -> Unit> = None<(GatewaySessionContext, Int64, String, String) -> Unit>,
    streamHook!: Option<(GatewaySessionContext, String) -> Unit> = None<(GatewaySessionContext, String) -> Unit>,
    streamingEnabled!: Bool = false,
    lifecycleHook!: Option<(String) -> Unit> = None<(String) -> Unit>,
    turnContextOverride!: Option<GatewayTurnContext> = None<GatewayTurnContext>,
    executionControl!: Option<GatewayExecutionControl> = None<GatewayExecutionControl>
): GatewayResolvedSessionTurnResult {
    let resolvedContext = gatewayResolveSessionContextWithAgentRoute(request)
    let context = match (turnContextOverride) {
        case Some(turnContext) => GatewaySessionContext(
            resolvedContext.source,
            resolvedContext.sourceLabel,
            resolvedContext.channelName,
            resolvedContext.sessionKey,
            resolvedContext.agentId,
            accountId: resolvedContext.accountId,
            preferredAccountId: resolvedContext.preferredAccountId,
            matchedBy: resolvedContext.matchedBy,
            lastRoutePolicy: resolvedContext.lastRoutePolicy,
            routeDiagnostics: resolvedContext.routeDiagnostics,
            lane: resolvedContext.lane,
            deliveryTarget: resolvedContext.deliveryTarget,
            turnContext: Some(turnContext)
        )
        case None => resolvedContext
    }
    let toolRuntimeContext = GatewayToolRuntimeContext(
        context.sourceLabel,
        channelName: context.channelName,
        sessionKey: context.sessionKey,
        senderId: request.senderId,
        declaredUser: request.declaredUser,
        agentId: context.turnContext.agentId,
        workspaceDir: context.turnContext.workspaceDir,
        agentDir: context.turnContext.agentDir,
        modelsJsonPath: context.turnContext.modelsJsonPath,
        authProfilesPath: context.turnContext.authProfilesPath,
        operatorScopes: request.operatorScopes,
        prompt: prompt,
        mediaContext: request.mediaContext,
        memorySearchPolicy: gatewayMemorySearchPolicyFromScope(context.turnContext.agentScope),
        cronJobId: request.cronJobId,
        toolExecMode: request.toolExecMode,
        toolExecAllowlist: request.toolExecAllowlist,
        lifecycleHook: lifecycleHook,
        gatewayCallHook: gatewaySessionTurnGatewayCallHookFromDeliverHook(deliverHook),
        remainingMsHook: match (executionControl) {
            case Some(control) => Some<() -> Int64>({ => control.remainingMs() })
            case None => None<() -> Int64>
        },
        heartbeatHook: match (executionControl) {
            case Some(control) => Some<() -> Unit>({ => control.heartbeat() })
            case None => None<() -> Unit>
        },
        cancellationCheckHook: match (executionControl) {
            case Some(control) => Some<() -> Unit>({ => control.throwIfCancelled() })
            case None => None<() -> Unit>
        }
    )
    let mediaPrompt = gatewayBuildMediaContextPrompt(request.mediaContext)
    if (!mediaPrompt.trimAscii().isEmpty()) {
        let meta = JsonObject()
        meta.put("channel", JsonString(context.channelName))
        meta.put("sessionId", JsonString(context.sessionKey))
        meta.put("recordCount", JsonInt(Int64(gatewayMediaRecords(request.mediaContext).size())))
        meta.put("promptChars", JsonInt(Int64(mediaPrompt.size)))
        emitGatewayMediaDiagnostic("info", MediaDiagnosticEvent.mediaPromptInjected, "media prompt injected into model context", meta: meta)
    }
    let mergedExtraSystemPrompt = if (mediaPrompt.trimAscii().isEmpty()) {
        extraSystemPrompt
    } else if (extraSystemPrompt.trimAscii().isEmpty()) {
        mediaPrompt
    } else {
        extraSystemPrompt + "\n\n" + mediaPrompt
    }
    match (context.deliveryTarget) {
        case Some(target) =>
            // Persist the latest real delivery/binding target so later catalog views do not need to infer
            // conversation/thread/reply metadata from the session key alone.
            bridge.getSessionStore().appendBindingSnapshot(context.sessionKey, target)
        case None => ()
    }
    let execution = gatewayExecuteSessionTurn(
        bridge,
        context,
        prompt,
        deliver: deliver,
        extraSystemPrompt: mergedExtraSystemPrompt,
        timeoutSeconds: timeoutSeconds,
        toolRuntimeContext: Some(toolRuntimeContext),
        bestEffortDeliver: bestEffortDeliver,
        replyToMessageId: replyToMessageId,
        replyInThread: replyInThread,
        deliverHook: deliverHook,
        transcriptHook: transcriptHook,
        streamHook: streamHook,
        streamingEnabled: streamingEnabled,
        lifecycleHook: lifecycleHook
        , executionControl: executionControl
    )
    GatewayResolvedSessionTurnResult(context, execution)
}

public func gatewayExecuteSessionRequestTurnForUser(
    user: GatewayUserSettings,
    request: GatewaySessionRequest,
    prompt: String,
    deliver!: Bool = false,
    extraSystemPrompt!: String = "",
    timeoutSeconds!: Int64 = 0,
    bestEffortDeliver!: Bool = false,
    replyToMessageId!: Option<String> = None,
    replyInThread!: Bool = false,
    deliverHook!: Option<(String, String, String, String, Option<String>, Bool) -> String> = None<(String, String, String, String, Option<String>, Bool) -> String>,
    transcriptHook!: Option<(GatewaySessionContext, Int64, String, String) -> Unit> = None<(GatewaySessionContext, Int64, String, String) -> Unit>,
    streamHook!: Option<(GatewaySessionContext, String) -> Unit> = None<(GatewaySessionContext, String) -> Unit>,
    lifecycleHook!: Option<(String) -> Unit> = None<(String) -> Unit>,
    turnContextOverride!: Option<GatewayTurnContext> = None<GatewayTurnContext>,
    executionControl!: Option<GatewayExecutionControl> = None<GatewayExecutionControl>
): GatewayResolvedSessionTurnResult {
    let bridge = gatewayBridgeForSessionRequest(user, request)
    let context = gatewayResolveSessionContextWithAgentRoute(request)
    gatewayExecuteSessionRequestTurn(
        bridge,
        request,
        prompt,
        deliver: deliver,
        extraSystemPrompt: extraSystemPrompt,
        timeoutSeconds: timeoutSeconds,
        bestEffortDeliver: bestEffortDeliver,
        replyToMessageId: replyToMessageId,
        replyInThread: replyInThread,
        deliverHook: deliverHook,
        transcriptHook: transcriptHook,
        streamHook: streamHook,
        streamingEnabled: gatewayStreamingEnabledForUserChannel(user, context.channelName),
        lifecycleHook: lifecycleHook,
        turnContextOverride: turnContextOverride,
        executionControl: executionControl
    )
}
