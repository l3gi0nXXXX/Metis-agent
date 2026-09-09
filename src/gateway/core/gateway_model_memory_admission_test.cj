package metis.gateway.core

import std.collection.ArrayList
import std.core.Duration
import std.sync.{AtomicBool, Mutex}
import std.time.MonoTime
import std.unittest.testmacro.*

private const S3_ADMISSION_MIB: Int64 = 1024 * 1024
private const S3_ADMISSION_GIB: Int64 = 1024 * 1024 * 1024

private func s3AdmissionSnapshot(
    maxBytes: Int64,
    availableBytes: Int64,
    managedStatus!: String = "ok",
    physicalBytes!: Int64 = 1,
    physicalStatus!: String = "ok"
): GatewayRuntimeHeapSnapshot {
    let usedBytes = if (maxBytes > 0 && availableBytes >= 0 && availableBytes <= maxBytes) {
        maxBytes - availableBytes
    } else {
        -1
    }
    GatewayRuntimeHeapSnapshot(
        maxBytes,
        usedBytes,
        availableBytes,
        if (maxBytes > 0 && usedBytes >= 0) {
            Int64(Float64(usedBytes) * 100.0 / Float64(maxBytes))
        } else {
            -1
        },
        managedStatus,
        physicalBytes,
        physicalStatus
    )
}

private func s3AdmissionSetSnapshot(snapshot: GatewayRuntimeHeapSnapshot): Unit {
    setGatewayModelMemoryAdmissionSnapshotProviderForTest(Some({=> snapshot}))
}

private func s3AdmissionRestoreHealthyBaseline(): Unit {
    resetGatewayModelMemoryAdmissionForTest()
    s3AdmissionSetSnapshot(s3AdmissionSnapshot(2 * S3_ADMISSION_GIB, S3_ADMISSION_GIB))
}

private func s3AdmissionReject(source: GatewayModelMemoryAdmissionSource): GatewayModelMemoryPressureException {
    try {
        let permit = gatewayTryAcquireModelMemoryAdmission(source)
        let _ = permit.release()
        throw Exception("expected_model_memory_pressure")
    } catch (error: GatewayModelMemoryPressureException) {
        error
    }
}

private func s3AdmissionAttemptStatus(source: GatewayModelMemoryAdmissionSource): String {
    try {
        let permit = gatewayTryAcquireModelMemoryAdmission(source)
        let _ = permit.release()
        "admitted"
    } catch (error: GatewayModelMemoryPressureException) {
        error.status
    }
}

private class S3AdmissionCompletionProvider {
    private let lock = Mutex()
    private var calls: Int64 = 0
    public let firstStarted = AtomicBool(false)
    public let releaseFirst = AtomicBool(false)

    public func snapshot(): GatewayRuntimeHeapSnapshot {
        let call = synchronized(this.lock) {
            this.calls++
            this.calls
        }
        if (call == 1) {
            this.firstStarted.store(true)
            while (!this.releaseFirst.load()) {
                sleep(Duration.millisecond)
            }
            return s3AdmissionSnapshot(2 * S3_ADMISSION_GIB, 256 * S3_ADMISSION_MIB - 1)
        }
        s3AdmissionSnapshot(2 * S3_ADMISSION_GIB, S3_ADMISSION_GIB)
    }
}

private func s3AdmissionWait(check: () -> Bool, timeoutMs!: Int64 = 2000): Bool {
    let startedAt = MonoTime.now()
    while ((MonoTime.now() - startedAt).toMilliseconds() < timeoutMs) {
        if (check()) {
            return true
        }
        sleep(Duration.millisecond)
    }
    check()
}

private func s3AdmissionJoinFuture(future: Option<Future<String>>): Unit {
    match (future) {
        case Some(value) => try {
            let _ = value.get(Duration.second * 5)
        } catch (_: Exception) {
            ()
        }
        case None => ()
    }
}

@Test
public class GatewayModelMemoryAdmissionTest {
    @TestCase
    public func s3AU1SourcesAndPermitReleaseAreExact(): Unit {
        resetGatewayModelMemoryAdmissionForTest()
        try {
            @Expect(gatewayModelMemoryAdmissionSourceName(gatewayModelMemoryAdmissionSource(" CRON ")), "cron")
            @Expect(gatewayModelMemoryAdmissionSourceName(gatewayModelMemoryAdmissionSource("service-plugin")), "service-plugin")
            @Expect(gatewayModelMemoryAdmissionSourceName(gatewayModelMemoryAdmissionSource("unknown-中文🙂")), "ordinary")
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(2 * S3_ADMISSION_GIB, S3_ADMISSION_GIB))
            let ordinary = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            let cron = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Cron)
            let capacity = s3AdmissionReject(GatewayModelMemoryAdmissionSource.ServicePlugin)
            @Expect(capacity.errorKind, "model_memory_pressure")
            @Expect(capacity.message, "model_memory_pressure")
            @Expect(capacity.source, "service-plugin")
            @Expect(capacity.status, "capacity")
            @Expect(capacity.active, 2)
            @Expect(ordinary.release(), true)
            @Expect(ordinary.release(), false)
            @Expect(cron.release(), true)
            let service = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.ServicePlugin)
            @Expect(service.release(), true)
            let truth = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(truth.active, 0)
            @Expect(truth.maxActive, 2)
            @Expect(truth.maxActiveSeen, 2)
            @Expect(truth.acceptedOrdinary, 1)
            @Expect(truth.acceptedCron, 1)
            @Expect(truth.acceptedServicePlugin, 1)
            @Expect(truth.rejectedOrdinary, 0)
            @Expect(truth.rejectedCron, 0)
            @Expect(truth.rejectedServicePlugin, 1)
            @Expect(truth.released, 3)
        } finally {
            s3AdmissionRestoreHealthyBaseline()
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().active, 0)
        }
    }

    @TestCase
    public func s3AB1ReserveBoundariesUseExactManagedHeapBytes(): Unit {
        resetGatewayModelMemoryAdmissionForTest()
        try {
            let twoGiB = 2 * S3_ADMISSION_GIB
            let proportionalReserve = twoGiB / 5
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(twoGiB, proportionalReserve))
            let exact = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            @Expect(exact.release(), true)

            resetGatewayModelMemoryAdmissionForTest()
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(twoGiB, proportionalReserve - 1))
            let below = s3AdmissionReject(GatewayModelMemoryAdmissionSource.Ordinary)
            @Expect(below.status, "heap_pressure")
            @Expect(below.reserveBytes, proportionalReserve)
            @Expect(below.availableBytes, proportionalReserve - 1)

            resetGatewayModelMemoryAdmissionForTest()
            let max511MiB = 511 * S3_ADMISSION_MIB
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(max511MiB, max511MiB))
            let smallHeap = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Cron)
            @Expect(smallHeap.release(), true)

            resetGatewayModelMemoryAdmissionForTest()
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(max511MiB, 256 * S3_ADMISSION_MIB))
            let floorExact = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Cron)
            @Expect(floorExact.release(), true)

            resetGatewayModelMemoryAdmissionForTest()
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(max511MiB, 256 * S3_ADMISSION_MIB - 1))
            let floorBelow = s3AdmissionReject(GatewayModelMemoryAdmissionSource.Cron)
            @Expect(floorBelow.reserveBytes, 256 * S3_ADMISSION_MIB)
            @Expect(floorBelow.status, "heap_pressure")

            resetGatewayModelMemoryAdmissionForTest()
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(Int64.Max, Int64.Max))
            let nearMax = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.ServicePlugin)
            @Expect(nearMax.release(), true)
            let nearMaxTruth = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(nearMaxTruth.lastReserveBytes, Int64.Max / 5)
            @Expect(nearMaxTruth.lastAvailableBytes, Int64.Max)
        } finally {
            s3AdmissionRestoreHealthyBaseline()
        }
    }

    @TestCase
    public func s3AB2PressureRecoveryAndProviderCompletionOrderAreDeterministic(): Unit {
        resetGatewayModelMemoryAdmissionForTest()
        try {
            let maxBytes = 2 * S3_ADMISSION_GIB
            let reserve = maxBytes / 5
            let recovery = reserve + 64 * S3_ADMISSION_MIB
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(maxBytes, reserve - 1))
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Ordinary).status, "heap_pressure")
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().pressureHigh, true)

            s3AdmissionSetSnapshot(s3AdmissionSnapshot(maxBytes, reserve))
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Cron).status, "heap_pressure")
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().recoveryStreak, 0)

            s3AdmissionSetSnapshot(s3AdmissionSnapshot(maxBytes, recovery - 1))
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Cron).status, "heap_pressure")
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().recoveryStreak, 0)

            s3AdmissionSetSnapshot(s3AdmissionSnapshot(maxBytes, recovery))
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Cron).status, "heap_pressure")
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().recoveryStreak, 1)

            s3AdmissionSetSnapshot(s3AdmissionSnapshot(-1, -1, managedStatus: "unavailable"))
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Cron).status, "heap_unavailable")
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().recoveryStreak, 0)

            s3AdmissionSetSnapshot(s3AdmissionSnapshot(maxBytes, recovery))
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Cron).status, "heap_pressure")
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(maxBytes, recovery))
            let recovered = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Cron)
            @Expect(recovered.release(), true)
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().pressureHigh, false)

            resetGatewayModelMemoryAdmissionForTest()
            let provider = S3AdmissionCompletionProvider()
            setGatewayModelMemoryAdmissionSnapshotProviderForTest(Some({=> provider.snapshot()}))
            var slowLow = None<Future<String>>
            var fastHealthy = None<Future<String>>
            var slowStatus = "not_started"
            var fastStatus = "not_started"
            try {
                slowLow = Some(spawn {s3AdmissionAttemptStatus(GatewayModelMemoryAdmissionSource.Ordinary)})
                let firstStarted = s3AdmissionWait({=> provider.firstStarted.load()})
                @Expect(firstStarted, true)
                if (!firstStarted) {
                    throw Exception("s3_admission_first_provider_not_started")
                }
                fastHealthy = Some(spawn {s3AdmissionAttemptStatus(GatewayModelMemoryAdmissionSource.Cron)})
                fastStatus = fastHealthy.getOrThrow().get(Duration.second * 5)
                provider.releaseFirst.store(true)
                slowStatus = slowLow.getOrThrow().get(Duration.second * 5)
            } finally {
                provider.releaseFirst.store(true)
                s3AdmissionJoinFuture(fastHealthy)
                s3AdmissionJoinFuture(slowLow)
            }
            @Expect(fastStatus, "admitted")
            @Expect(slowStatus, "heap_pressure")
            let ordered = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(ordered.pressureHigh, true)
            @Expect(ordered.lastSource, "ordinary")
            @Expect(ordered.lastStatus, "heap_pressure")
            @Expect(ordered.active, 0)
        } finally {
            s3AdmissionRestoreHealthyBaseline()
        }
    }

    @TestCase
    public func s3AP1HundredTurnsUseControlledWavesWithTwoActive(): Unit {
        resetGatewayModelMemoryAdmissionForTest()
        try {
            s3AdmissionSetSnapshot(s3AdmissionSnapshot(2 * S3_ADMISSION_GIB, S3_ADMISSION_GIB))
            var cursor: Int64 = 0
            var completed: Int64 = 0
            while (cursor < 100) {
                let permits = ArrayList<GatewayModelMemoryAdmissionPermit>()
                let rejectedAttempts = ArrayList<Future<String>>()
                let startRejectedAttempts = AtomicBool(false)
                let admittedEnd = min(cursor + 2, 100)
                try {
                    for (index in cursor..admittedEnd) {
                        let source = match (index % 3) {
                            case 0 => GatewayModelMemoryAdmissionSource.Ordinary
                            case 1 => GatewayModelMemoryAdmissionSource.Cron
                            case _ => GatewayModelMemoryAdmissionSource.ServicePlugin
                        }
                        permits.add(gatewayTryAcquireModelMemoryAdmission(source))
                    }
                    @Expect(gatewayModelMemoryAdmissionSnapshotForTest().active, admittedEnd - cursor)
                    for (index in admittedEnd..100) {
                        let source = match (index % 3) {
                            case 0 => GatewayModelMemoryAdmissionSource.Ordinary
                            case 1 => GatewayModelMemoryAdmissionSource.Cron
                            case _ => GatewayModelMemoryAdmissionSource.ServicePlugin
                        }
                        rejectedAttempts.add(
                            spawn {
                                while (!startRejectedAttempts.load()) {
                                    sleep(Duration.millisecond)
                                }
                                s3AdmissionAttemptStatus(source)
                            })
                    }
                    startRejectedAttempts.store(true)
                    for (attempt in rejectedAttempts) {
                        @Expect(attempt.get(Duration.second * 5), "capacity")
                    }
                } finally {
                    startRejectedAttempts.store(true)
                    for (attempt in rejectedAttempts) {
                        s3AdmissionJoinFuture(Some(attempt))
                    }
                    for (permit in permits) {
                        if (permit.release()) {
                            completed++
                        }
                    }
                }
                @Expect(gatewayModelMemoryAdmissionSnapshotForTest().active, 0)
                cursor = admittedEnd
            }
            let truth = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(completed, 100)
            @Expect(truth.acceptedTotal(), 100)
            @Expect(truth.rejectedTotal(), 2450)
            @Expect(truth.maxActiveSeen, 2)
            @Expect(truth.active, 0)
            @Expect(truth.released, 100)
            @Expect(truth.acceptedOrdinary, 34)
            @Expect(truth.acceptedCron, 33)
            @Expect(truth.acceptedServicePlugin, 33)
        } finally {
            s3AdmissionRestoreHealthyBaseline()
        }
    }

    @TestCase
    public func s3AN1UnavailableInvalidAndPhysicalTruthStayFailClosedAndRedacted(): Unit {
        resetGatewayModelMemoryAdmissionForTest()
        try {
            setGatewayModelMemoryAdmissionSnapshotProviderForTest(
                Some({
                    => throw Exception("Authorization: Bearer secret /private/user/prompt-中文🙂")
                }))
            let unavailable = s3AdmissionReject(GatewayModelMemoryAdmissionSource.ServicePlugin)
            @Expect(unavailable.errorKind, "model_memory_pressure")
            @Expect(unavailable.message, "model_memory_pressure")
            @Expect(unavailable.status, "heap_unavailable")
            @Expect(unavailable.source, "service-plugin")
            @Expect(unavailable.message.contains("Authorization"), false)
            @Expect(unavailable.message.contains("/private/"), false)
            @Expect(unavailable.message.contains("中文"), false)

            resetGatewayModelMemoryAdmissionForTest()
            let invalid = GatewayRuntimeHeapSnapshot(
                2 * S3_ADMISSION_GIB,
                S3_ADMISSION_GIB,
                S3_ADMISSION_GIB - 1,
                50,
                "ok",
                4 * S3_ADMISSION_GIB,
                "ok"
            )
            s3AdmissionSetSnapshot(invalid)
            @Expect(s3AdmissionReject(GatewayModelMemoryAdmissionSource.Ordinary).status, "heap_unavailable")
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().recoveryStreak, 0)

            resetGatewayModelMemoryAdmissionForTest()
            s3AdmissionSetSnapshot(
                s3AdmissionSnapshot(
                    2 * S3_ADMISSION_GIB,
                    S3_ADMISSION_GIB,
                    physicalBytes: Int64.Max,
                    physicalStatus: "ok"
                )
            )
            let physicalAboveMax = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            @Expect(physicalAboveMax.release(), true)

            resetGatewayModelMemoryAdmissionForTest()
            s3AdmissionSetSnapshot(
                s3AdmissionSnapshot(
                    2 * S3_ADMISSION_GIB,
                    S3_ADMISSION_GIB,
                    physicalBytes: -1,
                    physicalStatus: "unavailable"
                )
            )
            let physicalUnavailable = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            @Expect(physicalUnavailable.release(), true)
            let truth = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(truth.lastStatus, "admitted")
            @Expect(truth.lastMaxHeapBytes, 2 * S3_ADMISSION_GIB)
            @Expect(truth.lastAvailableBytes, S3_ADMISSION_GIB)
        } finally {
            s3AdmissionRestoreHealthyBaseline()
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().active, 0)
        }
    }
}
