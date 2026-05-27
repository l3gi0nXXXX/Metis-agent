package metis.gateway.tools

import metis.core.{gatewayCurrentToolRuntimeContext, gatewayInvokeCurrentToolRuntimeGatewayCall}

import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

public func gatewayToolInvokeChannelsSend(
    toolName: String,
    payload: JsonObject,
    callRunnerForTest!: Option<(String, JsonObject) -> JsonObject> = None<(String, JsonObject) -> JsonObject>,
    cliFallback!: Option<() -> JsonObject> = None<() -> JsonObject>
): JsonObject {
    match (callRunnerForTest) {
        case Some(runner) => return runner("channels.send", payload)
        case None => ()
    }

    match (gatewayCurrentToolRuntimeContext()) {
        case Some(_) =>
            match (gatewayInvokeCurrentToolRuntimeGatewayCall("channels.send", payload)) {
                case Some(result) => return result
                case None => return gatewayToolChannelsSendHookMissing(toolName)
            }
        case None =>
            match (cliFallback) {
                case Some(fallback) => return fallback()
                case None => return gatewayToolChannelsSendUnavailable(toolName)
            }
    }
}

private func gatewayToolChannelsSendHookMissing(toolName: String): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString("error"))
    out.put("code", JsonString("send_hook_missing"))
    out.put("method", JsonString("channels.send"))
    out.put("toolName", JsonString(toolName))
    out.put("selfCallPrevented", JsonBool(true))
    out.put("error", JsonString("Gateway runtime channels.send hook is unavailable; skipped internal CLI/RPC self-call."))
    out
}

private func gatewayToolChannelsSendUnavailable(toolName: String): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString("gateway_call_unavailable"))
    out.put("method", JsonString("channels.send"))
    out.put("toolName", JsonString(toolName))
    out.put("error", JsonString("Gateway runtime call hook is unavailable and no CLI fallback is configured."))
    out
}
