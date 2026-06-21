package metis.gateway.runtime

import magic.jsonable.*

import metis.gateway.model.GatewayConfig

import std.collection.HashMap
import std.convert.Parsable
import std.random.Random
import std.sync.Mutex
import std.time.DateTime
import stdx.encoding.json.{JsonObject, JsonString}

public class GatewayCanvasNodeSessionState {
    public let nodeId: String
    public let role: String
    public let capabilities: Array<String>
    public let expiresAtMs: Int64
    public let canvasHostUrl: String

    public init(
        nodeId: String,
        role!: String = "node",
        capabilities!: Array<String> = [],
        expiresAtMs!: Int64 = 0,
        canvasHostUrl!: String = ""
    ) {
        this.nodeId = nodeId
        this.role = role
        this.capabilities = capabilities
        this.expiresAtMs = expiresAtMs
        this.canvasHostUrl = canvasHostUrl
    }
}

public class GatewayCanvasCapabilityAuthResult {
    public let ok: Bool
    public let nodeId: String
    public let errorCode: String

    public init(ok: Bool, nodeId!: String = "", errorCode!: String = "") {
        this.ok = ok
        this.nodeId = nodeId
        this.errorCode = errorCode
    }
}

public class GatewayCanvasScopedPath {
    public let ok: Bool
    public let token: String
    public let canvasPath: String
    public let errorCode: String

    public init(ok: Bool, token!: String = "", canvasPath!: String = "", errorCode!: String = "") {
        this.ok = ok
        this.token = token
        this.canvasPath = canvasPath
        this.errorCode = errorCode
    }
}

private let gatewayCanvasNodeSessionLock = Mutex()
private var gatewayCanvasNodeSessions = HashMap<String, GatewayCanvasNodeSessionState>()
private var gatewayCanvasCapabilityNodeByToken = HashMap<String, String>()
private var gatewayCanvasCapabilityRoleByToken = HashMap<String, String>()
private var gatewayCanvasCapabilityExpiresAtByToken = HashMap<String, Int64>()

public func gatewayCanvasCapabilityNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toNanoseconds() / 1000000
}

private func gatewayCanvasTokenRandomHex(count: Int64): String {
    let rand = Random()
    let chars = "0123456789abcdef".toRuneArray()
    let out = StringBuilder()
    for (_ in 0..count) {
        let raw = rand.nextInt64()
        let idx = Int64((raw % chars.size + chars.size) % chars.size)
        out.append(chars[idx])
    }
    out.toString()
}

public func gatewayCanvasMintCapabilityToken(): String {
    "metis_canvas_cap_${gatewayCanvasCapabilityNowMs()}_${gatewayCanvasTokenRandomHex(24)}"
}

public func debugGatewayCanvasMintCapabilityTokenForTest(): String {
    gatewayCanvasMintCapabilityToken()
}

private func gatewayCanvasSessionActive(state: GatewayCanvasNodeSessionState, now: Int64): Bool {
    !state.nodeId.trimAscii().isEmpty() && state.expiresAtMs > now
}

private func gatewayCanvasSessionCanUseCanvas(state: GatewayCanvasNodeSessionState): Bool {
    state.role.trimAscii().toAsciiLower() == "node" && state.capabilities.contains("canvas")
}

private func gatewayCanvasStringParam(request: GatewayRpcRequest, key: String, fallback: String): String {
    match (request.params.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayCanvasIntParam(request: GatewayRpcRequest, key: String, fallback: Int64): Int64 {
    match (request.params.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayCanvasPutCapability(token: String, nodeId: String, role: String, expiresAtMs: Int64): Unit {
    gatewayCanvasCapabilityNodeByToken[token] = nodeId
    gatewayCanvasCapabilityRoleByToken[token] = role
    gatewayCanvasCapabilityExpiresAtByToken[token] = expiresAtMs
}

public func debugGatewayCanvasRegisterNodeSessionForTest(
    nodeId: String,
    role!: String = "node",
    capabilities!: Array<String> = ["canvas"],
    ttlMs!: Int64 = 600000
): Unit {
    let normalized = nodeId.trimAscii()
    if (normalized.isEmpty()) {
        return
    }
    synchronized(gatewayCanvasNodeSessionLock) {
        gatewayCanvasNodeSessions[normalized] = GatewayCanvasNodeSessionState(
            normalized,
            role: role,
            capabilities: capabilities,
            expiresAtMs: gatewayCanvasCapabilityNowMs() + ttlMs,
            canvasHostUrl: ""
        )
    }
}

public func debugGatewayCanvasPutCapabilityForTest(token: String, nodeId: String, role: String, expiresAtMs: Int64): Unit {
    synchronized(gatewayCanvasNodeSessionLock) {
        gatewayCanvasPutCapability(token.trimAscii(), nodeId.trimAscii(), role.trimAscii(), expiresAtMs)
    }
}

public func debugGatewayCanvasClearNodeSessionsForTest(): Unit {
    synchronized(gatewayCanvasNodeSessionLock) {
        gatewayCanvasNodeSessions.clear()
        gatewayCanvasCapabilityNodeByToken.clear()
        gatewayCanvasCapabilityRoleByToken.clear()
        gatewayCanvasCapabilityExpiresAtByToken.clear()
    }
}

public func gatewayCanvasAuthorizeCapabilityToken(token: String): GatewayCanvasCapabilityAuthResult {
    let normalized = token.trimAscii()
    if (normalized.isEmpty()) {
        return GatewayCanvasCapabilityAuthResult(false, errorCode: "missing_capability")
    }
    let now = gatewayCanvasCapabilityNowMs()
    synchronized(gatewayCanvasNodeSessionLock) {
        let nodeId = gatewayCanvasCapabilityNodeByToken.get(normalized) ?? ""
        if (nodeId.isEmpty()) {
            return GatewayCanvasCapabilityAuthResult(false, errorCode: "unknown_capability")
        }
        let role = gatewayCanvasCapabilityRoleByToken.get(normalized) ?? ""
        if (role.toAsciiLower() != "node") {
            return GatewayCanvasCapabilityAuthResult(false, nodeId: nodeId, errorCode: "invalid_capability_role")
        }
        let expiresAt = gatewayCanvasCapabilityExpiresAtByToken.get(normalized) ?? 0
        if (expiresAt <= now) {
            return GatewayCanvasCapabilityAuthResult(false, nodeId: nodeId, errorCode: "expired_capability")
        }
        GatewayCanvasCapabilityAuthResult(true, nodeId: nodeId)
    }
}

public func gatewayCanvasScopedRouteFor(token: String, routePath: String): String {
    let normalizedToken = token.trimAscii()
    if (routePath == "/__metis__/canvas" || routePath == "/__metis__/canvas/") {
        return "/__metis__/canvas/cap/${normalizedToken}/"
    }
    let prefix = "/__metis__/canvas/"
    if (!routePath.startsWith(prefix)) {
        return "/__metis__/canvas/cap/${normalizedToken}/"
    }
    let runes = routePath.toRuneArray()
    let prefixSize = prefix.toRuneArray().size
    if (runes.size <= prefixSize) {
        return "/__metis__/canvas/cap/${normalizedToken}/"
    }
    "/__metis__/canvas/cap/${normalizedToken}/" + String(runes[prefixSize..])
}

public func gatewayCanvasNormalizeScopedUrlPath(rawPath: String): GatewayCanvasScopedPath {
    let normalized = gatewayCanvasNormalizeUrlPath(rawPath)
    let parts = normalized.split("/")
    if (parts.size < 5) {
        return GatewayCanvasScopedPath(false, errorCode: "malformed_scoped_path")
    }
    if (parts[1] != "__metis__" || parts[2] != "canvas" || parts[3] != "cap") {
        return GatewayCanvasScopedPath(false, errorCode: "malformed_scoped_path")
    }
    let token = parts[4].trimAscii()
    if (token.isEmpty()) {
        return GatewayCanvasScopedPath(false, errorCode: "missing_capability")
    }
    let out = StringBuilder("/")
    var first = true
    for (i in 5..parts.size) {
        let part = parts[i].trimAscii()
        if (part.isEmpty()) {
            continue
        }
        if (!first) {
            out.append(r'/')
        }
        out.append(part)
        first = false
    }
    GatewayCanvasScopedPath(true, token: token, canvasPath: if (first) { "/" } else { out.toString() })
}

public func gatewayCanvasRefreshNodeCapability(cfg: GatewayConfig, request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "node.canvas.capability.refresh"
    let requestedNodeId = gatewayCanvasStringParam(request, "nodeId", request.clientId).trimAscii()
    if (requestedNodeId.isEmpty()) {
        return GatewayRpcResponse(false, method, error: "nodeId is required", errorCode: "invalid_request")
    }
    let snapshot = GatewayCanvasHostRuntime.snapshot(cfg)
    let hostStarted = match (snapshot.get("hostStarted")) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
    if (!hostStarted) {
        return GatewayRpcResponse(false, method, error: "Canvas host is unavailable", errorCode: "unavailable")
    }
    let now = gatewayCanvasCapabilityNowMs()
    let ttlMs = max(1000, gatewayCanvasIntParam(request, "ttlMs", 600000))
    var token = ""
    var expiresAtMs = now + ttlMs
    synchronized(gatewayCanvasNodeSessionLock) {
        let session = gatewayCanvasNodeSessions.get(requestedNodeId) ?? GatewayCanvasNodeSessionState("")
        if (!gatewayCanvasSessionActive(session, now) || !gatewayCanvasSessionCanUseCanvas(session)) {
            return GatewayRpcResponse(false, method, error: "No active canvas-capable node session", errorCode: "unavailable")
        }
        expiresAtMs = min(session.expiresAtMs, now + ttlMs)
        token = gatewayCanvasMintCapabilityToken()
        gatewayCanvasPutCapability(token, requestedNodeId, "node", expiresAtMs)
    }
    GatewayCanvasHostRuntime.registerCapabilityRoutes(cfg, token)
    let result = JsonObject()
    result.put("nodeId", JsonString(requestedNodeId))
    result.put("capability", JsonString("canvas"))
    result.put("scopedUrl", JsonString(gatewayCanvasScopedRouteUrl(cfg, token)))
    result.put("expiresAtMs", expiresAtMs.toJsonValue())
    result.put("ttlMs", max(0, expiresAtMs - now).toJsonValue())
    GatewayRpcResponse(true, method, result: result)
}
