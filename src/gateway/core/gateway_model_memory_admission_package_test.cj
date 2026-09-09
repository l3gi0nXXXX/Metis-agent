package metis.gateway.core

import std.unittest.testmacro.*

private const GATEWAY_MODEL_MEMORY_TEST_GIB: Int64 = 1024 * 1024 * 1024

private func gatewayInstallModelMemoryHealthyPackageBaseline(): Bool {
    setGatewayModelMemoryAdmissionSnapshotProviderForTest(
        Some({=> GatewayRuntimeHeapSnapshot(
            2 * GATEWAY_MODEL_MEMORY_TEST_GIB,
            GATEWAY_MODEL_MEMORY_TEST_GIB,
            GATEWAY_MODEL_MEMORY_TEST_GIB,
            50,
            "ok",
            1,
            "ok"
        )})
    )
    true
}

private let gatewayModelMemoryHealthyPackageBaseline = gatewayInstallModelMemoryHealthyPackageBaseline()

@Test
public class GatewayModelMemoryAdmissionPackageBaselineTest {
    @TestCase
    public func s3BU0CorePackageUsesHealthyAdmissionBaseline(): Unit {
        try {
            let permit = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            @Expect(permit.release(), true)
            @Expect(gatewayModelMemoryAdmissionSnapshotForTest().lastMaxHeapBytes, 2 * GATEWAY_MODEL_MEMORY_TEST_GIB)
        } finally {
            resetGatewayModelMemoryAdmissionForTest()
            let _ = gatewayInstallModelMemoryHealthyPackageBaseline()
        }
    }

    @TestCase
    public func s3BU0ExplicitDefaultProviderUsesRealRuntimeHeapSnapshot(): Unit {
        resetGatewayModelMemoryAdmissionForTest()
        try {
            let runtime = gatewayRuntimeHeapSnapshot()
            @Expect(runtime.managedHeapStatus, "ok")
            @Expect(runtime.maxHeapBytes, 64 * 1024 * 1024)
            @Expect(runtime.managedHeapAvailableBytes,
                runtime.maxHeapBytes - runtime.managedHeapUsedBytes)
            @Expect(runtime.managedHeapAvailableBytes >= 0, true)
            @Expect(runtime.managedHeapAvailableBytes <= runtime.maxHeapBytes, true)
            var rejected = false
            try {
                let _ = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            } catch (error: GatewayModelMemoryPressureException) {
                rejected = true
                @Expect(error.status, "heap_pressure")
                @Expect(error.maxHeapBytes, 64 * 1024 * 1024)
                @Expect(error.reserveBytes, 256 * 1024 * 1024)
                let rejectedTruth = gatewayModelMemoryAdmissionSnapshotForTest()
                @Expect(error.maxHeapBytes, rejectedTruth.lastMaxHeapBytes)
                @Expect(error.availableBytes, rejectedTruth.lastAvailableBytes)
            }
            @Expect(rejected, true)
            let truth = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(truth.lastStatus, "heap_pressure")
            @Expect(truth.lastMaxHeapBytes, 64 * 1024 * 1024)
            @Expect(truth.lastAvailableBytes >= 0, true)
            @Expect(truth.lastAvailableBytes <= truth.lastMaxHeapBytes, true)
            @Expect(truth.lastReserveBytes, 256 * 1024 * 1024)
            @Expect(truth.active, 0)
        } finally {
            resetGatewayModelMemoryAdmissionForTest()
            let _ = gatewayInstallModelMemoryHealthyPackageBaseline()
        }
    }
}
