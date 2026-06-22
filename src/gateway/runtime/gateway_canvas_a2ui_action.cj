package metis.gateway.runtime

import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private var gatewayCanvasA2uiActionRunnerForTest: Option<(JsonObject) -> JsonObject> = None<(JsonObject) -> JsonObject>

public func debugSetGatewayCanvasA2uiActionRunnerForTest(runner: Option<(JsonObject) -> JsonObject>): Unit {
    gatewayCanvasA2uiActionRunnerForTest = runner
}

private func gatewayCanvasA2uiParamString(params: JsonObject, keys: Array<String>, fallback: String): String {
    for (key in keys) {
        match (params.get(key)) {
            case Some(v) =>
                let value = try { v.asString().getValue() } catch (_: Exception) { "" }
                if (!value.trimAscii().isEmpty()) {
                    return value
                }
            case None => ()
        }
    }
    fallback
}

private func gatewayCanvasA2uiParamObject(params: JsonObject, key: String): JsonObject {
    match (params.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayCanvasA2uiFormatActionText(action: JsonObject): String {
    let actionType = gatewayCanvasA2uiParamString(action, ["type", "name", "event"], "")
    let label = gatewayCanvasA2uiParamString(action, ["label", "title", "text", "value"], "")
    let sb = StringBuilder()
    sb.append("Canvas A2UI user action")
    if (!actionType.trimAscii().isEmpty()) {
        sb.append(": ")
        sb.append(actionType.trimAscii())
    }
    if (!label.trimAscii().isEmpty()) {
        sb.append("\n")
        sb.append(label)
    } else {
        sb.append("\n")
        sb.append(action.toJsonString())
    }
    sb.toString()
}

private func gatewayCanvasA2uiRunChat(params: JsonObject): JsonObject {
    match (gatewayCanvasA2uiActionRunnerForTest) {
        case Some(runner) => runner(params)
        case None =>
            try {
                JsonValue.fromStr(gatewayDashboardChatSendJsonFromRpc(params)).asObject()
            } catch (_: Exception) {
                let out = JsonObject()
                out.put("error", JsonString("dashboard chat send failed"))
                out
            }
    }
}

public func gatewayCanvasHandleA2uiUserAction(request: GatewayRpcRequest): GatewayRpcResponse {
    let method = "canvas.a2ui.action"
    let token = gatewayCanvasA2uiParamString(request.params, ["capabilityToken", "token"], "")
    let auth = gatewayCanvasAuthorizeCapabilityToken(token)
    if (!auth.ok) {
        return GatewayRpcResponse(false, method, error: "canvas capability required", errorCode: auth.errorCode)
    }
    let session = gatewayCanvasA2uiParamString(request.params, ["session", "sessionKey"], "")
    if (session.trimAscii().isEmpty()) {
        return GatewayRpcResponse(false, method, error: "session is required", errorCode: "invalid_request")
    }
    let action = gatewayCanvasA2uiParamObject(request.params, "action")
    if (action.toJsonString() == "{}") {
        return GatewayRpcResponse(false, method, error: "action is required", errorCode: "invalid_request")
    }
    let chatParams = JsonObject()
    chatParams.put("source", JsonString("canvas-a2ui"))
    chatParams.put("session", JsonString(session.trimAscii()))
    chatParams.put("text", JsonString(gatewayCanvasA2uiFormatActionText(action)))
    chatParams.put("deliver", JsonBool(false))
    let chatResult = gatewayCanvasA2uiRunChat(chatParams)
    match (chatResult.get("error")) {
        case Some(v) =>
            let err = try { v.asString().getValue() } catch (_: Exception) { "dashboard chat send failed" }
            let details = JsonObject()
            details.put("source", JsonString("canvas-a2ui"))
            details.put("nodeId", JsonString(auth.nodeId))
            details.put("chat", chatResult)
            return GatewayRpcResponse(false, method, error: err, errorCode: "chat_failed", details: details)
        case None => ()
    }
    let result = JsonObject()
    result.put("accepted", JsonBool(true))
    result.put("source", JsonString("canvas-a2ui"))
    result.put("nodeId", JsonString(auth.nodeId))
    result.put("session", JsonString(session.trimAscii()))
    result.put("chat", chatResult)
    GatewayRpcResponse(true, method, result: result)
}
