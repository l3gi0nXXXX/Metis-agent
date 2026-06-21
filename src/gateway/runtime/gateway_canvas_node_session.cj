package metis.gateway.runtime

import magic.jsonable.*

import metis.gateway.model.GatewayConfig

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.random.Random
import std.sync.Mutex
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

public class GatewayCanvasNodeSessionState {
    public let nodeId: String
    public let role: String
    public let capabilities: Array<String>
    public let commands: Array<String>
    public let connected: Bool
    public let connectedAtMs: Int64
    public let lastSeenAtMs: Int64
    public let expiresAtMs: Int64
    public let canvasHostUrl: String
    public let connectionId: String

    public init(
        nodeId: String,
        role!: String = "node",
        capabilities!: Array<String> = [],
        commands!: Array<String> = [],
        connected!: Bool = true,
        connectedAtMs!: Int64 = 0,
        lastSeenAtMs!: Int64 = 0,
        expiresAtMs!: Int64 = 0,
        canvasHostUrl!: String = "",
        connectionId!: String = ""
    ) {
        this.nodeId = nodeId
        this.role = role
        this.capabilities = capabilities
        this.commands = commands
        this.connected = connected
        this.connectedAtMs = connectedAtMs
        this.lastSeenAtMs = lastSeenAtMs
        this.expiresAtMs = expiresAtMs
        this.canvasHostUrl = canvasHostUrl
        this.connectionId = connectionId
    }
}

public class GatewayCanvasNodeLookupResult {
    public let ok: Bool
    public let state: GatewayCanvasNodeSessionState
    public let errorCode: String
    public let error: String

    public init(
        ok: Bool,
        state!: GatewayCanvasNodeSessionState = GatewayCanvasNodeSessionState(""),
        errorCode!: String = "",
        error!: String = ""
    ) {
        this.ok = ok
        this.state = state
        this.errorCode = errorCode
        this.error = error
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
    state.connected && !state.nodeId.trimAscii().isEmpty() && state.expiresAtMs > now
}

private func gatewayCanvasSessionCanUseCanvas(state: GatewayCanvasNodeSessionState): Bool {
    state.role.trimAscii().toAsciiLower() == "node" && state.capabilities.contains("canvas")
}

private func gatewayCanvasSessionSupportsCommand(state: GatewayCanvasNodeSessionState, command: String): Bool {
    state.commands.contains(command.trimAscii())
}

private func gatewayCanvasStringArrayParam(request: GatewayRpcRequest, key: String): Array<String> {
    match (request.params.get(key)) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                let out = ArrayList<String>()
                for (item in arr.getItems()) {
                    let text = item.asString().getValue().trimAscii()
                    if (!text.isEmpty() && !out.contains(text)) {
                        out.add(text)
                    }
                }
                out.toArray()
            } catch (_: Exception) {
                []
            }
        case None => []
    }
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
    commands!: Array<String> = [],
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
            commands: commands,
            connected: true,
            connectedAtMs: gatewayCanvasCapabilityNowMs(),
            lastSeenAtMs: gatewayCanvasCapabilityNowMs(),
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

private func gatewayCanvasNodeSessionToJsonLocked(state: GatewayCanvasNodeSessionState, now: Int64): JsonObject {
    let row = JsonObject()
    let connected = gatewayCanvasSessionActive(state, now)
    row.put("nodeId", JsonString(state.nodeId))
    row.put("role", JsonString(state.role))
    row.put("connected", connected.toJsonValue())
    row.put("canvasCapable", (connected && gatewayCanvasSessionCanUseCanvas(state)).toJsonValue())
    row.put("capabilities", state.capabilities.toJsonValue())
    row.put("commands", state.commands.toJsonValue())
    row.put("connectedAtMs", state.connectedAtMs.toJsonValue())
    row.put("lastSeenAtMs", state.lastSeenAtMs.toJsonValue())
    row.put("expiresAtMs", state.expiresAtMs.toJsonValue())
    row.put("canvasHostUrl", JsonString(state.canvasHostUrl))
    row.put("connectionId", JsonString(state.connectionId))
    row
}

public func gatewayCanvasRegisterConnectedNode(request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "node.connect"
    let nodeId = gatewayCanvasStringParam(request, "nodeId", request.clientId).trimAscii()
    if (nodeId.isEmpty()) {
        return GatewayRpcResponse(false, method, error: "nodeId is required", errorCode: "invalid_request")
    }
    let capabilities = gatewayCanvasStringArrayParam(request, "capabilities")
    let commands = gatewayCanvasStringArrayParam(request, "commands")
    let role = gatewayCanvasStringParam(request, "role", "node")
    let ttlMs = max(1000, gatewayCanvasIntParam(request, "ttlMs", 600000))
    let now = gatewayCanvasCapabilityNowMs()
    let state = GatewayCanvasNodeSessionState(
        nodeId,
        role: role,
        capabilities: capabilities,
        commands: commands,
        connected: true,
        connectedAtMs: now,
        lastSeenAtMs: now,
        expiresAtMs: now + ttlMs,
        canvasHostUrl: gatewayCanvasStringParam(request, "canvasHostUrl", ""),
        connectionId: gatewayCanvasStringParam(request, "connectionId", request.clientId)
    )
    let result = JsonObject()
    synchronized(gatewayCanvasNodeSessionLock) {
        gatewayCanvasNodeSessions[nodeId] = state
        result.put("node", gatewayCanvasNodeSessionToJsonLocked(state, now))
    }
    GatewayRpcResponse(true, method, result: result)
}

public func gatewayCanvasHeartbeatConnectedNode(request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "node.heartbeat"
    let nodeId = gatewayCanvasStringParam(request, "nodeId", request.clientId).trimAscii()
    if (nodeId.isEmpty()) {
        return GatewayRpcResponse(false, method, error: "nodeId is required", errorCode: "invalid_request")
    }
    let ttlMs = max(1000, gatewayCanvasIntParam(request, "ttlMs", 600000))
    let now = gatewayCanvasCapabilityNowMs()
    synchronized(gatewayCanvasNodeSessionLock) {
        let current = gatewayCanvasNodeSessions.get(nodeId) ?? GatewayCanvasNodeSessionState("")
        if (!gatewayCanvasSessionActive(current, now)) {
            return GatewayRpcResponse(false, method, error: "No active node session", errorCode: "unavailable")
        }
        let updated = GatewayCanvasNodeSessionState(
            current.nodeId,
            role: current.role,
            capabilities: current.capabilities,
            commands: current.commands,
            connected: true,
            connectedAtMs: current.connectedAtMs,
            lastSeenAtMs: now,
            expiresAtMs: now + ttlMs,
            canvasHostUrl: current.canvasHostUrl,
            connectionId: current.connectionId
        )
        gatewayCanvasNodeSessions[nodeId] = updated
        let result = JsonObject()
        result.put("node", gatewayCanvasNodeSessionToJsonLocked(updated, now))
        return GatewayRpcResponse(true, method, result: result)
    }
}

public func gatewayCanvasDisconnectConnectedNode(request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "node.disconnect"
    let nodeId = gatewayCanvasStringParam(request, "nodeId", request.clientId).trimAscii()
    if (nodeId.isEmpty()) {
        return GatewayRpcResponse(false, method, error: "nodeId is required", errorCode: "invalid_request")
    }
    synchronized(gatewayCanvasNodeSessionLock) {
        gatewayCanvasNodeSessions.remove(nodeId)
        let staleTokens = ArrayList<String>()
        for ((token, tokenNodeId) in gatewayCanvasCapabilityNodeByToken) {
            if (tokenNodeId == nodeId) {
                staleTokens.add(token)
            }
        }
        for (token in staleTokens) {
            gatewayCanvasCapabilityNodeByToken.remove(token)
            gatewayCanvasCapabilityRoleByToken.remove(token)
            gatewayCanvasCapabilityExpiresAtByToken.remove(token)
        }
    }
    let result = JsonObject()
    result.put("nodeId", JsonString(nodeId))
    result.put("disconnected", true.toJsonValue())
    GatewayRpcResponse(true, method, result: result)
}

public func gatewayCanvasNodeSessionsSnapshot(nodeId!: String = ""): JsonArray {
    let normalized = nodeId.trimAscii()
    let now = gatewayCanvasCapabilityNowMs()
    synchronized(gatewayCanvasNodeSessionLock) {
        let rows = JsonArray([])
        for ((id, state) in gatewayCanvasNodeSessions) {
            if (!normalized.isEmpty() && id != normalized) {
                continue
            }
            rows.add(gatewayCanvasNodeSessionToJsonLocked(state, now))
        }
        rows
    }
}

public func gatewayCanvasLookupNodeForCommand(nodeId: String, command: String): GatewayCanvasNodeLookupResult {
    let normalizedNodeId = nodeId.trimAscii()
    let normalizedCommand = command.trimAscii()
    if (normalizedNodeId.isEmpty()) {
        return GatewayCanvasNodeLookupResult(false, errorCode: "invalid_request", error: "nodeId is required")
    }
    if (normalizedCommand.isEmpty()) {
        return GatewayCanvasNodeLookupResult(false, errorCode: "invalid_request", error: "command is required")
    }
    let now = gatewayCanvasCapabilityNowMs()
    synchronized(gatewayCanvasNodeSessionLock) {
        let state = gatewayCanvasNodeSessions.get(normalizedNodeId) ?? GatewayCanvasNodeSessionState("")
        if (!gatewayCanvasSessionActive(state, now)) {
            return GatewayCanvasNodeLookupResult(false, errorCode: "unavailable", error: "Node is offline")
        }
        if (!gatewayCanvasSessionSupportsCommand(state, normalizedCommand)) {
            return GatewayCanvasNodeLookupResult(false, state: state, errorCode: "invalid_request", error: "Node command is not advertised")
        }
        GatewayCanvasNodeLookupResult(true, state: state)
    }
}

public func gatewayCanvasSelectNodeForCommand(command: String): GatewayCanvasNodeLookupResult {
    let normalizedCommand = command.trimAscii()
    if (normalizedCommand.isEmpty()) {
        return GatewayCanvasNodeLookupResult(false, errorCode: "invalid_request", error: "command is required")
    }
    let now = gatewayCanvasCapabilityNowMs()
    synchronized(gatewayCanvasNodeSessionLock) {
        for ((_id, state) in gatewayCanvasNodeSessions) {
            if (gatewayCanvasSessionActive(state, now) && gatewayCanvasSessionSupportsCommand(state, normalizedCommand)) {
                return GatewayCanvasNodeLookupResult(true, state: state)
            }
        }
        GatewayCanvasNodeLookupResult(false, errorCode: "unavailable", error: "No connected node advertises command")
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
