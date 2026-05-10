package metis.core

import metis.core.config.MetisPaths

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.time.*
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
        case "openai-image-generation" => "openai-images"
        case "openai-images" => "openai-images"
        case "dashscope-qwen-image" => "dashscope-qwen-image-generation"
        case "qwen-image" => "dashscope-qwen-image-generation"
        case "dashscope-qwen-image-generation" => "dashscope-qwen-image-generation"
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

private func imageGenerationOpenAiEndpoint(providerConfig: JsonObject): String {
    "${imageGenerationTrimBaseUrl(imageGenerationString(providerConfig, "baseUrl"), "https://api.openai.com/v1")}/images/generations"
}

private func imageGenerationDashScopeEndpoint(providerConfig: JsonObject): String {
    let endpoint = imageGenerationString(providerConfig, "endpoint")
    if (!endpoint.isEmpty()) {
        return endpoint
    }
    "${imageGenerationTrimBaseUrl(imageGenerationString(providerConfig, "baseUrl"), "https://dashscope.aliyuncs.com/api/v1")}/services/aigc/multimodal-generation/generation"
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
        let reqBuilder = HttpRequestBuilder().url(url).post().body(imageGenerationObject(request, "body").toJsonString())
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
    let clientParts = buildGatewayProviderHttpClientBuilder(url, resolveGatewayProviderHttpTransportConfig(providerConfig))
    let client = clientParts[0].build()
    try {
        let response = client.send(HttpRequestBuilder().url(url).get().build())
        let bytes = imageGenerationReadAllBytes(response)
        if (response.status >= 200 && response.status < 300 && maxBytes > 0 && Int64(bytes.size) > maxBytes) {
            return GatewayImageGenerationHttpResult(413, error: "downloaded image exceeds maxImageBytes")
        }
        let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
        GatewayImageGenerationHttpResult(Int64(response.status), bodyBytes: bytes, contentType: contentType)
    } finally {
        client.close()
    }
}

private func imageGenerationDownload(url: String, timeoutMs: Int64, maxBytes: Int64, providerConfig: JsonObject): GatewayImageGenerationHttpResult {
    let trimmed = url.trimAscii()
    if (!(trimmed.startsWith("https://") || trimmed.startsWith("http://"))) {
        throw ImageGenerationException("provider_error", "generated image URL is not http(s): ${imageGenerationSafeUrl(trimmed)}")
    }
    let result = match (imageGenerationDownloaderOverride) {
        case Some(downloader) => downloader(trimmed, timeoutMs, maxBytes, providerConfig)
        case None => imageGenerationNativeDownload(trimmed, timeoutMs, maxBytes, providerConfig)
    }
    if (result.statusCode >= 200 && result.statusCode < 300 && maxBytes > 0 && Int64(result.bodyBytes.size) > maxBytes) {
        return GatewayImageGenerationHttpResult(413, error: "downloaded image exceeds maxImageBytes")
    }
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

private func imageGenerationValidateReferenceImage(config: JsonObject, providerConfig: JsonObject, request: JsonObject): Unit {
    let ref = imageGenerationString(request, "referenceImage")
    if (ref.isEmpty()) {
        return
    }
    if (!imageGenerationBool(providerConfig, "supportsEdit", false)) {
        throw ImageGenerationException("provider_unsupported", "referenceImage was provided but the configured provider does not support image editing.")
    }
    let path = Path(ref)
    if (!exists(path)) {
        throw ImageGenerationException("invalid_request", "referenceImage does not exist.")
    }
    if (!imageGenerationPathAllowed(path, config)) {
        throw ImageGenerationException("write_denied", "referenceImage must be under an allowed Metis media/output root.")
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
        imageGenerationValidateReferenceImage(config, providerConfig, request)
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
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
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
        imageGenerationValidateReferenceImage(config, providerConfig, request)
        if (!imageGenerationString(request, "referenceImage").isEmpty()) {
            throw ImageGenerationException("provider_unsupported", "referenceImage editing is not implemented for openai-images provider.")
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
        imageGenerationAttachAttempt(out, imageGenerationAttempt(provider, providerKind, e.status, imageGenerationRedact(e.message, providerConfig)))
    } catch (e: Exception) {
        let status = if (e.message.toAsciiLower().contains("timeout")) { "timeout" } else { "provider_error" }
        let out = imageGenerationStatus(status, ok: false, message: imageGenerationRedact(e.message, providerConfig))
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("model", JsonString(model))
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
    if (!imageGenerationPathAllowed(outputRoot, config)) {
        let out = imageGenerationStatus("invalid_request", ok: false, message: "image generation outputRoot is not under an allowed managed root.")
        out.put("outputRoot", JsonString(outputRoot.toString()))
        return out
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
            return result
        case None => ()
    }
    if (providerKind == "openai-images") {
        let apiKey = imageGenerationSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = imageGenerationStatus("not_configured", ok: false, message: "Configured OpenAI image generation provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        }
        return imageGenerationOpenAiGenerate(config, request, provider, providerKind, providerConfig, outputRoot)
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
    let out = imageGenerationStatus("not_found", ok: false, message: "Configured image generation provider '${provider}' is not available.")
    out.put("provider", JsonString(provider))
    out.put("providerKind", JsonString(providerKind))
    out
}

public func gatewayImageGenerationOutputRoot(config: JsonObject): String {
    gatewayImageGenerationResolveOutputRoot(config).toString()
}
