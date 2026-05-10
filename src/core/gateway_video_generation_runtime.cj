package metis.core

import metis.core.config.MetisPaths

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public class GatewayVideoGenerationDashScopeHttpResult {
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

private class VideoGenerationException <: Exception {
    public let status: String

    public init(status: String, message: String) {
        super(message)
        this.status = status
    }
}

private var videoGenerationDashScopeRunnerOverride: Option<(JsonObject) -> GatewayVideoGenerationDashScopeHttpResult> =
    None<(JsonObject) -> GatewayVideoGenerationDashScopeHttpResult>
private var videoGenerationDashScopePollerOverride: Option<(JsonObject) -> GatewayVideoGenerationDashScopeHttpResult> =
    None<(JsonObject) -> GatewayVideoGenerationDashScopeHttpResult>
private var videoGenerationDashScopeDownloaderOverride: Option<(String, Int64, Int64, JsonObject) -> GatewayVideoGenerationDashScopeHttpResult> =
    None<(String, Int64, Int64, JsonObject) -> GatewayVideoGenerationDashScopeHttpResult>
private var videoGenerationRunnerOverride: Option<(JsonObject, JsonObject) -> JsonObject> =
    None<(JsonObject, JsonObject) -> JsonObject>

public func setGatewayVideoGenerationDashScopeRunnerForTest(runner: Option<(JsonObject) -> GatewayVideoGenerationDashScopeHttpResult>): Unit {
    videoGenerationDashScopeRunnerOverride = runner
}

public func setGatewayVideoGenerationDashScopePollerForTest(poller: Option<(JsonObject) -> GatewayVideoGenerationDashScopeHttpResult>): Unit {
    videoGenerationDashScopePollerOverride = poller
}

public func setGatewayVideoGenerationDashScopeDownloaderForTest(downloader: Option<(String, Int64, Int64, JsonObject) -> GatewayVideoGenerationDashScopeHttpResult>): Unit {
    videoGenerationDashScopeDownloaderOverride = downloader
}

public func setGatewayVideoGenerationRunnerForTest(runner: Option<(JsonObject, JsonObject) -> JsonObject>): Unit {
    videoGenerationRunnerOverride = runner
}

private func videoGenerationNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func videoGenerationDateBucket(): String {
    let millis = videoGenerationNowMs()
    // Stable enough for managed directory partitioning without relying on locale formatting APIs.
    "${millis / 86400000}"
}

private func videoGenerationString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func videoGenerationInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func videoGenerationBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func videoGenerationObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func videoGenerationStringArray(obj: JsonObject, key: String): Array<String> {
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

private func videoGenerationSecretString(obj: JsonObject, key: String): String {
    let raw = videoGenerationString(obj, key)
    if (raw.startsWith("$" + "{") && raw.endsWith("}") && raw.size > 3) {
        let envKey = raw[2..raw.size - 1].trimAscii()
        if (!envKey.isEmpty()) {
            return getVariable(envKey) ?? ""
        }
    }
    raw
}

private func videoGenerationProviderConfig(config: JsonObject, provider: String): JsonObject {
    if (provider.isEmpty()) {
        return JsonObject()
    }
    let providers = videoGenerationObject(config, "providers")
    match (providers.get(provider)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func videoGenerationProviderKind(provider: String, providerConfig: JsonObject): String {
    if (provider.isEmpty()) {
        return "missing"
    }
    let explicit = videoGenerationString(providerConfig, "kind").toAsciiLower()
    match (explicit) {
        case "dashscope" => "dashscope-qwen-video-generation"
        case "qwen-video-generation" => "dashscope-qwen-video-generation"
        case "dashscope-qwen-video-generation" => "dashscope-qwen-video-generation"
        case _ => if (!explicit.isEmpty()) { explicit } else { "missing" }
    }
}

private func videoGenerationStatus(status: String, ok!: Bool = false, message!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("status", JsonString(status))
    out.put("videos", JsonArray([]))
    out.put("attempts", JsonArray([]))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func videoGenerationAttempt(provider: String, providerKind: String, status: String, message: String): JsonObject {
    let out = JsonObject()
    out.put("provider", JsonString(provider))
    out.put("providerKind", JsonString(providerKind))
    out.put("status", JsonString(status))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func videoGenerationAttachAttempt(result: JsonObject, attempt: JsonObject): JsonObject {
    let attempts = JsonArray([])
    attempts.add(attempt)
    result.put("attempts", attempts)
    result
}

public func gatewayVideoGenerationResolveOutputRoot(config: JsonObject): Path {
    let configured = videoGenerationString(config, "outputRoot")
    if (!configured.isEmpty()) {
        return Path(configured)
    }
    MetisPaths.homeRoot().join("gateway-video-generation").join(videoGenerationDateBucket())
}

private func videoGenerationPathAllowed(path: Path, config: JsonObject): Bool {
    let pathText = path.toString()
    if (pathText.isEmpty()) {
        return false
    }
    if (pathText.endsWith("metis.json") || pathText.contains("/.metis/metis.json")) {
        return false
    }
    for (root in videoGenerationStringArray(config, "allowedOutputRoots")) {
        let normalized = root.trimAscii()
        if (!normalized.isEmpty() && (pathText == normalized || pathText.startsWith("${normalized}/"))) {
            return true
        }
    }
    if (!videoGenerationString(config, "outputRoot").isEmpty()) {
        return false
    }
    let managedRoot = MetisPaths.homeRoot().join("gateway-video-generation").toString()
    if (pathText == managedRoot || pathText.startsWith("${managedRoot}/")) {
        return true
    }
    false
}

private func videoGenerationTrimBaseUrl(raw: String, fallback: String): String {
    var baseUrl = raw.trimAscii()
    if (baseUrl.isEmpty()) {
        baseUrl = fallback
    }
    while (baseUrl.endsWith("/") && baseUrl.size > 1) {
        baseUrl = baseUrl[..baseUrl.size - 1]
    }
    baseUrl
}

private func videoGenerationDashScopeBaseUrl(providerConfig: JsonObject): String {
    videoGenerationTrimBaseUrl(videoGenerationString(providerConfig, "baseUrl"), "https://dashscope.aliyuncs.com")
}

private func videoGenerationDashScopeAigcBaseUrl(providerConfig: JsonObject): String {
    let baseUrl = videoGenerationDashScopeBaseUrl(providerConfig)
    try {
        let parsed = URL.parse(baseUrl)
        let host = parsed.hostName
        if (host == "dashscope.aliyuncs.com" ||
            host == "dashscope-intl.aliyuncs.com" ||
            host == "coding.dashscope.aliyuncs.com" ||
            host == "coding-intl.dashscope.aliyuncs.com") {
            return "${parsed.scheme}://${host}"
        }
    } catch (_: Exception) {
        ()
    }
    if (baseUrl.startsWith("https://dashscope.aliyuncs.com/compatible-mode/")) {
        return "https://dashscope.aliyuncs.com"
    }
    if (baseUrl.startsWith("https://dashscope-intl.aliyuncs.com/compatible-mode/")) {
        return "https://dashscope-intl.aliyuncs.com"
    }
    baseUrl
}

private func videoGenerationDashScopeEndpoint(providerConfig: JsonObject): String {
    "${videoGenerationDashScopeAigcBaseUrl(providerConfig)}/api/v1/services/aigc/video-generation/video-synthesis"
}

private func videoGenerationDashScopeTaskUrl(providerConfig: JsonObject, taskId: String): String {
    "${videoGenerationDashScopeAigcBaseUrl(providerConfig)}/api/v1/tasks/${taskId}"
}

private func videoGenerationDashScopeSupportsDuration(model: String, providerConfig: JsonObject): Bool {
    match (providerConfig.get("supportsDuration")) {
        case Some(v) => try { return v.asBool().getValue() } catch (_: Exception) { () }
        case None => ()
    }
    let normalized = model.trimAscii().toAsciiLower()
    if (normalized == "wanx2.1-t2v-turbo") {
        return false
    }
    true
}

private func videoGenerationDashScopeBody(providerConfig: JsonObject, request: JsonObject): JsonObject {
    let body = JsonObject()
    let input = JsonObject()
    let parameters = JsonObject()
    let modelOverride = videoGenerationString(request, "model")
    let model = if (!modelOverride.isEmpty()) {
        modelOverride
    } else {
        let configured = videoGenerationString(providerConfig, "model")
        if (configured.isEmpty()) { "wan2.5-t2v-preview" } else { configured }
    }
    body.put("model", JsonString(model))
    input.put("prompt", JsonString(videoGenerationString(request, "prompt")))
    body.put("input", input)
    let aspectRatio = videoGenerationString(request, "aspectRatio")
    if (!aspectRatio.isEmpty()) {
        parameters.put("aspect_ratio", JsonString(aspectRatio))
    }
    let duration = videoGenerationInt(request, "durationSeconds", -1)
    if (duration > 0 && videoGenerationDashScopeSupportsDuration(model, providerConfig)) {
        parameters.put("duration", JsonInt(duration))
    }
    let size = videoGenerationString(request, "size")
    if (!size.isEmpty()) {
        parameters.put("size", JsonString(size))
    }
    if (parameters.size() > 0) {
        body.put("parameters", parameters)
    }
    body
}

private func videoGenerationDashScopeRequest(providerConfig: JsonObject, request: JsonObject, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString(videoGenerationDashScopeEndpoint(providerConfig)))
    req.put("authorization", JsonString("Bearer ${videoGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("asyncHeader", JsonString("enable"))
    req.put("body", videoGenerationDashScopeBody(providerConfig, request))
    videoGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func videoGenerationDashScopePollRequest(providerConfig: JsonObject, taskId: String, timeoutMs: Int64): JsonObject {
    let req = JsonObject()
    req.put("url", JsonString(videoGenerationDashScopeTaskUrl(providerConfig, taskId)))
    req.put("authorization", JsonString("Bearer ${videoGenerationSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    videoGenerationAttachTransportRoute(req, providerConfig)
    req
}

private func videoGenerationAttachTransportRoute(request: JsonObject, providerConfig: JsonObject): Unit {
    let url = videoGenerationString(request, "url")
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

private func videoGenerationReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func videoGenerationNativeSend(request: JsonObject, providerConfig: JsonObject, method: String): GatewayVideoGenerationDashScopeHttpResult {
    let url = videoGenerationString(request, "url")
    let timeoutMs = max(1, videoGenerationInt(request, "timeoutMs", videoGenerationInt(providerConfig, "timeoutMs", 120000)))
    let headers = HashMap<String, String>()
    headers["Authorization"] = videoGenerationString(request, "authorization")
    headers["Accept"] = "application/json, */*"
    let transportConfig = resolveGatewayProviderHttpTransportConfig(providerConfig)
    let clientParts = buildGatewayProviderHttpClientBuilder(url, transportConfig)
    let client = clientParts[0].build()
    try {
        let reqBuilder = if (method == "GET") {
            HttpRequestBuilder().url(url).get()
        } else {
            headers["Content-Type"] = "application/json"
            headers["X-DashScope-Async"] = videoGenerationString(request, "asyncHeader")
            HttpRequestBuilder().url(url).post().body(videoGenerationObject(request, "body").toJsonString())
        }
        for ((key, value) in headers) {
            if (!value.isEmpty()) {
                reqBuilder.header(key, value)
            }
        }
        let response = client.send(reqBuilder.build())
        let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
        GatewayVideoGenerationDashScopeHttpResult(Int64(response.status), bodyBytes: videoGenerationReadAllBytes(response), contentType: contentType)
    } finally {
        client.close()
    }
}

private func videoGenerationDashScopeSubmit(request: JsonObject, providerConfig: JsonObject): GatewayVideoGenerationDashScopeHttpResult {
    match (videoGenerationDashScopeRunnerOverride) {
        case Some(runner) => runner(request)
        case None => videoGenerationNativeSend(request, providerConfig, "POST")
    }
}

private func videoGenerationDashScopePoll(request: JsonObject, providerConfig: JsonObject): GatewayVideoGenerationDashScopeHttpResult {
    match (videoGenerationDashScopePollerOverride) {
        case Some(poller) => poller(request)
        case None => videoGenerationNativeSend(request, providerConfig, "GET")
    }
}

private func videoGenerationSafeUrl(url: String): String {
    let trimmed = url.trimAscii()
    match (trimmed.indexOf("?")) {
        case Some(i) => trimmed[..i]
        case None => trimmed
    }
}

private func videoGenerationRedact(detail: String, providerConfig: JsonObject): String {
    var out = detail.trimAscii()
    let apiKey = videoGenerationSecretString(providerConfig, "apiKey")
    if (!apiKey.isEmpty()) {
        out = out.replace(apiKey, "[redacted]")
    }
    out = out.replace(videoGenerationSafeUrl(out), videoGenerationSafeUrl(out))
    match (out.indexOf("?")) {
        case Some(i) => out = out[..i]
        case None => ()
    }
    if (out.size > 300) {
        out = out[..300]
    }
    out
}

private func videoGenerationEnsureSuccess(result: GatewayVideoGenerationDashScopeHttpResult, providerConfig: JsonObject, context: String): Unit {
    if (result.statusCode >= 200 && result.statusCode < 300) {
        return
    }
    var detail = result.error.trimAscii()
    if (detail.isEmpty()) {
        try { detail = String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { detail = "" }
    }
    detail = videoGenerationRedact(detail, providerConfig)
    let message = if (detail.isEmpty()) { "${context} error (${result.statusCode})" } else { "${context} error (${result.statusCode}): ${detail}" }
    if (result.statusCode == 408) {
        throw VideoGenerationException("timeout", message)
    }
    if (result.statusCode == 413) {
        throw VideoGenerationException("too_large", message)
    }
    throw VideoGenerationException("provider_error", message)
}

private func videoGenerationJsonRoot(bytes: Array<Byte>): JsonObject {
    let raw = String.fromUtf8(bytes).trimAscii()
    JsonValue.fromStr(raw).asObject()
}

private func videoGenerationFindString(value: JsonValue, keys: Array<String>): String {
    try {
        let obj = value.asObject()
        for (key in keys) {
            let direct = videoGenerationString(obj, key)
            if (!direct.isEmpty()) {
                return direct
            }
        }
        for ((_, child) in obj.getFields()) {
            let found = videoGenerationFindString(child, keys)
            if (!found.isEmpty()) {
                return found
            }
        }
    } catch (_: Exception) {
        try {
            let arr = value.asArray()
            for (child in arr.getItems()) {
                let found = videoGenerationFindString(child, keys)
                if (!found.isEmpty()) {
                    return found
                }
            }
        } catch (_inner: Exception) {
            ()
        }
    }
    ""
}

private func videoGenerationTaskStatus(payload: JsonObject): String {
    let direct = videoGenerationString(payload, "task_status")
    if (!direct.isEmpty()) {
        return direct.toAsciiUpper()
    }
    videoGenerationString(videoGenerationObject(payload, "output"), "task_status").toAsciiUpper()
}

private func videoGenerationTaskId(payload: JsonObject): String {
    let output = videoGenerationObject(payload, "output")
    let nested = videoGenerationString(output, "task_id")
    if (!nested.isEmpty()) {
        return nested
    }
    videoGenerationString(payload, "task_id")
}

private func videoGenerationVideoUrl(payload: JsonObject): String {
    videoGenerationFindString(payload.toJsonValue(), ["video_url", "videoUrl", "url"])
}

private func videoGenerationDashScopeWaitForVideoUrl(providerConfig: JsonObject, taskId: String, timeoutMs: Int64): String {
    let started = videoGenerationNowMs()
    let maxPollMs = max(0, videoGenerationInt(providerConfig, "maxPollSeconds", 600)) * 1000
    let pollIntervalMs = max(0, videoGenerationInt(providerConfig, "pollIntervalMs", 3000))
    while (true) {
        if (maxPollMs == 0 || videoGenerationNowMs() - started > maxPollMs) {
            throw VideoGenerationException("timeout", "DashScope video generation task ${taskId} did not finish in time.")
        }
        let pollRequest = videoGenerationDashScopePollRequest(providerConfig, taskId, timeoutMs)
        let pollResult = videoGenerationDashScopePoll(pollRequest, providerConfig)
        videoGenerationEnsureSuccess(pollResult, providerConfig, "DashScope video generation task poll")
        let payload = videoGenerationJsonRoot(pollResult.bodyBytes)
        let status = videoGenerationTaskStatus(payload)
        if (status == "SUCCEEDED") {
            let url = videoGenerationVideoUrl(payload)
            if (url.isEmpty()) {
                throw VideoGenerationException("provider_error", "DashScope video generation completed without video URL.")
            }
            return url
        }
        if (status == "FAILED" || status == "CANCELED" || status == "CANCELLED") {
            let msg = videoGenerationFindString(payload.toJsonValue(), ["message", "code"])
            throw VideoGenerationException("provider_error", if (msg.isEmpty()) { "DashScope video generation task ${taskId} ${status.toAsciiLower()}." } else { videoGenerationRedact(msg, providerConfig) })
        }
        if (pollIntervalMs > 0) {
            sleep(Duration.millisecond * pollIntervalMs)
        }
    }
    ""
}

private func videoGenerationNativeDownload(url: String, timeoutMs: Int64, maxBytes: Int64, providerConfig: JsonObject): GatewayVideoGenerationDashScopeHttpResult {
    let transportConfig = resolveGatewayProviderHttpTransportConfig(providerConfig)
    let clientParts = buildGatewayProviderHttpClientBuilder(url, transportConfig)
    let client = clientParts[0].build()
    try {
        let response = client.send(HttpRequestBuilder().url(url).get().build())
        let bytes = videoGenerationReadAllBytes(response)
        if (response.status >= 200 && response.status < 300 && maxBytes > 0 && Int64(bytes.size) > maxBytes) {
            return GatewayVideoGenerationDashScopeHttpResult(413, error: "downloaded video exceeds maxVideoBytes")
        }
        let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
        GatewayVideoGenerationDashScopeHttpResult(Int64(response.status), bodyBytes: bytes, contentType: contentType)
    } finally {
        client.close()
    }
}

private func videoGenerationDownload(url: String, timeoutMs: Int64, maxBytes: Int64, providerConfig: JsonObject): GatewayVideoGenerationDashScopeHttpResult {
    let trimmed = url.trimAscii()
    if (!(trimmed.startsWith("https://") || trimmed.startsWith("http://"))) {
        throw VideoGenerationException("provider_error", "DashScope video URL is not http(s): ${videoGenerationSafeUrl(trimmed)}")
    }
    let result = match (videoGenerationDashScopeDownloaderOverride) {
        case Some(downloader) => downloader(trimmed, timeoutMs, maxBytes, providerConfig)
        case None => videoGenerationNativeDownload(trimmed, timeoutMs, maxBytes, providerConfig)
    }
    if (result.statusCode >= 200 && result.statusCode < 300 && maxBytes > 0 && Int64(result.bodyBytes.size) > maxBytes) {
        return GatewayVideoGenerationDashScopeHttpResult(413, error: "downloaded video exceeds maxVideoBytes")
    }
    result
}

private func videoGenerationExtensionFromMimeOrUrl(mime: String, url: String): String {
    let lowMime = mime.toAsciiLower()
    if (lowMime.contains("webm")) {
        return "webm"
    }
    if (lowMime.contains("quicktime")) {
        return "mov"
    }
    let safe = videoGenerationSafeUrl(url).toAsciiLower()
    if (safe.endsWith(".webm")) {
        return "webm"
    }
    if (safe.endsWith(".mov")) {
        return "mov"
    }
    "mp4"
}

private func videoGenerationMimeFromExtension(extension: String, contentType: String): String {
    let trimmed = contentType.trimAscii()
    if (trimmed.startsWith("video/")) {
        return trimmed
    }
    match (extension) {
        case "webm" => "video/webm"
        case "mov" => "video/quicktime"
        case _ => "video/mp4"
    }
}

private func videoGenerationSanitizeFileName(raw: String, extension: String): String {
    var name = raw.trimAscii()
    if (name.isEmpty()) {
        return "video-${videoGenerationNowMs()}.${extension}"
    }
    name = name.replace("/", "-").replace("\\", "-").replace(" ", "-").replace(":", "-")
    while (name.contains("--")) {
        name = name.replace("--", "-")
    }
    if (!(name.endsWith(".mp4") || name.endsWith(".webm") || name.endsWith(".mov"))) {
        name = "${name}.${extension}"
    }
    name
}

private func videoGenerationDashScopeGenerate(config: JsonObject, request: JsonObject, provider: String, providerKind: String, providerConfig: JsonObject, outputRoot: Path): JsonObject {
    let timeoutMs = max(1, videoGenerationInt(providerConfig, "timeoutMs", videoGenerationInt(config, "timeoutMs", 600000)))
    let maxVideoBytes = max(1, videoGenerationInt(providerConfig, "maxVideoBytes", videoGenerationInt(config, "maxVideoBytes", 250 * 1024 * 1024)))
    let submitRequest = videoGenerationDashScopeRequest(providerConfig, request, timeoutMs)
    let model = videoGenerationString(videoGenerationObject(submitRequest, "body"), "model")
    try {
        let submitResult = videoGenerationDashScopeSubmit(submitRequest, providerConfig)
        videoGenerationEnsureSuccess(submitResult, providerConfig, "DashScope video generation submit")
        let submitted = videoGenerationJsonRoot(submitResult.bodyBytes)
        let taskId = videoGenerationTaskId(submitted)
        if (taskId.isEmpty()) {
            throw VideoGenerationException("provider_error", "DashScope video generation response missing task_id.")
        }
        let videoUrl = videoGenerationDashScopeWaitForVideoUrl(providerConfig, taskId, timeoutMs)
        let download = videoGenerationDownload(videoUrl, timeoutMs, maxVideoBytes, providerConfig)
        videoGenerationEnsureSuccess(download, providerConfig, "DashScope generated video download")
        if (download.bodyBytes.isEmpty()) {
            throw VideoGenerationException("empty_result", "DashScope generated video download returned empty video.")
        }
        let extension = videoGenerationExtensionFromMimeOrUrl(download.contentType, videoUrl)
        let mimeType = videoGenerationMimeFromExtension(extension, download.contentType)
        let fileName = videoGenerationSanitizeFileName(videoGenerationString(request, "filename"), extension)
        if (!exists(outputRoot)) {
            Directory.create(outputRoot, recursive: true)
        }
        let outputPath = outputRoot.join(fileName)
        File.writeTo(outputPath, download.bodyBytes)
        let video = JsonObject()
        video.put("path", JsonString(outputPath.toString()))
        video.put("mimeType", JsonString(mimeType))
        video.put("fileName", JsonString(fileName))
        let videos = JsonArray([video])
        let out = videoGenerationStatus("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        out.put("videos", videos)
        let metadata = JsonObject()
        metadata.put("taskId", JsonString(taskId))
        metadata.put("sourceUrl", JsonString(videoGenerationSafeUrl(videoUrl)))
        out.put("metadata", metadata)
        videoGenerationAttachAttempt(out, videoGenerationAttempt(provider, providerKind, "ok", ""))
    } catch (e: VideoGenerationException) {
        let out = videoGenerationStatus(e.status, ok: false, message: videoGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        videoGenerationAttachAttempt(out, videoGenerationAttempt(provider, providerKind, e.status, videoGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = videoGenerationStatus(status, ok: false, message: videoGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
        videoGenerationAttachAttempt(out, videoGenerationAttempt(provider, providerKind, status, videoGenerationRedact(e.message, providerConfig)))
    }
}

public func gatewayVideoGenerationGenerate(config: JsonObject, request: JsonObject): JsonObject {
    if (!videoGenerationBool(config, "enabled", true)) {
        return videoGenerationStatus("disabled", ok: false, message: "Gateway video generation is disabled.")
    }
    let prompt = videoGenerationString(request, "prompt")
    if (prompt.isEmpty()) {
        return videoGenerationStatus("invalid_request", ok: false, message: "video generation prompt is required.")
    }
    let maxPromptChars = videoGenerationInt(config, "maxPromptChars", 4000)
    if (maxPromptChars > 0 && Int64(prompt.size) > maxPromptChars) {
        let out = videoGenerationStatus("invalid_request", ok: false, message: "video generation prompt exceeds maxPromptChars.")
        out.put("maxPromptChars", JsonInt(maxPromptChars))
        return out
    }
    let provider = videoGenerationString(config, "provider")
    if (provider.isEmpty()) {
        return videoGenerationStatus("not_configured", ok: false, message: "video generation provider is not configured")
    }
    let providerConfig = videoGenerationProviderConfig(config, provider)
    let providerKind = videoGenerationProviderKind(provider, providerConfig)
    let outputRoot = gatewayVideoGenerationResolveOutputRoot(config)
    if (!videoGenerationPathAllowed(outputRoot, config)) {
        let out = videoGenerationStatus("invalid_request", ok: false, message: "video generation outputRoot is not under an allowed managed root.")
        out.put("outputRoot", JsonString(outputRoot.toString()))
        return out
    }
    match (videoGenerationRunnerOverride) {
        case Some(runner) =>
            let result = runner(config, request)
            if (result.get("ok").isNone()) {
                result.put("ok", JsonBool(videoGenerationString(result, "status") == "ok"))
            }
            if (result.get("provider").isNone()) {
                result.put("provider", JsonString(provider))
            }
            if (result.get("providerKind").isNone()) {
                result.put("providerKind", JsonString(providerKind))
            }
            if (result.get("model").isNone()) {
                result.put("model", JsonString(videoGenerationString(providerConfig, "model")))
            }
            result.put("outputRoot", JsonString(outputRoot.toString()))
            return result
        case None => ()
    }
    if (providerKind == "dashscope-qwen-video-generation") {
        let apiKey = videoGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = videoGenerationStatus("not_configured", ok: false, message: "Configured DashScope video generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        }
        return videoGenerationDashScopeGenerate(config, request, provider, providerKind, providerConfig, outputRoot)
    }
    let out = videoGenerationStatus("not_found", ok: false, message: "Configured video generation provider '${provider}' is not available.")
    out.put("provider", JsonString(provider))
    out.put("providerKind", JsonString(providerKind))
    out
}

public func gatewayVideoGenerationOutputRoot(config: JsonObject): String {
    gatewayVideoGenerationResolveOutputRoot(config).toString()
}
