package metis.gateway.core

import metis.core.config.CliConfig
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest}
import metis.gateway.model.{ChannelType, ChatType, InboundMessage, OutboundMessage, SendResult}
import magic.config.Config
import magic.jsonable.*

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.core.Duration
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private func gatewayChannelRuntimeTestReadState(): String {
    let path = Path(gatewayChannelRuntimeStatePath())
    if (!exists(path)) {
        return ""
    }
    String.fromUtf8(File.readFrom(path))
}

private func gatewayChannelRuntimeTestWriteState(content: String): Unit {
    File.writeTo(Path(gatewayChannelRuntimeStatePath()), content.toArray())
}

private func withGatewayChannelRuntimeTestHome<T>(block: () -> T): T {
    let testHome = "/tmp/metis-gateway-channel-runtime-test-home"
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

private func withGatewayChannelRuntimeLogCapture<T>(name: String, level: String, block: (String) -> T): T {
    let oldLevel = Config.logLevel
    let oldFile = Config.logFile
    let oldMetisLevel = getVariable("METIS_LOG_LEVEL")
    let oldMetisFile = getVariable("METIS_LOG_FILE")
    let oldMetisConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
    let path = CliConfig.logsDir.join("metis-gateway-channel-runtime-${name}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}.log").toString()
    if (!exists(Path(path).parent)) {
        Directory.create(Path(path).parent, recursive: true)
    }
    try { remove(Path(path), recursive: true) } catch (_: Exception) { () }
    Config.logLevel = level
    Config.logFile = path
    setVariable("METIS_LOG_LEVEL", level)
    setVariable("METIS_LOG_FILE", path)
    setVariable("METIS_CONSOLE_LEVEL", level)
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

private func gatewayChannelRuntimeReadLog(path: String): String {
    let captured = String.join(gatewayLoggingCapturedConsoleForTest(), delimiter: "\n")
    if (!exists(Path(path))) {
        return captured
    }
    String.fromUtf8(File.readFrom(Path(path))) + "\n" + captured
}

private func gatewayChannelRuntimeReadFileLog(path: String): String {
    if (!exists(Path(path))) {
        return ""
    }
    String.fromUtf8(File.readFrom(Path(path)))
}

private func gatewayChannelRuntimeLogOccurrenceCount(text: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    text.split(needle).size - 1
}

private func gatewayChannelRuntimeHasEvent(log: String, event: String): Bool {
    log.contains("\"event\":\"${event}\"") || log.contains("event=${event}")
}

private class GatewayChannelRuntimeFailingInboundAdapter <: ChannelAdapter {
    private let inbound = ArrayList<InboundMessage>()
    public var sentCount: Int64 = 0

    public prop name: String {
        get() { "telegram" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func queue(text: String): Unit {
        this.inbound.add(InboundMessage(
            ChannelType.Telegram,
            "msg-${this.inbound.size}",
            "user:42",
            "42",
            ChatType.Direct,
            text,
            false,
            DateTime.now()
        ))
    }

    public func pullInbound(): Array<InboundMessage> {
        let out = this.inbound.toArray()
        this.inbound.clear()
        out
    }

    public func send(_message: OutboundMessage): SendResult {
        this.sentCount += 1
        SendResult.Success
    }

    public func sendWithMessageId(_message: OutboundMessage): String {
        this.sentCount += 1
        "msg-out"
    }
}

private class GatewayChannelRuntimeSidecarFailureAdapter <: ChannelAdapter {
    private var failed = false

    public prop name: String {
        get() { "feishu" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func pullInbound(): Array<InboundMessage> {
        if (!this.failed) {
            this.failed = true
            throw Exception("feishu sidecar background failure: Authorization: Bearer sidecar-token appSecret=sidecar-secret-never-visible")
        }
        []
    }

    public func send(_message: OutboundMessage): SendResult {
        SendResult.Success
    }

    public func sendWithMessageId(_message: OutboundMessage): String {
        "fake-message"
    }
}

private class GatewayChannelRuntimeSidecarClosedAfterReadyAdapter <: ChannelAdapter {
    private var closed = false

    public prop name: String {
        get() { "feishu" }
    }

    public func start(): Unit {}

    public func stop(): Unit {}

    public func pullInbound(): Array<InboundMessage> {
        if (!this.closed) {
            this.closed = true
            throw Exception("feishu sidecar closed: websocket.close 1006")
        }
        []
    }

    public func send(_message: OutboundMessage): SendResult {
        SendResult.Success
    }

    public func sendWithMessageId(_message: OutboundMessage): String {
        "fake-message"
    }
}

private class GatewayChannelLifecycleFakeAdapter <: ChannelAdapter {
    private let adapterName: String
    private let accountId: String
    private let events: ArrayList<String>
    private let failMessage: String
    private let startDelayMs: Int64
    public var startCount: Int64 = 0
    public var stopCount: Int64 = 0

    public init(
        adapterName: String,
        accountId: String,
        events!: ArrayList<String> = ArrayList<String>(),
        failMessage!: String = "",
        startDelayMs!: Int64 = 0
    ) {
        this.adapterName = adapterName
        this.accountId = accountId
        this.events = events
        this.failMessage = failMessage
        this.startDelayMs = startDelayMs
    }

    public prop name: String {
        get() { this.adapterName }
    }

    public func start(): Unit {
        this.startCount += 1
        this.events.add("start:${this.accountId}")
        if (this.startDelayMs > 0) {
            sleep(Duration.millisecond * this.startDelayMs)
        }
        if (!this.failMessage.isEmpty()) {
            throw Exception(this.failMessage)
        }
    }

    public func stop(): Unit {
        this.stopCount += 1
        this.events.add("stop:${this.accountId}")
    }

    public func pullInbound(): Array<InboundMessage> {
        []
    }

    public func send(_message: OutboundMessage): SendResult {
        SendResult.Success
    }

    public func sendWithMessageId(_message: OutboundMessage): String {
        "fake-message"
    }
}

private func gatewayRuntimeTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func gatewayRuntimeTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

private func gatewayRuntimeTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_e: Exception) { -1 }
        case None => -1
    }
}

@Test
public class GatewayChannelRuntimeTest {
    @TestCase
    public func channelManagerLogsAccountStartSummariesWithoutInfoTimingNoise(): Unit {
        withGatewayChannelRuntimeTestHome {
            withGatewayChannelRuntimeLogCapture("start-info", "info", { path =>
                let manager = GatewayChannelManager()
                let first = GatewayChannelLifecycleFakeAdapter("telegram", "default")
                let second = GatewayChannelLifecycleFakeAdapter("telegram", "work")
                manager.registerAdapter(first, channelId: "telegram", accountId: "default")
                manager.registerAdapter(second, channelId: "telegram", accountId: "work")

                manager.startChannels()

                let log = gatewayChannelRuntimeReadLog(path)
                @Expect(log.contains("\"event\":\"channel.started\"") || log.contains("event=channel.started"), true)
                @Expect(log.contains("\"accountId\":\"default\"") || log.contains("accountId=default"), true)
                @Expect(log.contains("\"accountId\":\"work\"") || log.contains("accountId=work"), true)
                @Expect(log.contains("can-start-checked"), false)
                @Expect(log.contains("marked-starting"), false)
            })
        }
    }

    @TestCase
    public func channelManagerKeepsTimingDetailsAtDebugLevel(): Unit {
        withGatewayChannelRuntimeTestHome {
            withGatewayChannelRuntimeLogCapture("start-debug", "debug", { path =>
                let manager = GatewayChannelManager()
                manager.registerAdapter(GatewayChannelLifecycleFakeAdapter("telegram", "default"), channelId: "telegram", accountId: "default")

                manager.startChannels()

                let log = gatewayChannelRuntimeReadLog(path)
                @Expect(log.contains("\"event\":\"channel.timing\"") || log.contains("event=channel.timing"), true)
                @Expect(log.contains("can-start-checked"), true)
            })
        }
    }

    @TestCase
    public func channelManagerDoesNotWriteInfoPullLogsForEmptyPulls(): Unit {
        withGatewayChannelRuntimeTestHome {
            withGatewayChannelRuntimeLogCapture("empty-pull-info", "info", { path =>
                let manager = GatewayChannelManager()
                manager.registerAdapter(GatewayChannelLifecycleFakeAdapter("telegram", "default"), channelId: "telegram", accountId: "default")
                manager.startChannels()

                for (_ in 0..10) {
                    manager.processOnce({ _message, _accountId => () })
                }

                let log = gatewayChannelRuntimeReadLog(path)
                @Expect(gatewayChannelRuntimeLogOccurrenceCount(log, "\"event\":\"channel.pull\""), 0)
                @Expect(gatewayChannelRuntimeLogOccurrenceCount(log, "event=channel.pull"), 0)

                let row = gatewayChannelRuntimeAccountsJson("telegram")[0].asObject()
                @Expect(gatewayRuntimeTestInt(row, "pullCount"), 10)
                @Expect(gatewayRuntimeTestInt(row, "inboundCount"), 0)
            })
        }
    }

    @TestCase
    public func channelManagerKeepsInfoPullLogWhenInboundMessagesArrive(): Unit {
        withGatewayChannelRuntimeTestHome {
            withGatewayChannelRuntimeLogCapture("inbound-pull-info", "info", { path =>
                let manager = GatewayChannelManager()
                let adapter = GatewayChannelRuntimeFailingInboundAdapter()
                manager.registerAdapter(adapter, channelId: "telegram", accountId: "default")
                manager.startChannels()
                adapter.queue("hello")

                manager.processOnce({ _message, _accountId => () })

                let log = gatewayChannelRuntimeReadLog(path)
                @Expect(gatewayChannelRuntimeHasEvent(log, "channel.pull"), true)
                @Expect(log.contains("\"level\":\"info\"") || log.contains("] info "), true)
                @Expect(log.contains("\"inboundCount\":1") || log.contains("inboundCount=1"), true)

                let row = gatewayChannelRuntimeAccountsJson("telegram")[0].asObject()
                @Expect(gatewayRuntimeTestInt(row, "pullCount"), 1)
                @Expect(gatewayRuntimeTestInt(row, "inboundCount"), 1)
            })
        }
    }

    @TestCase
    public func channelManagerKeepsFailureLogAndBackoffStateWhenPullFails(): Unit {
        withGatewayChannelRuntimeTestHome {
            withGatewayChannelRuntimeLogCapture("pull-failed-info", "info", { path =>
                let manager = GatewayChannelManager()
                manager.registerAdapter(GatewayChannelRuntimeSidecarClosedAfterReadyAdapter(), channelId: "feishu", accountId: "tenant-a")
                manager.startChannels()

                manager.processOnce({ _message, _accountId => () })

                let log = gatewayChannelRuntimeReadLog(path)
                @Expect(gatewayChannelRuntimeHasEvent(log, "channel.failed"), true)
                @Expect(log.contains("\"level\":\"error\"") || log.contains("] error "), true)
                @Expect(log.contains("\"errorKind\":\"pull_failed\"") || log.contains("errorKind=pull_failed"), true)

                let row = gatewayChannelRuntimeAccountsJson("feishu")[0].asObject()
                @Expect(gatewayRuntimeTestString(row, "lifecycleState"), "backoff")
                @Expect(gatewayRuntimeTestString(row, "errorKind"), "pull_failed")
                @Expect(gatewayRuntimeTestBool(row, "running"), false)
                @Expect(gatewayRuntimeTestBool(row, "connected"), false)
            })
        }
    }

    @TestCase
    public func startChannelsMarksFailedAccountAndContinuesLaterAccounts(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let failed = GatewayChannelLifecycleFakeAdapter("telegram", "bad", failMessage: "boom")
            let later = GatewayChannelLifecycleFakeAdapter("telegram", "later")
            manager.registerAdapter(failed, channelId: "telegram", accountId: "bad")
            manager.registerAdapter(later, channelId: "telegram", accountId: "later")

            let summary = manager.startChannels()

            @Expect(gatewayRuntimeTestString(summary, "status"), "degraded")
            @Expect(gatewayRuntimeTestBool(summary, "degraded"), true)
            @Expect(gatewayRuntimeTestInt(summary, "accountCount"), 2)
            @Expect(gatewayRuntimeTestInt(summary, "okCount"), 1)
            @Expect(gatewayRuntimeTestInt(summary, "failedCount"), 1)
            @Expect(gatewayRuntimeTestInt(summary, "timedOutCount"), 0)
            @Expect(gatewayRuntimeTestInt(summary, "skippedCount"), 0)
            @Expect(failed.startCount, 1)
            @Expect(failed.stopCount, 1)
            @Expect(later.startCount, 1)

            let accounts = summary.get("accounts").getOrThrow().asArray()
            @Expect(accounts.size(), 2)
            @Expect(gatewayRuntimeTestString(accounts[0].asObject(), "status"), "failed")
            @Expect(gatewayRuntimeTestString(accounts[0].asObject(), "errorKind"), "start_failed")
            @Expect(gatewayRuntimeTestString(accounts[1].asObject(), "status"), "ok")
        }
    }

    @TestCase
    public func gatewayManagerKeepsFeishuSidecarStartFailureOutOfRunningState(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            let adapter = GatewayChannelLifecycleFakeAdapter(
                "feishu",
                "tenant-a",
                failMessage: "Feishu long-connect transport failed to start: missing_dependency: @larksuiteoapi/node-sdk under /tmp/metis-feishu-runtime"
            )
            manager.registerAdapter(adapter, channelId: "feishu", accountId: "tenant-a")

            let summary = manager.startChannels()
            let accounts = gatewayChannelRuntimeAccountsJson("feishu")
            let row = accounts[0].asObject()

            @Expect(gatewayRuntimeTestString(summary, "status"), "degraded")
            @Expect(gatewayRuntimeTestInt(summary, "failedCount"), 1)
            @Expect(gatewayRuntimeTestString(row, "lifecycleState"), "failed")
            @Expect(gatewayRuntimeTestString(row, "errorKind"), "start_failed")
            @Expect(gatewayRuntimeTestBool(row, "running"), false)
            @Expect(gatewayRuntimeTestBool(row, "connected"), false)
            @Expect(gatewayRuntimeTestString(row, "lastError").contains("missing_dependency"), true)
            @Expect(gatewayRuntimeTestString(row, "lastError").contains("@larksuiteoapi/node-sdk"), true)
            @Expect(adapter.startCount, 1)
            @Expect(adapter.stopCount, 1)
        }
    }

    @TestCase
    public func feishuSidecarReadyTimeoutPreservesRuntimeErrorKind(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 1000)
            manager.registerAdapter(
                GatewayChannelLifecycleFakeAdapter(
                    "feishu",
                    "tenant-a",
                    failMessage: "Feishu long-connect transport failed to start: ready_timeout: sidecar ready timeout"
                ),
                channelId: "feishu",
                accountId: "tenant-a"
            )

            manager.startChannels()

            let accounts = gatewayChannelRuntimeAccountsJson("feishu")
            let row = accounts[0].asObject()
            @Expect(gatewayRuntimeTestString(row, "lifecycleState"), "failed")
            @Expect(gatewayRuntimeTestString(row, "errorKind"), "ready_timeout")
            @Expect(gatewayRuntimeTestBool(row, "running"), false)
            @Expect(gatewayRuntimeTestBool(row, "connected"), false)
            @Expect(gatewayRuntimeTestString(row, "lastError").contains("ready timeout"), true)
        }
    }

    @TestCase
    public func startChannelsMarksTimedOutAccountAndContinuesLaterAccounts(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager(startupAccountTimeoutMs: 30)
            let slow = GatewayChannelLifecycleFakeAdapter("telegram", "slow", startDelayMs: 120)
            let later = GatewayChannelLifecycleFakeAdapter("telegram", "later")
            manager.registerAdapter(slow, channelId: "telegram", accountId: "slow")
            manager.registerAdapter(later, channelId: "telegram", accountId: "later")

            let summary = manager.startChannels()

            @Expect(gatewayRuntimeTestString(summary, "status"), "degraded")
            @Expect(gatewayRuntimeTestBool(summary, "degraded"), true)
            @Expect(gatewayRuntimeTestInt(summary, "accountCount"), 2)
            @Expect(gatewayRuntimeTestInt(summary, "okCount"), 1)
            @Expect(gatewayRuntimeTestInt(summary, "failedCount"), 0)
            @Expect(gatewayRuntimeTestInt(summary, "timedOutCount"), 1)
            @Expect(gatewayRuntimeTestInt(summary, "skippedCount"), 0)
            @Expect(slow.startCount, 1)
            @Expect(slow.stopCount, 1)
            @Expect(later.startCount, 1)

            let accounts = summary.get("accounts").getOrThrow().asArray()
            @Expect(accounts.size(), 2)
            @Expect(gatewayRuntimeTestString(accounts[0].asObject(), "status"), "timed_out")
            @Expect(gatewayRuntimeTestString(accounts[0].asObject(), "errorKind"), "start_timeout")
            @Expect(gatewayRuntimeTestString(accounts[1].asObject(), "status"), "ok")
        }
    }

    @TestCase
    public func autoEnabledPrimeClearsStaleManualStop(): Unit {
        withGatewayChannelRuntimeTestHome {
            gatewayChannelRuntimeRegisterAccount("qq", accountId: "qq:test")
            gatewayChannelRuntimeMarkStopped("qq", accountId: "qq:test", reason: "manual-stop", manualStop: true)
            @Expect(gatewayChannelRuntimeCanStart("qq", accountId: "qq:test"), false)

            let primed = gatewayChannelRuntimePrimeAccount(
                "qq",
                accountId: "qq:test",
                configuredBinding: true,
                autoEnabled: true
            )
            @Expect(primed.get("manualStop").getOrThrow().asBool().getValue(), false)
            @Expect(primed.get("abortState").getOrThrow().asString().getValue(), "clear")
            @Expect(gatewayChannelRuntimeCanStart("qq", accountId: "qq:test"), true)
        }
    }

    @TestCase
    public func prefixedConfiguredBindingAndCanonicalAdapterRegistrationShareRuntimeRow(): Unit {
        withGatewayChannelRuntimeTestHome {
            let entries = JsonArray([])
            let entry = JsonObject()
            entry.put("channelId", JsonString("feishu"))
            entry.put("accountId", JsonString("feishu:default"))
            entry.put("configuredBinding", true.toJsonValue())
            entry.put("autoEnabled", true.toJsonValue())
            entry.put("detail", JsonString("configured-binding-primed"))
            entries.add(entry)

            @Expect(gatewayChannelRuntimePrimeAccounts(entries), 1)
            gatewayChannelRuntimeRegisterAccount(
                "feishu",
                accountId: "default",
                runtimeKind: "builtin-adapter",
                compatibilityMode: "sidecar"
            )

            let accounts = gatewayChannelRuntimeAccountsJson("feishu")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(gatewayRuntimeTestString(row, "accountId"), "default")
            @Expect(gatewayRuntimeTestBool(row, "configuredBinding"), true)
            @Expect(gatewayRuntimeTestBool(row, "primed"), true)
            @Expect(gatewayRuntimeTestString(row, "runtimeKind"), "builtin-adapter")
            @Expect(gatewayRuntimeTestString(row, "compatibilityMode"), "sidecar")
            @Expect(gatewayRuntimeTestString(row, "bindingState"), "primed")
        }
    }

    @TestCase
    public func inboundTurnFailureDoesNotMarkChannelFailed(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let adapter = GatewayChannelRuntimeFailingInboundAdapter()
            manager.registerAdapter(adapter, channelId: "telegram", accountId: "telegram:default")
            manager.startChannels()
            adapter.queue("hello")

            manager.processOnce({ _message, _accountId =>
                throw Exception("delivery failed")
            })

            let accounts = gatewayChannelRuntimeAccountsJson("telegram")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(row.get("running").getOrThrow().asBool().getValue(), true)
            @Expect(row.get("lifecycleState").getOrThrow().asString().getValue(), "running")
            @Expect(row.get("phase").getOrThrow().asString().getValue(), "active")
            @Expect(row.get("taskState").getOrThrow().asString().getValue(), "running")
            @Expect(row.get("lastError").getOrThrow().asString().getValue(), "delivery failed")

            adapter.queue("second")
            manager.processOnce({ message, _accountId =>
                let _ = adapter.send(OutboundMessage(message.channel, message.peerId, "ok"))
            })
            @Expect(adapter.sentCount, 1)
        }
    }

    @TestCase
    public func runtimeStatusRedactsSecretBearingErrors(): Unit {
        withGatewayChannelRuntimeTestHome {
            gatewayChannelRuntimeRegisterAccount("feishu", accountId: "tenant-a")
            gatewayChannelRuntimeMarkFailure(
                "feishu",
                accountId: "tenant-a",
                error: "Authorization: Bearer access-secret appSecret=app-secret refresh_token=refresh-secret"
            )

            let rendered = gatewayChannelRuntimeSummary("feishu").toJsonString()
            @Expect(rendered.contains("access-secret"), false)
            @Expect(rendered.contains("app-secret"), false)
            @Expect(rendered.contains("refresh-secret"), false)
            @Expect(rendered.contains("[redacted]"), true)
        }
    }

    @TestCase
    public func feishuSidecarBackgroundFailureUpdatesGatewayRuntimeLastError(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            manager.registerAdapter(GatewayChannelRuntimeSidecarFailureAdapter(), channelId: "feishu", accountId: "tenant-a")
            manager.startChannels()

            manager.processOnce({ _message, _accountId => () })

            let accounts = gatewayChannelRuntimeAccountsJson("feishu")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(gatewayRuntimeTestString(row, "lifecycleState"), "backoff")
            @Expect(gatewayRuntimeTestString(row, "errorKind"), "pull_failed")
            @Expect(gatewayRuntimeTestString(row, "lastError"), "[redacted]")
            let summary = gatewayChannelManagerSummary("feishu")
            @Expect(gatewayRuntimeTestString(summary, "lastError"), "[redacted]")
            let raw = summary.toJsonString()
            @Expect(raw.contains("sidecar-token"), false)
            @Expect(raw.contains("sidecar-secret-never-visible"), false)
            @Expect(raw.contains("Authorization"), false)
        }
    }

    @TestCase
    public func feishuSidecarClosedAfterReadyMovesGatewayRuntimeToBackoff(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            manager.registerAdapter(GatewayChannelRuntimeSidecarClosedAfterReadyAdapter(), channelId: "feishu", accountId: "tenant-a")
            manager.startChannels()

            let runningRow = gatewayChannelRuntimeAccountsJson("feishu")[0].asObject()
            @Expect(gatewayRuntimeTestString(runningRow, "lifecycleState"), "running")
            @Expect(gatewayRuntimeTestBool(runningRow, "running"), true)
            @Expect(gatewayRuntimeTestBool(runningRow, "connected"), true)

            manager.processOnce({ _message, _accountId => () })

            let failedRow = gatewayChannelRuntimeAccountsJson("feishu")[0].asObject()
            @Expect(gatewayRuntimeTestString(failedRow, "lifecycleState"), "backoff")
            @Expect(gatewayRuntimeTestString(failedRow, "errorKind"), "pull_failed")
            @Expect(gatewayRuntimeTestBool(failedRow, "running"), false)
            @Expect(gatewayRuntimeTestBool(failedRow, "connected"), false)
            @Expect(gatewayRuntimeTestString(failedRow, "lastError").contains("websocket.close 1006"), true)
        }
    }

    @TestCase
    public func startChannelWithAccountStartsOnlyTargetAccount(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let telegramDefault = GatewayChannelLifecycleFakeAdapter("telegram", "default")
            let telegramWriter = GatewayChannelLifecycleFakeAdapter("telegram", "tg-writer")
            let feishuDefault = GatewayChannelLifecycleFakeAdapter("feishu", "default")
            manager.registerAdapter(telegramDefault, channelId: "telegram", accountId: "default")
            manager.registerAdapter(telegramWriter, channelId: "telegram", accountId: "tg-writer")
            manager.registerAdapter(feishuDefault, channelId: "feishu", accountId: "default")

            let result = manager.startChannel("telegram", accountId: "tg-writer")

            @Expect(gatewayRuntimeTestBool(result, "started"), true)
            @Expect(gatewayRuntimeTestString(result, "accountId"), "tg-writer")
            @Expect(telegramDefault.startCount, 0)
            @Expect(telegramWriter.startCount, 1)
            @Expect(feishuDefault.startCount, 0)
        }
    }

    @TestCase
    public func startChannelWithoutAccountStartsOnlyThatChannel(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let telegramDefault = GatewayChannelLifecycleFakeAdapter("telegram", "default")
            let telegramWriter = GatewayChannelLifecycleFakeAdapter("telegram", "tg-writer")
            let feishuDefault = GatewayChannelLifecycleFakeAdapter("feishu", "default")
            manager.registerAdapter(telegramDefault, channelId: "telegram", accountId: "default")
            manager.registerAdapter(telegramWriter, channelId: "telegram", accountId: "tg-writer")
            manager.registerAdapter(feishuDefault, channelId: "feishu", accountId: "default")

            let result = manager.startChannel("telegram")

            @Expect(gatewayRuntimeTestBool(result, "started"), true)
            @Expect(telegramDefault.startCount, 1)
            @Expect(telegramWriter.startCount, 1)
            @Expect(feishuDefault.startCount, 0)
        }
    }

    @TestCase
    public func startChannelCanStartAccountRegisteredAfterGlobalStart(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let telegramDefault = GatewayChannelLifecycleFakeAdapter("telegram", "default")
            let telegramLive = GatewayChannelLifecycleFakeAdapter("telegram", "tg-live")
            manager.registerAdapter(telegramDefault, channelId: "telegram", accountId: "default")
            manager.startChannels()
            manager.registerAdapter(telegramLive, channelId: "telegram", accountId: "tg-live")

            let result = manager.startChannel("telegram", accountId: "tg-live")

            @Expect(gatewayRuntimeTestBool(result, "started"), true)
            @Expect(telegramDefault.startCount, 1)
            @Expect(telegramLive.startCount, 1)
        }
    }

    @TestCase
    public func startChannelCanonicalizesChannelPrefixedAccountId(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let telegramWriter = GatewayChannelLifecycleFakeAdapter("telegram", "tg-writer")
            manager.registerAdapter(telegramWriter, channelId: "telegram", accountId: "tg-writer")

            let result = manager.startChannel("telegram", accountId: "telegram:tg-writer")
            let accounts = gatewayChannelRuntimeAccountsJson("telegram")
            let row = accounts[0].asObject()

            @Expect(gatewayRuntimeTestBool(result, "started"), true)
            @Expect(gatewayRuntimeTestString(result, "accountId"), "tg-writer")
            @Expect(gatewayRuntimeTestString(row, "accountId"), "tg-writer")
        }
    }

    @TestCase
    public func stopChannelWithAccountDoesNotStopSiblingAccounts(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let telegramDefault = GatewayChannelLifecycleFakeAdapter("telegram", "default")
            let telegramWriter = GatewayChannelLifecycleFakeAdapter("telegram", "tg-writer")
            manager.registerAdapter(telegramDefault, channelId: "telegram", accountId: "default")
            manager.registerAdapter(telegramWriter, channelId: "telegram", accountId: "tg-writer")
            manager.startChannel("telegram")

            let result = manager.stopChannel("telegram", accountId: "tg-writer")

            @Expect(gatewayRuntimeTestBool(result, "stopped"), true)
            @Expect(telegramDefault.stopCount, 0)
            @Expect(telegramWriter.stopCount, 1)
            @Expect(telegramDefault.startCount, 1)
        }
    }

    @TestCase
    public func restartChannelWithAccountStopsThenStartsSameAccount(): Unit {
        withGatewayChannelRuntimeTestHome {
            let events = ArrayList<String>()
            let manager = GatewayChannelManager()
            let telegramWriter = GatewayChannelLifecycleFakeAdapter("telegram", "tg-writer", events: events)
            manager.registerAdapter(telegramWriter, channelId: "telegram", accountId: "tg-writer")
            manager.startChannel("telegram", accountId: "tg-writer")
            events.clear()

            let result = manager.restartChannel("telegram", accountId: "tg-writer")

            @Expect(gatewayRuntimeTestBool(result, "restarted"), true)
            @Expect(events.size, 2)
            @Expect(events[0], "stop:tg-writer")
            @Expect(events[1], "start:tg-writer")
        }
    }

    @TestCase
    public func stopChannelMissingAccountReturnsDiagnosticWithoutTouchingSiblings(): Unit {
        withGatewayChannelRuntimeTestHome {
            let manager = GatewayChannelManager()
            let telegramDefault = GatewayChannelLifecycleFakeAdapter("telegram", "default")
            manager.registerAdapter(telegramDefault, channelId: "telegram", accountId: "default")
            manager.startChannel("telegram")

            let result = manager.stopChannel("telegram", accountId: "missing")

            @Expect(gatewayRuntimeTestBool(result, "ok"), false)
            @Expect(gatewayRuntimeTestString(result, "reason"), "account-not-registered")
            @Expect(telegramDefault.stopCount, 0)
            @Expect(telegramDefault.startCount, 1)
        }
    }
}
