package metis.gateway.core

import metis.core.config.CliConfig
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest}
import metis.gateway.model.{ChannelPolicyConfig, ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import magic.config.Config

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.core.Duration
import std.unittest.testmacro.*
import stdx.encoding.json.JsonObject

private func withGatewayServiceStartupTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-gateway-service-startup-test-home"
    try {
        remove(Path(testHome), recursive: true)
    } catch (_: Exception) {
        ()
    }
    Directory.create(testHome, recursive: true)
    let oldHome = getVariable("METIS_HOME")
    setVariable("METIS_HOME", testHome)
    CliConfig.invalidatePathCache()
    try {
        return block()
    } finally {
        match (oldHome) {
            case Some(value) => setVariable("METIS_HOME", value)
            case None => setVariable("METIS_HOME", "")
        }
        CliConfig.invalidatePathCache()
    }
}

private class GatewayServiceStartupFakeAdapter <: ChannelAdapter {
    private let adapterName: String
    private let startDelayMs: Int64
    private let failMessage: String
    private let stopFailure: String
    private let inbound = ArrayList<InboundMessage>()
    public var startCount: Int64 = 0
    public var stopCount: Int64 = 0
    public var pullCount: Int64 = 0
    public var sendCount: Int64 = 0

    public init(
        adapterName: String,
        startDelayMs!: Int64 = 0,
        failMessage!: String = "",
        stopFailure!: String = ""
    ) {
        this.adapterName = adapterName
        this.startDelayMs = startDelayMs
        this.failMessage = failMessage
        this.stopFailure = stopFailure
    }

    public prop name: String {
        get() { this.adapterName }
    }

    public func start(): Unit {
        this.startCount += 1
        if (this.startDelayMs > 0) {
            sleep(Duration.millisecond * this.startDelayMs)
        }
        if (!this.failMessage.isEmpty()) {
            throw Exception(this.failMessage)
        }
    }

    public func stop(): Unit {
        this.stopCount += 1
        if (!this.stopFailure.isEmpty()) {
            throw Exception(this.stopFailure)
        }
    }

    public func queue(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Telegram,
            "msg-${this.inbound.size}",
            "peer",
            "sender",
            ChatType.Direct,
            text,
            false,
            DateTime.now(),
            accountId: "default"
        ))
    }

    public func pullInbound(): Array<InboundMessage> {
        this.pullCount += 1
        let out = this.inbound.toArray()
        this.inbound.clear()
        out
    }

    public func send(_message: OutboundMessage): SendResult {
        this.sendCount += 1
        SendResult.Success
    }

    public func sendWithMessageId(_message: OutboundMessage): String {
        this.sendCount += 1
        "fake-message"
    }
}

private func withGatewayServiceStartupLogCapture<T>(name: String, block: (String) -> T): T {
    let oldLevel = Config.logLevel
    let oldFile = Config.logFile
    let oldMetisLevel = getVariable("METIS_LOG_LEVEL")
    let oldMetisFile = getVariable("METIS_LOG_FILE")
    let oldMetisConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
    let path = "/tmp/metis-gateway-service-startup-${name}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}.log"
    try { remove(Path(path), recursive: true) } catch (_: Exception) { () }
    Config.logLevel = "debug"
    Config.logFile = path
    setVariable("METIS_LOG_LEVEL", "debug")
    setVariable("METIS_LOG_FILE", path)
    setVariable("METIS_CONSOLE_LEVEL", "debug")
    gatewayLoggingResetForTest()
    gatewayLoggingCaptureConsoleForTest()
    try {
        return block(path)
    } finally {
        Config.logLevel = oldLevel
        Config.logFile = oldFile
        match (oldMetisLevel) {
            case Some(value) => setVariable("METIS_LOG_LEVEL", value)
            case None => setVariable("METIS_LOG_LEVEL", "")
        }
        match (oldMetisFile) {
            case Some(value) => setVariable("METIS_LOG_FILE", value)
            case None => setVariable("METIS_LOG_FILE", "")
        }
        match (oldMetisConsoleLevel) {
            case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value)
            case None => setVariable("METIS_CONSOLE_LEVEL", "")
        }
        gatewayLoggingResetForTest()
        try { remove(Path(path), recursive: true) } catch (_: Exception) { () }
    }
}

private func gatewayServiceStartupReadLog(path: String): String {
    let captured = String.join(gatewayLoggingCapturedConsoleForTest(), delimiter: "\n")
    if (!exists(Path(path))) {
        return captured
    }
    String.fromUtf8(File.readFrom(Path(path))) + "\n" + captured
}

private func gatewayServiceStartupString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func gatewayServiceStartupBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func gatewayServiceStartupInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_e: Exception) { -1 }
        case None => -1
    }
}

private func gatewayServiceStartupSummaryAccount(summary: JsonObject, accountId: String): JsonObject {
    let accounts = summary.get("accounts").getOrThrow().asArray()
    for (i in 0..accounts.size()) {
        let row = accounts[i].asObject()
        if (gatewayServiceStartupString(row, "accountId") == accountId) {
            return row
        }
    }
    JsonObject()
}

private func gatewayServiceStartupRuntimeAccount(channelId: String, accountId: String): JsonObject {
    let accounts = gatewayChannelRuntimeAccountsJson(channelId)
    for (i in 0..accounts.size()) {
        let row = accounts[i].asObject()
        if (gatewayServiceStartupString(row, "accountId") == accountId) {
            return row
        }
    }
    JsonObject()
}

@Test
public class GatewayServiceStartupTest {
    @TestCase
    public func startupTimeoutDoesNotPreventPollLoopForHealthyAccount(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let router = GatewayRouter(HashMap<String, ChannelPolicyConfig>())
            let service = GatewayService(router, channelStartupAccountTimeoutMs: 30)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 160)
            let healthy = GatewayServiceStartupFakeAdapter("telegram")
            service.registerAdapter(slow, channelId: "telegram", accountId: "slow")
            service.registerAdapter(healthy, channelId: "telegram", accountId: "default")

            service.start()
            healthy.queue("")
            service.processOnce()

            @Expect(slow.startCount, 1)
            @Expect(slow.stopCount, 1)
            @Expect(healthy.startCount, 1)
            @Expect(healthy.pullCount, 1)

            let slowAccounts = gatewayChannelRuntimeAccountsJson("telegram")
            var sawSlowFailure = false
            var sawHealthyRunning = false
            for (i in 0..slowAccounts.size()) {
                let row = slowAccounts[i].asObject()
                let accountId = row.get("accountId").getOrThrow().asString().getValue()
                let state = row.get("lifecycleState").getOrThrow().asString().getValue()
                if (accountId == "slow" && state == "failed") {
                    sawSlowFailure = true
                    @Expect(row.get("lastError").getOrThrow().asString().getValue().contains("timed out"), true)
                }
                if (accountId == "default" && state == "running") {
                    sawHealthyRunning = true
                }
            }
            @Expect(sawSlowFailure, true)
            @Expect(sawHealthyRunning, true)
        })
    }

    @TestCase
    public func startProbeTimeoutMarksAccountFailedNotRunning(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 120)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "timedOutCount"), 1)
            let row = gatewayServiceStartupRuntimeAccount("telegram", "slow")
            @Expect(gatewayServiceStartupString(row, "lifecycleState"), "failed")
            @Expect(gatewayServiceStartupString(row, "errorKind"), "start_timeout")
            @Expect(gatewayServiceStartupBool(row, "running"), false)
            @Expect(gatewayServiceStartupBool(row, "connected"), false)
        })
    }

    @TestCase
    public func startTimeoutInvokesBestEffortStopOnce(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 120)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            manager.startChannels()
            sleep(Duration.millisecond * 180)

            @Expect(slow.stopCount, 1)
        })
    }

    @TestCase
    public func fastAccountStartDoesNotTriggerCleanup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let fast = GatewayServiceStartupFakeAdapter("telegram")
            manager.registerAdapter(fast, channelId: "telegram", accountId: "default")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "ok")
            @Expect(fast.startCount, 1)
            @Expect(fast.stopCount, 0)
        })
    }

    @TestCase
    public func startThrowMarksAccountFailedAndContinues(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let broken = GatewayServiceStartupFakeAdapter("telegram", failMessage: "boom")
            let later = GatewayServiceStartupFakeAdapter("telegram")
            manager.registerAdapter(broken, channelId: "telegram", accountId: "broken")
            manager.registerAdapter(later, channelId: "telegram", accountId: "later")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "failedCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(broken.stopCount, 1)
            @Expect(later.startCount, 1)
            let failed = gatewayServiceStartupSummaryAccount(summary, "broken")
            @Expect(gatewayServiceStartupString(failed, "channel"), "telegram")
            @Expect(gatewayServiceStartupString(failed, "accountId"), "broken")
            @Expect(gatewayServiceStartupString(failed, "errorKind"), "start_failed")
        })
    }

    @TestCase
    public func cleanupFailureIsLoggedButDoesNotBlockStartup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            withGatewayServiceStartupLogCapture<Unit>("cleanup-failure", { path =>
                let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
                let broken = GatewayServiceStartupFakeAdapter(
                    "telegram",
                    failMessage: "boom",
                    stopFailure: "cleanup exploded"
                )
                let later = GatewayServiceStartupFakeAdapter("telegram")
                manager.registerAdapter(broken, channelId: "telegram", accountId: "broken")
                manager.registerAdapter(later, channelId: "telegram", accountId: "later")

                let summary = manager.startChannels()
                let log = gatewayServiceStartupReadLog(path)

                @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
                @Expect(gatewayServiceStartupInt(summary, "failedCount"), 1)
                @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
                @Expect(broken.stopCount, 1)
                @Expect(later.startCount, 1)
                @Expect(log.contains("channel.stop_cleanup_failed") || log.contains("cleanup_failed"), true)
            })
        })
    }

    @TestCase
    public func zeroTimeoutFailsImmediatelyWithCleanup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 0)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 80)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "timedOutCount"), 1)
            @Expect(slow.stopCount, 1)
            let row = gatewayServiceStartupRuntimeAccount("telegram", "slow")
            @Expect(gatewayServiceStartupString(row, "lifecycleState"), "failed")
            @Expect(gatewayServiceStartupString(row, "errorKind"), "start_timeout")
            @Expect(gatewayServiceStartupBool(row, "running"), false)
        })
    }

    @TestCase
    public func lateReadyAfterTimeoutDoesNotFlipRuntimeToRunning(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("telegram", startDelayMs: 80)
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")

            manager.startChannels()
            sleep(Duration.millisecond * 140)

            let row = gatewayServiceStartupRuntimeAccount("telegram", "slow")
            @Expect(gatewayServiceStartupString(row, "lifecycleState"), "failed")
            @Expect(gatewayServiceStartupString(row, "errorKind"), "start_timeout")
            @Expect(gatewayServiceStartupBool(row, "running"), false)
            @Expect(gatewayServiceStartupBool(row, "connected"), false)
            @Expect(slow.stopCount, 1)
        })
    }

    @TestCase
    public func startChannelsReturnsSummaryWhenOneFeishuAccountTimesOut(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 20)
            let slow = GatewayServiceStartupFakeAdapter("feishu", startDelayMs: 120)
            let later = GatewayServiceStartupFakeAdapter("feishu")
            manager.registerAdapter(slow, channelId: "feishu", accountId: "tenant-a")
            manager.registerAdapter(later, channelId: "feishu", accountId: "tenant-b")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupBool(summary, "degraded"), true)
            @Expect(gatewayServiceStartupInt(summary, "accountCount"), 2)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "failedCount"), 0)
            @Expect(gatewayServiceStartupInt(summary, "timedOutCount"), 1)
            let failed = gatewayServiceStartupSummaryAccount(summary, "tenant-a")
            @Expect(gatewayServiceStartupString(failed, "channel"), "feishu")
            @Expect(gatewayServiceStartupString(failed, "accountId"), "tenant-a")
            @Expect(gatewayServiceStartupString(failed, "errorKind"), "start_timeout")
        })
    }

    @TestCase
    public func failedAccountDoesNotPreventLaterAccountStartup(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let broken = GatewayServiceStartupFakeAdapter("feishu", failMessage: "sidecar failed")
            let later = GatewayServiceStartupFakeAdapter("feishu")
            manager.registerAdapter(broken, channelId: "feishu", accountId: "tenant-a")
            manager.registerAdapter(later, channelId: "feishu", accountId: "tenant-b")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "degraded")
            @Expect(gatewayServiceStartupInt(summary, "failedCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(later.startCount, 1)
            @Expect(gatewayServiceStartupString(gatewayServiceStartupSummaryAccount(summary, "tenant-b"), "status"), "ok")
        })
    }

    @TestCase
    public func disabledAccountIsSkippedAndRecorded(): Unit {
        withGatewayServiceStartupTestHome<Unit>({ =>
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let disabled = GatewayServiceStartupFakeAdapter("feishu")
            let later = GatewayServiceStartupFakeAdapter("feishu")
            manager.registerAdapter(disabled, channelId: "feishu", accountId: "tenant-disabled", enabled: false)
            manager.registerAdapter(later, channelId: "feishu", accountId: "tenant-enabled")

            let summary = manager.startChannels()

            @Expect(gatewayServiceStartupString(summary, "status"), "ok")
            @Expect(gatewayServiceStartupInt(summary, "skippedCount"), 1)
            @Expect(gatewayServiceStartupInt(summary, "okCount"), 1)
            @Expect(disabled.startCount, 0)
            @Expect(disabled.stopCount, 0)
            @Expect(later.startCount, 1)
            let skipped = gatewayServiceStartupSummaryAccount(summary, "tenant-disabled")
            @Expect(gatewayServiceStartupString(skipped, "channel"), "feishu")
            @Expect(gatewayServiceStartupString(skipped, "status"), "skipped")
            @Expect(gatewayServiceStartupString(skipped, "errorKind"), "disabled")
        })
    }
}
