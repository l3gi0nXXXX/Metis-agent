package metis.gateway.core

import metis.process.{ProcessFdSnapshot, captureCurrentProcessFdSnapshot}
import std.sync.Mutex
import std.time.MonoTime
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

private let gatewayFdObservationLock = Mutex()
private var gatewayFdObservationProvider: ?(() -> ProcessFdSnapshot) = None
private var gatewayFdObservationCached: ?ProcessFdSnapshot = None
private var gatewayFdObservationSampledAt = MonoTime.now()
private var gatewayFdObservationDurationMs: Int64 = 0

public func setGatewayFdSnapshotProviderForTest(provider: ?(() -> ProcessFdSnapshot)): Unit {
    synchronized(gatewayFdObservationLock) {
        gatewayFdObservationProvider = provider
        gatewayFdObservationCached = None
    }
}

/** At most one bounded native snapshot per second, even during an I/O storm. */
public func gatewayObserveFdPressure(phase: String): JsonObject {
    synchronized(gatewayFdObservationLock) {
        let now = MonoTime.now()
        if (gatewayFdObservationCached.isNone() ||
            (now - gatewayFdObservationSampledAt).toMilliseconds() >= 1000) {
            let value = try {
                match (gatewayFdObservationProvider) {
                    case Some(provider) => provider()
                    case None => captureCurrentProcessFdSnapshot()
                }
            } catch (_: Exception) { ProcessFdSnapshot("probe_failed") }
            gatewayFdObservationDurationMs = max(0, (MonoTime.now() - now).toMilliseconds())
            gatewayFdObservationCached = Some(value)
            gatewayFdObservationSampledAt = now
        }
        let snapshot = gatewayFdObservationCached.getOrThrow()
        let known = ["ok", "probe_failed", "invalid_native_result", "truncated", "unsupported"]
        let status = if (known.contains(snapshot.status)) { snapshot.status } else { "probe_failed" }
        let out = JsonObject()
        out.put("phase", JsonString(if (["persist", "recovered", "heartbeat"].contains(phase)) { phase } else { "unknown" }))
        out.put("durationMs", JsonInt(gatewayFdObservationDurationMs))
        out.put("fdStatus", JsonString(status))
        out.put("fdCount", JsonInt(if (status == "ok") { snapshot.fdCount } else { -1 }))
        out.put("fdLimit", JsonInt(snapshot.fdLimit))
        out.put("fdVnodeCount", JsonInt(if (status == "ok") { snapshot.vnodeCount } else { -1 }))
        out.put("fdSocketCount", JsonInt(if (status == "ok") { snapshot.socketCount } else { -1 }))
        out.put("fdPipeCount", JsonInt(if (status == "ok") { snapshot.pipeCount } else { -1 }))
        out.put("fdOtherCount", JsonInt(if (status == "ok") { snapshot.otherCount } else { -1 }))
        out
    }
}
