package metis.process

import std.collection.{ArrayList, HashMap}
import std.env.{getVariable, getVariables}
import std.fs.{Path, canonicalize, exists}
import std.io.{InputStream, OutputStream, StringReader, StringWriter}
import std.process.{ProcessRedirect, SubProcess, launch}
import std.sync.{Condition, Mutex}
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public let MANAGED_STDIO_OWNER_HARD_LIMIT: Int64 = 256
private let MANAGED_STDIO_OWNER_QUEUE_LIMIT: Int64 = 4096
private let MANAGED_STDIO_BROKER_START_TIMEOUT_MS: Int64 = 3000
private let MANAGED_STDIO_BROKER_PING_TIMEOUT_MS: Int64 = 500
private let MANAGED_STDIO_REAP_GRACE_MS: Int64 = 300

private func managedStdioHasControl(value: String): Bool {
    for (rune in value.runes()) {
        if ((rune >= r'\u{0}' && rune < r' ') || rune == r'\u{7f}') { return true }
    }
    false
}

private func managedStdioProjectRoot(start: Path): Option<Path> {
    try {
        var current = canonicalize(start)
        var guard: Int64 = 0
        while (guard < 96) {
            if (exists(current.join("cjpm.toml"))) { return Some(current) }
            let parent = current.parent
            if (parent == current) { break }
            current = parent
            guard += 1
        }
    } catch (_: Exception) { () }
    None<Path>
}

public func managedStdioResolveBrokerScriptPath(explicitPath!: String = ""): String {
    let explicit = explicitPath.trimAscii()
    if (!explicit.isEmpty()) { return explicit }
    match (getVariable("METIS_STDIO_BROKER_SCRIPT")) {
        case Some(value) =>
            let configured = value.trimAscii()
            if (!configured.isEmpty()) { return configured }
        case None => ()
    }
    match (getVariable("METIS_CJPM_ROOT")) {
        case Some(value) =>
            let root = Path(value.trimAscii())
            let candidate = root.join("scripts").join("metis-stdio-broker.mjs")
            if (exists(candidate)) { return try { canonicalize(candidate).toString() } catch (_: Exception) { candidate.toString() } }
        case None => ()
    }
    match (managedStdioProjectRoot(Path("."))) {
        case Some(root) =>
            let candidate = root.join("scripts").join("metis-stdio-broker.mjs")
            if (exists(candidate)) { return try { canonicalize(candidate).toString() } catch (_: Exception) { candidate.toString() } }
        case None => ()
    }
    "scripts/metis-stdio-broker.mjs"
}

private func managedStdioResolveNodeCommand(): String {
    match (getVariable("METIS_STDIO_BROKER_NODE_COMMAND")) {
        case Some(value) =>
            let configured = value.trimAscii()
            if (!configured.isEmpty()) { return configured }
        case None => ()
    }
    "node"
}

public class ManagedStdioOwnerSpec {
    public let ownerId: String
    public let command: String
    public let args: Array<String>
    public let workingDirectory: Option<String>
    public let environment: Array<(String, String)>
    public let stdinMode: String
    public let outputMode: String
    public let deadlineMs: Int64
    public let maxLineBytes: Int64
    public let maxBufferedBytes: Int64
    public let maxTotalOutputBytes: Int64

    public init(
        ownerId: String,
        command: String,
        args!: Array<String> = [],
        workingDirectory!: Option<String> = None<String>,
        environment!: Array<(String, String)> = [],
        stdinMode!: String = "line",
        outputMode!: String = "line",
        deadlineMs!: Int64 = 0,
        maxLineBytes!: Int64 = 1048576,
        maxBufferedBytes!: Int64 = 4194304,
        maxTotalOutputBytes!: Int64 = 0
    ) {
        this.ownerId = ownerId
        this.command = command
        this.args = args
        this.workingDirectory = workingDirectory
        this.environment = environment
        this.stdinMode = stdinMode
        this.outputMode = outputMode
        this.deadlineMs = deadlineMs
        this.maxLineBytes = maxLineBytes
        this.maxBufferedBytes = maxBufferedBytes
        this.maxTotalOutputBytes = maxTotalOutputBytes
    }

    public func validate(): String {
        if (this.ownerId.isEmpty() || this.ownerId.size > 256 || managedStdioHasControl(this.ownerId)) { return "invalid_owner_spec" }
        if (this.command.isEmpty() || this.command.contains("\u{0}")) { return "invalid_owner_spec" }
        for (arg in this.args) {
            if (arg.contains("\u{0}")) { return "invalid_owner_spec" }
        }
        for ((key, value) in this.environment) {
            if (key.isEmpty() || managedStdioHasControl(key) || key.contains("=") || value.contains("\u{0}")) { return "invalid_owner_spec" }
        }
        match (this.workingDirectory) {
            case Some(value) => if (value.contains("\u{0}")) { return "invalid_owner_spec" }
            case None => ()
        }
        if (this.stdinMode != "line" && this.stdinMode != "closed") { return "invalid_owner_spec" }
        if (this.outputMode != "line" && this.outputMode != "stream") { return "invalid_owner_spec" }
        if (this.deadlineMs < 0 || this.maxLineBytes <= 0 || this.maxBufferedBytes <= 0 || this.maxTotalOutputBytes < 0) {
            return "invalid_owner_spec"
        }
        "ok"
    }

    public func toStartFrame(): JsonObject {
        let out = JsonObject()
        out.put("type", JsonString("owner.start"))
        out.put("ownerId", JsonString(this.ownerId))
        out.put("command", JsonString(this.command))
        let jsonArgs = JsonArray()
        for (arg in this.args) { jsonArgs.add(JsonString(arg)) }
        out.put("args", jsonArgs)
        match (this.workingDirectory) {
            case Some(value) => out.put("cwd", JsonString(value))
            case None => ()
        }
        let env = JsonObject()
        for ((key, value) in this.environment) { env.put(key, JsonString(value)) }
        out.put("env", env)
        out.put("stdinMode", JsonString(this.stdinMode))
        out.put("outputMode", JsonString(this.outputMode))
        out.put("deadlineMs", JsonInt(this.deadlineMs))
        out.put("maxLineBytes", JsonInt(this.maxLineBytes))
        out.put("maxBufferedBytes", JsonInt(this.maxBufferedBytes))
        out.put("maxTotalOutputBytes", JsonInt(this.maxTotalOutputBytes))
        out
    }
}

public class ManagedStdioEvent {
    public let eventType: String
    public let ownerId: String
    public let status: String
    public let text: String
    public let sequence: Int64
    public let finalChunk: Bool
    public let exitCode: Int64

    public init(
        eventType: String,
        ownerId!: String = "",
        status!: String = "",
        text!: String = "",
        sequence!: Int64 = 0,
        finalChunk!: Bool = false,
        exitCode!: Int64 = 0
    ) {
        this.eventType = eventType
        this.ownerId = ownerId
        this.status = status
        this.text = text
        this.sequence = sequence
        this.finalChunk = finalChunk
        this.exitCode = exitCode
    }
}

public class ManagedStdioOperationResult {
    public let ok: Bool
    public let status: String
    public let generation: Int64
    public let pid: Int64
    public let pgid: Int64

    public init(ok: Bool, status: String, generation!: Int64 = 0, pid!: Int64 = 0, pgid!: Int64 = 0) {
        this.ok = ok
        this.status = status
        this.generation = generation
        this.pid = pid
        this.pgid = pgid
    }
}

public class ManagedStdioBrokerSnapshot {
    public let running: Bool
    public let responsive: Bool
    public let status: String
    public let generation: Int64
    public let brokerPid: Int64
    public let ownerCount: Int64
    public let readerCount: Int64

    public init(running: Bool, responsive: Bool, status: String, generation: Int64, brokerPid: Int64, ownerCount: Int64, readerCount: Int64) {
        this.running = running
        this.responsive = responsive
        this.status = status
        this.generation = generation
        this.brokerPid = brokerPid
        this.ownerCount = ownerCount
        this.readerCount = readerCount
    }
}

public interface ManagedStdioPlatformRunner {
    func terminateTree(pid: Int64, pgid: Int64, force: Bool): Bool
    func treeAlive(pid: Int64, pgid: Int64): Bool
}

public func managedStdioTerminationArgv(platform: String, pid: Int64, pgid: Int64, force: Bool): (String, Array<String>) {
    if (platform == "windows") {
        if (force) {
            return ("taskkill", ["/PID", "${pid}", "/T", "/F"])
        }
        return ("taskkill", ["/PID", "${pid}", "/T"])
    }
    ("/bin/kill", [if (force) { "-KILL" } else { "-TERM" }, "--", "-${pgid}"])
}

@When[os == "Windows"]
private func managedStdioPlatformName(): String { "windows" }
@When[os != "Windows"]
private func managedStdioPlatformName(): String { "posix" }

@When[os == "Windows"]
foreign {
    func OpenProcess(desiredAccess: UInt32, inheritHandle: UInt32, processId: UInt32): CPointer<Unit>
    func WaitForSingleObject(handle: CPointer<Unit>, milliseconds: UInt32): UInt32
    func CloseHandle(handle: CPointer<Unit>): UInt32
}

@When[os == "Windows"]
private func managedStdioWindowsPidAlive(pid: Int64): Bool {
    if (pid <= 1 || pid > 4294967295) { return false }
    let handle = unsafe { OpenProcess(UInt32(0x1000), UInt32(0), UInt32(pid)) }
    if (handle.isNull()) { return false }
    let waitStatus = unsafe { WaitForSingleObject(handle, UInt32(0)) }
    let _ = unsafe { CloseHandle(handle) }
    waitStatus == UInt32(258)
}

@When[os != "Windows"]
private func managedStdioWindowsPidAlive(pid: Int64): Bool { false }

public class ManagedStdioDefaultPlatformRunner <: ManagedStdioPlatformRunner {
    private let platform: String
    public init(platform!: String = managedStdioPlatformName()) { this.platform = platform }

    public func terminateTree(pid: Int64, pgid: Int64, force: Bool): Bool {
        if (pid <= 1 || (this.platform != "windows" && (pgid <= 1 || pgid != pid))) { return false }
        let (command, args) = managedStdioTerminationArgv(this.platform, pid, pgid, force)
        try {
            let proc = launch(command, args, stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
            let _ = proc.wait(timeout: Some(Duration.second))
            true
        } catch (_: Exception) {
            false
        }
    }

    public func treeAlive(pid: Int64, pgid: Int64): Bool {
        if (pid <= 1 || (this.platform != "windows" && (pgid <= 1 || pgid != pid))) { return false }
        if (this.platform == "windows") { return managedStdioWindowsPidAlive(pid) }
        try {
            let proc = launch("/bin/kill", ["-0", "--", "-${pgid}"], stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
            proc.wait(timeout: Some(Duration.second)) == 0
        } catch (_: Exception) {
            false
        }
    }
}

private class ManagedStdioOwnerState {
    let ownerId: String
    let generation: Int64
    let condition: Condition
    let events = ArrayList<ManagedStdioEvent>()
    let eventBytes = ArrayList<Int64>()
    var status: String = "starting"
    var pid: Int64 = 0
    var pgid: Int64 = 0
    var settled: Bool = false
    var lastWriteRequestId: String = ""
    var lastWriteStatus: String = ""
    var startRequestId: String = ""
    var lastStopRequestId: String = ""
    var maxBufferedBytes: Int64 = 1
    var queuedBytes: Int64 = 0
    init(ownerId: String, generation: Int64, condition: Condition) {
        this.ownerId = ownerId
        this.generation = generation
        this.condition = condition
    }
}

public class ManagedStdioBrokerClient {
    private let lock = Mutex()
    private let writerLock = Mutex()
    private let condition: Condition
    private let nodeCommand: String
    private let brokerScriptPath: String
    private let ownerHardLimit: Int64
    private let ownerQueueLimit: Int64
    private let platformRunner: ManagedStdioPlatformRunner
    private let brokerTestMode: Bool
    private var process: Option<SubProcess> = None<SubProcess>
    private var writer: Option<StringWriter<OutputStream>> = None<StringWriter<OutputStream>>
    private var owners = HashMap<String, ManagedStdioOwnerState>()
    private var generation: Int64 = 0
    private var brokerPid: Int64 = 0
    private var helloReceived: Bool = false
    private var lastPongId: String = ""
    private var status: String = "stopped"
    private var readerCount: Int64 = 0
    private var requestSequence: Int64 = 0
    private var closing: Bool = false
    private var exitHandledGeneration: Int64 = 0

    public init(
        nodeCommand!: String = "node",
        brokerScriptPath!: String = "",
        ownerHardLimit!: Int64 = MANAGED_STDIO_OWNER_HARD_LIMIT,
        ownerQueueLimit!: Int64 = MANAGED_STDIO_OWNER_QUEUE_LIMIT,
        platformRunner!: ManagedStdioPlatformRunner = ManagedStdioDefaultPlatformRunner(),
        brokerTestMode!: Bool = false
    ) {
        this.nodeCommand = nodeCommand
        this.brokerScriptPath = managedStdioResolveBrokerScriptPath(explicitPath: brokerScriptPath)
        this.ownerHardLimit = min(MANAGED_STDIO_OWNER_HARD_LIMIT, max(1, ownerHardLimit))
        this.ownerQueueLimit = max(1, ownerQueueLimit)
        this.platformRunner = platformRunner
        this.brokerTestMode = brokerTestMode
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    private func nowMs(): Int64 { DateTime.now().toUnixTimeStamp().toMilliseconds() }

    private func activeOwnerCountLocked(): Int64 {
        var count: Int64 = 0
        for ((_, state) in this.owners) {
            if (!state.settled) { count += 1 }
        }
        count
    }

    public func ensureBrokerRunning(timeoutMs!: Int64 = MANAGED_STDIO_BROKER_START_TIMEOUT_MS): ManagedStdioOperationResult {
        let existing = synchronized(this.lock) {
            match (this.process) {
                case Some(proc) => proc.isAlive() && this.helloReceived && !this.closing
                case None => false
            }
        }
        if (existing) {
            let snapshot = this.snapshot()
            return ManagedStdioOperationResult(true, "ready", generation: snapshot.generation, pid: snapshot.brokerPid)
        }
        synchronized(this.writerLock) {
            synchronized(this.lock) {
                if (this.closing) { return ManagedStdioOperationResult(false, "broker_unavailable", generation: this.generation) }
                match (this.process) {
                    case Some(proc) =>
                        if (proc.isAlive()) {
                            return this.waitForHelloLocked(timeoutMs)
                        }
                    case None => ()
                }
                this.generation += 1
                this.helloReceived = false
                this.brokerPid = 0
                this.status = "starting"
                let env = HashMap<String, String>()
                for ((key, value) in getVariables()) { env[key] = value }
                env["METIS_STDIO_BROKER_GENERATION"] = "${this.generation}"
                if (this.brokerTestMode) { env["METIS_STDIO_BROKER_TEST_MODE"] = "1" }
                try {
                    let proc = launch(
                        this.nodeCommand,
                        [this.brokerScriptPath],
                        environment: env,
                        stdIn: ProcessRedirect.Pipe,
                        stdOut: ProcessRedirect.Pipe,
                        stdErr: ProcessRedirect.Inherit
                    )
                    this.process = Some(proc)
                    this.writer = Some(StringWriter(proc.stdInPipe))
                    this.readerCount = 1
                    let readerGeneration = this.generation
                    spawn { this.readBrokerOutput(proc, readerGeneration) }
                } catch (_: Exception) {
                    this.process = None<SubProcess>
                    this.writer = None<StringWriter<OutputStream>>
                    this.status = "broker_unavailable"
                    this.readerCount = 0
                    return ManagedStdioOperationResult(false, "broker_unavailable", generation: this.generation)
                }
                this.waitForHelloLocked(timeoutMs)
            }
        }
    }

    private func waitForHelloLocked(timeoutMs: Int64): ManagedStdioOperationResult {
        let deadline = this.nowMs() + max(1, timeoutMs)
        while (!this.helloReceived && this.status == "starting") {
            let remaining = deadline - this.nowMs()
            if (remaining <= 0) {
                this.status = "broker_unresponsive"
                match (this.process) {
                    case Some(value) =>
                        try { value.terminate(force: true) } catch (_: Exception) { () }
                        try { let _ = value.wait(timeout: Some(Duration.second)) } catch (_: Exception) { () }
                    case None => ()
                }
                return ManagedStdioOperationResult(false, "broker_unresponsive", generation: this.generation)
            }
            let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
        }
        if (this.helloReceived) {
            ManagedStdioOperationResult(true, "ready", generation: this.generation, pid: this.brokerPid)
        } else {
            ManagedStdioOperationResult(false, this.status, generation: this.generation)
        }
    }

    public func startOwner(spec: ManagedStdioOwnerSpec, timeoutMs!: Int64 = MANAGED_STDIO_BROKER_START_TIMEOUT_MS): ManagedStdioOperationResult {
        let validation = spec.validate()
        if (validation != "ok") { return ManagedStdioOperationResult(false, validation) }
        let ready = this.ensureBrokerRunning(timeoutMs: timeoutMs)
        if (!ready.ok) { return ready }
        let owner: Option<ManagedStdioOwnerState> = synchronized(this.lock) {
            match (this.owners.get(spec.ownerId)) {
                case Some(previous) =>
                    if (previous.settled && previous.events.isEmpty()) { this.owners.remove(spec.ownerId) }
                case None => ()
            }
            if (this.owners.contains(spec.ownerId) || this.activeOwnerCountLocked() >= this.ownerHardLimit) {
                None<ManagedStdioOwnerState>
            } else {
                let value = ManagedStdioOwnerState(spec.ownerId, this.generation, this.lock.condition())
                value.maxBufferedBytes = spec.maxBufferedBytes
                this.requestSequence += 1
                value.startRequestId = "start-${this.generation}-${this.requestSequence}"
                this.owners[spec.ownerId] = value
                Some(value)
            }
        }
        match (owner) {
            case None =>
                let duplicate = synchronized(this.lock) { this.owners.contains(spec.ownerId) }
                return ManagedStdioOperationResult(false, if (duplicate) { "duplicate_owner" } else { "broker_capacity_exceeded" }, generation: ready.generation)
            case Some(state) =>
                let startFrame = spec.toStartFrame()
                startFrame.put("requestId", JsonString(state.startRequestId))
                if (!this.writeFrameForGeneration(startFrame, state.generation)) {
                    synchronized(this.lock) { this.owners.remove(spec.ownerId) }
                    return ManagedStdioOperationResult(false, "broker_exited", generation: ready.generation)
                }
                let deadline = this.nowMs() + max(1, timeoutMs)
                let outcome = synchronized(this.lock) {
                    var result = ManagedStdioOperationResult(false, "start_timeout", generation: state.generation)
                    var done = false
                    while (!done && state.status == "starting") {
                        let remaining = deadline - this.nowMs()
                        if (remaining <= 0) {
                            state.status = "start_timeout"
                            result = ManagedStdioOperationResult(false, state.status, generation: state.generation)
                            done = true
                        } else {
                            let _ = state.condition.wait(timeout: Duration.millisecond * remaining)
                        }
                    }
                    if (!done) {
                        result = ManagedStdioOperationResult(state.status == "running", state.status, generation: state.generation, pid: state.pid, pgid: state.pgid)
                    }
                    result
                }
                if (!outcome.ok && outcome.status == "start_timeout") {
                    let stop = JsonObject()
                    stop.put("type", JsonString("owner.stop"))
                    stop.put("ownerId", JsonString(spec.ownerId))
                    stop.put("reason", JsonString("start_timeout"))
                    let stopRequestId = synchronized(this.lock) {
                        this.requestSequence += 1
                        "stop-${state.generation}-${this.requestSequence}"
                    }
                    stop.put("requestId", JsonString(stopRequestId))
                    let _ = this.writeFrameForGeneration(stop, state.generation)
                } else if (!outcome.ok) {
                    synchronized(this.lock) { this.owners.remove(spec.ownerId) }
                }
                outcome
        }
    }

    public func writeOwnerLine(ownerId: String, line: String): ManagedStdioOperationResult {
        if (line.contains("\u{0}") || line.contains("\r") || line.contains("\n")) {
            return ManagedStdioOperationResult(false, "invalid_owner_write")
        }
        let state = synchronized(this.lock) { this.owners.get(ownerId) }
        match (state) {
            case None => ManagedStdioOperationResult(false, "owner_not_found", generation: this.generation)
            case Some(value) =>
                let requestId = synchronized(this.lock) {
                    this.requestSequence += 1
                    "write-${value.generation}-${this.requestSequence}"
                }
                let frame = JsonObject()
                frame.put("type", JsonString("owner.write"))
                frame.put("ownerId", JsonString(ownerId))
                frame.put("line", JsonString(line))
                frame.put("requestId", JsonString(requestId))
                if (!this.writeFrameForGeneration(frame, value.generation)) {
                    return ManagedStdioOperationResult(false, "broker_exited", generation: value.generation, pid: value.pid, pgid: value.pgid)
                }
                let deadline = this.nowMs() + 1000
                synchronized(this.lock) {
                    while (value.lastWriteRequestId != requestId && !value.settled) {
                        let remaining = deadline - this.nowMs()
                        if (remaining <= 0) {
                            return ManagedStdioOperationResult(false, "broker_unresponsive", generation: value.generation, pid: value.pid, pgid: value.pgid)
                        }
                        let _ = value.condition.wait(timeout: Duration.millisecond * remaining)
                    }
                    let status = if (value.lastWriteRequestId == requestId) { value.lastWriteStatus } else { value.status }
                    ManagedStdioOperationResult(status == "written", status, generation: value.generation, pid: value.pid, pgid: value.pgid)
                }
        }
    }

    public func readOwnerLine(ownerId: String, timeoutMs!: Int64 = 0): Option<ManagedStdioEvent> {
        let deadline = this.nowMs() + max(0, timeoutMs)
        synchronized(this.lock) {
            var result = None<ManagedStdioEvent>
            var done = false
            while (!done) {
                match (this.owners.get(ownerId)) {
                    case None => done = true
                    case Some(state) =>
                        if (!state.events.isEmpty()) {
                            result = Some(state.events.remove(at: 0))
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                            if (state.events.isEmpty() && state.settled) { this.owners.remove(ownerId) }
                            done = true
                        } else if (state.settled || timeoutMs <= 0) {
                            done = true
                        } else {
                            let remaining = deadline - this.nowMs()
                            if (remaining <= 0) {
                                done = true
                            } else {
                                let _ = state.condition.wait(timeout: Duration.millisecond * remaining)
                            }
                        }
                }
            }
            result
        }
    }

    public func stopOwner(ownerId: String, timeoutMs!: Int64 = 1000): ManagedStdioOperationResult {
        let state = synchronized(this.lock) { this.owners.get(ownerId) }
        match (state) {
            case None => return ManagedStdioOperationResult(true, "already_stopped", generation: this.generation)
            case Some(_) => ()
        }
        let frame = JsonObject()
        frame.put("type", JsonString("owner.stop"))
        frame.put("ownerId", JsonString(ownerId))
        frame.put("reason", JsonString("stopped"))
        let stateValue = state.getOrThrow()
        let stopRequestId = synchronized(this.lock) {
            this.requestSequence += 1
            "stop-${stateValue.generation}-${this.requestSequence}"
        }
        frame.put("requestId", JsonString(stopRequestId))
        if (!this.writeFrameForGeneration(frame, stateValue.generation)) { this.handleBrokerExit(stateValue.generation, "broker_exited") }
        let deadline = this.nowMs() + max(1, timeoutMs)
        synchronized(this.lock) {
            var result = ManagedStdioOperationResult(false, "stop_timeout", generation: this.generation)
            var done = false
            while (!done) {
                match (this.owners.get(ownerId)) {
                    case None =>
                        result = ManagedStdioOperationResult(true, "stopped", generation: this.generation)
                        done = true
                    case Some(value) =>
                        if (value.settled) {
                            let acked = value.lastStopRequestId == stopRequestId
                            this.owners.remove(ownerId)
                            result = ManagedStdioOperationResult(acked, if (acked) { "stopped" } else { "protocol_error" }, generation: value.generation)
                            done = true
                            continue
                        }
                        let remaining = deadline - this.nowMs()
                        if (remaining <= 0) {
                            result = ManagedStdioOperationResult(false, "stop_timeout", generation: value.generation, pid: value.pid, pgid: value.pgid)
                            done = true
                        } else {
                            let _ = value.condition.wait(timeout: Duration.millisecond * remaining)
                        }
                }
            }
            result
        }
    }

    public func probeBroker(timeoutMs!: Int64 = MANAGED_STDIO_BROKER_PING_TIMEOUT_MS): ManagedStdioOperationResult {
        let ready = this.ensureBrokerRunning(timeoutMs: timeoutMs)
        if (!ready.ok) { return ready }
        let requestId = synchronized(this.lock) {
            this.requestSequence += 1
            "ping-${this.generation}-${this.requestSequence}"
        }
        let frame = JsonObject()
        frame.put("type", JsonString("broker.ping"))
        frame.put("requestId", JsonString(requestId))
        if (!this.writeFrame(frame)) { return ManagedStdioOperationResult(false, "broker_exited", generation: ready.generation) }
        let deadline = this.nowMs() + max(1, timeoutMs)
        let result = synchronized(this.lock) {
            var outcome = ManagedStdioOperationResult(true, "ready", generation: this.generation, pid: this.brokerPid)
            var done = false
            while (!done && this.lastPongId != requestId) {
                let remaining = deadline - this.nowMs()
                if (remaining <= 0) {
                    this.status = "broker_unresponsive"
                    outcome = ManagedStdioOperationResult(false, "broker_unresponsive", generation: this.generation, pid: this.brokerPid)
                    done = true
                } else {
                    let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
                }
            }
            outcome
        }
        if (!result.ok && result.status == "broker_unresponsive") {
            let proc = synchronized(this.lock) { this.process }
            match (proc) {
                case Some(value) => try { value.terminate(force: true) } catch (_: Exception) { () }
                case None => ()
            }
            this.handleBrokerExit(result.generation, "broker_unresponsive")
        }
        result
    }

    private func writeFrame(frame: JsonObject): Bool {
        this.writeFrameForGeneration(frame, synchronized(this.lock) { this.generation })
    }

    private func writeFrameForGeneration(frame: JsonObject, expectedGeneration: Int64): Bool {
        synchronized(this.writerLock) {
            try {
                let selected = synchronized(this.lock) {
                    if (this.generation == expectedGeneration) { this.writer } else { None<StringWriter<OutputStream>> }
                }
                match (selected) {
                    case Some(value) =>
                        value.writeln(frame.toJsonString())
                        value.flush()
                        true
                    case None => false
                }
            } catch (_: Exception) {
                false
            }
        }
    }

    private func readBrokerOutput(proc: SubProcess, readerGeneration: Int64): Unit {
        let reader = StringReader<InputStream>(proc.stdOutPipe)
        var exitReason = "broker_exited"
        try {
            while (true) {
                match (reader.readln()) {
                    case Some(line) => this.handleBrokerFrame(line, readerGeneration)
                    case None => break
                }
            }
        } catch (_: Exception) {
            exitReason = "invalid_response_encoding"
        }
        this.handleBrokerExit(readerGeneration, exitReason)
        synchronized(this.lock) {
            if (this.generation == readerGeneration && this.readerCount > 0) {
                this.readerCount = 0
                this.condition.notifyAll()
            }
        }
    }

    private func handleBrokerFrame(raw: String, readerGeneration: Int64): Unit {
        let obj = try { JsonValue.fromStr(raw).asObject() } catch (_: Exception) {
            this.handleBrokerExit(readerGeneration, "malformed_json")
            return
        }
        let frameGeneration = managedStdioJsonInt(obj, "generation", -1)
        if (frameGeneration != readerGeneration) { return }
        let frameType = managedStdioJsonString(obj, "type")
        if (frameType == "broker.hello") {
            synchronized(this.lock) {
                if (this.generation != readerGeneration) { return }
                this.brokerPid = managedStdioJsonInt(obj, "pid", 0)
                this.helloReceived = true
                this.status = "ready"
                this.condition.notifyAll()
            }
            return
        }
        if (frameType == "broker.pong") {
            synchronized(this.lock) {
                if (this.generation == readerGeneration) {
                    this.lastPongId = managedStdioJsonString(obj, "requestId")
                    this.status = "ready"
                    this.condition.notifyAll()
                }
            }
            return
        }
        let ownerId = managedStdioJsonString(obj, "ownerId")
        var stopForCapacity = false
        synchronized(this.lock) {
            match (this.owners.get(ownerId)) {
                case None => ()
                case Some(state) =>
                    if (state.generation != readerGeneration) { return }
                    if (frameType == "owner.started") {
                        if (managedStdioJsonString(obj, "requestId") != state.startRequestId) { return }
                        state.pid = managedStdioJsonInt(obj, "pid", 0)
                        state.pgid = managedStdioJsonInt(obj, "pgid", 0)
                        state.status = "running"
                        state.condition.notifyAll()
                    } else if (frameType == "owner.stopping") {
                        state.lastStopRequestId = managedStdioJsonString(obj, "requestId")
                        state.condition.notifyAll()
                    } else if (frameType == "owner.written" || frameType == "owner.write-rejected") {
                        state.lastWriteRequestId = managedStdioJsonString(obj, "requestId")
                        state.lastWriteStatus = if (frameType == "owner.written") { "written" } else { managedStdioJsonString(obj, "status") }
                        state.condition.notifyAll()
                    } else if (frameType == "owner.stdout" || frameType == "owner.stderr") {
                        let text = managedStdioJsonString(obj, "text")
                        let textBytes = text.toArray().size
                        if (state.events.size >= this.ownerQueueLimit || state.queuedBytes + textBytes > state.maxBufferedBytes) {
                            state.status = "buffer_capacity_exceeded"
                            stopForCapacity = true
                        } else {
                            state.events.add(ManagedStdioEvent(
                                frameType,
                                ownerId: ownerId,
                                text: text,
                                sequence: managedStdioJsonInt(obj, "seq", 0),
                                finalChunk: managedStdioJsonBool(obj, "final")
                            ))
                            state.eventBytes.add(textBytes)
                            state.queuedBytes += textBytes
                        }
                        state.condition.notifyAll()
                    } else if (frameType == "owner.error" || frameType == "owner.timeout") {
                        state.status = managedStdioJsonString(obj, "status")
                        while (state.events.size >= this.ownerQueueLimit) {
                            state.events.remove(at: 0)
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                        }
                        state.events.add(ManagedStdioEvent(frameType, ownerId: ownerId, status: state.status))
                        state.eventBytes.add(0)
                        state.settled = true
                        state.condition.notifyAll()
                    } else if (frameType == "owner.exit") {
                        state.status = "exited"
                        while (state.events.size >= this.ownerQueueLimit) {
                            state.events.remove(at: 0)
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                        }
                        state.events.add(ManagedStdioEvent(frameType, ownerId: ownerId, exitCode: managedStdioJsonInt(obj, "exitCode", -1)))
                        state.eventBytes.add(0)
                        state.settled = true
                        state.condition.notifyAll()
                    }
            }
        }
        if (stopForCapacity) {
            let stop = JsonObject()
            stop.put("type", JsonString("owner.stop"))
            stop.put("ownerId", JsonString(ownerId))
            stop.put("reason", JsonString("buffer_capacity_exceeded"))
            let _ = this.writeFrameForGeneration(stop, readerGeneration)
        }
    }

    private func handleBrokerExit(readerGeneration: Int64, reason: String): Unit {
        let reap = ArrayList<(Int64, Int64)>()
        var brokerProcess = None<SubProcess>
        synchronized(this.lock) {
            if (readerGeneration != this.generation) { return }
            if (this.exitHandledGeneration == readerGeneration) { return }
            this.exitHandledGeneration = readerGeneration
            brokerProcess = this.process
            this.process = None<SubProcess>
            this.writer = None<StringWriter<OutputStream>>
            this.helloReceived = false
            this.brokerPid = 0
            this.status = reason
            for ((_, state) in this.owners) {
                if (state.generation == readerGeneration && !state.settled) {
                    if (state.pid > 0) { reap.add((state.pid, state.pgid)) }
                    state.status = reason
                    state.events.add(ManagedStdioEvent("owner.error", ownerId: state.ownerId, status: reason))
                    state.eventBytes.add(0)
                    state.settled = true
                    state.condition.notifyAll()
                }
            }
            this.condition.notifyAll()
        }
        match (brokerProcess) {
            case Some(value) =>
                if (value.isAlive()) { try { value.terminate(force: true) } catch (_: Exception) { () } }
                try { let _ = value.wait(timeout: Some(Duration.second)) } catch (_: Exception) { () }
            case None => ()
        }
        this.emergencyReapGeneration(reap.toArray())
    }

    private func emergencyReapGeneration(ids: Array<(Int64, Int64)>): Unit {
        for ((pid, pgid) in ids) { let _ = this.platformRunner.terminateTree(pid, pgid, false) }
        sleep(Duration.millisecond * MANAGED_STDIO_REAP_GRACE_MS)
        for ((pid, pgid) in ids) {
            if (this.platformRunner.treeAlive(pid, pgid)) { let _ = this.platformRunner.terminateTree(pid, pgid, true) }
        }
        let deadline = this.nowMs() + 1000
        while (this.nowMs() < deadline) {
            var anyAlive = false
            for ((pid, pgid) in ids) {
                if (this.platformRunner.treeAlive(pid, pgid)) { anyAlive = true }
            }
            if (!anyAlive) { return }
            sleep(Duration.millisecond * 20)
        }
    }

    public func close(timeoutMs!: Int64 = 2000): ManagedStdioOperationResult {
        let snapshot = this.snapshot()
        if (!snapshot.running && snapshot.readerCount == 0) {
            return ManagedStdioOperationResult(true, "already_stopped", generation: snapshot.generation)
        }
        synchronized(this.lock) { this.closing = true }
        let frame = JsonObject()
        frame.put("type", JsonString("broker.close"))
        let _ = this.writeFrame(frame)
        let proc = synchronized(this.lock) { this.process }
        match (proc) {
            case Some(value) =>
                try {
                    let _ = value.wait(timeout: Some(Duration.millisecond * max(1, timeoutMs)))
                } catch (_: Exception) {
                    try { value.terminate(force: true) } catch (_: Exception) { () }
                    try { let _ = value.wait(timeout: Some(Duration.second)) } catch (_: Exception) { () }
                }
            case None => ()
        }
        let readerDeadline = this.nowMs() + max(1, timeoutMs)
        synchronized(this.lock) {
            while (this.readerCount > 0 && this.nowMs() < readerDeadline) {
                let _ = this.condition.wait(timeout: Duration.millisecond * min(50, readerDeadline - this.nowMs()))
            }
        }
        let readerStopped = synchronized(this.lock) { this.readerCount == 0 }
        if (!readerStopped) { this.handleBrokerExit(snapshot.generation, "broker_exited") }
        synchronized(this.lock) {
            this.process = None<SubProcess>
            this.writer = None<StringWriter<OutputStream>>
            this.helloReceived = false
            this.brokerPid = 0
            this.readerCount = 0
            this.status = "stopped"
            this.owners.clear()
            this.closing = false
        }
        ManagedStdioOperationResult(readerStopped, if (readerStopped) { "stopped" } else { "broker_shutdown_timeout" }, generation: snapshot.generation)
    }

    public func debugKillBrokerForTest(): Unit {
        match (synchronized(this.lock) { this.process }) {
            case Some(value) => try { value.terminate(force: true) } catch (_: Exception) { () }
            case None => ()
        }
    }

    public func debugHangBrokerForTest(): Bool {
        let frame = JsonObject()
        frame.put("type", JsonString("broker.test-hang"))
        this.writeFrame(frame)
    }

    public func snapshot(): ManagedStdioBrokerSnapshot {
        synchronized(this.lock) {
            ManagedStdioBrokerSnapshot(
                this.process.map({ value => value.isAlive() }).getOrDefault({ => false }),
                this.status == "ready",
                this.status,
                this.generation,
                this.brokerPid,
                this.activeOwnerCountLocked(),
                this.readerCount
            )
        }
    }

    public func debugSnapshotForTest(): ManagedStdioBrokerSnapshot { this.snapshot() }
}

private let managedStdioSingletonLock = Mutex()
private var managedStdioSingleton: Option<ManagedStdioBrokerClient> = None<ManagedStdioBrokerClient>

public func managedStdioBroker(): ManagedStdioBrokerClient {
    synchronized(managedStdioSingletonLock) {
        match (managedStdioSingleton) {
            case Some(value) => value
            case None =>
                let value = ManagedStdioBrokerClient(nodeCommand: managedStdioResolveNodeCommand())
                managedStdioSingleton = Some(value)
                value
        }
    }
}

public func shutdownManagedStdioBroker(timeoutMs!: Int64 = 2000): ManagedStdioOperationResult {
    let client = synchronized(managedStdioSingletonLock) { managedStdioSingleton }
    match (client) {
        case Some(value) => value.close(timeoutMs: timeoutMs)
        case None => ManagedStdioOperationResult(true, "already_stopped")
    }
}

private func managedStdioJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func managedStdioJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(value) => try { value.asInt().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func managedStdioJsonBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(value) => try { value.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}
