package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.CliConfig
import metis.gateway.process.{gatewayStdioBrokerReady, gatewayStdioBrokerSnapshot}

import std.convert.Parsable
import std.fs.{File, exists, Path}
import std.sync.Mutex
import std.time.DateTime
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}

private var gatewayRuntimeStartedAtMs: Int64 = 0
private var gatewayRuntimeUpdatedAtMs: Int64 = 0
private var gatewayRuntimeRunning: Bool = false
private var gatewayRuntimeStatus: String = "stopped"
private var gatewayRuntimeReason: String = ""
private let gatewayRuntimeOperationalLock = Mutex()
private var gatewayRuntimeLastPollAtMs: Int64 = 0
private var gatewayRuntimeBrokerAlive: Bool = false
private var gatewayRuntimeBrokerResponsive: Bool = false
private var gatewayRuntimeBrokerStatus: String = ""
private var gatewayRuntimeBrokerGeneration: Int64 = 0
private var gatewayRuntimeBrokerOwnerCount: Int64 = 0
private var gatewayRuntimeInboundQueueDepth: Int64 = 0

private func gatewayRuntimeNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func gatewayRuntimePersist(): Unit {
    let root = JsonObject()
    root.put("running", gatewayRuntimeRunning.toJsonValue())
    root.put("status", JsonString(gatewayRuntimeStatus))
    root.put("reason", JsonString(gatewayRuntimeReason))
    root.put("startedAtMs", gatewayRuntimeStartedAtMs.toJsonValue())
    root.put("updatedAtMs", gatewayRuntimeUpdatedAtMs.toJsonValue())
    root.put("serveLockPresent", gatewayAnotherServeInstanceSeemsRunning().toJsonValue())
    gatewayRuntimeAppendOperational(root, gatewayRuntimeNowMs(), forceMemory: true)
    File.writeTo(gatewayRuntimeStatePath(), root.toJsonString().toArray())
}

private func gatewayRuntimeSnapshotBool(root: JsonObject, key: String): Bool {
    match (root.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func gatewayRuntimeSnapshotInt64(root: JsonObject, key: String): Int64 {
    match (root.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func gatewayRuntimeAppendOperational(root: JsonObject, nowMs: Int64, forceMemory!: Bool = false): Unit {
    synchronized(gatewayRuntimeOperationalLock) {
        if (gatewayRuntimeLastPollAtMs > 0 || forceMemory) {
            let age = if (gatewayRuntimeLastPollAtMs > 0 && nowMs > gatewayRuntimeLastPollAtMs) {
                nowMs - gatewayRuntimeLastPollAtMs
            } else {
                0
            }
            root.put("lastPollAtMs", gatewayRuntimeLastPollAtMs.toJsonValue())
            root.put("pollLagMs", age.toJsonValue())
            root.put("brokerAlive", gatewayRuntimeBrokerAlive.toJsonValue())
            root.put("brokerResponsive", gatewayRuntimeBrokerResponsive.toJsonValue())
            root.put("brokerStatus", JsonString(gatewayRuntimeBrokerStatus))
            root.put("brokerGeneration", gatewayRuntimeBrokerGeneration.toJsonValue())
            root.put("brokerOwnerCount", gatewayRuntimeBrokerOwnerCount.toJsonValue())
            root.put("inboundQueueDepth", gatewayRuntimeInboundQueueDepth.toJsonValue())
        } else {
            let persistedLastPollAtMs = gatewayRuntimeSnapshotInt64(root, "lastPollAtMs")
            let persistedAge = if (persistedLastPollAtMs > 0 && nowMs > persistedLastPollAtMs) {
                nowMs - persistedLastPollAtMs
            } else {
                0
            }
            root.put("pollLagMs", persistedAge.toJsonValue())
        }
    }
}

private func gatewayRuntimeResetOperational(): Unit {
    synchronized(gatewayRuntimeOperationalLock) {
        gatewayRuntimeLastPollAtMs = 0
        gatewayRuntimeBrokerAlive = false
        gatewayRuntimeBrokerResponsive = false
        gatewayRuntimeBrokerStatus = ""
        gatewayRuntimeBrokerGeneration = 0
        gatewayRuntimeBrokerOwnerCount = 0
        gatewayRuntimeInboundQueueDepth = 0
    }
}

public func gatewayRuntimeMarkPollCompleted(operational: JsonObject): Unit {
    let broker = match (operational.get("broker")) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
    synchronized(gatewayRuntimeOperationalLock) {
        gatewayRuntimeLastPollAtMs = gatewayRuntimeNowMs()
        gatewayRuntimeBrokerAlive = gatewayRuntimeSnapshotBool(broker, "running")
        gatewayRuntimeBrokerResponsive = gatewayRuntimeSnapshotBool(broker, "responsive")
        gatewayRuntimeBrokerStatus = match (broker.get("status")) {
            case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
            case None => ""
        }
        gatewayRuntimeBrokerGeneration = gatewayRuntimeSnapshotInt64(broker, "generation")
        gatewayRuntimeBrokerOwnerCount = gatewayRuntimeSnapshotInt64(broker, "ownerCount")
        gatewayRuntimeInboundQueueDepth = gatewayRuntimeSnapshotInt64(operational, "inboundQueueDepth")
    }
}

public func gatewayRuntimeStatePath(): Path {
    CliConfig.dotDir.join("gateway-runtime-state.json")
}

public func gatewayRuntimeMarkStarting(): Unit {
    gatewayRuntimeResetOperational()
    gatewayRuntimeStartedAtMs = gatewayRuntimeNowMs()
    gatewayRuntimeUpdatedAtMs = gatewayRuntimeStartedAtMs
    gatewayRuntimeRunning = false
    gatewayRuntimeStatus = "starting"
    gatewayRuntimeReason = ""
    gatewayRuntimePersist()
}

public func gatewayRuntimeMarkRunning(): Unit {
    let now = gatewayRuntimeNowMs()
    if (gatewayRuntimeStartedAtMs <= 0) {
        gatewayRuntimeStartedAtMs = now
    }
    gatewayRuntimeUpdatedAtMs = now
    gatewayRuntimeRunning = true
    gatewayRuntimeStatus = "running"
    gatewayRuntimeReason = ""
    gatewayRuntimePersist()
}

public func gatewayRuntimeHeartbeat(): Unit {
    let probe = gatewayStdioBrokerReady(timeoutMs: 500)
    let broker = gatewayStdioBrokerSnapshot()
    synchronized(gatewayRuntimeOperationalLock) {
        gatewayRuntimeBrokerAlive = gatewayRuntimeSnapshotBool(broker, "running")
        gatewayRuntimeBrokerResponsive = probe.ok && gatewayRuntimeSnapshotBool(broker, "responsive")
        gatewayRuntimeBrokerStatus = probe.status
        gatewayRuntimeBrokerGeneration = gatewayRuntimeSnapshotInt64(broker, "generation")
        gatewayRuntimeBrokerOwnerCount = gatewayRuntimeSnapshotInt64(broker, "ownerCount")
    }
    gatewayRuntimeUpdatedAtMs = gatewayRuntimeNowMs()
    if (gatewayRuntimeStatus.trimAscii().isEmpty()) {
        gatewayRuntimeStatus = if (gatewayRuntimeRunning) { "running" } else { "stopped" }
    }
    gatewayRuntimePersist()
}

public func gatewayRuntimeMarkStopped(reason!: String = "stopped"): Unit {
    gatewayRuntimeResetOperational()
    gatewayRuntimeUpdatedAtMs = gatewayRuntimeNowMs()
    gatewayRuntimeRunning = false
    gatewayRuntimeStatus = "stopped"
    gatewayRuntimeReason = reason.trimAscii()
    gatewayRuntimePersist()
}

public func gatewayRuntimeMarkStoppedFromCli(reason!: String = "stopped"): Unit {
    gatewayRuntimeResetOperational()
    let path = gatewayRuntimeStatePath()
    var startedAtMs: Int64 = gatewayRuntimeStartedAtMs
    if (exists(path)) {
        try {
            let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            let persistedStartedAtMs = gatewayRuntimeSnapshotInt64(root, "startedAtMs")
            if (persistedStartedAtMs > 0) {
                startedAtMs = persistedStartedAtMs
            }
        } catch (_: Exception) {
            ()
        }
    }
    gatewayRuntimeStartedAtMs = startedAtMs
    gatewayRuntimeUpdatedAtMs = gatewayRuntimeNowMs()
    gatewayRuntimeRunning = false
    gatewayRuntimeStatus = "stopped"
    gatewayRuntimeReason = reason.trimAscii()
    gatewayRuntimePersist()
}

public func gatewayRuntimeSnapshot(): JsonObject {
    let path = gatewayRuntimeStatePath()
    if (exists(path)) {
        try {
            let persisted = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            gatewayRuntimeAppendOperational(persisted, gatewayRuntimeNowMs())
            return persisted
        } catch (_e: Exception) {
            ()
        }
    }
    let root = JsonObject()
    root.put("running", gatewayRuntimeRunning.toJsonValue())
    root.put("status", JsonString(gatewayRuntimeStatus))
    root.put("reason", JsonString(gatewayRuntimeReason))
    root.put("startedAtMs", gatewayRuntimeStartedAtMs.toJsonValue())
    root.put("updatedAtMs", gatewayRuntimeUpdatedAtMs.toJsonValue())
    root.put("serveLockPresent", gatewayAnotherServeInstanceSeemsRunning().toJsonValue())
    gatewayRuntimeAppendOperational(root, gatewayRuntimeNowMs(), forceMemory: true)
    root
}
