package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.GatewayUserSettings
import metis.gateway.config.gatewayBuiltinAdapterRegistrationProfiles
import metis.gateway.core.gatewayChannelRuntimeSnapshot
import metis.gateway.model.GatewayConfig

import std.collection.{HashMap, HashSet}
import std.convert.Parsable
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

private func gatewayRuntimeJsonObject(value: JsonValue): JsonObject {
    try { value.asObject() } catch (_e: Exception) { JsonObject() }
}

private func gatewayRuntimeJsonArray(value: JsonValue): JsonArray {
    try { value.asArray() } catch (_e: Exception) { JsonArray([]) }
}

private func gatewayRuntimeString(obj: JsonObject, key: String, defaultValue!: String = ""): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_e: Exception) { defaultValue }
        case None => defaultValue
    }
}

private func gatewayRuntimeBool(obj: JsonObject, key: String, defaultValue!: Bool = false): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { defaultValue }
        case None => defaultValue
    }
}

private func gatewayRuntimeInt(obj: JsonObject, key: String, defaultValue!: Int64 = 0): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_e: Exception) { defaultValue }
        case None => defaultValue
    }
}

private func gatewayRuntimeSafeDiagnosticText(raw: String): String {
    var text = raw.trimAscii().replace("\n", " ").replace("\r", " ").replace("\t", " ")
    if (text.isEmpty()) {
        return ""
    }
    let lower = text.toAsciiLower()
    if (
        lower.contains("authorization") ||
        lower.contains("bearer ") ||
        lower.contains("secret") ||
        lower.contains("token") ||
        lower.contains("password") ||
        lower.contains("api_key") ||
        lower.contains("apikey") ||
        lower.contains("api key") ||
        lower.contains("access_token")
    ) {
        return "[redacted]"
    }
    if (text.size > 240) {
        return text[0..240] + "..."
    }
    text
}

private func gatewayRuntimeAccountKey(channelId: String, accountId: String): String {
    "${channelId.trimAscii().toAsciiLower()}:${accountId.trimAscii()}"
}

private func gatewayRuntimeActionForReason(channelId: String, reason: String): String {
    if (reason == "configured-account-failed") {
        return "reload-channel:${channelId}"
    }
    if (reason == "configured-account-not-started") {
        return "reload-channel:${channelId}"
    }
    if (reason == "stale-runtime-account") {
        return "reload-channel:${channelId}"
    }
    if (reason == "sidecar-start-timeout") {
        return "check-sidecar-deps"
    }
    if (reason == "credential") {
        return "check-credentials"
    }
    "restart-gateway"
}

private func gatewayRuntimeAccountDiagnostic(row: JsonObject, reason: String): JsonObject {
    let channelId = gatewayRuntimeString(row, "channelId").trimAscii().toAsciiLower()
    let out = JsonObject()
    out.put("channelId", JsonString(channelId))
    out.put("accountId", JsonString(gatewayRuntimeString(row, "accountId").trimAscii()))
    out.put("configured", gatewayRuntimeBool(row, "configured", defaultValue: true).toJsonValue())
    out.put("enabled", gatewayRuntimeBool(row, "enabled", defaultValue: true).toJsonValue())
    out.put("running", gatewayRuntimeBool(row, "running").toJsonValue())
    out.put("connected", gatewayRuntimeBool(row, "connected", defaultValue: gatewayRuntimeBool(row, "running")).toJsonValue())
    out.put("lifecycleState", JsonString(gatewayRuntimeString(row, "lifecycleState", defaultValue: "registered")))
    out.put("phase", JsonString(gatewayRuntimeString(row, "phase", defaultValue: "registered")))
    out.put("taskState", JsonString(gatewayRuntimeString(row, "taskState", defaultValue: "idle")))
    out.put("lastError", JsonString(gatewayRuntimeSafeDiagnosticText(gatewayRuntimeString(row, "lastError"))))
    out.put("errorKind", JsonString(gatewayRuntimeString(row, "errorKind", defaultValue: gatewayRuntimeReasonToErrorKind(reason, row))))
    out.put("restartCount", gatewayRuntimeInt(row, "restartCount").toJsonValue())
    out.put("failureCount", gatewayRuntimeInt(row, "failureCount").toJsonValue())
    out.put("lastStartAtMs", gatewayRuntimeInt(row, "lastStartAtMs").toJsonValue())
    out.put("lastStopAtMs", gatewayRuntimeInt(row, "lastStopAtMs").toJsonValue())
    out.put("reason", JsonString(reason))
    out.put("suggestedAction", JsonString(gatewayRuntimeActionForReason(channelId, reason)))
    out
}

private func gatewayRuntimeReasonToErrorKind(reason: String, row: JsonObject): String {
    let existing = gatewayRuntimeString(row, "errorKind")
    if (!existing.isEmpty()) {
        return existing
    }
    let err = gatewayRuntimeString(row, "lastError").toAsciiLower()
    if (err.contains("monitor-host-timeout") || err.contains("sidecar")) {
        return "sidecar"
    }
    if (err.contains("credential") || err.contains("appsecret") || err.contains("app secret")) {
        return "credential"
    }
    if (reason == "configured-account-not-started") {
        return "not_started"
    }
    if (reason == "stale-runtime-account") {
        return "stale"
    }
    reason
}

private func gatewayRuntimeConfiguredAccounts(user: GatewayUserSettings): JsonArray {
    let out = JsonArray([])
    let profiles = gatewayBuiltinAdapterRegistrationProfiles(user, user.channelHealthCheckMinutes > 0)
    for (profile in profiles) {
        if (!profile.enabled || !profile.configured) {
            continue
        }
        let row = JsonObject()
        row.put("channelId", JsonString(profile.channelId))
        row.put("accountId", JsonString(profile.accountId))
        row.put("pluginId", JsonString(profile.pluginId))
        row.put("origin", JsonString(profile.origin))
        row.put("runtimeKind", JsonString(profile.runtimeKind))
        row.put("compatibilityMode", JsonString(profile.compatibilityMode))
        row.put("label", JsonString(profile.label))
        row.put("detailLabel", JsonString(profile.detailLabel))
        row.put("enabled", profile.enabled.toJsonValue())
        row.put("configured", profile.configured.toJsonValue())
        row.put("healthMonitorEnabled", profile.healthMonitorEnabled.toJsonValue())
        out.add(row)
    }
    out
}

private func gatewayRuntimeSnapshotAccounts(channelRuntime: JsonObject): JsonArray {
    match (channelRuntime.get("accounts")) {
        case Some(v) => gatewayRuntimeJsonArray(v)
        case None => JsonArray([])
    }
}

private func gatewayRuntimeIndexAccounts(accounts: JsonArray): HashMap<String, JsonObject> {
    let index = HashMap<String, JsonObject>()
    for (i in 0..accounts.size()) {
        let row = try { accounts[i].asObject() } catch (_e: Exception) { JsonObject() }
        let key = gatewayRuntimeAccountKey(gatewayRuntimeString(row, "channelId"), gatewayRuntimeString(row, "accountId"))
        if (key != ":") {
            index[key] = row
        }
    }
    index
}

private func gatewayRuntimeAccountIsActive(row: JsonObject): Bool {
    let state = gatewayRuntimeString(row, "lifecycleState").trimAscii()
    gatewayRuntimeBool(row, "running") || state == "starting" || state == "backoff"
}

private func gatewayRuntimeAccountProblemReason(row: JsonObject, configured: Bool): String {
    let state = gatewayRuntimeString(row, "lifecycleState").trimAscii()
    if (state == "failed") {
        let err = gatewayRuntimeString(row, "lastError").toAsciiLower()
        if (err.contains("monitor-host-timeout") || err.contains("sidecar")) {
            return "sidecar-start-timeout"
        }
        if (err.contains("credential") || err.contains("appsecret") || err.contains("app secret")) {
            return "credential"
        }
        return if (configured) { "configured-account-failed" } else { "stale-runtime-account" }
    }
    if (state == "starting") {
        return "channel-starting"
    }
    if (state == "backoff") {
        return "channel-backoff"
    }
    ""
}

public func gatewayRuntimeConfigDriftSnapshot(user: GatewayUserSettings, channelRuntime!: JsonObject = gatewayChannelRuntimeSnapshot()): JsonObject {
    let configuredAccounts = gatewayRuntimeConfiguredAccounts(user)
    let runtimeAccounts = gatewayRuntimeSnapshotAccounts(channelRuntime)
    let configuredIndex = gatewayRuntimeIndexAccounts(configuredAccounts)
    let runtimeIndex = gatewayRuntimeIndexAccounts(runtimeAccounts)
    let configuredKeys = HashSet<String>()
    let runtimeKeys = HashSet<String>()

    let runningAccounts = JsonArray([])
    let staleRunningAccounts = JsonArray([])
    let notStartedConfiguredAccounts = JsonArray([])
    let failedConfiguredAccounts = JsonArray([])
    let problemAccounts = JsonArray([])

    for (i in 0..configuredAccounts.size()) {
        let row = try { configuredAccounts[i].asObject() } catch (_e: Exception) { JsonObject() }
        let key = gatewayRuntimeAccountKey(gatewayRuntimeString(row, "channelId"), gatewayRuntimeString(row, "accountId"))
        if (key != ":") {
            configuredKeys.add(key)
        }
    }
    for (i in 0..runtimeAccounts.size()) {
        let row = try { runtimeAccounts[i].asObject() } catch (_e: Exception) { JsonObject() }
        if (!gatewayRuntimeBool(row, "enabled", defaultValue: true) || !gatewayRuntimeBool(row, "configured", defaultValue: true)) {
            continue
        }
        let key = gatewayRuntimeAccountKey(gatewayRuntimeString(row, "channelId"), gatewayRuntimeString(row, "accountId"))
        if (key != ":") {
            runtimeKeys.add(key)
        }
        if (gatewayRuntimeAccountIsActive(row)) {
            runningAccounts.add(gatewayRuntimeAccountDiagnostic(row, "runtime-account-active"))
        }
        let configured = configuredIndex.get(key).isSome()
        if (!configured && gatewayRuntimeAccountIsActive(row)) {
            let diag = gatewayRuntimeAccountDiagnostic(row, "stale-runtime-account")
            staleRunningAccounts.add(diag)
            problemAccounts.add(diag)
        }
        let problemReason = gatewayRuntimeAccountProblemReason(row, configured)
        if (!problemReason.isEmpty()) {
            let diag = gatewayRuntimeAccountDiagnostic(row, problemReason)
            if (configured && gatewayRuntimeString(row, "lifecycleState") == "failed") {
                failedConfiguredAccounts.add(diag)
            }
            problemAccounts.add(diag)
        }
    }
    for (i in 0..configuredAccounts.size()) {
        let row = try { configuredAccounts[i].asObject() } catch (_e: Exception) { JsonObject() }
        let key = gatewayRuntimeAccountKey(gatewayRuntimeString(row, "channelId"), gatewayRuntimeString(row, "accountId"))
        if (!runtimeIndex.get(key).isSome()) {
            let diag = gatewayRuntimeAccountDiagnostic(row, "configured-account-not-started")
            notStartedConfiguredAccounts.add(diag)
            problemAccounts.add(diag)
        }
    }

    let drift = JsonObject()
    drift.put("configuredAccounts", configuredAccounts)
    drift.put("runningAccounts", runningAccounts)
    drift.put("staleRunningAccounts", staleRunningAccounts)
    drift.put("notStartedConfiguredAccounts", notStartedConfiguredAccounts)
    drift.put("failedConfiguredAccounts", failedConfiguredAccounts)
    drift.put("problemAccounts", problemAccounts)
    drift.put("configuredCount", Int64(configuredAccounts.size()).toJsonValue())
    drift.put("runningCount", Int64(runningAccounts.size()).toJsonValue())
    drift.put("staleRunningCount", Int64(staleRunningAccounts.size()).toJsonValue())
    drift.put("notStartedConfiguredCount", Int64(notStartedConfiguredAccounts.size()).toJsonValue())
    drift.put("failedConfiguredCount", Int64(failedConfiguredAccounts.size()).toJsonValue())
    drift.put("problemCount", Int64(problemAccounts.size()).toJsonValue())
    drift.put("hasDrift", (staleRunningAccounts.size() > 0 || notStartedConfiguredAccounts.size() > 0).toJsonValue())
    drift
}

private func gatewayRuntimeReadinessStatus(endpointReady: Bool, user: GatewayUserSettings, failedCount: Int64, startingCount: Int64, backoffCount: Int64, notStartedCount: Int64, staleCount: Int64): String {
    if (!endpointReady) {
        return "not-ready"
    }
    if (!user.enabled) {
        return "not-ready"
    }
    if (failedCount > 0 || backoffCount > 0 || notStartedCount > 0 || staleCount > 0) {
        return "degraded"
    }
    if (startingCount > 0) {
        return "starting"
    }
    "ready"
}

private func gatewayRuntimeReadinessReason(status: String, user: GatewayUserSettings, hasEnabledChannel: Bool): String {
    if (status == "ready") {
        return "ok"
    }
    if (!user.enabled) {
        return "gateway-disabled"
    }
    if (!hasEnabledChannel) {
        return "no-enabled-channel"
    }
    if (status == "starting") {
        return "channel-runtime-starting"
    }
    if (status == "degraded") {
        return "channel-runtime-degraded"
    }
    "http-disabled"
}

public func gatewayBuildRuntimeReadinessSnapshot(
    cfg: GatewayConfig,
    user: GatewayUserSettings,
    channelRuntime!: JsonObject = gatewayChannelRuntimeSnapshot()
): JsonObject {
    let endpointReady = gatewayHttpAnyEndpointEnabled(cfg)
    let hasEnabledChannel = gatewayHasAnyEnabledChannel(user)
    let drift = gatewayRuntimeConfigDriftSnapshot(user, channelRuntime: channelRuntime)
    let problems = gatewayRuntimeJsonArray(drift.get("problemAccounts") ?? JsonArray([]))
    var failedCount: Int64 = 0
    var startingCount: Int64 = 0
    var backoffCount: Int64 = 0
    for (i in 0..problems.size()) {
        let row = try { problems[i].asObject() } catch (_e: Exception) { JsonObject() }
        let state = gatewayRuntimeString(row, "lifecycleState")
        if (state == "failed") {
            failedCount += 1
        } else if (state == "starting") {
            startingCount += 1
        } else if (state == "backoff") {
            backoffCount += 1
        }
    }
    let notStartedCount = gatewayRuntimeInt(drift, "notStartedConfiguredCount")
    let staleCount = gatewayRuntimeInt(drift, "staleRunningCount")
    let status = gatewayRuntimeReadinessStatus(endpointReady, user, failedCount, startingCount, backoffCount, notStartedCount, staleCount)
    let ready = status == "ready"
    let out = JsonObject()
    out.put("ready", ready.toJsonValue())
    out.put("ok", ready.toJsonValue())
    out.put("status", JsonString(status))
    out.put("degraded", (status == "degraded").toJsonValue())
    out.put("reason", JsonString(gatewayRuntimeReadinessReason(status, user, hasEnabledChannel)))
    out.put("masterEnabled", user.enabled.toJsonValue())
    out.put("hasEnabledChannel", hasEnabledChannel.toJsonValue())
    out.put("endpointReady", endpointReady.toJsonValue())
    out.put("failedCount", failedCount.toJsonValue())
    out.put("startingCount", startingCount.toJsonValue())
    out.put("backoffCount", backoffCount.toJsonValue())
    out.put("staleRunningCount", staleCount.toJsonValue())
    out.put("notStartedConfiguredCount", notStartedCount.toJsonValue())
    out.put("accounts", problems)
    out.put("runtimeConfigDrift", drift)
    return out
}
