package metis.core

import magic.core.message.Message
import magic.core.model.ChatRequest
import magic.jsonable.*
import magic.model.ModelManager

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.regex.{Regex, RegexFlag}
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public class GatewayPdfInput {
    public let base64: String
    public let filename: String

    public init(base64: String, filename!: String = "") {
        this.base64 = base64.trimAscii()
        this.filename = filename.trimAscii()
    }
}

public class GatewayPdfExtractedImage {
    public let mimeType: String
    public let data: String
    public let pageNumber: Int64

    public init(mimeType: String, data: String, pageNumber!: Int64 = 0) {
        let normalizedMime = mimeType.trimAscii().toAsciiLower()
        this.mimeType = if (normalizedMime.startsWith("image/")) { normalizedMime } else { "image/png" }
        this.data = data.trimAscii()
        this.pageNumber = pageNumber
    }
}

public class GatewayPdfExtraction {
    public let text: String
    public let images: Array<GatewayPdfExtractedImage>
    public let pageCount: Int64
    public let selectedPages: Array<Int64>

    public init(
        text: String,
        images!: Array<GatewayPdfExtractedImage> = [],
        pageCount!: Int64 = 0,
        selectedPages!: Array<Int64> = []
    ) {
        this.text = text
        this.images = images
        this.pageCount = pageCount
        this.selectedPages = selectedPages
    }
}

public class GatewayPdfPromptCandidate {
    public let modelRef: String
    public let provider: String
    public let model: String
    public let source: String
    public let nativePdfSupported: Bool
    public let imageSupported: Bool
    public let apiKey: String
    public let baseUrl: String
    public let maxTokens: Int64
    public let timeoutMs: Int64

    public init(
        modelRef: String,
        source!: String = "",
        nativePdfSupported!: Bool = false,
        imageSupported!: Bool = false,
        apiKey!: String = "",
        baseUrl!: String = "",
        maxTokens!: Int64 = 4096,
        timeoutMs!: Int64 = 120000
    ) {
        let normalized = pdfNormalizeModelRef(modelRef)
        this.modelRef = normalized
        this.provider = pdfModelProvider(normalized)
        this.model = pdfModelName(normalized)
        this.source = source.trimAscii()
        this.nativePdfSupported = nativePdfSupported
        this.imageSupported = imageSupported
        this.apiKey = apiKey.trimAscii()
        this.baseUrl = baseUrl.trimAscii()
        this.maxTokens = if (maxTokens > 0) { maxTokens } else { 4096 }
        this.timeoutMs = if (timeoutMs > 0) { timeoutMs } else { 120000 }
    }
}

public class GatewayPdfPromptAttempt {
    public let provider: String
    public let model: String
    public let source: String
    public let native: Bool
    public let status: String
    public let error: String

    public init(provider: String, model: String, source: String, native: Bool, status: String, error!: String = "") {
        this.provider = provider
        this.model = model
        this.source = source
        this.native = native
        this.status = status
        this.error = error.trimAscii()
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("provider", JsonString(this.provider))
        out.put("model", JsonString(this.model))
        out.put("source", JsonString(this.source))
        out.put("native", JsonBool(this.native))
        out.put("status", JsonString(this.status))
        if (!this.error.isEmpty()) {
            out.put("error", JsonString(this.error))
        }
        out
    }
}

public class GatewayPdfPromptResult {
    public let ok: Bool
    public let text: String
    public let provider: String
    public let model: String
    public let native: Bool
    public let attempts: Array<GatewayPdfPromptAttempt>
    public let error: String

    public init(
        ok: Bool,
        text!: String = "",
        provider!: String = "",
        model!: String = "",
        native!: Bool = false,
        attempts!: Array<GatewayPdfPromptAttempt> = [],
        error!: String = ""
    ) {
        this.ok = ok
        this.text = text.trimAscii()
        this.provider = provider.trimAscii()
        this.model = model.trimAscii()
        this.native = native
        this.attempts = attempts
        this.error = error.trimAscii()
    }

    public func attemptsJson(): JsonArray {
        let out = JsonArray([])
        for (attempt in this.attempts) {
            out.add(attempt.toJson().toJsonValue())
        }
        out
    }
}

public class GatewayPdfNativeHttpResult {
    public let statusCode: Int64
    public let bodyBytes: Array<Byte>
    public let error: String

    public init(statusCode: Int64, bodyBytes!: Array<Byte> = [], error!: String = "") {
        this.statusCode = statusCode
        this.bodyBytes = bodyBytes
        this.error = error.trimAscii()
    }
}

private class GatewayPdfPromptProviderException <: Exception {
    public let status: String

    public init(status: String, message: String) {
        super(message)
        this.status = status
    }
}

private class GatewayPdfPromptImagePart {
    public let label: String
    public let dataUrl: String

    public init(label: String, dataUrl: String) {
        this.label = label
        this.dataUrl = dataUrl
    }
}

private var gatewayPdfNativeHttpRunnerOverride: Option<(JsonObject) -> GatewayPdfNativeHttpResult> =
    None<(JsonObject) -> GatewayPdfNativeHttpResult>

public func setGatewayPdfNativeHttpRunnerForTest(runner: Option<(JsonObject) -> GatewayPdfNativeHttpResult>): Unit {
    gatewayPdfNativeHttpRunnerOverride = runner
}

public func gatewayPdfProviderSupportsNativePdf(provider: String): Bool {
    let normalized = provider.trimAscii().toAsciiLower()
    normalized == "anthropic" || normalized == "google" || normalized == "gemini"
}

private func pdfNormalizeModelRef(modelRef: String): String {
    let trimmed = modelRef.trimAscii()
    if (trimmed.contains(":")) {
        return trimmed
    }
    if (let Some(idx) <- trimmed.indexOf("/")) {
        return "${trimmed[..idx]}:${trimmed[idx + 1..]}"
    }
    trimmed
}

private func pdfModelProvider(modelRef: String): String {
    let normalized = pdfNormalizeModelRef(modelRef)
    if (let Some(idx) <- normalized.indexOf(":")) {
        return normalized[..idx].trimAscii().toAsciiLower()
    }
    ""
}

private func pdfModelName(modelRef: String): String {
    let normalized = pdfNormalizeModelRef(modelRef)
    if (let Some(idx) <- normalized.indexOf(":")) {
        return normalized[idx + 1..].trimAscii()
    }
    normalized.trimAscii()
}

private func pdfSecretString(value: String): String {
    let raw = value.trimAscii()
    if (raw.startsWith("$" + "{") && raw.endsWith("}") && raw.size > 3) {
        let key = raw[2..raw.size - 1].trimAscii()
        if (!key.isEmpty()) {
            return getVariable(key) ?? ""
        }
    }
    raw
}

private func pdfTrimTrailingSlashes(value: String): String {
    var out = value.trimAscii()
    while (out.endsWith("/") && out.size > 1) {
        out = out[..out.size - 1]
    }
    out
}

private func pdfRegexReplace(text: String, pattern: String, replacement: String): String {
    try {
        Regex(pattern, [RegexFlag.IgnoreCase]).replaceAll(text, replacement)
    } catch (_: Exception) {
        text
    }
}

private func pdfRedactQueryParam(text: String, key: String): String {
    var out = text
    out = pdfRegexReplace(out, "\\?${key}=[^\\s&#]+", "?${key}=[redacted]")
    out = pdfRegexReplace(out, "&${key}=[^\\s&#]+", "&${key}=[redacted]")
    out
}

private func pdfRedactProviderError(detail: String, candidate: GatewayPdfPromptCandidate): String {
    var out = detail.trimAscii()
    let apiKey = pdfSecretString(candidate.apiKey)
    if (!apiKey.isEmpty()) {
        out = out.replace(apiKey, "[redacted]")
    }
    out = pdfRegexReplace(out, "x-api-key\\s*[:=]\\s*[^\\s,;\\}\\]]+", "x-api-key: [redacted]")
    out = pdfRegexReplace(out, "Authorization\\s*[:=]\\s*Bearer\\s+[^\\s,;\\}\\]]+", "Authorization: Bearer [redacted]")
    out = pdfRegexReplace(out, "Authorization\\s*[:=]\\s*[^\\s,;\\}\\]]+", "Authorization: [redacted]")
    out = pdfRegexReplace(out, "Bearer\\s+[^\\s,;\\}\\]]+", "Bearer [redacted]")
    out = pdfRegexReplace(out, "api[_-]?key\\s*[:=]\\s*[^\\s,;\\}\\]]+", "api_key=[redacted]")
    for (key in ["api_key", "apikey", "key", "token", "access_token", "auth_token"]) {
        out = pdfRedactQueryParam(out, key)
    }
    if (out.size > 500) {
        out = out[..500]
    }
    out
}

private func pdfPromptJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func pdfPromptJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func pdfPromptReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func pdfNativePost(request: JsonObject): GatewayPdfNativeHttpResult {
    let url = pdfPromptJsonString(request, "url")
    let timeoutMs = try {
        Int64.parse(request.get("timeoutMs").getOrThrow().toJsonString())
    } catch (_: Exception) {
        120000
    }
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * max(1, timeoutMs))
    if (url.startsWith("https")) {
        var tlsConfig = TlsClientConfig()
        tlsConfig.domain = URL.parse(url).hostName
        tlsConfig.alpnProtocolsList = ["http/1.1"]
        builder.tlsConfig(tlsConfig)
    }
    let client = builder.build()
    try {
        let reqBuilder = HttpRequestBuilder().url(url).post().body(pdfPromptJsonObject(request, "body").toJsonString())
        let headers = pdfPromptJsonObject(request, "headers")
        for ((key, value) in headers.getFields()) {
            let headerValue = try { value.asString().getValue() } catch (_: Exception) { "" }
            if (!headerValue.isEmpty()) {
                reqBuilder.header(key, headerValue)
            }
        }
        let response = client.send(reqBuilder.build())
        GatewayPdfNativeHttpResult(Int64(response.status), bodyBytes: pdfPromptReadAllBytes(response))
    } finally {
        client.close()
    }
}

private func pdfPost(request: JsonObject): GatewayPdfNativeHttpResult {
    match (gatewayPdfNativeHttpRunnerOverride) {
        case Some(runner) => runner(request)
        case None => pdfNativePost(request)
    }
}

public func gatewayPdfBuildAnthropicNativeRequest(
    pdfs: Array<GatewayPdfInput>,
    prompt: String,
    candidate: GatewayPdfPromptCandidate
): JsonObject {
    let apiKey = pdfSecretString(candidate.apiKey)
    let baseUrl = pdfTrimTrailingSlashes(if (!candidate.baseUrl.isEmpty()) { candidate.baseUrl } else { "https://api.anthropic.com" })
    let headers = JsonObject()
    headers.put("Content-Type", JsonString("application/json"))
    headers.put("Accept", JsonString("application/json, text/plain"))
    headers.put("x-api-key", JsonString(apiKey))
    headers.put("anthropic-version", JsonString("2023-06-01"))
    headers.put("anthropic-beta", JsonString("pdfs-2024-09-25"))

    let content = JsonArray([])
    for (pdf in pdfs) {
        let source = JsonObject()
        source.put("type", JsonString("base64"))
        source.put("media_type", JsonString("application/pdf"))
        source.put("data", JsonString(pdf.base64))
        let block = JsonObject()
        block.put("type", JsonString("document"))
        block.put("source", source.toJsonValue())
        content.add(block.toJsonValue())
    }
    let promptBlock = JsonObject()
    promptBlock.put("type", JsonString("text"))
    promptBlock.put("text", JsonString(prompt.trimAscii()))
    content.add(promptBlock.toJsonValue())

    let message = JsonObject()
    message.put("role", JsonString("user"))
    message.put("content", content)
    let messages = JsonArray([message.toJsonValue()])
    let body = JsonObject()
    body.put("model", JsonString(candidate.model))
    body.put("max_tokens", JsonInt(candidate.maxTokens))
    body.put("messages", messages)

    let request = JsonObject()
    request.put("provider", JsonString("anthropic"))
    request.put("model", JsonString(candidate.model))
    request.put("url", JsonString("${baseUrl}/v1/messages"))
    request.put("headers", headers.toJsonValue())
    request.put("body", body.toJsonValue())
    request.put("timeoutMs", JsonInt(candidate.timeoutMs))
    request
}

public func gatewayPdfBuildGeminiNativeRequest(
    pdfs: Array<GatewayPdfInput>,
    prompt: String,
    candidate: GatewayPdfPromptCandidate
): JsonObject {
    let apiKey = pdfSecretString(candidate.apiKey)
    var baseUrl = pdfTrimTrailingSlashes(if (!candidate.baseUrl.isEmpty()) { candidate.baseUrl } else { "https://generativelanguage.googleapis.com/v1beta" })
    if (baseUrl.toAsciiLower().endsWith("/v1beta")) {
        baseUrl = baseUrl[..baseUrl.size - 7]
    }
    let parts = JsonArray([])
    for (pdf in pdfs) {
        let inlineData = JsonObject()
        inlineData.put("mime_type", JsonString("application/pdf"))
        inlineData.put("data", JsonString(pdf.base64))
        let part = JsonObject()
        part.put("inline_data", inlineData.toJsonValue())
        parts.add(part.toJsonValue())
    }
    let promptPart = JsonObject()
    promptPart.put("text", JsonString(prompt.trimAscii()))
    parts.add(promptPart.toJsonValue())

    let content = JsonObject()
    content.put("role", JsonString("user"))
    content.put("parts", parts)
    let body = JsonObject()
    body.put("contents", JsonArray([content.toJsonValue()]))

    let headers = JsonObject()
    headers.put("Content-Type", JsonString("application/json"))
    headers.put("Accept", JsonString("application/json, text/plain"))

    let request = JsonObject()
    request.put("provider", JsonString("google"))
    request.put("model", JsonString(candidate.model))
    request.put("url", JsonString("${baseUrl}/v1beta/models/${candidate.model}:generateContent?key=${apiKey}"))
    request.put("headers", headers.toJsonValue())
    request.put("body", body.toJsonValue())
    request.put("timeoutMs", JsonInt(candidate.timeoutMs))
    request
}

private func pdfResponseBody(result: GatewayPdfNativeHttpResult): String {
    var body = result.error.trimAscii()
    if (body.isEmpty()) {
        body = try { String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { "" }
    }
    body
}

private func pdfThrowIfHttpFailed(result: GatewayPdfNativeHttpResult, label: String, candidate: GatewayPdfPromptCandidate): Unit {
    if (result.statusCode >= 200 && result.statusCode < 300) {
        return
    }
    let detail = pdfRedactProviderError(pdfResponseBody(result), candidate)
    let message = if (detail.isEmpty()) {
        "${label} PDF request failed (${result.statusCode})"
    } else {
        "${label} PDF request failed (${result.statusCode}): ${detail}"
    }
    if (result.statusCode == 408) {
        throw GatewayPdfPromptProviderException("timeout", message)
    }
    throw GatewayPdfPromptProviderException("provider_error", message)
}

private func pdfAnthropicText(raw: String): String {
    let out = ArrayList<String>()
    try {
        let obj = JsonValue.fromStr(raw).asObject()
        let content = obj.get("content").getOrThrow().asArray()
        for (idx in 0..content.size()) {
            let block = content[idx].asObject()
            if (pdfPromptJsonString(block, "type") == "text") {
                let text = pdfPromptJsonString(block, "text")
                if (!text.isEmpty()) {
                    out.add(text)
                }
            }
        }
    } catch (_: Exception) {
        return ""
    }
    String.join(out.toArray(), delimiter: "").trimAscii()
}

private func pdfGeminiText(raw: String): String {
    let out = ArrayList<String>()
    try {
        let obj = JsonValue.fromStr(raw).asObject()
        let candidates = obj.get("candidates").getOrThrow().asArray()
        if (candidates.size() <= 0) {
            return ""
        }
        let first = candidates[0].asObject()
        let parts = first.get("content").getOrThrow().asObject().get("parts").getOrThrow().asArray()
        for (idx in 0..parts.size()) {
            let text = pdfPromptJsonString(parts[idx].asObject(), "text")
            if (!text.isEmpty()) {
                out.add(text)
            }
        }
    } catch (_: Exception) {
        return ""
    }
    String.join(out.toArray(), delimiter: "").trimAscii()
}

private func pdfRunNative(
    pdfs: Array<GatewayPdfInput>,
    prompt: String,
    candidate: GatewayPdfPromptCandidate
): String {
    if (pdfSecretString(candidate.apiKey).isEmpty()) {
        throw GatewayPdfPromptProviderException("not_configured", "native PDF provider ${candidate.provider} is missing apiKey")
    }
    let provider = candidate.provider
    let request = if (provider == "anthropic") {
        gatewayPdfBuildAnthropicNativeRequest(pdfs, prompt, candidate)
    } else {
        gatewayPdfBuildGeminiNativeRequest(pdfs, prompt, candidate)
    }
    let result = pdfPost(request)
    let label = if (provider == "anthropic") { "Anthropic" } else { "Gemini" }
    pdfThrowIfHttpFailed(result, label, candidate)
    let raw = pdfResponseBody(result)
    let text = if (provider == "anthropic") { pdfAnthropicText(raw) } else { pdfGeminiText(raw) }
    if (text.isEmpty()) {
        throw GatewayPdfPromptProviderException("provider_error", "${label} PDF returned no text.")
    }
    text
}

private func pdfExtractionTextContext(extractions: Array<GatewayPdfExtraction>): String {
    let parts = ArrayList<String>()
    for (idx in 0..extractions.size) {
        let text = extractions[idx].text.trimAscii()
        if (text.isEmpty()) {
            continue
        }
        let label = if (extractions.size > 1) { "[PDF ${idx + 1} text]" } else { "[PDF text]" }
        parts.add("${label}\n${text}")
    }
    String.join(parts.toArray(), delimiter: "\n\n").trimAscii()
}

private func pdfImageDataUrl(image: GatewayPdfExtractedImage): String {
    let data = image.data.trimAscii()
    if (data.startsWith("data:image/")) {
        return data
    }
    "data:${image.mimeType};base64,${data}"
}

private func pdfExtractionImages(extractions: Array<GatewayPdfExtraction>): Array<GatewayPdfPromptImagePart> {
    let out = ArrayList<GatewayPdfPromptImagePart>()
    for (pdfIdx in 0..extractions.size) {
        let extraction = extractions[pdfIdx]
        for (imageIdx in 0..extraction.images.size) {
            let image = extraction.images[imageIdx]
            let pageSuffix = if (image.pageNumber > 0) { " page ${image.pageNumber}" } else { " page image ${imageIdx + 1}" }
            let label = if (extractions.size > 1) { "[PDF ${pdfIdx + 1}${pageSuffix}]" } else { "[PDF${pageSuffix}]" }
            out.add(GatewayPdfPromptImagePart(label, pdfImageDataUrl(image)))
        }
    }
    out.toArray()
}

private func pdfBuildFallbackMessages(prompt: String, extractions: Array<GatewayPdfExtraction>, includeImages: Bool): Array<Message> {
    let messages = ArrayList<Message>()
    let context = pdfExtractionTextContext(extractions)
    let images = if (includeImages) { pdfExtractionImages(extractions) } else { Array<GatewayPdfPromptImagePart>() }
    if (images.isEmpty()) {
        let content = if (context.isEmpty()) { prompt.trimAscii() } else { "${context}\n\n${prompt.trimAscii()}" }
        messages.add(Message.user(content))
        return messages.toArray()
    }

    for (idx in 0..images.size) {
        let image = images[idx]
        let content = if (idx == 0 && !context.isEmpty()) {
            "${context}\n\n${prompt.trimAscii()}\n\n${image.label}"
        } else if (idx == 0) {
            "${prompt.trimAscii()}\n\n${image.label}"
        } else {
            image.label
        }
        messages.add(Message.user(content, image: Some(image.dataUrl)))
    }
    messages.toArray()
}

private func pdfAttemptStatusFromMessage(message: String): String {
    let lower = message.toAsciiLower()
    if (lower.contains("timeout") || lower.contains("timed out")) {
        return "timeout"
    }
    if (lower.contains("not_configured") || lower.contains("missing apikey") || lower.contains("missing apikey")) {
        return "not_configured"
    }
    "provider_error"
}

private func pdfFailureResult(attempts: ArrayList<GatewayPdfPromptAttempt>, fallbackError: String): GatewayPdfPromptResult {
    var error = fallbackError.trimAscii()
    if (error.isEmpty() && attempts.size > 0) {
        error = attempts[attempts.size - 1].error
    }
    GatewayPdfPromptResult(false, attempts: attempts.toArray(), error: error)
}

public func gatewayPdfRunPrompt(
    pdfs: Array<GatewayPdfInput>,
    prompt: String,
    candidates: Array<GatewayPdfPromptCandidate>,
    extractor: () -> Array<GatewayPdfExtraction>,
    pageNumbers!: Array<Int64> = []
): GatewayPdfPromptResult {
    let attempts = ArrayList<GatewayPdfPromptAttempt>()
    if (pdfs.isEmpty()) {
        return GatewayPdfPromptResult(false, error: "pdf input is required")
    }
    if (candidates.isEmpty()) {
        return GatewayPdfPromptResult(false, error: "no PDF prompt model candidates configured")
    }
    let effectivePrompt = if (prompt.trimAscii().isEmpty()) { "Analyze this PDF document." } else { prompt.trimAscii() }
    var extractionCache: Option<Array<GatewayPdfExtraction>> = None<Array<GatewayPdfExtraction>>

    for (candidate in candidates) {
        let useNative = candidate.nativePdfSupported && gatewayPdfProviderSupportsNativePdf(candidate.provider)
        if (useNative) {
            if (!pageNumbers.isEmpty()) {
                let error = "pages is not supported with native PDF providers (${candidate.provider}/${candidate.model}). Remove pages, or use a non-native model for page filtering."
                attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, true, "unsupported_pages", error: error))
                continue
            }
            try {
                let text = pdfRunNative(pdfs, effectivePrompt, candidate)
                attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, true, "ok"))
                return GatewayPdfPromptResult(
                    true,
                    text: text,
                    provider: candidate.provider,
                    model: candidate.model,
                    native: true,
                    attempts: attempts.toArray()
                )
            } catch (e: GatewayPdfPromptProviderException) {
                attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, true, e.status, error: pdfRedactProviderError(e.message, candidate)))
                continue
            } catch (e: Exception) {
                attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, true, pdfAttemptStatusFromMessage(e.message), error: pdfRedactProviderError(e.message, candidate)))
                continue
            }
        }

        var extractions: Array<GatewayPdfExtraction> = []
        try {
            extractions = match (extractionCache) {
                case Some(v) => v
                case None =>
                    let loaded = extractor()
                    extractionCache = Some(loaded)
                    loaded
            }
        } catch (e: Exception) {
            let safeError = pdfRedactProviderError(e.message, candidate)
            attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, false, "extractor_error", error: safeError))
            return pdfFailureResult(attempts, safeError)
        }

        let images = pdfExtractionImages(extractions)
        let hasImages = !images.isEmpty()
        let textContext = pdfExtractionTextContext(extractions)
        if (hasImages && !candidate.imageSupported) {
            if (textContext.isEmpty()) {
                let error = "model_does_not_support_images_and_pdf_has_no_extractable_text"
                attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, false, "unsupported_images", error: error))
                continue
            }
        }

        let includeImages = hasImages && candidate.imageSupported
        let messages = pdfBuildFallbackMessages(effectivePrompt, extractions, includeImages)
        try {
            let model = ModelManager.createChatModel(candidate.modelRef)
            let response = model.create(ChatRequest(messages, temperature: Some(0.0), maxTokens: Some(candidate.maxTokens)))
            let text = response.message.content.trimAscii()
            if (text.isEmpty()) {
                attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, false, "empty_response", error: "PDF model returned no text."))
                continue
            }
            let status = if (hasImages && !includeImages) { "ok_text_only_downgrade" } else { "ok" }
            let downgradeReason = if (status == "ok_text_only_downgrade") {
                "text-only fallback: discarded rendered page images because model does not support image input"
            } else {
                ""
            }
            attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, false, status, error: downgradeReason))
            return GatewayPdfPromptResult(
                true,
                text: text,
                provider: model.provider,
                model: model.fullName,
                native: false,
                attempts: attempts.toArray()
            )
        } catch (e: Exception) {
            attempts.add(GatewayPdfPromptAttempt(candidate.provider, candidate.model, candidate.source, false, pdfAttemptStatusFromMessage(e.message), error: pdfRedactProviderError(e.message, candidate)))
        }
    }

    pdfFailureResult(attempts, "")
}
