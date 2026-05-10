package metis.core

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.fs.{File, Path, exists}
import std.time.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public class GatewayMediaVideoHttpResult {
    public let statusCode: Int64
    public let bodyBytes: Array<Byte>
    public let error: String
    public let contentType: String

    public init(statusCode: Int64, bodyBytes!: Array<Byte> = [], error!: String = "", contentType!: String = "") {
        this.statusCode = statusCode
        this.bodyBytes = bodyBytes
        this.error = error
        this.contentType = contentType
    }
}

private class GatewayMediaVideoProviderException <: Exception {
    public let status: String

    public init(status: String, message: String) {
        super(message)
        this.status = status
    }
}

private var gatewayMediaVideoHttpRunnerOverride: Option<(JsonObject) -> GatewayMediaVideoHttpResult> =
    None<(JsonObject) -> GatewayMediaVideoHttpResult>

public func setGatewayMediaVideoHttpRunnerForTest(runner: Option<(JsonObject) -> GatewayMediaVideoHttpResult>): Unit {
    gatewayMediaVideoHttpRunnerOverride = runner
}

private func videoString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func videoInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func videoBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func videoObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func videoSecretString(obj: JsonObject, key: String): String {
    let raw = videoString(obj, key)
    if (raw.startsWith("$" + "{") && raw.endsWith("}") && raw.size > 3) {
        let envKey = raw[2..raw.size - 1].trimAscii()
        if (!envKey.isEmpty()) {
            return getVariable(envKey) ?? ""
        }
    }
    raw
}

private func videoResult(status: String, ok!: Bool = false, message!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("status", JsonString(status))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func videoProviderConfig(config: JsonObject, provider: String): JsonObject {
    match (videoObject(config, "providers").get(provider)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func videoProviderKind(provider: String, providerConfig: JsonObject): String {
    if (provider.trimAscii().isEmpty()) {
        return "missing"
    }
    let explicit = videoString(providerConfig, "kind").toAsciiLower()
    if (!explicit.isEmpty()) {
        return explicit
    }
    "missing"
}

private func videoBaseUrl(providerConfig: JsonObject): String {
    var baseUrl = videoString(providerConfig, "baseUrl")
    if (baseUrl.isEmpty()) {
        baseUrl = "https://generativelanguage.googleapis.com/v1beta"
    }
    while (baseUrl.endsWith("/") && baseUrl.size > 1) {
        baseUrl = baseUrl[..baseUrl.size - 1]
    }
    baseUrl
}

private func videoQwenBaseUrl(providerConfig: JsonObject): String {
    var baseUrl = videoString(providerConfig, "baseUrl")
    if (baseUrl.isEmpty()) {
        baseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    }
    while (baseUrl.endsWith("/") && baseUrl.size > 1) {
        baseUrl = baseUrl[..baseUrl.size - 1]
    }
    baseUrl
}

private func videoGeminiModel(providerConfig: JsonObject): String {
    let model = videoString(providerConfig, "model")
    if (model.isEmpty()) {
        return "gemini-3-flash-preview"
    }
    model
}

private func videoQwenModel(providerConfig: JsonObject): String {
    let model = videoString(providerConfig, "model")
    if (model.isEmpty()) {
        return "qwen3-vl-plus"
    }
    model
}

private func videoPrompt(config: JsonObject, providerConfig: JsonObject, prompt: String): String {
    let requested = prompt.trimAscii()
    if (!requested.isEmpty()) {
        return requested
    }
    let providerPrompt = videoString(providerConfig, "prompt")
    if (!providerPrompt.isEmpty()) {
        return providerPrompt
    }
    let configPrompt = videoString(config, "prompt")
    if (!configPrompt.isEmpty()) {
        return configPrompt
    }
    "Describe the video."
}

private func videoQwenPrompt(config: JsonObject, providerConfig: JsonObject, prompt: String): String {
    let requested = prompt.trimAscii()
    if (!requested.isEmpty()) {
        return requested
    }
    let providerPrompt = videoString(providerConfig, "prompt")
    if (!providerPrompt.isEmpty()) {
        return providerPrompt
    }
    let configPrompt = videoString(config, "prompt")
    if (!configPrompt.isEmpty()) {
        return configPrompt
    }
    "Describe the video in detail."
}

private func videoEstimateBase64Bytes(bytes: Int64): Int64 {
    ((bytes + 2) / 3) * 4
}

private func videoTooLargeResult(message: String, fileBytes: Int64, limitBytes: Int64): JsonObject {
    let out = videoResult("too_large", ok: false, message: message)
    out.put("fileBytes", JsonInt(fileBytes))
    out.put("limitBytes", JsonInt(limitBytes))
    out
}

private func videoReadAllBytes(response: HttpResponse): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
    }
    out.toArray()
}

private func videoNativePost(request: JsonObject, providerConfig: JsonObject): GatewayMediaVideoHttpResult {
    let url = videoString(request, "url")
    let timeoutMs = max(1, videoInt(request, "timeoutMs", videoInt(providerConfig, "timeoutMs", 120000)))
    let headers = HashMap<String, String>()
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json, text/plain"
    let apiKey = videoString(request, "xGoogApiKey")
    if (!apiKey.isEmpty()) {
        headers["x-goog-api-key"] = apiKey
    }
    let authorization = videoString(request, "authorization")
    if (!authorization.isEmpty()) {
        headers["Authorization"] = authorization
    }
    let body = videoObject(request, "body")

    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * timeoutMs)
    if (url.startsWith("https")) {
        var tlsConfig = TlsClientConfig()
        if (videoBool(providerConfig, "insecureSkipTlsVerify", false)) {
            tlsConfig.verifyMode = TrustAll
        }
        tlsConfig.domain = URL.parse(url).hostName
        tlsConfig.alpnProtocolsList = ["http/1.1"]
        builder.tlsConfig(tlsConfig)
    }
    let client = builder.build()
    try {
        let reqBuilder = HttpRequestBuilder().url(url).post().body(body.toJsonString())
        for ((key, value) in headers) {
            reqBuilder.header(key, value)
        }
        let response = client.send(reqBuilder.build())
        GatewayMediaVideoHttpResult(Int64(response.status), bodyBytes: videoReadAllBytes(response))
    } finally {
        client.close()
    }
}

private func videoRedactValue(detail: String, value: String): String {
    if (value.trimAscii().isEmpty()) {
        return detail
    }
    detail.replace(value, "[redacted]")
}

private func videoRedactSensitive(detail: String, providerConfig: JsonObject, request: JsonObject, inputPath: String): String {
    var out = detail.trimAscii()
    out = videoRedactValue(out, videoSecretString(providerConfig, "apiKey"))
    out = videoRedactValue(out, videoString(request, "xGoogApiKey"))
    out = videoRedactValue(out, inputPath)
    out = out.replace("Authorization", "[redacted-header]").replace("authorization", "[redacted-header]")
    if (out.size > 300) {
        out = out[..300]
    }
    out
}

private func videoErrorDetail(result: GatewayMediaVideoHttpResult, providerConfig: JsonObject, request: JsonObject, inputPath: String): String {
    var detail = result.error.trimAscii()
    if (detail.isEmpty()) {
        try { detail = String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { detail = "" }
    }
    videoRedactSensitive(detail, providerConfig, request, inputPath)
}

private func videoGeminiTextFromJson(raw: String): String {
    let partsOut = ArrayList<String>()
    try {
        let obj = JsonValue.fromStr(raw).asObject()
        let candidates = match (obj.get("candidates")) {
            case Some(v) => v.asArray()
            case None => JsonArray()
        }
        if (candidates.size() <= 0) {
            return ""
        }
        let first = candidates[0].asObject()
        let content = first.get("content").getOrThrow().asObject()
        let parts = content.get("parts").getOrThrow().asArray()
        for (idx in 0..parts.size()) {
            let text = videoString(parts[idx].asObject(), "text")
            if (!text.isEmpty()) {
                partsOut.add(text)
            }
        }
    } catch (_: Exception) {
        return ""
    }
    String.join(partsOut.toArray(), delimiter: "\n").trimAscii()
}

private func videoGeminiDescription(result: GatewayMediaVideoHttpResult, providerConfig: JsonObject, request: JsonObject, inputPath: String): String {
    let status = result.statusCode
    if (status < 200 || status >= 300) {
        let detail = videoErrorDetail(result, providerConfig, request, inputPath)
        let message = if (detail.isEmpty()) { "video understanding provider failed (${status})" } else { "video understanding provider failed (${status}): ${detail}" }
        if (status == 408) {
            throw GatewayMediaVideoProviderException("timeout", message)
        }
        throw GatewayMediaVideoProviderException("provider_error", message)
    }
    let raw = try { String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { "" }
    let text = videoGeminiTextFromJson(raw).trimAscii()
    if (text.isEmpty()) {
        throw GatewayMediaVideoProviderException("provider_error", "Gemini video description response missing text.")
    }
    text
}

private func videoQwenTextFromJson(raw: String): String {
    let partsOut = ArrayList<String>()
    try {
        let obj = JsonValue.fromStr(raw).asObject()
        let choices = match (obj.get("choices")) {
            case Some(v) => v.asArray()
            case None => JsonArray()
        }
        if (choices.size() <= 0) {
            return ""
        }
        let first = choices[0].asObject()
        let message = first.get("message").getOrThrow().asObject()
        match (message.get("content")) {
            case Some(v) =>
                try {
                    let text = v.asString().getValue().trimAscii()
                    if (!text.isEmpty()) {
                        return text
                    }
                } catch (_: Exception) {
                    try {
                        let parts = v.asArray()
                        for (idx in 0..parts.size()) {
                            let text = videoString(parts[idx].asObject(), "text")
                            if (!text.isEmpty()) {
                                partsOut.add(text)
                            }
                        }
                        let joined = String.join(partsOut.toArray(), delimiter: "\n").trimAscii()
                        if (!joined.isEmpty()) {
                            return joined
                        }
                    } catch (_inner: Exception) {
                        ()
                    }
                }
            case None => ()
        }
        videoString(message, "reasoning_content")
    } catch (_: Exception) {
        return ""
    }
}

private func videoQwenDescription(result: GatewayMediaVideoHttpResult, providerConfig: JsonObject, request: JsonObject, inputPath: String): String {
    let status = result.statusCode
    if (status < 200 || status >= 300) {
        let detail = videoErrorDetail(result, providerConfig, request, inputPath)
        let message = if (detail.isEmpty()) { "Qwen video understanding provider failed (${status})" } else { "Qwen video understanding provider failed (${status}): ${detail}" }
        if (status == 408) {
            throw GatewayMediaVideoProviderException("timeout", message)
        }
        throw GatewayMediaVideoProviderException("provider_error", message)
    }
    let raw = try { String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { "" }
    let text = videoQwenTextFromJson(raw).trimAscii()
    if (text.isEmpty()) {
        throw GatewayMediaVideoProviderException("provider_error", "Qwen video description response missing content.")
    }
    text
}

private func videoGeminiRequest(config: JsonObject, providerConfig: JsonObject, inputBytes: Array<Byte>, mime: String, prompt: String, timeoutMs: Int64): JsonObject {
    let model = videoGeminiModel(providerConfig)
    let req = JsonObject()
    req.put("url", JsonString("${videoBaseUrl(providerConfig)}/models/${model}:generateContent"))
    req.put("xGoogApiKey", JsonString(videoSecretString(providerConfig, "apiKey")))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("model", JsonString(model))

    let inline = JsonObject()
    inline.put("mime_type", JsonString(if (mime.trimAscii().isEmpty()) { "video/mp4" } else { mime.trimAscii().toAsciiLower() }))
    inline.put("data", JsonString(toBase64String(inputBytes)))
    let textPart = JsonObject()
    textPart.put("text", JsonString(videoPrompt(config, providerConfig, prompt)))
    let inlinePart = JsonObject()
    inlinePart.put("inline_data", inline)
    let content = JsonObject()
    content.put("role", JsonString("user"))
    content.put("parts", JsonArray([textPart, inlinePart]))
    let body = JsonObject()
    body.put("contents", JsonArray([content]))
    req.put("body", body)
    req
}

private func videoQwenRequest(config: JsonObject, providerConfig: JsonObject, inputBytes: Array<Byte>, mime: String, prompt: String, timeoutMs: Int64): JsonObject {
    let model = videoQwenModel(providerConfig)
    let req = JsonObject()
    req.put("url", JsonString("${videoQwenBaseUrl(providerConfig)}/chat/completions"))
    req.put("authorization", JsonString("Bearer ${videoSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("model", JsonString(model))

    let textPart = JsonObject()
    textPart.put("type", JsonString("text"))
    textPart.put("text", JsonString(videoQwenPrompt(config, providerConfig, prompt)))

    let videoUrl = JsonObject()
    let normalizedMime = if (mime.trimAscii().isEmpty()) { "video/mp4" } else { mime.trimAscii().toAsciiLower() }
    videoUrl.put("url", JsonString("data:${normalizedMime};base64,${toBase64String(inputBytes)}"))
    let videoPart = JsonObject()
    videoPart.put("type", JsonString("video_url"))
    videoPart.put("video_url", videoUrl)

    let message = JsonObject()
    message.put("role", JsonString("user"))
    message.put("content", JsonArray([textPart, videoPart]))

    let body = JsonObject()
    body.put("model", JsonString(model))
    body.put("messages", JsonArray([message]))
    req.put("body", body)
    req
}

private func videoPost(request: JsonObject, providerConfig: JsonObject): GatewayMediaVideoHttpResult {
    match (gatewayMediaVideoHttpRunnerOverride) {
        case Some(runner) => runner(request)
        case None => videoNativePost(request, providerConfig)
    }
}

public func gatewayMediaVideoDescribePath(config: JsonObject, path: String, mime: String, prompt: String, outputRoot!: Path, maxBytes!: Int64 = 0): JsonObject {
    let inputPath = path.trimAscii()
    if (inputPath.isEmpty() || !exists(Path(inputPath))) {
        return videoResult("unsupported", ok: false, message: "video input path is missing")
    }
    if (!videoBool(config, "enabled", true)) {
        return videoResult("disabled", ok: false, message: "Gateway video understanding is disabled.")
    }
    let provider = videoString(config, "provider")
    if (provider.isEmpty()) {
        return videoResult("not_configured", ok: false, message: "No Metis Gateway video understanding provider is configured.")
    }
    let providerConfig = videoProviderConfig(config, provider)
    let providerKind = videoProviderKind(provider, providerConfig)
    let outBase = { status: String, message: String =>
        let out = videoResult(status, ok: false, message: message)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out
    }
    if (providerKind != "gemini-inline-video" && providerKind != "qwen-vl-video") {
        return outBase("not_found", "Configured video understanding provider '${provider}' is not available.")
    }
    let apiKey = videoSecretString(providerConfig, "apiKey")
    if (apiKey.isEmpty()) {
        return outBase("not_configured", "Configured video provider '${provider}' is missing apiKey.")
    }
    let inputBytes = File.readFrom(Path(inputPath))
    let fileBytes = Int64(inputBytes.size)
    let effectiveMaxBytes = videoInt(config, "maxBytes", maxBytes)
    if (effectiveMaxBytes > 0 && fileBytes > effectiveMaxBytes) {
        let out = videoTooLargeResult("video input exceeds configured maxBytes", fileBytes, effectiveMaxBytes)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        return out
    }
    let providerMaxBytes = videoInt(providerConfig, "maxBytes", 0)
    if (providerMaxBytes > 0 && fileBytes > providerMaxBytes) {
        let out = videoTooLargeResult("video input exceeds provider maxBytes", fileBytes, providerMaxBytes)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        return out
    }
    let estimatedBase64Bytes = videoEstimateBase64Bytes(fileBytes)
    let maxBase64Bytes = videoInt(config, "maxBase64Bytes", 70 * 1024 * 1024)
    if (maxBase64Bytes > 0 && estimatedBase64Bytes > maxBase64Bytes) {
        let out = videoResult("too_large", ok: false, message: "video base64 payload exceeds configured maxBase64Bytes")
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("fileBytes", JsonInt(fileBytes))
        out.put("base64Bytes", JsonInt(estimatedBase64Bytes))
        out.put("limitBytes", JsonInt(maxBase64Bytes))
        return out
    }
    let timeoutMs = max(1, videoInt(providerConfig, "timeoutMs", videoInt(config, "timeoutMs", 120000)))
    let request = if (providerKind == "qwen-vl-video") {
        videoQwenRequest(config, providerConfig, inputBytes, mime, prompt, timeoutMs)
    } else {
        videoGeminiRequest(config, providerConfig, inputBytes, mime, prompt, timeoutMs)
    }
    try {
        let result = videoPost(request, providerConfig)
        let description = if (providerKind == "qwen-vl-video") {
            videoQwenDescription(result, providerConfig, request, inputPath)
        } else {
            videoGeminiDescription(result, providerConfig, request, inputPath)
        }.trimAscii()
        let out = videoResult("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(videoString(request, "model")))
        out.put("description", JsonString(description))
        return out
    } catch (e: GatewayMediaVideoProviderException) {
        let out = outBase(e.status, videoRedactSensitive(e.message, providerConfig, request, inputPath))
        if (e.status == "timeout") {
            out.put("timeoutMs", JsonInt(timeoutMs))
        }
        return out
    } catch (e: Exception) {
        let msg = e.message.toAsciiLower()
        if (msg.contains("timeout") || msg.contains("timed out")) {
            let out = outBase("timeout", "Configured video understanding provider request timed out.")
            out.put("timeoutMs", JsonInt(timeoutMs))
            return out
        }
        outBase("provider_error", videoRedactSensitive(e.message, providerConfig, request, inputPath))
    }
}
