package metis.gateway.runtime

import metis.gateway.core.{GatewayModelMemoryAdmissionSource, GatewayRuntimeHeapSnapshot, gatewayModelMemoryAdmissionSnapshotForTest, gatewayTryAcquireModelMemoryAdmission, resetGatewayModelMemoryAdmissionForTest, setGatewayModelMemoryAdmissionSnapshotProviderForTest}

import std.unittest.testmacro.*

private const GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB: Int64 = 1024 * 1024 * 1024

private func gatewayInstallRuntimeModelMemoryHealthyPackageBaseline(): Bool {
    setGatewayModelMemoryAdmissionSnapshotProviderForTest(
        Some({=> GatewayRuntimeHeapSnapshot(
            2 * GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB,
            GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB,
            GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB,
            50,
            "ok",
            1,
            "ok"
        )})
    )
    true
}

private let gatewayRuntimeModelMemoryHealthyPackageBaseline = gatewayInstallRuntimeModelMemoryHealthyPackageBaseline()

@Test
public class GatewayRuntimeModelMemoryAdmissionPackageBaselineTest {
    @TestCase
    public func s3BU0RuntimePackageUsesHealthyAdmissionBaseline(): Unit {
        try {
            let permit = gatewayTryAcquireModelMemoryAdmission(GatewayModelMemoryAdmissionSource.Ordinary)
            @Expect(permit.release(), true)
            @Expect(
                gatewayModelMemoryAdmissionSnapshotForTest().lastMaxHeapBytes,
                2 * GATEWAY_MODEL_MEMORY_RUNTIME_TEST_GIB
            )
        } finally {
            resetGatewayModelMemoryAdmissionForTest()
            let _ = gatewayInstallRuntimeModelMemoryHealthyPackageBaseline()
        }
    }
}
