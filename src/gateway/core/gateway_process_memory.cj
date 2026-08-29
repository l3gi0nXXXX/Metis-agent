package metis.gateway.core

import std.convert.Parsable
import std.process.executeWithOutput
import std.sync.Mutex
import std.time.MonoTime
import stdx.encoding.json.{JsonInt, JsonObject}

private let gatewayMemoryObservationStateLock = Mutex()
private let gatewayMemoryObservationMonotonicOrigin = MonoTime.now()
private var gatewayMemoryObservationNextSequence: Int64 = 0
private var gatewayMemoryObservationActiveTurns: Int64 = 0
private var gatewayMemoryObservationCompletedTurns: Int64 = 0
private var gatewayProcessRssProviderForTest: Option<() -> Int64> = None<() -> Int64>

public class GatewayMemoryObservation {
    public let turnSequence: Int64
    public let sampled: Bool
    public let sessionHash: String
    public let channel: String
    public let agentId: String
    public var model: String
    public let startedAtMs: Int64

    private let stateLock = Mutex()
    private var baselineRssKb: Int64 = -1
    private var peakRssKb: Int64 = -1
    private var lastRssKb: Int64 = -1
    private var finished: Bool = false

    public init(
        turnSequence: Int64,
        sampled: Bool,
        sessionHash: String,
        channel: String,
        agentId: String,
        model: String,
        startedAtMs: Int64
    ) {
        this.turnSequence = turnSequence
        this.sampled = sampled
        this.sessionHash = sessionHash.trimAscii()
        this.channel = channel.trimAscii().toAsciiLower()
        this.agentId = agentId.trimAscii()
        this.model = model.trimAscii()
        this.startedAtMs = startedAtMs
    }

    public func recordRss(rssKb: Int64): (Int64, Int64, Int64) {
        synchronized(this.stateLock) {
            if (rssKb >= 0) {
                if (this.baselineRssKb < 0) {
                    this.baselineRssKb = rssKb
                }
                this.lastRssKb = rssKb
                if (this.peakRssKb < rssKb) {
                    this.peakRssKb = rssKb
                }
            }
            let delta = if (rssKb >= 0 && this.baselineRssKb >= 0) { rssKb - this.baselineRssKb } else { -1 }
            (this.baselineRssKb, delta, this.peakRssKb)
        }
    }

    public func memorySnapshot(): (Int64, Int64, Int64) {
        synchronized(this.stateLock) {
            (this.baselineRssKb, this.peakRssKb, this.lastRssKb)
        }
    }

    public func markFinished(): Bool {
        synchronized(this.stateLock) {
            if (this.finished) {
                return false
            }
            this.finished = true
            true
        }
    }
}

private func gatewayMemoryObservationNowMs(): Int64 {
    (MonoTime.now() - gatewayMemoryObservationMonotonicOrigin).toMilliseconds()
}

private func gatewayMemoryObservationStageKnown(stage: String): Bool {
    let normalized = stage.trimAscii()
    normalized == "turn_enter" ||
    normalized == "history_loaded" ||
    normalized == "model_input_built" ||
    normalized == "system_prompt_built" ||
    normalized == "model_returned" ||
    normalized == "final_correction_ready" ||
    normalized == "session_persisted" ||
    normalized == "turn_exit" ||
    normalized == "service_plugin_turn_released"
}

private func gatewayMemoryObservationStatus(raw: String): String {
    let normalized = raw.trimAscii().toAsciiLower()
    if (normalized == "entered" || normalized == "success" || normalized == "failed" || normalized == "cancelled") {
        return normalized
    }
    "failed"
}

private func gatewayMemoryObservationErrorKind(raw: String): String {
    let normalized = raw.trimAscii().toAsciiLower()
    if (
        normalized == "none" || normalized == "model_failed" || normalized == "session_failed" ||
        normalized == "writeback_failed" || normalized == "delivery_failed" || normalized == "cancelled" ||
        normalized == "unknown"
    ) {
        return normalized
    }
    "unknown"
}

private func gatewayMemoryObservationMeta(
    observation: GatewayMemoryObservation,
    stage: String,
    rssKb: Int64,
    rssDeltaKb: Int64,
    peakRssKb: Int64,
    activeTurns: Int64,
    completedTurns: Int64,
    status: String,
    errorKind: String,
    extra: JsonObject
): JsonObject {
    let meta = gatewayLogMeta()
    for (key in extra.getFields().keys()) {
        match (extra.get(key)) {
            case Some(value) => meta.value(key, value)
            case None => ()
        }
    }
    meta.string("stage", stage)
        .int("turnSequence", observation.turnSequence)
        .bool("sampled", observation.sampled)
        .int("rssKb", rssKb)
        .int("rssDeltaKb", rssDeltaKb)
        .int("peakRssKb", peakRssKb)
        .int("elapsedMs", gatewayMemoryObservationNowMs() - observation.startedAtMs)
        .int("activeTurns", activeTurns)
        .int("completedTurns", completedTurns)
        .string("sessionHash", observation.sessionHash)
        .string("channel", observation.channel)
        .string("agentId", observation.agentId)
        .string("model", observation.model)
        .string("status", gatewayMemoryObservationStatus(status))
        .string("errorKind", gatewayMemoryObservationErrorKind(errorKind))
        .object()
}

public func setGatewayProcessRssProviderForTest(provider: Option<() -> Int64>): Unit {
    synchronized(gatewayMemoryObservationStateLock) {
        gatewayProcessRssProviderForTest = provider
    }
}

public func resetGatewayMemoryObservationForTest(): Unit {
    synchronized(gatewayMemoryObservationStateLock) {
        gatewayMemoryObservationNextSequence = 0
        gatewayMemoryObservationActiveTurns = 0
        gatewayMemoryObservationCompletedTurns = 0
        gatewayProcessRssProviderForTest = None<() -> Int64>
    }
}

private func gatewayMemoryObservationCounters(): (Int64, Int64, Int64) {
    synchronized(gatewayMemoryObservationStateLock) {
        (
            gatewayMemoryObservationNextSequence,
            gatewayMemoryObservationActiveTurns,
            gatewayMemoryObservationCompletedTurns
        )
    }
}

public func gatewayMemoryObservationCountersForTest(): (Int64, Int64, Int64) {
    gatewayMemoryObservationCounters()
}

public func gatewayBeginMemoryObservation(
    sessionHash: String,
    channel!: String = "",
    agentId!: String = "",
    model!: String = ""
): GatewayMemoryObservation {
    let state = synchronized(gatewayMemoryObservationStateLock) {
        gatewayMemoryObservationNextSequence += 1
        gatewayMemoryObservationActiveTurns += 1
        (gatewayMemoryObservationNextSequence, gatewayMemoryObservationActiveTurns)
    }
    let sequence = state[0]
    GatewayMemoryObservation(
        sequence,
        sequence <= 3 || sequence % 5 == 0,
        sessionHash,
        channel,
        agentId,
        model,
        gatewayMemoryObservationNowMs()
    )
}

private func gatewayObserveMemoryStageInternal(
    observation: GatewayMemoryObservation,
    stage: String,
    meta: JsonObject,
    status: String,
    errorKind: String,
    force: Bool
): Bool {
    let normalizedStage = stage.trimAscii().toAsciiLower()
    if (!gatewayMemoryObservationStageKnown(normalizedStage)) {
        return false
    }
    if (!observation.sampled && !force) {
        return true
    }
    let rssKb = gatewayProcessResidentSetKb()
    let rss = observation.recordRss(rssKb)
    let counters = gatewayMemoryObservationCounters()
    let subsystem = if (normalizedStage == "service_plugin_turn_released") {
        "gateway/service-plugin"
    } else {
        "gateway/model"
    }
    gatewayLogEventDebugFileOnly(
        subsystem,
        "process.memory",
        "gateway model memory stage",
        meta: gatewayMemoryObservationMeta(
            observation,
            normalizedStage,
            rssKb,
            rss[1],
            rss[2],
            counters[1],
            counters[2],
            status,
            errorKind,
            meta
        )
    )
    true
}

public func gatewayObserveMemoryStage(
    observation: GatewayMemoryObservation,
    stage: String,
    meta!: JsonObject = JsonObject(),
    status!: String = "entered",
    errorKind!: String = "none"
): Bool {
    gatewayObserveMemoryStageInternal(observation, stage, meta, status, errorKind, false)
}

public func gatewayFinishMemoryObservation(
    observation: GatewayMemoryObservation,
    meta!: JsonObject = JsonObject(),
    status!: String = "success",
    errorKind!: String = "none"
): Bool {
    if (!observation.markFinished()) {
        return false
    }
    let normalizedStatus = gatewayMemoryObservationStatus(status)
    let forceFailureTerminal = !observation.sampled && normalizedStatus != "success"
    let _ = gatewayObserveMemoryStageInternal(
        observation,
        "turn_exit",
        meta,
        status,
        errorKind,
        forceFailureTerminal
    )
    let counters = synchronized(gatewayMemoryObservationStateLock) {
        if (gatewayMemoryObservationActiveTurns > 0) {
            gatewayMemoryObservationActiveTurns -= 1
        }
        gatewayMemoryObservationCompletedTurns += 1
        (gatewayMemoryObservationActiveTurns, gatewayMemoryObservationCompletedTurns)
    }
    if (observation.sampled || forceFailureTerminal) {
        let rss = observation.memorySnapshot()
        let summary = gatewayMemoryObservationMeta(
            observation,
            "turn_summary",
            rss[2],
            if (rss[2] >= 0 && rss[0] >= 0) { rss[2] - rss[0] } else { -1 },
            rss[1],
            counters[0],
            counters[1],
            status,
            errorKind,
            meta
        )
        summary.put("durationMs", JsonInt(gatewayMemoryObservationNowMs() - observation.startedAtMs))
        gatewayLogEventInfoFileOnly(
            "gateway/model",
            "process.memory",
            "gateway model memory summary",
            meta: summary
        )
    }
    true
}

public func gatewayLogServicePluginTurnReleased(
    turnSequence: Int64,
    sampled: Bool,
    baselineRssKb: Int64,
    sessionHash: String,
    meta!: JsonObject = JsonObject(),
    status!: String = "success",
    errorKind!: String = "none"
): Bool {
    if (!sampled || turnSequence <= 0) {
        return false
    }
    let rssKb = gatewayProcessResidentSetKb()
    let counters = gatewayMemoryObservationCounters()
    let row = gatewayLogMeta()
    for (key in meta.getFields().keys()) {
        match (meta.get(key)) {
            case Some(value) => row.value(key, value)
            case None => ()
        }
    }
    row.string("stage", "service_plugin_turn_released")
        .int("turnSequence", turnSequence)
        .bool("sampled", true)
        .int("rssKb", rssKb)
        .int("rssDeltaKb", if (rssKb >= 0 && baselineRssKb >= 0) { rssKb - baselineRssKb } else { -1 })
        .int("peakRssKb", -1)
        .int("elapsedMs", -1)
        .int("activeTurns", counters[1])
        .int("completedTurns", counters[2])
        .string("sessionHash", sessionHash.trimAscii())
        .string("channel", "gitcode")
        .string("agentId", "")
        .string("model", "")
        .string("status", gatewayMemoryObservationStatus(status))
        .string("errorKind", gatewayMemoryObservationErrorKind(errorKind))
    gatewayLogEventDebugFileOnly(
        "gateway/service-plugin",
        "process.memory",
        "service plugin model turn released",
        meta: row.object()
    )
    true
}

@When[os == "Windows"]
foreign {
    func GetCurrentProcessId(): UInt32
}

@When[os != "Windows"]
foreign {
    func getpid(): Int32
}

@When[os == "Windows"]
public func gatewayProcessCurrentPid(): Int64 {
    Int64(unsafe { GetCurrentProcessId() })
}

@When[os != "Windows"]
public func gatewayProcessCurrentPid(): Int64 {
    Int64(unsafe { getpid() })
}

public func gatewayProcessResidentSetKb(): Int64 {
    let testProvider = synchronized(gatewayMemoryObservationStateLock) {
        gatewayProcessRssProviderForTest
    }
    match (testProvider) {
        case Some(provider) =>
            try {
                return provider()
            } catch (_: Exception) {
                return -1
            }
        case None => ()
    }
    let pid = gatewayProcessCurrentPid()
    if (pid <= 0) {
        return -1
    }
    try {
        let (exitCode, stdout, _) = executeWithOutput("ps", ["-o", "rss=", "-p", "${pid}"])
        if (exitCode != 0) {
            return -1
        }
        let raw = String.fromUtf8(stdout).trimAscii()
        if (raw.isEmpty()) {
            return -1
        }
        let firstLine = raw.split("\n")[0].trimAscii()
        if (firstLine.isEmpty()) {
            return -1
        }
        Int64.parse(firstLine)
    } catch (_: Exception) {
        -1
    }
}

public func gatewayLogProcessMemory(scope: String, note!: String = ""): Unit {
    let pid = gatewayProcessCurrentPid()
    let rssKb = gatewayProcessResidentSetKb()
    gatewayLogEventInfo(
        "gateway/runtime",
        "process.memory",
        "gateway process memory snapshot",
        meta: gatewayLogMeta()
            .string("scope", scope)
            .int("pid", pid)
            .int("rssKb", rssKb)
            .rawString("note", note.trimAscii())
            .object()
    )
}
