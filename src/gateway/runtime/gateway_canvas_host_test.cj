package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.model.GatewayConfig
import metis.gateway.tools.debugSetGatewayCanvasToolArtifactRootForTest

import std.convert.Parsable
import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.sync.Mutex
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}
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

private func canvasTestUserSettings(enabled: Bool, root: String, port!: Int64 = 18793, openClawCompat!: Bool = false): GatewayUserSettings {
    var user = GatewayUserSettings()
    user.canvas.enabled = enabled
    user.canvas.root = root
    user.canvas.port = port
    user.canvas.liveReload = true
    user.canvas.openClawCompat = openClawCompat
    user
}

private func canvasTestUserSettingsWithLiveReload(enabled: Bool, root: String, port: Int64, liveReload: Bool): GatewayUserSettings {
    var user = canvasTestUserSettings(enabled, root, port: port)
    user.canvas.liveReload = liveReload
    user
}

private func canvasTestConfig(enabled: Bool, root: String, port!: Int64 = 18793, openClawCompat!: Bool = false): GatewayConfig {
    buildGatewayConfigFromUserSettings(canvasTestUserSettings(enabled, root, port: port, openClawCompat: openClawCompat))
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

private func canvasScopedUrlForTest(cfg: GatewayConfig, nodeId: String): String {
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
    let result = try {
        response.result.asObject()
    } catch (_: Exception) {
        JsonObject()
    }
    canvasTestString(result, "scopedUrl")
}

private func canvasWaitUntil(timeoutMs: Int64, condition: () -> Bool): Bool {
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt < timeoutMs) {
        if (condition()) {
            return true
        }
        sleep(Duration.millisecond * 50)
    }
    condition()
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
    public func openClawCompatRoutesAreDisabledByDefault(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>metis</html>".toArray())
            let cfg = canvasTestConfig(true, root.toString(), port: canvasTestPort())
            let routes = gatewayCanvasRegisteredRoutes(cfg)
            @Expect(gatewayCanvasCompatRoutesEnabled(cfg), false)
            @Expect(canvasJsonArrayContains(routes, "/__metis__/canvas/"), true)
            @Expect(routes.toJsonString().contains("/__openclaw__/"), false)
            @Expect(gatewayCanvasOpenClawCompatPath("/__metis__/canvas/cap/token/app.js"), "/__openclaw__/canvas/cap/token/app.js")
            @Expect(gatewayCanvasOpenClawCompatPath("/__metis__/a2ui/cap/token/action"), "/__openclaw__/a2ui/cap/token/action")
        })
    }

    @TestCase
    public func openClawCompatRoutesAreRegisteredOnlyWhenEnabled(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>metis</html>".toArray())
            File.writeTo(root.join("app.js"), "console.log('metis')".toArray())
            let cfg = canvasTestConfig(true, root.toString(), port: canvasTestPort(), openClawCompat: true)
            let routes = gatewayCanvasRegisteredRoutes(cfg)
            @Expect(gatewayCanvasCompatRoutesEnabled(cfg), true)
            @Expect(canvasJsonArrayContains(routes, "/__metis__/canvas/"), true)
            @Expect(canvasJsonArrayContains(routes, "/__openclaw__/canvas/"), true)
            @Expect(canvasJsonArrayContains(routes, "/__openclaw__/canvas/app.js"), true)
            @Expect(routes.toJsonString().contains("lobster"), false)
            @Expect(routes.toJsonString().contains("openclaw/assets"), false)
        })
    }

    @TestCase
    public func openClawCompatAliasUsesSameCapabilityHandler(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html><body>metis compat canvas</body></html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port, openClawCompat: true)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let unauth = canvasFetch("http://127.0.0.1:${port}/__openclaw__/canvas/")
                @Expect(unauth.status, 401)

                let scopedUrl = canvasScopedUrlForTest(cfg, "node-openclaw-compat")
                let compatScopedUrl = scopedUrl.replace("/__metis__/canvas/", "/__openclaw__/canvas/")
                let canonical = canvasFetch(scopedUrl)
                let compat = canvasFetch(compatScopedUrl)
                @Expect(canonical.status, 200)
                @Expect(compat.status, 200)
                @Expect(compat.body.contains("metis compat canvas"), true)

                let state = GatewayCanvasHostRuntime.snapshot(cfg)
                @Expect(canvasJsonArrayContains(state.get("routes").getOrThrow().asArray(), "/__openclaw__/canvas/"), true)
                @Expect(canvasTestBool(state, "openClawCompat"), true)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func expiredCapabilityIsRejectedButRefreshedCompatUrlWorks(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html><body>fresh canvas</body></html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port, openClawCompat: true)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                debugGatewayCanvasPutCapabilityForTest("expired-token", "node-refresh", "node", gatewayCanvasCapabilityNowMs() - 1000)
                GatewayCanvasHostRuntime.registerCapabilityRoutes(cfg, "expired-token")
                let expired = canvasFetch(gatewayCanvasScopedRouteUrl(cfg, "expired-token"))
                @Expect(expired.status, 401)

                let freshScopedUrl = canvasScopedUrlForTest(cfg, "node-refresh")
                let fresh = canvasFetch(freshScopedUrl.replace("/__metis__/canvas/", "/__openclaw__/canvas/"))
                @Expect(fresh.status, 200)
                @Expect(fresh.body.contains("fresh canvas"), true)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
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
            let user = canvasTestUserSettings(true, root.toString(), port: port)
            let cfg = buildGatewayConfigFromUserSettings(user)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let scopedUrl = canvasScopedUrlForTest(cfg, "node-missing-asset")
                let result = canvasFetch(scopedUrl + "missing.txt")
                @Expect(result.status, 404)
                @Expect(result.body.contains(root.toString()), false)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
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
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let scopedUrl = canvasScopedUrlForTest(cfg, "node-methods")
                let post = canvasFetch(scopedUrl, method: "POST")
                let put = canvasFetch(scopedUrl, method: "PUT")
                @Expect(post.status, 405)
                @Expect(put.status, 405)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
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
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let scopedUrl = canvasScopedUrlForTest(cfg, "node-started-host")
                let result = canvasFetch(scopedUrl)
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
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func liveReloadDisabledReportsStaticWithoutPoller(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>static</html>".toArray())
            let port = canvasTestPort()
            let cfg = buildGatewayConfigFromUserSettings(canvasTestUserSettingsWithLiveReload(true, root.toString(), port, false))
            try {
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let state = GatewayCanvasHostRuntime.snapshot(cfg)
                let live = GatewayCanvasHostRuntime.debugLiveReloadStateForTest()
                @Expect(canvasTestBool(state, "hostStarted"), true)
                @Expect(canvasTestString(state, "watchState"), "static")
                @Expect(canvasTestBool(live, "running"), false)
                @Expect(canvasTestInt(live, "eventCount"), 0)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
            }
        })
    }

    @TestCase
    public func liveReloadPollerPublishesReloadAndStopsCleanly(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>reload</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            let publishLock = Mutex()
            let payloads = ArrayList<JsonObject>()
            debugSetGatewayCanvasLiveReloadPublisherForTest(Some({ payload: JsonObject =>
                var count: Int64 = 0
                synchronized(publishLock) {
                    payloads.add(payload)
                    count = Int64(payloads.size)
                }
                count
            }))
            try {
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                @Expect(canvasWaitUntil(1000, { => canvasTestBool(GatewayCanvasHostRuntime.debugLiveReloadStateForTest(), "running") }), true)
                sleep(Duration.millisecond * 320)
                File.writeTo(root.join("app.js"), "console.log('reload')".toArray())
                @Expect(canvasWaitUntil(2000, { =>
                    synchronized(publishLock) {
                        payloads.size > 0
                    }
                }), true)
                let first = synchronized(publishLock) {
                    payloads[0]
                }
                @Expect(canvasTestString(first, "type"), "reload")
                @Expect(canvasTestString(first, "reason"), "canvas-root-changed")
                @Expect(first.toJsonString().contains(root.toString()), false)
                let state = GatewayCanvasHostRuntime.snapshot(cfg)
                @Expect(canvasTestString(state, "watchState"), "watching")
                @Expect(canvasTestInt(state, "liveReloadEventCount") > 0, true)
                GatewayCanvasHostRuntime.stopIfRunning()
                let countAfterStop = synchronized(publishLock) {
                    payloads.size
                }
                File.writeTo(root.join("after-stop.js"), "console.log('stopped')".toArray())
                sleep(Duration.millisecond * 420)
                let finalCount = synchronized(publishLock) {
                    payloads.size
                }
                @Expect(finalCount, countAfterStop)
                @Expect(canvasTestBool(GatewayCanvasHostRuntime.debugLiveReloadStateForTest(), "running"), false)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugSetGatewayCanvasLiveReloadPublisherForTest(None<(JsonObject) -> Int64>)
            }
        })
    }

    @TestCase
    public func canvasReloadEventKindIsControlUiDirectPushEligible(): Unit {
        @Expect(debugGatewayServerShouldDirectPushControlUiEventForTest("control-ui-test", "control-ui.canvas.reload"), true)
        @Expect(debugGatewayServerShouldDirectPushControlUiEventForTest("control-ui-test", "control-ui.unknown"), false)
    }

    @TestCase
    public func missingRootDoesNotStartCanvasHost(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            let port = canvasTestPort()
            let missing = root.join("missing").toString()
            let cfg = canvasTestConfig(true, missing, port: port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let state = GatewayCanvasHostRuntime.snapshot(cfg)
                @Expect(GatewayCanvasHostRuntime.isRunning(), false)
                @Expect(canvasTestBool(state, "hostStarted"), false)
                @Expect(canvasTestBool(state, "healthy"), false)
                @Expect(canvasTestString(state, "httpUrl"), "")
                @Expect(canvasTestString(state, "phase"), "misconfigured")
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func capabilityTokensAreNonEmptyAndUnique(): Unit {
        let seen = ArrayList<String>()
        for (_ in 0..100) {
            let token = debugGatewayCanvasMintCapabilityTokenForTest()
            @Expect(token.isEmpty(), false)
            @Expect(seen.contains(token), false)
            seen.add(token)
        }
    }

    @TestCase
    public func scopedCanvasUrlPathNormalizesTokenAndCanvasPath(): Unit {
        let token = "metis_canvas_cap_test"
        let good = gatewayCanvasNormalizeScopedUrlPath("/__metis__/canvas/cap/${token}/app.js")
        @Expect(good.ok, true)
        @Expect(good.token, token)
        @Expect(good.canvasPath, "/app.js")
        let root = gatewayCanvasNormalizeScopedUrlPath("/__metis__/canvas/cap/${token}/")
        @Expect(root.ok, true)
        @Expect(root.canvasPath, "/")
        let malformed = gatewayCanvasNormalizeScopedUrlPath("/__metis__/canvas/app.js")
        @Expect(malformed.ok, false)
        @Expect(malformed.errorCode, "malformed_scoped_path")
    }

    @TestCase
    public func expiredCapabilityCannotReadCanvasRoute(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>expired</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let token = "metis_canvas_cap_expired"
                debugGatewayCanvasPutCapabilityForTest(token, "expired-node", "node", gatewayCanvasCapabilityNowMs() - 1000)
                GatewayCanvasHostRuntime.registerCapabilityRoutes(cfg, token)
                let result = canvasFetch(gatewayCanvasScopedRouteUrl(cfg, token))
                @Expect(result.status, 401)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func operatorCapabilityCannotReadCanvasRoute(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>operator</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let token = "metis_canvas_cap_operator"
                debugGatewayCanvasPutCapabilityForTest(token, "operator-session", "operator", gatewayCanvasCapabilityNowMs() + 600000)
                GatewayCanvasHostRuntime.registerCapabilityRoutes(cfg, token)
                let result = canvasFetch(gatewayCanvasScopedRouteUrl(cfg, token))
                @Expect(result.status, 401)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func fakeActiveNodeRefreshesCapabilityAndReadsCanvas(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>capability ok</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let scopedUrl = canvasScopedUrlForTest(cfg, "node-capability-ok")
                @Expect(scopedUrl.isEmpty(), false)
                let result = canvasFetch(scopedUrl)
                @Expect(result.status, 200)
                @Expect(result.body.contains("capability ok"), true)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func refreshCapabilityWithoutActiveNodeReturnsUnavailable(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>missing node</html>".toArray())
            let port = canvasTestPort()
            let user = canvasTestUserSettings(true, root.toString(), port: port)
            let cfg = buildGatewayConfigFromUserSettings(user)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let params = JsonObject()
                params.put("nodeId", JsonString("missing-node"))
                let response = handleGatewayNodeFamily(
                    "node.canvas.capability.refresh",
                    user,
                    request: Some(GatewayRpcRequest("node.canvas.capability.refresh", params: params, clientId: "missing-node", mode: "node"))
                ).getOrThrow()
                @Expect(response.ok, false)
                @Expect(response.errorCode, "unavailable")
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func unscopedCanvasRouteRequiresCapability(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            File.writeTo(root.join("index.html"), "<html>unscoped</html>".toArray())
            let port = canvasTestPort()
            let cfg = canvasTestConfig(true, root.toString(), port: port)
            try {
                debugGatewayCanvasClearNodeSessionsForTest()
                GatewayCanvasHostRuntime.startIfNeeded(cfg)
                let result = canvasFetch("http://127.0.0.1:${port}/__metis__/canvas/")
                @Expect(result.status, 401)
            } finally {
                GatewayCanvasHostRuntime.stopIfRunning()
                debugGatewayCanvasClearNodeSessionsForTest()
            }
        })
    }

    @TestCase
    public func connectedFakeNodeRegistryReportsCanvasCapability(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let params = JsonObject()
            params.put("nodeId", JsonString("node-registry"))
            params.put("capabilities", JsonArray([JsonString("canvas")]))
            params.put("commands", JsonArray([JsonString("canvas.present")]))
            let connected = handleGatewayNodeFamily(
                "node.connect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.connect", params: params, clientId: "node-registry", mode: "node"))
            ).getOrThrow()
            @Expect(connected.ok, true)
            let listed = handleGatewayNodeFamily("node.list", GatewayUserSettings()).getOrThrow()
            let nodes = listed.result.asObject().get("nodes").getOrThrow().asArray()
            @Expect(nodes.size(), 1)
            let node = nodes[0].asObject()
            @Expect(canvasTestBool(node, "connected"), true)
            @Expect(canvasTestBool(node, "canvasCapable"), true)
            @Expect(canvasJsonArrayContains(node.get("commands").getOrThrow().asArray(), "canvas.present"), true)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func nodeHeartbeatAndDisconnectUpdateConnectedRegistry(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let params = JsonObject()
            params.put("nodeId", JsonString("node-heartbeat"))
            params.put("capabilities", JsonArray([JsonString("canvas")]))
            params.put("commands", JsonArray([JsonString("canvas.present")]))
            let connected = handleGatewayNodeFamily(
                "node.connect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.connect", params: params, clientId: "node-heartbeat", mode: "node"))
            ).getOrThrow()
            @Expect(connected.ok, true)
            let heartbeat = handleGatewayNodeFamily(
                "node.heartbeat",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.heartbeat", params: params, clientId: "node-heartbeat", mode: "node"))
            ).getOrThrow()
            @Expect(heartbeat.ok, true)
            let disconnected = handleGatewayNodeFamily(
                "node.disconnect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.disconnect", params: params, clientId: "node-heartbeat", mode: "node"))
            ).getOrThrow()
            @Expect(disconnected.ok, true)
            let listed = handleGatewayNodeFamily("node.list", GatewayUserSettings()).getOrThrow()
            @Expect(listed.result.asObject().get("nodes").getOrThrow().asArray().size(), 0)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func gatewayNodeInvokeCompletesWithFakeNodeResult(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let connectParams = JsonObject()
            connectParams.put("nodeId", JsonString("node-invoke"))
            connectParams.put("capabilities", JsonArray([JsonString("canvas")]))
            connectParams.put("commands", JsonArray([JsonString("canvas.present")]))
            let _ = handleGatewayNodeFamily(
                "node.connect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.connect", params: connectParams, clientId: "node-invoke", mode: "node"))
            ).getOrThrow()
            let autoPayload = JsonObject()
            autoPayload.put("presented", JsonString("ok"))
            debugGatewayNodeInvokeAutoResultForTest("node-invoke", "canvas.present", autoPayload)

            let payload = JsonObject()
            payload.put("url", JsonString("http://127.0.0.1:18793/__metis__/canvas/cap/test/"))
            let invokeParams = JsonObject()
            invokeParams.put("nodeId", JsonString("node-invoke"))
            invokeParams.put("command", JsonString("canvas.present"))
            invokeParams.put("payload", payload)
            let response = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: invokeParams, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            @Expect(response.ok, true)
            let result = response.result.asObject()
            @Expect(canvasTestString(result, "nodeId"), "node-invoke")
            @Expect(canvasTestString(result, "command"), "canvas.present")
            @Expect(canvasTestString(result.get("payload").getOrThrow().asObject(), "presented"), "ok")
            @Expect(debugGatewayNodeInvokeRequestCountForTest("node-invoke", "canvas.present"), 1)
            let sent = debugGatewayNodeInvokeLastRequestForTest("node-invoke", "canvas.present")
            @Expect(canvasTestString(sent, "command"), "canvas.present")
            @Expect(canvasTestString(sent.get("payload").getOrThrow().asObject(), "url").contains("/__metis__/canvas/cap/test/"), true)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func lateInvokeResultIsIgnoredSuccess(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let params = JsonObject()
            params.put("invokeId", JsonString("missing-invoke"))
            params.put("nodeId", JsonString("node-late"))
            let response = handleGatewayNodeFamily(
                "node.invoke.result",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke.result", params: params, clientId: "node-late", mode: "node"))
            ).getOrThrow()
            @Expect(response.ok, true)
            @Expect(canvasTestBool(response.result.asObject(), "ignored"), true)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func duplicateIdempotencyKeyDoesNotSendDuplicateRequest(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let connectParams = JsonObject()
            connectParams.put("nodeId", JsonString("node-idempotent"))
            connectParams.put("capabilities", JsonArray([JsonString("canvas")]))
            connectParams.put("commands", JsonArray([JsonString("canvas.present")]))
            let _ = handleGatewayNodeFamily(
                "node.connect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.connect", params: connectParams, clientId: "node-idempotent", mode: "node"))
            ).getOrThrow()
            let autoPayload = JsonObject()
            autoPayload.put("presented", JsonString("ok"))
            debugGatewayNodeInvokeAutoResultForTest("node-idempotent", "canvas.present", autoPayload)
            let invokeParams = JsonObject()
            invokeParams.put("nodeId", JsonString("node-idempotent"))
            invokeParams.put("command", JsonString("canvas.present"))
            invokeParams.put("payload", JsonObject())
            invokeParams.put("idempotencyKey", JsonString("same-action"))
            let first = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: invokeParams, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            let second = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: invokeParams, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            @Expect(first.ok, true)
            @Expect(second.ok, true)
            @Expect(canvasTestString(first.result.asObject(), "invokeId"), canvasTestString(second.result.asObject(), "invokeId"))
            @Expect(canvasTestBool(second.result.asObject(), "duplicate"), true)
            @Expect(debugGatewayNodeInvokeRequestCountForTest("node-idempotent", "canvas.present"), 1)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func unadvertisedCanvasCommandIsRejectedWithoutSending(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let connectParams = JsonObject()
            connectParams.put("nodeId", JsonString("node-no-snapshot"))
            connectParams.put("capabilities", JsonArray([JsonString("canvas")]))
            connectParams.put("commands", JsonArray([JsonString("canvas.present")]))
            let _ = handleGatewayNodeFamily(
                "node.connect",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.connect", params: connectParams, clientId: "node-no-snapshot", mode: "node"))
            ).getOrThrow()
            let invokeParams = JsonObject()
            invokeParams.put("nodeId", JsonString("node-no-snapshot"))
            invokeParams.put("command", JsonString("canvas.snapshot"))
            invokeParams.put("payload", JsonObject())
            let response = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: invokeParams, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            @Expect(response.ok, false)
            @Expect(response.errorCode, "invalid_request")
            @Expect(debugGatewayNodeInvokeRequestCountForTest("node-no-snapshot", "canvas.snapshot"), 0)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func offlineNodeInvokeReturnsUnavailableWithoutTimeoutWait(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let startedAt = gatewayCanvasCapabilityNowMs()
            let invokeParams = JsonObject()
            invokeParams.put("nodeId", JsonString("node-offline"))
            invokeParams.put("command", JsonString("canvas.present"))
            invokeParams.put("payload", JsonObject())
            invokeParams.put("timeoutMs", 3000.toJsonValue())
            let response = handleGatewayNodeFamily(
                "node.invoke",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke", params: invokeParams, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            let elapsed = gatewayCanvasCapabilityNowMs() - startedAt
            @Expect(response.ok, false)
            @Expect(response.errorCode, "unavailable")
            @Expect(elapsed < 500, true)
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func operatorCannotSubmitNodeInvokeResult(): Unit {
        try {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
            let params = JsonObject()
            params.put("invokeId", JsonString("invoke-from-operator"))
            params.put("nodeId", JsonString("node-forbidden"))
            let response = handleGatewayNodeFamily(
                "node.invoke.result",
                GatewayUserSettings(),
                request: Some(GatewayRpcRequest("node.invoke.result", params: params, clientId: "operator", mode: "local-cli"))
            ).getOrThrow()
            @Expect(response.ok, false)
            @Expect(response.errorCode, "forbidden")
        } finally {
            debugGatewayCanvasClearNodeSessionsForTest()
            debugGatewayNodeInvokeClearForTest()
        }
    }

    @TestCase
    public func nodesCanvasCliSnapshotUsesFakeRunnerAndWritesArtifact(): Unit {
        withGatewayCanvasTestRoot<Unit>({ root =>
            debugSetGatewayCanvasToolArtifactRootForTest(Some(root))
            debugSetGatewayNodesCanvasCliRunnerForTest(Some({ method: String, params: JsonObject =>
                @Expect(method, "node.invoke")
                @Expect(canvasTestString(params, "nodeId"), "node-cli")
                @Expect(canvasTestString(params, "command"), "canvas.snapshot")
                let requestPayload = params.get("payload").getOrThrow().asObject()
                @Expect(canvasTestString(requestPayload, "format"), "png")
                let snapshot = JsonObject()
                snapshot.put("format", JsonString("png"))
                snapshot.put("base64", JsonString(toBase64String("cli-png".toArray())))
                let result = JsonObject()
                result.put("payload", snapshot)
                GatewayRpcResponse(true, method, result: result)
            }))
            try {
                let response = gatewayNodesCanvasInvokeForCliForTest(
                    "snapshot",
                    ["--node", "node-cli", "--format", "png", "--json"]
                )
                @Expect(response.ok, true)
                let result = response.result.asObject()
                let artifact = result.get("artifact").getOrThrow().asObject()
                let path = canvasTestString(artifact, "path")
                @Expect(canvasTestString(artifact, "format"), "png")
                @Expect(path.startsWith(root.toString()), true)
                @Expect(exists(Path(path)), true)
            } finally {
                debugSetGatewayNodesCanvasCliRunnerForTest(None<(String, JsonObject) -> GatewayRpcResponse>)
                debugSetGatewayCanvasToolArtifactRootForTest(None<Path>)
            }
        })
    }

    @TestCase
    public func nodesCanvasCliOfflineReturnsStructuredError(): Unit {
        debugSetGatewayNodesCanvasCliRunnerForTest(Some({ method: String, params: JsonObject =>
            @Expect(method, "node.invoke")
            @Expect(canvasTestString(params, "nodeId"), "missing-node")
            @Expect(canvasTestString(params, "command"), "canvas.present")
            GatewayRpcResponse(false, method, error: "Node is offline.", errorCode: "unavailable")
        }))
        try {
            let response = gatewayNodesCanvasInvokeForCliForTest(
                "present",
                ["--node", "missing-node", "--url", "http://127.0.0.1:18793/__metis__/canvas/"]
            )
            @Expect(response.ok, false)
            @Expect(response.errorCode, "unavailable")
            @Expect(response.error.contains("offline"), true)
        } finally {
            debugSetGatewayNodesCanvasCliRunnerForTest(None<(String, JsonObject) -> GatewayRpcResponse>)
        }
    }
}
