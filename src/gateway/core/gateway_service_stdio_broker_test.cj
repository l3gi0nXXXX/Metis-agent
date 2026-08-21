package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.model.ChannelPolicyConfig
import metis.gateway.process.{gatewayStdioBrokerReady, gatewayStdioBrokerSnapshot}
import metis.process.ManagedStdioOperationResult
import std.collection.HashMap
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func withGatewayStdioBrokerTestHome<T>(block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-gateway-stdio-stop-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        let oldNode = getVariable("METIS_STDIO_BROKER_NODE_COMMAND")
        setVariable("METIS_HOME", home.toString())
        setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "metis-node-command-does-not-exist")
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            match (oldNode) {
                case Some(value) => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", value)
                case None => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class GatewayServiceStdioBrokerTest {
    @TestCase
    public func p1N3RealGatewayStopIsBoundedWhenNodeIsUnavailable(): Unit {
        withGatewayStdioBrokerTestHome<Unit>({ =>
            let unavailable = gatewayStdioBrokerReady(timeoutMs: 100)
            @Expect(unavailable.ok, false)
            @Expect(unavailable.status, "broker_unavailable")
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
            service.stop()
            @Expect(DateTime.now().toUnixTimeStamp().toMilliseconds() - started < 2000, true)
            let snapshot = gatewayStdioBrokerSnapshot()
            @Expect(snapshot.get("running").getOrThrow().asBool().getValue(), false)
            @Expect(snapshot.get("readerCount").getOrThrow().asInt().getValue(), 0)
        })
    }

    @TestCase
    public func p1N3OwnerStopFailureStillRunsBrokerFinally(): Unit {
        var brokerCalled = false
        var caught = false
        try {
            gatewayServiceStopOwnersThenBroker(
                { => throw Exception("injected-owner-stop-failure") },
                { =>
                    brokerCalled = true
                    ManagedStdioOperationResult(true, "stopped")
                }
            )
        } catch (_: Exception) {
            caught = true
        }
        @Expect(caught, true)
        @Expect(brokerCalled, true)
    }
}
