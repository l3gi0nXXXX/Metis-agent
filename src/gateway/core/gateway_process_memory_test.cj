package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager}
import metis.gateway.logging.gatewayLoggingResetForTest

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.sync.Mutex
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonValue}

private class GatewayMemoryRssProbe {
    private let lock = Mutex()
    private let values: Array<Int64>
    private var index: Int64 = 0

    public init(values: Array<Int64>) {
        this.values = values
    }

    public func next(): Int64 {
        synchronized(this.lock) {
            let current = this.index
            this.index += 1
            if (current >= 0 && current < this.values.size) {
                return this.values[current]
            }
            if (this.values.isEmpty()) { -1 } else { this.values[this.values.size - 1] }
        }
    }

    public func calls(): Int64 {
        synchronized(this.lock) { this.index }
    }
}

private class GatewayMemoryFailingRssProbe {
    private let lock = Mutex()
    private var callCount: Int64 = 0

    public func next(): Int64 {
        synchronized(this.lock) { this.callCount += 1 }
        throw Exception("synthetic RSS failure Authorization: Bearer must-not-leak")
    }

    public func calls(): Int64 {
        synchronized(this.lock) { this.callCount }
    }
}

private func gatewayMemoryTestRestoreEnv(name: String, oldValue: Option<String>): Unit {
    match (oldValue) {
        case Some(value) => setVariable(name, value)
        case None => setVariable(name, "")
    }
}

private func gatewayMemoryTestHome(label: String): Path {
    let path = Path("/tmp/metis-memory-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(path, recursive: true)
    path
}

private func gatewayMemoryTestRows(path: Path): Array<JsonObject> {
    let raw = try {
        String.fromUtf8(File.readFrom(path))
    } catch (_: Exception) {
        ""
    }
    let rows = ArrayList<JsonObject>()
    for (line in raw.split("\n")) {
        let trimmed = line.trimAscii()
        if (!trimmed.isEmpty()) {
            try {
                rows.add(JsonValue.fromStr(trimmed).asObject())
            } catch (_: Exception) {
                ()
            }
        }
    }
    rows.toArray()
}

private func gatewayMemoryTestSetup(home: Path, file: Path): Unit {
    setVariable("METIS_HOME", home.toString())
    setVariable("METIS_LOG_FILE", file.toString())
    setVariable("METIS_LOG_LEVEL", "debug")
    setVariable("METIS_CONSOLE_LEVEL", "silent")
    CliConfig.invalidatePathCache()
    CliSettingManager.invalidate()
    gatewayLoggingResetForTest()
    resetGatewayMemoryObservationForTest()
}

private func gatewayMemoryTestCleanup(
    home: Path,
    oldHome: Option<String>,
    oldFile: Option<String>,
    oldLevel: Option<String>,
    oldConsoleLevel: Option<String>
): Unit {
    resetGatewayMemoryObservationForTest()
    gatewayMemoryTestRestoreEnv("METIS_HOME", oldHome)
    gatewayMemoryTestRestoreEnv("METIS_LOG_FILE", oldFile)
    gatewayMemoryTestRestoreEnv("METIS_LOG_LEVEL", oldLevel)
    gatewayMemoryTestRestoreEnv("METIS_CONSOLE_LEVEL", oldConsoleLevel)
    CliConfig.invalidatePathCache()
    CliSettingManager.invalidate()
    gatewayLoggingResetForTest()
    try { remove(home, recursive: true) } catch (_: Exception) { () }
}

@Test
public class GatewayProcessMemoryTest {
    @TestCase
    public func s0U1ObservationRecordsRssDeltaAndStableSequence(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s0-u1")
        let file = home.join("memory.log")
        let probe = GatewayMemoryRssProbe([1000, 1200, 1300])
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            let observation = gatewayBeginMemoryObservation("session-hash", channel: "gitcode", agentId: "writer", model: "fake")
            @Expect(observation.turnSequence, 1)
            @Expect(observation.sampled, true)
            @Expect(gatewayObserveMemoryStage(observation, "turn_enter"), true)
            @Expect(gatewayObserveMemoryStage(observation, "history_loaded"), true)
            let rows = gatewayMemoryTestRows(file)
            @Expect(rows.size, 2)
            @Expect(rows[0].get("rssKb").getOrThrow().asInt().getValue(), 1000)
            @Expect(rows[0].get("rssDeltaKb").getOrThrow().asInt().getValue(), 0)
            @Expect(rows[1].get("rssKb").getOrThrow().asInt().getValue(), 1200)
            @Expect(rows[1].get("rssDeltaKb").getOrThrow().asInt().getValue(), 200)
            @Expect(rows[1].get("turnSequence").getOrThrow().asInt().getValue(), 1)
            @Expect(gatewayFinishMemoryObservation(observation), true)
            @Expect(gatewayFinishMemoryObservation(observation), false)
            let counters = gatewayMemoryObservationCountersForTest()
            @Expect(counters[1], 0)
            @Expect(counters[2], 1)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s0B1SamplingUsesFirstThreeAndEveryFifthTurnOnly(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s0-b1")
        let file = home.join("memory.log")
        let probe = GatewayMemoryRssProbe([1000])
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            for (i in 1..=13) {
                let observation = gatewayBeginMemoryObservation("session-${i}")
                let _ = gatewayObserveMemoryStage(observation, "turn_enter")
                let _ = if (i == 4) {
                    gatewayFinishMemoryObservation(observation, status: "failed", errorKind: "model_failed")
                } else {
                    gatewayFinishMemoryObservation(observation)
                }
            }
            @Expect(probe.calls(), 11)
            let sampled = ArrayList<Int64>()
            var unsampledFailureExit = 0
            var unsampledFailureSummary = 0
            for (row in gatewayMemoryTestRows(file)) {
                if (row.get("stage").getOrThrow().asString().getValue() == "turn_enter") {
                    sampled.add(row.get("turnSequence").getOrThrow().asInt().getValue())
                }
                if (
                    row.get("turnSequence").getOrThrow().asInt().getValue() == 4 &&
                    !row.get("sampled").getOrThrow().asBool().getValue() &&
                    row.get("status").getOrThrow().asString().getValue() == "failed"
                ) {
                    if (row.get("stage").getOrThrow().asString().getValue() == "turn_exit") {
                        unsampledFailureExit += 1
                    }
                    if (row.get("stage").getOrThrow().asString().getValue() == "turn_summary") {
                        unsampledFailureSummary += 1
                    }
                }
            }
            @Expect(sampled.toArray(), [1, 2, 3, 5, 10])
            @Expect(unsampledFailureExit, 1)
            @Expect(unsampledFailureSummary, 1)
            let counters = gatewayMemoryObservationCountersForTest()
            @Expect(counters[0], 13)
            @Expect(counters[1], 0)
            @Expect(counters[2], 13)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s0N1RssFailureAndUnknownStageFailClosedWithoutSensitiveOutput(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s0-n1")
        let file = home.join("memory.log")
        let probe = GatewayMemoryFailingRssProbe()
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            let observation = gatewayBeginMemoryObservation("redacted-session")
            @Expect(gatewayObserveMemoryStage(observation, "turn_enter"), true)
            @Expect(probe.calls(), 1)
            @Expect(gatewayObserveMemoryStage(observation, "not_a_stage"), false)
            @Expect(probe.calls(), 1)
            @Expect(gatewayFinishMemoryObservation(observation, status: "failed", errorKind: "model_failed"), true)
            let rows = gatewayMemoryTestRows(file)
            @Expect(rows[0].get("rssKb").getOrThrow().asInt().getValue(), -1)
            @Expect(rows[0].get("rssDeltaKb").getOrThrow().asInt().getValue(), -1)
            let raw = try {
                String.fromUtf8(File.readFrom(file))
            } catch (_: Exception) {
                ""
            }
            @Expect(raw.contains("must-not-leak"), false)
            @Expect(raw.contains("Authorization"), false)
            @Expect(raw.contains("not_a_stage"), false)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s2P1ReleasedStageKeepsTurnCorrelationAndSchedulerScalars(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s2-p1")
        let file = home.join("memory.log")
        let probe = GatewayMemoryRssProbe([1000, 1100, 1200])
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            let observation = gatewayBeginMemoryObservation("session-hash", channel: "gitcode")
            let _ = gatewayObserveMemoryStage(observation, "turn_enter")
            let baseline = observation.memorySnapshot()[0]
            let _ = gatewayFinishMemoryObservation(observation)
            let released = gatewayLogServicePluginTurnReleased(
                observation.turnSequence,
                observation.sampled,
                baseline,
                observation.sessionHash,
                meta: gatewayLogMeta()
                    .int("dispatchActive", 2)
                    .int("dispatchQueued", 30)
                    .int("dispatchFutures", 2)
                    .object()
            )
            @Expect(released, true)
            let rows = gatewayMemoryTestRows(file)
            let row = rows[rows.size - 1]
            @Expect(row.get("stage").getOrThrow().asString().getValue(), "service_plugin_turn_released")
            @Expect(row.get("turnSequence").getOrThrow().asInt().getValue(), observation.turnSequence)
            @Expect(row.get("sessionHash").getOrThrow().asString().getValue(), "session-hash")
            @Expect(row.get("rssKb").getOrThrow().asInt().getValue(), 1200)
            @Expect(row.get("rssDeltaKb").getOrThrow().asInt().getValue(), 200)
            @Expect(row.get("dispatchActive").getOrThrow().asInt().getValue(), 2)
            @Expect(row.get("dispatchQueued").getOrThrow().asInt().getValue(), 30)
            @Expect(row.get("dispatchFutures").getOrThrow().asInt().getValue(), 2)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s2N1UnsampledReleasedStageDoesNotProbeOrWrite(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s2-n1")
        let file = home.join("memory.log")
        let probe = GatewayMemoryRssProbe([1000])
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            for (_ in 0..3) {
                let sampled = gatewayBeginMemoryObservation("sampled")
                let _ = gatewayFinishMemoryObservation(sampled)
            }
            let observation = gatewayBeginMemoryObservation("unsampled")
            @Expect(observation.sampled, false)
            let callsBefore = probe.calls()
            @Expect(gatewayLogServicePluginTurnReleased(4, false, -1, "unsampled"), false)
            @Expect(probe.calls(), callsBefore)
            for (row in gatewayMemoryTestRows(file)) {
                @Expect(row.get("turnSequence").getOrThrow().asInt().getValue() == 4, false)
            }
            let _ = gatewayFinishMemoryObservation(observation)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }
}
