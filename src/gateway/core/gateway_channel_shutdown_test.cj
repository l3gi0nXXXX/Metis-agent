package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest}
import metis.gateway.model.{ChannelPolicyConfig, InboundMessage, OutboundMessage, SendResult}
import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.sync.{Condition, Mutex}
import std.time.{DateTime, MonoTime}
import std.core.Duration
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

private class ShutdownLifecycleCounts {
    var compat: Int64 = 0
    var sidecar: Int64 = 0
}

private func shutdownLifecycleResult(status: String): JsonObject {
    let result = JsonObject()
    result.put("ok", JsonBool(true))
    result.put("status", JsonString(status))
    result
}

private class ChannelShutdownBarrier {
    private let lock = Mutex()
    private var condition: Condition
    var begins: Int64 = 0
    var leastBeginsAtAwait: Int64 = 100
    var stops: Int64 = 0
    private var released = false
    init() { synchronized(this.lock) { this.condition = this.lock.condition() } }
    func begin(): Unit { synchronized(this.lock) { this.begins += 1 } }
    func wait(deadline: MonoTime, bounded: Bool): Bool {
        synchronized(this.lock) {
            this.stops += 1
            this.leastBeginsAtAwait = min(this.leastBeginsAtAwait, this.begins)
            while (!this.released) {
                let remaining = (deadline - MonoTime.now()).toMilliseconds()
                if (bounded && remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * if (bounded) { remaining } else { 100 })
            }
            true
        }
    }
    func release(): Unit { synchronized(this.lock) { this.released = true; this.condition.notifyAll() } }
}

private open class ShutdownLegacyAdapter <: ChannelAdapter {
    let barrier: ChannelShutdownBarrier
    var starts: Int64 = 0
    init(barrier: ChannelShutdownBarrier) { this.barrier = barrier }
    public prop name: String { get() { "qq" } }
    public func start(): Unit { this.starts += 1 }
    public open func stop(): Unit { let _ = this.barrier.wait(MonoTime.now(), false) }
    public func pullInbound(): Array<InboundMessage> { [] }
    public func send(_message: OutboundMessage): SendResult { SendResult.Success }
    public func sendWithMessageId(_message: OutboundMessage): String { "" }
}

private class ShutdownBoundedAdapter <: ShutdownLegacyAdapter & GatewayBoundedChannelShutdown {
    var diagnostic = ""
    var pendingReturns: Int64 = 0
    var failBegin: Bool
    init(barrier: ChannelShutdownBarrier, failBegin!: Bool = false) { super(barrier); this.failBegin = failBegin }
    public func beginShutdown(_deadline: MonoTime): Unit {
        this.barrier.begin()
        if (this.failBegin) { throw Exception("begin failed 中文🧪") }
    }
    public func awaitShutdown(deadline: MonoTime): GatewayChannelShutdownResult {
        let done = this.barrier.wait(deadline, true)
        if (!done) { this.pendingReturns += 1 }
        GatewayChannelShutdownResult(done, if (done) { "stopped" } else { "cleanup_pending" }, pendingCount: if (done) { 0 } else { 1 }, diagnostic: this.diagnostic)
    }
}

private func withChannelShutdownHome(block: () -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-channel-shutdown-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(home, recursive: false)
        let old = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try { block() } finally {
            match (old) { case Some(value) => setVariable("METIS_HOME", value) case None => removeVariable("METIS_HOME") }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            remove(home, recursive: true)
        }
    }
}

@Test
public class GatewayChannelShutdownTest {
    @TestCase
    public func s2B1FiveAccountsBroadcastBeforeSharedDeadlineAndReap(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            let manager = GatewayChannelManager()
            let adapters = ArrayList<ShutdownBoundedAdapter>()
            for (i in 0..5) {
                let adapter = ShutdownBoundedAdapter(barrier)
                adapters.add(adapter)
                manager.registerAdapter(adapter, channelId: "qq", accountId: "budget-${i}")
            }
            let _ = manager.startChannels()
            try {
                let began = MonoTime.now()
                let pending = manager.stopChannelsDetailed(deadline: began + Duration.millisecond * 100)
                @Expect((MonoTime.now() - began).toMilliseconds() < 500, true)
                @Expect(barrier.begins, 5)
                @Expect(barrier.leastBeginsAtAwait, 5)
                @Expect(pending.ok, false)
                @Expect(pending.pendingCount, 5)
                @Expect(manager.startChannel("qq").get("ok").getOrThrow().asBool().getValue(), false)
                let _ = manager.startChannels()
                for (adapter in adapters) { @Expect(adapter.starts, 1) }
                barrier.release()
                let stopped = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second * 2)
                @Expect(stopped.ok, true)
                @Expect(stopped.pendingCount, 0)
                @Expect(stopped.stopped, 5)
            } finally {
                barrier.release()
                let _ = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second * 2)
            }
        })
    }

    @TestCase
    public func s2B1LegacyStopRetainsFutureAndNeverCallsStopTwice(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            let adapter = ShutdownLegacyAdapter(barrier)
            let manager = GatewayChannelManager()
            manager.registerAdapter(adapter, channelId: "qq", accountId: "legacy")
            let _ = manager.startChannels()
            try {
                let pending = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.millisecond * 50)
                @Expect(pending.pendingCount, 1)
                let _ = manager.stopChannelsDetailed(deadline: MonoTime.now())
                @Expect(manager.startChannel("qq").get("ok").getOrThrow().asBool().getValue(), false)
                @Expect(adapter.starts, 1)
                @Expect(barrier.stops, 1)
                barrier.release()
                @Expect(manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second * 2).ok, true)
                @Expect(barrier.stops, 1)
            } finally {
                barrier.release()
                let _ = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second * 2)
            }
        })
    }

    @TestCase
    public func s2N1BeginFailureCannotBecomeFalseStopped(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            barrier.release()
            let manager = GatewayChannelManager()
            let adapter = ShutdownBoundedAdapter(barrier, failBegin: true)
            manager.registerAdapter(adapter, channelId: "qq", accountId: "throws")
            let _ = manager.startChannels()
            let result = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second)
            @Expect(result.ok, false)
            @Expect(result.pendingCount, 1)
            @Expect(manager.startChannel("qq").get("ok").getOrThrow().asBool().getValue(), false)
            adapter.failBegin = false
            @Expect(manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second).ok, true)
        })
    }

    @TestCase
    public func s2P1ServiceTwoGenerationsNeverReuseTheOldSuccessfulStop(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            barrier.release()
            let adapter = ShutdownBoundedAdapter(barrier)
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            service.registerAdapter(adapter, channelId: "qq", accountId: "two-generations")
            service.start()
            @Expect(service.stop(deadline: MonoTime.now() + Duration.second * 3).ok, true)
            @Expect(barrier.stops, 1)
            service.start()
            @Expect(adapter.starts, 2)
            @Expect(service.stop(deadline: MonoTime.now() + Duration.second * 3).ok, true)
            @Expect(barrier.stops, 2)
        })
    }

    @TestCase
    public func s2N1ServiceHeldReleaseReapsBeforeItAllowsRestart(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            let adapter = ShutdownBoundedAdapter(barrier)
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            service.registerAdapter(adapter, channelId: "qq", accountId: "held-service")
            service.start()
            try {
                let result = service.stop(deadline: MonoTime.now() + Duration.millisecond * 2100)
                @Expect(result.ok, false)
                var rejected = false
                try { service.start() } catch (e: Exception) { rejected = e.message == "gateway_shutdown_pending" }
                @Expect(rejected, true)
                barrier.release()
                @Expect(service.stop(deadline: MonoTime.now() + Duration.second * 3).ok, true)
                service.start()
                @Expect(adapter.starts, 2)
                @Expect(service.stop(deadline: MonoTime.now() + Duration.second * 3).ok, true)
            } finally {
                barrier.release()
                let _ = service.stop(deadline: MonoTime.now() + Duration.second * 3)
            }
        })
    }
    @TestCase
    public func s2P1OptionalDiagnosticIsPreservedWithoutChangingSuccessfulStop(): Unit {
        withChannelShutdownHome({ =>
            let oldLevel = getVariable("METIS_CONSOLE_LEVEL")
            setVariable("METIS_CONSOLE_LEVEL", "info")
            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            let barrier = ChannelShutdownBarrier()
            barrier.release()
            let adapter = ShutdownBoundedAdapter(barrier)
            adapter.diagnostic = "optional_confirmation_failed 中文🧪"
            let manager = GatewayChannelManager()
            manager.registerAdapter(adapter, channelId: "qq", accountId: "optional-diagnostic")
            try {
                let _ = manager.startChannels()
                @Expect(manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second).ok, true)
                let captured = String.join(gatewayLoggingCapturedConsoleForTest(), delimiter: "\n")
                @Expect(captured.contains("optional_confirmation_failed"), true)
            } finally {
                match (oldLevel) { case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value) case None => removeVariable("METIS_CONSOLE_LEVEL") }
                gatewayLoggingResetForTest()
            }
        })
    }

    @TestCase
    public func s2N1CompatAndSidecarExceptionsCanBeReapedOnRetry(): Unit {
        withChannelShutdownHome({ =>
            let calls = ShutdownLifecycleCounts()
            setGatewayOpenClawCompatHostLifecycleHooks(
                Some<(GatewayUserSettings) -> JsonObject>({ _: GatewayUserSettings => shutdownLifecycleResult("running") }),
                Some<(GatewayUserSettings) -> JsonObject>({ _: GatewayUserSettings =>
                    calls.compat += 1
                    if (calls.compat == 1) { throw Exception("injected compat stop") }
                    shutdownLifecycleResult("stopped")
                }))
            setGatewayOpenClawPluginSidecarRunnerForTest(Some<(String, JsonObject) -> JsonObject>({ method: String, _: JsonObject =>
                if (method == "lifecycle.stop") {
                    calls.sidecar += 1
                    if (calls.sidecar == 1) { throw Exception("injected sidecar stop") }
                    shutdownLifecycleResult("stopped")
                } else { shutdownLifecycleResult("running") }
            }))
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            try {
                service.start()
                @Expect(service.stop(deadline: MonoTime.now() + Duration.second * 3).ok, false)
                @Expect(service.stop(deadline: MonoTime.now() + Duration.second * 3).ok, true)
                @Expect(calls.compat, 2)
                @Expect(calls.sidecar, 2)
            } finally {
                setGatewayOpenClawCompatHostLifecycleHooks(None<(GatewayUserSettings) -> JsonObject>, None<(GatewayUserSettings) -> JsonObject>)
                setGatewayOpenClawPluginSidecarRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            }
        })
    }

    @TestCase
    public func s2B1RemovedRegistrationStillOwnsThePendingLegacyFuture(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            let adapter = ShutdownLegacyAdapter(barrier)
            let manager = GatewayChannelManager()
            manager.registerAdapter(adapter, channelId: "qq", accountId: "removed-legacy")
            let _ = manager.startChannels()
            try {
                @Expect(manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.millisecond * 50).pendingCount, 1)
                manager.clearChannelRegistrations("qq")
                let removed = manager.stopChannelsDetailed(deadline: MonoTime.now())
                @Expect(removed.ok, false)
                @Expect(removed.total, 1)
                @Expect(removed.pendingCount, 1)
                @Expect(barrier.stops, 1)
                barrier.release()
                let reaped = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second * 2)
                @Expect(reaped.ok, true)
                @Expect(reaped.pendingCount, 0)
                @Expect(barrier.stops, 1)
            } finally {
                barrier.release()
                let _ = manager.stopChannelsDetailed(deadline: MonoTime.now() + Duration.second * 2)
            }
        })
    }

    @TestCase
    public func s2P1LateCooperativeOwnerIsReapedWithinTheRemainingBudget(): Unit {
        withChannelShutdownHome({ =>
            let barrier = ChannelShutdownBarrier()
            setGatewayOpenClawCompatHostLifecycleHooks(
                Some<(GatewayUserSettings) -> JsonObject>({ _: GatewayUserSettings => shutdownLifecycleResult("running") }),
                Some<(GatewayUserSettings) -> JsonObject>({ _: GatewayUserSettings =>
                    let _ = barrier.wait(MonoTime.now(), false)
                    shutdownLifecycleResult("stopped")
                }))
            let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
            let adapter = ShutdownBoundedAdapter(barrier)
            service.registerAdapter(adapter, channelId: "qq", accountId: "late-cooperative")
            let releaser = spawn { sleep(Duration.millisecond * 150); barrier.release() }
            try {
                service.start()
                let stopped = service.stop(deadline: MonoTime.now() + Duration.millisecond * 2100)
                @Expect(stopped.ok, true)
                @Expect(stopped.compatStatus, "stopped")
                @Expect(adapter.pendingReturns > 0, true)
                @Expect(stopped.channelPendingCount, 0)
                @Expect(stopped.channelsStatus, "stopped")
            } finally {
                barrier.release()
                releaser.get(Duration.second)
                setGatewayOpenClawCompatHostLifecycleHooks(None<(GatewayUserSettings) -> JsonObject>, None<(GatewayUserSettings) -> JsonObject>)
            }
        })
    }

}
