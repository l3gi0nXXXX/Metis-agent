package metis.gateway.process

import std.unittest.testmacro.*

@Test
public class GatewayStdioBrokerFacadeTest {
    @TestCase
    public func p1U1FacadeDelegatesReadinessSnapshotAndIdempotentShutdown(): Unit {
        let ready = gatewayStdioBrokerReady(timeoutMs: 1000)
        @Expect(ready.ok, true)
        let snapshot = gatewayStdioBrokerSnapshot()
        @Expect(snapshot.get("running").getOrThrow().asBool().getValue(), true)
        @Expect(snapshot.get("responsive").getOrThrow().asBool().getValue(), true)
        @Expect(snapshot.get("readerCount").getOrThrow().asInt().getValue(), 1)
        @Expect(shutdownGatewayStdioBroker(timeoutMs: 2000).ok, true)
        @Expect(shutdownGatewayStdioBroker(timeoutMs: 2000).ok, true)
        let stopped = gatewayStdioBrokerSnapshot()
        @Expect(stopped.get("running").getOrThrow().asBool().getValue(), false)
        @Expect(stopped.get("status").getOrThrow().asString().getValue(), "stopped")
        @Expect(stopped.get("readerCount").getOrThrow().asInt().getValue(), 0)
    }

}
