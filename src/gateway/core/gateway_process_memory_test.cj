package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager}
import metis.gateway.logging.gatewayLoggingResetForTest

import std.collection.{ArrayList, HashMap, HashSet}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
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

public class GatewayMemoryAnalysisForTest {
    public let status: String
    public let sampledTurns: Int64
    public let enterRssSlopeKbPerTurn: Int64
    public let lateEnterRssSlopeKbPerTurn: Int64
    public let providerDeltaKb: Int64
    public let correctionDeltaKb: Int64
    public let persistDeltaKb: Int64
    public let releaseDeltaKb: Int64
    public let settledFloorKb: Int64

    public init(
        status: String,
        sampledTurns: Int64,
        enterRssSlopeKbPerTurn: Int64,
        lateEnterRssSlopeKbPerTurn: Int64,
        providerDeltaKb: Int64,
        correctionDeltaKb: Int64,
        persistDeltaKb: Int64,
        releaseDeltaKb: Int64,
        settledFloorKb: Int64
    ) {
        this.status = status
        this.sampledTurns = sampledTurns
        this.enterRssSlopeKbPerTurn = enterRssSlopeKbPerTurn
        this.lateEnterRssSlopeKbPerTurn = lateEnterRssSlopeKbPerTurn
        this.providerDeltaKb = providerDeltaKb
        this.correctionDeltaKb = correctionDeltaKb
        this.persistDeltaKb = persistDeltaKb
        this.releaseDeltaKb = releaseDeltaKb
        this.settledFloorKb = settledFloorKb
    }
}

public func gatewayMemoryApplyExternalThresholdForTest(
    samples: Array<JsonObject>,
    thresholdKb: Int64,
    formalStop: () -> Bool
): String {
    var previousSequence: Int64 = 0
    for (sample in samples) {
        try {
            let sequence = sample.get("sampleSequence").getOrThrow().asInt().getValue()
            let rssKb = sample.get("rssKb").getOrThrow().asInt().getValue()
            if (sequence <= previousSequence || rssKb < 0) { return "evidence_incomplete" }
            previousSequence = sequence
            if (rssKb >= thresholdKb) {
                return if (formalStop()) { "formal_stop_completed" } else { "formal_stop_failed" }
            }
        } catch (_: Exception) {
            return "evidence_incomplete"
        }
    }
    "threshold_not_reached"
}

public func gatewayMemoryHistoricalClassificationForTest(events: Array<String>): String {
    var oomIndex: Int64 = -1
    var shutdownIndex: Int64 = -1
    var brokerFailureIndex: Int64 = -1
    for (i in 0..events.size) {
        let event = events[i].trimAscii()
        if (event == "out_of_memory" && oomIndex < 0) { oomIndex = Int64(i) }
        if (event == "gateway_shutdown_started" && shutdownIndex < 0) { shutdownIndex = Int64(i) }
        if (event == "stdio_broker_writer_failed" && brokerFailureIndex < 0) { brokerFailureIndex = Int64(i) }
    }
    if (oomIndex < 0 || shutdownIndex < 0 || brokerFailureIndex < 0) { return "evidence_incomplete" }
    if (oomIndex < shutdownIndex && shutdownIndex < brokerFailureIndex) { return "oom_precedes_cleanup_failure" }
    "ordering_inconsistent"
}

private func gatewayMemoryAnalysisKey(sequence: Int64, stage: String): String {
    "${sequence}:${stage.trimAscii()}"
}

public func gatewayMemoryAnalyzeRowsForTest(rows: Array<JsonObject>): GatewayMemoryAnalysisForTest {
    let values = HashMap<String, Int64>()
    let sequences = HashSet<Int64>()
    var invalid = false
    var firstSequence: Int64 = -1
    var lastSequence: Int64 = -1
    var firstEnter: Int64 = -1
    var lastEnter: Int64 = -1
    var settledFloor: Int64 = -1
    for (row in rows) {
        try {
            let sequence = row.get("turnSequence").getOrThrow().asInt().getValue()
            let stage = row.get("stage").getOrThrow().asString().getValue()
            let rss = row.get("rssKb").getOrThrow().asInt().getValue()
            if (stage == "turn_summary") { continue }
            if (sequence <= 0 || stage.isEmpty() || rss < 0) {
                invalid = true
                continue
            }
            values[gatewayMemoryAnalysisKey(sequence, stage)] = rss
            sequences.add(sequence)
            if (stage == "turn_enter") {
                if (firstSequence < 0 || sequence < firstSequence) {
                    firstSequence = sequence
                    firstEnter = rss
                }
                if (lastSequence < 0 || sequence > lastSequence) {
                    lastSequence = sequence
                    lastEnter = rss
                }
            }
            if (stage == "service_plugin_turn_released" && row.get("activeTurns").getOrThrow().asInt().getValue() == 0) {
                if (sequence >= lastSequence) { settledFloor = rss }
            }
        } catch (_: Exception) {
            invalid = true
        }
    }
    var providerTotal: Int64 = 0
    var correctionTotal: Int64 = 0
    var persistTotal: Int64 = 0
    var releaseTotal: Int64 = 0
    var completeTurns: Int64 = 0
    for (sequence in sequences) {
        let system = values.get(gatewayMemoryAnalysisKey(sequence, "system_prompt_built"))
        let returned = values.get(gatewayMemoryAnalysisKey(sequence, "model_returned"))
        let corrected = values.get(gatewayMemoryAnalysisKey(sequence, "final_correction_ready"))
        let persisted = values.get(gatewayMemoryAnalysisKey(sequence, "session_persisted"))
        let exited = values.get(gatewayMemoryAnalysisKey(sequence, "turn_exit"))
        let released = values.get(gatewayMemoryAnalysisKey(sequence, "service_plugin_turn_released"))
        match ((system, returned, corrected, persisted, exited, released)) {
            case (Some(a), Some(b), Some(c), Some(d), Some(e), Some(f)) =>
                providerTotal += b - a
                correctionTotal += c - b
                persistTotal += d - c
                releaseTotal += f - e
                completeTurns++
            case _ => invalid = true
        }
    }
    if (invalid || completeTurns == 0 || firstSequence <= 0 || lastSequence <= firstSequence || settledFloor < 0) {
        return GatewayMemoryAnalysisForTest("evidence_incomplete", completeTurns, -1, -1, -1, -1, -1, -1, settledFloor)
    }
    let midpoint = firstSequence + (lastSequence - firstSequence) / 2
    var lateFirstSequence: Int64 = -1
    var lateLastSequence: Int64 = -1
    var lateFirstEnter: Int64 = -1
    var lateLastEnter: Int64 = -1
    for (sequence in sequences) {
        if (sequence < midpoint) { continue }
        match (values.get(gatewayMemoryAnalysisKey(sequence, "turn_enter"))) {
            case Some(rss) =>
                if (lateFirstSequence < 0 || sequence < lateFirstSequence) {
                    lateFirstSequence = sequence
                    lateFirstEnter = rss
                }
                if (lateLastSequence < 0 || sequence > lateLastSequence) {
                    lateLastSequence = sequence
                    lateLastEnter = rss
                }
            case None => ()
        }
    }
    let fullSlope = (lastEnter - firstEnter) / (lastSequence - firstSequence)
    let lateSlope = if (lateFirstSequence >= 0 && lateLastSequence > lateFirstSequence) {
        (lateLastEnter - lateFirstEnter) / (lateLastSequence - lateFirstSequence)
    } else {
        fullSlope
    }
    GatewayMemoryAnalysisForTest(
        "complete",
        completeTurns,
        fullSlope,
        lateSlope,
        providerTotal / completeTurns,
        correctionTotal / completeTurns,
        persistTotal / completeTurns,
        releaseTotal / completeTurns,
        settledFloor
    )
}

private func gatewayMemorySyntheticRow(sequence: Int64, stage: String, rssKb: Int64, activeTurns!: Int64 = 1): JsonObject {
    gatewayLogMeta()
        .string("event", "process.memory")
        .int("turnSequence", sequence)
        .string("stage", stage)
        .int("rssKb", rssKb)
        .int("activeTurns", activeTurns)
        .object()
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

    @TestCase
    public func s3U1HundredFakeTurnsKeepSamplingAndLogVolumeBounded(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s3-u1")
        let file = home.join("memory.log")
        let probe = GatewayMemoryRssProbe([4096])
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            for (i in 1..=100) {
                let observation = gatewayBeginMemoryObservation("session-hash-${i}", channel: "gitcode", model: "fake")
                let _ = gatewayObserveMemoryStage(observation, "turn_enter")
                let _ = gatewayObserveMemoryStage(observation, "history_loaded")
                let _ = gatewayObserveMemoryStage(observation, "model_input_built")
                let _ = gatewayObserveMemoryStage(observation, "system_prompt_built")
                let _ = gatewayObserveMemoryStage(observation, "model_returned")
                let _ = gatewayObserveMemoryStage(observation, "final_correction_ready")
                let _ = gatewayObserveMemoryStage(observation, "session_persisted")
                let baseline = observation.memorySnapshot()[0]
                let _ = gatewayFinishMemoryObservation(observation)
                let _ = gatewayLogServicePluginTurnReleased(
                    observation.turnSequence,
                    observation.sampled,
                    baseline,
                    observation.sessionHash,
                    meta: gatewayLogMeta().int("dispatchActive", 0).int("dispatchQueued", 0).object()
                )
            }
            let rows = gatewayMemoryTestRows(file)
            var debugRows: Int64 = 0
            var infoRows: Int64 = 0
            let sampledSequences = HashSet<Int64>()
            for (row in rows) {
                if (row.get("level").getOrThrow().asString().getValue() == "debug") {
                    debugRows += 1
                } else if (row.get("level").getOrThrow().asString().getValue() == "info") {
                    infoRows += 1
                }
                sampledSequences.add(row.get("turnSequence").getOrThrow().asInt().getValue())
            }
            @Expect(sampledSequences.size, 23)
            @Expect(debugRows, 23 * 9)
            @Expect(infoRows, 23)
            @Expect(rows.size, 23 * 10)
            @Expect(probe.calls(), 207)
            let counters = gatewayMemoryObservationCountersForTest()
            @Expect(counters[0], 100)
            @Expect(counters[1], 0)
            @Expect(counters[2], 100)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s3B1OverlappingTurnsRemainCorrelatedWhenCompletionIsReversed(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s3-b1")
        let file = home.join("memory.log")
        try {
            gatewayMemoryTestSetup(home, file)
            setGatewayProcessRssProviderForTest(Some({ => 8192 }))
            let first = gatewayBeginMemoryObservation("session-first", channel: "gitcode", model: "stream")
            let second = gatewayBeginMemoryObservation("session-second", channel: "gitcode", model: "ordinary")
            let _ = gatewayObserveMemoryStage(first, "turn_enter")
            let _ = gatewayObserveMemoryStage(second, "turn_enter")
            let _ = gatewayFinishMemoryObservation(second)
            let _ = gatewayFinishMemoryObservation(first)
            var peakActive: Int64 = 0
            var firstRows: Int64 = 0
            var secondRows: Int64 = 0
            for (row in gatewayMemoryTestRows(file)) {
                let active = row.get("activeTurns").getOrThrow().asInt().getValue()
                if (active > peakActive) { peakActive = active }
                let sequence = row.get("turnSequence").getOrThrow().asInt().getValue()
                let sessionHash = row.get("sessionHash").getOrThrow().asString().getValue()
                if (sequence == first.turnSequence) {
                    firstRows += 1
                    @Expect(sessionHash, "session-first")
                } else if (sequence == second.turnSequence) {
                    secondRows += 1
                    @Expect(sessionHash, "session-second")
                } else {
                    @Expect(false, true)
                }
            }
            @Expect(first.turnSequence != second.turnSequence, true)
            @Expect(peakActive, 2)
            @Expect(firstRows, 3)
            @Expect(secondRows, 3)
            let counters = gatewayMemoryObservationCountersForTest()
            @Expect(counters[1], 0)
            @Expect(counters[2], 2)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s3N1LoggerAndRssFailuresDoNotChangeTurnTruth(): Unit {
        let oldHome = getVariable("METIS_HOME")
        let oldFile = getVariable("METIS_LOG_FILE")
        let oldLevel = getVariable("METIS_LOG_LEVEL")
        let oldConsoleLevel = getVariable("METIS_CONSOLE_LEVEL")
        let home = gatewayMemoryTestHome("s3-n1")
        let probe = GatewayMemoryFailingRssProbe()
        try {
            gatewayMemoryTestSetup(home, home)
            setGatewayProcessRssProviderForTest(Some({ => probe.next() }))
            let observation = gatewayBeginMemoryObservation("safe-session-hash", channel: "gitcode", model: "fake")
            @Expect(gatewayObserveMemoryStage(
                observation,
                "turn_enter",
                meta: gatewayLogMeta().int("promptChars", 9).object()
            ), true)
            @Expect(gatewayFinishMemoryObservation(observation, status: "failed", errorKind: "model_failed"), true)
            @Expect(probe.calls(), 2)
            let counters = gatewayMemoryObservationCountersForTest()
            @Expect(counters[0], 1)
            @Expect(counters[1], 0)
            @Expect(counters[2], 1)
            @Expect(exists(home), true)
        } finally {
            gatewayMemoryTestCleanup(home, oldHome, oldFile, oldLevel, oldConsoleLevel)
        }
    }

    @TestCase
    public func s4U1SyntheticRowsProduceExactStageDeltasAndSlope(): Unit {
        let rows = ArrayList<JsonObject>()
        for (row in [
            gatewayMemorySyntheticRow(1, "turn_enter", 100),
            gatewayMemorySyntheticRow(1, "system_prompt_built", 120),
            gatewayMemorySyntheticRow(1, "model_returned", 150),
            gatewayMemorySyntheticRow(1, "final_correction_ready", 160),
            gatewayMemorySyntheticRow(1, "session_persisted", 170),
            gatewayMemorySyntheticRow(1, "turn_exit", 175, activeTurns: 1),
            gatewayMemorySyntheticRow(1, "service_plugin_turn_released", 180, activeTurns: 0),
            gatewayMemorySyntheticRow(2, "turn_enter", 110),
            gatewayMemorySyntheticRow(2, "system_prompt_built", 130),
            gatewayMemorySyntheticRow(2, "model_returned", 160),
            gatewayMemorySyntheticRow(2, "final_correction_ready", 170),
            gatewayMemorySyntheticRow(2, "session_persisted", 185),
            gatewayMemorySyntheticRow(2, "turn_exit", 190, activeTurns: 1),
            gatewayMemorySyntheticRow(2, "service_plugin_turn_released", 200, activeTurns: 0)
        ]) { rows.add(row) }
        let analysis = gatewayMemoryAnalyzeRowsForTest(rows.toArray())
        @Expect(analysis.status, "complete")
        @Expect(analysis.sampledTurns, 2)
        @Expect(analysis.enterRssSlopeKbPerTurn, 10)
        @Expect(analysis.lateEnterRssSlopeKbPerTurn, 10)
        @Expect(analysis.providerDeltaKb, 30)
        @Expect(analysis.correctionDeltaKb, 10)
        @Expect(analysis.persistDeltaKb, 12)
        @Expect(analysis.releaseDeltaKb, 7)
        @Expect(analysis.settledFloorKb, 200)
    }

    @TestCase
    public func s4N1MissingStageAndInvalidRssDowngradeToIncompleteEvidence(): Unit {
        let missingRelease = [
            gatewayMemorySyntheticRow(1, "turn_enter", 100),
            gatewayMemorySyntheticRow(1, "system_prompt_built", 120),
            gatewayMemorySyntheticRow(1, "model_returned", 150),
            gatewayMemorySyntheticRow(1, "final_correction_ready", 160),
            gatewayMemorySyntheticRow(1, "session_persisted", 170),
            gatewayMemorySyntheticRow(1, "turn_exit", 175)
        ]
        let missing = gatewayMemoryAnalyzeRowsForTest(missingRelease)
        @Expect(missing.status, "evidence_incomplete")
        @Expect(missing.enterRssSlopeKbPerTurn, -1)
        @Expect(missing.lateEnterRssSlopeKbPerTurn, -1)

        let invalidRss = [
            gatewayMemorySyntheticRow(1, "turn_enter", -1),
            gatewayMemorySyntheticRow(1, "service_plugin_turn_released", -1, activeTurns: 0)
        ]
        let invalid = gatewayMemoryAnalyzeRowsForTest(invalidRss)
        @Expect(invalid.status, "evidence_incomplete")
        @Expect(invalid.providerDeltaKb, -1)
        @Expect(invalid.settledFloorKb, -1)
    }

    @TestCase
    public func s4B1ExternalSamplerThresholdRequestsFormalStopExactlyOnce(): Unit {
        let samples = [
            gatewayLogMeta().int("sampleSequence", 1).int("rssKb", 120000).object(),
            gatewayLogMeta().int("sampleSequence", 2).int("rssKb", 180000).object(),
            gatewayLogMeta().int("sampleSequence", 3).int("rssKb", 260000).object()
        ]
        let stopCalls = ArrayList<Bool>()
        let result = gatewayMemoryApplyExternalThresholdForTest(samples, 200000, { =>
            stopCalls.add(true)
            true
        })
        @Expect(result, "formal_stop_completed")
        @Expect(stopCalls.size, 1)

        let interrupted = gatewayMemoryApplyExternalThresholdForTest([
            gatewayLogMeta().int("sampleSequence", 1).int("rssKb", 100000).object(),
            gatewayLogMeta().int("sampleSequence", 1).int("rssKb", 110000).object()
        ], 200000, { => true })
        @Expect(interrupted, "evidence_incomplete")
    }

    @TestCase
    public func hS401OomPrecedesShutdownAndBrokerWriterFailure(): Unit {
        @Expect(gatewayMemoryHistoricalClassificationForTest([
            "out_of_memory",
            "gateway_shutdown_started",
            "stdio_broker_writer_failed"
        ]), "oom_precedes_cleanup_failure")
        @Expect(gatewayMemoryHistoricalClassificationForTest([
            "gateway_shutdown_started",
            "stdio_broker_writer_failed"
        ]), "evidence_incomplete")
        @Expect(gatewayMemoryHistoricalClassificationForTest([
            "stdio_broker_writer_failed",
            "out_of_memory",
            "gateway_shutdown_started"
        ]), "ordering_inconsistent")
    }
}
