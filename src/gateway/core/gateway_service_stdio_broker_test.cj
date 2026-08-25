package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.model.ChannelPolicyConfig
import metis.gateway.process.{gatewayStdioBrokerReady, gatewayStdioBrokerSnapshot}
import metis.gateway.service_plugin.{ServicePluginHostShutdownResult, ServiceStopResult}
import metis.process.{ManagedStdioOperationResult, resetManagedStdioBrokerForTest}
import magic.jsonable.*
import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private class GatewayServiceStdioTestBoolBox {
    var value = false
}

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
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
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
    public func s4U1DisabledAndAlreadyStoppedOwnersAreTerminalButErrorsRemainFailures(): Unit {
        for (field in ["status", "state"]) {
            for (status in ["disabled", "already_stopped", "not_applicable"]) {
                let terminal = JsonObject()
                terminal.put("ok", false.toJsonValue())
                terminal.put(field, JsonString(status))
                let parsed = gatewayServiceStopJsonStatus(terminal)
                @Expect(parsed[0], true)
                @Expect(parsed[1], status)
            }
        }

        for (status in ["error", "cleanup_pending", "unknown"]) {
            let failed = JsonObject()
            failed.put("ok", false.toJsonValue())
            failed.put("status", JsonString(status))
            let parsed = gatewayServiceStopJsonStatus(failed)
            @Expect(parsed[0], false)
            @Expect(parsed[1], status)
        }
    }

    @TestCase
    public func p1N3RealGatewayStopIsBoundedWhenNodeIsUnavailable(): Unit {
        withGatewayStdioBrokerTestHome<Unit>({ =>
            let unavailable = gatewayStdioBrokerReady(timeoutMs: 100)
            @Expect(unavailable.ok, false)
            @Expect(unavailable.status, "broker_unavailable")
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let stopped = service.stop()
            @Expect(DateTime.now().toUnixTimeStamp().toMilliseconds() - started < 2000, true)
            @Expect(stopped.ok, true)
            @Expect(stopped.status, "stopped")
            @Expect(stopped.brokerStatus, "already_stopped")
            let snapshot = gatewayStdioBrokerSnapshot()
            @Expect(snapshot.get("running").getOrThrow().asBool().getValue(), false)
            @Expect(snapshot.get("readerCount").getOrThrow().asInt().getValue(), 0)
        })
    }

    @TestCase
    public func p1N3OwnerStopFailureStillRunsBrokerFinally(): Unit {
        let brokerCalled = GatewayServiceStdioTestBoolBox()
        let channelsCalled = GatewayServiceStdioTestBoolBox()
        let result = gatewayServiceStopOwnersThenBroker(
            { => throw Exception("injected-owner-stop-failure") },
            { =>
                channelsCalled.value = true
                GatewayChannelStopSummary(true, "stopped")
            },
            { =>
                brokerCalled.value = true
                ManagedStdioOperationResult(true, "stopped")
            }
        )
        @Expect(result.ok, false)
        @Expect(result.status, "cleanup_pending")
        @Expect(result.ownersStatus, "owners_failed")
        @Expect(result.channelsStatus, "stopped")
        @Expect(result.brokerStatus, "stopped")
        @Expect(channelsCalled.value, true)
        @Expect(brokerCalled.value, true)
    }

    @TestCase
    public func s4N1OwnersChannelsAndBrokerFailuresRemainIndependent(): Unit {
        let owners = ArrayList<ServiceStopResult>()
        owners.add(ServiceStopResult(
            false,
            "fake-gcm",
            "cleanup_pending",
            ingressStopStatus: "sent",
            dispatchStatus: "dispatch_pending",
            ownerStopStatus: "timeout",
            leaseStatus: "running",
            portStatus: "port_release_timeout"
        ))
        let result = gatewayServiceStopOwnersThenBroker(
            { => ServicePluginHostShutdownResult(false, "cleanup_pending", owners) },
            { => GatewayChannelStopSummary(false, "stop_failed", total: 1, failed: 1) },
            { => throw Exception("injected-broker-writer-failure") }
        )
        @Expect(result.ok, false)
        @Expect(result.status, "cleanup_pending")
        @Expect(result.ownersStatus, "cleanup_pending")
        @Expect(result.channelsStatus, "stop_failed")
        @Expect(result.brokerStatus, "broker_failed")
        @Expect(result.servicePluginIngressStatus, "sent")
        @Expect(result.servicePluginDispatchStatus, "cleanup_pending")
        @Expect(result.servicePluginOwnerStatus, "cleanup_pending")
        @Expect(result.servicePluginLeaseStatus, "cleanup_pending")
        @Expect(result.servicePluginPortStatus, "cleanup_pending")
        @Expect(result.servicePluginPendingCount, 1)
        @Expect(result.diagnostic.contains("owners=cleanup_pending"), true)
        @Expect(result.diagnostic.contains("channels=stop_failed"), true)
        @Expect(result.diagnostic.contains("broker=broker_failed"), true)
    }
}
