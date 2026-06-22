package metis.gateway.runtime

import metis.gateway.model.GatewayConfig

private const GATEWAY_CANVAS_OPENCLAW_CANVAS_PREFIX: String = "/__openclaw__/canvas"
private const GATEWAY_CANVAS_OPENCLAW_A2UI_PREFIX: String = "/__openclaw__/a2ui"

public func gatewayCanvasCompatRoutesEnabled(cfg: GatewayConfig): Bool {
    cfg.canvas.openClawCompat
}

public func gatewayCanvasOpenClawCompatPath(routePath: String): String {
    let trimmed = routePath.trimAscii()
    let normalized = gatewayCanvasNormalizeUrlPath(routePath)
    let keepTrailingSlash = trimmed.endsWith("/") && normalized != "/"
    let canvasPrefix = "/__metis__/canvas"
    let a2uiPrefix = gatewayCanvasA2uiRoutePrefix()
    if (normalized == canvasPrefix || normalized.startsWith(canvasPrefix + "/")) {
        return gatewayCanvasCompatWithTrailingSlash(
            GATEWAY_CANVAS_OPENCLAW_CANVAS_PREFIX + gatewayCanvasRouteSuffix(normalized, canvasPrefix),
            keepTrailingSlash
        )
    }
    if (normalized == a2uiPrefix || normalized.startsWith(a2uiPrefix + "/")) {
        return gatewayCanvasCompatWithTrailingSlash(
            GATEWAY_CANVAS_OPENCLAW_A2UI_PREFIX + gatewayCanvasRouteSuffix(normalized, a2uiPrefix),
            keepTrailingSlash
        )
    }
    normalized
}

private func gatewayCanvasCompatWithTrailingSlash(path: String, keepTrailingSlash: Bool): String {
    if (keepTrailingSlash && !path.endsWith("/")) {
        return path + "/"
    }
    path
}

private func gatewayCanvasRouteSuffix(value: String, prefix: String): String {
    let valueRunes = value.toRuneArray()
    let prefixSize = prefix.toRuneArray().size
    if (valueRunes.size <= prefixSize) {
        return ""
    }
    String(valueRunes[prefixSize..])
}
