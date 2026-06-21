package metis.gateway.runtime

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.model.GatewayConfig

import std.convert.Parsable
import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject}
import stdx.net.http.*

private func withGatewayCanvasTestRoot<T>(block: (Path) -> T): T {
    let root = Path("/tmp/metis-canvas-host-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try {
        if (exists(root)) {
            remove(root, recursive: true)
        }
    } catch (_: Exception) {
        ()
    }
    Directory.create(root, recursive: true)
    try {
        return block(root)
    } finally {
        try {
            remove(root, recursive: true)
        } catch (_: Exception) {
            ()
        }
    }
}

private func canvasTestConfig(enabled: Bool, root: String, port!: Int64 = 18793): GatewayConfig {
    var user = GatewayUserSettings()
    user.canvas.enabled = enabled
    user.canvas.root = root
    user.canvas.port = port
    user.canvas.liveReload = true
    buildGatewayConfigFromUserSettings(user)
}

private func canvasTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func canvasTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func canvasTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

private class CanvasHttpProbeResult {
    let status: Int64
    let contentType: String
    let body: String

    init(status: Int64, contentType: String, body: String) {
        this.status = status
        this.contentType = contentType
        this.body = body
    }
}

private func canvasTestPort(): Int64 {
    20000 + (DateTime.now().toUnixTimeStamp().toNanoseconds() % 20000)
}

private func canvasReadHttpBody(response: HttpResponse): String {
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

private func canvasFetch(url: String, method!: String = "GET"): CanvasHttpProbeResult {
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
                return CanvasHttpProbeResult(Int64(response.status), contentType, canvasReadHttpBody(response))
            } finally {
                client.close()
            }
        } catch (_: Exception) {
            sleep(Duration.millisecond * 50)
        }
    }
    CanvasHttpProbeResult(0, "", "")
}

private func canvasJsonArrayContains(arr: JsonArray, expected: String): Bool {
    for (item in arr.getItems()) {
        let value = try {
            item.asString().getValue()
        } catch (_: Exception) {
            ""
        }
        if (value == expected) {
            return true
        }
    }
    false
}

@Test
public class GatewayCanvasHostRootStateTest {
    @TestCase
    public func disabledConfigReportsDisabledWithoutHttpUrl(): Unit {
        let state = gatewayCanvasResolveRootState(canvasTestConfig(false, ""))
        @Expect(canvasTestBool(state, "enabled"), false)
        @Expect(canvasTestString(state, "phase"), "disabled")
        @Expect(canvasTestBool(state, "healthy"), false)
        @Expect(canvasTestString(state, "httpUrl"), "")
        @Expect(canvasTestBool(state, "hostStarted"), false)
    }

    @TestCase
    public func readableTempRootReportsMountedButHostNotStarted(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            let state = gatewayCanvasResolveRootState(canvasTestConfig(true, root.toString()))
            @Expect(canvasTestBool(state, "rootPresent"), true)
            @Expect(canvasTestBool(state, "rootReadable"), true)
            @Expect(canvasTestString(state, "assetState"), "mounted")
            @Expect(canvasTestString(state, "phase"), "configured")
            @Expect(canvasTestBool(state, "hostStarted"), false)
            @Expect(canvasTestBool(state, "healthy"), false)
            @Expect(canvasTestString(state, "httpUrl"), "")
        })
    }

    @TestCase
    public func missingRootDoesNotReportReadyOrHealthy(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            let missing = root.join("missing").toString()
            let state = gatewayCanvasResolveRootState(canvasTestConfig(true, missing))
            @Expect(canvasTestBool(state, "rootPresent"), false)
            @Expect(canvasTestString(state, "assetState"), "missing-root")
            @Expect(canvasTestString(state, "phase"), "misconfigured")
            @Expect(canvasTestBool(state, "healthy"), false)
            @Expect(canvasTestString(state, "httpUrl"), "")
        })
    }

    @TestCase
    public func rootResolverBlocksTraversalAndSymlinkEscape(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            let outside = root.parent.join("metis-canvas-outside-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            Directory.create(outside, recursive: true)
            File.writeTo(outside.join("secret.txt"), "secret".toArray())
            let linkPath = root.join("escape")
            try {
                let _ = executeWithOutput("ln", ["-s", outside.toString(), linkPath.toString()])
            } catch (_: Exception) {
                ()
            }
            @Expect(gatewayCanvasResolveFileWithinRoot(root, "/%2e%2e/package.json").status, "blocked")
            @Expect(gatewayCanvasResolveFileWithinRoot(root, "/../x").status, "blocked")
            if (exists(linkPath)) {
                let linkResult = gatewayCanvasResolveFileWithinRoot(root, "/escape/secret.txt")
                @Expect(linkResult.ok, false)
                @Expect(linkResult.status, "blocked")
            }
            try {
                remove(outside, recursive: true)
            } catch (_: Exception) {
                ()
            }
        })
    }

    @TestCase
    public func canvasRuntimeRpcUsesResolvedRootState(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            var user = GatewayUserSettings()
            user.canvas.enabled = true
            user.canvas.root = root.toString()
            let response = handleGatewayOpsFamily("canvas.runtime", user)
            @Expect(response.isSome(), true)
            let canvas = response.getOrThrow().result.asObject().get("canvas").getOrThrow().asObject()
            @Expect(canvasTestBool(canvas, "rootPresent"), true)
            @Expect(canvasTestBool(canvas, "hostStarted"), false)
            @Expect(canvasTestBool(canvas, "healthy"), false)
            @Expect(canvasTestString(canvas, "httpUrl"), "")
        })
    }

    @TestCase
    public func emptyRootReturnsMisconfiguredActionWithoutHttpUrl(): Unit {
        var user = GatewayUserSettings()
        user.canvas.enabled = true
        user.canvas.root = ""
        let response = handleGatewayOpsFamily("canvas.audit", user)
        @Expect(response.isSome(), true)
        let audit = response.getOrThrow().result.asObject().get("audit").getOrThrow().asObject()
        let pipeline = audit.get("pipeline").getOrThrow().asObject()
        @Expect(canvasTestString(pipeline, "pipelineState"), "misconfigured")
        @Expect(canvasTestInt(audit, "actionsNeeded") > 0, true)
        @Expect(canvasTestString(pipeline, "httpUrl"), "")
    }

    @TestCase
    public func routeScannerListsCanvasRootAndAssetsWithoutDiskRoot(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>metis</html>".toArray())
            File.writeTo(root.join("app.js"), "console.log('metis')".toArray())
            let cfg = canvasTestConfig(true, root.toString(), port: canvasTestPort())
            let routes = gatewayCanvasRegisteredRoutes(cfg)
            @Expect(canvasJsonArrayContains(routes, "/__metis__/canvas/"), true)
            @Expect(canvasJsonArrayContains(routes, "/__metis__/canvas/app.js"), true)
            @Expect(routes.toJsonString().contains(root.toString()), false)
        })
    }

    @TestCase
    public func mimeHelperRecognizesCanvasAssetTypes(): Unit {
        @Expect(gatewayCanvasMimeType("index.html"), "text/html; charset=utf-8")
        @Expect(gatewayCanvasMimeType("app.js"), "text/javascript; charset=utf-8")
        @Expect(gatewayCanvasMimeType("style.css"), "text/css; charset=utf-8")
        @Expect(gatewayCanvasMimeType("image.png"), "image/png")
        @Expect(gatewayCanvasMimeType("photo.jpg"), "image/jpeg")
        @Expect(gatewayCanvasMimeType("icon.svg"), "image/svg+xml")
        @Expect(gatewayCanvasMimeType("module.wasm"), "application/wasm")
        @Expect(gatewayCanvasMimeType("asset.bin"), "application/octet-stream")
    }

    @TestCase
    public func missingCanvasAssetReturnsNotFoundWithoutDiskRoot(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>metis</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let result = canvasFetch("http://127.0.0.1:${port}/__metis__/canvas/missing.txt")
                @Expect(result.status, 404)
                @Expect(result.body.contains(root.toString()), false)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
            }
        })
    }

    @TestCase
    public func canvasRouteRejectsPostAndPut(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>metis</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let post = canvasFetch("http://127.0.0.1:${port}/__metis__/canvas/", method: "POST")
                let put = canvasFetch("http://127.0.0.1:${port}/__metis__/canvas/", method: "PUT")
                @Expect(post.status, 405)
                @Expect(put.status, 405)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
            }
        })
    }

    @TestCase
    public func startedHostServesTempRootIndexAndReportsHealthy(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html><body>metis canvas</body></html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let result = canvasFetch("http://127.0.0.1:${port}/__metis__/canvas/")
                @Expect(result.status, 200)
                @Expect(result.contentType, "text/html; charset=utf-8")
                @Expect(result.body.contains("metis canvas"), true)
                let state = GatewayCanvasHostRuntime.snapshot(cfg)
                @Expect(canvasTestBool(state, "hostStarted"), true)
                @Expect(canvasTestBool(state, "healthy"), true)
                @Expect(canvasTestString(state, "phase"), "ready")
                @Expect(canvasTestString(state, "httpUrl"), "http://127.0.0.1:${port}/__metis__/canvas/")
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
            }
        })
    }

    @TestCase
    public func missingRootDoesNotStartCanvasHost(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            let port = canvasTestPort()
            let missing = root.join("missing").toString()
            let cfg = canvasTestConfig(true, missing, port: port)
            try {
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let state = GatewayCanvasHostRuntime.snapshot(cfg)
                @Expect(GatewayCanvasHostRuntime.isRunning(), false)
                @Expect(canvasTestBool(state, "hostStarted"), false)
                @Expect(canvasTestBool(state, "healthy"), false)
                @Expect(canvasTestString(state, "httpUrl"), "")
                @Expect(canvasTestString(state, "phase"), "misconfigured")
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
            }
        })
    }
}
