package metis.core

import std.convert.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

public class MediaDiagnosticEvent {
    public static const mediaInboundDetected: String = "media.inbound.detected"
    public static const mediaDownloadStarted: String = "media.download.started"
    public static const mediaDownloadFinished: String = "media.download.finished"
    public static const mediaDownloadFailed: String = "media.download.failed"
    public static const mediaPreflightStarted: String = "media.preflight.started"
    public static const mediaPreflightFinished: String = "media.preflight.finished"
    public static const mediaUnderstandingStarted: String = "media.understanding.started"
    public static const mediaUnderstandingAttempt: String = "media.understanding.attempt"
    public static const mediaUnderstandingFinished: String = "media.understanding.finished"
    public static const mediaUnderstandingFailed: String = "media.understanding.failed"
    public static const mediaPromptInjected: String = "media.prompt.injected"
    public static const mediaGenerationStarted: String = "media.generation.started"
    public static const mediaGenerationAttempt: String = "media.generation.attempt"
    public static const mediaGenerationPoll: String = "media.generation.poll"
    public static const mediaGenerationDownload: String = "media.generation.download"
    public static const mediaGenerationFinished: String = "media.generation.finished"
    public static const mediaGenerationFailed: String = "media.generation.failed"
    public static const mediaOutboundResolve: String = "media.outbound.resolve"
    public static const mediaOutboundUpload: String = "media.outbound.upload"
    public static const mediaOutboundSend: String = "media.outbound.send"
    public static const mediaOutboundFailed: String = "media.outbound.failed"
    public static const mediaToolInvoked: String = "media.tool.invoked"
    public static const mediaToolResult: String = "media.tool.result"
    public static const mediaToolFailed: String = "media.tool.failed"
}

public interface GatewayMediaDiagnosticSink {
    func emit(level: String, event: String, message: String, meta: JsonObject): Unit
}

private var gatewayMediaDiagnosticSink: Option<GatewayMediaDiagnosticSink> =
    None<GatewayMediaDiagnosticSink>

public func setGatewayMediaDiagnosticSinkForRuntime(sink: Option<GatewayMediaDiagnosticSink>): Unit {
    gatewayMediaDiagnosticSink = sink
}

public func resetGatewayMediaDiagnosticSinkForTest(): Unit {
    gatewayMediaDiagnosticSink = None<GatewayMediaDiagnosticSink>
}

public func emitGatewayMediaDiagnostic(
    level: String,
    event: String,
    message: String,
    meta!: JsonObject = JsonObject()
): Unit {
    match (gatewayMediaDiagnosticSink) {
        case Some(sink) =>
            try {
                sink.emit(level.trimAscii(), event.trimAscii(), message, meta)
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
}

private func mediaDiagnosticString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func mediaDiagnosticInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(v.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func mediaDiagnosticObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func mediaDiagnosticStableHash(text: String): String {
    var hash: Int64 = 5381
    let modulus: Int64 = 1000000007
    for (b in text.toArray()) {
        hash = ((hash * 33) % modulus + (Int64(b) % modulus)) % modulus
    }
    hash.toString()
}

private func mediaDiagnosticBasename(path: String): String {
    let normalized = path.trimAscii().replace("\\", "/")
    if (normalized.isEmpty()) {
        return ""
    }
    var lastSlash: Int64 = -1
    for (i in 0..normalized.size) {
        if (normalized[i] == UInt8(47)) {
            lastSlash = i
        }
    }
    if (lastSlash >= 0 && lastSlash < normalized.size - 1) {
        normalized[lastSlash + 1..]
    } else if (lastSlash == normalized.size - 1) {
        ""
    } else {
        normalized
    }
}

private func mediaDiagnosticSafePathRoot(path: String, managedRoot: String): String {
    let root = managedRoot.trimAscii()
    if (root.isEmpty()) {
        return ""
    }
    if (path == root || path.startsWith("${root}/")) {
        return "managed"
    }
    ""
}

public func mediaDiagnosticPathMeta(path: String, managedRoot!: String = ""): JsonObject {
    let normalized = path.trimAscii()
    let root = managedRoot.trimAscii()
    let out = JsonObject()
    let isManaged = !root.isEmpty() && (normalized == root || normalized.startsWith("${root}/"))
    out.put("pathKind", JsonString(if (normalized.isEmpty()) { "empty" } else if (isManaged) { "managed" } else { "external" }))
    out.put("pathBasename", JsonString(mediaDiagnosticBasename(normalized)))
    out.put("pathRoot", JsonString(mediaDiagnosticSafePathRoot(normalized, root)))
    if (!normalized.isEmpty()) {
        out.put("pathHash", JsonString(mediaDiagnosticStableHash(normalized)))
    }
    out
}

private func mediaDiagnosticStripQuery(url: String): String {
    let trimmed = url.trimAscii()
    match (trimmed.indexOf("?")) {
        case Some(i) => trimmed[..i]
        case None => trimmed
    }
}

private func mediaDiagnosticUrlPath(url: String): String {
    let trimmed = url.trimAscii()
    if (trimmed.startsWith("data:")) {
        return "[redacted-data-url]"
    }
    let withoutQuery = mediaDiagnosticStripQuery(trimmed)
    match (withoutQuery.indexOf("://")) {
        case Some(schemeEnd) =>
            let hostStart = schemeEnd + 3
            match (withoutQuery.indexOf("/", hostStart)) {
                case Some(pathStart) => withoutQuery[pathStart..]
                case None => "/"
            }
        case None => if (withoutQuery.startsWith("/")) { withoutQuery } else { "" }
    }
}

private func mediaDiagnosticTargetHost(url: String): String {
    let trimmed = url.trimAscii()
    if (trimmed.startsWith("data:")) {
        return ""
    }
    let withoutQuery = mediaDiagnosticStripQuery(trimmed)
    match (withoutQuery.indexOf("://")) {
        case Some(schemeEnd) =>
            let hostStart = schemeEnd + 3
            let hostEnd = match (withoutQuery.indexOf("/", hostStart)) {
                case Some(pathStart) => pathStart
                case None => withoutQuery.size
            }
            withoutQuery[hostStart..hostEnd]
        case None => ""
    }
}

private func mediaDiagnosticRedactProxy(raw: String): String {
    let value = raw.trimAscii()
    match (value.indexOf("://")) {
        case Some(schemeEnd) =>
            let authStart = schemeEnd + 3
            let pathStart = match (value.indexOf("/", authStart)) {
                case Some(i) => i
                case None => value.size
            }
            let authority = value[authStart..pathStart]
            match (authority.indexOf("@")) {
                case Some(at) => value[..authStart] + "[redacted]@" + authority[at + 1..] + value[pathStart..]
                case None => value
            }
        case None => value
    }
}

private func mediaDiagnosticCopyTransportRoute(route: JsonObject): JsonObject {
    let out = JsonObject()
    for (key in ["mode", "proxySource", "targetHost", "error"]) {
        let value = mediaDiagnosticString(route, key)
        if (!value.isEmpty()) {
            out.put(key, JsonString(value))
        }
    }
    let proxy = mediaDiagnosticString(route, "redactedProxy")
    if (!proxy.isEmpty()) {
        out.put("redactedProxy", JsonString(mediaDiagnosticRedactProxy(proxy)))
    }
    out
}

public func mediaDiagnosticHttpMetaFromRequest(
    request: JsonObject,
    method!: String = "",
    statusCode!: Int64 = 0,
    contentType!: String = "",
    responseBytes!: Int64 = 0,
    elapsedMs!: Int64 = 0
): JsonObject {
    let out = JsonObject()
    let url = mediaDiagnosticString(request, "url")
    let route = mediaDiagnosticObject(request, "transportRoute")
    let targetHost = mediaDiagnosticString(route, "targetHost")
    if (!method.trimAscii().isEmpty()) {
        out.put("method", JsonString(method.trimAscii()))
    }
    out.put("urlPath", JsonString(mediaDiagnosticUrlPath(url)))
    out.put("targetHost", JsonString(if (targetHost.isEmpty()) { mediaDiagnosticTargetHost(url) } else { targetHost }))
    out.put("statusCode", JsonInt(statusCode))
    if (!contentType.trimAscii().isEmpty()) {
        out.put("contentType", JsonString(contentType.trimAscii()))
    }
    out.put("responseBytes", JsonInt(responseBytes))
    out.put("timeoutMs", JsonInt(mediaDiagnosticInt(request, "timeoutMs", 0)))
    out.put("elapsedMs", JsonInt(elapsedMs))
    if (route.size() > 0) {
        out.put("transportRoute", mediaDiagnosticCopyTransportRoute(route))
    }
    out
}

public func mediaDiagnosticProviderMeta(
    provider: String,
    providerKind!: String = "",
    model!: String = "",
    capability!: String = ""
): JsonObject {
    let out = JsonObject()
    if (!provider.trimAscii().isEmpty()) {
        out.put("provider", JsonString(provider.trimAscii()))
    }
    if (!providerKind.trimAscii().isEmpty()) {
        out.put("providerKind", JsonString(providerKind.trimAscii()))
    }
    if (!model.trimAscii().isEmpty()) {
        out.put("model", JsonString(model.trimAscii()))
    }
    if (!capability.trimAscii().isEmpty()) {
        out.put("capability", JsonString(capability.trimAscii()))
    }
    out
}

public func mediaDiagnosticMergeMeta(left: JsonObject, right: JsonObject): JsonObject {
    let out = JsonObject()
    for (key in left.getFields().keys()) {
        match (left.get(key)) {
            case Some(value) => out.put(key, value)
            case None => ()
        }
    }
    for (key in right.getFields().keys()) {
        match (right.get(key)) {
            case Some(value) => out.put(key, value)
            case None => ()
        }
    }
    out
}
