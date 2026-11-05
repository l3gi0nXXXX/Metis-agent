package metis.gateway.service_plugin

import magic.config.Config
import metis.core.config.{CliConfig, CliSettingManager, GatewayServicePluginUserSettings, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.logging.gatewayLoggingResetForTest

import std.collection.ArrayList
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, FileInfo, Path, canonicalize, exists, remove}
import std.time.{DateTime, MonoTime}
import std.env.getProcessId
import metis.process.{managedStdioBroker, resetManagedStdioBrokerForTest}
import std.core.Duration
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

private func servicePluginConfigRuntimeRestoreEnv(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => setVariable(name, v)
        case None => removeVariable(name)
    }
}

private func servicePluginConfigRuntimeResetCaches(): Unit {
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func withServicePluginConfigRuntimeTestHome<T>(label: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds()
        let homeName = "metis-service-plugin-config-runtime-home-${label}-${stamp}"
        let home = Path("/private/tmp").join(homeName)
        let oldLogFile = Config.logFile
        let oldHome = getVariable("METIS_HOME")
        let targetIsSymlink = try { FileInfo(home).isSymbolicLink() } catch (_: Exception) { false }
        let homeIdentityOk = stamp > 0 && home.toString() == "/private/tmp/${homeName}" &&
            home.parent.toString() == "/private/tmp" && canonicalize(home.parent).toString() == "/private/tmp" &&
            home.fileName == homeName && !exists(home) && !targetIsSymlink
        @Expect(homeIdentityOk, true)
        if (!homeIdentityOk) { throw Exception("service_plugin_config_runtime_home_identity_invalid") }
        var homeCreated = false
        try {
            Directory.create(home, recursive: false)
            homeCreated = true
            setVariable("METIS_HOME", home.toString())
            servicePluginConfigRuntimeResetCaches()
            return block()
        } finally {
            try {
                resetServicePluginHostForTest()
            } finally {
                try {
                    servicePluginConfigRuntimeRestoreEnv("METIS_HOME", oldHome)
                    match (oldHome) {
                        case Some(value) =>
                            match (getVariable("METIS_HOME")) {
                                case Some(actual) =>
                                    @Expect(actual, value)
                                    if (actual != value) { throw Exception("service_plugin_config_runtime_home_restore_mismatch") }
                                case None => throw Exception("service_plugin_config_runtime_home_restore_missing")
                            }
                        case None =>
                            let restored = getVariable("METIS_HOME")
                            @Expect(restored.isNone(), true)
                            if (restored.isSome()) { throw Exception("service_plugin_config_runtime_home_restore_not_absent") }
                    }
                } finally {
                    try {
                        servicePluginConfigRuntimeResetCaches()
                    } finally {
                        try {
                            gatewayLoggingResetForTest()
                        } finally {
                            try {
                                Config.logFile = oldLogFile
                                @Expect(Config.logFile, oldLogFile)
                            } finally {
                                if (homeCreated) {
                                    let homeInfo = FileInfo(home)
                                    let removable = homeInfo.isDirectory() && !homeInfo.isSymbolicLink() &&
                                        canonicalize(home).toString() == home.normalize().toString()
                                    @Expect(removable, true)
                                    if (!removable) { throw Exception("service_plugin_config_runtime_home_cleanup_identity_invalid") }
                                    remove(home, recursive: true)
                                    let remains = exists(home) || try { FileInfo(home).isSymbolicLink() } catch (_: Exception) { false }
                                    @Expect(remains, false)
                                    if (remains) { throw Exception("service_plugin_config_runtime_home_cleanup_failed") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Test
public class ServicePluginConfigRuntimeTest {

    @TestCase
    public func registerConfiguredServicePluginsCanDeferRealAutostart(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let home = Directory.createTemp("/private/tmp")
            let oldHome = getVariable("METIS_HOME")
            let oldLog = Config.logFile
            let errors = ArrayList<Exception>()
            let attempt = { action: () -> Unit => try { action() } catch (error: Exception) { errors.add(error) } }
            let check = { value: Bool =>
                @Expect(value, true)
                if (!value) { throw Exception("startup_deferred_contract_failed") }
            }
            var bodyError = None<Exception>
            var formal = false
            try {
                File.writeTo(home.join("startup-dispatch.owner"),
                    "metis-startup-dispatch-v1\ntestPid:${getProcessId()}\nname:config-deferred\n".toArray())
                setVariable("METIS_HOME", home.toString())
                servicePluginConfigRuntimeResetCaches()
                resetServicePluginHostForTest()
                check(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok)
                let launched = home.join("launched")
                let argument = home.join("argument")
                let expectedArgument = "参数中文😀"
                let script = "printf 'launch\\n' >> '${launched.toString()}'; printf '%s' \"$1\" > '${argument.toString()}'; " +
                    "printf '%s\\n' '{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}'; " +
                    "while IFS= read -r request; do exit 0; done"
                let manifest = home.join("plugin.json")
                File.writeTo(manifest, servicePluginConfigRuntimeStdioManifest("/bin/sh", ["-c", script, "startup", expectedArgument]).toArray())
                var plugin = GatewayServicePluginUserSettings()
                plugin.pluginId = "gitcode-monitor"
                plugin.manifestPath = manifest.toString()
                plugin.autostart = true
                plugin.startupTimeoutMs = 1000
                var user = GatewayUserSettings()
                user.servicePlugins = [plugin]
                let baseline = managedStdioBroker().snapshot()
                registerConfiguredServicePlugins(user, autostart: false)
                let deferred = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                let unlaunched = managedStdioBroker().snapshot()
                check(deferred.status == "registered" && deferred.pid == 0 &&
                    deferred.capabilityIds.contains("gitcode.monitor.status") && !exists(launched))
                check(unlaunched.ownerCount == 0 && unlaunched.brokerPid == 0 && unlaunched.generation == baseline.generation)
                let observationDeadline = MonoTime.now() + Duration.second * 5
                registerConfiguredServicePlugins(user)
                let active = getServicePluginSnapshot("gitcode-monitor").getOrThrow()
                check(active.status == "running" && active.pid > 1 && MonoTime.now() < observationDeadline)
                registerConfiguredServicePlugins(user)
                let markers = try { String.fromUtf8(File.readFrom(launched)) }
                    catch (_: Exception) { throw Exception("startup_marker_invalid_encoding") }
                let observedArgument = try { String.fromUtf8(File.readFrom(argument)) }
                    catch (_: Exception) { throw Exception("startup_argument_invalid_encoding") }
                check(markers == "launch\n" && observedArgument == expectedArgument)
                let remaining = (observationDeadline - MonoTime.now()).toMilliseconds()
                check(remaining > 0)
                check(stopServicePlugin("gitcode-monitor", reason: "startup-deferred", timeoutMillis: min(2000, remaining)).ok)
                let resourceDeadline = MonoTime.now() + Duration.second * 2
                check(servicePluginCleanupPendingCountForTest() == 0)
                let resourceRemaining = (resourceDeadline - MonoTime.now()).toMilliseconds()
                check(resourceRemaining > 0)
                check(resetManagedStdioBrokerForTest(timeoutMs: resourceRemaining).ok)
                let settled = managedStdioBroker().snapshot()
                check(!settled.running && settled.ownerCount == 0 && settled.readerCount == 0 && settled.dispatcherCount == 0)
                formal = true
            } catch (error: Exception) { bodyError = Some(error) } finally {
                let cleanupDeadline = MonoTime.now() + Duration.second * 3
                attempt({ => resetServicePluginHostForTest() })
                attempt({ =>
                    let remaining = (cleanupDeadline - MonoTime.now()).toMilliseconds()
                    if (remaining <= 0 || !resetManagedStdioBrokerForTest(timeoutMs: remaining).ok) {
                        throw Exception("startup_deferred_cleanup_pending")
                    }
                })
                attempt({ => servicePluginConfigRuntimeRestoreEnv("METIS_HOME", oldHome) })
                attempt({ => servicePluginConfigRuntimeResetCaches() })
                attempt({ => gatewayLoggingResetForTest() })
                attempt({ => Config.logFile = oldLog })
                if (MonoTime.now() > cleanupDeadline) { errors.add(Exception("startup_deferred_cleanup_deadline")) }
                if (formal && errors.isEmpty()) { attempt({ => remove(home, recursive: true) }) }
                else { let savedFormal = formal; attempt({ => println("STARTUP-DISPATCH retained=${home.fileName};formal=${savedFormal}") }) }
            }
            match (bodyError) { case Some(error) => throw error case None => () }
            if (!errors.isEmpty()) { throw errors[0] }
        }
    }
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
