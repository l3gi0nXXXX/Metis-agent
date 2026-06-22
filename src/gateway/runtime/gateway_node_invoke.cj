package metis.gateway.runtime

import magic.jsonable.*

import std.collection.HashMap
import std.convert.Parsable
import std.sync.Mutex
import std.time.*
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}

private let gatewayNodeInvokeLock = Mutex()
private var gatewayNodeInvokeCounter: Int64 = 0
private var gatewayNodePendingById = HashMap<String, GatewayNodePendingInvoke>()
private var gatewayNodeInvokeIdByIdempotency = HashMap<String, String>()
private var gatewayNodeCompletedResultById = HashMap<String, JsonObject>()
private var gatewayNodeDebugAutoResultByKey = HashMap<String, JsonObject>()
private var gatewayNodeDebugRequestCountByKey = HashMap<String, Int64>()
private var gatewayNodeDebugLastRequestByKey = HashMap<String, JsonObject>()

private class GatewayNodePendingInvoke {
    let invokeId: String
    let nodeId: String
    let command: String
    let payload: JsonObject
    let idempotencyKey: String
    let createdAtMs: Int64

    init(
        invokeId: String,
        nodeId: String,
        command: String,
        payload: JsonObject,
        idempotencyKey: String,
        createdAtMs: Int64
    ) {
        this.invokeId = invokeId
        this.nodeId = nodeId
        this.command = command
        this.payload = payload
        this.idempotencyKey = idempotencyKey
        this.createdAtMs = createdAtMs
    }
}

private func gatewayNodeInvokeNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toNanoseconds() / 1000000
}

private func gatewayNodeInvokeStringParam(obj: JsonObject, key: String, fallback: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayNodeInvokeBoolParam(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayNodeInvokeIntParam(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func gatewayNodeInvokeObjectParam(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayNodeInvokeAllowedCommand(command: String): Bool {
    let normalized = command.trimAscii()
    normalized == "canvas.present" ||
        normalized == "canvas.hide" ||
        normalized == "canvas.navigate" ||
        normalized == "canvas.eval" ||
        normalized == "canvas.snapshot" ||
        normalized == "canvas.a2ui.pushJSONL" ||
        normalized == "canvas.a2ui.push" ||
        normalized == "canvas.a2ui.reset"
}

private func gatewayNodeInvokeKey(nodeId: String, command: String): String {
    nodeId.trimAscii() + "|" + command.trimAscii()
}

private func gatewayNodeInvokeIdempotencyMapKey(nodeId: String, command: String, idempotencyKey: String): String {
    nodeId.trimAscii() + "|" + command.trimAscii() + "|" + idempotencyKey.trimAscii()
}

private func gatewayNodeNextInvokeIdLocked(): String {
    gatewayNodeInvokeCounter += 1
    "metis-node-invoke-${gatewayNodeInvokeNowMs()}-${gatewayNodeInvokeCounter}"
}

private func gatewayNodePendingRequestJson(pending: GatewayNodePendingInvoke): JsonObject {
    let request = JsonObject()
    request.put("type", JsonString("node.invoke.request"))
    request.put("invokeId", JsonString(pending.invokeId))
    request.put("nodeId", JsonString(pending.nodeId))
    request.put("command", JsonString(pending.command))
    request.put("payload", pending.payload)
    request.put("idempotencyKey", JsonString(pending.idempotencyKey))
    request.put("createdAtMs", pending.createdAtMs.toJsonValue())
    request
}

private func gatewayNodeCompletedResponseJson(
    pending: GatewayNodePendingInvoke,
    ok: Bool,
    payload: JsonValue,
    error: String,
    errorCode: String,
    duplicate!: Bool = false
): JsonObject {
    let out = JsonObject()
    out.put("invokeId", JsonString(pending.invokeId))
    out.put("nodeId", JsonString(pending.nodeId))
    out.put("command", JsonString(pending.command))
    out.put("ok", ok.toJsonValue())
    out.put("status", JsonString("completed"))
    out.put("duplicate", duplicate.toJsonValue())
    out.put("payload", payload)
    out.put("error", JsonString(error))
    out.put("errorCode", JsonString(errorCode))
    out
}

private func gatewayNodeCachedResponseLocked(invokeId: String, duplicate: Bool): JsonObject {
    let cached = gatewayNodeCompletedResultById.get(invokeId) ?? JsonObject()
    let out = JsonObject()
    out.put("invokeId", cached.get("invokeId") ?? JsonString(invokeId))
    out.put("nodeId", cached.get("nodeId") ?? JsonString(""))
    out.put("command", cached.get("command") ?? JsonString(""))
    out.put("ok", cached.get("ok") ?? true.toJsonValue())
    out.put("status", cached.get("status") ?? JsonString("completed"))
    out.put("duplicate", duplicate.toJsonValue())
    out.put("payload", cached.get("payload") ?? JsonObject())
    out.put("error", cached.get("error") ?? JsonString(""))
    out.put("errorCode", cached.get("errorCode") ?? JsonString(""))
    out
}

private func gatewayNodePendingDuplicateResponseLocked(invokeId: String): JsonObject {
    let pending = gatewayNodePendingById.get(invokeId) ?? GatewayNodePendingInvoke("", "", "", JsonObject(), "", 0)
    let out = JsonObject()
    out.put("invokeId", JsonString(invokeId))
    out.put("nodeId", JsonString(pending.nodeId))
    out.put("command", JsonString(pending.command))
    out.put("ok", true.toJsonValue())
    out.put("status", JsonString("pending"))
    out.put("duplicate", true.toJsonValue())
    out.put("request", gatewayNodePendingRequestJson(pending))
    return out
}

private func gatewayNodeCompletePendingLocked(
    pending: GatewayNodePendingInvoke,
    ok: Bool,
    payload: JsonValue,
    error: String,
    errorCode: String
): JsonObject {
    gatewayNodePendingById.remove(pending.invokeId)
    let result = gatewayNodeCompletedResponseJson(pending, ok, payload, error, errorCode)
    gatewayNodeCompletedResultById[pending.invokeId] = result
    result
}

private func gatewayNodeCompletedOrPendingResult(invokeId: String): Option<JsonObject> {
    synchronized(gatewayNodeInvokeLock) {
        match (gatewayNodeCompletedResultById.get(invokeId)) {
            case Some(v) => return Some(v)
            case None => ()
        }
        None<JsonObject>
    }
}

public func debugGatewayNodeInvokeClearForTest(): Unit {
    synchronized(gatewayNodeInvokeLock) {
        gatewayNodeInvokeCounter = 0
        gatewayNodePendingById.clear()
        gatewayNodeInvokeIdByIdempotency.clear()
        gatewayNodeCompletedResultById.clear()
        gatewayNodeDebugAutoResultByKey.clear()
        gatewayNodeDebugRequestCountByKey.clear()
        gatewayNodeDebugLastRequestByKey.clear()
    }
}

public func debugGatewayNodeInvokeAutoResultForTest(nodeId: String, command: String, payload: JsonObject): Unit {
    synchronized(gatewayNodeInvokeLock) {
        gatewayNodeDebugAutoResultByKey[gatewayNodeInvokeKey(nodeId, command)] = payload
    }
}

public func debugGatewayNodeInvokeRequestCountForTest(nodeId: String, command: String): Int64 {
    synchronized(gatewayNodeInvokeLock) {
        gatewayNodeDebugRequestCountByKey.get(gatewayNodeInvokeKey(nodeId, command)) ?? 0
    }
}

public func debugGatewayNodeInvokeLastRequestForTest(nodeId: String, command: String): JsonObject {
    synchronized(gatewayNodeInvokeLock) {
        gatewayNodeDebugLastRequestByKey.get(gatewayNodeInvokeKey(nodeId, command)) ?? JsonObject()
    }
}

public func gatewayNodeInvoke(request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "node.invoke"
    let command = gatewayNodeInvokeStringParam(request.params, "command", "")
    if (command.isEmpty()) {
        return GatewayRpcResponse(false, method, error: "command is required", errorCode: "invalid_request")
    }
    if (!gatewayNodeInvokeAllowedCommand(command)) {
        return GatewayRpcResponse(false, method, error: "Unsupported node command", errorCode: "invalid_request")
    }
    var nodeId = gatewayNodeInvokeStringParam(request.params, "nodeId", "")
    if (nodeId.isEmpty()) {
        let selected = gatewayCanvasSelectNodeForCommand(command)
        if (selected.ok) {
            nodeId = selected.state.nodeId
        }
    }
    let lookup = gatewayCanvasLookupNodeForCommand(nodeId, command)
    if (!lookup.ok) {
        return GatewayRpcResponse(false, method, error: lookup.error, errorCode: lookup.errorCode)
    }
    let payload = gatewayNodeInvokeObjectParam(request.params, "payload")
    let idempotencyKey = gatewayNodeInvokeStringParam(request.params, "idempotencyKey", "")
    let idempotencyMapKey = gatewayNodeInvokeIdempotencyMapKey(nodeId, command, idempotencyKey)
    if (!idempotencyKey.isEmpty()) {
        synchronized(gatewayNodeInvokeLock) {
            let existingInvokeId = gatewayNodeInvokeIdByIdempotency.get(idempotencyMapKey) ?? ""
            if (!existingInvokeId.isEmpty()) {
                match (gatewayNodeCompletedResultById.get(existingInvokeId)) {
                    case Some(_) => return GatewayRpcResponse(true, method, result: gatewayNodeCachedResponseLocked(existingInvokeId, true))
                    case None => return GatewayRpcResponse(true, method, result: gatewayNodePendingDuplicateResponseLocked(existingInvokeId))
                }
            }
        }
    }
    let timeoutMs = max(1, min(gatewayNodeInvokeIntParam(request.params, "timeoutMs", 1000), 5000))
    let startedAt = gatewayNodeInvokeNowMs()
    let invokeId = synchronized(gatewayNodeInvokeLock) {
        let next = gatewayNodeNextInvokeIdLocked()
        let pending = GatewayNodePendingInvoke(next, nodeId, command, payload, idempotencyKey, startedAt)
        gatewayNodePendingById[next] = pending
        if (!idempotencyKey.isEmpty()) {
            gatewayNodeInvokeIdByIdempotency[idempotencyMapKey] = next
        }
        let key = gatewayNodeInvokeKey(nodeId, command)
        gatewayNodeDebugRequestCountByKey[key] = (gatewayNodeDebugRequestCountByKey.get(key) ?? 0) + 1
        gatewayNodeDebugLastRequestByKey[key] = gatewayNodePendingRequestJson(pending)
        match (gatewayNodeDebugAutoResultByKey.get(key)) {
            case Some(autoPayload) =>
                let _ = gatewayNodeCompletePendingLocked(pending, true, autoPayload, "", "")
            case None => ()
        }
        next
    }
    var elapsed: Int64 = 0
    while (elapsed <= timeoutMs) {
        match (gatewayNodeCompletedOrPendingResult(invokeId)) {
            case Some(result) => return GatewayRpcResponse(true, method, result: result)
            case None => ()
        }
        sleep(Duration.millisecond * 10)
        elapsed = gatewayNodeInvokeNowMs() - startedAt
    }
    synchronized(gatewayNodeInvokeLock) {
        gatewayNodePendingById.remove(invokeId)
    }
    let details = JsonObject()
    details.put("invokeId", JsonString(invokeId))
    details.put("nodeId", JsonString(nodeId))
    details.put("command", JsonString(command))
    GatewayRpcResponse(false, method, error: "Node invoke timed out", errorCode: "timeout", details: details)
}

public func gatewayNodeInvokeResult(request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "node.invoke.result"
    let callerMode = request.mode.trimAscii().toAsciiLower()
    if (callerMode != "node") {
        return GatewayRpcResponse(false, method, error: "node identity is required", errorCode: "forbidden")
    }
    let invokeId = gatewayNodeInvokeStringParam(request.params, "invokeId", gatewayNodeInvokeStringParam(request.params, "id", ""))
    let nodeId = gatewayNodeInvokeStringParam(request.params, "nodeId", request.clientId)
    if (invokeId.isEmpty()) {
        return GatewayRpcResponse(false, method, error: "invokeId is required", errorCode: "invalid_request")
    }
    let ok = gatewayNodeInvokeBoolParam(request.params, "ok", true)
    let payload = match (request.params.get("payload")) {
        case Some(v) => v
        case None => JsonObject()
    }
    let error = gatewayNodeInvokeStringParam(request.params, "error", "")
    let errorCode = gatewayNodeInvokeStringParam(request.params, "errorCode", "")
    synchronized(gatewayNodeInvokeLock) {
        let pending = gatewayNodePendingById.get(invokeId) ?? GatewayNodePendingInvoke("", "", "", JsonObject(), "", 0)
        if (pending.invokeId.isEmpty()) {
            let result = JsonObject()
            result.put("invokeId", JsonString(invokeId))
            result.put("nodeId", JsonString(nodeId))
            result.put("ignored", true.toJsonValue())
            return GatewayRpcResponse(true, method, result: result)
        }
        if (pending.nodeId != nodeId) {
            return GatewayRpcResponse(false, method, error: "invoke result nodeId mismatch", errorCode: "invalid_request")
        }
        let completed = gatewayNodeCompletePendingLocked(pending, ok, payload, error, errorCode)
        completed.put("completed", true.toJsonValue())
        return GatewayRpcResponse(true, method, result: completed)
    }
}
