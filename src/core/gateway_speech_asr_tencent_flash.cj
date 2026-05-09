package metis.core

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getVariable
import std.sort.*
import std.time.*
import stdx.crypto.digest.{HMAC, HashType}
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

private let TENCENT_FLASH_DEFAULT_ENDPOINT = "https://asr.cloud.tencent.com/asr/flash/v1"
private let TENCENT_FLASH_HOST = "asr.cloud.tencent.com"
private let TENCENT_FLASH_PATH_PREFIX = "/asr/flash/v1"

public class GatewaySpeechAsrTencentFlashHttpResult {
    public let statusCode: Int64
    public let body: String
    public let error: String

    public init(statusCode: Int64, body!: String = "", error!: String = "") {
        this.statusCode = statusCode
        this.body = body
        this.error = error
    }
}

private var tencentFlashRunnerOverride: Option<(JsonObject, Array<Byte>) -> GatewaySpeechAsrTencentFlashHttpResult> =
    None<(JsonObject, Array<Byte>) -> GatewaySpeechAsrTencentFlashHttpResult>

public func setGatewaySpeechAsrTencentFlashRunnerForTest(runner: Option<(JsonObject, Array<Byte>) -> GatewaySpeechAsrTencentFlashHttpResult>): Unit {
    tencentFlashRunnerOverride = runner
}

private func tencentFlashNowSeconds(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
}

private func tencentFlashString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func tencentFlashInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func tencentFlashConfigString(config: JsonObject, key: String): String {
    let raw = tencentFlashString(config, key)
    if (raw.startsWith("$" + "{") && raw.endsWith("}") && raw.size > 3) {
        let envKey = raw[2..raw.size - 1].trimAscii()
        if (!envKey.isEmpty()) {
            return getVariable(envKey) ?? ""
        }
    }
    raw
}

private func tencentFlashStatus(status: String, ok!: Bool = false, message!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    out.put("status", JsonString(status))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func tencentFlashEndpoint(config: JsonObject): String {
    var endpoint = tencentFlashString(config, "endpoint")
    if (endpoint.isEmpty()) {
        endpoint = TENCENT_FLASH_DEFAULT_ENDPOINT
    }
    while (endpoint.endsWith("/") && endpoint.size > 1) {
        endpoint = endpoint[..endpoint.size - 1]
    }
    endpoint
}

private func tencentFlashEndpointHost(endpoint: String): String {
    try { URL.parse(endpoint).hostName.trimAscii() } catch (_: Exception) { TENCENT_FLASH_HOST }
}

private func tencentFlashEndpointPath(endpoint: String): String {
    let trimmed = endpoint.trimAscii()
    let marker = "://"
    let rest = match (trimmed.indexOf(marker)) {
        case Some(idx) => trimmed[idx + marker.size..]
        case None => trimmed
    }
    match (rest.indexOf("/")) {
        case Some(slashIdx) =>
            let path = rest[slashIdx..]
            if (path.isEmpty()) {
                return TENCENT_FLASH_PATH_PREFIX
            }
            path
        case None => TENCENT_FLASH_PATH_PREFIX
    }
}

private func tencentFlashIsUnreserved(b: Byte): Bool {
    (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 45 || b == 46 || b == 95 || b == 126
}

private func tencentFlashHexDigit(value: Int64): String {
    if (value < 10) {
        return "${value}"
    }
    match (value) {
        case 10 => "A"
        case 11 => "B"
        case 12 => "C"
        case 13 => "D"
        case 14 => "E"
        case _ => "F"
    }
}

private func tencentFlashJoin(items: ArrayList<String>, separator: String): String {
    var out = ""
    for (i in 0..items.size) {
        if (i > 0) {
            out += separator
        }
        out += items[i]
    }
    out
}

private func tencentFlashEncodeQueryValue(value: String): String {
    let out = ArrayList<String>()
    for (b in value.toArray()) {
        if (tencentFlashIsUnreserved(b)) {
            out.add(String.fromUtf8([b]))
        } else if (b == 32) {
            out.add("+")
        } else {
            let n = Int64(b)
            out.add("%${tencentFlashHexDigit(n / 16)}${tencentFlashHexDigit(n % 16)}")
        }
    }
    tencentFlashJoin(out, "")
}

private func tencentFlashBuildQuery(params: HashMap<String, String>): String {
    let keys = ArrayList<String>()
    for ((key, _value) in params) {
        keys.add(key)
    }
    var sortedKeys = keys.toArray()
    sort(sortedKeys)
    let parts = ArrayList<String>()
    for (key in sortedKeys) {
        parts.add("${key}=${tencentFlashEncodeQueryValue(params[key])}")
    }
    tencentFlashJoin(parts, "&")
}

private func tencentFlashHmacSha1Base64(secretKey: String, signText: String): String {
    let mac = HMAC(secretKey.toArray(), HashType.SHA1)
    mac.write(signText.toArray())
    toBase64String(mac.finish())
}

public func gatewaySpeechAsrTencentFlashBuildRequest(config: JsonObject, timestamp: Int64): JsonObject {
    let appId = tencentFlashConfigString(config, "appId")
    let endpoint = tencentFlashEndpoint(config)
    let params = HashMap<String, String>()
    params["engine_type"] = if (tencentFlashString(config, "engineType").isEmpty()) { "16k_zh" } else { tencentFlashString(config, "engineType") }
    params["secretid"] = tencentFlashConfigString(config, "secretId")
    params["timestamp"] = "${timestamp}"
    params["voice_format"] = if (tencentFlashString(config, "voiceFormat").isEmpty()) { "silk" } else { tencentFlashString(config, "voiceFormat") }
    let query = tencentFlashBuildQuery(params)
    let path = tencentFlashEndpointPath(endpoint)
    let host = tencentFlashEndpointHost(endpoint)
    let signText = "POST${host}${path}/${appId}?${query}"
    let request = JsonObject()
    request.put("url", JsonString("${endpoint}/${appId}?${query}"))
    request.put("query", JsonString(query))
    request.put("signText", JsonString(signText))
    request.put("authorization", JsonString(tencentFlashHmacSha1Base64(tencentFlashConfigString(config, "secretKey"), signText)))
    request.put("contentType", JsonString("application/octet-stream"))
    request.put("timeoutMs", JsonInt(max(1, tencentFlashInt(config, "timeoutMs", 30000))))
    return request
}

private func tencentFlashJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func tencentFlashJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func tencentFlashReadText(item: JsonObject): String {
    tencentFlashJsonString(item, "text")
}

private func tencentFlashExtractTranscript(payload: JsonObject): String {
    let lines = ArrayList<String>()
    match (payload.get("flash_result")) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                for (itemValue in arr.getItems()) {
                    let item = try { itemValue.asObject() } catch (_: Exception) { JsonObject() }
                    let direct = tencentFlashReadText(item)
                    if (!direct.isEmpty()) {
                        lines.add(direct)
                        continue
                    }
                    match (item.get("sentence_list")) {
                        case Some(sentencesValue) =>
                            try {
                                let sentences = sentencesValue.asArray()
                                for (sentenceValue in sentences.getItems()) {
                                    let sentence = try { sentenceValue.asObject() } catch (_: Exception) { JsonObject() }
                                    let text = tencentFlashReadText(sentence)
                                    if (!text.isEmpty()) {
                                        lines.add(text)
                                    }
                                }
                            } catch (_: Exception) {
                                ()
                            }
                        case None => ()
                    }
                }
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    tencentFlashJoin(lines, "\n").trimAscii()
}

public func gatewaySpeechAsrTencentFlashParseResponse(statusCode: Int64, body: String): JsonObject {
    let payload = try {
        JsonValue.fromStr(body).asObject()
    } catch (_: Exception) {
        return tencentFlashStatus("provider_error", ok: false, message: "Tencent Flash ASR response is not valid JSON.")
    }
    if (statusCode == 401 || statusCode == 403) {
        return tencentFlashStatus("auth_error", ok: false, message: "Tencent Flash ASR authentication failed.")
    }
    if (statusCode == 408) {
        return tencentFlashStatus("timeout", ok: false, message: "Tencent Flash ASR request timed out.")
    }
    if (statusCode < 200 || statusCode >= 300) {
        return tencentFlashStatus("provider_error", ok: false, message: "Tencent Flash ASR HTTP error (${statusCode}).")
    }
    let code = tencentFlashJsonInt(payload, "code", -1)
    if (code != 0) {
        return tencentFlashStatus("provider_error", ok: false, message: "Tencent Flash ASR failed with code ${code}.")
    }
    let transcript = tencentFlashExtractTranscript(payload)
    if (transcript.isEmpty()) {
        return tencentFlashStatus("empty_result", ok: false, message: "Tencent Flash ASR returned an empty transcript.")
    }
    let out = tencentFlashStatus("ok", ok: true)
    out.put("transcript", JsonString(transcript))
    out.put("providerKind", JsonString("tencent-flash"))
    return out
}

private func tencentFlashReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func tencentFlashNativePost(request: JsonObject, audio: Array<Byte>): GatewaySpeechAsrTencentFlashHttpResult {
    let url = tencentFlashString(request, "url")
    let timeoutMs = max(1, tencentFlashInt(request, "timeoutMs", 30000))
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * timeoutMs)
    if (url.startsWith("https")) {
        var tlsConfig = TlsClientConfig()
        tlsConfig.domain = URL.parse(url).hostName
        tlsConfig.alpnProtocolsList = ["http/1.1"]
        builder.tlsConfig(tlsConfig)
    }
    let client = builder.build()
    try {
        let reqBuilder = HttpRequestBuilder().url(url).post().body(audio)
        reqBuilder.header("Authorization", tencentFlashString(request, "authorization"))
        reqBuilder.header("Content-Type", "application/octet-stream")
        let response = client.send(reqBuilder.build())
        let bytes = tencentFlashReadAllBytes(response)
        let body = try { String.fromUtf8(bytes) } catch (_: Exception) { "" }
        return GatewaySpeechAsrTencentFlashHttpResult(Int64(response.status), body: body)
    } finally {
        client.close()
    }
}

private func tencentFlashPost(request: JsonObject, audio: Array<Byte>): GatewaySpeechAsrTencentFlashHttpResult {
    match (tencentFlashRunnerOverride) {
        case Some(runner) => runner(request, audio)
        case None => tencentFlashNativePost(request, audio)
    }
}

public func gatewaySpeechAsrTencentFlashTranscribeAudio(config: JsonObject, audio: Array<Byte>, timestamp!: Int64 = 0): JsonObject {
    let maxBytes = tencentFlashInt(config, "maxBytes", 0)
    if (maxBytes > 0 && Int64(audio.size) > maxBytes) {
        let out = tencentFlashStatus("too_large", ok: false, message: "audio input exceeds configured maxBytes")
        out.put("fileBytes", JsonInt(Int64(audio.size)))
        out.put("limitBytes", JsonInt(maxBytes))
        return out
    }
    if (tencentFlashConfigString(config, "appId").isEmpty() ||
        tencentFlashConfigString(config, "secretId").isEmpty() ||
        tencentFlashConfigString(config, "secretKey").isEmpty()) {
        return tencentFlashStatus("not_configured", ok: false, message: "Tencent Flash ASR credentials are not configured.")
    }
    let request = gatewaySpeechAsrTencentFlashBuildRequest(config, if (timestamp > 0) { timestamp } else { tencentFlashNowSeconds() })
    try {
        let result = tencentFlashPost(request, audio)
        return gatewaySpeechAsrTencentFlashParseResponse(result.statusCode, if (result.body.isEmpty()) { result.error } else { result.body })
    } catch (_: Exception) {
        return tencentFlashStatus("provider_error", ok: false, message: "Tencent Flash ASR request failed.")
    }
}
