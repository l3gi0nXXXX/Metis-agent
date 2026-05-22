package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.GatewayUserSettings
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.model.GatewayConfig

import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private const GATEWAY_PROCESS_IDENTITY_SCHEMA = "metis.gateway.process.v1"
private const GATEWAY_BUILD_FINGERPRINT = "metis-gateway-feishu-sidecar-2026-05-22"

public func gatewayBuildFingerprint(): String {
    GATEWAY_BUILD_FINGERPRINT
}

private func gatewayProcessPidArrayJson(pids: Array<Int64>): JsonArray {
    let arr = JsonArray()
    for (pid in pids) {
        arr.add(pid.toJsonValue())
    }
    arr
}

private func gatewayProcessPidArrayContains(pids: Array<Int64>, pid: Int64): Bool {
    for (item in pids) {
        if (item == pid) {
            return true
        }
    }
    false
}

private func gatewayProcessIdentityStatus(
    lockPid: Option<Int64>,
    lockAlive: Bool,
    listenerPids: Array<Int64>,
    pidMismatch: Bool
): String {
    if (pidMismatch) {
        return "pid-mismatch"
    }
    if (listenerPids.size > 0) {
        return "listening"
    }
    match (lockPid) {
        case Some(_) =>
            if (lockAlive) {
                return "lock-only"
            }
            "stale-lock"
        case None => "not-running"
    }
}

private func gatewayProcessIdentityAdvice(status: String): JsonArray {
    let arr = JsonArray()
    if (status == "pid-mismatch") {
        arr.add(JsonString("Gateway lock PID and listening PID differ; stop the stale Gateway process and restart Gateway after rebuilding Metis."))
    } else if (status == "stale-lock") {
        arr.add(JsonString("Gateway lock file points to a dead process; remove stale runtime state by running gateway stop, then restart Gateway."))
    } else if (status == "lock-only") {
        arr.add(JsonString("Gateway lock exists but no verified listener was found on the configured port; check Gateway logs and restart if channels look stale."))
    } else if (status == "not-running") {
        arr.add(JsonString("No running Gateway listener was detected for this configuration."))
    }
    arr
}

public func gatewayProcessIdentitySnapshotForConfig(user: GatewayUserSettings, cfg: GatewayConfig): JsonObject {
    let lockPid = gatewayPeekServeLockPid()
    let listenerPids = gatewayFindVerifiedListenerPidsOnPort(port: cfg.port)
    let effectivePids = gatewayResolveStopTargetPids(listenerPids, lockPid: lockPid)
    let lockAlive = match (lockPid) {
        case Some(pid) => gatewayServePidIsAlive(pid)
        case None => false
    }
    var pidMismatch = false
    match (lockPid) {
        case Some(pid) =>
            if (listenerPids.size > 0 && !gatewayProcessPidArrayContains(listenerPids, pid)) {
                pidMismatch = true
            }
        case None => ()
    }
    let runtime = gatewayRuntimeSnapshot()
    let http = GatewayHttpSurface.snapshot(cfg)
    let status = gatewayProcessIdentityStatus(lockPid, lockAlive, listenerPids, pidMismatch)

    let out = JsonObject()
    out.put("schema", JsonString(GATEWAY_PROCESS_IDENTITY_SCHEMA))
    out.put("buildFingerprint", JsonString(gatewayBuildFingerprint()))
    out.put("status", JsonString(status))
    out.put("currentPid", gatewayCliOwnProcessId().toJsonValue())
    match (lockPid) {
        case Some(pid) => out.put("lockPid", pid.toJsonValue())
        case None => out.put("lockPid", 0.toJsonValue())
    }
    out.put("lockAlive", lockAlive.toJsonValue())
    out.put("listenerPresent", (listenerPids.size > 0).toJsonValue())
    out.put("listenerPids", gatewayProcessPidArrayJson(listenerPids))
    out.put("effectivePids", gatewayProcessPidArrayJson(effectivePids))
    out.put("pidMismatch", pidMismatch.toJsonValue())
    out.put("runtimeUpdatedAtMs", runtime.get("updatedAtMs") ?? 0.toJsonValue())
    out.put("runtimeStartedAtMs", runtime.get("startedAtMs") ?? 0.toJsonValue())
    out.put("httpBaseUrl", http.get("baseUrl") ?? JsonString(""))
    out.put("preferredGatewayUrl", JsonString(gatewayPreferredGatewayUrlFromSettings(user)))
    out.put("advice", gatewayProcessIdentityAdvice(status))
    out.put("redacted", true.toJsonValue())
    out
}

public func gatewayProcessIdentitySnapshot(user: GatewayUserSettings): JsonObject {
    gatewayProcessIdentitySnapshotForConfig(user, buildGatewayConfigFromUserSettings(user))
}
