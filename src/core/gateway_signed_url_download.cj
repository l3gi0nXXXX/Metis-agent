package metis.core

import std.collection.ArrayList
import std.time.*
import stdx.encoding.json.JsonObject
import stdx.net.http.*

public class GatewaySignedUrlDownloadResult {
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

private var gatewaySignedUrlHttpSendOverrideForTest:
    Option<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult> =
        None<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult>

public func setGatewaySignedUrlHttpSendForTest(
    runner: Option<(String, String, Int64, Int64, JsonObject) -> GatewaySignedUrlDownloadResult>
): Unit {
    gatewaySignedUrlHttpSendOverrideForTest = runner
}

private func gatewaySignedUrlMinIndex(current: Int64, base: Int64, found: Option<Int64>): Int64 {
    match (found) {
        case Some(idx) => min(current, base + idx)
        case None => current
    }
}

private func gatewaySignedUrlRequestTargetStart(url: String): Int64 {
    match (url.indexOf("://")) {
        case Some(schemeEnd) =>
            let authorityStart = schemeEnd + 3
            let rest = url[authorityStart..]
            var targetStart = Int64(url.size)
            targetStart = gatewaySignedUrlMinIndex(targetStart, authorityStart, rest.indexOf("/"))
            targetStart = gatewaySignedUrlMinIndex(targetStart, authorityStart, rest.indexOf("?"))
            targetStart = gatewaySignedUrlMinIndex(targetStart, authorityStart, rest.indexOf("#"))
            targetStart
        case None => 0
    }
}

public func gatewaySignedUrlProtectPercentEncodingForHttpBuilder(rawUrl: String): String {
    let trimmed = rawUrl.trimAscii()
    if (!trimmed.contains("%")) {
        return trimmed
    }
    let targetStart = gatewaySignedUrlRequestTargetStart(trimmed)
    let prefix = trimmed[..targetStart]
    let requestTarget = trimmed[targetStart..]
    if (!requestTarget.contains("%")) {
        return trimmed
    }
    prefix + requestTarget.replace("%", "%25")
}

private func gatewaySignedUrlReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func gatewaySignedUrlSafeError(err: String): String {
    let trimmed = err.trimAscii()
    if (trimmed.isEmpty()) {
        return "signed URL download failed"
    }
    let lower = trimmed.toAsciiLower()
    if (
        trimmed.contains("?") ||
        lower.contains("signature=") ||
        lower.contains("ossaccesskeyid=") ||
        lower.contains("expires=") ||
        lower.contains("x-amz-credential=")
    ) {
        return "signed URL download failed"
    }
    if (trimmed.size > 300) {
        return trimmed[..300]
    }
    trimmed
}

private func gatewaySignedUrlNormalizeResult(result: GatewaySignedUrlDownloadResult, maxBytes: Int64): GatewaySignedUrlDownloadResult {
    if (result.statusCode >= 200 && result.statusCode < 300 && maxBytes > 0 && Int64(result.bodyBytes.size) > maxBytes) {
        return GatewaySignedUrlDownloadResult(413, error: "downloaded media exceeds maxBytes")
    }
    let safeError = if (result.error.trimAscii().isEmpty()) { "" } else { gatewaySignedUrlSafeError(result.error) }
    GatewaySignedUrlDownloadResult(result.statusCode, bodyBytes: result.bodyBytes, error: safeError, contentType: result.contentType)
}

public func gatewaySignedUrlDownload(
    rawUrl: String,
    timeoutMs: Int64,
    maxBytes: Int64,
    providerConfig: JsonObject
): GatewaySignedUrlDownloadResult {
    let originalUrl = rawUrl.trimAscii()
    let builderUrl = gatewaySignedUrlProtectPercentEncodingForHttpBuilder(originalUrl)
    match (gatewaySignedUrlHttpSendOverrideForTest) {
        case Some(runner) =>
            return gatewaySignedUrlNormalizeResult(runner(builderUrl, originalUrl, timeoutMs, maxBytes, providerConfig), maxBytes)
        case None => ()
    }

    try {
        let transportConfig = resolveGatewayProviderHttpTransportConfig(providerConfig)
        let clientParts = buildGatewayProviderHttpClientBuilder(originalUrl, transportConfig)
        let client = clientParts[0].build()
        try {
            let response = client.send(HttpRequestBuilder().url(builderUrl).get().build())
            let bytes = gatewaySignedUrlReadAllBytes(response)
            let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
            return gatewaySignedUrlNormalizeResult(
                GatewaySignedUrlDownloadResult(Int64(response.status), bodyBytes: bytes, contentType: contentType),
                maxBytes
            )
        } finally {
            client.close()
        }
    } catch (e: Exception) {
        GatewaySignedUrlDownloadResult(0, error: gatewaySignedUrlSafeError(e.message))
    }
}
