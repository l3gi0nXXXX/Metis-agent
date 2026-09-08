package metis.gateway.core

import std.sync.Mutex

public const GATEWAY_MODEL_MEMORY_PRESSURE_ERROR_KIND = "model_memory_pressure"
private const GATEWAY_MODEL_MEMORY_MAX_ACTIVE: Int64 = 2
private const GATEWAY_MODEL_MEMORY_MIN_RESERVE_BYTES: Int64 = 256 * 1024 * 1024
private const GATEWAY_MODEL_MEMORY_RECOVERY_MARGIN_BYTES: Int64 = 64 * 1024 * 1024

public enum GatewayModelMemoryAdmissionSource {
    | Ordinary
    | Cron
    | ServicePlugin
}

public func gatewayModelMemoryAdmissionSource(raw: String): GatewayModelMemoryAdmissionSource {
    let normalized = raw.trimAscii().toAsciiLower()
    if (normalized == "cron") {
        GatewayModelMemoryAdmissionSource.Cron
    } else if (normalized == "service-plugin") {
        GatewayModelMemoryAdmissionSource.ServicePlugin
    } else {
        GatewayModelMemoryAdmissionSource.Ordinary
    }
}

public func gatewayModelMemoryAdmissionSourceName(source: GatewayModelMemoryAdmissionSource): String {
    match (source) {
        case GatewayModelMemoryAdmissionSource.Ordinary => "ordinary"
        case GatewayModelMemoryAdmissionSource.Cron => "cron"
        case GatewayModelMemoryAdmissionSource.ServicePlugin => "service-plugin"
    }
}

public class GatewayModelMemoryPressureException <: Exception {
    public let errorKind: String = GATEWAY_MODEL_MEMORY_PRESSURE_ERROR_KIND
    public let source: String
    public let status: String
    public let active: Int64
    public let maxHeapBytes: Int64
    public let reserveBytes: Int64
    public let availableBytes: Int64
    public let accepted: Int64
    public let rejected: Int64

    public init(
        source: String,
        status: String,
        active: Int64,
        maxHeapBytes: Int64,
        reserveBytes: Int64,
        availableBytes: Int64,
        accepted: Int64,
        rejected: Int64
    ) {
        super(GATEWAY_MODEL_MEMORY_PRESSURE_ERROR_KIND)
        this.source = source
        this.status = status
        this.active = active
        this.maxHeapBytes = maxHeapBytes
        this.reserveBytes = reserveBytes
        this.availableBytes = availableBytes
        this.accepted = accepted
        this.rejected = rejected
    }
}

public class GatewayModelMemoryAdmissionSnapshotForTest {
    public let active: Int64
    public let maxActive: Int64
    public let maxActiveSeen: Int64
    public let pressureHigh: Bool
    public let recoveryStreak: Int64
    public let acceptedOrdinary: Int64
    public let acceptedCron: Int64
    public let acceptedServicePlugin: Int64
    public let rejectedOrdinary: Int64
    public let rejectedCron: Int64
    public let rejectedServicePlugin: Int64
    public let released: Int64
    public let lastSource: String
    public let lastStatus: String
    public let lastMaxHeapBytes: Int64
    public let lastReserveBytes: Int64
    public let lastAvailableBytes: Int64

    public init(
        active: Int64,
        maxActive: Int64,
        maxActiveSeen: Int64,
        pressureHigh: Bool,
        recoveryStreak: Int64,
        acceptedOrdinary: Int64,
        acceptedCron: Int64,
        acceptedServicePlugin: Int64,
        rejectedOrdinary: Int64,
        rejectedCron: Int64,
        rejectedServicePlugin: Int64,
        released: Int64,
        lastSource: String,
        lastStatus: String,
        lastMaxHeapBytes: Int64,
        lastReserveBytes: Int64,
        lastAvailableBytes: Int64
    ) {
        this.active = active
        this.maxActive = maxActive
        this.maxActiveSeen = maxActiveSeen
        this.pressureHigh = pressureHigh
        this.recoveryStreak = recoveryStreak
        this.acceptedOrdinary = acceptedOrdinary
        this.acceptedCron = acceptedCron
        this.acceptedServicePlugin = acceptedServicePlugin
        this.rejectedOrdinary = rejectedOrdinary
        this.rejectedCron = rejectedCron
        this.rejectedServicePlugin = rejectedServicePlugin
        this.released = released
        this.lastSource = lastSource
        this.lastStatus = lastStatus
        this.lastMaxHeapBytes = lastMaxHeapBytes
        this.lastReserveBytes = lastReserveBytes
        this.lastAvailableBytes = lastAvailableBytes
    }

    public func acceptedTotal(): Int64 {
        this.acceptedOrdinary + this.acceptedCron + this.acceptedServicePlugin
    }

    public func rejectedTotal(): Int64 {
        this.rejectedOrdinary + this.rejectedCron + this.rejectedServicePlugin
    }
}

private class GatewayModelMemoryAdmissionDecision {
    let admitted: Bool
    let source: String
    let status: String
    let active: Int64
    let maxHeapBytes: Int64
    let reserveBytes: Int64
    let availableBytes: Int64
    let accepted: Int64
    let rejected: Int64

    init(
        admitted: Bool,
        source: String,
        status: String,
        active: Int64,
        maxHeapBytes: Int64,
        reserveBytes: Int64,
        availableBytes: Int64,
        accepted: Int64,
        rejected: Int64
    ) {
        this.admitted = admitted
        this.source = source
        this.status = status
        this.active = active
        this.maxHeapBytes = maxHeapBytes
        this.reserveBytes = reserveBytes
        this.availableBytes = availableBytes
        this.accepted = accepted
        this.rejected = rejected
    }
}

private let gatewayModelMemoryAdmissionLock = Mutex()
private let gatewayModelMemoryAdmissionProviderLock = Mutex()
private var gatewayModelMemoryAdmissionSnapshotProviderForTest: Option<() -> GatewayRuntimeHeapSnapshot> = None<() -> GatewayRuntimeHeapSnapshot>
private var gatewayModelMemoryAdmissionActive: Int64 = 0
private var gatewayModelMemoryAdmissionMaxActiveSeen: Int64 = 0
private var gatewayModelMemoryAdmissionPressureHigh: Bool = false
private var gatewayModelMemoryAdmissionRecoveryStreak: Int64 = 0
private var gatewayModelMemoryAdmissionAcceptedOrdinary: Int64 = 0
private var gatewayModelMemoryAdmissionAcceptedCron: Int64 = 0
private var gatewayModelMemoryAdmissionAcceptedServicePlugin: Int64 = 0
private var gatewayModelMemoryAdmissionRejectedOrdinary: Int64 = 0
private var gatewayModelMemoryAdmissionRejectedCron: Int64 = 0
private var gatewayModelMemoryAdmissionRejectedServicePlugin: Int64 = 0
private var gatewayModelMemoryAdmissionReleased: Int64 = 0
private var gatewayModelMemoryAdmissionLastSource: String = "none"
private var gatewayModelMemoryAdmissionLastStatus: String = "idle"
private var gatewayModelMemoryAdmissionLastMaxHeapBytes: Int64 = -1
private var gatewayModelMemoryAdmissionLastReserveBytes: Int64 = -1
private var gatewayModelMemoryAdmissionLastAvailableBytes: Int64 = -1

private func gatewayModelMemoryAdmissionReserveBytes(maxHeapBytes: Int64): Int64 {
    let proportional = maxHeapBytes / 5
    if (proportional > GATEWAY_MODEL_MEMORY_MIN_RESERVE_BYTES) {
        proportional
    } else {
        GATEWAY_MODEL_MEMORY_MIN_RESERVE_BYTES
    }
}

private func gatewayModelMemoryAdmissionSaturatingAdd(left: Int64, right: Int64): Int64 {
    if (left >= Int64.Max - right) {
        Int64.Max
    } else {
        left + right
    }
}

private func gatewayModelMemoryAdmissionManagedSnapshotValid(snapshot: GatewayRuntimeHeapSnapshot): Bool {
    snapshot.managedHeapStatus == "ok" && snapshot.maxHeapBytes > 0 && snapshot.managedHeapUsedBytes >= 0 &&
        snapshot.managedHeapUsedBytes <= snapshot.maxHeapBytes && snapshot.managedHeapAvailableBytes ==
        snapshot.maxHeapBytes - snapshot.managedHeapUsedBytes
}

private func gatewayModelMemoryAdmissionAcceptedForSource(source: GatewayModelMemoryAdmissionSource): Int64 {
    match (source) {
        case GatewayModelMemoryAdmissionSource.Ordinary => gatewayModelMemoryAdmissionAcceptedOrdinary
        case GatewayModelMemoryAdmissionSource.Cron => gatewayModelMemoryAdmissionAcceptedCron
        case GatewayModelMemoryAdmissionSource.ServicePlugin => gatewayModelMemoryAdmissionAcceptedServicePlugin
    }
}

private func gatewayModelMemoryAdmissionRejectedForSource(source: GatewayModelMemoryAdmissionSource): Int64 {
    match (source) {
        case GatewayModelMemoryAdmissionSource.Ordinary => gatewayModelMemoryAdmissionRejectedOrdinary
        case GatewayModelMemoryAdmissionSource.Cron => gatewayModelMemoryAdmissionRejectedCron
        case GatewayModelMemoryAdmissionSource.ServicePlugin => gatewayModelMemoryAdmissionRejectedServicePlugin
    }
}

private func gatewayModelMemoryAdmissionIncrementAccepted(source: GatewayModelMemoryAdmissionSource): Unit {
    match (source) {
        case GatewayModelMemoryAdmissionSource.Ordinary => gatewayModelMemoryAdmissionAcceptedOrdinary++
        case GatewayModelMemoryAdmissionSource.Cron => gatewayModelMemoryAdmissionAcceptedCron++
        case GatewayModelMemoryAdmissionSource.ServicePlugin => gatewayModelMemoryAdmissionAcceptedServicePlugin++
    }
}

private func gatewayModelMemoryAdmissionIncrementRejected(source: GatewayModelMemoryAdmissionSource): Unit {
    match (source) {
        case GatewayModelMemoryAdmissionSource.Ordinary => gatewayModelMemoryAdmissionRejectedOrdinary++
        case GatewayModelMemoryAdmissionSource.Cron => gatewayModelMemoryAdmissionRejectedCron++
        case GatewayModelMemoryAdmissionSource.ServicePlugin => gatewayModelMemoryAdmissionRejectedServicePlugin++
    }
}

private func gatewayModelMemoryAdmissionUnavailableSnapshot(): GatewayRuntimeHeapSnapshot {
    GatewayRuntimeHeapSnapshot(-1, -1, -1, -1, "unavailable", -1, "unavailable")
}

private func gatewayModelMemoryAdmissionReadSnapshot(): GatewayRuntimeHeapSnapshot {
    let provider = synchronized(gatewayModelMemoryAdmissionProviderLock) {
        gatewayModelMemoryAdmissionSnapshotProviderForTest
    }
    try {
        match (provider) {
            case Some(value) => value()
            case None => gatewayRuntimeHeapSnapshot()
        }
    } catch (_: Exception) {
        gatewayModelMemoryAdmissionUnavailableSnapshot()
    }
}

private func gatewayModelMemoryAdmissionDecision(
    source: GatewayModelMemoryAdmissionSource,
    snapshot: GatewayRuntimeHeapSnapshot
): GatewayModelMemoryAdmissionDecision {
    synchronized(gatewayModelMemoryAdmissionLock) {
        let sourceName = gatewayModelMemoryAdmissionSourceName(source)
        gatewayModelMemoryAdmissionLastSource = sourceName
        gatewayModelMemoryAdmissionLastMaxHeapBytes = snapshot.maxHeapBytes
        gatewayModelMemoryAdmissionLastAvailableBytes = snapshot.managedHeapAvailableBytes
        if (!gatewayModelMemoryAdmissionManagedSnapshotValid(snapshot)) {
            gatewayModelMemoryAdmissionRecoveryStreak = 0
            gatewayModelMemoryAdmissionLastReserveBytes = -1
            gatewayModelMemoryAdmissionLastStatus = "heap_unavailable"
            gatewayModelMemoryAdmissionIncrementRejected(source)
            return GatewayModelMemoryAdmissionDecision(
                false,
                sourceName,
                gatewayModelMemoryAdmissionLastStatus,
                gatewayModelMemoryAdmissionActive,
                snapshot.maxHeapBytes,
                -1,
                snapshot.managedHeapAvailableBytes,
                gatewayModelMemoryAdmissionAcceptedForSource(source),
                gatewayModelMemoryAdmissionRejectedForSource(source)
            )
        }
        let reserveBytes = gatewayModelMemoryAdmissionReserveBytes(snapshot.maxHeapBytes)
        gatewayModelMemoryAdmissionLastReserveBytes = reserveBytes
        if (gatewayModelMemoryAdmissionPressureHigh) {
            let recoveryBytes = gatewayModelMemoryAdmissionSaturatingAdd(
                reserveBytes,
                GATEWAY_MODEL_MEMORY_RECOVERY_MARGIN_BYTES
            )
            if (snapshot.managedHeapAvailableBytes >= recoveryBytes) {
                gatewayModelMemoryAdmissionRecoveryStreak++
            } else {
                gatewayModelMemoryAdmissionRecoveryStreak = 0
            }
            if (gatewayModelMemoryAdmissionRecoveryStreak >= 2) {
                gatewayModelMemoryAdmissionPressureHigh = false
                gatewayModelMemoryAdmissionRecoveryStreak = 0
            } else {
                gatewayModelMemoryAdmissionLastStatus = "heap_pressure"
                gatewayModelMemoryAdmissionIncrementRejected(source)
                return GatewayModelMemoryAdmissionDecision(
                    false,
                    sourceName,
                    gatewayModelMemoryAdmissionLastStatus,
                    gatewayModelMemoryAdmissionActive,
                    snapshot.maxHeapBytes,
                    reserveBytes,
                    snapshot.managedHeapAvailableBytes,
                    gatewayModelMemoryAdmissionAcceptedForSource(source),
                    gatewayModelMemoryAdmissionRejectedForSource(source)
                )
            }
        } else if (snapshot.managedHeapAvailableBytes < reserveBytes) {
            gatewayModelMemoryAdmissionPressureHigh = true
            gatewayModelMemoryAdmissionRecoveryStreak = 0
            gatewayModelMemoryAdmissionLastStatus = "heap_pressure"
            gatewayModelMemoryAdmissionIncrementRejected(source)
            return GatewayModelMemoryAdmissionDecision(
                false,
                sourceName,
                gatewayModelMemoryAdmissionLastStatus,
                gatewayModelMemoryAdmissionActive,
                snapshot.maxHeapBytes,
                reserveBytes,
                snapshot.managedHeapAvailableBytes,
                gatewayModelMemoryAdmissionAcceptedForSource(source),
                gatewayModelMemoryAdmissionRejectedForSource(source)
            )
        }
        if (gatewayModelMemoryAdmissionActive >= GATEWAY_MODEL_MEMORY_MAX_ACTIVE) {
            gatewayModelMemoryAdmissionLastStatus = "capacity"
            gatewayModelMemoryAdmissionIncrementRejected(source)
            return GatewayModelMemoryAdmissionDecision(
                false,
                sourceName,
                gatewayModelMemoryAdmissionLastStatus,
                gatewayModelMemoryAdmissionActive,
                snapshot.maxHeapBytes,
                reserveBytes,
                snapshot.managedHeapAvailableBytes,
                gatewayModelMemoryAdmissionAcceptedForSource(source),
                gatewayModelMemoryAdmissionRejectedForSource(source)
            )
        }
        gatewayModelMemoryAdmissionActive++
        if (gatewayModelMemoryAdmissionActive > gatewayModelMemoryAdmissionMaxActiveSeen) {
            gatewayModelMemoryAdmissionMaxActiveSeen = gatewayModelMemoryAdmissionActive
        }
        gatewayModelMemoryAdmissionIncrementAccepted(source)
        gatewayModelMemoryAdmissionLastStatus = "admitted"
        GatewayModelMemoryAdmissionDecision(
            true,
            sourceName,
            gatewayModelMemoryAdmissionLastStatus,
            gatewayModelMemoryAdmissionActive,
            snapshot.maxHeapBytes,
            reserveBytes,
            snapshot.managedHeapAvailableBytes,
            gatewayModelMemoryAdmissionAcceptedForSource(source),
            gatewayModelMemoryAdmissionRejectedForSource(source)
        )
    }
}

private func gatewayModelMemoryAdmissionRelease(): Unit {
    synchronized(gatewayModelMemoryAdmissionLock) {
        if (gatewayModelMemoryAdmissionActive > 0) {
            gatewayModelMemoryAdmissionActive--
            gatewayModelMemoryAdmissionReleased++
        }
    }
}

public class GatewayModelMemoryAdmissionPermit {
    private let releaseLock = Mutex()
    private var released: Bool = false

    private init() {}

    internal static func acquire(source: GatewayModelMemoryAdmissionSource): GatewayModelMemoryAdmissionPermit {
        let snapshot = gatewayModelMemoryAdmissionReadSnapshot()
        let decision = gatewayModelMemoryAdmissionDecision(source, snapshot)
        if (!decision.admitted) {
            throw GatewayModelMemoryPressureException(
                decision.source,
                decision.status,
                decision.active,
                decision.maxHeapBytes,
                decision.reserveBytes,
                decision.availableBytes,
                decision.accepted,
                decision.rejected
            )
        }
        GatewayModelMemoryAdmissionPermit()
    }

    public func release(): Bool {
        let shouldRelease = synchronized(this.releaseLock) {
            if (this.released) {
                false
            } else {
                this.released = true
                true
            }
        }
        if (shouldRelease) {
            gatewayModelMemoryAdmissionRelease()
        }
        shouldRelease
    }
}

public func gatewayTryAcquireModelMemoryAdmission(source: GatewayModelMemoryAdmissionSource): GatewayModelMemoryAdmissionPermit {
    GatewayModelMemoryAdmissionPermit.acquire(source)
}

public func setGatewayModelMemoryAdmissionSnapshotProviderForTest(provider: Option<() -> GatewayRuntimeHeapSnapshot>): Unit {
    synchronized(gatewayModelMemoryAdmissionProviderLock) {
        gatewayModelMemoryAdmissionSnapshotProviderForTest = provider
    }
}

public func gatewayModelMemoryAdmissionSnapshotForTest(): GatewayModelMemoryAdmissionSnapshotForTest {
    synchronized(gatewayModelMemoryAdmissionLock) {
        GatewayModelMemoryAdmissionSnapshotForTest(
            gatewayModelMemoryAdmissionActive,
            GATEWAY_MODEL_MEMORY_MAX_ACTIVE,
            gatewayModelMemoryAdmissionMaxActiveSeen,
            gatewayModelMemoryAdmissionPressureHigh,
            gatewayModelMemoryAdmissionRecoveryStreak,
            gatewayModelMemoryAdmissionAcceptedOrdinary,
            gatewayModelMemoryAdmissionAcceptedCron,
            gatewayModelMemoryAdmissionAcceptedServicePlugin,
            gatewayModelMemoryAdmissionRejectedOrdinary,
            gatewayModelMemoryAdmissionRejectedCron,
            gatewayModelMemoryAdmissionRejectedServicePlugin,
            gatewayModelMemoryAdmissionReleased,
            gatewayModelMemoryAdmissionLastSource,
            gatewayModelMemoryAdmissionLastStatus,
            gatewayModelMemoryAdmissionLastMaxHeapBytes,
            gatewayModelMemoryAdmissionLastReserveBytes,
            gatewayModelMemoryAdmissionLastAvailableBytes
        )
    }
}

public func resetGatewayModelMemoryAdmissionForTest(): Unit {
    synchronized(gatewayModelMemoryAdmissionProviderLock) {
        gatewayModelMemoryAdmissionSnapshotProviderForTest = None<() -> GatewayRuntimeHeapSnapshot>
    }
    synchronized(gatewayModelMemoryAdmissionLock) {
        gatewayModelMemoryAdmissionActive = 0
        gatewayModelMemoryAdmissionMaxActiveSeen = 0
        gatewayModelMemoryAdmissionPressureHigh = false
        gatewayModelMemoryAdmissionRecoveryStreak = 0
        gatewayModelMemoryAdmissionAcceptedOrdinary = 0
        gatewayModelMemoryAdmissionAcceptedCron = 0
        gatewayModelMemoryAdmissionAcceptedServicePlugin = 0
        gatewayModelMemoryAdmissionRejectedOrdinary = 0
        gatewayModelMemoryAdmissionRejectedCron = 0
        gatewayModelMemoryAdmissionRejectedServicePlugin = 0
        gatewayModelMemoryAdmissionReleased = 0
        gatewayModelMemoryAdmissionLastSource = "none"
        gatewayModelMemoryAdmissionLastStatus = "idle"
        gatewayModelMemoryAdmissionLastMaxHeapBytes = -1
        gatewayModelMemoryAdmissionLastReserveBytes = -1
        gatewayModelMemoryAdmissionLastAvailableBytes = -1
    }
}
