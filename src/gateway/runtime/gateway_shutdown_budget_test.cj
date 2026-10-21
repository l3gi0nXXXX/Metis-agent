package metis.gateway.runtime

import metis.core.memory.MemoryMaintenanceStopResult
import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import metis.gateway.core.{GatewayStopResult, gatewayShutdownRemainingMs}
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.sync.{Condition, Mutex}
import std.time.{DateTime, MonoTime}
import std.core.Duration
import std.unittest.testmacro.*

private class ShutdownMemoryProof {
    var requested = false
    var brokerClosed = false
    var settled = false
    var joined = false
}

private class ShutdownBudgetBarrier {
    private let lock = Mutex()
    private var condition: Condition
    private var entered = false
    private var released = false
    init() { synchronized(this.lock) { this.condition = this.lock.condition() } }
    func hold(): Unit {
        synchronized(this.lock) {
            this.entered = true; this.condition.notifyAll()
            while (!this.released) { let _ = this.condition.wait(timeout: Duration.second) }
        }
    }
    func waitEntered(): Bool {
        let deadline = MonoTime.now() + Duration.second * 2
        synchronized(this.lock) {
            while (!this.entered) {
                let remaining = (deadline - MonoTime.now()).toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }
    func release(): Unit { synchronized(this.lock) { this.released = true; this.condition.notifyAll() } }
}

private func withShutdownBudgetHome(block: (Path) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-shutdown-budget-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(home, recursive: false)
        let old = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        try { block(home) } finally {
            match (old) { case Some(value) => setVariable("METIS_HOME", value) case None => removeVariable("METIS_HOME") }
            CliConfig.invalidatePathCache()
            remove(home, recursive: true)
        }
    }
}

private func shutdownBudgetCompletion(home: Path, identity: GatewayServeIdentity): GatewayServeCompletionResult {
    let text = try { String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))) } catch (_: Exception) { "" }
    gatewayParseServeCompletion(text, identity)
}

@Test
public class GatewayShutdownBudgetTest {
    @TestCase
    public func s2U1FakeMonotonicPhasesConsumeOneBudgetAndPreserveReserves(): Unit {
        @Expect(GATEWAY_SERVE_GRACEFUL_SHUTDOWN_TIMEOUT_MS, 60000)
        @Expect(gatewayShutdownWorkRemainingMs(1000, 1000), 54000)
        @Expect(gatewayShutdownWorkRemainingMs(1000, 6000), 49000)
        @Expect(gatewayShutdownWorkRemainingMs(1000, 100000), 0)
        @Expect(gatewayShutdownWorkRemainingMs(1000, 500), 54000)
        let origin = MonoTime.now()
        let deadline = origin + Duration.millisecond * gatewayShutdownWorkRemainingMs(1000, 1000)
        var now = origin
        var previous: Int64 = 54000
        // cron/http/plugin/channel respectively consume 3s/2s/30s/17s.
        for (cost in [3000, 2000, 30000, 17000]) {
            now = now + Duration.millisecond * cost
            let remaining = gatewayShutdownRemainingMs(deadline, now: now)
            @Expect(remaining <= previous, true)
            previous = remaining
        }
        @Expect(previous, 2000)
        @Expect(gatewayShutdownRemainingMs(deadline, capMs: 2000, now: now), 2000)
        now = now + Duration.millisecond * 2000
        @Expect(gatewayShutdownRemainingMs(deadline, now: now), 0)
        // The original soft request window still has completion/exit reserve.
        @Expect(55000 - (now - origin).toMilliseconds(), 1000)
    }

    @TestCase
    public func s2N1ThrownAndHeldPhasesDoNotSkipLaterClosureAndRetainPending(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let owners = GatewayServeShutdownOwners()
            @Expect(owners.reap(), 0)
            let barrier = ShutdownBudgetBarrier()
            try {
                let failed = owners.run("state", MonoTime.now() + Duration.second, { => throw Exception("中文🧪") })
                @Expect(failed.status, "stop_failed")
                let pending = owners.run("http", MonoTime.now() + Duration.millisecond * 20, { =>
                    barrier.hold(); GatewaySurfaceStopResult(true, "stopped")
                })
                @Expect(barrier.waitEntered(), true)
                @Expect(pending.ok, false)
                @Expect(owners.reap(), 1)
                let broker = owners.run("broker", MonoTime.now() + Duration.second, { => GatewaySurfaceStopResult(true, "stopped") })
                @Expect(broker.ok, true)
                @Expect(owners.reap(), 1)
                barrier.release()
                @Expect(owners.result("http", pending).status == "cleanup_pending" || owners.result("http", pending).status == "stopped", true)
            } finally {
                barrier.release()
                let deadline = MonoTime.now() + Duration.second * 2
                while (owners.reap() > 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                @Expect(owners.reap(), 0)
            }
        }
    }

    @TestCase
    public func s2P1CompletionRequiresAllActualTerminalFactsAndHumanDiagnostic(): Unit {
        withShutdownBudgetHome({ home: Path =>
            let identity = GatewayServeIdentity(987654300, 1000, "budget-fixture")
            let terminal = GatewayStopResult(true, "stopped", channelsStatus: "stopped")
            @Expect(gatewayWriteServeCompletionMarker(identity, terminal, cronStatus: "stopped", memoryStatus: "stopped"), true)
            let completion = shutdownBudgetCompletion(home, identity)
            @Expect(completion.status, "graceful")
            @Expect(completion.fullTerminal, true)
            for (phase in ["cron", "memory", "canvas", "http", "server", "channels", "owners", "state"]) {
                let text = gatewayStopPhaseHumanText(phase)
                @Expect(text.startsWith("[网关]"), true)
                @Expect(text.contains("\"ok\"") || text.contains("\"result\""), false)
            }
            @Expect(gatewayStopPhaseHumanText("未知🧪"), "")
        })
    }

    @TestCase
    public func s2N1PendingOrUnknownFactsCannotWriteFullTerminal(): Unit {
        withShutdownBudgetHome({ home: Path =>
            let identity = GatewayServeIdentity(987654300, 1000, "budget-fixture")
            let apparentlyOk = GatewayStopResult(true, "stopped", channelPendingCount: 1)
            @Expect(gatewayWriteServeCompletionMarker(identity, apparentlyOk), true)
            var completion = shutdownBudgetCompletion(home, identity)
            @Expect(completion.fullTerminal, false)
            @Expect(completion.status, "cleanup_pending")
            let marker = try { String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))) } catch (_: Exception) { "" }
            let contradictory = marker.replace("fullTerminal:0", "fullTerminal:1").replace("status:cleanup_pending", "status:graceful")
            @Expect(gatewayParseServeCompletion(contradictory, identity).fullTerminal, false)
            @Expect(gatewayWriteServeCompletionMarker(identity, GatewayStopResult(true, "stopped"),
                shutdownPendingCount: 1, shutdownPhase: "http", cronStatus: "stopped", memoryStatus: "stopped"), true)
            completion = shutdownBudgetCompletion(home, identity)
            @Expect(completion.fullTerminal, false)
        })
    }
    @TestCase
    public func s2N1ReturnedPendingStillRetainsTheResourceOwner(): Unit {
        let owners = GatewayServeShutdownOwners()
        let result = owners.run("http", MonoTime.now() + Duration.second, { =>
            GatewaySurfaceStopResult(false, "cleanup_pending")
        })
        @Expect(result.status, "cleanup_pending")
        // The callback completed, but it did not prove its resource terminal.
        @Expect(owners.reap(), 1)
        @Expect(owners.result("http", GatewaySurfaceStopResult(true, "stopped")).ok, false)
        let nextGeneration = GatewayServeShutdownOwners()
        @Expect(nextGeneration.run("http", MonoTime.now() + Duration.second, { => GatewaySurfaceStopResult(true, "stopped") }).ok, true)
        @Expect(nextGeneration.reap(), 0)
        @Expect(owners.reap(), 1)
    }

    @TestCase
    public func s2N1SettledMemoryFailureDoesNotRetainAReleasedOwner(): Unit {
        let owners = GatewayServeShutdownOwners()
        let stopped = owners.run("memory", MonoTime.now() + Duration.second, { =>
            gatewayMemoryMaintenanceStopSurface(MemoryMaintenanceStopResult(false, "worker_failed", pendingCount: 0))
        })
        @Expect(stopped.ok, true)
        @Expect(stopped.status, "stopped")
        @Expect(owners.reap(), 0)
        @Expect(gatewayMemoryMaintenanceStopSurface(MemoryMaintenanceStopResult(false, "worker_failed", pendingCount: 1)).ok, false)
        @Expect(gatewayMemoryMaintenanceStopSurface(MemoryMaintenanceStopResult(false, "unknown", pendingCount: 0)).ok, false)
        @Expect(gatewayMemoryMaintenanceStopSurface(MemoryMaintenanceStopResult(false, "cleanup_pending", pendingCount: 1)).ok, false)
    }

    @TestCase
    public func s2U1HeldMemoryWaitsForBrokerBeforeItsActualJoin(): Unit {
        let barrier = ShutdownBudgetBarrier()
        let proof = ShutdownMemoryProof()
        let owners = GatewayServeShutdownOwners()
        let deadline = MonoTime.now() + Duration.second * 2
        let worker = spawn {
            try { barrier.hold() } finally { proof.settled = true }
        }
        try {
            @Expect(barrier.waitEntered(), true)
            proof.requested = true
            @Expect(proof.settled, false)
            @Expect(owners.run("canvas", deadline, { => GatewaySurfaceStopResult(true, "stopped") }).ok, true)
            @Expect(proof.settled, false)
            let broker = owners.run("broker", deadline, { =>
                @Expect(proof.requested, true)
                proof.brokerClosed = true
                barrier.release()
                GatewaySurfaceStopResult(true, "stopped")
            })
            @Expect(broker.ok, true)
            let memory = owners.run("memory", deadline, { =>
                @Expect(proof.brokerClosed, true)
                let remaining = gatewayShutdownRemainingMs(deadline)
                if (remaining == 0) { return GatewaySurfaceStopResult(false, "cleanup_pending") }
                worker.get(Duration.millisecond * remaining)
                @Expect(proof.settled, true)
                proof.joined = true
                GatewaySurfaceStopResult(true, "stopped")
            })
            @Expect(memory.ok, true)
            @Expect(proof.joined, true)
            @Expect(owners.reap(), 0)
            @Expect(gatewayShutdownRemainingMs(deadline) > 0, true)
        } finally {
            barrier.release()
            worker.get(Duration.second)
        }
    }

}
