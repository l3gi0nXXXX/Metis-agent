package metis.core

import metis.core.config.MetisPaths

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.time.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.net.http.*

public class GatewayImageGenerationHttpResult {
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

private class ImageGenerationException <: Exception {
    public let status: String

    public init(status: String, message: String) {
        super(message)
        this.status = status
    }
}

private var imageGenerationOpenAiRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationDashScopeRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationGoogleRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationMiniMaxRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationFalRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationVydraRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationComfyRunnerOverride: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationDownloaderOverride: Option<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult> =
    None<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>
private var imageGenerationRunnerOverride: Option<(JsonObject, JsonObject) -> JsonObject> =
    None<(JsonObject, JsonObject) -> JsonObject>

public func setGatewayImageGenerationOpenAiRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationOpenAiRunnerOverride = runner
}

public func setGatewayImageGenerationDashScopeRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationDashScopeRunnerOverride = runner
}

public func setGatewayImageGenerationGoogleRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationGoogleRunnerOverride = runner
}

public func setGatewayImageGenerationMiniMaxRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationMiniMaxRunnerOverride = runner
}

public func setGatewayImageGenerationFalRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationFalRunnerOverride = runner
}

public func setGatewayImageGenerationVydraRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationVydraRunnerOverride = runner
}

public func setGatewayImageGenerationComfyRunnerForTest(runner: Option<(JsonObject, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationComfyRunnerOverride = runner
}

public func setGatewayImageGenerationDownloaderForTest(downloader: Option<(String, Int64, Int64, JsonObject) -> GatewayImageGenerationHttpResult>): Unit {
    imageGenerationDownloaderOverride = downloader
}

public func setGatewayImageGenerationRunnerForTest(runner: Option<(JsonObject, JsonObject) -> JsonObject>): Unit {
    imageGenerationRunnerOverride = runner
}

private func imageGenerationNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func imageGenerationDateBucket(): String {
    "${imageGenerationNowMs() / 86400000}"
}

private func imageGenerationString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func imageGenerationInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func imageGenerationBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func imageGenerationObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func imageGenerationStringArray(obj: JsonObject, key: String): Array<String> {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                let out = ArrayList<String>()
                for (item in arr.getItems()) {
                    try {
                        let text = item.asString().getValue().trimAscii()
                        if (!text.isEmpty()) {
                            out.add(text)
                        }
                    } catch (_: Exception) {
                        ()
                    }
                }
                out.toArray()
            } catch (_: Exception) {
                []
            }
        case None => []
    }
}

private func imageGenerationSecretString(obj: JsonObject, key: String): String {
    let raw = imageGenerationString(obj, key)
    if (raw.startsWith("$" + "{") && raw.endsWith("}") && raw.size > 3) {
        let envKey = raw[2..raw.size - 1].trimAscii()
        if (!envKey.isEmpty()) {
            return getVariable(envKey) ?? ""
        }
    }
    raw
}

private func imageGenerationProviderConfig(config: JsonObject, provider: String): JsonObject {
    if (provider.isEmpty()) {
        return JsonObject()
    }
    let providers = imageGenerationObject(config, "providers")
    match (providers.get(provider)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func imageGenerationProviderKind(provider: String, providerConfig: JsonObject): String {
    if (provider.isEmpty()) {
        return "missing"
    }
    let explicit = imageGenerationString(providerConfig, "kind").toAsciiLower()
    match (explicit) {
        case "openai" => "openai-images"
        case "openai-compatible" => "openai-images"
        case "openai-compatible-images" => "openai-images"
        case "openai-qwen-image" => "openai-images"
        case "qwen-openai-image" => "openai-images"
        case "openai-image-generation" => "openai-images"
        case "openai-images" => "openai-images"
        case "dashscope-qwen-image" => "dashscope-qwen-image-generation"
        case "qwen-image" => "dashscope-qwen-image-generation"
        case "dashscope-qwen-image-generation" => "dashscope-qwen-image-generation"
        case "google" => "google-gemini-image"
        case "gemini-image" => "google-gemini-image"
        case "google-gemini-image" => "google-gemini-image"
        case "minimax" => "minimax-image"
        case "minimax-image" => "minimax-image"
        case "fal" => "fal-image"
        case "fal-image" => "fal-image"
        case "vydra" => "vydra-image"
        case "vydra-image" => "vydra-image"
        case "comfy" => "comfy-image"
        case "comfy-image" => "comfy-image"
        case "fake" => "fake-image-generation"
        case "fake-image-generation" => "fake-image-generation"
        case _ => if (!explicit.isEmpty()) { explicit } else { "missing" }
    }
}

private func imageGenerationStatus(status: String, ok!: Bool = false, message!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("status", JsonString(status))
    out.put("images", JsonArray([]))
    out.put("attempts", JsonArray([]))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func imageGenerationAttempt(provider: String, providerKind: String, status: String, message: String): JsonObject {
    let out = JsonObject()
    out.put("provider", JsonString(provider))
    out.put("providerKind", JsonString(providerKind))
    out.put("status", JsonString(status))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func imageGenerationAttachAttempt(result: JsonObject, attempt: JsonObject): JsonObject {
    let attempts = JsonArray([])
    attempts.add(attempt)
    result.put("attempts", attempts)
    result
}

private func imageGenerationUrlPath(url: String): String {
    let withoutQuery = match (url.indexOf("?")) {
        case Some(i) => url[..i]
        case None => url
    }
    match (withoutQuery.indexOf("://")) {
        case Some(schemeEnd) =>
            let hostStart = schemeEnd + 3
            match (withoutQuery.indexOf("/", hostStart)) {
                case Some(pathStart) => withoutQuery[pathStart..]
                case None => "/"
            }
        case None => withoutQuery
    }
}

private func imageGenerationAttachDiagnostics(result: JsonObject, providerKind: String, submitRequest: JsonObject): Unit {
    let diagnostics = JsonObject()
    diagnostics.put("providerKind", JsonString(providerKind))
    let request = JsonObject()
    request.put("urlPath", JsonString(imageGenerationUrlPath(imageGenerationString(submitRequest, "url"))))
    request.put("timeoutMs", JsonInt(imageGenerationInt(submitRequest, "timeoutMs", 0)))
    diagnostics.put("request", request)
    diagnostics.put("transportRoute", imageGenerationObject(submitRequest, "transportRoute"))
    result.put("diagnostics", diagnostics)
}

private func imageGenerationDiagnosticBase(
    provider: String,
    providerKind: String,
    model: String,
    prompt: String,
    outputRoot: Path
): JsonObject {
    var meta = mediaDiagnosticProviderMeta(provider, providerKind: providerKind, model: model, capability: "image")
    meta.put("generationKind", JsonString("image"))
    meta.put("promptChars", JsonInt(Int64(prompt.size)))
    meta = mediaDiagnosticMergeMeta(meta, mediaDiagnosticPathMeta(outputRoot.toString()))
    meta
}

private func imageGenerationDiagnosticMetaForResult(base: JsonObject, result: JsonObject): JsonObject {
    let meta = mediaDiagnosticMergeMeta(base, JsonObject())
    let status = imageGenerationString(result, "status")
    if (!status.isEmpty()) {
        meta.put("status", JsonString(status))
    }
    match (result.get("ok")) {
        case Some(v) => meta.put("ok", v)
        case None => ()
    }
    let message = imageGenerationString(result, "message")
    if (!message.isEmpty()) {
        meta.put("reason", JsonString(message))
    }
    match (result.get("images")) {
        case Some(v) =>
            try {
                let images = v.asArray()
                meta.put("imageCount", JsonInt(Int64(images.size())))
                if (images.size() > 0) {
                    let first = images[0].asObject()
                    let fileName = imageGenerationString(first, "fileName")
                    if (!fileName.isEmpty()) {
                        meta.put("outputFileName", JsonString(fileName))
                    }
                    let path = imageGenerationString(first, "path")
                    if (!path.isEmpty()) {
                        meta.put("outputPathHash", JsonString(mediaDiagnosticPathMeta(path).get("pathHash").getOrThrow().asString().getValue()))
                    }
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    let diagnostics = imageGenerationObject(result, "diagnostics")
    let request = imageGenerationObject(diagnostics, "request")
    let urlPath = imageGenerationString(request, "urlPath")
    if (!urlPath.isEmpty()) {
        meta.put("urlPath", JsonString(urlPath))
    }
    let timeoutMs = imageGenerationInt(request, "timeoutMs", 0)
    if (timeoutMs > 0) {
        meta.put("timeoutMs", JsonInt(timeoutMs))
    }
    let route = imageGenerationObject(diagnostics, "transportRoute")
    if (route.size() > 0) {
        meta.put("transportRoute", route)
    }
    meta
}

private func imageGenerationEmitStarted(provider: String, providerKind: String, model: String, prompt: String, outputRoot: Path): JsonObject {
    let meta = imageGenerationDiagnosticBase(provider, providerKind, model, prompt, outputRoot)
    emitGatewayMediaDiagnostic("info", MediaDiagnosticEvent.mediaGenerationStarted, "image generation started", meta: meta)
    meta
}

private func imageGenerationEmitResult(base: JsonObject, result: JsonObject): JsonObject {
    let meta = imageGenerationDiagnosticMetaForResult(base, result)
    let ok = imageGenerationBool(result, "ok", false)
    emitGatewayMediaDiagnostic(
        if (ok) { "info" } else { "warn" },
        if (ok) { MediaDiagnosticEvent.mediaGenerationFinished } else { MediaDiagnosticEvent.mediaGenerationFailed },
        if (ok) { "image generation finished" } else { "image generation failed" },
        meta: meta
    )
    result
}

public func gatewayImageGenerationResolveOutputRoot(config: JsonObject): Path {
    let configured = imageGenerationString(config, "outputRoot")
    if (!configured.isEmpty()) {
        return Path(configured)
    }
    MetisPaths.homeRoot().join("gateway-image-generation").join(imageGenerationDateBucket())
}

private func imageGenerationPathAllowed(path: Path, config: JsonObject): Bool {
    let pathText = path.toString()
    if (pathText.isEmpty()) {
        return false
    }
    if (pathText.endsWith("metis.json") || pathText.contains("/.metis/metis.json")) {
        return false
    }
    for (root in imageGenerationStringArray(config, "allowedOutputRoots")) {
        let normalized = root.trimAscii()
        if (!normalized.isEmpty() && (pathText == normalized || pathText.startsWith("${normalized}/"))) {
            return true
        }
    }
    if (!imageGenerationString(config, "outputRoot").isEmpty()) {
        return false
    }
    let managedRoot = MetisPaths.homeRoot().join("gateway-image-generation").toString()
    if (pathText == managedRoot || pathText.startsWith("${managedRoot}/")) {
        return true
    }
    false
}

private func imageGenerationTrimBaseUrl(raw: String, fallback: String): String {
    var baseUrl = raw.trimAscii()
    if (baseUrl.isEmpty()) {
        baseUrl = fallback
    }
    while (baseUrl.endsWith("/") && baseUrl.size > 1) {
        baseUrl = baseUrl[..baseUrl.size - 1]
    }
    baseUrl
}

private func imageGenerationUrlOrigin(raw: String, fallback: String): String {
    let baseUrl = imageGenerationTrimBaseUrl(raw, fallback)
    match (baseUrl.indexOf("://")) {
        case Some(schemeEnd) =>
            let hostStart = schemeEnd + 3
            match (baseUrl.indexOf("/", hostStart)) {
                case Some(pathStart) => baseUrl[..pathStart]
                case None => baseUrl
            }
        case None => imageGenerationTrimBaseUrl(fallback, "")
    }
}

private func imageGenerationGoogleBaseUrl(providerConfig: JsonObject): String {
    let baseUrl = imageGenerationTrimBaseUrl(
        imageGenerationString(providerConfig, "baseUrl"),
        "https://generativelanguage.googleapis.com/v1beta"
    )
    let lowered = baseUrl.toAsciiLower()
    if (lowered == "https://generativelanguage.googleapis.com") {
        return "${baseUrl}/v1beta"
    }
    baseUrl
}

private func imageGenerationOpenAiEndpoint(providerConfig: JsonObject): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    "${imageGenerationTrimBaseUrl(imageGenerationString(providerConfig, "baseUrl"), "https://api.openai.com/v1")}/images/generations"
}

private func imageGenerationGoogleEndpoint(providerConfig: JsonObject, model: String): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    "${imageGenerationGoogleBaseUrl(providerConfig)}/models/${model}:generateContent"
}

private func imageGenerationMiniMaxEndpoint(providerConfig: JsonObject): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    "${imageGenerationUrlOrigin(imageGenerationString(providerConfig, "baseUrl"), "https://api.minimax.io")}/v1/image_generation"
}

private func imageGenerationFalEndpoint(providerConfig: JsonObject, model: String): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    "${imageGenerationTrimBaseUrl(imageGenerationString(providerConfig, "baseUrl"), "https://fal.run")}/${model}"
}

private func imageGenerationVydraBaseUrl(providerConfig: JsonObject): String {
    let raw = imageGenerationTrimBaseUrl(imageGenerationString(providerConfig, "baseUrl"), "https://www.vydra.ai/api/v1")
    let lowered = raw.toAsciiLower()
    if (lowered == "https://vydra.ai" || lowered == "https://www.vydra.ai") {
        return "https://www.vydra.ai/api/v1"
    }
    raw
}

private func imageGenerationVydraEndpoint(providerConfig: JsonObject, model: String): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    "${imageGenerationVydraBaseUrl(providerConfig)}/models/${model}"
}

private func imageGenerationComfyBaseUrl(providerConfig: JsonObject): String {
    let mode = imageGenerationString(providerConfig, "mode").toAsciiLower()
    let fallback = if (mode == "cloud") { "https://cloud.comfy.org" } else { "http://127.0.0.1:8188" }
    imageGenerationTrimBaseUrl(imageGenerationString(providerConfig, "baseUrl"), fallback)
}

private func imageGenerationComfySubmitEndpoint(providerConfig: JsonObject): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    let mode = imageGenerationString(providerConfig, "mode").toAsciiLower()
    if (mode == "cloud") {
        return "${imageGenerationComfyBaseUrl(providerConfig)}/api/prompt"
    }
    "${imageGenerationComfyBaseUrl(providerConfig)}/prompt"
}

private func imageGenerationComfyPollEndpoint(providerConfig: JsonObject, promptId: String): String {
    let pollEndpoint = imageGenerationString(providerConfig, "pollEndpoint")
    if (!pollEndpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(pollEndpoint, "")
    }
    let mode = imageGenerationString(providerConfig, "mode").toAsciiLower()
    if (mode == "cloud") {
        return "${imageGenerationComfyBaseUrl(providerConfig)}/api/job/${promptId}/status"
    }
    "${imageGenerationComfyBaseUrl(providerConfig)}/history/${promptId}"
}

private func imageGenerationDashScopeEndpoint(providerConfig: JsonObject): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return imageGenerationTrimBaseUrl(endpoint, "")
    }
    let suffix = "/services/aigc/multimodal-generation/generation"
    let baseUrl = resolveDashScopeAigcBaseUrlForImage(imageGenerationString(providerConfig, "baseUrl"))
    if (baseUrl.endsWith(suffix)) {
        return baseUrl
    }
    "${baseUrl}${suffix}"
}

private func imageGenerationAttachTransportRoute(request: JsonObject, providerConfig: JsonObject): Unit {
    let url = imageGenerationString(request, "url")
    if (url.isEmpty()) {
        return
    }
    let route = resolveGatewayProviderHttpRoute(url, resolveGatewayProviderHttpTransportConfig(providerConfig))
    let obj = JsonObject()
    obj.put("mode", JsonString(route.mode))
    obj.put("proxySource", JsonString(route.proxySource))
    obj.put("redactedProxy", JsonString(route.redactedProxy))
    obj.put("targetHost", JsonString(route.targetHost))
    if (!route.error.isEmpty()) {
        obj.put("error", JsonString(route.error))
    }
    request.put("transportRoute", obj)
}

private func imageGenerationOpenAiBody(providerConfig: JsonObject, request: JsonObject): JsonObject {
    let body = JsonObject()
    let modelOverride = imageGenerationString(request, "model")
    let model = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = imageGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "gpt-image-1" } else { configured }
    }
    body.put("model", JsonString(model))
    body.put("prompt", JsonString(imageGenerationString(request, "prompt")))
    let size = imageGenerationString(request, "size")
    if (!size.isEmpty()) {
        body.put("size", JsonString(size))
    }
    let count = imageGenerationInt(request, "count", 1)
    if (count > 0) {
        body.put("n", JsonInt(count))
    }
    let quality = imageGenerationString(request, "quality")
    if (!quality.isEmpty()) {
        body.put("quality", JsonString(quality))
    }
    body
}

private func imageGenerationOpenAiRequest(providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationOpenAiEndpoint(providerConfig)))
    req.put("authorization", JsonString("Bearer ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", imageGenerationOpenAiBody(providerConfig, request))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationGoogleBody(config: JsonObject, request: JsonObject): JsonObject {
    let parts = JsonArray([])
    let ref = imageGenerationReferenceImageBase64(config, request, true)
    if (!ref[0].isEmpty()) {
        let inlineData = JsonObject()
        inlineData.put("mimeType", JsonString(ref[1]))
        inlineData.put("data", JsonString(ref[0]))
        let imagePart = JsonObject()
        imagePart.put("inlineData", inlineData)
        parts.add(imagePart)
    }
    let text = JsonObject()
    text.put("text", JsonString(imageGenerationString(request, "prompt")))
    parts.add(text)
    let content = JsonObject()
    content.put("role", JsonString("user"))
    content.put("parts", parts)
    let contents = JsonArray([])
    contents.add(content)
    let body = JsonObject()
    body.put("contents", contents)
    let generationConfig = JsonObject()
    generationConfig.put("responseModalities", JsonArray([JsonString("TEXT"), JsonString("IMAGE")]))
    let aspectRatio = imageGenerationString(request, "aspectRatio")
    if (!aspectRatio.isEmpty()) {
        let imageConfig = JsonObject()
        imageConfig.put("aspectRatio", JsonString(aspectRatio))
        generationConfig.put("imageConfig", imageConfig)
    }
    body.put("generationConfig", generationConfig)
    body
}

private func imageGenerationGoogleRequest(config: JsonObject, providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let modelOverride = imageGenerationString(request, "model")
    let model = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = imageGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "gemini-3.1-flash-image-preview" } else { configured }
    }
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationGoogleEndpoint(providerConfig, model)))
    req.put("authorization", JsonString("Bearer ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", imageGenerationGoogleBody(config, request))
    req.put("model", JsonString(model))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationMiniMaxBody(config: JsonObject, providerConfig: JsonObject, request: JsonObject): JsonObject {
    let body = JsonObject()
    let modelOverride = imageGenerationString(request, "model")
    let model = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = imageGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "image-01" } else { configured }
    }
    body.put("model", JsonString(model))
    body.put("prompt", JsonString(imageGenerationString(request, "prompt")))
    body.put("response_format", JsonString("base64"))
    body.put("n", JsonInt(imageGenerationInt(request, "count", 1)))
    let aspectRatio = imageGenerationString(request, "aspectRatio")
    if (!aspectRatio.isEmpty()) {
        body.put("aspect_ratio", JsonString(aspectRatio))
    }
    let ref = imageGenerationReferenceImageBase64(config, request, true)
    if (!ref[0].isEmpty()) {
        let subject = JsonObject()
        subject.put("type", JsonString("base64"))
        subject.put("image_base64", JsonString(ref[0]))
        subject.put("mime_type", JsonString(ref[1]))
        let refs = JsonArray([])
        refs.add(subject)
        body.put("subject_reference", refs)
    }
    body
}

private func imageGenerationMiniMaxRequest(config: JsonObject, providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationMiniMaxEndpoint(providerConfig)))
    req.put("authorization", JsonString("Bearer ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", imageGenerationMiniMaxBody(config, providerConfig, request))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationFalBody(config: JsonObject, request: JsonObject): JsonObject {
    let body = JsonObject()
    body.put("prompt", JsonString(imageGenerationString(request, "prompt")))
    body.put("num_images", JsonInt(imageGenerationInt(request, "count", 1)))
    body.put("output_format", JsonString("png"))
    let size = imageGenerationString(request, "size")
    if (!size.isEmpty()) {
        body.put("image_size", JsonString(size))
    }
    let ref = imageGenerationReferenceImageDataUrl(config, request, true)
    if (!ref.isEmpty()) {
        body.put("image_url", JsonString(ref))
    }
    body
}

private func imageGenerationFalEditModel(model: String, request: JsonObject): String {
    if (imageGenerationString(request, "referenceImage").isEmpty()) {
        return model
    }
    if (model.contains("image-to-image")) {
        return model
    }
    "${model}/image-to-image"
}

private func imageGenerationFalRequest(config: JsonObject, providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let modelOverride = imageGenerationString(request, "model")
    let configuredModel = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = imageGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "fal-ai/flux/dev" } else { configured }
    }
    let model = imageGenerationFalEditModel(configuredModel, request)
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationFalEndpoint(providerConfig, model)))
    req.put("authorization", JsonString("Key ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", imageGenerationFalBody(config, request))
    req.put("model", JsonString(model))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationVydraRequest(providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let modelOverride = imageGenerationString(request, "model")
    let model = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = imageGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "grok-imagine" } else { configured }
    }
    let body = JsonObject()
    body.put("prompt", JsonString(imageGenerationString(request, "prompt")))
    body.put("model", JsonString("text-to-image"))
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationVydraEndpoint(providerConfig, model)))
    req.put("authorization", JsonString("Bearer ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", body)
    req.put("model", JsonString(model))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationComfyWorkflow(providerConfig: JsonObject): JsonObject {
    match (providerConfig.get("workflow")) {
        case Some(value) =>
            try { return value.asObject() } catch (_: Exception) { () }
        case None => ()
    }
    let workflowPath = imageGenerationString(providerConfig, "workflowPath")
    if (!workflowPath.isEmpty()) {
        return JsonValue.fromStr(String.fromUtf8(File.readFrom(Path(workflowPath)))).asObject()
    }
    JsonObject()
}

private func imageGenerationComfyRequest(providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let workflow = imageGenerationComfyWorkflow(providerConfig)
    if (workflow.size() == 0) {
        throw ImageGenerationException("not_configured", "Configured Comfy image generation provider requires workflow or workflowPath.")
    }
    let promptNodeId = imageGenerationString(providerConfig, "promptNodeId")
    if (promptNodeId.isEmpty()) {
        throw ImageGenerationException("not_configured", "Configured Comfy image generation provider requires promptNodeId.")
    }
    let body = JsonObject()
    body.put("prompt", workflow)
    body.put("promptText", JsonString(imageGenerationString(request, "prompt")))
    body.put("promptNodeId", JsonString(promptNodeId))
    let clientId = imageGenerationString(providerConfig, "clientId")
    if (!clientId.isEmpty()) {
        body.put("client_id", JsonString(clientId))
    }
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationComfySubmitEndpoint(providerConfig)))
    let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
    if (!apiKey.isEmpty()) {
        req.put("authorization", JsonString("Bearer ${apiKey}"))
    }
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", body)
    req.put("model", JsonString(imageGenerationString(providerConfig, "model")))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationDashScopeSize(request: JsonObject): String {
    let size = imageGenerationString(request, "size")
    if (size.isEmpty()) {
        return imageGenerationString(request, "dashScopeSize")
    }
    size.replace("x", "*").replace("X", "*")
}

private func imageGenerationDashScopeBody(providerConfig: JsonObject, request: JsonObject): JsonObject {
    let body = JsonObject()
    let modelOverride = imageGenerationString(request, "model")
    let model = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = imageGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "qwen-image-2.0-pro" } else { configured }
    }
    body.put("model", JsonString(model))

    let content = JsonArray([])
    let text = JsonObject()
    text.put("text", JsonString(imageGenerationString(request, "prompt")))
    content.add(text)
    let message = JsonObject()
    message.put("role", JsonString("user"))
    message.put("content", content)
    let messages = JsonArray([])
    messages.add(message)
    let input = JsonObject()
    input.put("messages", messages)
    body.put("input", input)

    let parameters = JsonObject()
    let count = imageGenerationInt(request, "count", 1)
    if (count > 0) {
        parameters.put("n", JsonInt(count))
    }
    let size = imageGenerationDashScopeSize(request)
    if (!size.isEmpty()) {
        parameters.put("size", JsonString(size))
    }
    let negativePrompt = imageGenerationString(request, "negativePrompt")
    if (!negativePrompt.isEmpty()) {
        parameters.put("negative_prompt", JsonString(negativePrompt))
    }
    if (request.get("promptExtend").isSome()) {
        parameters.put("prompt_extend", JsonBool(imageGenerationBool(request, "promptExtend", false)))
    }
    if (request.get("watermark").isSome()) {
        parameters.put("watermark", JsonBool(imageGenerationBool(request, "watermark", false)))
    }
    body.put("parameters", parameters)
    body
}

private func imageGenerationDashScopeRequest(providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationDashScopeEndpoint(providerConfig)))
    req.put("authorization", JsonString("Bearer ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("body", imageGenerationDashScopeBody(providerConfig, request))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func imageGenerationNativeSend(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    let url = imageGenerationString(request, "url")
    let headers = HashMap<String, String>()
    headers["Authorization"] = imageGenerationString(request, "authorization")
    headers["Accept"] = "application/json, */*"
    headers["Content-Type"] = "application/json"
    let clientParts = buildGatewayProviderHttpClientBuilder(url, resolveGatewayProviderHttpTransportConfig(providerConfig))
    let client = clientParts[0].build()
    try {
        let method = imageGenerationString(request, "method").toAsciiUpper()
        let reqBuilder = if (method == "GET") {
            HttpRequestBuilder().url(url).get()
        } else {
            HttpRequestBuilder().url(url).post().body(imageGenerationObject(request, "body").toJsonString())
        }
        for ((key, value) in headers) {
            if (!value.isEmpty()) {
                reqBuilder.header(key, value)
            }
        }
        let response = client.send(reqBuilder.build())
        let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
        GatewayImageGenerationHttpResult(Int64(response.status), bodyBytes: imageGenerationReadAllBytes(response), contentType: contentType)
    } finally {
        client.close()
    }
}

private func imageGenerationOpenAiSubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationOpenAiRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationDashScopeSubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationDashScopeRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationGoogleSubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationGoogleRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationMiniMaxSubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationMiniMaxRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationFalSubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationFalRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationVydraSubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationVydraRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationComfySubmit(request: JsonObject, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    match (imageGenerationComfyRunnerOverride) {
        case Some(runner) => runner(request, providerConfig)
        case None => imageGenerationNativeSend(request, providerConfig)
    }
}

private func imageGenerationSafeUrl(url: String): String {
    let trimmed = url.trimAscii()
    match (trimmed.indexOf("?")) {
        case Some(i) => trimmed[..i]
        case None => trimmed
    }
}

private func imageGenerationRedact(detail: String, providerConfig: JsonObject): String {
    var out = detail.trimAscii()
    let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
    if (!apiKey.isEmpty()) {
        out = out.replace(apiKey, "[redacted]")
    }
    match (out.indexOf("?")) {
        case Some(i) => out = out[..i]
        case None => ()
    }
    if (out.size > 300) {
        out = out[..300]
    }
    out
}

private func imageGenerationEnsureSuccess(result: GatewayImageGenerationHttpResult, providerConfig: JsonObject, context: String): Unit {
    if (result.statusCode >= 200 && result.statusCode < 300) {
        return
    }
    var detail = result.error.trimAscii()
    if (detail.isEmpty()) {
        try { detail = String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { detail = "" }
    }
    detail = imageGenerationRedact(detail, providerConfig)
    let message = if (detail.isEmpty()) { "${context} error (${result.statusCode})" } else { "${context} error (${result.statusCode}): ${detail}" }
    if (result.statusCode == 408) {
        throw ImageGenerationException("timeout", message)
    }
    if (result.statusCode == 413) {
        throw ImageGenerationException("too_large", message)
    }
    throw ImageGenerationException("provider_error", message)
}

private func imageGenerationBase64Value(ch: Byte): Int64 {
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

private func imageGenerationDecodeBase64(data: String): Array<Byte> {
    let out = ArrayList<Byte>()
    var buffer: Int64 = 0
    var bits: Int64 = 0
    for (ch in data.toArray()) {
        if (ch == UInt8(61)) {
            break
        }
        let value = imageGenerationBase64Value(ch)
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

private func imageGenerationNativeDownload(url: String, timeoutMs: Int64, maxBytes: Int64, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    let downloaded = gatewaySignedUrlDownload(url, timeoutMs, maxBytes, providerConfig)
    GatewayImageGenerationHttpResult(
        downloaded.statusCode,
        bodyBytes: downloaded.bodyBytes,
        error: downloaded.error,
        contentType: downloaded.contentType
    )
}

private func imageGenerationDownload(url: String, timeoutMs: Int64, maxBytes: Int64, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    let trimmed = url.trimAscii()
    if (!(trimmed.startsWith("https://") || trimmed.startsWith("http://"))) {
        throw ImageGenerationException("provider_error", "generated image URL is not http(s): ${imageGenerationSafeUrl(trimmed)}")
    }
    let request = JsonObject()
    request.put("url", JsonString(trimmed))
    request.put("timeoutMs", JsonInt(timeoutMs))
    let startedMeta = mediaDiagnosticHttpMetaFromRequest(request, method: "GET")
    startedMeta.put("generationKind", JsonString("image"))
    startedMeta.put("capability", JsonString("image"))
    if (maxBytes > 0) {
        startedMeta.put("limitBytes", JsonInt(maxBytes))
    }
    emitGatewayMediaDiagnostic("debug", MediaDiagnosticEvent.mediaGenerationDownload, "generated image download started", meta: startedMeta)
    let startedAtMs = imageGenerationNowMs()
    let result = match (imageGenerationDownloaderOverride) {
        case Some(downloader) => downloader(trimmed, timeoutMs, maxBytes, providerConfig)
        case None => imageGenerationNativeDownload(trimmed, timeoutMs, maxBytes, providerConfig)
    }
    if (result.statusCode >= 200 && result.statusCode < 300 && maxBytes > 0 && Int64(result.bodyBytes.size) > maxBytes) {
        let tooLarge = GatewayImageGenerationHttpResult(413, error: "downloaded image exceeds maxImageBytes")
        let failedMeta = mediaDiagnosticHttpMetaFromRequest(request, method: "GET", statusCode: tooLarge.statusCode, responseBytes: Int64(result.bodyBytes.size), elapsedMs: max(0, imageGenerationNowMs() - startedAtMs))
        failedMeta.put("generationKind", JsonString("image"))
        failedMeta.put("capability", JsonString("image"))
        failedMeta.put("status", JsonString("too_large"))
        failedMeta.put("reason", JsonString(tooLarge.error))
        emitGatewayMediaDiagnostic("warn", MediaDiagnosticEvent.mediaGenerationDownload, "generated image download failed", meta: failedMeta)
        return tooLarge
    }
    let finishedMeta = mediaDiagnosticHttpMetaFromRequest(
        request,
        method: "GET",
        statusCode: result.statusCode,
        contentType: result.contentType,
        responseBytes: Int64(result.bodyBytes.size),
        elapsedMs: max(0, imageGenerationNowMs() - startedAtMs)
    )
    finishedMeta.put("generationKind", JsonString("image"))
    finishedMeta.put("capability", JsonString("image"))
    finishedMeta.put("status", JsonString(if (result.statusCode >= 200 && result.statusCode < 300) { "ok" } else { "http_error" }))
    emitGatewayMediaDiagnostic(
        if (result.statusCode >= 200 && result.statusCode < 300) { "debug" } else { "warn" },
        MediaDiagnosticEvent.mediaGenerationDownload,
        if (result.statusCode >= 200 && result.statusCode < 300) { "generated image download finished" } else { "generated image download failed" },
        meta: finishedMeta
    )
    result
}

private func imageGenerationExtensionFromMimeOrUrl(mime: String, url: String): String {
    let lowMime = mime.toAsciiLower()
    if (lowMime.contains("jpeg") || lowMime.contains("jpg")) {
        return "jpg"
    }
    if (lowMime.contains("webp")) {
        return "webp"
    }
    if (lowMime.contains("gif")) {
        return "gif"
    }
    let safe = imageGenerationSafeUrl(url).toAsciiLower()
    if (safe.endsWith(".jpg") || safe.endsWith(".jpeg")) {
        return "jpg"
    }
    if (safe.endsWith(".webp")) {
        return "webp"
    }
    if (safe.endsWith(".gif")) {
        return "gif"
    }
    "png"
}

private func imageGenerationMimeFromExtension(extension: String, contentType: String): String {
    let trimmed = contentType.trimAscii()
    if (trimmed.startsWith("image/")) {
        return trimmed
    }
    match (extension) {
        case "jpg" => "image/jpeg"
        case "webp" => "image/webp"
        case "gif" => "image/gif"
        case _ => "image/png"
    }
}

private func imageGenerationMimeFromPath(path: Path): String {
    let lower = path.toString().toAsciiLower()
    if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) {
        return "image/jpeg"
    }
    if (lower.endsWith(".webp")) {
        return "image/webp"
    }
    if (lower.endsWith(".gif")) {
        return "image/gif"
    }
    "image/png"
}

private func imageGenerationReferenceImagePath(config: JsonObject, request: JsonObject, providerSupportsEdit: Bool): Option<Path> {
    let ref = imageGenerationString(request, "referenceImage")
    if (ref.isEmpty()) {
        return None<Path>
    }
    if (!providerSupportsEdit) {
        throw ImageGenerationException("provider_unsupported", "referenceImage was provided but the configured provider does not support image editing.")
    }
    let path = Path(ref)
    if (!exists(path)) {
        throw ImageGenerationException("invalid_request", "referenceImage does not exist.")
    }
    if (!imageGenerationPathAllowed(path, config)) {
        throw ImageGenerationException("write_denied", "referenceImage must be under an allowed Metis media/output root.")
    }
    Some(path)
}

private func imageGenerationReferenceImageDataUrl(config: JsonObject, request: JsonObject, providerSupportsEdit: Bool): String {
    match (imageGenerationReferenceImagePath(config, request, providerSupportsEdit)) {
        case Some(path) =>
            let mimeType = imageGenerationMimeFromPath(path)
            "data:${mimeType};base64,${toBase64String(File.readFrom(path))}"
        case None => ""
    }
}

private func imageGenerationReferenceImageBase64(config: JsonObject, request: JsonObject, providerSupportsEdit: Bool): (String, String) {
    match (imageGenerationReferenceImagePath(config, request, providerSupportsEdit)) {
        case Some(path) => (toBase64String(File.readFrom(path)), imageGenerationMimeFromPath(path))
        case None => ("", "")
    }
}

private func imageGenerationSanitizeFileName(raw: String, extension: String, index: Int64): String {
    var name = raw.trimAscii()
    if (name.isEmpty()) {
        return if (index <= 0) { "image-${imageGenerationNowMs()}.${extension}" } else { "image-${imageGenerationNowMs()}-${index}.${extension}" }
    }
    name = name.replace("/", "-").replace("\\", "-").replace(" ", "-").replace(":", "-")
    while (name.contains("--")) {
        name = name.replace("--", "-")
    }
    if (!(name.endsWith(".png") || name.endsWith(".jpg") || name.endsWith(".jpeg") || name.endsWith(".webp") || name.endsWith(".gif"))) {
        name = "${name}.${extension}"
    }
    if (index > 0) {
        let suffix = ".${extension}"
        if (name.endsWith(suffix)) {
            return "${name[..name.size - suffix.size]}-${index}${suffix}"
        }
    }
    name
}

private func imageGenerationFirstString(obj: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        let value = imageGenerationString(obj, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    ""
}

private func imageGenerationWriteAsset(outputRoot: Path, fileName: String, bytes: Array<Byte>, mimeType: String): JsonObject {
    if (!exists(outputRoot)) {
        Directory.create(outputRoot, recursive: true)
    }
    let outputPath = outputRoot.join(fileName)
    File.writeTo(outputPath, bytes)
    let image = JsonObject()
    image.put("path", JsonString(outputPath.toString()))
    image.put("mimeType", JsonString(mimeType))
    image.put("fileName", JsonString(fileName))
    image
}

private func imageGenerationImagesFromOpenAiResponse(bytes: Array<Byte>, providerConfig: JsonObject, request: JsonObject, outputRoot: Path): JsonArray {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let data = match (root.get("data")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    let images = JsonArray([])
    var index: Int64 = 0
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", 120000))
    let maxImageBytes = max(1, imageGenerationInt(providerConfig, "maxImageBytes", 25 * 1024 * 1024))
    for (item in data.getItems()) {
        let entry = try { item.asObject() } catch (_: Exception) { continue }
        var imageBytes: Array<Byte> = []
        var sourceUrl = ""
        var contentType = "image/png"
        let b64 = imageGenerationFirstString(entry, ["b64_json", "b64Json", "base64"])
        if (!b64.isEmpty()) {
            imageBytes = imageGenerationDecodeBase64(b64)
        } else {
            sourceUrl = imageGenerationFirstString(entry, ["url", "image_url", "imageUrl"])
            if (!sourceUrl.isEmpty()) {
                let download = imageGenerationDownload(sourceUrl, timeoutMs, maxImageBytes, providerConfig)
                imageGenerationEnsureSuccess(download, providerConfig, "generated image download")
                imageBytes = download.bodyBytes
                contentType = download.contentType
            }
        }
        if (imageBytes.isEmpty()) {
            continue
        }
        if (maxImageBytes > 0 && Int64(imageBytes.size) > maxImageBytes) {
            throw ImageGenerationException("too_large", "generated image exceeds maxImageBytes")
        }
        let extension = imageGenerationExtensionFromMimeOrUrl(contentType, sourceUrl)
        let mimeType = imageGenerationMimeFromExtension(extension, contentType)
        let fileName = imageGenerationSanitizeFileName(imageGenerationString(request, "filename"), extension, index)
        images.add(imageGenerationWriteAsset(outputRoot, fileName, imageBytes, mimeType))
        index += 1
    }
    images
}

private func imageGenerationAddDashScopeImageUrl(urls: ArrayList<String>, url: String): Unit {
    let trimmed = url.trimAscii()
    if (!trimmed.isEmpty()) {
        urls.add(trimmed)
    }
}

private func imageGenerationCollectDashScopeContentUrls(urls: ArrayList<String>, content: JsonArray): Unit {
    for (item in content.getItems()) {
        let entry = try { item.asObject() } catch (_: Exception) { continue }
        imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(entry, ["image", "url", "image_url", "imageUrl"]))
    }
}

private func imageGenerationDashScopeImageUrls(bytes: Array<Byte>): Array<String> {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let urls = ArrayList<String>()
    let output = imageGenerationObject(root, "output")
    let choices = match (output.get("choices")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    for (choice in choices.getItems()) {
        let choiceObj = try { choice.asObject() } catch (_: Exception) { continue }
        let message = imageGenerationObject(choiceObj, "message")
        let content = match (message.get("content")) {
            case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
            case None => JsonArray([])
        }
        imageGenerationCollectDashScopeContentUrls(urls, content)
    }
    let images = match (output.get("images")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    for (item in images.getItems()) {
        try {
            imageGenerationAddDashScopeImageUrl(urls, item.asString().getValue())
        } catch (_: Exception) {
            let obj = try { item.asObject() } catch (_inner: Exception) { JsonObject() }
            imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(obj, ["image", "url", "image_url", "imageUrl"]))
        }
    }
    urls.toArray()
}

private func imageGenerationImagesFromDashScopeResponse(bytes: Array<Byte>, providerConfig: JsonObject, request: JsonObject, outputRoot: Path): JsonArray {
    let images = JsonArray([])
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", 120000))
    let maxImageBytes = max(1, imageGenerationInt(providerConfig, "maxImageBytes", 25 * 1024 * 1024))
    var index: Int64 = 0
    for (sourceUrl in imageGenerationDashScopeImageUrls(bytes)) {
        let download = imageGenerationDownload(sourceUrl, timeoutMs, maxImageBytes, providerConfig)
        imageGenerationEnsureSuccess(download, providerConfig, "DashScope generated image download")
        let extension = imageGenerationExtensionFromMimeOrUrl(download.contentType, sourceUrl)
        let mimeType = imageGenerationMimeFromExtension(extension, download.contentType)
        let fileName = imageGenerationSanitizeFileName(imageGenerationString(request, "filename"), extension, index)
        images.add(imageGenerationWriteAsset(outputRoot, fileName, download.bodyBytes, mimeType))
        index += 1
    }
    images
}

private func imageGenerationAddInlineImage(images: JsonArray, outputRoot: Path, request: JsonObject, data: String, mimeType: String, index: Int64): Bool {
    let imageBytes = imageGenerationDecodeBase64(data)
    if (imageBytes.isEmpty()) {
        return false
    }
    let extension = imageGenerationExtensionFromMimeOrUrl(mimeType, "")
    let fileName = imageGenerationSanitizeFileName(imageGenerationString(request, "filename"), extension, index)
    images.add(imageGenerationWriteAsset(outputRoot, fileName, imageBytes, imageGenerationMimeFromExtension(extension, mimeType)))
    true
}

private func imageGenerationImagesFromGoogleResponse(bytes: Array<Byte>, _providerConfig: JsonObject, request: JsonObject, outputRoot: Path): JsonArray {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let candidates = match (root.get("candidates")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    let images = JsonArray([])
    var index: Int64 = 0
    for (candidate in candidates.getItems()) {
        let candidateObj = try { candidate.asObject() } catch (_: Exception) { continue }
        let content = imageGenerationObject(candidateObj, "content")
        let parts = match (content.get("parts")) {
            case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
            case None => JsonArray([])
        }
        for (partValue in parts.getItems()) {
            let part = try { partValue.asObject() } catch (_: Exception) { continue }
            var inline = imageGenerationObject(part, "inlineData")
            if (inline.size() == 0) {
                inline = imageGenerationObject(part, "inline_data")
            }
            let data = imageGenerationString(inline, "data")
            if (data.isEmpty()) {
                continue
            }
            var mimeType = imageGenerationString(inline, "mimeType")
            if (mimeType.isEmpty()) {
                mimeType = imageGenerationString(inline, "mime_type")
            }
            if (mimeType.isEmpty()) {
                mimeType = "image/png"
            }
            if (imageGenerationAddInlineImage(images, outputRoot, request, data, mimeType, index)) {
                index += 1
            }
        }
    }
    images
}

private func imageGenerationImagesFromMiniMaxResponse(bytes: Array<Byte>, _providerConfig: JsonObject, request: JsonObject, outputRoot: Path): JsonArray {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let baseResp = imageGenerationObject(root, "base_resp")
    let statusCode = imageGenerationInt(baseResp, "status_code", 0)
    if (statusCode != 0) {
        let statusMsg = imageGenerationString(baseResp, "status_msg")
        throw ImageGenerationException("provider_error", "MiniMax image generation API error (${statusCode}): ${statusMsg}")
    }
    let dataObj = imageGenerationObject(root, "data")
    let values = match (dataObj.get("image_base64")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    let images = JsonArray([])
    var index: Int64 = 0
    for (item in values.getItems()) {
        let data = try { item.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        if (imageGenerationAddInlineImage(images, outputRoot, request, data, "image/png", index)) {
            index += 1
        }
    }
    images
}

private func imageGenerationFalImageUrls(bytes: Array<Byte>): Array<String> {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let urls = ArrayList<String>()
    let images = match (root.get("images")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    for (item in images.getItems()) {
        let entry = try { item.asObject() } catch (_: Exception) { continue }
        imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(entry, ["url", "image_url", "imageUrl"]))
    }
    urls.toArray()
}

private func imageGenerationImagesFromUrlList(urls: Array<String>, providerConfig: JsonObject, request: JsonObject, outputRoot: Path, context: String): JsonArray {
    let images = JsonArray([])
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", 120000))
    let maxImageBytes = max(1, imageGenerationInt(providerConfig, "maxImageBytes", 25 * 1024 * 1024))
    var index: Int64 = 0
    for (sourceUrl in urls) {
        let download = imageGenerationDownload(sourceUrl, timeoutMs, maxImageBytes, providerConfig)
        imageGenerationEnsureSuccess(download, providerConfig, context)
        let extension = imageGenerationExtensionFromMimeOrUrl(download.contentType, sourceUrl)
        let mimeType = imageGenerationMimeFromExtension(extension, download.contentType)
        let fileName = imageGenerationSanitizeFileName(imageGenerationString(request, "filename"), extension, index)
        images.add(imageGenerationWriteAsset(outputRoot, fileName, download.bodyBytes, mimeType))
        index += 1
    }
    images
}

private func imageGenerationVydraImageUrls(bytes: Array<Byte>): Array<String> {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let urls = ArrayList<String>()
    imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(root, ["imageUrl", "image_url", "resultUrl", "result_url", "url"]))
    let dataObj = imageGenerationObject(root, "data")
    imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(dataObj, ["imageUrl", "image_url", "resultUrl", "result_url", "url"]))
    urls.toArray()
}

private func imageGenerationVydraJobId(bytes: Array<Byte>): String {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let direct = imageGenerationFirstString(root, ["jobId", "job_id", "id", "taskId", "task_id"])
    if (!direct.isEmpty()) {
        return direct
    }
    imageGenerationFirstString(imageGenerationObject(root, "data"), ["jobId", "job_id", "id", "taskId", "task_id"])
}

private func imageGenerationVydraFailureMessage(bytes: Array<Byte>): String {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let status = imageGenerationFirstString(root, ["status", "state"]).toAsciiLower()
    if (status == "failed" || status == "error" || status == "cancelled" || status == "canceled") {
        let message = imageGenerationFirstString(root, ["error", "message", "status_msg", "statusMessage"])
        return if (message.isEmpty()) { "Vydra image generation job ${status}." } else { "Vydra image generation job ${status}: ${message}" }
    }
    let data = imageGenerationObject(root, "data")
    let dataStatus = imageGenerationFirstString(data, ["status", "state"]).toAsciiLower()
    if (dataStatus == "failed" || dataStatus == "error" || dataStatus == "cancelled" || dataStatus == "canceled") {
        let message = imageGenerationFirstString(data, ["error", "message", "status_msg", "statusMessage"])
        return if (message.isEmpty()) { "Vydra image generation job ${dataStatus}." } else { "Vydra image generation job ${dataStatus}: ${message}" }
    }
    ""
}

private func imageGenerationVydraPollRequest(providerConfig: JsonObject, jobId: String, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString("${imageGenerationVydraBaseUrl(providerConfig)}/jobs/${jobId}"))
    req.put("method", JsonString("GET"))
    req.put("authorization", JsonString("Bearer ${imageGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationVydraPollUrls(jobId: String, providerConfig: JsonObject, timeoutMs: Int64): Array<String> {
    let maxPolls = max(1, imageGenerationInt(providerConfig, "pollMaxAttempts", 20))
    let pollIntervalMs = max(0, imageGenerationInt(providerConfig, "pollIntervalMs", 1000))
    for (i in 0..maxPolls) {
        if (i > 0 && pollIntervalMs > 0) {
            sleep(Duration.millisecond * pollIntervalMs)
        }
        let pollRequest = imageGenerationVydraPollRequest(providerConfig, jobId, timeoutMs)
        let pollResult = imageGenerationVydraSubmit(pollRequest, providerConfig)
        imageGenerationEnsureSuccess(pollResult, providerConfig, "Vydra image generation poll")
        let failure = imageGenerationVydraFailureMessage(pollResult.bodyBytes)
        if (!failure.isEmpty()) {
            throw ImageGenerationException("provider_error", failure)
        }
        let urls = imageGenerationVydraImageUrls(pollResult.bodyBytes)
        if (urls.size > 0) {
            return urls
        }
    }
    throw ImageGenerationException("timeout", "Vydra image generation job timed out before an image URL was available.")
}

private func imageGenerationComfyPromptId(bytes: Array<Byte>): String {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    imageGenerationFirstString(root, ["prompt_id", "promptId", "jobId", "job_id", "id"])
}

private func imageGenerationComfyFailureMessage(bytes: Array<Byte>): String {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let statusObj = imageGenerationObject(root, "status")
    var status = imageGenerationFirstString(root, ["status", "state"]).toAsciiLower()
    if (status.isEmpty()) {
        status = imageGenerationFirstString(statusObj, ["status_str", "status", "state"]).toAsciiLower()
    }
    if (status == "failed" || status == "error" || status == "cancelled" || status == "canceled") {
        let message = imageGenerationFirstString(root, ["error", "message"])
        return if (message.isEmpty()) { "Comfy image generation job ${status}." } else { "Comfy image generation job ${status}: ${message}" }
    }
    ""
}

private func imageGenerationComfyImageUrls(bytes: Array<Byte>): Array<String> {
    let raw = String.fromUtf8(bytes).trimAscii()
    let root = JsonValue.fromStr(raw).asObject()
    let urls = ArrayList<String>()
    imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(root, ["imageUrl", "image_url", "resultUrl", "result_url", "url"]))
    let images = match (root.get("images")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
    for (item in images.getItems()) {
        let entry = try { item.asObject() } catch (_: Exception) { continue }
        imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(entry, ["url", "image_url", "imageUrl"]))
    }
    let dataObj = imageGenerationObject(root, "data")
    imageGenerationAddDashScopeImageUrl(urls, imageGenerationFirstString(dataObj, ["imageUrl", "image_url", "resultUrl", "result_url", "url"]))
    urls.toArray()
}

private func imageGenerationComfyPollRequest(providerConfig: JsonObject, promptId: String, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString(imageGenerationComfyPollEndpoint(providerConfig, promptId)))
    req.put("method", JsonString("GET"))
    let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
    if (!apiKey.isEmpty()) {
        req.put("authorization", JsonString("Bearer ${apiKey}"))
    }
    req.put("timeoutMs", JsonInt(timeoutMs))
    imageGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func imageGenerationComfyPollUrls(promptId: String, providerConfig: JsonObject, timeoutMs: Int64): Array<String> {
    let maxPolls = max(1, imageGenerationInt(providerConfig, "pollMaxAttempts", 20))
    let pollIntervalMs = max(0, imageGenerationInt(providerConfig, "pollIntervalMs", 1000))
    for (i in 0..maxPolls) {
        if (i > 0 && pollIntervalMs > 0) {
            sleep(Duration.millisecond * pollIntervalMs)
        }
        let pollRequest = imageGenerationComfyPollRequest(providerConfig, promptId, timeoutMs)
        let pollResult = imageGenerationComfySubmit(pollRequest, providerConfig)
        imageGenerationEnsureSuccess(pollResult, providerConfig, "Comfy image generation poll")
        let failure = imageGenerationComfyFailureMessage(pollResult.bodyBytes)
        if (!failure.isEmpty()) {
            throw ImageGenerationException("provider_error", failure)
        }
        let urls = imageGenerationComfyImageUrls(pollResult.bodyBytes)
        if (urls.size > 0) {
            return urls
        }
    }
    throw ImageGenerationException("timeout", "Comfy image generation job timed out before an image URL was available.")
}

private func imageGenerationValidateReferenceImage(config: JsonObject, request: JsonObject, providerSupportsEdit: Bool): Unit {
    match (imageGenerationReferenceImagePath(config, request, providerSupportsEdit)) {
        case Some(_) => ()
        case None => ()
    }
}

private func imageGenerationDashScopeGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    let submitRequest = imageGenerationDashScopeRequest(providerConfig, request, timeoutMs)
    let model = imageGenerationString(imageGenerationObject(submitRequest, "body"), "model")
    try {
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        imageGenerationValidateReferenceImage(config, request, false)
        if (!imageGenerationString(request, "referenceImage").isEmpty()) {
            throw ImageGenerationException("provider_unsupported", "referenceImage editing is not implemented for dashscope-qwen-image-generation provider.")
        }
        let submitResult = imageGenerationDashScopeSubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "DashScope image generation")
        let images = imageGenerationImagesFromDashScopeResponse(submitResult.bodyBytes, providerConfig, request, outputRoot)
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "DashScope image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

private func imageGenerationOpenAiGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    let submitRequest = imageGenerationOpenAiRequest(providerConfig, request, timeoutMs)
    let model = imageGenerationString(imageGenerationObject(submitRequest, "body"), "model")
    try {
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        imageGenerationValidateReferenceImage(config, request, false)
        if (!imageGenerationString(request, "referenceImage").isEmpty()) {
            throw ImageGenerationException("provider_unsupported", "referenceImage editing is not implemented for ${providerKind} provider.")
        }
        let submitResult = imageGenerationOpenAiSubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "OpenAI image generation")
        let images = imageGenerationImagesFromOpenAiResponse(submitResult.bodyBytes, providerConfig, request, outputRoot)
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "OpenAI image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

private func imageGenerationGoogleGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    var submitRequest = JsonObject()
    var model = ""
    try {
        imageGenerationValidateReferenceImage(config, request, true)
        submitRequest = imageGenerationGoogleRequest(config, providerConfig, request, timeoutMs)
        model = imageGenerationString(submitRequest, "model")
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        let submitResult = imageGenerationGoogleSubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "Google image generation")
        let images = imageGenerationImagesFromGoogleResponse(submitResult.bodyBytes, providerConfig, request, outputRoot)
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "Google image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

private func imageGenerationMiniMaxGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    var submitRequest = JsonObject()
    var model = ""
    try {
        imageGenerationValidateReferenceImage(config, request, true)
        submitRequest = imageGenerationMiniMaxRequest(config, providerConfig, request, timeoutMs)
        model = imageGenerationString(imageGenerationObject(submitRequest, "body"), "model")
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        let submitResult = imageGenerationMiniMaxSubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "MiniMax image generation")
        let images = imageGenerationImagesFromMiniMaxResponse(submitResult.bodyBytes, providerConfig, request, outputRoot)
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "MiniMax image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

private func imageGenerationFalGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    var submitRequest = JsonObject()
    var model = ""
    try {
        imageGenerationValidateReferenceImage(config, request, true)
        submitRequest = imageGenerationFalRequest(config, providerConfig, request, timeoutMs)
        model = imageGenerationString(submitRequest, "model")
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        let submitResult = imageGenerationFalSubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "fal image generation")
        let images = imageGenerationImagesFromUrlList(imageGenerationFalImageUrls(submitResult.bodyBytes), providerConfig, request, outputRoot, "fal generated image download")
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "fal image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

private func imageGenerationVydraGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    let submitRequest = imageGenerationVydraRequest(providerConfig, request, timeoutMs)
    let model = imageGenerationString(submitRequest, "model")
    try {
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        imageGenerationValidateReferenceImage(config, request, false)
        let submitResult = imageGenerationVydraSubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "Vydra image generation")
        var urls = imageGenerationVydraImageUrls(submitResult.bodyBytes)
        if (urls.size == 0) {
            let jobId = imageGenerationVydraJobId(submitResult.bodyBytes)
            if (!jobId.isEmpty()) {
                urls = imageGenerationVydraPollUrls(jobId, providerConfig, timeoutMs)
            }
        }
        let images = imageGenerationImagesFromUrlList(urls, providerConfig, request, outputRoot, "Vydra generated image download")
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "Vydra image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

private func imageGenerationComfyGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, imageGenerationInt(providerConfig, "timeoutMs", imageGenerationInt(config, "timeoutMs", 120000)))
    var submitRequest = JsonObject()
    var model = imageGenerationString(providerConfig, "model")
    try {
        imageGenerationValidateReferenceImage(config, request, false)
        submitRequest = imageGenerationComfyRequest(providerConfig, request, timeoutMs)
        let route = imageGenerationObject(submitRequest, "transportRoute")
        let routeError = imageGenerationString(route, "error")
        if (!routeError.isEmpty()) {
            throw ImageGenerationException("provider_error", routeError)
        }
        let submitResult = imageGenerationComfySubmit(submitRequest, providerConfig)
        imageGenerationEnsureSuccess(submitResult, providerConfig, "Comfy image generation submit")
        let promptId = imageGenerationComfyPromptId(submitResult.bodyBytes)
        var urls = imageGenerationComfyImageUrls(submitResult.bodyBytes)
        if (urls.size == 0 && !promptId.isEmpty()) {
            urls = imageGenerationComfyPollUrls(promptId, providerConfig, timeoutMs)
        }
        let images = imageGenerationImagesFromUrlList(urls, providerConfig, request, outputRoot, "Comfy generated image download")
        if (images.size() == 0) {
            throw ImageGenerationException("empty_result", "Comfy image generation returned no images.")
        }
        let out = imageGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("images", images)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: ImageGenerationException) {
        let out = imageGenerationStatus(e.status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        imageGenerationAttachDiagnostics(out, providerKind, submitRequest)
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, status, imageGenerationRedact(e.message, providerConfig)))
    }
}

public func gatewayImageGenerationGenerate(config: JsonObject, request: JsonObject): JsonObject {
    if (!imageGenerationBool(config, "enabled", true)) {
        return imageGenerationStatus("disabled", ok: false, message: "Gateway image generation is disabled.")
    }
    let prompt = imageGenerationString(request, "prompt")
    if (prompt.isEmpty()) {
        return imageGenerationStatus("invalid_request", ok: false, message: "image generation prompt is required.")
    }
    let maxPromptChars = imageGenerationInt(config, "maxPromptChars", 4000)
    if (maxPromptChars > 0 && Int64(prompt.size) > maxPromptChars) {
        let out = imageGenerationStatus("invalid_request", ok: false, message: "image generation prompt exceeds maxPromptChars.")
        out.put("maxPromptChars", JsonInt(maxPromptChars))
        return out
    }
    let count = imageGenerationInt(request, "count", 1)
    let maxCount = imageGenerationInt(config, "maxCount", 4)
    if (count <= 0 || (maxCount > 0 && count > maxCount)) {
        let out = imageGenerationStatus("invalid_request", ok: false, message: "image generation count is outside allowed range.")
        out.put("maxCount", JsonInt(maxCount))
        return out
    }
    let provider = imageGenerationString(config, "provider")
    if (provider.isEmpty()) {
        return imageGenerationStatus("not_configured", ok: false, message: "image generation provider is not configured")
    }
    let providerConfig = imageGenerationProviderConfig(config, provider)
    let providerKind = imageGenerationProviderKind(provider, providerConfig)
    let outputRoot = gatewayImageGenerationResolveOutputRoot(config)
    let diagnosticBase = imageGenerationEmitStarted(provider, providerKind, imageGenerationString(providerConfig, "model"), prompt, outputRoot)
    emitGatewayMediaDiagnostic("debug", MediaDiagnosticEvent.mediaGenerationAttempt, "image generation provider selected", meta: diagnosticBase)
    if (!imageGenerationPathAllowed(outputRoot, config)) {
        let out = imageGenerationStatus("invalid_request", ok: false, message: "image generation outputRoot is not under an allowed managed root.")
        out.put("outputRoot", JsonString(outputRoot.toString()))
        return imageGenerationEmitResult(diagnosticBase, out)
    }
    match (imageGenerationRunnerOverride) {
        case Some(runner) =>
            let result = runner(config, request)
            if (result.get("ok").isNone()) {
                result.put("ok", JsonBool(imageGenerationString(result, "status") == "ok"))
            }
            if (result.get("provider").isNone()) {
                result.put("provider", JsonString(provider))
            }
            if (result.get("providerKind").isNone()) {
                result.put("providerKind", JsonString(providerKind))
            }
            if (result.get("model").isNone()) {
                result.put("model", JsonString(imageGenerationString(providerConfig, "model")))
            }
            result.put("outputRoot", JsonString(outputRoot.toString()))
            return imageGenerationEmitResult(diagnosticBase, result)
        case None => ()
    }
    if (providerKind == "openai-images") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured OpenAI image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return imageGenerationEmitResult(diagnosticBase, out)
        }
        return imageGenerationEmitResult(diagnosticBase, imageGenerationOpenAiGenerate(config, request, provider, providerKind, providerConfig, outputRoot))
    }
    if (providerKind == "dashscope-qwen-image-generation") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured DashScope image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        }
        return imageGenerationDashScopeGenerate(config, request, provider, providerKind, providerConfig, outputRoot)
    }
    if (providerKind == "google-gemini-image") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured Google image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return imageGenerationEmitResult(diagnosticBase, out)
        }
        return imageGenerationEmitResult(diagnosticBase, imageGenerationGoogleGenerate(config, request, provider, providerKind, providerConfig, outputRoot))
    }
    if (providerKind == "minimax-image") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured MiniMax image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return imageGenerationEmitResult(diagnosticBase, out)
        }
        return imageGenerationEmitResult(diagnosticBase, imageGenerationMiniMaxGenerate(config, request, provider, providerKind, providerConfig, outputRoot))
    }
    if (providerKind == "fal-image") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured fal image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return imageGenerationEmitResult(diagnosticBase, out)
        }
        return imageGenerationEmitResult(diagnosticBase, imageGenerationFalGenerate(config, request, provider, providerKind, providerConfig, outputRoot))
    }
    if (providerKind == "vydra-image") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured Vydra image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return imageGenerationEmitResult(diagnosticBase, out)
        }
        return imageGenerationEmitResult(diagnosticBase, imageGenerationVydraGenerate(config, request, provider, providerKind, providerConfig, outputRoot))
    }
    if (providerKind == "comfy-image") {
        return imageGenerationEmitResult(diagnosticBase, imageGenerationComfyGenerate(config, request, provider, providerKind, providerConfig, outputRoot))
    }
    let out = imageGenerationStatus("unsupported_provider_kind", ok: false, message: "Configured image generation provider '${provider}' has unsupported kind '${providerKind}'.")
    out.put("provider", JsonString(provider))
    out.put("providerKind", JsonString(providerKind))
    imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, "unsupported_provider_kind", imageGenerationString(out, "message")))
    imageGenerationEmitResult(diagnosticBase, out)
}

public func gatewayImageGenerationOutputRoot(config: JsonObject): String {
    gatewayImageGenerationResolveOutputRoot(config).toString()
}
