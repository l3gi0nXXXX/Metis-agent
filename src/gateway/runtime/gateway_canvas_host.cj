package metis.gateway.runtime

import magic.jsonable.*

import metis.gateway.core.GATEWAY_CONTROL_UI_CLIENT_NAME
import metis.gateway.model.GatewayConfig

import std.collection.ArrayList
import std.fs.{Directory, File, FileInfo, Path, canonicalize, exists}
import std.sort.*
import std.sync.Mutex
import std.time.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}
import stdx.log.*
import stdx.net.http.*

public class GatewayCanvasResolveResult {
    public let ok: Bool
    public let status: String
    public let path: String
    public let relativePath: String
    public let mimeType: String

    public init(
        ok: Bool,
        status: String,
        path!: String = "",
        relativePath!: String = "",
        mimeType!: String = ""
    ) {
        this.ok = ok
        this.status = status
        this.path = path
        this.relativePath = relativePath
        this.mimeType = mimeType
    }
}

private func gatewayCanvasHexNibble(r: Rune): Int64 {
    match (r) {
        case r'0' => 0
        case r'1' => 1
        case r'2' => 2
        case r'3' => 3
        case r'4' => 4
        case r'5' => 5
        case r'6' => 6
        case r'7' => 7
        case r'8' => 8
        case r'9' => 9
        case r'a' | r'A' => 10
        case r'b' | r'B' => 11
        case r'c' | r'C' => 12
        case r'd' | r'D' => 13
        case r'e' | r'E' => 14
        case r'f' | r'F' => 15
        case _ => -1
    }
}

private func gatewayCanvasPercentDecodePath(raw: String): String {
    let runes = raw.toRuneArray()
    let out = StringBuilder()
    var i: Int64 = 0
    while (i < runes.size) {
        let ch = runes[i]
        if (ch == r'?' || ch == r'#') {
            break
        }
        if (ch == r'%' && i + 2 < runes.size) {
            let hi = gatewayCanvasHexNibble(runes[i + 1])
            let lo = gatewayCanvasHexNibble(runes[i + 2])
            if (hi >= 0 && lo >= 0) {
                let value = hi * 16 + lo
                if (value >= 0 && value <= 127) {
                    out.append(String.fromUtf8([UInt8(value)]))
                    i += 3
                    continue
                }
            }
        }
        if (ch == r'\\') {
            out.append(r'/')
        } else {
            out.append(ch)
        }
        i += 1
    }
    out.toString()
}

private func gatewayCanvasPathHasTraversal(decoded: String): Bool {
    for (part in decoded.split("/")) {
        let seg = part.trimAscii()
        if (seg == ".." || seg.contains("\u{0}")) {
            return true
        }
    }
    false
}

public func gatewayCanvasNormalizeUrlPath(raw: String): String {
    let decoded = gatewayCanvasPercentDecodePath(raw.trimAscii())
    let parts = ArrayList<String>()
    for (part in decoded.split("/")) {
        let seg = part.trimAscii()
        if (seg.isEmpty() || seg == ".") {
            continue
        }
        if (seg == "..") {
            parts.add("..")
        } else {
            parts.add(seg)
        }
    }
    if (parts.isEmpty()) {
        return "/"
    }
    let out = StringBuilder("/")
    var first = true
    for (part in parts) {
        if (!first) {
            out.append(r'/')
        }
        out.append(part)
        first = false
    }
    out.toString()
}

private func gatewayCanvasPathInsideRoot(root: String, candidate: String): Bool {
    candidate == root || candidate.startsWith(root + "/")
}

private func gatewayCanvasRelativeFromNormalized(normalized: String): String {
    if (normalized == "/") {
        return "index.html"
    }
    let runes = normalized.toRuneArray()
    if (runes.size <= 1) {
        return "index.html"
    }
    if (runes[0] == r'/') {
        return String(runes[1..])
    }
    normalized
}

public func gatewayCanvasResolveFileWithinRoot(root: Path, requestPath: String): GatewayCanvasResolveResult {
    let decoded = gatewayCanvasPercentDecodePath(requestPath.trimAscii())
    if (decoded.isEmpty() || gatewayCanvasPathHasTraversal(decoded)) {
        return GatewayCanvasResolveResult(false, "blocked")
    }
    let rootCanonical = try {
        canonicalize(root).toString()
    } catch (_: Exception) {
        return GatewayCanvasResolveResult(false, "root-missing")
    }
    if (!exists(Path(rootCanonical)) || !FileInfo(Path(rootCanonical)).isDirectory()) {
        return GatewayCanvasResolveResult(false, "root-unavailable")
    }
    let normalized = gatewayCanvasNormalizeUrlPath(decoded)
    let relative = gatewayCanvasRelativeFromNormalized(normalized)
    let candidate = Path(rootCanonical).join(relative)
    let candidateCanonical = try {
        canonicalize(candidate).toString()
    } catch (_: Exception) {
        return GatewayCanvasResolveResult(false, "missing", relativePath: relative)
    }
    if (!gatewayCanvasPathInsideRoot(rootCanonical, candidateCanonical)) {
        return GatewayCanvasResolveResult(false, "blocked", relativePath: relative)
    }
    GatewayCanvasResolveResult(
        true,
        "ok",
        path: candidateCanonical,
        relativePath: relative,
        mimeType: gatewayCanvasMimeType(relative)
    )
}

public func gatewayCanvasMimeType(path: String): String {
    let lower = path.toAsciiLower()
    if (lower.endsWith(".html") || lower.endsWith(".htm")) { return "text/html; charset=utf-8" }
    if (lower.endsWith(".js") || lower.endsWith(".mjs")) { return "text/javascript; charset=utf-8" }
    if (lower.endsWith(".css")) { return "text/css; charset=utf-8" }
    if (lower.endsWith(".json")) { return "application/json; charset=utf-8" }
    if (lower.endsWith(".svg")) { return "image/svg+xml" }
    if (lower.endsWith(".png")) { return "image/png" }
    if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) { return "image/jpeg" }
    if (lower.endsWith(".webp")) { return "image/webp" }
    if (lower.endsWith(".wasm")) { return "application/wasm" }
    "application/octet-stream"
}

private const GATEWAY_CANVAS_ROUTE_PREFIX: String = "/__metis__/canvas"

private func gatewayCanvasPortToUInt16(v: Int64, fallback: UInt16): UInt16 {
    if (v <= 0 || v > 65535) {
        return fallback
    }
    UInt16(v)
}

public func gatewayCanvasBaseUrl(cfg: GatewayConfig): String {
    "http://127.0.0.1:${gatewayCanvasPortToUInt16(cfg.canvas.port, 18793u16)}${GATEWAY_CANVAS_ROUTE_PREFIX}/"
}

public func gatewayCanvasScopedRouteUrl(cfg: GatewayConfig, token: String): String {
    "http://127.0.0.1:${gatewayCanvasPortToUInt16(cfg.canvas.port, 18793u16)}${GATEWAY_CANVAS_ROUTE_PREFIX}/cap/${token.trimAscii()}/"
}

public func gatewayCanvasA2uiScopedRouteUrl(cfg: GatewayConfig, token: String): String {
    "http://127.0.0.1:${gatewayCanvasPortToUInt16(cfg.canvas.port, 18793u16)}${gatewayCanvasA2uiRoutePrefix()}/cap/${token.trimAscii()}/"
}

private func gatewayCanvasCanServePath(path: String): Bool {
    let lower = path.toAsciiLower()
    lower.endsWith(".html") ||
    lower.endsWith(".htm") ||
    lower.endsWith(".js") ||
    lower.endsWith(".mjs") ||
    lower.endsWith(".css") ||
    lower.endsWith(".json") ||
    lower.endsWith(".svg") ||
    lower.endsWith(".png") ||
    lower.endsWith(".jpg") ||
    lower.endsWith(".jpeg") ||
    lower.endsWith(".webp") ||
    lower.endsWith(".wasm")
}

private func gatewayCanvasRouteForRelative(relative: String): String {
    let trimmed = gatewayCanvasNormalizeUrlPath(relative)
    if (trimmed == "/" || trimmed == "/index.html") {
        return GATEWAY_CANVAS_ROUTE_PREFIX + "/"
    }
    GATEWAY_CANVAS_ROUTE_PREFIX + trimmed
}

private func gatewayCanvasRemovePrefix(text: String, prefix: String): String {
    if (!text.startsWith(prefix)) {
        return text
    }
    let textRunes = text.toRuneArray()
    let prefixSize = prefix.toRuneArray().size
    if (textRunes.size <= prefixSize) {
        return ""
    }
    String(textRunes[prefixSize..])
}

private func gatewayCanvasScanRoutesUnder(root: Path, dir: Path, out: ArrayList<String>): Unit {
    let rootPrefix = root.normalize().toString().replace("\\", "/")
    let rootPrefixWithSlash = if (rootPrefix.endsWith("/")) { rootPrefix } else { rootPrefix + "/" }
    for (entry in Directory.readFrom(dir)) {
        let path = entry.path
        if (entry.isDirectory()) {
            gatewayCanvasScanRoutesUnder(root, path, out)
            continue
        }
        let info = FileInfo(path)
        if (!info.isRegular()) {
            continue
        }
        let full = path.normalize().toString().replace("\\", "/")
        if (!full.startsWith(rootPrefixWithSlash)) {
            continue
        }
        let rel = gatewayCanvasRemovePrefix(full, rootPrefixWithSlash)
        if (rel.isEmpty() || !gatewayCanvasCanServePath(rel)) {
            continue
        }
        let routePath = gatewayCanvasRouteForRelative(rel)
        if (!out.contains(routePath)) {
            out.add(routePath)
        }
    }
}

private func gatewayCanvasCanonicalRegisteredRoutes(cfg: GatewayConfig): JsonArray {
    let routes = ArrayList<String>()
    if (!cfg.canvas.enabled || cfg.canvas.root.trimAscii().isEmpty()) {
        return JsonArray([])
    }
    let root = Path(cfg.canvas.root)
    let rootReady = try {
        exists(root) && FileInfo(root).isDirectory()
    } catch (_: Exception) {
        false
    }
    if (!rootReady) {
        return JsonArray([])
    }
    routes.add(GATEWAY_CANVAS_ROUTE_PREFIX)
    routes.add(GATEWAY_CANVAS_ROUTE_PREFIX + "/")
    gatewayCanvasScanRoutesUnder(root, root, routes)
    let out = JsonArray([])
    for (route in routes) {
        out.add(JsonString(route))
    }
    out
}

private func gatewayCanvasAppendCompatRoutes(cfg: GatewayConfig, routes: JsonArray): JsonArray {
    if (!gatewayCanvasCompatRoutesEnabled(cfg)) {
        return routes
    }
    let out = JsonArray([])
    let seen = ArrayList<String>()
    for (routeValue in routes.getItems()) {
        let route = try {
            routeValue.asString().getValue()
        } catch (_: Exception) {
            ""
        }
        if (route.trimAscii().isEmpty()) {
            continue
        }
        if (!seen.contains(route)) {
            out.add(JsonString(route))
            seen.add(route)
        }
        let compatRoute = gatewayCanvasOpenClawCompatPath(route)
        if (!seen.contains(compatRoute)) {
            out.add(JsonString(compatRoute))
            seen.add(compatRoute)
        }
    }
    out
}

public func gatewayCanvasRegisteredRoutes(cfg: GatewayConfig): JsonArray {
    gatewayCanvasAppendCompatRoutes(cfg, gatewayCanvasCanonicalRegisteredRoutes(cfg))
}

private func gatewayCanvasRequestPathFromRoute(routePath: String): String {
    if (routePath == GATEWAY_CANVAS_ROUTE_PREFIX || routePath == GATEWAY_CANVAS_ROUTE_PREFIX + "/") {
        return "/"
    }
    let prefix = GATEWAY_CANVAS_ROUTE_PREFIX + "/"
    if (!routePath.startsWith(prefix)) {
        return "/"
    }
    let runes = routePath.toRuneArray()
    let prefixSize = prefix.toRuneArray().size
    if (runes.size <= prefixSize) {
        return "/"
    }
    "/" + String(runes[prefixSize..])
}

private func gatewayCanvasA2uiRequestPathFromRoute(routePath: String): String {
    let prefix = gatewayCanvasA2uiRoutePrefix()
    if (routePath == prefix || routePath == prefix + "/") {
        return "/"
    }
    let prefixWithSlash = prefix + "/"
    if (!routePath.startsWith(prefixWithSlash)) {
        return "/"
    }
    let runes = routePath.toRuneArray()
    let prefixSize = prefixWithSlash.toRuneArray().size
    if (runes.size <= prefixSize) {
        return "/"
    }
    "/" + String(runes[prefixSize..])
}

private func gatewayCanvasA2uiScopedRouteFor(token: String, routePath: String): String {
    let normalizedToken = token.trimAscii()
    let prefix = gatewayCanvasA2uiRoutePrefix()
    if (routePath == prefix || routePath == prefix + "/") {
        return prefix + "/cap/${normalizedToken}/"
    }
    let prefixWithSlash = prefix + "/"
    if (!routePath.startsWith(prefixWithSlash)) {
        return prefix + "/cap/${normalizedToken}/"
    }
    let runes = routePath.toRuneArray()
    let prefixSize = prefixWithSlash.toRuneArray().size
    if (runes.size <= prefixSize) {
        return prefix + "/cap/${normalizedToken}/"
    }
    prefix + "/cap/${normalizedToken}/" + String(runes[prefixSize..])
}

private func gatewayCanvasHttpMethodAllowed(method: String): Bool {
    let normalized = method.trimAscii().toAsciiUpper()
    normalized == "GET" || normalized == "HEAD"
}

private func gatewayCanvasHttpBodyForMethod(method: String, body: Array<Byte>): Array<Byte> {
    if (method.trimAscii().toAsciiUpper() == "HEAD") {
        return Array<Byte>(0, repeat: 0)
    }
    body
}

private func gatewayCanvasReadRequestBody(ctx: HttpContext, maxBytes!: Int64 = 64 * 1024): (Bool, String) {
    let chunks = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    try {
        while (true) {
            let n = ctx.request.body.read(buffer)
            if (n <= 0) {
                break
            }
            if (chunks.size + n > maxBytes) {
                return (false, "")
            }
            chunks.add(all: buffer[..n])
        }
        return (true, String.fromUtf8(chunks.toArray()))
    } catch (_: Exception) {
        (false, "")
    }
}

private func gatewayCanvasReplyUnauthorized(ctx: HttpContext): Unit {
    let rb = ctx.responseBuilder
    rb.status(401)
    rb.header("content-type", "text/plain; charset=utf-8")
    rb.body("canvas capability required")
}

private func gatewayCanvasReplyJson(ctx: HttpContext, status: UInt16, body: String): Unit {
    let rb = ctx.responseBuilder
    rb.status(status)
    rb.header("content-type", "application/json; charset=utf-8")
    rb.header("cache-control", "no-cache")
    rb.body(body)
}

private func gatewayCanvasReplyAsset(ctx: HttpContext, root: Path, requestPath: String, token: String): Unit {
    let rb = ctx.responseBuilder
    let auth = gatewayCanvasAuthorizeCapabilityToken(token)
    if (!auth.ok) {
        gatewayCanvasReplyUnauthorized(ctx)
        return
    }
    let method = ctx.request.method
    if (!gatewayCanvasHttpMethodAllowed(method)) {
        rb.status(405)
        rb.header("allow", "GET, HEAD")
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("Method Not Allowed")
        return
    }
    let resolved = gatewayCanvasResolveFileWithinRoot(root, requestPath)
    if (!resolved.ok) {
        rb.status(404)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas asset not found")
        return
    }
    let filePath = Path(resolved.path)
    if (!exists(filePath) || !FileInfo(filePath).isRegular()) {
        rb.status(404)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas asset not found")
        return
    }
    try {
        rb.header("content-type", resolved.mimeType)
        rb.header("cache-control", "no-cache")
        rb.body(gatewayCanvasHttpBodyForMethod(method, File.readFrom(filePath)))
    } catch (_: Exception) {
        rb.status(500)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas asset read failed")
    }
}

private func gatewayCanvasReplyA2uiAsset(ctx: HttpContext, requestPath: String, token: String): Unit {
    let rb = ctx.responseBuilder
    let auth = gatewayCanvasAuthorizeCapabilityToken(token)
    if (!auth.ok) {
        gatewayCanvasReplyUnauthorized(ctx)
        return
    }
    let method = ctx.request.method
    if (!gatewayCanvasHttpMethodAllowed(method)) {
        rb.status(405)
        rb.header("allow", "GET, HEAD")
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("Method Not Allowed")
        return
    }
    let rootState = gatewayCanvasResolveA2uiRootState()
    if (!gatewayCanvasReadBool(rootState, "rootPresent", false) ||
        !gatewayCanvasReadBool(rootState, "rootReadable", false) ||
        gatewayCanvasReadString(rootState, "errorKind", "") != "") {
        rb.status(503)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas a2ui assets unavailable")
        return
    }
    let resolved = gatewayCanvasResolveFileWithinRoot(gatewayCanvasA2uiAssetRoot(), requestPath)
    if (!resolved.ok) {
        rb.status(404)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas a2ui asset not found")
        return
    }
    let filePath = Path(resolved.path)
    if (!exists(filePath) || !FileInfo(filePath).isRegular()) {
        rb.status(404)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas a2ui asset not found")
        return
    }
    try {
        rb.header("content-type", resolved.mimeType)
        rb.header("cache-control", "no-cache")
        let body = File.readFrom(filePath)
        if (resolved.relativePath == "index.html") {
            let html = String.fromUtf8(body)
            rb.body(gatewayCanvasHttpBodyForMethod(method, gatewayCanvasInjectBridgeAndLiveReload(html).toArray()))
        } else {
            rb.body(gatewayCanvasHttpBodyForMethod(method, body))
        }
    } catch (_: Exception) {
        rb.status(500)
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("canvas a2ui asset read failed")
    }
}

private func gatewayCanvasReplyA2uiAction(ctx: HttpContext, token: String): Unit {
    let auth = gatewayCanvasAuthorizeCapabilityToken(token)
    if (!auth.ok) {
        gatewayCanvasReplyUnauthorized(ctx)
        return
    }
    if (ctx.request.method.trimAscii().toAsciiUpper() != "POST") {
        let rb = ctx.responseBuilder
        rb.status(405)
        rb.header("allow", "POST")
        rb.header("content-type", "text/plain; charset=utf-8")
        rb.body("Method Not Allowed")
        return
    }
    let body = gatewayCanvasReadRequestBody(ctx)
    if (!body[0]) {
        gatewayCanvasReplyJson(ctx, 400u16, GatewayRpcResponse(false, "canvas.a2ui.action", error: "invalid request body", errorCode: "invalid_request").toJson().toJsonString())
        return
    }
    let params = try {
        JsonValue.fromStr(body[1]).asObject()
    } catch (_: Exception) {
        gatewayCanvasReplyJson(ctx, 400u16, GatewayRpcResponse(false, "canvas.a2ui.action", error: "malformed JSON body", errorCode: "malformed_json").toJson().toJsonString())
        return
    }
    params.put("capabilityToken", JsonString(token.trimAscii()))
    let response = gatewayCanvasHandleA2uiUserAction(
        GatewayRpcRequest("canvas.a2ui.action", params: params, clientId: auth.nodeId, mode: "node")
    )
    gatewayCanvasReplyJson(ctx, if (response.ok) { 200u16 } else { 400u16 }, response.toJson().toJsonString())
}

private func gatewayCanvasReadBool(obj: JsonObject, key: String, defaultValue: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { defaultValue }
        case None => defaultValue
    }
}

private func gatewayCanvasReadString(obj: JsonObject, key: String, defaultValue: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { defaultValue }
        case None => defaultValue
    }
}

private func gatewayCanvasNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func gatewayCanvasFileMtimeMs(path: Path): Int64 {
    try {
        FileInfo(path).lastModificationTime.toUnixTimeStamp().toMilliseconds()
    } catch (_: Exception) {
        0
    }
}

private func gatewayCanvasScanMaxMtimeMs(root: Path): Int64 {
    var maxMtime = gatewayCanvasFileMtimeMs(root)
    try {
        for (entry in Directory.readFrom(root)) {
            if (entry.isDirectory()) {
                let nested = gatewayCanvasScanMaxMtimeMs(entry.path)
                if (nested > maxMtime) {
                    maxMtime = nested
                }
                continue
            }
            let info = FileInfo(entry.path)
            if (!info.isRegular()) {
                continue
            }
            let mtime = gatewayCanvasFileMtimeMs(entry.path)
            if (mtime > maxMtime) {
                maxMtime = mtime
            }
        }
    } catch (_: Exception) {
        ()
    }
    maxMtime
}

private func gatewayCanvasAppendFilesystemSignature(root: Path, dir: Path, out: ArrayList<String>): Unit {
    let entries = ArrayList<FileInfo>()
    try {
        for (entry in Directory.readFrom(dir)) {
            entries.add(entry)
        }
    } catch (_: Exception) {
        out.add("error|${dir.normalize().toString()}")
        return
    }
    sort(entries, by: { a, b => a.path.normalize().toString().compare(b.path.normalize().toString()) })
    let rootPrefix = root.normalize().toString().replace("\\", "/")
    let rootPrefixWithSlash = if (rootPrefix.endsWith("/")) { rootPrefix } else { rootPrefix + "/" }
    for (entry in entries) {
        let path = entry.path
        let full = path.normalize().toString().replace("\\", "/")
        let relative = if (full.startsWith(rootPrefixWithSlash)) {
            gatewayCanvasRemovePrefix(full, rootPrefixWithSlash)
        } else {
            full
        }
        if (entry.isDirectory()) {
            out.add("dir|${relative}|${gatewayCanvasFileMtimeMs(path)}")
            gatewayCanvasAppendFilesystemSignature(root, path, out)
            continue
        }
        let info = try {
            FileInfo(path)
        } catch (_: Exception) {
            out.add("error|${relative}")
            continue
        }
        if (!info.isRegular()) {
            continue
        }
        out.add("file|${relative}|${gatewayCanvasFileMtimeMs(path)}|${info.size}")
    }
}

private func gatewayCanvasFilesystemSignature(root: Path): String {
    let lines = ArrayList<String>()
    lines.add("root|${gatewayCanvasFileMtimeMs(root)}")
    gatewayCanvasAppendFilesystemSignature(root, root, lines)
    String.join(lines.toArray(), delimiter: "\n")
}

private var gatewayCanvasLiveReloadPublisherForTest: Option<(JsonObject) -> Int64> = None<(JsonObject) -> Int64>

public func debugSetGatewayCanvasLiveReloadPublisherForTest(runner: Option<(JsonObject) -> Int64>): Unit {
    gatewayCanvasLiveReloadPublisherForTest = runner
}

private func gatewayCanvasPublishLiveReloadEvent(payload: JsonObject): Int64 {
    match (gatewayCanvasLiveReloadPublisherForTest) {
        case Some(runner) => runner(payload)
        case None =>
            gatewayServerPublishEventToMatchingClients(
                "control-ui.canvas.reload",
                detail: "reload",
                payload: payload,
                predicate: { _clientId, clientName, clientMode =>
                    clientName.trimAscii() == GATEWAY_CONTROL_UI_CLIENT_NAME ||
                    clientMode.trimAscii() == "control-ui-browser"
                }
            )
    }
}

public class GatewayCanvasHostRuntime {
    private static let lock = Mutex()
    private static var started: Bool = false
    private static var server: Option<Server> = None
    private static var rootPath: String = ""
    private static var listenPort: UInt16 = 18793u16
    private static var canonicalRoutes: JsonArray = JsonArray([])
    private static var registeredRoutes: JsonArray = JsonArray([])
    private static var lastErrorKind: String = ""
    private static var liveReloadRunning: Bool = false
    private static var liveReloadStopRequested: Bool = false
    private static var liveReloadRootPath: String = ""
    private static var liveReloadLastMtimeMs: Int64 = 0
    private static var liveReloadLastSignature: String = ""
    private static var liveReloadEventCount: Int64 = 0
    private static var liveReloadLastEventAtMs: Int64 = 0
    private static var liveReloadGeneration: Int64 = 0
    private static let liveReloadPollIntervalMs: Int64 = 250

    public static func isRunning(): Bool {
        synchronized(lock) {
            started
        }
    }

    public static func startIfNeeded(cfg: GatewayConfig): Unit {
        synchronized(lock) {
            if (started) {
                return
            }
            let state = gatewayCanvasResolveRootState(cfg)
            if (!gatewayCanvasReadBool(state, "enabled", false) ||
                !gatewayCanvasReadBool(state, "rootPresent", false) ||
                !gatewayCanvasReadBool(state, "rootReadable", false)) {
                lastErrorKind = gatewayCanvasReadString(state, "errorKind", "root-unavailable")
                return
            }
            let root = Path(cfg.canvas.root)
            let canonicalRoot = try {
                canonicalize(root)
            } catch (_: Exception) {
                lastErrorKind = "root-unavailable"
                return
            }
            let s = ServerBuilder()
                .addr("127.0.0.1")
                .port(gatewayCanvasPortToUInt16(cfg.canvas.port, 18793u16))
                .build()
            s.logger.level = LogLevel.OFF
            let routes = gatewayCanvasCanonicalRegisteredRoutes(cfg)
            let publicRoutes = gatewayCanvasRegisteredRoutes(cfg)
            for (routeValue in routes.getItems()) {
                let routePath = try {
                    routeValue.asString().getValue()
                } catch (_: Exception) {
                    ""
                }
                if (routePath.trimAscii().isEmpty()) {
                    continue
                }
                let requestPath = gatewayCanvasRequestPathFromRoute(routePath)
                s.distributor.register(routePath, { ctx =>
                    gatewayCanvasReplyAsset(ctx, canonicalRoot, requestPath, "")
                })
                if (gatewayCanvasCompatRoutesEnabled(cfg)) {
                    let compatRoute = gatewayCanvasOpenClawCompatPath(routePath)
                    if (compatRoute != routePath) {
                        s.distributor.register(compatRoute, { ctx =>
                            gatewayCanvasReplyAsset(ctx, canonicalRoot, requestPath, "")
                        })
                    }
                }
            }
            for (routeValue in gatewayCanvasA2uiRegisteredRoutes().getItems()) {
                let routePath = try {
                    routeValue.asString().getValue()
                } catch (_: Exception) {
                    ""
                }
                if (routePath.trimAscii().isEmpty()) {
                    continue
                }
                s.distributor.register(routePath, { ctx =>
                    gatewayCanvasReplyUnauthorized(ctx)
                })
                if (gatewayCanvasCompatRoutesEnabled(cfg)) {
                    let compatRoute = gatewayCanvasOpenClawCompatPath(routePath)
                    if (compatRoute != routePath) {
                        s.distributor.register(compatRoute, { ctx =>
                            gatewayCanvasReplyUnauthorized(ctx)
                        })
                    }
                }
            }
            server = Some(s)
            started = true
            rootPath = canonicalRoot.toString()
            listenPort = gatewayCanvasPortToUInt16(cfg.canvas.port, 18793u16)
            canonicalRoutes = routes
            registeredRoutes = publicRoutes
            lastErrorKind = ""
            if (cfg.canvas.liveReload) {
                GatewayCanvasHostRuntime.startLiveReloadPoller(canonicalRoot)
            } else {
                GatewayCanvasHostRuntime.stopLiveReloadPollerLocked()
            }
            spawn {
                try {
                    s.serve()
                } catch (_: Exception) {
                    ()
                } finally {
                    synchronized(lock) {
                        started = false
                        server = None
                        liveReloadStopRequested = true
                        liveReloadRunning = false
                        liveReloadRootPath = ""
                    }
                }
            }
        }
    }

    private static func startLiveReloadPoller(root: Path): Unit {
        liveReloadGeneration += 1
        let generation = liveReloadGeneration
        liveReloadStopRequested = false
        liveReloadRunning = true
        liveReloadRootPath = root.toString()
        liveReloadLastMtimeMs = gatewayCanvasScanMaxMtimeMs(root)
        liveReloadLastSignature = gatewayCanvasFilesystemSignature(root)
        liveReloadEventCount = 0
        liveReloadLastEventAtMs = 0
        spawn {
            while (true) {
                sleep(Duration.millisecond * liveReloadPollIntervalMs)
                let scanRoot = synchronized(lock) {
                    if (liveReloadGeneration != generation || liveReloadStopRequested || !liveReloadRunning) {
                        ""
                    } else {
                        liveReloadRootPath
                    }
                }
                if (scanRoot.trimAscii().isEmpty()) {
                    break
                }
                let scanPath = Path(scanRoot)
                let nextMtime = gatewayCanvasScanMaxMtimeMs(scanPath)
                let nextSignature = gatewayCanvasFilesystemSignature(scanPath)
                var shouldPublish = false
                synchronized(lock) {
                    if (liveReloadGeneration != generation || liveReloadStopRequested || !liveReloadRunning) {
                        shouldPublish = false
                    } else if (nextMtime > 0 && !nextSignature.isEmpty() && nextSignature != liveReloadLastSignature) {
                        liveReloadLastMtimeMs = nextMtime
                        liveReloadLastSignature = nextSignature
                        liveReloadEventCount += 1
                        liveReloadLastEventAtMs = gatewayCanvasNowMs()
                        shouldPublish = true
                    }
                }
                if (shouldPublish) {
                    let payload = JsonObject()
                    payload.put("type", JsonString("reload"))
                    payload.put("reason", JsonString("canvas-root-changed"))
                    payload.put("mtimeMs", nextMtime.toJsonValue())
                    payload.put("eventCount", synchronized(lock) { liveReloadEventCount }.toJsonValue())
                    gatewayCanvasPublishLiveReloadEvent(payload)
                }
            }
            synchronized(lock) {
                if (liveReloadGeneration == generation) {
                    liveReloadRunning = false
                    liveReloadRootPath = ""
                }
            }
        }
    }

    private static func stopLiveReloadPollerLocked(): Unit {
        liveReloadGeneration += 1
        liveReloadStopRequested = true
        liveReloadRunning = false
        liveReloadRootPath = ""
        liveReloadLastSignature = ""
    }

    public static func registerCapabilityRoutes(cfg: GatewayConfig, token: String): Unit {
        let normalizedToken = token.trimAscii()
        if (normalizedToken.isEmpty()) {
            return
        }
        synchronized(lock) {
            if (!started) {
                return
            }
            if (let Some(s) <- server) {
                let root = Path(rootPath)
                let registeredScopedRoutes = ArrayList<String>()
                for (routeValue in canonicalRoutes.getItems()) {
                    let routePath = try {
                        routeValue.asString().getValue()
                    } catch (_: Exception) {
                        ""
                    }
                    if (routePath.trimAscii().isEmpty()) {
                        continue
                    }
                    let scopedRoute = gatewayCanvasScopedRouteFor(normalizedToken, routePath)
                    if (registeredScopedRoutes.contains(scopedRoute)) {
                        continue
                    }
                    registeredScopedRoutes.add(scopedRoute)
                    let requestPath = gatewayCanvasRequestPathFromRoute(routePath)
                    s.distributor.register(scopedRoute, { ctx =>
                        gatewayCanvasReplyAsset(ctx, root, requestPath, normalizedToken)
                    })
                    if (gatewayCanvasCompatRoutesEnabled(cfg)) {
                        let compatScopedRoute = gatewayCanvasOpenClawCompatPath(scopedRoute)
                        if (!registeredScopedRoutes.contains(compatScopedRoute)) {
                            registeredScopedRoutes.add(compatScopedRoute)
                            s.distributor.register(compatScopedRoute, { ctx =>
                                gatewayCanvasReplyAsset(ctx, root, requestPath, normalizedToken)
                            })
                        }
                    }
                }
                for (routeValue in gatewayCanvasA2uiRegisteredRoutes().getItems()) {
                    let routePath = try {
                        routeValue.asString().getValue()
                    } catch (_: Exception) {
                        ""
                    }
                    if (routePath.trimAscii().isEmpty()) {
                        continue
                    }
                    let scopedRoute = gatewayCanvasA2uiScopedRouteFor(normalizedToken, routePath)
                    if (registeredScopedRoutes.contains(scopedRoute)) {
                        continue
                    }
                    registeredScopedRoutes.add(scopedRoute)
                    let requestPath = gatewayCanvasA2uiRequestPathFromRoute(routePath)
                    s.distributor.register(scopedRoute, { ctx =>
                        gatewayCanvasReplyA2uiAsset(ctx, requestPath, normalizedToken)
                    })
                    if (gatewayCanvasCompatRoutesEnabled(cfg)) {
                        let compatScopedRoute = gatewayCanvasOpenClawCompatPath(scopedRoute)
                        if (!registeredScopedRoutes.contains(compatScopedRoute)) {
                            registeredScopedRoutes.add(compatScopedRoute)
                            s.distributor.register(compatScopedRoute, { ctx =>
                                gatewayCanvasReplyA2uiAsset(ctx, requestPath, normalizedToken)
                            })
                        }
                    }
                }
                let actionRoute = gatewayCanvasA2uiRoutePrefix() + "/cap/${normalizedToken}/action"
                if (!registeredScopedRoutes.contains(actionRoute)) {
                    registeredScopedRoutes.add(actionRoute)
                    s.distributor.register(actionRoute, { ctx =>
                        gatewayCanvasReplyA2uiAction(ctx, normalizedToken)
                    })
                }
                if (gatewayCanvasCompatRoutesEnabled(cfg)) {
                    let compatActionRoute = gatewayCanvasOpenClawCompatPath(actionRoute)
                    if (!registeredScopedRoutes.contains(compatActionRoute)) {
                        registeredScopedRoutes.add(compatActionRoute)
                        s.distributor.register(compatActionRoute, { ctx =>
                            gatewayCanvasReplyA2uiAction(ctx, normalizedToken)
                        })
                    }
                }
            }
        }
    }

    public static func stopIfRunning(): Unit {
        synchronized(lock) {
            GatewayCanvasHostRuntime.stopLiveReloadPollerLocked()
            if (let Some(s) <- server) {
                try {
                    s.close()
                } catch (_: Exception) {
                    ()
                }
            }
            started = false
            server = None
            rootPath = ""
            canonicalRoutes = JsonArray([])
            registeredRoutes = JsonArray([])
            lastErrorKind = ""
        }
    }

    public static func snapshot(cfg: GatewayConfig): JsonObject {
        let root = gatewayCanvasResolveRootState(cfg)
        synchronized(lock) {
            if (!started) {
                if (!lastErrorKind.trimAscii().isEmpty()) {
                    root.put("errorKind", JsonString(lastErrorKind))
                }
                root.put("routes", registeredRoutes)
                root.put("routeCount", registeredRoutes.size().toJsonValue())
                return root
            }
            let currentRoot = try {
                canonicalize(Path(cfg.canvas.root)).toString()
            } catch (_: Exception) {
                ""
            }
            let cfgPort = gatewayCanvasPortToUInt16(cfg.canvas.port, 18793u16)
            if (currentRoot == rootPath && cfgPort == listenPort) {
                root.put("hostStarted", true.toJsonValue())
                root.put("httpUrl", JsonString(gatewayCanvasBaseUrl(cfg)))
                root.put("healthy", true.toJsonValue())
                root.put("phase", JsonString("ready"))
                root.put("errorKind", JsonString(""))
                root.put("watchState", JsonString(if (cfg.canvas.liveReload && liveReloadRunning) { "watching" } else { "static" }))
                root.put("liveReloadEventCount", liveReloadEventCount.toJsonValue())
                root.put("liveReloadLastEventAtMs", liveReloadLastEventAtMs.toJsonValue())
                root.put("liveReloadPollIntervalMs", liveReloadPollIntervalMs.toJsonValue())
                root.put("routes", registeredRoutes)
                root.put("routeCount", registeredRoutes.size().toJsonValue())
                return root
            }
            root.put("hostStarted", false.toJsonValue())
            root.put("healthy", false.toJsonValue())
            root.put("httpUrl", JsonString(""))
            root.put("phase", JsonString("configured"))
            root.put("errorKind", JsonString("host-config-mismatch"))
            root.put("routes", JsonArray([]))
            root.put("routeCount", 0.toJsonValue())
            root
        }
    }

    public static func debugLiveReloadStateForTest(): JsonObject {
        synchronized(lock) {
            let out = JsonObject()
            out.put("running", liveReloadRunning.toJsonValue())
            out.put("stopRequested", liveReloadStopRequested.toJsonValue())
            out.put("rootPath", JsonString(liveReloadRootPath))
            out.put("lastMtimeMs", liveReloadLastMtimeMs.toJsonValue())
            out.put("lastSignatureEmpty", liveReloadLastSignature.isEmpty().toJsonValue())
            out.put("eventCount", liveReloadEventCount.toJsonValue())
            out.put("lastEventAtMs", liveReloadLastEventAtMs.toJsonValue())
            out.put("generation", liveReloadGeneration.toJsonValue())
            out.put("pollIntervalMs", liveReloadPollIntervalMs.toJsonValue())
            out
        }
    }
}

public func gatewayCanvasResolveRootState(cfg: GatewayConfig): JsonObject {
    let root = JsonObject()
    let enabled = cfg.canvas.enabled
    let rootText = cfg.canvas.root.trimAscii()
    root.put("enabled", enabled.toJsonValue())
    root.put("root", JsonString(cfg.canvas.root))
    root.put("port", cfg.canvas.port.toJsonValue())
    root.put("liveReload", cfg.canvas.liveReload.toJsonValue())
    root.put("openClawCompat", cfg.canvas.openClawCompat.toJsonValue())
    root.put("hostStarted", false.toJsonValue())
    root.put("httpUrl", JsonString(""))
    root.put("healthy", false.toJsonValue())

    if (!enabled) {
        root.put("rootPresent", false.toJsonValue())
        root.put("rootReadable", false.toJsonValue())
        root.put("assetState", JsonString("disabled"))
        root.put("watchState", JsonString("disabled"))
        root.put("phase", JsonString("disabled"))
        root.put("errorKind", JsonString(""))
        return root
    }
    if (rootText.isEmpty()) {
        root.put("rootPresent", false.toJsonValue())
        root.put("rootReadable", false.toJsonValue())
        root.put("assetState", JsonString("missing-root"))
        root.put("watchState", JsonString("disabled"))
        root.put("phase", JsonString("misconfigured"))
        root.put("errorKind", JsonString("root-empty"))
        return root
    }

    let rootPath = Path(rootText)
    if (!exists(rootPath)) {
        root.put("rootPresent", false.toJsonValue())
        root.put("rootReadable", false.toJsonValue())
        root.put("assetState", JsonString("missing-root"))
        root.put("watchState", JsonString("disabled"))
        root.put("phase", JsonString("misconfigured"))
        root.put("errorKind", JsonString("missing-root"))
        return root
    }
    let readable = try {
        FileInfo(rootPath).isDirectory()
    } catch (_: Exception) {
        false
    }
    root.put("rootPresent", true.toJsonValue())
    root.put("rootReadable", readable.toJsonValue())
    root.put("assetState", JsonString(if (readable) { "mounted" } else { "unreadable-root" }))
    root.put("watchState", JsonString(if (readable && cfg.canvas.liveReload) { "static" } else { "disabled" }))
    root.put("phase", JsonString(if (readable) { "configured" } else { "misconfigured" }))
    root.put("errorKind", JsonString(if (readable) { "host-not-started" } else { "unreadable-root" }))
    root
}
