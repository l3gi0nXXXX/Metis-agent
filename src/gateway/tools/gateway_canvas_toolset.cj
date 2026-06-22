package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*
import magic.jsonable.*

import metis.core.{GatewayToolRuntimeContext, gatewayCurrentToolRuntimeContext, gatewayInvokeCurrentToolRuntimeGatewayCall}
import metis.core.config.CliConfig
import metis.io.PrintUtils

import std.fs.{Directory, File, Path, canonicalize, exists}
import std.time.DateTime
import stdx.encoding.base64.fromBase64String
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private var gatewayCanvasToolArtifactRootForTest: Option<Path> = None<Path>

public func debugSetGatewayCanvasToolArtifactRootForTest(root: Option<Path>): Unit {
    gatewayCanvasToolArtifactRootForTest = root
}

private func gatewayCanvasToolString(value: Option<String>): String {
    match (value) {
        case Some(v) => v.trimAscii()
        case None => ""
    }
}

private func gatewayCanvasToolInt(value: Option<Int64>, fallback: Int64): Int64 {
    match (value) {
        case Some(v) => v
        case None => fallback
    }
}

private func gatewayCanvasToolError(errorCode: String, message: String): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("errorCode", JsonString(errorCode))
    out.put("error", JsonString(message))
    out
}

private func gatewayCanvasToolActionCommand(action: String): String {
    match (action.trimAscii().toAsciiLower().replace("-", "_")) {
        case "present" => "canvas.present"
        case "hide" => "canvas.hide"
        case "navigate" => "canvas.navigate"
        case "eval" => "canvas.eval"
        case "snapshot" => "canvas.snapshot"
        case "a2ui_push" | "a2ui.push" | "a2ui_push_jsonl" | "a2ui.pushjsonl" => "canvas.a2ui.pushJSONL"
        case "a2ui_reset" | "a2ui.reset" => "canvas.a2ui.reset"
        case _ => ""
    }
}

private func gatewayCanvasToolSnapshotMime(format: String): (String, String) {
    match (format.trimAscii().toAsciiLower()) {
        case "png" => ("png", "image/png")
        case "jpg" | "jpeg" => ("jpg", "image/jpeg")
        case "webp" => ("webp", "image/webp")
        case _ => ("", "")
    }
}

private func gatewayCanvasToolFirstJsonObject(obj: JsonObject, keys: Array<String>): JsonObject {
    for (key in keys) {
        match (obj.get(key)) {
            case Some(v) =>
                try {
                    return v.asObject()
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
    }
    JsonObject()
}

private func gatewayCanvasToolFirstString(obj: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        match (obj.get(key)) {
            case Some(v) =>
                try {
                    let text = v.asString().getValue().trimAscii()
                    if (!text.isEmpty()) {
                        return text
                    }
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
    }
    ""
}

private func gatewayCanvasToolStripDataUrl(raw: String): String {
    let trimmed = raw.trimAscii()
    if (!trimmed.toAsciiLower().startsWith("data:")) {
        return trimmed
    }
    let parts = trimmed.split(";base64,")
    if (parts.size >= 2) {
        return parts[1].trimAscii()
    }
    trimmed
}

public func gatewayCanvasParseSnapshotPayload(payload: JsonObject, maxBase64Bytes!: Int64 = 8 * 1024 * 1024): JsonObject {
    let format = gatewayCanvasToolFirstString(payload, ["format", "type", "extension"])
    let normalized = gatewayCanvasToolSnapshotMime(if (format.isEmpty()) { "png" } else { format })
    if (normalized[0].isEmpty()) {
        return gatewayCanvasToolError("invalid_format", "Canvas snapshot format must be png, jpg, jpeg, or webp.")
    }
    let b64 = gatewayCanvasToolStripDataUrl(gatewayCanvasToolFirstString(payload, ["base64", "data", "imageBase64"]))
    if (b64.isEmpty()) {
        return gatewayCanvasToolError("missing_base64", "Canvas snapshot payload is missing base64 image data.")
    }
    if (maxBase64Bytes > 0 && b64.size > maxBase64Bytes) {
        let out = gatewayCanvasToolError("payload_too_large", "Canvas snapshot base64 payload exceeds the configured limit.")
        out.put("base64Bytes", JsonInt(b64.size))
        out.put("limitBytes", JsonInt(maxBase64Bytes))
        return out
    }
    match (fromBase64String(b64)) {
        case Some(bytes) =>
            if (bytes.size == 0) {
                return gatewayCanvasToolError("invalid_base64", "Canvas snapshot base64 payload decoded to empty bytes.")
            }
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("format", JsonString(normalized[0]))
            out.put("mimeType", JsonString(normalized[1]))
            out.put("bytes", JsonString(b64))
            out.put("byteCount", JsonInt(bytes.size))
            out
        case None => gatewayCanvasToolError("invalid_base64", "Canvas snapshot base64 payload is invalid.")
    }
}

private func gatewayCanvasArtifactRoot(): Path {
    match (gatewayCanvasToolArtifactRootForTest) {
        case Some(root) => root
        case None => CliConfig.dotDir.join("gateway-canvas").join("artifacts")
    }
}

public func gatewayCanvasWriteSnapshotArtifact(parsed: JsonObject): JsonObject {
    let ok = match (parsed.get("ok")) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
    if (!ok) {
        return parsed
    }
    let format = gatewayCanvasToolFirstString(parsed, ["format"])
    let b64 = gatewayCanvasToolFirstString(parsed, ["bytes"])
    match (fromBase64String(b64)) {
        case Some(bytes) =>
            let root = gatewayCanvasArtifactRoot()
            if (!exists(root)) {
                Directory.create(root, recursive: true)
            }
            let path = root.join("canvas-snapshot-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.${format}")
            File.writeTo(path, bytes)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("type", JsonString("image"))
            out.put("format", JsonString(format))
            out.put("mimeType", parsed.get("mimeType") ?? JsonString(""))
            out.put("path", JsonString(path.toString()))
            out.put("byteCount", JsonInt(bytes.size))
            out
        case None => gatewayCanvasToolError("invalid_base64", "Canvas snapshot base64 payload is invalid.")
    }
}

private func gatewayCanvasToolResponsePayload(response: JsonObject): JsonObject {
    let result = gatewayCanvasToolFirstJsonObject(response, ["result"])
    let resultPayload = gatewayCanvasToolFirstJsonObject(result, ["payload"])
    if (!resultPayload.toJsonString().isEmpty() && resultPayload.toJsonString() != "{}") {
        return resultPayload
    }
    let directPayload = gatewayCanvasToolFirstJsonObject(response, ["payload"])
    if (!directPayload.toJsonString().isEmpty() && directPayload.toJsonString() != "{}") {
        return directPayload
    }
    result
}

private func gatewayCanvasPathWithinAllowedRoots(path: String, context: GatewayToolRuntimeContext): Bool {
    let candidate = try { canonicalize(Path(path)).toString() } catch (_: Exception) { return false }
    for (rootText in [context.workspaceDir, context.agentDir]) {
        let root = rootText.trimAscii()
        if (root.isEmpty()) {
            continue
        }
        let canonicalRoot = try { canonicalize(Path(root)).toString() } catch (_: Exception) { continue }
        if (candidate == canonicalRoot || candidate.startsWith(canonicalRoot + "/")) {
            return true
        }
    }
    false
}

private func gatewayCanvasToolReadJsonlPath(path: String): (Bool, String, String) {
    let normalized = path.trimAscii()
    if (normalized.isEmpty()) {
        return (false, "", "jsonlPath is empty")
    }
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(context) =>
            if (!gatewayCanvasPathWithinAllowedRoots(normalized, context)) {
                return (false, "", "jsonlPath is outside allowed workspace roots")
            }
        case None => return (false, "", "jsonlPath requires a Gateway tool runtime context")
    }
    if (!exists(Path(normalized))) {
        return (false, "", "jsonlPath does not exist")
    }
    try {
        (true, String.fromUtf8(File.readFrom(Path(normalized))), "")
    } catch (_: Exception) {
        (false, "", "jsonlPath is not valid UTF-8")
    }
}

private func gatewayCanvasBuildInvokePayload(
    action: String,
    target: Option<String>,
    url: Option<String>,
    javaScript: Option<String>,
    outputFormat: Option<String>,
    maxWidth: Option<Int64>,
    quality: Option<Int64>,
    jsonl: Option<String>,
    jsonlPath: Option<String>
): JsonObject {
    let payload = JsonObject()
    let normalizedAction = action.trimAscii().toAsciiLower().replace("-", "_")
    let targetValue = gatewayCanvasToolString(target)
    let urlValue = gatewayCanvasToolString(url)
    if (normalizedAction == "present" || normalizedAction == "navigate") {
        payload.put("url", JsonString(if (!urlValue.isEmpty()) { urlValue } else { targetValue }))
    }
    if (normalizedAction == "eval") {
        payload.put("javaScript", JsonString(gatewayCanvasToolString(javaScript)))
    }
    if (normalizedAction == "snapshot") {
        payload.put("format", JsonString(if (gatewayCanvasToolString(outputFormat).isEmpty()) { "png" } else { gatewayCanvasToolString(outputFormat) }))
        payload.put("maxWidth", JsonInt(gatewayCanvasToolInt(maxWidth, 0)))
        payload.put("quality", JsonInt(gatewayCanvasToolInt(quality, 90)))
    }
    if (normalizedAction == "a2ui_push" || normalizedAction == "a2ui.push" || normalizedAction == "a2ui_push_jsonl" || normalizedAction == "a2ui.pushjsonl") {
        let direct = gatewayCanvasToolString(jsonl)
        if (!direct.isEmpty()) {
            payload.put("jsonl", JsonString(direct))
        } else {
            let read = gatewayCanvasToolReadJsonlPath(gatewayCanvasToolString(jsonlPath))
            if (read[0]) {
                payload.put("jsonl", JsonString(read[1]))
            } else {
                payload.put("jsonlError", JsonString(read[2]))
            }
        }
    }
    payload
}

public func gatewayCanvasToolInvokeNode(params: JsonObject): JsonObject {
    match (gatewayInvokeCurrentToolRuntimeGatewayCall("node.invoke", params)) {
        case Some(result) => result
        case None => gatewayCanvasToolError("gateway_call_unavailable", "No Gateway runtime hook is available for canvas tool invocation.")
    }
}

@toolset
public class GatewayCanvasToolset {
    public func debugCanvasForTest(
        action: String,
        node: Option<String>,
        target: Option<String>,
        url: Option<String>,
        javaScript: Option<String>,
        outputFormat: Option<String>,
        maxWidth: Option<Int64>,
        quality: Option<Int64>,
        jsonl: Option<String>,
        jsonlPath: Option<String>,
        timeoutMs: Option<Int64>
    ): String {
        this.__tool_impl_of_canvas(action, node, target, url, javaScript, outputFormat, maxWidth, quality, jsonl, jsonlPath, timeoutMs)
    }

    @tool[
        description: "Control the Metis Canvas through the Gateway connected-node RPC contract. Actions are present, hide, navigate, eval, snapshot, a2ui_push, and a2ui_reset.",
        parameters: {
            action: "Canvas action: present, hide, navigate, eval, snapshot, a2ui_push, or a2ui_reset.",
            node: "Optional connected node id. If omitted, Gateway selects a node that advertises the Canvas command.",
            target: "Optional target URL alias. For present/navigate, used when url is omitted.",
            url: "Canvas URL for present or navigate.",
            javaScript: "JavaScript source for eval.",
            outputFormat: "Snapshot output format: png, jpg, jpeg, or webp.",
            maxWidth: "Optional snapshot max width.",
            quality: "Optional snapshot quality integer.",
            jsonl: "A2UI JSONL content for a2ui_push.",
            jsonlPath: "A2UI JSONL file path. Only files under the current Gateway tool workspace or agent dir are readable.",
            timeoutMs: "Optional node.invoke timeout in milliseconds."
        }
    ]
    public func canvas(
        action: String,
        node: Option<String>,
        target: Option<String>,
        url: Option<String>,
        javaScript: Option<String>,
        outputFormat: Option<String>,
        maxWidth: Option<Int64>,
        quality: Option<Int64>,
        jsonl: Option<String>,
        jsonlPath: Option<String>,
        timeoutMs: Option<Int64>
    ): String {
        let command = gatewayCanvasToolActionCommand(action)
        PrintUtils.printTool("canvas", shortMessage: action.trimAscii())
        if (command.isEmpty()) {
            let out = gatewayCanvasToolError("invalid_action", "Unsupported canvas action `${action.trimAscii()}`.").toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }
        let payload = gatewayCanvasBuildInvokePayload(action, target, url, javaScript, outputFormat, maxWidth, quality, jsonl, jsonlPath)
        let jsonlError = gatewayCanvasToolFirstString(payload, ["jsonlError"])
        if (!jsonlError.isEmpty()) {
            let out = gatewayCanvasToolError("invalid_jsonl_path", jsonlError).toJsonString()
            PrintUtils.printToolResult(out)
            return out
        }
        let params = JsonObject()
        let nodeId = gatewayCanvasToolString(node)
        if (!nodeId.isEmpty()) {
            params.put("nodeId", JsonString(nodeId))
        }
        params.put("command", JsonString(command))
        params.put("payload", payload)
        match (timeoutMs) {
            case Some(v) => params.put("timeoutMs", JsonInt(v))
            case None => ()
        }
        let response = gatewayCanvasToolInvokeNode(params)
        if (command == "canvas.snapshot") {
            let responseOk = match (response.get("ok")) {
                case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
                case None => false
            }
            if (responseOk) {
                let artifact = gatewayCanvasWriteSnapshotArtifact(gatewayCanvasParseSnapshotPayload(gatewayCanvasToolResponsePayload(response)))
                let out = JsonObject()
                out.put("ok", artifact.get("ok") ?? JsonBool(false))
                out.put("method", JsonString("node.invoke"))
                out.put("command", JsonString(command))
                out.put("artifact", artifact)
                let raw = out.toJsonString()
                PrintUtils.printToolResult(raw)
                return raw
            }
        }
        let raw = response.toJsonString()
        PrintUtils.printToolResult(raw)
        raw
    }
}
