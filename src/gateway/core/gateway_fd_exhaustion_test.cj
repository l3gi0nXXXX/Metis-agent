package metis.gateway.core

import magic.config.Config
import magic.jsonable.*
import metis.core.config.CliConfig
import metis.gateway.logging.{gatewayLoggingResetForTest, gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest}
import metis.gateway.model.*
import std.collection.ArrayList
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, FSException, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}

private func fdS1Home(block: () -> Unit): Unit {
    let home = Path("/tmp/metis-fd-s1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    if (exists(home)) { throw Exception("owned_home_exists") }
    let oldHome = getVariable("METIS_HOME")
    let oldLog = getVariable("METIS_LOG_FILE")
    let oldConsole = getVariable("METIS_CONSOLE_LEVEL")
    let oldLevel = getVariable("METIS_LOG_LEVEL")
    let oldConfigLog = Config.logFile
    Directory.create(home)
    try {
        setVariable("METIS_HOME", home.toString())
        setVariable("METIS_LOG_FILE", home.join("diagnostic.log").toString())
        setVariable("METIS_CONSOLE_LEVEL", "off")
        setVariable("METIS_LOG_LEVEL", "info")
        CliConfig.invalidatePathCache()
        gatewayLoggingResetForTest()
        gatewayLoggingCaptureConsoleForTest()
        resetGatewayChannelRuntimeObservationForTest()
        block()
    } finally {
        resetGatewayChannelRuntimeObservationForTest()
        gatewayLoggingResetForTest()
        match (oldHome) { case Some(v) => setVariable("METIS_HOME", v) case None => removeVariable("METIS_HOME") }
        match (oldLog) { case Some(v) => setVariable("METIS_LOG_FILE", v) case None => removeVariable("METIS_LOG_FILE") }
        match (oldConsole) { case Some(v) => setVariable("METIS_CONSOLE_LEVEL", v) case None => removeVariable("METIS_CONSOLE_LEVEL") }
        match (oldLevel) { case Some(v) => setVariable("METIS_LOG_LEVEL", v) case None => removeVariable("METIS_LOG_LEVEL") }
        CliConfig.invalidatePathCache()
        Config.logFile = oldConfigLog
        remove(home, recursive: true)
        @Expect(exists(home), false)
    }
}

private class FdS1Adapter <: ChannelAdapter {
    public var pulls: Int64 = 0
    public var stops: Int64 = 0
    public var failPull: Bool = false
    public var sends: Int64 = 0
    public var failSend: Bool = false
    public var failureReason: String = "fixture_send_failed 中文😀"
    public var directFailure: String = ""
    public prop name: String { get() { "telegram" } }
    public func start(): Unit {}
    public func stop(): Unit { this.stops += 1 }
    public func pullInbound(): Array<InboundMessage> {
        this.pulls += 1
        if (this.failPull) { throw Exception("fixture_pull_failed") }
        [InboundMessage(ChannelType.Telegram, "fixture-${this.pulls}", "fixture-user", "fixture-peer",
            ChatType.Direct, "中文😀", false, DateTime.now())]
    }
    public func send(_message: OutboundMessage): SendResult {
        this.sends += 1
        if (this.failSend) { return SendResult.Failed(this.failureReason) }
        SendResult.Success
    }
    public func sendWithMessageId(_message: OutboundMessage): String {
        this.sends += 1
        if (this.directFailure == "timeout") { throw GatewayChannelSendTimeoutException("fixture_timeout 中文😀") }
        if (this.directFailure == "failed") { throw Exception("fixture_direct_failed 中文😀") }
        "fixture-output"
    }
}

private func fdS1FailWrites(): Unit {
    setGatewayChannelRuntimeWriterForTest(Some({ _path: Path, _bytes: Array<Byte> =>
        throw FSException("fixture EMFILE token=fake-secret /private/fixture-only")
    }))
}

private func fdS1Tick(): GatewayChannelRuntimeObservationResult {
    gatewayChannelRuntimeTryObservationUpdate("telegram", "default", { =>
        gatewayChannelRuntimeMarkMonitorTick("telegram")
    })
}

@Test
public class GatewayFdExhaustionTest {
    @TestCase
    public func fdS1U1MonitorWriteFailureIsDegraded(): Unit {
        fdS1Home {
            let manager = GatewayChannelManager()
            let adapter = FdS1Adapter()
            manager.registerAdapter(adapter)
            let _ = manager.startChannels()
            fdS1FailWrites()
            let result = fdS1Tick()
            @Expect(result.persisted, false)
            @Expect(result.status, "state_write_failed")
            let handled = ArrayList<String>()
            manager.processOnce({ _, account => handled.add(account) })
            @Expect(adapter.pulls, 1)
            @Expect(handled.size, 1)
            @Expect(adapter.stops, 0)
            @Expect(manager.liveSnapshotJson().toJsonString().contains("fixture_pull_failed"), false)
            manager.markInboundRejected("telegram", "default", "inbound_queue_full")
            manager.markInboundFailure("telegram", "default", "中文😀fixture_turn_failed")
            let reports = ArrayList<Bool>()
            setGatewayChannelRuntimeDiagnosticForTest(Some({ => reports.add(true) }))
            for (_ in 0..100) { @Expect(fdS1Tick().status, "state_write_failed") }
            @Expect(reports.size, 0)
            setGatewayChannelRuntimeWriterForTest(None<(Path, Array<Byte>) -> Unit>)
            @Expect(fdS1Tick().status, "ok")
            @Expect(reports.size, 1)
            @Expect(fdS1Tick().status, "ok")
            @Expect(reports.size, 1)
        }
    }

    @TestCase
    public func fdS1B1InvalidStateNeverOverwritesControlBytes(): Unit {
        fdS1Home {
            let path = Path(gatewayChannelRuntimeStatePath())
            let invalidBytes: Array<Byte> = [0xff, 0xfe]
            let invalid = [invalidBytes, "{中文😀".toArray(), "{\"accounts\":{}}".toArray(),
                "{\"accounts\":[{\"manualStop\":\"true\"}]}".toArray(),
                "{\"accounts\":[{\"channelId\":42,\"manualStop\":true}]}".toArray(),
                "{\"accounts\":[{\"channelId\":\"telegram\",\"accountId\":{},\"manualStop\":true}]}".toArray()]
            for (i in 0..invalid.size) {
                File.writeTo(path, invalid[i])
                let result = fdS1Tick()
                @Expect(result.persisted, false)
                @Expect(result.status, if (i == 0) { "invalid_response_encoding" } else { "malformed_json" })
                @Expect(File.readFrom(path), invalid[i])
                @Expect(gatewayChannelRuntimeCanStart("telegram"), false)
                var failed = false
                try { let _ = gatewayChannelRuntimeMarkStopped("telegram", manualStop: true) }
                catch (_: Exception) { failed = true }
                @Expect(failed, true)
                @Expect(File.readFrom(path), invalid[i])
            }
            remove(path)
            Directory.create(path)
            @Expect(fdS1Tick().status, "state_read_failed")
            @Expect(exists(path), true)
            remove(path)
            let large = String(Array<Rune>(349525, repeat: r'中')) + "😀"
            @Expect(large.size >= 1048576, true)
            let root = JsonObject()
            root.put("fixture", JsonString(large))
            File.writeTo(path, root.toJsonString().toArray())
            @Expect(fdS1Tick().status, "ok")
            let stored = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "decode_failed" }
            @Expect(JsonValue.fromStr(stored).asObject().get("fixture").getOrThrow().asString().getValue(), large)
            let logs = Path(CliConfig.dotDir.join("diagnostic.log").toString())
            let text = if (exists(logs)) { try { String.fromUtf8(File.readFrom(logs)) } catch (_: Exception) { "invalid_log" } } else { "" }
            @Expect(text.contains("fake-secret"), false)
            @Expect(text.contains("/private/fixture-only"), false)
            @Expect(text.contains("invalid_log"), false)
            for (line in text.split("\n")) {
                if (!line.trimAscii().isEmpty()) {
                    @Expect(JsonValue.fromStr(line).asObject().get("event").isSome(), true)
                }
            }
        }
    }

    @TestCase
    public func fdS1P1WritableTwoAccountsPreserveRuntimeFields(): Unit {
        fdS1Home {
            let manager = GatewayChannelManager()
            let first = FdS1Adapter()
            let second = FdS1Adapter()
            manager.registerAdapter(first, accountId: "first")
            manager.registerAdapter(second, accountId: "second")
            let _ = manager.startChannels()
            let handled = ArrayList<String>()
            manager.processOnce({ _, account => handled.add(account) })
            @Expect(handled.toArray(), ["first", "second"])
            @Expect(first.pulls, 1)
            @Expect(second.pulls, 1)
            let rows = gatewayChannelRuntimeAccountsJson("telegram")
            @Expect(rows.size(), 2)
            for (i in 0..rows.size()) {
                let row = rows[i].asObject()
                @Expect(row.get("pullCount").getOrThrow().toJsonString(), "1")
                @Expect(row.get("inboundCount").getOrThrow().toJsonString(), "1")
                @Expect(row.get("running").getOrThrow().asBool().getValue(), true)
                @Expect(row.get("lifecycleState").getOrThrow().asString().getValue(), "running")
                @Expect(row.get("restartBudget").getOrThrow().toJsonString(), "0")
            }
        }
    }

    @TestCase
    public func fdS1N1PullAndDiagnosticFailuresDoNotEscape(): Unit {
        fdS1Home {
            let manager = GatewayChannelManager()
            let failed = FdS1Adapter()
            let later = FdS1Adapter()
            manager.registerAdapter(failed, accountId: "failed")
            manager.registerAdapter(later, accountId: "later")
            let _ = manager.startChannels()
            failed.failPull = true
            fdS1FailWrites()
            let diagnosticAttempts = ArrayList<Bool>()
            setGatewayChannelRuntimeDiagnosticForTest(Some({ =>
                diagnosticAttempts.add(true)
                throw Exception("fixture_logger_failed")
            }))
            let handled = ArrayList<String>()
            manager.processOnce({ _, account => handled.add(account) })
            @Expect(failed.pulls, 1)
            @Expect(later.pulls, 1)
            @Expect(handled.size, 1)
            @Expect(diagnosticAttempts.size > 0, true)
            let live = manager.liveSnapshotJson().get("channelAccounts").getOrThrow().asObject()
                .get("telegram").getOrThrow().asArray()
            @Expect(live[0].asObject().get("running").getOrThrow().asBool().getValue(), false)
            @Expect(live[0].asObject().get("lastError").getOrThrow().asString().getValue(), "fixture_pull_failed")
            @Expect(live[1].asObject().get("running").getOrThrow().asBool().getValue(), true)
        }
    }

    @TestCase
    public func fdS1P2SendSuccessSurvivesPersistenceAndLoggerFailures(): Unit {
        fdS1Home {
            let manager = GatewayChannelManager()
            let adapter = FdS1Adapter()
            manager.registerAdapter(adapter)
            let _ = manager.startChannels()
            fdS1FailWrites()
            setGatewayChannelRuntimeDiagnosticForTest(Some({ => throw Exception("fixture_logger_failed") }))
            let message = OutboundMessage(ChannelType.Telegram, "fixture-peer", "中文😀")
            let sent = manager.sendToAdapterName("telegram", message)
            @Expect(sent.delivered, true)
            @Expect(sent.reasonKind, "")
            let direct = manager.sendWithMessageIdToAdapterName("telegram", message)
            @Expect(direct.delivered, true)
            @Expect(direct.messageId, "fixture-output")
            @Expect(adapter.sends, 2)
            @Expect(adapter.stops, 0)
        }
    }

    @TestCase
    public func fdS1N2SendFailureKeepsOriginalClassification(): Unit {
        fdS1Home {
            let manager = GatewayChannelManager()
            let adapter = FdS1Adapter()
            manager.registerAdapter(adapter)
            let _ = manager.startChannels()
            adapter.failSend = true
            fdS1FailWrites()
            setGatewayChannelRuntimeDiagnosticForTest(Some({ => throw Exception("fixture_logger_failed") }))
            let message = OutboundMessage(ChannelType.Telegram, "fixture-peer", "中文😀")
            let sent = manager.sendToAdapterName("telegram", message)
            @Expect(sent.delivered, false)
            @Expect(sent.reasonKind, "send_failed")
            @Expect(sent.lastReason.contains("fixture_send_failed 中文😀"), true)
            adapter.directFailure = "failed"
            let direct = manager.sendWithMessageIdToAdapterName("telegram", message)
            @Expect(direct.delivered, false)
            @Expect(direct.reasonKind, "send_failed")
            @Expect(direct.lastReason.contains("fixture_direct_failed 中文😀"), true)
            adapter.directFailure = "timeout"
            let timeout = manager.sendWithMessageIdToAdapterName("telegram", message)
            @Expect(timeout.delivered, false)
            @Expect(timeout.reasonKind, "send_timeout")
            setGatewayChannelRuntimeDiagnosticForTest(None<() -> Unit>)
            adapter.failureReason = "x" + String(Array<Rune>(1000, repeat: r'中')) + "😀"
            let longFailure = manager.sendToAdapterName("telegram", message)
            @Expect(longFailure.delivered, false)
            @Expect(longFailure.reasonKind, "send_failed")
            let decoded = try { String.fromUtf8(longFailure.lastReason.toArray()) } catch (_: Exception) { "invalid_utf8" }
            @Expect(decoded, longFailure.lastReason)
            @Expect(longFailure.lastReason.size < 1024, true)
            @Expect(adapter.sends, 4)
            @Expect(adapter.stops, 0)
            let logPath = CliConfig.dotDir.join("diagnostic.log")
            let logText = try { String.fromUtf8(File.readFrom(logPath)) } catch (_: Exception) { "invalid_utf8" }
            @Expect(logText.contains("invalid_utf8"), false)
            var events: Int64 = 0
            for (line in logText.split("\n")) {
                if (!line.trimAscii().isEmpty()) {
                    let row = JsonValue.fromStr(line).asObject()
                    if ((row.get("event") ?? JsonString("")).asString().getValue() == "channel.failed") { events += 1 }
                }
            }
            @Expect(events > 0, true)
        }
    }

    @TestCase
    public func fdS1H01ControlWritesStayStrict(): Unit {
        fdS1Home {
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "manual")
            let _ = gatewayChannelRuntimeMarkStopped("telegram", accountId: "manual", manualStop: true)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "exhausted")
            for (_ in 0..4) {
                let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "exhausted", backoffMs: 1)
            }
            let path = Path(gatewayChannelRuntimeStatePath())
            let before = File.readFrom(path)
            fdS1FailWrites()
            @Expect(gatewayChannelRuntimeCanStart("telegram", accountId: "manual"), false)
            @Expect(gatewayChannelRuntimeCanStart("telegram", accountId: "exhausted"), false)
            var commitFailed = false
            try { let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "manual") }
            catch (_: Exception) { commitFailed = true }
            @Expect(commitFailed, true)
            @Expect(File.readFrom(path), before)
            @Expect(gatewayChannelRuntimeCanStart("telegram", accountId: "manual"), false)
            @Expect(gatewayChannelRuntimeCanStart("telegram", accountId: "exhausted"), false)
        }
    }
}
