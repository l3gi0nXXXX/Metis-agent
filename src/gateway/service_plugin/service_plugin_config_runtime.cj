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

    public init(pluginId: String, ok: Bool, status: String, errorKind!: String = "", diagnostic!: String = "") {
        this.pluginId = pluginId.trimAscii()
        this.ok = ok
        this.status = status.trimAscii()
        this.errorKind = errorKind.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
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
        let manifestPath = plugin.manifestPath.trimAscii()
        if (manifestPath.isEmpty()) {
            return ConfiguredServicePluginStatus(wanted, true, "configured")
        }
        if (!exists(Path(manifestPath))) {
            return ConfiguredServicePluginStatus(wanted, false, "degraded", errorKind: "manifest_missing", diagnostic: "service plugin manifest missing")
        }
        let manifest = loadServicePluginManifest(manifestPath)
        if (!manifest.ok) {
            return ConfiguredServicePluginStatus(wanted, false, "degraded", errorKind: manifest.errorKind, diagnostic: manifest.status)
        }
        return ConfiguredServicePluginStatus(wanted, true, "configured")
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
                configRef: ServicePluginConfigRef(configPath: plugin.configRef),
                enabled: plugin.enabled,
                grants: plugin.grants
            )
        )
        servicePluginConfigLog(
            if (result.ok) { "service_plugin.registered" } else { "service_plugin.degraded" },
            pluginId,
            result.status,
            errorKind: if (result.ok) { "" } else { result.status }
        )
    }
}
