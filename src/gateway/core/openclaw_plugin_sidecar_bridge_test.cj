package metis.gateway.core

import metis.core.config.GatewayUserSettings
import metis.process.managedStdioResolveBrokerScriptPath
import std.fs.Path
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

private func p3ShellOpenClawFakeCommandPath(): String {
    Path(managedStdioResolveBrokerScriptPath()).parent.join("gateway-stdio-fake-command-child.mjs").toString()
}

private func p3ShellOpenClawString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try {
            value.asString().getValue()
        } catch (_: Exception) {
            ""
        }
        case None => ""
    }
}

@Test
public class OpenClawPluginSidecarBridgeTest {
    @TestCase
    public func p3P5ConfiguredSidecarHealthUsesFormalTimedShellPath(): Unit {
        var user = GatewayUserSettings()
        let sidecar = JsonObject()
        sidecar.put("enabled", JsonBool(true))
        sidecar.put("nodeCommand", JsonString("node"))
        sidecar.put("scriptPath", JsonString(p3ShellOpenClawFakeCommandPath()))
        sidecar.put("timeoutMs", JsonInt(2000))
        let extra = JsonObject()
        extra.put("openclawPluginCompatibility", sidecar)
        user.channelsExtra = Some(extra)

        let result = gatewayOpenClawPluginSidecarHealth(user)

        @Expect(p3ShellOpenClawString(result, "status"), "ready")
        @Expect(p3ShellOpenClawString(result, "text"), "中文🙂sidecar")
        @Expect(p3ShellOpenClawString(result, "method"), "lifecycle.health")
    }
}
