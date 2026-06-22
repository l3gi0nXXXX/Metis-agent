package metis.gateway.runtime

import magic.jsonable.*

import std.collection.ArrayList
import std.fs.{FileInfo, Path, canonicalize, exists}
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private const GATEWAY_CANVAS_A2UI_ROUTE_PREFIX: String = "/__metis__/a2ui"

public func gatewayCanvasA2uiRoutePrefix(): String {
    GATEWAY_CANVAS_A2UI_ROUTE_PREFIX
}

public func gatewayCanvasA2uiAssetRoot(): Path {
    Path("assets").join("canvas-a2ui")
}

public func gatewayCanvasResolveA2uiRootState(rootOverride!: String = ""): JsonObject {
    let root = if (!rootOverride.trimAscii().isEmpty()) { Path(rootOverride.trimAscii()) } else { gatewayCanvasA2uiAssetRoot() }
    let out = JsonObject()
    out.put("enabled", true.toJsonValue())
    out.put("root", JsonString(root.toString()))
    out.put("rootPresent", false.toJsonValue())
    out.put("rootReadable", false.toJsonValue())
    out.put("phase", JsonString("missing-assets"))
    out.put("errorKind", JsonString("missing-a2ui-root"))
    if (!exists(root)) {
        return out
    }
    let readable = try {
        FileInfo(root).isDirectory()
    } catch (_: Exception) {
        false
    }
    out.put("rootPresent", true.toJsonValue())
    out.put("rootReadable", readable.toJsonValue())
    if (!readable) {
        out.put("phase", JsonString("unreadable-assets"))
        out.put("errorKind", JsonString("unreadable-a2ui-root"))
        return out
    }
    let indexPath = root.join("index.html")
    let bundlePath = root.join("a2ui.bundle.js")
    let indexReady = try { exists(indexPath) && FileInfo(indexPath).isRegular() } catch (_: Exception) { false }
    let bundleReady = try { exists(bundlePath) && FileInfo(bundlePath).isRegular() } catch (_: Exception) { false }
    out.put("indexPresent", indexReady.toJsonValue())
    out.put("bundlePresent", bundleReady.toJsonValue())
    if (!indexReady || !bundleReady) {
        out.put("phase", JsonString("missing-assets"))
        out.put("errorKind", JsonString("missing-a2ui-assets"))
        return out
    }
    let canonicalRoot = try {
        canonicalize(root).toString()
    } catch (_: Exception) {
        root.toString()
    }
    out.put("root", JsonString(canonicalRoot))
    out.put("phase", JsonString("ready"))
    out.put("errorKind", JsonString(""))
    out
}

public func gatewayCanvasA2uiRegisteredRoutes(): JsonArray {
    JsonArray([
        JsonString(GATEWAY_CANVAS_A2UI_ROUTE_PREFIX),
        JsonString(GATEWAY_CANVAS_A2UI_ROUTE_PREFIX + "/"),
        JsonString(GATEWAY_CANVAS_A2UI_ROUTE_PREFIX + "/index.html"),
        JsonString(GATEWAY_CANVAS_A2UI_ROUTE_PREFIX + "/a2ui.bundle.js")
    ])
}

private func gatewayCanvasA2uiBridgeScript(): String {
    "<script>\n" +
    "window.__METIS_A2UI_ACTION_ENDPOINT__ = window.__METIS_A2UI_ACTION_ENDPOINT__ || './action';\n" +
    "window.__METIS_A2UI_SESSION__ = window.__METIS_A2UI_SESSION__ || new URLSearchParams(window.location.search).get('session') || '';\n" +
    "window.__METIS_A2UI_LIVE_RELOAD__ = window.__METIS_A2UI_LIVE_RELOAD__ || false;\n" +
    "window.metisA2UI = window.metisA2UI || {};\n" +
    "window.Metis = window.Metis || {};\n" +
    "window.Metis.sendUserAction = window.Metis.sendUserAction || async function(action) {\n" +
    "  const endpoint = window.__METIS_A2UI_ACTION_ENDPOINT__;\n" +
    "  const session = window.__METIS_A2UI_SESSION__ || new URLSearchParams(window.location.search).get('session') || '';\n" +
    "  if (!endpoint) { return { ok: false, error: 'Metis A2UI action endpoint is not configured.' }; }\n" +
    "  const response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ session: session, action: action || {} }) });\n" +
    "  return response.json();\n" +
    "};\n" +
    "</script>\n"
}

public func gatewayCanvasInjectBridgeAndLiveReload(html: String): String {
    let bridge = gatewayCanvasA2uiBridgeScript()
    if (html.contains("</body>")) {
        return html.replace("</body>", bridge + "</body>")
    }
    html + "\n" + bridge
}

private func gatewayCanvasA2uiValidationOk(messageCount: Int64): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(true))
    out.put("version", JsonString("0.8"))
    out.put("messageCount", JsonInt(messageCount))
    out.put("errorKind", JsonString(""))
    out
}

private func gatewayCanvasA2uiValidationError(errorKind: String, lineNumber: Int64, message: String): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("version", JsonString("0.8"))
    out.put("messageCount", JsonInt(0))
    out.put("errorKind", JsonString(errorKind))
    out.put("error", JsonString(message))
    out.put("lineNumber", JsonInt(lineNumber))
    return out
}

private func gatewayCanvasA2uiHasKey(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(_) => true
        case None => false
    }
}

private func gatewayCanvasA2uiActionKeyCount(obj: JsonObject): Int64 {
    var count: Int64 = 0
    for (key in ["beginRendering", "surfaceUpdate", "dataModelUpdate", "deleteSurface"]) {
        if (gatewayCanvasA2uiHasKey(obj, key)) {
            count += 1
        }
    }
    count
}

public func gatewayCanvasValidateA2uiJsonlV08(jsonl: String): JsonObject {
    let lines = jsonl.split("\n")
    var messageCount: Int64 = 0
    var lineNumber: Int64 = 0
    for (line in lines) {
        lineNumber += 1
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            continue
        }
        let obj = try {
            JsonValue.fromStr(trimmed).asObject()
        } catch (_: Exception) {
            return gatewayCanvasA2uiValidationError("malformed_json", lineNumber, "A2UI JSONL line is not a JSON object.")
        }
        if (gatewayCanvasA2uiHasKey(obj, "createSurface")) {
            return gatewayCanvasA2uiValidationError("unsupported_version", lineNumber, "A2UI JSONL v0.9 createSurface is not supported; use v0.8 action rows.")
        }
        let actionCount = gatewayCanvasA2uiActionKeyCount(obj)
        if (actionCount == 0) {
            return gatewayCanvasA2uiValidationError("missing_action", lineNumber, "A2UI JSONL line must contain one v0.8 action key.")
        }
        if (actionCount > 1) {
            return gatewayCanvasA2uiValidationError("multiple_action_keys", lineNumber, "A2UI JSONL line must contain exactly one v0.8 action key.")
        }
        messageCount += 1
    }
    if (messageCount == 0) {
        return gatewayCanvasA2uiValidationError("empty_jsonl", 0, "A2UI JSONL content is empty.")
    }
    gatewayCanvasA2uiValidationOk(messageCount)
}
