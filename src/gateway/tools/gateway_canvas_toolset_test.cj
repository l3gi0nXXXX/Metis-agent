package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func canvasToolsetTestRoot(label: String): Path {
    Path("/tmp/metis-gateway-canvas-toolset-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
}

private func withCanvasToolsetTestRoot<T>(label: String, block: (Path) -> T): T {
    let root = canvasToolsetTestRoot(label)
    try { remove(root, recursive: true) } catch (_: Exception) { () }
    Directory.create(root, recursive: true)
    try {
        block(root)
    } finally {
        try { remove(root, recursive: true) } catch (_: Exception) { () }
        debugSetGatewayCanvasToolArtifactRootForTest(None<Path>)
    }
}

private func canvasToolsetObj(raw: String): JsonObject {
    try {
        JsonValue.fromStr(raw).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func canvasToolsetString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func canvasToolsetBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

@Test
public class GatewayCanvasToolsetTest {
    @TestCase
    public func presentToolBuildsNodeInvokeParamsWithTargetAlias(): Unit {
        let methods = ArrayList<String>()
        let paramsSeen = ArrayList<JsonObject>()
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            gatewayCallHook: Some({ method: String, params: JsonObject =>
                methods.add(method)
                paramsSeen.add(params)
                let payload = JsonObject()
                payload.put("presented", JsonString("ok"))
                let result = JsonObject()
                result.put("payload", payload)
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("result", result)
                out
            })
        )

        let raw = gatewayWithToolRuntimeContext(context, { =>
            GatewayCanvasToolset().debugCanvasForTest(
                "present",
                Some("node-a"),
                Some("http://127.0.0.1:18793/__metis__/canvas/cap/test/"),
                None<String>,
                None<String>,
                None<String>,
                None<Int64>,
                None<Int64>,
                None<String>,
                None<String>,
                Some(1000)
            )
        })
        let result = canvasToolsetObj(raw)
        let sent = paramsSeen[0]
        let payload = sent.get("payload").getOrThrow().asObject()

        @Expect(canvasToolsetBool(result, "ok"), true)
        @Expect(methods[0], "node.invoke")
        @Expect(canvasToolsetString(sent, "nodeId"), "node-a")
        @Expect(canvasToolsetString(sent, "command"), "canvas.present")
        @Expect(canvasToolsetString(payload, "url"), "http://127.0.0.1:18793/__metis__/canvas/cap/test/")
        @Expect(sent.get("timeoutMs").getOrThrow().toJsonString(), "1000")
    }

    @TestCase
    public func snapshotPayloadWritesArtifactUnderTempRoot(): Unit {
        withCanvasToolsetTestRoot<Unit>("snapshot", { root =>
            debugSetGatewayCanvasToolArtifactRootForTest(Some(root))
            let payload = JsonObject()
            payload.put("format", JsonString("png"))
            payload.put("base64", JsonString(toBase64String("png-bytes".toArray())))

            let parsed = gatewayCanvasParseSnapshotPayload(payload)
            let artifact = gatewayCanvasWriteSnapshotArtifact(parsed)
            let path = canvasToolsetString(artifact, "path")

            @Expect(canvasToolsetBool(parsed, "ok"), true)
            @Expect(canvasToolsetString(parsed, "mimeType"), "image/png")
            @Expect(canvasToolsetBool(artifact, "ok"), true)
            @Expect(canvasToolsetString(artifact, "format"), "png")
            @Expect(path.startsWith(root.toString()), true)
            @Expect(exists(Path(path)), true)
            @Expect(artifact.get("byteCount").getOrThrow().toJsonString(), "9")
        })
    }

    @TestCase
    public func snapshotPayloadRejectsInvalidInputs(): Unit {
        let invalidFormat = JsonObject()
        invalidFormat.put("format", JsonString("bmp"))
        invalidFormat.put("base64", JsonString(toBase64String("image".toArray())))
        let formatResult = gatewayCanvasParseSnapshotPayload(invalidFormat)
        @Expect(canvasToolsetBool(formatResult, "ok"), false)
        @Expect(canvasToolsetString(formatResult, "errorCode"), "invalid_format")

        let invalidBase64 = JsonObject()
        invalidBase64.put("format", JsonString("png"))
        invalidBase64.put("base64", JsonString("***not-base64***"))
        let base64Result = gatewayCanvasParseSnapshotPayload(invalidBase64)
        @Expect(canvasToolsetBool(base64Result, "ok"), false)
        @Expect(canvasToolsetString(base64Result, "errorCode"), "invalid_base64")

        let tooLarge = JsonObject()
        tooLarge.put("format", JsonString("png"))
        tooLarge.put("base64", JsonString(toBase64String("payload".toArray())))
        let tooLargeResult = gatewayCanvasParseSnapshotPayload(tooLarge, maxBase64Bytes: 2)
        @Expect(canvasToolsetBool(tooLargeResult, "ok"), false)
        @Expect(canvasToolsetString(tooLargeResult, "errorCode"), "payload_too_large")
    }

    @TestCase
    public func jsonlPathOutsideRuntimeRootsIsRejectedBeforeGatewayCall(): Unit {
        withCanvasToolsetTestRoot<Unit>("jsonl-path", { root =>
            let workspace = root.join("workspace")
            let agent = root.join("agent")
            Directory.create(workspace, recursive: true)
            Directory.create(agent, recursive: true)
            let outside = root.join("outside.jsonl")
            File.writeTo(outside, "{\"type\":\"text\",\"text\":\"secret\"}\n".toArray())
            let calls = ArrayList<String>()
            let context = GatewayToolRuntimeContext(
                "cli",
                channelName: "cli",
                workspaceDir: workspace.toString(),
                agentDir: agent.toString(),
                gatewayCallHook: Some({ method: String, _params: JsonObject =>
                    calls.add(method)
                    JsonObject()
                })
            )

            let raw = gatewayWithToolRuntimeContext(context, { =>
                GatewayCanvasToolset().debugCanvasForTest(
                    "a2ui_push",
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    None<String>,
                    Some(outside.toString()),
                    None<Int64>
                )
            })
            let result = canvasToolsetObj(raw)

            @Expect(canvasToolsetBool(result, "ok"), false)
            @Expect(canvasToolsetString(result, "errorCode"), "invalid_jsonl_path")
            @Expect(canvasToolsetString(result, "error").contains("outside allowed workspace roots"), true)
            @Expect(calls.size, 0)
        })
    }

    @TestCase
    public func navigateToolUsesGatewayHookAndReturnsOk(): Unit {
        let methods = ArrayList<String>()
        let paramsSeen = ArrayList<JsonObject>()
        let context = GatewayToolRuntimeContext(
            "feishu",
            channelName: "feishu",
            sessionKey: "feishu:chat:1",
            gatewayCallHook: Some({ method: String, params: JsonObject =>
                methods.add(method)
                paramsSeen.add(params)
                let payload = JsonObject()
                payload.put("navigated", JsonString("ok"))
                let result = JsonObject()
                result.put("payload", payload)
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("result", result)
                out
            })
        )

        let raw = gatewayWithToolRuntimeContext(context, { =>
            GatewayCanvasToolset().debugCanvasForTest(
                "navigate",
                None<String>,
                None<String>,
                Some("http://127.0.0.1:18793/page.html"),
                None<String>,
                None<String>,
                None<Int64>,
                None<Int64>,
                None<String>,
                None<String>,
                None<Int64>
            )
        })
        let result = canvasToolsetObj(raw)
        let sentPayload = paramsSeen[0].get("payload").getOrThrow().asObject()

        @Expect(canvasToolsetBool(result, "ok"), true)
        @Expect(methods[0], "node.invoke")
        @Expect(canvasToolsetString(paramsSeen[0], "command"), "canvas.navigate")
        @Expect(canvasToolsetString(sentPayload, "url"), "http://127.0.0.1:18793/page.html")
    }

    @TestCase
    public func a2uiPushToolUsesPushJsonlCommandAndSendsJsonl(): Unit {
        let methods = ArrayList<String>()
        let paramsSeen = ArrayList<JsonObject>()
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:a2ui",
            gatewayCallHook: Some({ method: String, params: JsonObject =>
                methods.add(method)
                paramsSeen.add(params)
                let payload = JsonObject()
                payload.put("accepted", JsonBool(true))
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("payload", payload)
                out
            })
        )

        let raw = gatewayWithToolRuntimeContext(context, { =>
            GatewayCanvasToolset().debugCanvasForTest(
                "a2ui_push",
                Some("node-a2ui"),
                None<String>,
                None<String>,
                None<String>,
                None<String>,
                None<Int64>,
                None<Int64>,
                Some("{\"beginRendering\":{}}\n"),
                None<String>,
                Some(1000)
            )
        })
        let result = canvasToolsetObj(raw)
        let sent = paramsSeen[0]
        let payload = sent.get("payload").getOrThrow().asObject()

        @Expect(canvasToolsetBool(result, "ok"), true)
        @Expect(methods[0], "node.invoke")
        @Expect(canvasToolsetString(sent, "nodeId"), "node-a2ui")
        @Expect(canvasToolsetString(sent, "command"), "canvas.a2ui.pushJSONL")
        @Expect(canvasToolsetString(payload, "jsonl").contains("beginRendering"), true)
    }

    @TestCase
    public func canvasToolWithoutGatewayHookReturnsUnavailable(): Unit {
        let raw = GatewayCanvasToolset().debugCanvasForTest(
            "navigate",
            None<String>,
            None<String>,
            Some("http://127.0.0.1:18793/page.html"),
            None<String>,
            None<String>,
            None<Int64>,
            None<Int64>,
            None<String>,
            None<String>,
            None<Int64>
        )
        let result = canvasToolsetObj(raw)

        @Expect(canvasToolsetBool(result, "ok"), false)
        @Expect(canvasToolsetString(result, "errorCode"), "gateway_call_unavailable")
    }
}
