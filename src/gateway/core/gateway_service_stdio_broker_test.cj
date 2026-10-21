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
import std.time.{DateTime, MonoTime}
import std.core.Duration
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private class GatewayShutdownFakeClock {
    var now: MonoTime
    init(now: MonoTime) { this.now = now }
}

private class GatewayServiceStdioTestBoolBox {
    var value = false
}

private class GatewayServiceStopObserverProof {
    let phases = ArrayList<String>()
    var ownersCalled = false
    var channelsCalled = false
    var brokerCalled = false
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
    public func hrS1U3PreservesBrokerExternalTerminalThroughGatewayStop(): Unit {
        for (terminal in [false, true]) {
            let result = gatewayServiceStopOwnersThenBroker(
                { => ServicePluginHostShutdownResult(true, "stopped", ArrayList<ServiceStopResult>()) },
                { => GatewayChannelStopSummary(true, "stopped") },
                { => ManagedStdioOperationResult(false, "broker_close_exit_nonzero",
                    externalTerminal: terminal, terminalBasis: if (terminal) { "closed_ack_exit_observed" } else { "unknown" }) })
            @Expect(result.ok, false)
            @Expect(result.status, "cleanup_pending")
            @Expect(result.brokerStatus, "broker_close_exit_nonzero")
            @Expect(result.brokerExternalTerminal, terminal)
            @Expect(result.brokerTerminalBasis, if (terminal) { "closed_ack_exit_observed" } else { "unknown" })
        }
    }

    @TestCase
    public func hbBrN7StopObserverReportsOrderedBoundariesAndIsFailureIsolated(): Unit {
        let expectedPhases = "owners_enter,owners_done,channels_enter,channels_done,broker_enter,broker_done"
        for (failure in ["none", "owners", "channels", "broker", "observer"]) {
            let proof = GatewayServiceStopObserverProof()
            let result = gatewayServiceStopOwnersThenBroker(
                { =>
                    proof.ownersCalled = true
                    if (failure == "owners") { throw Exception("injected-owner-stop-failure") }
                    ServicePluginHostShutdownResult(true, "stopped", ArrayList<ServiceStopResult>())
                },
                { =>
                    proof.channelsCalled = true
                    if (failure == "channels") { throw Exception("injected-channel-stop-failure") }
                    GatewayChannelStopSummary(true, "stopped")
                },
                { =>
                    proof.brokerCalled = true
                    if (failure == "broker") { throw Exception("injected-broker-stop-failure") }
                    ManagedStdioOperationResult(true, "stopped")
                },
                shutdownObserver: Some<(String) -> Unit>({ phase: String =>
                    proof.phases.add(phase)
                    if (failure == "observer") { throw Exception("injected-observer-failure") }
                })
            )
            @Expect(String.join(proof.phases.toArray(), delimiter: ","), expectedPhases)
            @Expect(proof.ownersCalled, true)
            @Expect(proof.channelsCalled, true)
            @Expect(proof.brokerCalled, true)
            @Expect(result.ok, failure == "none" || failure == "observer")
            @Expect(result.ownersStatus, if (failure == "owners") { "owners_failed" } else { "stopped" })
            @Expect(result.channelsStatus, if (failure == "channels") { "channels_failed" } else { "stopped" })
            @Expect(result.brokerStatus, if (failure == "broker") { "broker_failed" } else { "stopped" })
        }
    }

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
    @TestCase
    public func s2U1FakeClockPhasesKeepBrokerLastAndReserveCompletion(): Unit {
        let origin = MonoTime.now()
        let deadline = origin + Duration.second * 54
        let ownerDeadline = deadline - Duration.second * 2
        let clock = GatewayShutdownFakeClock(origin)
        let remaining = ArrayList<Int64>()
        let phases = ArrayList<String>()
        let consume = { name: String, cost: Int64 =>
            phases.add(name)
            remaining.add(gatewayShutdownRemainingMs(ownerDeadline, now: clock.now))
            clock.now = clock.now + Duration.millisecond * cost
        }
        consume("cron", 3000)
        consume("http", 2000)
        let result = gatewayServiceStopOwnersThenBroker({ =>
            consume("plugin", 30000)
            ServicePluginHostShutdownResult(true, "stopped", ArrayList<ServiceStopResult>())
        }, { =>
            consume("channel", 17000)
            GatewayChannelStopSummary(true, "stopped")
        }, { =>
            phases.add("broker")
            @Expect(gatewayShutdownRemainingMs(deadline, capMs: 2000, now: clock.now), 2000)
            clock.now = clock.now + Duration.second * 2
            ManagedStdioOperationResult(true, "stopped")
        })
        phases.add("completion")
        @Expect(result.ok, true)
        @Expect(String.join(phases.toArray(), delimiter: ","), "cron,http,plugin,channel,broker,completion")
        @Expect(remaining[0], 52000)
        @Expect(remaining[1], 49000)
        @Expect(remaining[2], 47000)
        @Expect(remaining[3], 17000)
        @Expect(55000 - (clock.now - origin).toMilliseconds(), 1000)
    }

    @TestCase
    public func s2N1PendingChannelCountCannotBeMaskedByAnOkFlag(): Unit {
        let result = gatewayServiceStopOwnersThenBroker(
            { => ServicePluginHostShutdownResult(true, "stopped", ArrayList<ServiceStopResult>()) },
            { => GatewayChannelStopSummary(true, "stopped", pendingCount: 1) },
            { => ManagedStdioOperationResult(true, "stopped") })
        @Expect(result.ok, false)
        @Expect(result.status, "cleanup_pending")
        @Expect(result.channelPendingCount, 1)
    }

    @TestCase
    public func s2N1PostBrokerReapPreservesOnlySameCallConcretePendingEvidence(): Unit {
        let priorRows = ArrayList<ServiceStopResult>()
        priorRows.add(ServiceStopResult(false, "service-a", "cleanup_pending", diagnostic: "prior-evidence",
            ingressStopStatus: "sent", dispatchStatus: "cleanup_pending", ownerStopStatus: "terminated",
            leaseStatus: "cleanup_pending", portStatus: "cleanup_pending"))
        let previous = ServicePluginHostShutdownResult(false, "cleanup_pending", priorRows)
        let genericRows = ArrayList<ServiceStopResult>()
        genericRows.add(ServiceStopResult(false, "service-a", "cleanup_pending"))
        let kept = gatewayServiceSelectPluginShutdownEvidence(previous, ServicePluginHostShutdownResult(false, "cleanup_pending", genericRows))
        @Expect(kept.ok, false)
        @Expect(kept.status, "cleanup_pending")
        @Expect(kept.results[0].ok, false)
        @Expect(kept.results[0].ingressStopStatus, "sent")
        @Expect(kept.results[0].ownerStopStatus, "terminated")
        @Expect(kept.results[0].diagnostic, "prior-evidence")
        for (id in ["service-b", "service-a"]) {
            for (status in ["running", "unknown"]) {
                let rows = ArrayList<ServiceStopResult>()
                rows.add(ServiceStopResult(false, id, "cleanup_pending", ownerStopStatus: status))
                let latest = gatewayServiceSelectPluginShutdownEvidence(previous, ServicePluginHostShutdownResult(false, "cleanup_pending", rows))
                @Expect(latest.results[0].ownerStopStatus, status)
            }
        }
        let changed = ArrayList<ServiceStopResult>()
        changed.add(ServiceStopResult(false, "service-b", "cleanup_pending"))
        @Expect(gatewayServiceSelectPluginShutdownEvidence(previous, ServicePluginHostShutdownResult(false, "cleanup_pending", changed)).results[0].serviceId, "service-b")
        let duplicated = ArrayList<ServiceStopResult>()
        duplicated.add(priorRows[0]); duplicated.add(priorRows[0])
        let duplicateLatest = ArrayList<ServiceStopResult>()
        duplicateLatest.add(genericRows[0]); duplicateLatest.add(genericRows[0])
        @Expect(gatewayServiceSelectPluginShutdownEvidence(ServicePluginHostShutdownResult(false, "cleanup_pending", duplicated),
            ServicePluginHostShutdownResult(false, "cleanup_pending", duplicateLatest)).results[0].ownerStopStatus, "not_started")
        let uniquePrevious = ArrayList<ServiceStopResult>()
        uniquePrevious.add(priorRows[0])
        uniquePrevious.add(ServiceStopResult(false, "service-b", "cleanup_pending", ownerStopStatus: "terminated"))
        @Expect(gatewayServiceSelectPluginShutdownEvidence(ServicePluginHostShutdownResult(false, "cleanup_pending", uniquePrevious),
            ServicePluginHostShutdownResult(false, "cleanup_pending", duplicateLatest)).results[0].ownerStopStatus, "not_started")
        let terminalRows = ArrayList<ServiceStopResult>()
        terminalRows.add(ServiceStopResult(true, "service-a", "stopped", ingressStopStatus: "sent", dispatchStatus: "drained",
            ownerStopStatus: "terminated", leaseStatus: "stopped", portStatus: "released"))
        let terminal = gatewayServiceSelectPluginShutdownEvidence(previous, ServicePluginHostShutdownResult(true, "stopped", terminalRows))
        @Expect(terminal.ok, true)
        @Expect(terminal.results[0].leaseStatus, "stopped")
    }

    @TestCase
    public func s2N1MixedPluginReapKeepsRowsBoundToTheirOwnService(): Unit {
        let old = ArrayList<ServiceStopResult>()
        old.add(ServiceStopResult(false, "service-a", "cleanup_pending", diagnostic: "owner-a",
            ingressStopStatus: "sent", ownerStopStatus: "terminated", leaseStatus: "cleanup_pending", portStatus: "cleanup_pending"))
        old.add(ServiceStopResult(true, "service-b", "not_applicable", ownerStopStatus: "not_applicable"))
        let before = ServicePluginHostShutdownResult(false, "cleanup_pending", old)
        let rows = ArrayList<ServiceStopResult>()
        rows.add(ServiceStopResult(false, "service-a", "cleanup_pending"))
        rows.add(ServiceStopResult(true, "service-b", "not_applicable", ingressStopStatus: "not_applicable",
            dispatchStatus: "not_applicable", ownerStopStatus: "not_applicable", leaseStatus: "not_applicable", portStatus: "not_applicable"))
        let mixed = gatewayServiceSelectPluginShutdownEvidence(before, ServicePluginHostShutdownResult(false, "cleanup_pending", rows))
        @Expect(mixed.ok, false)
        @Expect(mixed.status, "cleanup_pending")
        @Expect(mixed.results[0].serviceId, "service-a")
        @Expect(mixed.results[0].ingressStopStatus, "sent")
        @Expect(mixed.results[0].ownerStopStatus, "terminated")
        @Expect(mixed.results[0].diagnostic, "owner-a")
        @Expect(mixed.results[1].ok, true)
        @Expect(mixed.results[1].ingressStopStatus, "not_applicable")
        for (state in ["running", "unknown"]) {
            let latest = ArrayList<ServiceStopResult>()
            latest.add(rows[0])
            latest.add(ServiceStopResult(false, "service-b", "cleanup_pending", ownerStopStatus: state))
            let selected = gatewayServiceSelectPluginShutdownEvidence(before, ServicePluginHostShutdownResult(false, "cleanup_pending", latest))
            @Expect(selected.ok, false)
            @Expect(selected.results[0].ownerStopStatus, "terminated")
            @Expect(selected.results[1].ownerStopStatus, state)
        }
        let generic = ArrayList<ServiceStopResult>()
        generic.add(rows[0]); generic.add(ServiceStopResult(false, "service-b", "cleanup_pending"))
        let failed = gatewayServiceSelectPluginShutdownEvidence(before, ServicePluginHostShutdownResult(false, "cleanup_pending", generic))
        @Expect(failed.results[1].ok, false)
        @Expect(failed.results[1].ownerStopStatus, "not_started")
    }

    @TestCase
    public func s2N1UnknownEmptyHostResultCannotClaimNoResources(): Unit {
        for (ok in [false, true]) {
            let result = gatewayServiceStopOwnersThenBroker(
                { => ServicePluginHostShutdownResult(ok, if (ok) { "stopped" } else { "cleanup_pending" }, ArrayList<ServiceStopResult>()) },
                { => GatewayChannelStopSummary(true, "stopped") },
                { => ManagedStdioOperationResult(true, "stopped") })
            @Expect(result.ok, ok)
            @Expect(result.servicePluginPendingCount, if (ok) { 0 } else { 1 })
            for (status in [result.servicePluginIngressStatus, result.servicePluginDispatchStatus, result.servicePluginOwnerStatus,
                result.servicePluginLeaseStatus, result.servicePluginPortStatus]) {
                @Expect(status, if (ok) { "not_applicable" } else { "cleanup_pending" })
            }
        }
    }

}
