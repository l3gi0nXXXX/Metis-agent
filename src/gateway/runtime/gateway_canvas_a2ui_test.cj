package metis.gateway.runtime

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.model.GatewayConfig

import std.collection.ArrayList
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists, remove}
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}
import stdx.net.http.*

private func withGatewayCanvasA2uiTestRoot<T>(block: (Path) -> T): T {
    let root = Path("/tmp/metis-canvas-a2ui-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try { remove(root, recursive: true) } catch (_: Exception) { () }
    Directory.create(root, recursive: true)
    try {
        return block(root)
    } finally {
        try { remove(root, recursive: true) } catch (_: Exception) { () }
    }
}

private func a2uiTestConfig(root: String, port: Int64): GatewayConfig {
    var user = GatewayUserSettings()
    user.canvas.enabled = true
    user.canvas.root = root
    user.canvas.port = port
    user.canvas.liveReload = true
    buildGatewayConfigFromUserSettings(user)
}

private func a2uiTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func a2uiTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func a2uiTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

private class GatewayCanvasA2uiHttpProbeResult {
    let status: Int64
    let contentType: String
    let body: String

    init(status: Int64, contentType: String, body: String) {
        this.status = status
        this.contentType = contentType
        this.body = body
    }
}

private func a2uiTestPort(): Int64 {
    25000 + (DateTime.now().toUnixTimeStamp().toNanoseconds() % 15000)
}

private func a2uiReadHttpBody(response: HttpResponse): String {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(1024, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
        if (out.size > 1024 * 128) {
            break
        }
    }
    try {
        String.fromUtf8(out.toArray())
    } catch (_: Exception) {
        ""
    }
}

private func a2uiFetch(url: String, method!: String = "GET"): GatewayCanvasA2uiHttpProbeResult {
    var attempts: Int64 = 0
    while (attempts < 8) {
        attempts += 1
        try {
            let builder = ClientBuilder()
            builder.readTimeout(Duration.millisecond * 500)
            let client = builder.build()
            try {
                let reqBuilder = HttpRequestBuilder().url(url)
                let normalized = method.trimAscii().toAsciiUpper()
                if (normalized == "GET") {
                    reqBuilder.get()
                } else {
                    reqBuilder.method(normalized)
                }
                let response = client.send(reqBuilder.build())
                let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
                return GatewayCanvasA2uiHttpProbeResult(Int64(response.status), contentType, a2uiReadHttpBody(response))
            } finally {
                client.close()
            }
        } catch (_: Exception) {
            sleep(Duration.millisecond * 50)
        }
    }
    GatewayCanvasA2uiHttpProbeResult(0, "", "")
}

private func a2uiPostJson(url: String, body: String): GatewayCanvasA2uiHttpProbeResult {
    var attempts: Int64 = 0
    while (attempts < 8) {
        attempts += 1
        try {
            let builder = ClientBuilder()
            builder.readTimeout(Duration.millisecond * 500)
            let client = builder.build()
            try {
                let response = client.send(
                    HttpRequestBuilder()
                        .url(url)
                        .post()
                        .header("content-type", "application/json")
                        .body(body)
                        .build()
                )
                let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
                return GatewayCanvasA2uiHttpProbeResult(Int64(response.status), contentType, a2uiReadHttpBody(response))
            } finally {
                client.close()
            }
        } catch (_: Exception) {
            sleep(Duration.millisecond * 50)
        }
    }
    GatewayCanvasA2uiHttpProbeResult(0, "", "")
}

private func a2uiScopedUrlForTest(cfg: GatewayConfig, nodeId: String): String {
    debugGatewayCanvasRegisterNodeSessionForTest(nodeId, role: "node", capabilities: ["canvas"], ttlMs: 600000)
    let params = JsonObject()
    params.put("nodeId", JsonString(nodeId))
    let response = gatewayCanvasRefreshNodeCapability(
        cfg,
        GatewayRpcRequest("node.canvas.capability.refresh", params: params, clientId: nodeId, mode: "node")
    )
    if (!response.ok) {
        return ""
    }
    let result = try { response.result.asObject() } catch (_: Exception) { JsonObject() }
    a2uiTestString(result, "a2uiUrl")
}

@Test
public class GatewayCanvasA2uiTest {
    @TestCase
    public func validatesA2uiJsonlV08Actions(): Unit {
        let jsonl = "{\"beginRendering\":{}}\n{\"surfaceUpdate\":{\"id\":\"surface-1\"}}\n{\"dataModelUpdate\":{\"id\":\"model-1\"}}\n{\"deleteSurface\":{\"id\":\"surface-1\"}}\n"
        let result = gatewayCanvasValidateA2uiJsonlV08(jsonl)
        @Expect(a2uiTestBool(result, "ok"), true)
        @Expect(a2uiTestString(result, "version"), "0.8")
        @Expect(a2uiTestInt(result, "messageCount"), 4)
    }

    @TestCase
    public func rejectsA2uiJsonlV09CreateSurface(): Unit {
        let result = gatewayCanvasValidateA2uiJsonlV08("{\"createSurface\":{\"id\":\"surface-1\"}}\n")
        @Expect(a2uiTestBool(result, "ok"), false)
        @Expect(a2uiTestString(result, "errorKind"), "unsupported_version")
        @Expect(a2uiTestString(result, "error").contains("v0.9"), true)
        @Expect(a2uiTestInt(result, "lineNumber"), 1)
    }

    @TestCase
    public func rejectsMalformedEmptyAndAmbiguousA2uiJsonl(): Unit {
        let empty = gatewayCanvasValidateA2uiJsonlV08("\n")
        @Expect(a2uiTestBool(empty, "ok"), false)
        @Expect(a2uiTestString(empty, "errorKind"), "empty_jsonl")

        let malformed = gatewayCanvasValidateA2uiJsonlV08("{not-json}\n")
        @Expect(a2uiTestBool(malformed, "ok"), false)
        @Expect(a2uiTestString(malformed, "errorKind"), "malformed_json")
        @Expect(a2uiTestInt(malformed, "lineNumber"), 1)

        let ambiguous = gatewayCanvasValidateA2uiJsonlV08("{\"beginRendering\":{},\"surfaceUpdate\":{}}\n")
        @Expect(a2uiTestBool(ambiguous, "ok"), false)
        @Expect(a2uiTestString(ambiguous, "errorKind"), "multiple_action_keys")
    }

    @TestCase
    public func scopedA2uiRouteServesMetisShellAndBridgeOnlyWithCapability(): Unit {
        withGatewayCanvasA2uiTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>canvas</html>".toArray())
            let port = a2uiTestPort()
            let cfg = a2uiTestConfig(root.toString(), port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let scopedUrl = a2uiScopedUrlForTest(cfg, "node-a2ui-shell")
                @Expect(scopedUrl.isEmpty(), false)
                let result = a2uiFetch(scopedUrl)
                @Expect(result.status, 200)
                @Expect(result.contentType, "text/html; charset=utf-8")
                @Expect(result.body.contains("metisA2UI"), true)
                @Expect(result.body.contains("Metis.sendUserAction"), true)
                @Expect(result.body.contains("OpenClaw"), false)
                @Expect(result.body.contains("lobster-gradient"), false)
                @Expect(result.body.contains("Left Claw"), false)
                @Expect(result.body.contains("Right Claw"), false)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func unscopedA2uiRouteRequiresCanvasCapability(): Unit {
        withGatewayCanvasA2uiTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>canvas</html>".toArray())
            let port = a2uiTestPort()
            let cfg = a2uiTestConfig(root.toString(), port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let result = a2uiFetch("http://127.0.0.1:${port}/__metis__/a2ui/")
                @Expect(result.status, 401)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func a2uiUserActionUsesCanvasCapabilityAndDashboardChatParams(): Unit {
        let captured = ArrayList<JsonObject>()
        debugSetGatewayCanvasA2uiActionRunnerForTest(Some({ params: JsonObject =>
            captured.add(params)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("runId", JsonString("fake-a2ui-run"))
            out
        }))
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            let token = "metis_canvas_cap_a2ui_action"
            debugGatewayCanvasPutCapabilityForTest(token, "node-a2ui-action", "node", gatewayCanvasCapabilityNowMs() + 600000)
            let action = JsonObject()
            action.put("type", JsonString("click"))
            action.put("label", JsonString("Run analysis"))
            let params = JsonObject()
            params.put("capabilityToken", JsonString(token))
            params.put("session", JsonString("canvas-session-1"))
            params.put("action", action)
            let response = handleGatewayNodeFamily(
                "canvas.a2ui.action",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("canvas.a2ui.action", params: params, clientId: "node-a2ui-action", mode: "node"))
            ).getOrThrow()
            @Expect(response.ok, true)
            let result = response.result.asObject()
            @Expect(a2uiTestBool(result, "accepted"), true)
            @Expect(a2uiTestString(result, "source"), "canvas-a2ui")
            @Expect(captured.size, 1)
            @Expect(a2uiTestString(captured[0], "source"), "canvas-a2ui")
            @Expect(a2uiTestString(captured[0], "session"), "canvas-session-1")
            @Expect(a2uiTestString(captured[0], "text").contains("Run analysis"), true)
        } finally {
            debugSetGatewayCanvasA2uiActionRunnerForTest(None<(JsonObject) -> JsonObject>)
            debugGatewayCanvasClearNodeSessionsForTest()
        }
    }

    @TestCase
    public func scopedA2uiActionRoutePostsToDashboardChatParams(): Unit {
        let captured = ArrayList<JsonObject>()
        debugSetGatewayCanvasA2uiActionRunnerForTest(Some({ params: JsonObject =>
            captured.add(params)
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("runId", JsonString("fake-a2ui-http-run"))
            out
        }))
        withGatewayCanvasA2uiTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>canvas</html>".toArray())
            let port = a2uiTestPort()
            let cfg = a2uiTestConfig(root.toString(), port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let scopedUrl = a2uiScopedUrlForTest(cfg, "node-a2ui-http-action")
                let result = a2uiPostJson(
                    scopedUrl + "action",
                    "{\"session\":\"canvas-http-session\",\"action\":{\"type\":\"submit\",\"label\":\"Create report\"}}"
                )
                @Expect(result.status, 200)
                @Expect(result.contentType, "application/json; charset=utf-8")
                @Expect(result.body.contains("canvas-a2ui"), true)
                @Expect(captured.size, 1)
                @Expect(a2uiTestString(captured[0], "source"), "canvas-a2ui")
                @Expect(a2uiTestString(captured[0], "session"), "canvas-http-session")
                @Expect(a2uiTestString(captured[0], "text").contains("Create report"), true)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
                debugSetGatewayCanvasA2uiActionRunnerForTest(None<(JsonObject) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func fakeNodeReceivesA2uiPushJsonlInvoke(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let connectParams = JsonObject()
            connectParams.put("nodeId", JsonString("node-a2ui-push"))
            connectParams.put("capabilities", JsonArray([JsonString("canvas")]))
            connectParams.put("commands", JsonArray([JsonString("canvas.a2ui.pushJSONL")]))
            let connected = handleGatewayNodeFamily(
                "node.connect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.connect", params: connectParams, clientId: "node-a2ui-push", mode: "node"))
            ).getOrThrow()
            @Expect(connected.ok, true)
            let autoPayload = JsonObject()
            autoPayload.put("accepted", JsonBool(true))
            debugGatewayNodeInvokeAutoResultForTest("node-a2ui-push", "canvas.a2ui.pushJSONL", autoPayload)
            let payload = JsonObject()
            payload.put("jsonl", JsonString("{\"beginRendering\":{}}\n"))
            let invokeParams = JsonObject()
            invokeParams.put("nodeId", JsonString("node-a2ui-push"))
            invokeParams.put("command", JsonString("canvas.a2ui.pushJSONL"))
            invokeParams.put("payload", payload)
            let response = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: invokeParams, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            @Expect(response.ok, true)
            let sent = debugGatewayNodeInvokeLastRequestForTest("node-a2ui-push", "canvas.a2ui.pushJSONL")
            @Expect(a2uiTestString(sent, "command"), "canvas.a2ui.pushJSONL")
            @Expect(a2uiTestString(sent.get("payload").getOrThrow().asObject(), "jsonl").contains("beginRendering"), true)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }
}
