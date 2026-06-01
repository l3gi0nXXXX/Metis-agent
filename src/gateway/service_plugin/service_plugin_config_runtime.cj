package metis.gateway.service_plugin

import metis.core.config.GatewayUserSettings
import metis.gateway.logging.{MetisLogEvent, metisCreateSubsystemLogger}

import std.fs.{Path, exists}
import stdx.encoding.json.{JsonObject, JsonString}

public class ConfiguredServicePluginStatus {
    public let pluginId: String
    public let ok: Bool
    public let status: String
    public let errorKind: String
    public let diagnostic: String
    public let runtimeStatus: String
    public let lastError: String

    public init(pluginId: String, ok: Bool, status: String, errorKind!: String = "", diagnostic!: String = "", runtimeStatus!: String = "", lastError!: String = "") {
        this.pluginId = pluginId.trimAscii()
        this.ok = ok
        this.status = status.trimAscii()
        this.errorKind = errorKind.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.runtimeStatus = runtimeStatus.trimAscii()
        this.lastError = lastError.trimAscii()
    }
}

private let servicePluginConfigLogger = metisCreateSubsystemLogger("gateway/service_plugin")

private func servicePluginConfigLog(event: String, pluginId: String, status: String, errorKind!: String = ""): Unit {
    let meta = JsonObject()
    meta.put("pluginId", JsonString(pluginId.trimAscii()))
    meta.put("status", JsonString(status.trimAscii()))
    if (!errorKind.trimAscii().isEmpty()) {
        meta.put("errorKind", JsonString(errorKind.trimAscii()))
    }
    servicePluginConfigLogger.info(MetisLogEvent.loggingRaw, event, meta: meta)
}

public func normalizeServicePluginStartupTimeoutMs(value: Int64): Int64 {
    if (value <= 0) {
        return 10000
    }
    if (value > 60000) {
        return 60000
    }
    value
}

private func servicePluginRestartPolicyValid(policy: String): Bool {
    let normalized = policy.trimAscii().toAsciiLower()
    normalized == "never" || normalized == "on-failure"
}

private func servicePluginRuntimeStatus(pluginId: String): (String, String) {
    match (getServicePluginSnapshot(pluginId.trimAscii())) {
        case Some(snapshot) => (snapshot.status, renderServicePluginDiagnostics(snapshot))
        case None => ("missing", "")
    }
}

public func servicePluginConfiguredStatusForUser(user: GatewayUserSettings, pluginId: String): ConfiguredServicePluginStatus {
    let wanted = pluginId.trimAscii()
    if (wanted.isEmpty()) {
        return ConfiguredServicePluginStatus(wanted, false, "missing", errorKind: "plugin_id_empty", diagnostic: "service plugin id is empty")
    }
    for (plugin in user.servicePlugins) {
        if (plugin.pluginId.trimAscii() != wanted) {
            continue
        }
        if (!plugin.enabled) {
            return ConfiguredServicePluginStatus(wanted, false, "disabled", errorKind: "plugin_disabled", diagnostic: "service plugin is disabled")
        }
        if (!servicePluginRestartPolicyValid(plugin.restartPolicy)) {
            let runtime = servicePluginRuntimeStatus(wanted)
            return ConfiguredServicePluginStatus(wanted, false, "degraded", errorKind: "invalid_restart_policy", diagnostic: "service plugin restartPolicy is invalid", runtimeStatus: runtime[0], lastError: runtime[1])
        }
        let manifestPath = plugin.manifestPath.trimAscii()
        if (manifestPath.isEmpty()) {
            let runtime = servicePluginRuntimeStatus(wanted)
            return ConfiguredServicePluginStatus(wanted, true, "configured", runtimeStatus: runtime[0], lastError: runtime[1])
        }
        if (!exists(Path(manifestPath))) {
            return ConfiguredServicePluginStatus(wanted, false, "degraded", errorKind: "manifest_missing", diagnostic: "service plugin manifest missing")
        }
        let manifest = loadServicePluginManifest(manifestPath)
        if (!manifest.ok) {
            return ConfiguredServicePluginStatus(wanted, false, "degraded", errorKind: manifest.errorKind, diagnostic: manifest.status)
        }
        let runtime = servicePluginRuntimeStatus(wanted)
        return ConfiguredServicePluginStatus(wanted, true, "configured", runtimeStatus: runtime[0], lastError: runtime[1])
    }
    ConfiguredServicePluginStatus(wanted, false, "missing", errorKind: "plugin_missing", diagnostic: "service plugin is not configured")
}

public func registerConfiguredServicePlugins(user: GatewayUserSettings): Unit {
    for (plugin in user.servicePlugins) {
        let pluginId = plugin.pluginId.trimAscii()
        if (pluginId.isEmpty()) {
            servicePluginConfigLog("service_plugin.skipped", pluginId, "skipped", errorKind: "plugin_id_empty")
            continue
        }
        if (!plugin.enabled) {
            servicePluginConfigLog("service_plugin.skipped", pluginId, "disabled", errorKind: "plugin_disabled")
            continue
        }
        if (getServicePluginSnapshot(pluginId).isSome()) {
            if (!servicePluginRestartPolicyValid(plugin.restartPolicy)) {
                markServicePluginDegraded(pluginId, "invalid_restart_policy", diagnostic: "service plugin restartPolicy is invalid")
            }
            servicePluginConfigLog("service_plugin.registered", pluginId, "registered")
            continue
        }
        let manifestPath = plugin.manifestPath.trimAscii()
        if (manifestPath.isEmpty()) {
            servicePluginConfigLog("service_plugin.skipped", pluginId, "configured", errorKind: "manifest_not_required")
            continue
        }
        let loaded = loadServicePluginManifest(manifestPath)
        if (!loaded.ok) {
            servicePluginConfigLog("service_plugin.degraded", pluginId, "degraded", errorKind: loaded.errorKind)
            continue
        }
        let result = registerServicePlugin(
            ServicePluginRegistration(
                loaded.manifest,
                configRef: ServicePluginConfigRef(
                    configPath: plugin.configRef,
                    manifestPath: manifestPath,
                    workingDirectory: Path(manifestPath).parent.toString()
                ),
                enabled: plugin.enabled,
                grants: plugin.grants
            )
        )
        if (result.ok && !servicePluginRestartPolicyValid(plugin.restartPolicy)) {
            markServicePluginDegraded(pluginId, "invalid_restart_policy", diagnostic: "service plugin restartPolicy is invalid")
        }
        servicePluginConfigLog(
            if (result.ok) { "service_plugin.registered" } else { "service_plugin.degraded" },
            pluginId,
            result.status,
            errorKind: if (result.ok) { "" } else { result.status }
        )
    }
    startAutostartServicePlugins(user)
}

public func startAutostartServicePlugins(user: GatewayUserSettings): Unit {
    for (plugin in user.servicePlugins) {
        let pluginId = plugin.pluginId.trimAscii()
        if (pluginId.isEmpty() || !plugin.enabled || !plugin.autostart) {
            continue
        }
        if (!servicePluginRestartPolicyValid(plugin.restartPolicy)) {
            markServicePluginDegraded(pluginId, "invalid_restart_policy", diagnostic: "service plugin restartPolicy is invalid")
            servicePluginConfigLog("service_plugin.autostart.degraded", pluginId, "degraded", errorKind: "invalid_restart_policy")
            continue
        }
        let status = servicePluginConfiguredStatusForUser(user, pluginId)
        if (!status.ok) {
            servicePluginConfigLog("service_plugin.autostart.skipped", pluginId, status.status, errorKind: status.errorKind)
            continue
        }
        let started = ensureRegisteredServicePluginStarted(pluginId, startupTimeoutMs: normalizeServicePluginStartupTimeoutMs(plugin.startupTimeoutMs))
        servicePluginConfigLog(
            if (started.ok) { "service_plugin.autostart.running" } else { "service_plugin.autostart.degraded" },
            pluginId,
            started.status,
            errorKind: if (started.ok) { "" } else { started.status }
        )
    }
}
