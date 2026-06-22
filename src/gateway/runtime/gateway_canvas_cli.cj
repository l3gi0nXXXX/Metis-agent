package metis.gateway.runtime

import magic.jsonable.*

import metis.gateway.tools.{gatewayCanvasParseSnapshotPayload, gatewayCanvasWriteSnapshotArtifact}
import metis.io.PrintUtils

import std.convert.Parsable
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

private var gatewayNodesCanvasCliRunnerForTest: Option<(String, JsonObject) -> GatewayRpcResponse> = None<(String, JsonObject) -> GatewayRpcResponse>

public func debugSetGatewayNodesCanvasCliRunnerForTest(runner: Option<(String, JsonObject) -> GatewayRpcResponse>): Unit {
    gatewayNodesCanvasCliRunnerForTest = runner
}

private func gatewayNodesCanvasCommandForAction(action: String): String {
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

private func gatewayNodesCanvasPrintHelp(): Unit {
    PrintUtils.printLine("Metis gateway nodes canvas")
    PrintUtils.printLine("Usage:")
    PrintUtils.printLine("  gateway nodes canvas present --url <url> [--node <id>] [--json]")
    PrintUtils.printLine("  gateway nodes canvas hide [--node <id>] [--json]")
    PrintUtils.printLine("  gateway nodes canvas navigate --url <url> [--node <id>] [--json]")
    PrintUtils.printLine("  gateway nodes canvas eval --js <source> [--node <id>] [--json]")
    PrintUtils.printLine("  gateway nodes canvas snapshot [--format png|jpg|webp] [--node <id>] [--json]")
    PrintUtils.printLine("  gateway nodes canvas a2ui_push --jsonl <jsonl> [--node <id>] [--json]")
    PrintUtils.printLine("  gateway nodes canvas a2ui_reset [--node <id>] [--json]")
}

private func gatewayNodesCanvasOption(args: Array<String>, name: String): String {
    var i: Int64 = 0
    while (i < args.size) {
        if (args[i] == name && i + 1 < args.size) {
            return args[i + 1]
        }
        i += 1
    }
    ""
}

private func gatewayNodesCanvasHas(args: Array<String>, name: String): Bool {
    for (arg in args) {
        if (arg == name) {
            return true
        }
    }
    false
}

private func gatewayNodesCanvasCliError(errorCode: String, message: String): GatewayRpcResponse {
    GatewayRpcResponse(false, "node.invoke", error: message, errorCode: errorCode)
}

private func gatewayNodesCanvasBuildParams(action: String, args: Array<String>): GatewayRpcResponse {
    let command = gatewayNodesCanvasCommandForAction(action)
    if (command.isEmpty()) {
        return gatewayNodesCanvasCliError("invalid_action", "Unsupported canvas action `${action}`.")
    }
    let params = JsonObject()
    let payload = JsonObject()
    let node = gatewayNodesCanvasOption(args, "--node")
    if (!node.trimAscii().isEmpty()) {
        params.put("nodeId", JsonString(node.trimAscii()))
    }
    params.put("command", JsonString(command))
    let timeoutText = gatewayNodesCanvasOption(args, "--timeout-ms")
    if (!timeoutText.trimAscii().isEmpty()) {
        try {
            params.put("timeoutMs", JsonInt(Int64.parse(timeoutText.trimAscii())))
        } catch (_: Exception) {
            return gatewayNodesCanvasCliError("invalid_request", "--timeout-ms must be an integer.")
        }
    }
    if (command == "canvas.present" || command == "canvas.navigate") {
        let url = gatewayNodesCanvasOption(args, "--url")
        if (url.trimAscii().isEmpty()) {
            return gatewayNodesCanvasCliError("invalid_request", "--url is required for ${action}.")
        }
        payload.put("url", JsonString(url.trimAscii()))
    } else if (command == "canvas.eval") {
        let js = gatewayNodesCanvasOption(args, "--js")
        if (js.trimAscii().isEmpty()) {
            return gatewayNodesCanvasCliError("invalid_request", "--js is required for eval.")
        }
        payload.put("javaScript", JsonString(js))
    } else if (command == "canvas.snapshot") {
        let format = gatewayNodesCanvasOption(args, "--format")
        payload.put("format", JsonString(if (format.trimAscii().isEmpty()) { "png" } else { format.trimAscii() }))
    } else if (command == "canvas.a2ui.pushJSONL") {
        let jsonl = gatewayNodesCanvasOption(args, "--jsonl")
        let jsonlPath = gatewayNodesCanvasOption(args, "--jsonl-path")
        if (!jsonl.trimAscii().isEmpty()) {
            payload.put("jsonl", JsonString(jsonl))
        } else if (!jsonlPath.trimAscii().isEmpty()) {
            payload.put("jsonlPath", JsonString(jsonlPath.trimAscii()))
        } else {
            return gatewayNodesCanvasCliError("invalid_request", "--jsonl or --jsonl-path is required for a2ui_push.")
        }
    }
    params.put("payload", payload)
    GatewayRpcResponse(true, "node.invoke", result: params)
}

private func gatewayNodesCanvasResponsePayload(response: GatewayRpcResponse): JsonObject {
    let result = try {
        response.result.asObject()
    } catch (_: Exception) {
        JsonObject()
    }
    match (result.get("payload")) {
        case Some(v) => try { return v.asObject() } catch (_: Exception) { () }
        case None => ()
    }
    result
}

private func gatewayNodesCanvasAttachSnapshotArtifact(response: GatewayRpcResponse): GatewayRpcResponse {
    if (!response.ok) {
        return response
    }
    let artifact = gatewayCanvasWriteSnapshotArtifact(gatewayCanvasParseSnapshotPayload(gatewayNodesCanvasResponsePayload(response)))
    let artifactOk = match (artifact.get("ok")) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
    let result = JsonObject()
    result.put("invoke", response.result)
    result.put("artifact", artifact)
    GatewayRpcResponse(
        artifactOk,
        response.method,
        requestId: response.requestId,
        result: result,
        error: if (artifactOk) { "" } else { "Canvas snapshot artifact write failed." },
        errorCode: if (artifactOk) { "" } else { "artifact_failed" },
        details: response.details
    )
}

public func gatewayNodesCanvasInvokeForCliForTest(action: String, args: Array<String>): GatewayRpcResponse {
    let built = gatewayNodesCanvasBuildParams(action, args)
    if (!built.ok) {
        return built
    }
    let params = built.result.asObject()
    let response = match (gatewayNodesCanvasCliRunnerForTest) {
        case Some(runner) => runner("node.invoke", params)
        case None => GatewayClient().request("node.invoke", params: params)
    }
    if (gatewayNodesCanvasCommandForAction(action) == "canvas.snapshot") {
        return gatewayNodesCanvasAttachSnapshotArtifact(response)
    }
    response
}

public func runGatewayNodesCanvasCli(sub: Array<String>): Int64 {
    if (sub.size < 3 || sub[2] == "help" || sub[2] == "-h" || sub[2] == "--help") {
        gatewayNodesCanvasPrintHelp()
        return 0
    }
    let action = sub[2].trimAscii().toAsciiLower()
    let args = sub[3..]
    let json = gatewayNodesCanvasHas(args, "--json")
    let response = gatewayNodesCanvasInvokeForCliForTest(action, args)
    if (json) {
        PrintUtils.printLine(response.toJson().toJsonString())
    } else {
        gatewayPrintCommandOutput(response.toJson().toJsonString())
    }
    if (response.ok) { 0 } else { 1 }
}
