package metis.gateway.service_plugin

import metis.core.config.{GatewayServicePluginUserSettings, GatewayUserSettings}

import std.fs.{File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func servicePluginConfigRuntimeTestManifest(): String {
    "{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"gitcode-monitor\"},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"gitcode.monitor.status\",\"kind\":\"controlAction\"},{\"capabilityId\":\"gitcode.monitor.scan_once\",\"kind\":\"controlAction\"}]}"
}

private func servicePluginConfigRuntimeTempPath(label: String): Path {
    Path("/tmp/metis-service-plugin-config-runtime-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json")
}

@Test
public class ServicePluginConfigRuntimeTest {
    @TestCase
    public func registerConfiguredServicePluginsLoadsManifestAndRegistersCapabilities(): Unit {
        resetServicePluginHostForTest()
        let manifestPath = servicePluginConfigRuntimeTempPath("valid")
        File.writeTo(manifestPath, servicePluginConfigRuntimeTestManifest().toArray())
        try {
            var plugin = GatewayServicePluginUserSettings()
            plugin.pluginId = "gitcode-monitor"
            plugin.manifestPath = manifestPath.toString()
            plugin.grants = ["host.agent.invoke"]
            var user = GatewayUserSettings()
            user.servicePlugins = [plugin]

            registerConfiguredServicePlugins(user)

            let rows = listServicePlugins()
            @Expect(rows.size, 1)
            @Expect(rows[0].serviceId, "gitcode-monitor")
            @Expect(resolveCapabilityRoute("gitcode.monitor.status", CapabilityCaller()).ok, true)
            let status = servicePluginConfiguredStatusForUser(user, "gitcode-monitor")
            @Expect(status.ok, true)
            @Expect(status.status, "configured")
        } finally {
            resetServicePluginHostForTest()
            try { remove(manifestPath, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func configuredStatusReportsMissingManifestWithoutRegisteringPlugin(): Unit {
        resetServicePluginHostForTest()
        let manifestPath = servicePluginConfigRuntimeTempPath("missing")
        try { remove(manifestPath, recursive: true) } catch (_: Exception) { () }
        var plugin = GatewayServicePluginUserSettings()
        plugin.pluginId = "gitcode-monitor"
        plugin.manifestPath = manifestPath.toString()
        var user = GatewayUserSettings()
        user.servicePlugins = [plugin]

        registerConfiguredServicePlugins(user)

        let status = servicePluginConfiguredStatusForUser(user, "gitcode-monitor")
        @Expect(status.ok, false)
        @Expect(status.status, "degraded")
        @Expect(status.errorKind, "manifest_missing")
        @Expect(listServicePlugins().size, 0)
        resetServicePluginHostForTest()
    }
}
