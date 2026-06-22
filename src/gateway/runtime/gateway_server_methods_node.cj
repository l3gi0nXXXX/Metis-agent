package metis.gateway.runtime

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings

import stdx.encoding.json.JsonObject

public func handleGatewayNodeFamily(
    method: String,
    user: GatewayUserSettings,
    request!: Option<GatewayRpcRequest> = None<GatewayRpcRequest>
): Option<GatewayRpcResponse> {
    let req = match (request) {
        case Some(v) => v
        case None => GatewayRpcRequest(method)
    }
    if (method == "node.connect") {
        return Some(gatewayCanvasRegisterConnectedNode(req))
    }
    if (method == "node.heartbeat") {
        return Some(gatewayCanvasHeartbeatConnectedNode(req))
    }
    if (method == "node.disconnect") {
        return Some(gatewayCanvasDisconnectConnectedNode(req))
    }
    if (method == "node.list") {
        let result = JsonObject()
        result.put("nodes", gatewayCanvasNodeSessionsSnapshot())
        return Some(GatewayRpcResponse(true, method, result: result))
    }
    if (method == "node.describe") {
        let result = JsonObject()
        let nodeId = match (req.params.get("nodeId")) {
            case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { req.clientId }
            case None => req.clientId
        }
        result.put("nodes", gatewayCanvasNodeSessionsSnapshot(nodeId: nodeId))
        return Some(GatewayRpcResponse(true, method, result: result))
    }
    if (method == "node.invoke") {
        return Some(gatewayNodeInvoke(req))
    }
    if (method == "node.invoke.result") {
        return Some(gatewayNodeInvokeResult(req))
    }
    if (method == "canvas.a2ui.action") {
        return Some(gatewayCanvasHandleA2uiUserAction(req))
    }
    if (method == "node.canvas.capability.refresh") {
        return Some(gatewayCanvasRefreshNodeCapability(buildGatewayConfigFromUserSettings(user), req))
    }
    None<GatewayRpcResponse>
}
