package metis.core

import metis.utils.{ShellTimeoutException, ShellUtils}

import magic.jsonable.*

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.time.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public class GatewaySpeechAsrOpenAICompatibleHttpResult {
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

private class SpeechAsrOpenAICompatibleException <: Exception {
    public let status: String

    public init(status: String, message: String) {
        super(message)
        this.status = status
    }
}

private var speechAsrOpenAICompatibleRunnerOverride: Option<(JsonObject) -> GatewaySpeechAsrOpenAICompatibleHttpResult> =
    None<(JsonObject) -> GatewaySpeechAsrOpenAICompatibleHttpResult>

public func setGatewaySpeechAsrOpenAICompatibleRunnerForTest(runner: Option<(JsonObject) -> GatewaySpeechAsrOpenAICompatibleHttpResult>): Unit {
    speechAsrOpenAICompatibleRunnerOverride = runner
}

private func speechAsrNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func speechAsrString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func speechAsrInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func speechAsrBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func speechAsrObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func speechAsrStringArray(obj: JsonObject, key: String): Array<String> {
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

private func speechAsrSecretString(obj: JsonObject, key: String): String {
    let raw = speechAsrString(obj, key)
    if (raw.startsWith("$" + "{") && raw.endsWith("}") && raw.size > 3) {
        let envKey = raw[2..raw.size - 1].trimAscii()
        if (!envKey.isEmpty()) {
            return getVariable(envKey) ?? ""
        }
    }
    raw
}

private func speechAsrProviderConfig(config: JsonObject, provider: String): JsonObject {
    let providers = speechAsrObject(config, "providers")
    match (providers.get(provider)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func speechAsrProviderKind(provider: String, providerConfig: JsonObject): String {
    if (provider.isEmpty()) {
        return "missing"
    }
    let explicit = speechAsrString(providerConfig, "kind").toAsciiLower()
    if (!explicit.isEmpty()) {
        return explicit
    }
    if (speechAsrStringArray(providerConfig, "command").size > 0) {
        return "command"
    }
    "missing"
}

private func speechAsrResult(status: String, ok!: Bool = false, message!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("status", JsonString(status))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func speechAsrCommandArgs(providerConfig: JsonObject, inputPath: String, mime: String, outputPath: Path, outputDir: Path): Array<String> {
    let raw = speechAsrStringArray(providerConfig, "command")
    let out = ArrayList<String>()
    for (part in raw) {
        out.add(part
            .replace("{input}", inputPath)
            .replace("{mime}", mime)
            .replace("{output}", outputPath.toString())
            .replace("{outputDir}", outputDir.toString()))
    }
    out.toArray()
}

private func speechAsrTooLargeResult(fileBytes: Int64, limitBytes: Int64): JsonObject {
    let out = speechAsrResult("too_large", ok: false, message: "audio input exceeds configured maxBytes")
    out.put("fileBytes", JsonInt(fileBytes))
    out.put("limitBytes", JsonInt(limitBytes))
    out
}

private func speechAsrOpenAICompatibleBaseUrl(providerConfig: JsonObject): String {
    var baseUrl = speechAsrString(providerConfig, "baseUrl")
    if (baseUrl.isEmpty()) {
        baseUrl = "https://api.openai.com/v1"
    }
    while (baseUrl.endsWith("/") && baseUrl.size > 1) {
        baseUrl = baseUrl[..baseUrl.size - 1]
    }
    baseUrl
}

private func speechAsrOpenAICompatibleRequest(providerConfig: JsonObject, inputPath: String, mime: String, fileBytes: Int64, timeoutMs: Int64): JsonObject {
    let fields = JsonObject()
    let model = speechAsrString(providerConfig, "model")
    fields.put("model", JsonString(if (model.isEmpty()) { "whisper-1" } else { model }))
    let language = speechAsrString(providerConfig, "language")
    if (!language.isEmpty()) {
        fields.put("language", JsonString(language))
    }

    let req = JsonObject()
    req.put("url", JsonString("${speechAsrOpenAICompatibleBaseUrl(providerConfig)}/audio/transcriptions"))
    req.put("authorization", JsonString("Bearer ${speechAsrSecretString(providerConfig, "apiKey")}"))
    req.put("timeoutMs", JsonInt(timeoutMs))
    req.put("filePath", JsonString(inputPath))
    req.put("fileBytes", JsonInt(fileBytes))
    req.put("mime", JsonString(mime))
    req.put("fields", fields)
    req
}

private func speechAsrOpenAICompatibleReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func speechAsrOpenAICompatibleNativePost(request: JsonObject, providerConfig: JsonObject): GatewaySpeechAsrOpenAICompatibleHttpResult {
    let url = speechAsrString(request, "url")
    let timeoutMs = max(1, speechAsrInt(request, "timeoutMs", speechAsrInt(providerConfig, "timeoutMs", 30000)))
    let headers = HashMap<String, String>()
    headers["Authorization"] = speechAsrString(request, "authorization")
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json, text/plain"

    let body = JsonObject()
    body.put("model", speechAsrString(speechAsrObject(request, "fields"), "model").toJsonValue())
    let language = speechAsrString(speechAsrObject(request, "fields"), "language")
    if (!language.isEmpty()) {
        body.put("language", JsonString(language))
    }
    body.put("filePath", JsonString(speechAsrString(request, "filePath")))
    body.put("fileBytes", JsonInt(speechAsrInt(request, "fileBytes", 0)))
    body.put("mime", JsonString(speechAsrString(request, "mime")))

    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * timeoutMs)
    if (url.startsWith("https")) {
        var tlsConfig = TlsClientConfig()
        if (speechAsrBool(providerConfig, "insecureSkipTlsVerify", false)) {
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
        GatewaySpeechAsrOpenAICompatibleHttpResult(Int64(response.status), bodyBytes: speechAsrOpenAICompatibleReadAllBytes(response))
    } finally {
        client.close()
    }
}

private func speechAsrOpenAICompatibleErrorDetail(result: GatewaySpeechAsrOpenAICompatibleHttpResult, apiKey: String): String {
    var detail = result.error.trimAscii()
    if (detail.isEmpty()) {
        try { detail = String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { detail = "" }
    }
    if (!apiKey.isEmpty()) {
        detail = detail.replace(apiKey, "[redacted]")
    }
    if (detail.size > 300) {
        detail = detail[..300]
    }
    detail
}

private func speechAsrOpenAICompatibleTextFromJson(raw: String): String {
    try {
        let obj = JsonValue.fromStr(raw).asObject()
        return speechAsrString(obj, "text")
    } catch (_: Exception) {
        return ""
    }
}

private func speechAsrOpenAICompatibleTranscript(result: GatewaySpeechAsrOpenAICompatibleHttpResult, apiKey: String): String {
    let status = result.statusCode
    if (status < 200 || status >= 300) {
        let detail = speechAsrOpenAICompatibleErrorDetail(result, apiKey)
        let message = if (detail.isEmpty()) { "OpenAI-compatible ASR API error (${status})" } else { "OpenAI-compatible ASR API error (${status}): ${detail}" }
        if (status == 401 || status == 403) {
            throw SpeechAsrOpenAICompatibleException("auth_error", message)
        }
        if (status == 408) {
            throw SpeechAsrOpenAICompatibleException("timeout", message)
        }
        throw SpeechAsrOpenAICompatibleException("provider_error", message)
    }

    let raw = try { String.fromUtf8(result.bodyBytes).trimAscii() } catch (_: Exception) { "" }
    if (raw.isEmpty()) {
        return ""
    }
    let contentType = result.contentType.toAsciiLower()
    if (contentType.contains("json") || raw.startsWith("{")) {
        let text = speechAsrOpenAICompatibleTextFromJson(raw).trimAscii()
        if (!text.isEmpty()) {
            return text
        }
        return ""
    }
    raw
}

private func speechAsrOpenAICompatiblePost(request: JsonObject, providerConfig: JsonObject): String {
    let result = match (speechAsrOpenAICompatibleRunnerOverride) {
        case Some(runner) => runner(request)
        case None => speechAsrOpenAICompatibleNativePost(request, providerConfig)
    }
    speechAsrOpenAICompatibleTranscript(result, speechAsrSecretString(providerConfig, "apiKey"))
}

public func gatewaySpeechAsrTranscribeAudioPath(config: JsonObject, path: String, mime: String, outputRoot!: Path, maxBytes!: Int64 = 0): JsonObject {
    let inputPath = path.trimAscii()
    if (inputPath.isEmpty() || !exists(Path(inputPath))) {
        return speechAsrResult("unsupported", ok: false, message: "audio input path is missing")
    }
    let inputBytes = File.readFrom(Path(inputPath))
    let inputByteCount = Int64(inputBytes.size)
    let effectiveMaxBytes = speechAsrInt(config, "maxBytes", maxBytes)
    if (effectiveMaxBytes > 0) {
        if (inputByteCount > effectiveMaxBytes) {
            return speechAsrTooLargeResult(inputByteCount, effectiveMaxBytes)
        }
    }
    if (!speechAsrBool(config, "enabled", true)) {
        return speechAsrResult("disabled", ok: false, message: "Gateway ASR is disabled")
    }
    let provider = speechAsrString(config, "provider")
    if (provider.isEmpty()) {
        return speechAsrResult("not_configured", ok: false, message: "No Metis Gateway ASR provider is configured.")
    }
    let providerConfig = speechAsrProviderConfig(config, provider)
    let providerMaxBytes = speechAsrInt(providerConfig, "maxBytes", 0)
    if (providerMaxBytes > 0 && inputByteCount > providerMaxBytes) {
        return speechAsrTooLargeResult(inputByteCount, providerMaxBytes)
    }
    let providerKind = speechAsrProviderKind(provider, providerConfig)
    if (providerKind == "openai-compatible") {
        let apiKey = speechAsrSecretString(providerConfig, "apiKey")
        if (apiKey.isEmpty()) {
            let out = speechAsrResult("not_configured", ok: false, message: "Configured OpenAI-compatible ASR provider '${provider}' is missing apiKey.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        }
        let timeoutMs = max(1, speechAsrInt(providerConfig, "timeoutMs", speechAsrInt(config, "timeoutMs", 30000)))
        let request = speechAsrOpenAICompatibleRequest(providerConfig, inputPath, mime.trimAscii().toAsciiLower(), inputByteCount, timeoutMs)
        try {
            let transcript = speechAsrOpenAICompatiblePost(request, providerConfig).trimAscii()
            if (transcript.isEmpty()) {
                let out = speechAsrResult("empty_result", ok: false, message: "Configured ASR provider returned an empty transcript.")
                out.put("provider", JsonString(provider))
                out.put("providerKind", JsonString(providerKind))
                return out
            }
            let out = speechAsrResult("ok", ok: true)
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            out.put("transcript", JsonString(transcript))
            return out
        } catch (e: SpeechAsrOpenAICompatibleException) {
            let out = speechAsrResult(e.status, ok: false, message: e.message.replace(apiKey, "[redacted]"))
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        } catch (e: Exception) {
            let msg = e.message.toAsciiLower()
            if (msg.contains("timeout") || msg.contains("timed out")) {
                let out = speechAsrResult("timeout", ok: false, message: "Configured ASR provider request timed out.")
                out.put("provider", JsonString(provider))
                out.put("providerKind", JsonString(providerKind))
                out.put("timeoutMs", JsonInt(timeoutMs))
                return out
            }
            let out = speechAsrResult("provider_error", ok: false, message: e.message.replace(apiKey, "[redacted]"))
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        }
    }
    if (providerKind == "tencent-flash") {
        let result = gatewaySpeechAsrTencentFlashTranscribeAudio(providerConfig, inputBytes)
        result.put("provider", JsonString(provider))
        result.put("providerKind", JsonString(providerKind))
        return result
    }
    if (providerKind != "command") {
        let out = speechAsrResult("not_found", ok: false, message: "Configured ASR provider '${provider}' is not available.")
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        return out
    }
    if (!exists(outputRoot)) {
        Directory.create(outputRoot, recursive: true)
    }
    let outputPath = outputRoot.join("asr-${speechAsrNowMs()}.txt")
    let command = speechAsrCommandArgs(providerConfig, inputPath, mime.trimAscii().toAsciiLower(), outputPath, outputRoot)
    if (command.size == 0) {
        let out = speechAsrResult("not_found", ok: false, message: "Configured ASR provider '${provider}' has no command array.")
        out.put("provider", JsonString(provider))
        return out
    }
    let timeoutMs = max(1, speechAsrInt(providerConfig, "timeoutMs", speechAsrInt(config, "timeoutMs", 60000)))
    try {
        let (exitCode, stdout, _stderr) = ShellUtils.execute(command, timeout: Some(Duration.millisecond * timeoutMs), withWrap: false)
        if (exitCode != 0) {
            let out = speechAsrResult("provider_error", ok: false, message: "Configured ASR provider command failed.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            out.put("exitCode", JsonInt(exitCode))
            return out
        }
        let transcript = if (exists(outputPath)) {
            String.fromUtf8(File.readFrom(outputPath)).trimAscii()
        } else {
            stdout.trimAscii()
        }
        if (transcript.isEmpty()) {
            let out = speechAsrResult("provider_error", ok: false, message: "Configured ASR provider returned an empty transcript.")
            out.put("provider", JsonString(provider))
            out.put("providerKind", JsonString(providerKind))
            return out
        }
        let out = speechAsrResult("ok", ok: true)
        out.put("provider", JsonString(provider))
        out.put("providerKind", JsonString(providerKind))
        out.put("transcript", JsonString(transcript))
        out.put("outputPath", JsonString(outputPath.toString()))
        return out
    } catch (_: ShellTimeoutException) {
        let out = speechAsrResult("timeout", ok: false, message: "Configured ASR provider command timed out.")
        out.put("provider", JsonString(provider))
        out.put("timeoutMs", JsonInt(timeoutMs))
        return out
    } catch (e: Exception) {
        let out = speechAsrResult("provider_error", ok: false, message: e.message)
        out.put("provider", JsonString(provider))
        return out
    }
}
