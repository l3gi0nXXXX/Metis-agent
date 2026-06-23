package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.model.GatewayConfig
import metis.gateway.tools.{debugSetGatewayCanvasToolArtifactRootForTest, gatewayCanvasParseSnapshotPayload, gatewayCanvasWriteSnapshotArtifact}

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}
import stdx.net.http.*

private class GatewayCanvasE2eHttpResult {
    let status: Int64
    let contentType: String
    let body: String

    init(status: Int64, contentType: String, body: String) {
        this.status = status
        this.contentType = contentType
        this.body = body
    }
}

private func withGatewayCanvasE2eRoot<T>(block: (Path) -> T): T {
    debugWithGatewayCanvasHostRuntimeForTest<T>({ =>
        let root = Path("/tmp/metis-canvas-e2e-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try { remove(root, recursive: true) } catch (_: Exception) { () }
        Directory.create(root, recursive: true)
        try {
            block(root)
        } finally {
            try { remove(root, recursive: true) } catch (_: Exception) { () }
            debugSetGatewayCanvasToolArtifactRootForTest(None<Path>)
        }
    })
}

private func canvasE2eConfig(root: Path, port: Int64): GatewayConfig {
    var user = GatewayUserSettings()
    user.canvas.enabled = true
    user.canvas.root = root.toString()
    user.canvas.port = port
    user.canvas.liveReload = false
    user.canvas.openClawCompat = true
    buildGatewayConfigFromUserSettings(user)
}

private func canvasE2ePort(): Int64 {
    debugNextGatewayCanvasHostRuntimePortForTest()
}

private func canvasE2eString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func canvasE2eBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func canvasE2eReadBody(response: HttpResponse): String {
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
    try { String.fromUtf8(out.toArray()) } catch (_: Exception) { "" }
}

private func canvasE2eFetch(url: String): GatewayCanvasE2eHttpResult {
    var attempts: Int64 = 0
    while (attempts < 30) {
        attempts += 1
        try {
            let builder = ClientBuilder()
            builder.readTimeout(Duration.millisecond * 500)
            let client = builder.build()
            try {
                let response = client.send(HttpRequestBuilder().url(url).get().build())
                let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
                return GatewayCanvasE2eHttpResult(Int64(response.status), contentType, canvasE2eReadBody(response))
            } finally {
                client.close()
            }
        } catch (_: Exception) {
            sleep(Duration.millisecond * 100)
        }
    }
    GatewayCanvasE2eHttpResult(0, "", "")
}

private func canvasE2ePostJson(url: String, body: String): GatewayCanvasE2eHttpResult {
    var attempts: Int64 = 0
    while (attempts < 30) {
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
                return GatewayCanvasE2eHttpResult(Int64(response.status), contentType, canvasE2eReadBody(response))
            } finally {
                client.close()
            }
        } catch (_: Exception) {
            sleep(Duration.millisecond * 100)
        }
    }
    GatewayCanvasE2eHttpResult(0, "", "")
}

private func canvasE2eConnectFakeNode(nodeId: String): Unit {
    let params = JsonObject()
    params.put("nodeId", JsonString(nodeId))
    params.put("capabilities", JsonArray([JsonString("canvas")]))
    params.put("commands", JsonArray([
        JsonString("canvas.present"),
        JsonString("canvas.snapshot"),
        JsonString("canvas.a2ui.pushJSONL")
    ]))
    let connected = handleGatewayNodeFamily(
        "node.connect",
        GatewayUserSettings(),
        request: Some(GatewayRpcRequest("node.connect", params: params, clientId: nodeId, mode: "node"))
    ).getOrThrow()
    @Expect(connected.ok, true)
}

private func canvasE2eRefreshCapability(cfg: GatewayConfig, nodeId: String): JsonObject {
    let params = JsonObject()
    params.put("nodeId", JsonString(nodeId))
    let response = gatewayCanvasRefreshNodeCapability(
        cfg,
        GatewayRpcRequest("node.canvas.capability.refresh", params: params, clientId: nodeId, mode: "node")
    )
    @Expect(response.ok, true)
    response.result.asObject()
}

@Test
public class GatewayCanvasE2eTest {
    @TestCase
    public func fakeNodeCompletesCanvasPresentSnapshotA2uiAndCompatAction(): Unit {
        withGatewayCanvasE2eRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html><body>canvas e2e</body></html>".toArray())
            let artifacts = root.join("artifacts")
            debugSetGatewayCanvasToolArtifactRootForTest(Some(artifacts))
            let capturedActions = ArrayList<JsonObject>()
            debugSetGatewayCanvasA2uiActionRunnerForTest(Some({ params: JsonObject =>
                capturedActions.add(params)
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("runId", JsonString("canvas-e2e-action"))
                out
            }))
            let nodeId = "node-canvas-e2e"
            let cfg = canvasE2eConfig(root, canvasE2ePort())
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                debugGatewayNodeInvokeClearForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                canvasE2eConnectFakeNode(nodeId)
                let capability = canvasE2eRefreshCapability(cfg, nodeId)
                let scopedUrl = canvasE2eString(capability, "scopedUrl")
                let a2uiUrl = canvasE2eString(capability, "a2uiUrl")

                let compatFetch = canvasE2eFetch(scopedUrl.replace("/__metis__/canvas/", "/__openclaw__/canvas/"))
                @Expect(compatFetch.status, 200)
                @Expect(compatFetch.body.contains("canvas e2e"), true)

                let presentPayload = JsonObject()
                presentPayload.put("url", JsonString(scopedUrl))
                let presentParams = JsonObject()
                presentParams.put("nodeId", JsonString(nodeId))
                presentParams.put("command", JsonString("canvas.present"))
                presentParams.put("payload", presentPayload)
                let presentAuto = JsonObject()
                presentAuto.put("presented", JsonString("ok"))
                debugGatewayNodeInvokeAutoResultForTest(nodeId, "canvas.present", presentAuto)
                let present = handleGatewayNodeFamily(
                    "node.invoke",
                    GatewayUserSettings(),
                    request: Some(GatewayRpcRequest("node.invoke", params: presentParams, clientId: "operator", mode: "local-cli"))
                ).getOrThrow()
                @Expect(present.ok, true)
                @Expect(canvasE2eString(debugGatewayNodeInvokeLastRequestForTest(nodeId, "canvas.present"), "command"), "canvas.present")

                let snapshotPayload = JsonObject()
                snapshotPayload.put("format", JsonString("png"))
                snapshotPayload.put("base64", JsonString(toBase64String("e2e-png".toArray())))
                debugGatewayNodeInvokeAutoResultForTest(nodeId, "canvas.snapshot", snapshotPayload)
                let snapshotParams = JsonObject()
                snapshotParams.put("nodeId", JsonString(nodeId))
                snapshotParams.put("command", JsonString("canvas.snapshot"))
                snapshotParams.put("payload", JsonObject())
                let snapshot = handleGatewayNodeFamily(
                    "node.invoke",
                    GatewayUserSettings(),
                    request: Some(GatewayRpcRequest("node.invoke", params: snapshotParams, clientId: "operator", mode: "local-cli"))
                ).getOrThrow()
                @Expect(snapshot.ok, true)
                let artifact = gatewayCanvasWriteSnapshotArtifact(
                    gatewayCanvasParseSnapshotPayload(snapshot.result.asObject().get("payload").getOrThrow().asObject())
                )
                @Expect(canvasE2eBool(artifact, "ok"), true)
                @Expect(canvasE2eString(artifact, "mimeType"), "image/png")
                @Expect(exists(Path(canvasE2eString(artifact, "path"))), true)

                let a2uiPayload = JsonObject()
                a2uiPayload.put("jsonl", JsonString("{\"beginRendering\":{}}\n{\"surfaceUpdate\":{\"id\":\"main\"}}\n"))
                let a2uiParams = JsonObject()
                a2uiParams.put("nodeId", JsonString(nodeId))
                a2uiParams.put("command", JsonString("canvas.a2ui.pushJSONL"))
                a2uiParams.put("payload", a2uiPayload)
                let a2uiAuto = JsonObject()
                a2uiAuto.put("accepted", JsonBool(true))
                debugGatewayNodeInvokeAutoResultForTest(nodeId, "canvas.a2ui.pushJSONL", a2uiAuto)
                let a2ui = handleGatewayNodeFamily(
                    "node.invoke",
                    GatewayUserSettings(),
                    request: Some(GatewayRpcRequest("node.invoke", params: a2uiParams, clientId: "operator", mode: "local-cli"))
                ).getOrThrow()
                @Expect(a2ui.ok, true)
                @Expect(canvasE2eString(debugGatewayNodeInvokeLastRequestForTest(nodeId, "canvas.a2ui.pushJSONL"), "command"), "canvas.a2ui.pushJSONL")

                let action = canvasE2ePostJson(
                    a2uiUrl.replace("/__metis__/a2ui/", "/__openclaw__/a2ui/") + "action",
                    "{\"session\":\"canvas-e2e-session\",\"action\":{\"type\":\"submit\",\"label\":\"Approve\"}}"
                )
                @Expect(action.status, 200)
                @Expect(action.body.contains("canvas-a2ui"), true)
                @Expect(capturedActions.size, 1)
                @Expect(canvasE2eString(capturedActions[0], "session"), "canvas-e2e-session")
                @Expect(canvasE2eString(capturedActions[0], "text").contains("Approve"), true)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
                debugGatewayNodeInvokeClearForTest()
                debugSetGatewayCanvasA2uiActionRunnerForTest(None<(JsonObject) -> JsonObject>)
                debugSetGatewayCanvasToolArtifactRootForTest(None<Path>)
            }
        })
    }

    @TestCase
    public func disconnectedFakeNodeSnapshotFailsFastWithoutRawStack(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let params = JsonObject()
            params.put("nodeId", JsonString("node-missing"))
            params.put("command", JsonString("canvas.snapshot"))
            params.put("payload", JsonObject())
            params.put("timeoutMs", 3000.toJsonValue())
            let response = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: params, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            @Expect(response.ok, false)
            @Expect(response.errorCode, "unavailable")
            @Expect(response.error.contains("Exception"), false)
            @Expect(response.error.contains("stack"), false)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }
}
