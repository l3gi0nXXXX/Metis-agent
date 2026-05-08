package metis.gateway.runtime

import metis.core.config.{CliConfig, GatewayUserSettings}
import metis.gateway.config.GatewayChannelPluginRegistry
import metis.gateway.openclaw_http.OpenClawHttpRouteRegistry

import magic.jsonable.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private func gatewayOpenClawCompatLifecycleSettings(): GatewayUserSettings {
    var user = GatewayUserSettings()
    let runtime = JsonObject()
    runtime.put("enabled", true.toJsonValue())
    runtime.put("nodeCommand", JsonString("node"))
    runtime.put("hostScript", JsonString(CliConfig.cwd.join("scripts").join("openclaw-compat-host.mjs").toString()))
    let roots = JsonArray([])
    roots.add(JsonString(CliConfig.cwd.join("scripts").join("fixtures").join("openclaw-compat-host").join("raw-register").toString()))
    runtime.put("pluginRoots", roots)
    runtime.put("timeoutMs", 5000.toJsonValue())
    let secrets = JsonObject()
    secrets.put("OPENCLAW_TOKEN", JsonString("super-secret-token"))
    runtime.put("secrets", secrets)
    let permissions = JsonObject()
    permissions.put("media", true.toJsonValue())
    permissions.put("reply", true.toJsonValue())
    permissions.put("conversation", true.toJsonValue())
    permissions.put("thread", true.toJsonValue())
    permissions.put("process", false.toJsonValue())
    runtime.put("permissions", permissions)
    let extra = JsonObject()
    extra.put("openclawRuntime", runtime)
    user.channelsExtra = Some(extra)
    user
}

@Test
public class GatewayOpenClawCompatLifecycleTest {
    @TestCase
    public func lifecycleStartSyncsHostCapabilitiesIntoGatewayRegistries(): Unit {
        OpenClawHttpRouteRegistry.clearForTest()
        GatewayChannelPluginRegistry.removeForTest("raw-register-openclaw-fixture")
        let user = gatewayOpenClawCompatLifecycleSettings()

        let started = gatewayOpenClawCompatHostStart(user)
        let stopped = gatewayOpenClawCompatHostStop(user)
        let channelRegistered = GatewayChannelPluginRegistry.getById("raw-register-openclaw-fixture").isSome()
        let httpRouteRegistered = OpenClawHttpRouteRegistry.find("GET", "/fixture").isSome()
        GatewayChannelPluginRegistry.removeForTest("raw-register-openclaw-fixture")
        OpenClawHttpRouteRegistry.clearForTest()

        @Expect(started.get("state").getOrThrow().asString().getValue(), "running")
        @Expect(started.get("registrySync").getOrThrow().asObject().get("channels").getOrThrow().asInt().getValue(), 1)
        @Expect(started.get("registrySync").getOrThrow().asObject().get("httpRoutes").getOrThrow().asInt().getValue(), 1)
        @Expect(channelRegistered, true)
        @Expect(httpRouteRegistered, true)
        @Expect(stopped.get("state").getOrThrow().asString().getValue(), "stopped")
    }
}
