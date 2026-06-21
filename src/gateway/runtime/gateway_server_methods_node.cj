package metis.gateway.runtime

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings

public func handleGatewayNodeFamily(
    method: String,
    user: GatewayUserSettings,
    request!: Option<GatewayRpcRequest> = None<GatewayRpcRequest>
): Option<GatewayRpcResponse> {
    if (method == "node.canvas.capability.refresh") {
        let req = match (request) {
            case Some(v) => v
            case None => GatewayRpcRequest(method)
        }
        return Some(gatewayCanvasRefreshNodeCapability(buildGatewayConfigFromUserSettings(user), req))
    }
    None<GatewayRpcResponse>
}
