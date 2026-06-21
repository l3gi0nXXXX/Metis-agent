package metis.gateway.runtime

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.model.GatewayConfig

import std.convert.Parsable
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonObject

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

private func canvasTestConfig(enabled: Bool, root: String): GatewayConfig {
    var user = GatewayUserSettings()
    user.canvas.enabled = enabled
    user.canvas.root = root
    user.canvas.port = 18793
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
}
