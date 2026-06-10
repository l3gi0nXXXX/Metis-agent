package metis.gateway.service_plugin

import metis.core.config.{CliConfig, CliSettingManager, GatewayServicePluginUserSettings, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonString

private func servicePluginConfigRuntimeTestManifest(): String {
    "{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"gitcode-monitor\"},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"gitcode.monitor.status\",\"kind\":\"controlAction\"},{\"capabilityId\":\"gitcode.monitor.scan_once\",\"kind\":\"controlAction\"}]}"
}

private func servicePluginConfigRuntimeStdioManifest(command: String, args: Array<String>): String {
    let argItems = ArrayList<String>()
    for (arg in args) {
        argItems.add(JsonString(arg).toJsonString())
    }
    "{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":${JsonString(command).toJsonString()},\"args\":[${String.join(argItems.toArray(), delimiter: ",")}]},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"gitcode.monitor.status\",\"kind\":\"controlAction\"}]}"
}

private func servicePluginConfigRuntimeTempPath(label: String): Path {
    Path("/private/tmp/metis-service-plugin-config-runtime-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json")
}

private func servicePluginConfigRuntimeTempHome(label: String): Path {
    Path("/private/tmp/metis-service-plugin-config-runtime-home-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
}

private func servicePluginConfigRuntimeRestoreEnv(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => setVariable(name, v)
        case None => setVariable(name, "")
    }
}

private func servicePluginConfigRuntimeResetCaches(): Unit {
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func withServicePluginConfigRuntimeTestHome<T>(label: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = servicePluginConfigRuntimeTempHome(label)
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        servicePluginConfigRuntimeResetCaches()
        try {
            return block()
        } finally {
            resetServicePluginHostForTest()
            servicePluginConfigRuntimeRestoreEnv("METIS_HOME", oldHome)
            servicePluginConfigRuntimeResetCaches()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class ServicePluginConfigRuntimeTest {
    @TestCase
    public func registerConfiguredServicePluginsLoadsManifestAndRegistersCapabilities(): Unit {
        withServicePluginConfigRuntimeTestHome("valid", { =>
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
        })
    }

    @TestCase
    public func registerConfiguredServicePluginsKeepsLegacyAutostartDisabled(): Unit {
        withServicePluginConfigRuntimeTestHome("legacy-autostart-disabled", { =>
            resetServicePluginHostForTest()
            let manifestPath = servicePluginConfigRuntimeTempPath("legacy-autostart-disabled")
            let script = "printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}'; while read ignored; do :; done"
            File.writeTo(manifestPath, servicePluginConfigRuntimeStdioManifest("/bin/sh", ["-lc", script]).toArray())
            try {
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gitcode-monitor"
                plugin.manifestPath = manifestPath.toString()
                var user = GatewayUserSettings()
                user.servicePlugins = [plugin]

                registerConfiguredServicePlugins(user)

                @Expect(queryServicePluginStatus("gitcode-monitor").status, "registered")
                @Expect(queryServicePluginStatus("gitcode-monitor").running, false)
            } finally {
                resetServicePluginHostForTest()
                try { remove(manifestPath, recursive: true) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func autostartServicePluginStartsAfterRegistration(): Unit {
        withServicePluginConfigRuntimeTestHome("autostart-ready", { =>
            resetServicePluginHostForTest()
            let manifestPath = servicePluginConfigRuntimeTempPath("autostart-ready")
            let script = "printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}'; while read ignored; do :; done"
            File.writeTo(manifestPath, servicePluginConfigRuntimeStdioManifest("/bin/sh", ["-lc", script]).toArray())
            try {
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gitcode-monitor"
                plugin.manifestPath = manifestPath.toString()
                plugin.autostart = true
                var user = GatewayUserSettings()
                user.servicePlugins = [plugin]

                registerConfiguredServicePlugins(user)

                @Expect(queryServicePluginStatus("gitcode-monitor").status, "running")
                @Expect(queryServicePluginStatus("gitcode-monitor").running, true)
            } finally {
                resetServicePluginHostForTest()
                try { remove(manifestPath, recursive: true) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func autostartPreservesCjpmSkipBuildAndInjectsConfigRefIntoRunArgs(): Unit {
        withServicePluginConfigRuntimeTestHome("autostart-args", { =>
            resetServicePluginHostForTest()
            let manifestPath = servicePluginConfigRuntimeTempPath("autostart-args")
            let configPath = servicePluginConfigRuntimeTempPath("config-ref").toString()
            let script = "case \" $* \" in *\" --skip-build \"*) has_skip=1;; *) has_skip=0;; esac; case \" $* \" in *\" --name gitcodemonitor \"*) has_name=1;; *) has_name=0;; esac; case \" $* \" in *\" --config ${configPath} plugin-stdio\"*) has_config=1;; *) has_config=0;; esac; if [ \"$has_skip\" = \"1\" ] && [ \"$has_name\" = \"1\" ] && [ \"$has_config\" = \"1\" ]; then printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}'; while read ignored; do :; done; else printf '%s\\n' 'bad args' >&2; exit 2; fi"
            File.writeTo(manifestPath, servicePluginConfigRuntimeStdioManifest("/bin/sh", ["-lc", script, "cjpm", "run", "--skip-build", "--name", "gitcodemonitor", "--run-args", "plugin-stdio"]).toArray())
            try {
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gitcode-monitor"
                plugin.manifestPath = manifestPath.toString()
                plugin.configRef = configPath
                plugin.autostart = true
                var user = GatewayUserSettings()
                user.servicePlugins = [plugin]

                registerConfiguredServicePlugins(user)

                @Expect(queryServicePluginStatus("gitcode-monitor").status, "running")
            } finally {
                resetServicePluginHostForTest()
                try { remove(manifestPath, recursive: true) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func autostartInitializeFailureDegradesAndContinues(): Unit {
        withServicePluginConfigRuntimeTestHome("autostart-fail-continue", { =>
            resetServicePluginHostForTest()
            let failManifestPath = servicePluginConfigRuntimeTempPath("autostart-fail")
            let readyManifestPath = servicePluginConfigRuntimeTempPath("autostart-continue")
            let failScript = "printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":false,\"status\":\"config_missing\",\"diagnostic\":\"config missing\"}}'"
            let readyScript = "printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor-ready\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}'; while read ignored; do :; done"
            File.writeTo(failManifestPath, servicePluginConfigRuntimeStdioManifest("/bin/sh", ["-lc", failScript]).toArray())
            File.writeTo(readyManifestPath, "{\"schema\":\"metis.servicePlugin.v1\",\"pluginId\":\"gitcode-monitor-ready\",\"kind\":\"service\",\"protocolVersion\":\"1.0\",\"entry\":{\"command\":\"/bin/sh\",\"args\":[\"-lc\",${JsonString(readyScript).toJsonString()}]},\"configSchema\":{\"type\":\"object\"},\"capabilityDeclarations\":[{\"capabilityId\":\"gitcode.monitor.ready_status\",\"kind\":\"controlAction\"}]}".toArray())
            try {
                var first = GatewayServicePluginUserSettings()
                first.pluginId = "gitcode-monitor"
                first.manifestPath = failManifestPath.toString()
                first.autostart = true
                var second = GatewayServicePluginUserSettings()
                second.pluginId = "gitcode-monitor-ready"
                second.manifestPath = readyManifestPath.toString()
                second.autostart = true
                var user = GatewayUserSettings()
                user.servicePlugins = [first, second]

                registerConfiguredServicePlugins(user)

                let failed = queryServicePluginStatus("gitcode-monitor")
                @Expect(failed.status, "degraded")
                @Expect(failed.degradedReason, "initialize_failed")
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        let diagnostic = renderServicePluginDiagnostics(snapshot)
                        @Expect(diagnostic.contains("{"), false)
                    case None => @Expect(true, false)
                }
                @Expect(queryServicePluginStatus("gitcode-monitor-ready").status, "running")
            } finally {
                resetServicePluginHostForTest()
                try { remove(failManifestPath, recursive: true) } catch (_: Exception) { () }
                try { remove(readyManifestPath, recursive: true) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func startupTimeoutIsNormalizedForAutostart(): Unit {
        @Expect(normalizeServicePluginStartupTimeoutMs(0), 10000)
        @Expect(normalizeServicePluginStartupTimeoutMs(-1), 10000)
        @Expect(normalizeServicePluginStartupTimeoutMs(750), 750)
        @Expect(normalizeServicePluginStartupTimeoutMs(90000), 60000)
    }

    @TestCase
    public func unknownRestartPolicyRegistersDegradedDiagnostic(): Unit {
        withServicePluginConfigRuntimeTestHome("restart-policy", { =>
            resetServicePluginHostForTest()
            let manifestPath = servicePluginConfigRuntimeTempPath("restart-policy")
            File.writeTo(manifestPath, servicePluginConfigRuntimeTestManifest().toArray())
            try {
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gitcode-monitor"
                plugin.manifestPath = manifestPath.toString()
                plugin.autostart = true
                plugin.restartPolicy = "always"
                var user = GatewayUserSettings()
                user.servicePlugins = [plugin]

                registerConfiguredServicePlugins(user)

                let status = servicePluginConfiguredStatusForUser(user, "gitcode-monitor")
                @Expect(status.ok, false)
                @Expect(status.status, "degraded")
                @Expect(status.errorKind, "invalid_restart_policy")
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) =>
                        @Expect(snapshot.status, "degraded")
                        @Expect(renderServicePluginDiagnostics(snapshot).contains("invalid_restart_policy"), true)
                    case None => @Expect(true, false)
                }
            } finally {
                resetServicePluginHostForTest()
                try { remove(manifestPath, recursive: true) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func configuredStatusReportsMissingManifestWithoutRegisteringPlugin(): Unit {
        withServicePluginConfigRuntimeTestHome("missing", { =>
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
        })
    }
}
