package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.core.{gatewayChannelRuntimeMarkFailure, gatewayChannelRuntimeMarkRunning, gatewayChannelRuntimeMarkStarting, gatewayChannelRuntimeRegisterAccount}
import metis.gateway.logging.{gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, gatewayLoggingResetForTest, gatewayLoggingResolveSettings}
import metis.gateway.process.{gatewayStdioBrokerReady, gatewayStdioBrokerSnapshot}
import metis.process.{ManagedStdioBrokerClient, ManagedStdioBrokerSnapshot, ManagedStdioOwnerSpec, managedStdioBroker}
import metis.process.resetManagedStdioBrokerForTest

import std.env.{getVariable, setVariable}
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func gatewayStatusTestUser(): GatewayUserSettings {
    var user = GatewayUserSettings()
    user.auth.mode = "none"
    user.telegram.enabled = true
    user.telegram.botToken = "123456:status-test-token"
    return user
}

private func withGatewayStatusTestSettings<T>(name: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let testHome = "/tmp/metis-gateway-status-test-${name}"
        try {
            remove(Path(testHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(testHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            block()
        } finally {
            let _ = executeWithOutput("/bin/chmod", ["700", testHome])
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
        }
    }
}

private func statusTestObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func statusTestArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func statusTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func statusTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func gatewayStatusPersistUser(user: GatewayUserSettings): Unit {
    let _ = MetisConfigManager.setGatewaySettings(user)
    CliSettingManager.invalidate()
}

private func gatewayStatusOperational(
    alive: Bool,
    responsive: Bool,
    status: String,
    pollLagMs!: Int64 = 0,
    queueDepth!: Int64 = 0,
    queueCapacity!: Int64 = 128
): JsonObject {
    let broker = JsonObject()
    broker.put("running", JsonBool(alive))
    broker.put("responsive", JsonBool(responsive))
    broker.put("status", JsonString(status))
    broker.put("generation", JsonInt(1))
    broker.put("ownerCount", JsonInt(0))
    let out = JsonObject()
    out.put("broker", broker)
    out.put("pollLagMs", JsonInt(pollLagMs))
    out.put("inboundQueueDepth", JsonInt(queueDepth))
    out.put("inboundQueueCapacity", JsonInt(queueCapacity))
    out
}

private func gatewayStatusOperationalFromBroker(snapshot: ManagedStdioBrokerSnapshot): JsonObject {
    let broker = JsonObject()
    broker.put("running", JsonBool(snapshot.running))
    broker.put("responsive", JsonBool(snapshot.responsive))
    broker.put("status", JsonString(snapshot.status))
    broker.put("generation", JsonInt(snapshot.generation))
    broker.put("ownerCount", JsonInt(snapshot.ownerCount))
    let out = JsonObject()
    out.put("broker", broker)
    out.put("pollLagMs", JsonInt(0))
    out.put("inboundQueueDepth", JsonInt(0))
    out.put("inboundQueueCapacity", JsonInt(128))
    out
}

private func gatewayStatusPidGone(pid: Int64): Bool {
    if (pid <= 0) { return true }
    let (exitCode, _, _) = executeWithOutput("/bin/kill", ["-0", "${pid}"])
    exitCode != 0
}

private func gatewayStatusPgidGone(pgid: Int64): Bool {
    if (pgid <= 0) { return true }
    let (exitCode, _, _) = executeWithOutput("/bin/kill", ["-0", "--", "-${pgid}"])
    exitCode != 0
}

private func gatewayStatusWaitForGone(pid: Int64, pgid: Int64, timeoutMs!: Int64 = 3000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        if (gatewayStatusPidGone(pid) && gatewayStatusPgidGone(pgid)) { return true }
        sleep(Duration.millisecond * 20)
    }
    gatewayStatusPidGone(pid) && gatewayStatusPgidGone(pgid)
}

private func gatewayHeartbeatStatusLogCount(lines: Array<String>, event: String): Int64 {
    var count: Int64 = 0
    for (line in lines) {
        if (line.contains(event)) { count += 1 }
    }
    count
}

private func gatewayHeartbeatStatusInstallLsofMarker(marker: Path): Option<String> {
    let oldPath = getVariable("PATH")
    let bin = marker.parent.join("bin")
    Directory.create(bin, recursive: true)
    File.writeTo(
        bin.join("lsof"),
        ("#!/bin/sh\nprintf called > '${marker.toString()}'\nexit 1\n").toArray()
    )
    @Expect(executeWithOutput("/bin/chmod", ["700", bin.join("lsof").toString()])[0], 0)
    let inherited = match (oldPath) { case Some(value) => value case None => "/usr/bin:/bin" }
    setVariable("PATH", "${bin.toString()}:${inherited}")
    oldPath
}

private func gatewayHeartbeatStatusRestorePath(oldPath: Option<String>): Unit {
    match (oldPath) { case Some(value) => setVariable("PATH", value) case None => setVariable("PATH", "") }
}

private func gatewayHeartbeatStatusMakePersistFail(): Unit {
    let state = gatewayRuntimeStatePath()
    try { remove(state, recursive: true) } catch (_: Exception) { () }
    @Expect(executeWithOutput("/bin/chmod", ["500", CliConfig.dotDir.toString()])[0], 0)
}

private func gatewayHeartbeatStatusRepairPersist(): Unit {
    @Expect(executeWithOutput("/bin/chmod", ["700", CliConfig.dotDir.toString()])[0], 0)
    try { remove(gatewayRuntimeStatePath(), recursive: true) } catch (_: Exception) { () }
}

@Test
public class GatewayServerMethodsStatusTest {
    @TestCase
    public func s2U1RuntimePersistenceDoesNotInvokeListenerDiscovery(): Unit {
        withGatewayStatusTestSettings<Unit>("s2-u1-pure-persist", { =>
            let marker = CliConfig.dotDir.join("lsof-called")
            let oldPath = gatewayHeartbeatStatusInstallLsofMarker(marker)
            try {
                gatewayRuntimeMarkStarting()
                gatewayRuntimeMarkRunning()
                gatewayRuntimeHeartbeat()
                gatewayRuntimeMarkStopped(reason: "done")
                @Expect(exists(marker), false)
            } finally {
                let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                gatewayHeartbeatStatusRestorePath(oldPath)
            }
        })
    }

    @TestCase
    public func s2B1MissingOrCorruptSnapshotUsesPureLockFileFallback(): Unit {
        withGatewayStatusTestSettings<Unit>("s2-b1-fallback", { =>
            let marker = CliConfig.dotDir.join("lsof-called")
            let oldPath = gatewayHeartbeatStatusInstallLsofMarker(marker)
            try {
                gatewayRuntimeMarkStarting()
                try { remove(gatewayRuntimeStatePath()) } catch (_: Exception) { () }
                File.writeTo(gatewayServeLockPath(), "test-lock".toArray())
                let missing = gatewayRuntimeSnapshot()
                @Expect(missing.get("serveLockPresent").getOrThrow().asBool().getValue(), true)
                File.writeTo(gatewayRuntimeStatePath(), "{malformed".toArray())
                let malformed = gatewayRuntimeSnapshot()
                @Expect(malformed.get("serveLockPresent").getOrThrow().asBool().getValue(), true)
                File.writeTo(gatewayRuntimeStatePath(), [UInt8(0xff), UInt8(0xfe)])
                let invalidUtf8 = gatewayRuntimeSnapshot()
                @Expect(invalidUtf8.get("serveLockPresent").getOrThrow().asBool().getValue(), true)
                @Expect(exists(marker), false)
                @Expect(
                    gatewayStdioBrokerSnapshot().get("ownerCount").getOrThrow().asInt().getValue(),
                    0
                )
            } finally {
                gatewayHeartbeatStatusRestorePath(oldPath)
            }
        })
    }

    @TestCase
    public func s2P1RuntimePhaseSequencePersistsExplicitServeLockTruth(): Unit {
        withGatewayStatusTestSettings<Unit>("s2-p1-phases", { =>
            gatewayRuntimeMarkStarting()
            @Expect(gatewayRuntimeSnapshot().get("serveLockPresent").getOrThrow().asBool().getValue(), true)
            gatewayRuntimeMarkRunning()
            @Expect(gatewayRuntimeSnapshot().get("serveLockPresent").getOrThrow().asBool().getValue(), true)
            gatewayRuntimeHeartbeat()
            @Expect(gatewayRuntimeSnapshot().get("serveLockPresent").getOrThrow().asBool().getValue(), true)
            gatewayRuntimeMarkStopped(reason: "done")
            @Expect(gatewayRuntimeSnapshot().get("serveLockPresent").getOrThrow().asBool().getValue(), false)
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
        })
    }

    @TestCase
    public func s2N1StoppedRuntimePersistenceDoesNotResurrectBroker(): Unit {
        withGatewayStatusTestSettings<Unit>("s2-n1-no-resurrection", { =>
            gatewayRuntimeMarkStarting()
            gatewayRuntimeHeartbeat()
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            let stopped = gatewayStdioBrokerSnapshot()
            @Expect(stopped.get("running").getOrThrow().asBool().getValue(), false)
            @Expect(stopped.get("brokerPid").getOrThrow().asInt().getValue(), 0)
            @Expect(stopped.get("readerCount").getOrThrow().asInt().getValue(), 0)
            @Expect(stopped.get("ownerCount").getOrThrow().asInt().getValue(), 0)
            gatewayRuntimeMarkStopped(reason: "done")
            let after = gatewayStdioBrokerSnapshot()
            @Expect(after.get("running").getOrThrow().asBool().getValue(), false)
            @Expect(
                after.get("generation").getOrThrow().asInt().getValue(),
                stopped.get("generation").getOrThrow().asInt().getValue()
            )
            @Expect(
                after.get("brokerPid").getOrThrow().asInt().getValue(),
                stopped.get("brokerPid").getOrThrow().asInt().getValue()
            )
            @Expect(
                after.get("readerCount").getOrThrow().asInt().getValue(),
                stopped.get("readerCount").getOrThrow().asInt().getValue()
            )
            @Expect(after.get("ownerCount").getOrThrow().asInt().getValue(), 0)
        })
    }

    @TestCase
    public func hbS4B1HundredHeartbeatsIgnoreHangingLsofAndKeepBrokerGeneration(): Unit {
        withGatewayStatusTestSettings<Unit>("hb-s4-b1-heartbeat-lsof", { =>
            let marker = CliConfig.dotDir.join("lsof-called")
            let oldPath = getVariable("PATH")
            let oldNodeCommand = getVariable("METIS_STDIO_BROKER_NODE_COMMAND")
            let oldBrokerPathCarrier = getVariable("METIS_TEST_HBS4_BROKER_PATH")
            let bin = CliConfig.dotDir.join("bin")
            let brokerLauncher = bin.join("node-with-isolated-path")
            Directory.create(bin, recursive: true)
            File.writeTo(
                bin.join("lsof"),
                ("#!/bin/sh\nprintf called > '${marker.toString()}'\nsleep 1\nprintf '24626\\n'\n").toArray()
            )
            @Expect(executeWithOutput("/bin/chmod", ["700", bin.join("lsof").toString()])[0], 0)
            let inherited = match (oldPath) { case Some(value) => value case None => "/usr/bin:/bin" }
            setVariable("PATH", "${bin.toString()}:${inherited}")
            let brokerPath = getVariable("PATH").getOrDefault { "" }.trimAscii()
            @Expect(brokerPath.isEmpty(), false)
            File.writeTo(
                brokerLauncher,
                ("#!/bin/sh\nexport PATH=\"$METIS_TEST_HBS4_BROKER_PATH\"\n" +
                    "unset METIS_TEST_HBS4_BROKER_PATH\nexec node \"$@\"\n").toArray()
            )
            @Expect(executeWithOutput("/bin/chmod", ["700", brokerLauncher.toString()])[0], 0)
            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            try {
                if (brokerPath.isEmpty()) { return }
                setVariable("METIS_TEST_HBS4_BROKER_PATH", brokerPath)
                setVariable("METIS_STDIO_BROKER_NODE_COMMAND", brokerLauncher.toString())
                let setupReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(setupReset.ok, true)
                let setupStopped = gatewayStdioBrokerSnapshot()
                @Expect(setupStopped.get("running").getOrThrow().asBool().getValue(), false)
                @Expect(setupStopped.get("brokerPid").getOrThrow().asInt().getValue(), 0)
                @Expect(setupStopped.get("ownerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(setupStopped.get("readerCount").getOrThrow().asInt().getValue(), 0)
                let setupDispatcherCount = managedStdioBroker().snapshot().dispatcherCount
                @Expect(setupDispatcherCount, 0)
                let setupFullyStopped = !setupStopped.get("running").getOrThrow().asBool().getValue() &&
                    setupStopped.get("brokerPid").getOrThrow().asInt().getValue() == 0 &&
                    setupStopped.get("ownerCount").getOrThrow().asInt().getValue() == 0 &&
                    setupStopped.get("readerCount").getOrThrow().asInt().getValue() == 0 &&
                    setupDispatcherCount == 0
                if (!setupReset.ok || !setupFullyStopped) { return }
                gatewayRuntimeMarkStarting()
                gatewayRuntimeHeartbeat()
                let ready = gatewayStdioBrokerReady(timeoutMs: 5000)
                @Expect(ready.ok, true)
                @Expect(ready.status, "ready")
                @Expect(ready.generation > 0, true)
                @Expect(ready.pid > 0, true)
                if (!ready.ok || ready.status != "ready" || ready.generation <= 0 || ready.pid <= 0) {
                    return
                }
                let before = gatewayStdioBrokerSnapshot()
                @Expect(before.get("running").getOrThrow().asBool().getValue(), true)
                @Expect(before.get("responsive").getOrThrow().asBool().getValue(), true)
                @Expect(before.get("status").getOrThrow().asString().getValue(), "ready")
                @Expect(before.get("generation").getOrThrow().asInt().getValue(), ready.generation)
                @Expect(before.get("brokerPid").getOrThrow().asInt().getValue(), ready.pid)
                let discovery = gatewayFindVerifiedListenerPidsOnPortDetailed(port: 49141, timeoutMs: 800)
                @Expect(discovery.conclusive, false)
                @Expect(discovery.status, "listener_discovery_timeout")
                @Expect(exists(marker), true)
                try { remove(marker) } catch (_: Exception) { () }

                for (_ in 0..100) {
                    gatewayRuntimeMarkPollCompleted(gatewayStatusOperational(true, true, "ready"))
                    gatewayRuntimeHeartbeat()
                    @Expect(statusTestInt(gatewayRuntimeSnapshot(), "lastPollAtMs") > 0, true)
                }
                let after = gatewayStdioBrokerSnapshot()
                @Expect(exists(marker), false)
                @Expect(
                    after.get("generation").getOrThrow().asInt().getValue(),
                    before.get("generation").getOrThrow().asInt().getValue()
                )
                @Expect(
                    after.get("brokerPid").getOrThrow().asInt().getValue(),
                    before.get("brokerPid").getOrThrow().asInt().getValue()
                )
                @Expect(after.get("ownerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(gatewayHeartbeatStatusLogCount(gatewayLoggingCapturedConsoleForTest(), "gateway.runtime_state.persist_failed"), 0)

                let stopReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(stopReset.ok, true)
                let stopped = gatewayStdioBrokerSnapshot()
                @Expect(stopped.get("running").getOrThrow().asBool().getValue(), false)
                @Expect(stopped.get("brokerPid").getOrThrow().asInt().getValue(), 0)
                @Expect(stopped.get("ownerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(stopped.get("readerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(managedStdioBroker().snapshot().dispatcherCount, 0)
                gatewayRuntimeMarkStopped(reason: "hb-s4-b1-complete")
                let terminal = gatewayStdioBrokerSnapshot()
                @Expect(terminal.get("running").getOrThrow().asBool().getValue(), false)
                @Expect(terminal.get("brokerPid").getOrThrow().asInt().getValue(), 0)
                @Expect(terminal.get("ownerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(terminal.get("readerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(managedStdioBroker().snapshot().dispatcherCount, 0)
                @Expect(
                    terminal.get("generation").getOrThrow().asInt().getValue(),
                    stopped.get("generation").getOrThrow().asInt().getValue()
                )
            } finally {
                let finalReset = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                @Expect(finalReset.ok, true)
                match (oldNodeCommand) {
                    case Some(value) => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", value)
                    case None => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
                }
                match (oldBrokerPathCarrier) {
                    case Some(value) => setVariable("METIS_TEST_HBS4_BROKER_PATH", value)
                    case None => setVariable("METIS_TEST_HBS4_BROKER_PATH", "")
                }
                gatewayHeartbeatStatusRestorePath(oldPath)
                let finalBroker = gatewayStdioBrokerSnapshot()
                @Expect(finalBroker.get("running").getOrThrow().asBool().getValue(), false)
                @Expect(finalBroker.get("brokerPid").getOrThrow().asInt().getValue(), 0)
                @Expect(finalBroker.get("ownerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(finalBroker.get("readerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(managedStdioBroker().snapshot().dispatcherCount, 0)
                gatewayLoggingResetForTest()
            }
        })
    }

    @TestCase
    public func s3U1HeartbeatPersistenceFailureIsNonFatalAndLaterTickContinues(): Unit {
        withGatewayStatusTestSettings<Unit>("s3-u1-nonfatal", { =>
            gatewayRuntimeMarkStarting()
            gatewayHeartbeatStatusMakePersistFail()
            gatewayRuntimeHeartbeat()
            gatewayRuntimeHeartbeat()
            gatewayHeartbeatStatusRepairPersist()
            gatewayRuntimeHeartbeat()
            @Expect(exists(gatewayRuntimeStatePath()), true)
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
        })
    }

    @TestCase
    public func s3B1RepeatedPersistenceFailuresEmitOneTransition(): Unit {
        withGatewayStatusTestSettings<Unit>("s3-b1-bounded", { =>
            gatewayRuntimeMarkStarting()
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let logFile = CliConfig.dotDir.parent.join("metis-heartbeat-s3-b1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.log")
            setVariable("METIS_LOG_FILE", logFile.toString())
            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            let _ = gatewayLoggingResolveSettings()
            try {
                gatewayHeartbeatStatusMakePersistFail()
                for (_ in 0..100) { gatewayRuntimeMarkRunning() }
                gatewayHeartbeatStatusRepairPersist()
                gatewayRuntimeMarkRunning()
                let lines = gatewayLoggingCapturedConsoleForTest()
                @Expect(gatewayHeartbeatStatusLogCount(lines, "gateway.runtime_state.persist_failed"), 1)
                @Expect(gatewayHeartbeatStatusLogCount(lines, "gateway.runtime_state.persist_recovered"), 1)
            } finally {
                match (oldLogFile) { case Some(value) => setVariable("METIS_LOG_FILE", value) case None => setVariable("METIS_LOG_FILE", "") }
                gatewayLoggingResetForTest()
                try { remove(logFile) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func s3P1PersistenceRecoveryIsLoggedOnceAndWritesValidState(): Unit {
        withGatewayStatusTestSettings<Unit>("s3-p1-recovery", { =>
            gatewayRuntimeMarkStarting()
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let logFile = CliConfig.dotDir.parent.join("metis-heartbeat-s3-p1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.log")
            setVariable("METIS_LOG_FILE", logFile.toString())
            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            let _ = gatewayLoggingResolveSettings()
            try {
                gatewayHeartbeatStatusMakePersistFail()
                gatewayRuntimeHeartbeat()
                gatewayHeartbeatStatusRepairPersist()
                gatewayRuntimeHeartbeat()
                let lines = gatewayLoggingCapturedConsoleForTest()
                @Expect(gatewayHeartbeatStatusLogCount(lines, "gateway.runtime_state.persist_failed"), 1)
                @Expect(gatewayHeartbeatStatusLogCount(lines, "gateway.runtime_state.persist_recovered"), 1)
                let state = JsonValue.fromStr(String.fromUtf8(File.readFrom(gatewayRuntimeStatePath()))).asObject()
                @Expect(statusTestString(state, "status"), "starting")
            } finally {
                let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                match (oldLogFile) { case Some(value) => setVariable("METIS_LOG_FILE", value) case None => setVariable("METIS_LOG_FILE", "") }
                gatewayLoggingResetForTest()
                try { remove(logFile) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func s3N1PersistenceDiagnosticsDoNotEchoReasonOrPath(): Unit {
        withGatewayStatusTestSettings<Unit>("s3-n1-redaction", { =>
            gatewayRuntimeMarkStarting()
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let logFile = CliConfig.dotDir.parent.join("metis-heartbeat-s3-n1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.log")
            setVariable("METIS_LOG_FILE", logFile.toString())
            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            let _ = gatewayLoggingResolveSettings()
            try {
                gatewayHeartbeatStatusMakePersistFail()
                let secret = "Authorization: Bearer synthetic-secret 中文🙂 /Users/private/synthetic-path"
                gatewayRuntimeMarkStopped(reason: secret)
                gatewayHeartbeatStatusRepairPersist()
                gatewayRuntimeMarkStopped(reason: "recovered")
                var rendered = ""
                for (line in gatewayLoggingCapturedConsoleForTest()) { rendered += line + "\n" }
                @Expect(rendered.contains("synthetic-secret"), false)
                @Expect(rendered.contains("/Users/private/synthetic-path"), false)
                @Expect(rendered.contains("gateway.runtime_state.persist_failed"), true)
                @Expect(rendered.contains("gateway.runtime_state.persist_recovered"), true)
            } finally {
                match (oldLogFile) { case Some(value) => setVariable("METIS_LOG_FILE", value) case None => setVariable("METIS_LOG_FILE", "") }
                gatewayLoggingResetForTest()
                try { remove(logFile) } catch (_: Exception) { () }
            }
        })
    }

    @TestCase
    public func s3N2PersistenceAndLoggerSinkFailuresRemainNonFatal(): Unit {
        withGatewayStatusTestSettings<Unit>("s3-n2-logger-failure", { =>
            let oldLogFile = getVariable("METIS_LOG_FILE")
            let oldConsole = getVariable("METIS_CONSOLE_LEVEL")
            let blockedParent = CliConfig.dotDir.join("blocked-log-parent")
            File.writeTo(blockedParent, "regular-file".toArray())
            setVariable("METIS_LOG_FILE", blockedParent.join("gateway.log").toString())
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            gatewayLoggingResetForTest()
            try {
                gatewayRuntimeMarkStarting()
                gatewayHeartbeatStatusMakePersistFail()
                gatewayRuntimeMarkRunning()
                gatewayRuntimeHeartbeat()
                gatewayRuntimeHeartbeat()
                gatewayHeartbeatStatusRepairPersist()
                gatewayRuntimeHeartbeat()
                @Expect(exists(gatewayRuntimeStatePath()), true)
            } finally {
                let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                match (oldLogFile) { case Some(value) => setVariable("METIS_LOG_FILE", value) case None => setVariable("METIS_LOG_FILE", "") }
                match (oldConsole) { case Some(value) => setVariable("METIS_CONSOLE_LEVEL", value) case None => setVariable("METIS_CONSOLE_LEVEL", "") }
                gatewayLoggingResetForTest()
            }
        })
    }

    @TestCase
    public func hS3U1HealthyHeartbeatKeepsHistoricalFieldsWithoutFailureLog(): Unit {
        withGatewayStatusTestSettings<Unit>("h-s3-u1-healthy", { =>
            gatewayRuntimeMarkStarting()
            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            gatewayRuntimeHeartbeat()
            let snapshot = gatewayRuntimeSnapshot()
            @Expect(statusTestString(snapshot, "status"), "starting")
            @Expect(snapshot.get("serveLockPresent").getOrThrow().asBool().getValue(), true)
            @Expect(gatewayHeartbeatStatusLogCount(gatewayLoggingCapturedConsoleForTest(), "gateway.runtime_state.persist_failed"), 0)
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            gatewayLoggingResetForTest()
        })
    }

    @TestCase
    public func p5P1BrokerUnresponsiveReadinessAndGenerationRecoveryAreExact(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-broker-recovery", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")
            let client = ManagedStdioBrokerClient(brokerTestMode: true)
            try {
                let old = client.startOwner(ManagedStdioOwnerSpec(
                    "p5-readiness-old",
                    "node",
                    args: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
                    stdinMode: "closed",
                    deadlineMs: 10000
                ))
                @Expect(old.ok, true)
                let initiallyReady = gatewayBuildRuntimeReadinessSnapshot(
                    cfg,
                    user,
                    operational: Some(gatewayStatusOperationalFromBroker(client.snapshot()))
                )
                @Expect(statusTestString(initiallyReady, "status"), "ready")

                @Expect(client.debugHangBrokerForTest(), true)
                let probe = client.probeBrokerForGeneration(old.generation, timeoutMs: 80)
                @Expect(probe.ok, false)
                @Expect(probe.status, "broker_unresponsive")
                let degraded = gatewayBuildRuntimeReadinessSnapshot(
                    cfg,
                    user,
                    operational: Some(gatewayStatusOperationalFromBroker(client.snapshot()))
                )
                @Expect(statusTestString(degraded, "status"), "degraded")
                @Expect(statusTestString(degraded, "reason"), "broker_unresponsive")
                @Expect(gatewayStatusWaitForGone(old.pid, old.pgid), true)
                @Expect(client.snapshot().ownerCount, 0)

                let replacement = client.startOwner(ManagedStdioOwnerSpec(
                    "p5-readiness-replacement",
                    "node",
                    args: ["-e", "console.log('恢复中文🙂')"],
                    stdinMode: "closed",
                    deadlineMs: 2000
                ))
                @Expect(replacement.ok, true)
                @Expect(replacement.generation > old.generation, true)
                var output = ""
                var terminal = false
                let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 3000
                while (!terminal && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
                    match (client.readOwnerLine("p5-readiness-replacement", timeoutMs: 50)) {
                        case Some(event) =>
                            if (event.eventType == "owner.stdout") { output = event.text }
                            if (event.eventType == "owner.exit" || event.eventType == "owner.error") { terminal = true }
                        case None => ()
                    }
                }
                @Expect(terminal, true)
                @Expect(output, "恢复中文🙂")
                let recovered = gatewayBuildRuntimeReadinessSnapshot(
                    cfg,
                    user,
                    operational: Some(gatewayStatusOperationalFromBroker(client.snapshot()))
                )
                @Expect(statusTestString(recovered, "status"), "ready")
                @Expect(statusTestString(recovered, "reason"), "ok")
            } finally {
                let closed = client.close(timeoutMs: 3000)
                @Expect(closed.ok, true)
            }
        })
    }

    @TestCase
    public func p5N1OperationalTransitionLogsAreStableAndDoNotEchoDiagnostics(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-operational-logs", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")
            let secret = "Authorization: Bearer secret-never-visible 中文🙂 /Users/private/never-visible " + "长" * 300
            let failed = gatewayStatusOperational(true, false, secret)
            failed.put("diagnostic", JsonString(secret))

            gatewayLoggingResetForTest()
            gatewayLoggingCaptureConsoleForTest()
            let _ = gatewayBuildRuntimeReadinessSnapshot(cfg, user, operational: Some(failed))
            let _ = gatewayBuildRuntimeReadinessSnapshot(
                cfg,
                user,
                operational: Some(gatewayStatusOperational(true, true, "ready"))
            )
            var rendered = ""
            for (line in gatewayLoggingCapturedConsoleForTest()) { rendered += line + "\n" }
            @Expect(rendered.contains("event=stdio.broker.unresponsive"), true)
            @Expect(rendered.contains("event=gateway.poll.recovered"), true)
            @Expect(rendered.contains("secret-never-visible"), false)
            @Expect(rendered.contains("/Users/private/never-visible"), false)
            gatewayLoggingResetForTest()
        })
    }

    @TestCase
    public func p5U1PollCompletionUpdatesMemoryAndHeartbeatFields(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-poll-snapshot", { =>
            gatewayRuntimeMarkStarting()
            try {
                let operational = gatewayStatusOperational(true, true, "ready", queueDepth: 7)
                gatewayRuntimeMarkPollCompleted(operational)
                let snapshot = gatewayRuntimeSnapshot()
                @Expect(statusTestInt(snapshot, "lastPollAtMs") > 0, true)
                @Expect(statusTestInt(snapshot, "pollLagMs") >= 0, true)
                @Expect(snapshot.get("brokerAlive").getOrThrow().asBool().getValue(), true)
                @Expect(snapshot.get("brokerResponsive").getOrThrow().asBool().getValue(), true)
                @Expect(statusTestInt(snapshot, "brokerGeneration"), 1)
                @Expect(statusTestInt(snapshot, "brokerOwnerCount"), 0)
                @Expect(statusTestInt(snapshot, "inboundQueueDepth"), 7)
            } finally {
                gatewayRuntimeMarkStopped(reason: "test-complete")
            }
        })
    }

    @TestCase
    public func hbHS2U1StatusRpcPreservesRuntimeFields(): Unit {
        withGatewayStatusTestSettings<Unit>("hb-h-s2-u1-status-runtime", { =>
            let oldPath = gatewayHeartbeatStatusInstallLsofMarker(CliConfig.dotDir.join("lsof-called"))
            gatewayRuntimeMarkStarting()
            try {
                gatewayRuntimeMarkRunning()
                gatewayRuntimeMarkPollCompleted(
                    gatewayStatusOperational(true, true, "ready", pollLagMs: 7, queueDepth: 9)
                )
                let status = buildGatewayRpcStatusJson(GatewayUserSettings())
                let runtime = statusTestObject(status, "runtime")
                @Expect(runtime.get("running").getOrThrow().asBool().getValue(), true)
                @Expect(runtime.get("status").getOrThrow().asString().getValue(), "running")
                @Expect(runtime.get("reason").getOrThrow().asString().getValue(), "")
                @Expect(runtime.get("startedAtMs").getOrThrow().asInt().getValue() > 0, true)
                @Expect(
                    runtime.get("updatedAtMs").getOrThrow().asInt().getValue() >=
                        runtime.get("startedAtMs").getOrThrow().asInt().getValue(),
                    true
                )
                @Expect(runtime.get("serveLockPresent").getOrThrow().asBool().getValue(), true)
                @Expect(runtime.get("pollLagMs").getOrThrow().asInt().getValue() >= 0, true)
                @Expect(runtime.get("brokerAlive").getOrThrow().asBool().getValue(), true)
                @Expect(runtime.get("brokerResponsive").getOrThrow().asBool().getValue(), true)
                @Expect(runtime.get("brokerStatus").getOrThrow().asString().getValue(), "ready")
                @Expect(runtime.get("brokerGeneration").getOrThrow().asInt().getValue(), 1)
                @Expect(runtime.get("brokerOwnerCount").getOrThrow().asInt().getValue(), 0)
                @Expect(runtime.get("inboundQueueDepth").getOrThrow().asInt().getValue(), 9)
                @Expect(runtime.get("lastPollAtMs").getOrThrow().asInt().getValue() > 0, true)
            } finally {
                gatewayRuntimeMarkStopped(reason: "hb-h-s2-u1-complete")
                gatewayHeartbeatStatusRestorePath(oldPath)
            }
        })
    }

    @TestCase
    public func p5U1ReadinessDistinguishesBrokerPollAndQueueFailures(): Unit {
        withGatewayStatusTestSettings<Unit>("p5-operational", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")

            let healthy = gatewayBuildRuntimeReadinessSnapshot(
                cfg,
                user,
                operational: Some(gatewayStatusOperational(true, true, "ready", pollLagMs: 5000, queueDepth: 127))
            )
            @Expect(statusTestString(healthy, "status"), "ready")
            @Expect(statusTestString(healthy, "reason"), "ok")

            let cases = [
                (gatewayStatusOperational(true, false, "broker_unresponsive"), "broker_unresponsive"),
                (gatewayStatusOperational(false, false, "broker_exited"), "broker_dead"),
                (gatewayStatusOperational(false, false, "broker_unavailable"), "broker_unavailable"),
                (gatewayStatusOperational(true, true, "ready", pollLagMs: 5001), "poll_stale"),
                (gatewayStatusOperational(true, true, "ready", queueDepth: 128), "inbound_queue_full")
            ]
            for ((operational, expectedReason) in cases) {
                let readiness = gatewayBuildRuntimeReadinessSnapshot(cfg, user, operational: Some(operational))
                @Expect(statusTestString(readiness, "status"), "degraded")
                @Expect(statusTestString(readiness, "reason"), expectedReason)
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
            }

            let health = JsonValue.fromStr(gatewayHttpHealthProbeJson(cfg)).asObject()
            @Expect(statusTestString(health, "status"), "live")
            @Expect(health.get("ok").getOrThrow().asBool().getValue(), true)
        })
    }

    @TestCase
    public func healthAndReadinessExposeSharedInspectContext(): Unit {
        let health = handleGatewayStatusFamily("health", GatewayUserSettings()).getOrThrow()
        let healthResult = health.result.toJsonString()
        @Expect(healthResult.contains("surfaces"), true)
        @Expect(healthResult.contains("platform"), true)
        @Expect(healthResult.contains("openclawCompatHost"), true)
        @Expect(healthResult.contains("processIdentity"), true)

        let readiness = handleGatewayStatusFamily("readiness", GatewayUserSettings()).getOrThrow()
        let readinessResult = readiness.result.toJsonString()
        @Expect(readinessResult.contains("surfaces"), true)
        @Expect(readinessResult.contains("platform"), true)
        @Expect(readinessResult.contains("openclawCompatHost"), true)
        @Expect(readinessResult.contains("processIdentity"), true)

        let status = buildGatewayRpcStatusJson(GatewayUserSettings())
        let identity = statusTestObject(status, "processIdentity")
        @Expect(statusTestString(identity, "schema"), "metis.gateway.process.v1")
        @Expect(statusTestString(identity, "buildFingerprint"), gatewayBuildFingerprint())
    }

    @TestCase
    public func failedChannelRuntimeAccountMatchesReadyzStatusHealthAndReadiness(): Unit {
        withGatewayStatusTestSettings<Unit>("failed-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkStarting("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "transport-timeout", errorKind: "start_timeout")

            let readyz = JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject()
            let readyzReadiness = statusTestObject(readyz, "readiness")
            let status = buildGatewayRpcStatusJson(user)
            let statusReadiness = statusTestObject(status, "readiness")
            let statusChannelReadiness = statusTestObject(status, "channelReadiness")
            let health = handleGatewayStatusFamily("health", user).getOrThrow().result.asObject()
            let healthReadiness = statusTestObject(health, "ready")
            let rpcReadiness = handleGatewayStatusFamily("readiness", user).getOrThrow().result.asObject()
            let rpcReadinessReadiness = statusTestObject(rpcReadiness, "readiness")

            for (readiness in [readyzReadiness, statusReadiness, statusChannelReadiness, healthReadiness, rpcReadinessReadiness]) {
                @Expect(statusTestString(readiness, "status"), "degraded")
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("ok").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("failedCount").getOrThrow().toJsonString(), "1")
                let accounts = statusTestArray(readiness, "accounts")
                @Expect(accounts.size(), 1)
                let row = accounts[0].asObject()
                @Expect(statusTestString(row, "channelId"), "telegram")
                @Expect(statusTestString(row, "accountId"), "default")
                @Expect(statusTestString(row, "lifecycleState"), "failed")
                @Expect(statusTestString(row, "lastError"), "transport-timeout")
                @Expect(statusTestString(row, "errorKind"), "start_timeout")
            }
        })
    }

    @TestCase
    public func startingChannelRuntimeAccountIsNotReportedOk(): Unit {
        withGatewayStatusTestSettings<Unit>("starting-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkStarting("telegram", accountId: "default")

            let readyzReadiness = statusTestObject(JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject(), "readiness")
            let statusReadiness = statusTestObject(buildGatewayRpcStatusJson(user), "readiness")
            let rpcReadinessReadiness = statusTestObject(handleGatewayStatusFamily("readiness", user).getOrThrow().result.asObject(), "readiness")

            for (readiness in [readyzReadiness, statusReadiness, rpcReadinessReadiness]) {
                @Expect(statusTestString(readiness, "status"), "starting")
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("ok").getOrThrow().asBool().getValue(), false)
                @Expect(readiness.get("startingCount").getOrThrow().toJsonString(), "1")
            }
        })
    }

    @TestCase
    public func disabledAndUnconfiguredRuntimeAccountsDoNotFailReadiness(): Unit {
        withGatewayStatusTestSettings<Unit>("disabled-runtime", { =>
            let user = gatewayStatusTestUser()
            gatewayStatusPersistUser(user)
            let cfg = buildGatewayConfigFromUserSettings(user)
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkRunning("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "disabled", enabled: false, configured: true)
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "disabled", error: "disabled", errorKind: "disabled")
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "unconfigured", enabled: true, configured: false)
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "unconfigured", error: "account-not-configured", errorKind: "account_not_configured")

            let readyzReadiness = statusTestObject(JsonValue.fromStr(gatewayHttpReadyProbeJson(cfg)).asObject(), "readiness")
            let statusReadiness = statusTestObject(buildGatewayRpcStatusJson(user), "readiness")

            for (readiness in [readyzReadiness, statusReadiness]) {
                @Expect(statusTestString(readiness, "status"), "ready")
                @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), true)
                @Expect(readiness.get("failedCount").getOrThrow().toJsonString(), "0")
                @Expect(statusTestArray(readiness, "accounts").size(), 0)
            }
        })
    }

    @TestCase
    public func readinessAccountDetailsRedactSecretLikeErrors(): Unit {
        withGatewayStatusTestSettings<Unit>("redacted-runtime", { =>
            let user = gatewayStatusTestUser()
            let secret = "appSecret=app-secret-never-visible Authorization: Bearer bearer-never-visible bot token=bot-token-never-visible proxy password=proxy-never-visible"
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: secret, errorKind: "start_failed")

            let status = buildGatewayRpcStatusJson(user)
            let rendered = status.toJsonString()
            @Expect(rendered.contains("app-secret-never-visible"), false)
            @Expect(rendered.contains("bearer-never-visible"), false)
            @Expect(rendered.contains("bot-token-never-visible"), false)
            @Expect(rendered.contains("proxy-never-visible"), false)
            @Expect(rendered.contains("redacted"), true)

            let readiness = statusTestObject(status, "channelReadiness")
            let accounts = statusTestArray(readiness, "accounts")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(statusTestString(row, "lastError").contains("redacted"), true)
            @Expect(statusTestString(row, "errorKind"), "start_failed")
        })
    }

    @TestCase
    public func runtimeConfigDriftReportsStaleAndNotStartedAccounts(): Unit {
        withGatewayStatusTestSettings<Unit>("runtime-config-drift", { =>
            var user = GatewayUserSettings()
            user.auth.mode = "none"
            user.feishu.enabled = true
            user.feishu.appId = "feishu-app"
            user.feishu.appSecret = "feishu-secret"
            let _ = gatewayChannelRuntimeRegisterAccount("feishu", accountId: "xiaohongshu-ceo")
            let _ = gatewayChannelRuntimeMarkRunning("feishu", accountId: "xiaohongshu-ceo")

            let status = buildGatewayRpcStatusJson(user)
            let readiness = statusTestObject(status, "channelReadiness")
            let drift = statusTestObject(readiness, "runtimeConfigDrift")
            let stale = statusTestArray(drift, "staleRunningAccounts")
            let notStarted = statusTestArray(drift, "notStartedConfiguredAccounts")

            @Expect(statusTestString(readiness, "status"), "degraded")
            @Expect(stale.size(), 1)
            @Expect(statusTestString(stale[0].asObject(), "accountId"), "xiaohongshu-ceo")
            @Expect(statusTestString(stale[0].asObject(), "reason"), "stale-runtime-account")
            @Expect(statusTestString(stale[0].asObject(), "suggestedAction"), "reload-channel:feishu")
            @Expect(notStarted.size(), 1)
            @Expect(statusTestString(notStarted[0].asObject(), "accountId"), "default")
            @Expect(statusTestString(notStarted[0].asObject(), "reason"), "configured-account-not-started")
        })
    }

    @TestCase
    public func driftDiagnosticsExposeCredentialAndSidecarActionsWithoutSecrets(): Unit {
        withGatewayStatusTestSettings<Unit>("runtime-config-actions", { =>
            var user = GatewayUserSettings()
            user.auth.mode = "none"
            user.feishu.enabled = true
            user.feishu.appId = "feishu-app"
            user.feishu.appSecret = "feishu-secret"
            let _ = gatewayChannelRuntimeRegisterAccount("feishu", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("feishu", accountId: "default", error: "transport-timeout appSecret=hidden-secret", errorKind: "start_timeout")

            let status = buildGatewayRpcStatusJson(user)
            let rendered = status.toJsonString()
            @Expect(rendered.contains("hidden-secret"), false)
            let readiness = statusTestObject(status, "channelReadiness")
            let accounts = statusTestArray(readiness, "accounts")
            @Expect(accounts.size(), 1)
            let row = accounts[0].asObject()
            @Expect(statusTestString(row, "reason"), "transport-start-timeout")
            @Expect(statusTestString(row, "suggestedAction"), "check-channel-transport")
            @Expect(statusTestString(row, "lastError").contains("redacted"), true)
        })
    }

    @TestCase
    public func doctorUsesRuntimeReadinessSnapshot(): Unit {
        withGatewayStatusTestSettings<Unit>("doctor-runtime", { =>
            let user = gatewayStatusTestUser()
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "doctor-start-failed", errorKind: "start_failed")

            let response = handleGatewayOpsFamily("doctor", user).getOrThrow()
            let doctor = statusTestObject(response.result.asObject(), "doctor")
            let readiness = statusTestObject(doctor, "readiness")
            @Expect(statusTestString(readiness, "status"), "degraded")
            @Expect(readiness.get("ready").getOrThrow().asBool().getValue(), false)
            @Expect(statusTestArray(readiness, "accounts").size(), 1)
        })
    }

    @TestCase
    public func humanCliStatusOutputDoesNotExposeRawJsonAfterChannelReadinessFields(): Unit {
        withGatewayStatusTestSettings<Unit>("human-cli", { =>
            let user = gatewayStatusTestUser()
            let _ = gatewayChannelRuntimeRegisterAccount("telegram", accountId: "default")
            let _ = gatewayChannelRuntimeMarkFailure("telegram", accountId: "default", error: "cli-start-failed", errorKind: "start_failed")
            let response = GatewayRpcResponse(true, "status", result: buildGatewayRpcStatusJson(user)).toJson().toJsonString()
            let rendered = gatewayFormatCommandOutput(response)
            @Expect(rendered.contains("Gateway call: status"), true)
            @Expect(rendered.contains("\"ok\""), false)
            @Expect(rendered.contains("\"channelReadiness\""), false)
        })
    }
}
