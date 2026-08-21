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
private let MANAGED_STDIO_DISPATCH_QUEUE_LIMIT: Int64 = 16384
private let MANAGED_STDIO_DISPATCH_BYTES_LIMIT: Int64 = 16777216

private func managedStdioHasControl(value: String): Bool {
    for (rune in value.runes()) {
        if ((rune >= r'\u{0}' && rune < r' ') || rune == r'\u{7f}') { return true }
    }
    false
}

private func managedStdioCompactJson(value: JsonObject): String {
    let out = StringBuilder()
    var inString = false
    var escaped = false
    for (rune in value.toJsonString().runes()) {
        if (inString) {
            out.append(rune)
            if (escaped) {
                escaped = false
            } else if (rune == r'\\') {
                escaped = true
            } else if (rune == r'"') {
                inString = false
            }
        } else if (rune == r'"') {
            inString = true
            out.append(rune)
        } else if (rune != r' ' && rune != r'\n' && rune != r'\r' && rune != r'\t') {
            out.append(rune)
        }
    }
    out.toString()
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

public func managedStdioResolveBrokerScriptPath(
    explicitPath!: String = "",
    startDirectory!: Path = Path(".")
): String {
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
            let configuredRoot = value.trimAscii()
            if (!configuredRoot.isEmpty()) {
                let root = Path(configuredRoot)
                let candidate = root.join("scripts").join("metis-stdio-broker.mjs")
                if (exists(candidate)) { return try { canonicalize(candidate).toString() } catch (_: Exception) { candidate.toString() } }
            }
        case None => ()
    }
    match (managedStdioProjectRoot(startDirectory)) {
        case Some(root) =>
            let candidate = root.join("scripts").join("metis-stdio-broker.mjs")
            if (exists(candidate)) { return try { canonicalize(candidate).toString() } catch (_: Exception) { candidate.toString() } }
        case None => ()
    }
    ""
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

// Subscribers must return promptly and may only enqueue the event into bounded
// in-memory state. The broker always invokes this callback without broker locks.
public interface ManagedStdioOwnerSubscriber {
    func onManagedStdioEvent(event: ManagedStdioEvent): Unit
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
    public let dispatcherCount: Int64

    public init(running: Bool, responsive: Bool, status: String, generation: Int64, brokerPid: Int64, ownerCount: Int64, readerCount: Int64, dispatcherCount!: Int64 = 0) {
        this.running = running
        this.responsive = responsive
        this.status = status
        this.generation = generation
        this.brokerPid = brokerPid
        this.ownerCount = ownerCount
        this.readerCount = readerCount
        this.dispatcherCount = dispatcherCount
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

public func managedStdioOwnerIdentitySafeForReap(platform: String, pid: Int64, pgid: Int64): Bool {
    if (pid <= 1) { return false }
    if (platform == "windows") { return true }
    pgid > 1 && pgid == pid
}

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
    var subscriber: Option<ManagedStdioOwnerSubscriber> = None<ManagedStdioOwnerSubscriber>
    var readModeClaimed: Bool = false
    var dispatchPending: Int64 = 0
    var terminalQueued: Bool = false
    var subscriberFailed: Bool = false
    init(ownerId: String, generation: Int64, condition: Condition) {
        this.ownerId = ownerId
        this.generation = generation
        this.condition = condition
    }
}

private class ManagedStdioDispatchItem {
    let ownerId: String
    let generation: Int64
    let event: ManagedStdioEvent
    let eventBytes: Int64
    let subscriber: ManagedStdioOwnerSubscriber

    init(ownerId: String, generation: Int64, event: ManagedStdioEvent, eventBytes: Int64, subscriber: ManagedStdioOwnerSubscriber) {
        this.ownerId = ownerId
        this.generation = generation
        this.event = event
        this.eventBytes = eventBytes
        this.subscriber = subscriber
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
    private let platformName: String
    private let brokerTestMode: Bool
    private var process: Option<SubProcess> = None<SubProcess>
    private var writer: Option<StringWriter<OutputStream>> = None<StringWriter<OutputStream>>
    private var readerFuture: Option<Future<Unit>> = None<Future<Unit>>
    private var dispatchFuture: Option<Future<Unit>> = None<Future<Unit>>
    private let dispatchItems = ArrayList<ManagedStdioDispatchItem>()
    private var dispatchBytes: Int64 = 0
    private var dispatcherCount: Int64 = 0
    private var dispatchClosing: Bool = false
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
        platformName!: String = managedStdioPlatformName(),
        brokerTestMode!: Bool = false
    ) {
        this.nodeCommand = nodeCommand
        this.brokerScriptPath = managedStdioResolveBrokerScriptPath(explicitPath: brokerScriptPath)
        this.ownerHardLimit = min(MANAGED_STDIO_OWNER_HARD_LIMIT, max(1, ownerHardLimit))
        this.ownerQueueLimit = max(1, ownerQueueLimit)
        this.platformRunner = platformRunner
        this.platformName = platformName
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
            var staleProcess = None<SubProcess>
            var staleReader = None<Future<Unit>>
            var staleGeneration: Int64 = 0
            var needsStaleJoin = false
            synchronized(this.lock) {
                staleGeneration = this.generation
                match (this.process) {
                    case Some(proc) =>
                        if (!proc.isAlive()) {
                            staleProcess = Some(proc)
                            staleReader = this.readerFuture
                            needsStaleJoin = true
                        }
                    case None =>
                        if (this.readerFuture.isSome()) {
                            staleReader = this.readerFuture
                            needsStaleJoin = true
                        }
                }
            }
            if (needsStaleJoin) {
                match (staleProcess) {
                    case Some(proc) => try { let _ = proc.wait(timeout: Some(Duration.second)) } catch (_: Exception) { () }
                    case None => ()
                }
                let readerJoined = match (staleReader) {
                    case Some(future) => try { future.get(Duration.second); true } catch (_: Exception) { false }
                    case None => true
                }
                if (!readerJoined) {
                    return ManagedStdioOperationResult(false, "broker_unavailable", generation: staleGeneration)
                }
                synchronized(this.lock) {
                    if (this.generation == staleGeneration) {
                        this.process = None<SubProcess>
                        this.writer = None<StringWriter<OutputStream>>
                        this.readerFuture = None<Future<Unit>>
                        this.readerCount = 0
                    }
                }
            }
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
                if (this.brokerScriptPath.isEmpty() || !exists(Path(this.brokerScriptPath))) {
                    this.status = "broker_unavailable"
                    return ManagedStdioOperationResult(false, "broker_unavailable", generation: this.generation)
                }
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
                    this.readerFuture = Some(spawn { this.readBrokerOutput(proc, readerGeneration) })
                } catch (_: Exception) {
                    this.process = None<SubProcess>
                    this.writer = None<StringWriter<OutputStream>>
                    this.readerFuture = None<Future<Unit>>
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
                    if (previous.settled && previous.events.isEmpty() && previous.dispatchPending == 0) { this.owners.remove(spec.ownerId) }
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
                    synchronized(this.lock) {
                        match (this.owners.get(spec.ownerId)) {
                            case Some(current) => if (current.generation == state.generation) { this.owners.remove(spec.ownerId) }
                            case None => ()
                        }
                    }
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
                    let settleDeadline = this.nowMs() + 500
                    let settled = synchronized(this.lock) {
                        while (!state.settled && this.nowMs() < settleDeadline) {
                            let _ = state.condition.wait(timeout: Duration.millisecond * min(50, settleDeadline - this.nowMs()))
                        }
                        state.settled
                    }
                    if (!settled) {
                        let proc = synchronized(this.lock) {
                            if (this.generation == state.generation) { this.process } else { None<SubProcess> }
                        }
                        match (proc) {
                            case Some(value) => try { value.terminate(force: true) } catch (_: Exception) { () }
                            case None => ()
                        }
                        this.handleBrokerExit(state.generation, "broker_unresponsive")
                    }
                    synchronized(this.lock) { this.owners.remove(spec.ownerId) }
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

    private func isTerminalEvent(event: ManagedStdioEvent): Bool {
        event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout"
    }

    // Caller holds lock. The item continues to count against the owner budget
    // until the callback returns or the item is discarded.
    private func enqueueDispatchLocked(state: ManagedStdioOwnerState, event: ManagedStdioEvent, eventBytes: Int64): Bool {
        match (state.subscriber) {
            case None => false
            case Some(subscriber) =>
                if (this.dispatchItems.size >= MANAGED_STDIO_DISPATCH_QUEUE_LIMIT || this.dispatchBytes + eventBytes > MANAGED_STDIO_DISPATCH_BYTES_LIMIT) {
                    state.status = "dispatch_capacity_exceeded"
                    state.subscriber = None<ManagedStdioOwnerSubscriber>
                    state.subscriberFailed = true
                    state.condition.notifyAll()
                    return false
                }
                if (this.isTerminalEvent(event)) {
                    if (state.terminalQueued) { return true }
                    state.terminalQueued = true
                }
                this.dispatchItems.add(ManagedStdioDispatchItem(state.ownerId, state.generation, event, eventBytes, subscriber))
                this.dispatchBytes += eventBytes
                state.dispatchPending += 1
                this.condition.notifyAll()
                true
        }
    }

    public func subscribeOwner(
        ownerId: String,
        expectedGeneration: Int64,
        subscriber: ManagedStdioOwnerSubscriber
    ): ManagedStdioOperationResult {
        synchronized(this.lock) {
            match (this.owners.get(ownerId)) {
                case None => ManagedStdioOperationResult(false, "owner_not_found", generation: this.generation)
                case Some(state) =>
                    if (state.generation != expectedGeneration) {
                        return ManagedStdioOperationResult(false, "stale_generation", generation: state.generation)
                    }
                    if (state.readModeClaimed || state.subscriber.isSome()) {
                        return ManagedStdioOperationResult(false, "owner_delivery_conflict", generation: state.generation)
                    }
                    state.subscriber = Some(subscriber)
                    var accepted = true
                    while (!state.events.isEmpty() && accepted) {
                        let event = state.events.remove(at: 0)
                        let eventBytes = state.eventBytes.remove(at: 0)
                        accepted = this.enqueueDispatchLocked(state, event, eventBytes)
                    }
                    if (!accepted) {
                        var index: Int64 = this.dispatchItems.size - 1
                        while (index >= 0) {
                            let item = this.dispatchItems[index]
                            if (item.ownerId == ownerId && item.generation == expectedGeneration) {
                                this.dispatchItems.remove(at: index)
                                this.dispatchBytes -= item.eventBytes
                                state.queuedBytes -= item.eventBytes
                                state.dispatchPending -= 1
                            }
                            index -= 1
                        }
                        while (!state.events.isEmpty()) {
                            state.events.remove(at: 0)
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                        }
                        return ManagedStdioOperationResult(false, "dispatch_capacity_exceeded", generation: state.generation)
                    }
                    if (this.dispatchFuture.isNone()) {
                        this.dispatchClosing = false
                        this.dispatcherCount = 1
                        this.dispatchFuture = Some(spawn { this.dispatchOwnerEvents() })
                    }
                    ManagedStdioOperationResult(true, "subscribed", generation: state.generation, pid: state.pid, pgid: state.pgid)
            }
        }
    }

    public func unsubscribeOwner(ownerId: String, expectedGeneration: Int64): ManagedStdioOperationResult {
        synchronized(this.lock) {
            match (this.owners.get(ownerId)) {
                case None => ManagedStdioOperationResult(true, "already_unsubscribed", generation: this.generation)
                case Some(state) =>
                    if (state.generation != expectedGeneration) {
                        return ManagedStdioOperationResult(false, "stale_generation", generation: state.generation)
                    }
                    state.subscriber = None<ManagedStdioOwnerSubscriber>
                    var index: Int64 = this.dispatchItems.size - 1
                    while (index >= 0) {
                        let item = this.dispatchItems[index]
                        if (item.ownerId == ownerId && item.generation == expectedGeneration) {
                            this.dispatchItems.remove(at: index)
                            this.dispatchBytes -= item.eventBytes
                            state.queuedBytes -= item.eventBytes
                            state.dispatchPending -= 1
                        }
                        index -= 1
                    }
                    if (state.settled && state.dispatchPending == 0 && state.events.isEmpty()) { this.owners.remove(ownerId) }
                    state.condition.notifyAll()
                    ManagedStdioOperationResult(true, "unsubscribed", generation: state.generation)
            }
        }
    }

    private func dispatchOwnerEvents(): Unit {
        while (true) {
            let item = synchronized(this.lock) {
                while (this.dispatchItems.isEmpty() && !this.dispatchClosing) {
                    let _ = this.condition.wait(timeout: Duration.millisecond * 100)
                }
                if (this.dispatchItems.isEmpty()) {
                    None<ManagedStdioDispatchItem>
                } else {
                    let value = this.dispatchItems.remove(at: 0)
                    this.dispatchBytes -= value.eventBytes
                    Some(value)
                }
            }
            match (item) {
                case None => break
                case Some(value) =>
                    var delivered = true
                    try { value.subscriber.onManagedStdioEvent(value.event) } catch (_: Exception) { delivered = false }
                    var stopFailedSubscriber = false
                    synchronized(this.lock) {
                        match (this.owners.get(value.ownerId)) {
                            case Some(state) =>
                                if (state.generation == value.generation) {
                                    state.queuedBytes -= value.eventBytes
                                    state.dispatchPending -= 1
                                    if (!delivered) {
                                        state.status = "subscriber_failed"
                                        state.subscriber = None<ManagedStdioOwnerSubscriber>
                                        state.subscriberFailed = true
                                        var index: Int64 = this.dispatchItems.size - 1
                                        while (index >= 0) {
                                            let queued = this.dispatchItems[index]
                                            if (queued.ownerId == value.ownerId && queued.generation == value.generation) {
                                                this.dispatchItems.remove(at: index)
                                                this.dispatchBytes -= queued.eventBytes
                                                state.queuedBytes -= queued.eventBytes
                                                state.dispatchPending -= 1
                                            }
                                            index -= 1
                                        }
                                        stopFailedSubscriber = !state.settled
                                    } else if (this.isTerminalEvent(value.event)) {
                                        state.subscriber = None<ManagedStdioOwnerSubscriber>
                                    }
                                    if (state.settled && state.dispatchPending == 0 && state.events.isEmpty()) { this.owners.remove(value.ownerId) }
                                    state.condition.notifyAll()
                                }
                            case None => ()
                        }
                    }
                    if (stopFailedSubscriber) {
                        let stop = JsonObject()
                        stop.put("type", JsonString("owner.stop"))
                        stop.put("ownerId", JsonString(value.ownerId))
                        stop.put("reason", JsonString("subscriber_failed"))
                        let _ = this.writeFrameForGeneration(stop, value.generation)
                    }
            }
        }
        synchronized(this.lock) {
            this.dispatcherCount = 0
            this.condition.notifyAll()
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
                        if (state.subscriber.isSome()) {
                            result = Some(ManagedStdioEvent("owner.error", ownerId: ownerId, status: "owner_delivery_conflict"))
                            done = true
                        } else if (!state.events.isEmpty()) {
                            state.readModeClaimed = true
                            result = Some(state.events.remove(at: 0))
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                            if (state.events.isEmpty() && state.settled) { this.owners.remove(ownerId) }
                            done = true
                        } else if (state.settled || timeoutMs <= 0) {
                            state.readModeClaimed = true
                            done = true
                        } else {
                            state.readModeClaimed = true
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

    public func stopOwner(
        ownerId: String,
        timeoutMs!: Int64 = 1000,
        expectedGeneration!: Option<Int64> = None<Int64>
    ): ManagedStdioOperationResult {
        let state = synchronized(this.lock) { this.owners.get(ownerId) }
        match (state) {
            case None =>
                match (expectedGeneration) {
                    case Some(value) =>
                        if (value != this.generation) { return ManagedStdioOperationResult(false, "stale_generation", generation: this.generation) }
                    case None => ()
                }
                return ManagedStdioOperationResult(true, "already_stopped", generation: this.generation)
            case Some(value) =>
                match (expectedGeneration) {
                    case Some(expected) =>
                        if (value.generation != expected) { return ManagedStdioOperationResult(false, "stale_generation", generation: value.generation) }
                    case None => ()
                }
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
                            if (value.subscriber.isNone() && value.dispatchPending == 0 && value.events.isEmpty()) { this.owners.remove(ownerId) }
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
                        value.writeln(managedStdioCompactJson(frame))
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

    // Caller holds lock.
    private func routeOwnerEventLocked(state: ManagedStdioOwnerState, event: ManagedStdioEvent, eventBytes: Int64): Bool {
        if (state.subscriberFailed) { return true }
        if (state.events.size + state.dispatchPending >= this.ownerQueueLimit || state.queuedBytes + eventBytes > state.maxBufferedBytes) {
            state.status = "buffer_capacity_exceeded"
            return false
        }
        state.queuedBytes += eventBytes
        if (state.subscriber.isSome()) {
            if (!this.enqueueDispatchLocked(state, event, eventBytes)) {
                state.queuedBytes -= eventBytes
                return false
            }
        } else {
            state.events.add(event)
            state.eventBytes.add(eventBytes)
        }
        true
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
                        if (!this.routeOwnerEventLocked(state, ManagedStdioEvent(
                            frameType,
                            ownerId: ownerId,
                            text: text,
                            sequence: managedStdioJsonInt(obj, "seq", 0),
                            finalChunk: managedStdioJsonBool(obj, "final")
                        ), textBytes)) {
                            stopForCapacity = true
                        }
                        state.condition.notifyAll()
                    } else if (frameType == "owner.error" || frameType == "owner.timeout") {
                        state.status = managedStdioJsonString(obj, "status")
                        while (state.events.size + state.dispatchPending >= this.ownerQueueLimit && !state.events.isEmpty()) {
                            state.events.remove(at: 0)
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                        }
                        let _ = this.routeOwnerEventLocked(state, ManagedStdioEvent(frameType, ownerId: ownerId, status: state.status), 0)
                        state.settled = true
                        if (state.subscriberFailed && state.dispatchPending == 0) { this.owners.remove(ownerId) }
                        state.condition.notifyAll()
                    } else if (frameType == "owner.exit") {
                        state.status = "exited"
                        while (state.events.size + state.dispatchPending >= this.ownerQueueLimit && !state.events.isEmpty()) {
                            state.events.remove(at: 0)
                            state.queuedBytes -= state.eventBytes.remove(at: 0)
                        }
                        let _ = this.routeOwnerEventLocked(state, ManagedStdioEvent(frameType, ownerId: ownerId, exitCode: managedStdioJsonInt(obj, "exitCode", -1)), 0)
                        state.settled = true
                        if (state.subscriberFailed && state.dispatchPending == 0) { this.owners.remove(ownerId) }
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
                    let _ = this.routeOwnerEventLocked(state, ManagedStdioEvent("owner.error", ownerId: state.ownerId, status: reason), 0)
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
        let safeIds = ArrayList<(Int64, Int64)>()
        for ((pid, pgid) in ids) {
            if (managedStdioOwnerIdentitySafeForReap(this.platformName, pid, pgid)) { safeIds.add((pid, pgid)) }
        }
        for ((pid, pgid) in safeIds) { let _ = this.platformRunner.terminateTree(pid, pgid, false) }
        sleep(Duration.millisecond * MANAGED_STDIO_REAP_GRACE_MS)
        for ((pid, pgid) in safeIds) {
            if (this.platformRunner.treeAlive(pid, pgid)) { let _ = this.platformRunner.terminateTree(pid, pgid, true) }
        }
        let deadline = this.nowMs() + 1000
        while (this.nowMs() < deadline) {
            var anyAlive = false
            for ((pid, pgid) in safeIds) {
                if (this.platformRunner.treeAlive(pid, pgid)) { anyAlive = true }
            }
            if (!anyAlive) { return }
            sleep(Duration.millisecond * 20)
        }
    }

    public func close(timeoutMs!: Int64 = 2000): ManagedStdioOperationResult {
        let snapshot = this.snapshot()
        let fullyStopped = synchronized(this.lock) {
            this.process.isNone() && this.readerFuture.isNone() && this.readerCount == 0 && this.dispatchFuture.isNone()
        }
        if (fullyStopped) {
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
        let reader = synchronized(this.lock) { this.readerFuture }
        let readerJoined = match (reader) {
            case Some(future) => try { future.get(Duration.millisecond * max(1, timeoutMs)); true } catch (_: Exception) { false }
            case None => synchronized(this.lock) { this.readerCount == 0 }
        }
        let dispatcher = synchronized(this.lock) {
            this.dispatchClosing = true
            this.condition.notifyAll()
            this.dispatchFuture
        }
        let dispatcherJoined = match (dispatcher) {
            case Some(future) => try { future.get(Duration.millisecond * max(1, timeoutMs)); true } catch (_: Exception) { false }
            case None => true
        }
        if (readerJoined && dispatcherJoined) {
            synchronized(this.lock) {
                this.process = None<SubProcess>
                this.writer = None<StringWriter<OutputStream>>
                this.readerFuture = None<Future<Unit>>
                this.helloReceived = false
                this.brokerPid = 0
                this.readerCount = 0
                this.dispatchFuture = None<Future<Unit>>
                this.dispatchItems.clear()
                this.dispatchBytes = 0
                this.dispatcherCount = 0
                this.dispatchClosing = false
                this.status = "stopped"
                this.owners.clear()
                this.closing = false
            }
        } else {
            synchronized(this.lock) {
                this.status = "broker_shutdown_timeout"
                this.closing = false
            }
        }
        let joined = readerJoined && dispatcherJoined
        ManagedStdioOperationResult(joined, if (joined) { "stopped" } else { "broker_shutdown_timeout" }, generation: snapshot.generation)
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
                this.readerCount,
                dispatcherCount: this.dispatcherCount
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

// Test-only singleton reset. Holding the singleton lock through close prevents
// concurrent callers from observing or creating a replacement before teardown.
public func resetManagedStdioBrokerForTest(timeoutMs!: Int64 = 2000): ManagedStdioOperationResult {
    synchronized(managedStdioSingletonLock) {
        match (managedStdioSingleton) {
            case Some(value) =>
                let result = value.close(timeoutMs: timeoutMs)
                if (result.ok) { managedStdioSingleton = None<ManagedStdioBrokerClient> }
                result
            case None => ManagedStdioOperationResult(true, "already_stopped")
        }
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
