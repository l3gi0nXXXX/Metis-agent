package metis.gateway.channels.feishu

import metis.core.config.CliConfig

import std.collection.{ArrayList, HashMap}
import std.env.getVariables
import std.fs.Path
import std.io.*
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class FeishuSidecarTransportOptions {
    public let command: String
    public let args: Array<String>
    public let readyTimeoutMs: Int64
    public let readTimeoutMs: Int64
    public let stopTimeoutMs: Int64
    public let startBackgroundReader: Bool
    public let runtimeRoot: String
    public let workingDirectory: String
    public let env: Array<(String, String)>

    public init(
        command!: String = "node",
        args!: Array<String> = ["scripts/feishu-sidecar.mjs"],
        runtimeRoot!: String = "",
        workingDirectory!: String = "",
        env!: Array<(String, String)> = [],
        readyTimeoutMs!: Int64 = 10000,
        readTimeoutMs!: Int64 = 250,
        stopTimeoutMs!: Int64 = 500,
        startBackgroundReader!: Bool = false
    ) {
        this.command = if (command.trimAscii().isEmpty()) { "node" } else { command.trimAscii() }
        this.args = args
        this.runtimeRoot = feishuSidecarNormalizeRuntimeRoot(runtimeRoot)
        this.workingDirectory = feishuSidecarNormalizeWorkingDirectory(workingDirectory)
        this.env = feishuSidecarNormalizeEnv(env, this.runtimeRoot)
        this.readyTimeoutMs = if (readyTimeoutMs > 0) { readyTimeoutMs } else { 10000 }
        this.readTimeoutMs = if (readTimeoutMs > 0) { readTimeoutMs } else { 250 }
        this.stopTimeoutMs = if (stopTimeoutMs > 0) { stopTimeoutMs } else { 500 }
        this.startBackgroundReader = startBackgroundReader
    }
}

public class FeishuSidecarLaunchSpec {
    public let command: String
    public let args: Array<String>
    public let runtimeRoot: String
    public let workingDirectory: Option<String>
    public let env: Array<(String, String)>

    public init(
        command!: String,
        args!: Array<String>,
        runtimeRoot!: String = "",
        workingDirectory!: Option<String> = None<String>,
        env!: Array<(String, String)> = []
    ) {
        this.command = command.trimAscii()
        this.args = args
        this.runtimeRoot = feishuSidecarNormalizeRuntimeRoot(runtimeRoot)
        this.workingDirectory = match (workingDirectory) {
            case Some(raw) =>
                let normalized = feishuSidecarNormalizeWorkingDirectory(raw)
                if (normalized.isEmpty()) { None<String> } else { Some(normalized) }
            case None =>
                let normalized = feishuSidecarNormalizeWorkingDirectory("")
                if (normalized.isEmpty()) { None<String> } else { Some(normalized) }
        }
        this.env = feishuSidecarNormalizeEnv(env, this.runtimeRoot)
    }
}

public interface FeishuSidecarProtocolProcess {
    func pid(): Int64
    func writeLine(line: String): Unit
    func readLine(timeoutMs: Int64): Option<String>
    func isAlive(): Bool
    func wait(timeoutMs: Int64): Option<Int64>
    func terminate(force: Bool): Unit
    func stdoutSummary(): String
    func stderrSummary(): String
}

public enum FeishuSidecarProtocolStartResult {
    | Started(FeishuSidecarProtocolProcess)
    | Failed(String)
}

public interface FeishuSidecarProtocolRunner {
    func start(spec: FeishuSidecarLaunchSpec): FeishuSidecarProtocolStartResult
}

public class FeishuSidecarDiagnosticSnapshot {
    public let atMs: Int64
    public let level: String
    public let phase: String
    public let status: String
    public let message: String

    public init(atMs!: Int64, level!: String = "info", phase!: String = "", status!: String = "", message!: String = "") {
        this.atMs = atMs
        this.level = if (level.trimAscii().isEmpty()) { "info" } else { level.trimAscii() }
        this.phase = phase.trimAscii()
        this.status = status.trimAscii()
        this.message = message.trimAscii()
    }
}

public class FeishuSidecarHealthSnapshot {
    public let pid: Int64
    public let ready: Bool
    public let connected: Bool
    public let lastError: String
    public let lastInboundAt: Int64
    public let diagnosticRingSize: Int64

    public init(
        pid!: Int64 = 0,
        ready!: Bool = false,
        connected!: Bool = false,
        lastError!: String = "",
        lastInboundAt!: Int64 = 0,
        diagnosticRingSize!: Int64 = 0
    ) {
        this.pid = pid
        this.ready = ready
        this.connected = connected
        this.lastError = lastError.trimAscii()
        this.lastInboundAt = lastInboundAt
        this.diagnosticRingSize = diagnosticRingSize
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("pid", JsonInt(this.pid))
        out.put("ready", JsonString(if (this.ready) { "true" } else { "false" }))
        out.put("connected", JsonString(if (this.connected) { "true" } else { "false" }))
        out.put("lastError", JsonString(this.lastError))
        out.put("lastInboundAt", JsonInt(this.lastInboundAt))
        out.put("diagnosticRingSize", JsonInt(this.diagnosticRingSize))
        out
    }
}

public class FeishuSidecarNotConfiguredRunner <: FeishuSidecarProtocolRunner {
    public init() {}

    public func start(_spec: FeishuSidecarLaunchSpec): FeishuSidecarProtocolStartResult {
        FeishuSidecarProtocolStartResult.Failed("not_configured: Feishu sidecar protocol runner is not configured")
    }
}

private let FEISHU_SIDECAR_STDIO_MAX_QUEUED_LINES: Int64 = 256
private let FEISHU_SIDECAR_STDIO_SUMMARY_LINES: Int64 = 16
private let FEISHU_SIDECAR_STDIO_MAX_LINE_CHARS: Int64 = 1048576

public class FeishuSidecarLineBuffer {
    private let lock = Mutex()
    private let condition: Condition
    private let name: String
    private let maxLines: Int64
    private let maxSummaryLines: Int64
    private let maxLineChars: Int64
    private let lines = ArrayList<String>()
    private let summaryLines = ArrayList<String>()
    private var closed = false
    private var lastErrorText = ""
    private var dropped: Int64 = 0

    public init(
        name!: String = "stdio",
        maxLines!: Int64 = FEISHU_SIDECAR_STDIO_MAX_QUEUED_LINES,
        maxLineChars!: Int64 = FEISHU_SIDECAR_STDIO_MAX_LINE_CHARS,
        maxSummaryLines!: Int64 = FEISHU_SIDECAR_STDIO_SUMMARY_LINES
    ) {
        let normalizedName = name.trimAscii()
        this.name = if (normalizedName.isEmpty()) { "stdio" } else { normalizedName }
        this.maxLines = if (maxLines > 0) { maxLines } else { 1 }
        this.maxLineChars = if (maxLineChars > 0) { maxLineChars } else { FEISHU_SIDECAR_STDIO_MAX_LINE_CHARS }
        this.maxSummaryLines = if (maxSummaryLines > 0) { maxSummaryLines } else { FEISHU_SIDECAR_STDIO_SUMMARY_LINES }
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    public func appendLine(line: String): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
            if (line.size > this.maxLineChars) {
                this.dropped += 1
                this.rememberSummaryLocked("${this.name} dropped oversized line chars=${line.size} max=${this.maxLineChars}")
                return
            }
            while (this.lines.size >= this.maxLines) {
                this.lines.remove(at: 0)
                this.dropped += 1
            }
            this.lines.add(line)
            this.rememberSummaryLocked(line)
            this.condition.notifyAll()
        }
    }

    public func readLine(timeoutMs: Int64): Option<String> {
        let effectiveTimeoutMs = if (timeoutMs > 0) { timeoutMs } else { 250 }
        synchronized(this.lock) {
            if (this.lines.isEmpty() && !this.closed) {
                let _ = this.condition.waitUntil(
                    { => !this.lines.isEmpty() || this.closed },
                    timeout: Duration.millisecond * effectiveTimeoutMs
                )
            }
            if (this.lines.isEmpty()) {
                return None<String>
            }
            let line = this.lines[0]
            this.lines.remove(at: 0)
            Some(line)
        }
    }

    public func close(error!: String = ""): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.lastErrorText = error.trimAscii()
            } else if (this.lastErrorText.isEmpty()) {
                this.lastErrorText = error.trimAscii()
            }
            this.condition.notifyAll()
        }
    }

    public func droppedCount(): Int64 {
        synchronized(this.lock) {
            this.dropped
        }
    }

    public func lastError(): String {
        synchronized(this.lock) {
            this.lastErrorText
        }
    }

    public func summary(): String {
        synchronized(this.lock) {
            let parts = ArrayList<String>()
            if (this.dropped > 0) {
                parts.add("${this.name} dropped=${this.dropped}")
            }
            if (!this.lastErrorText.isEmpty()) {
                parts.add("${this.name} error=${this.lastErrorText}")
            }
            let text = String.join(this.summaryLines.toArray(), delimiter: "\n")
            if (!text.isEmpty()) {
                parts.add(text)
            }
            feishuSidecarSummarizeText(String.join(parts.toArray(), delimiter: "\n"))
        }
    }

    private func rememberSummaryLocked(line: String): Unit {
        this.summaryLines.add(line)
        while (this.summaryLines.size > this.maxSummaryLines) {
            this.summaryLines.remove(at: 0)
        }
    }
}

public class FeishuSidecarStdioProcess <: FeishuSidecarProtocolProcess {
    private let process: SubProcess
    private let writer: StringWriter<OutputStream>
    private let stateLock = Mutex()
    private let stdoutBuffer = FeishuSidecarLineBuffer(
        name: "stdout",
        maxLines: FEISHU_SIDECAR_STDIO_MAX_QUEUED_LINES,
        maxLineChars: FEISHU_SIDECAR_STDIO_MAX_LINE_CHARS,
        maxSummaryLines: FEISHU_SIDECAR_STDIO_SUMMARY_LINES
    )
    private let stderrBuffer = FeishuSidecarLineBuffer(
        name: "stderr",
        maxLines: FEISHU_SIDECAR_STDIO_SUMMARY_LINES,
        maxLineChars: FEISHU_SIDECAR_STDIO_MAX_LINE_CHARS,
        maxSummaryLines: FEISHU_SIDECAR_STDIO_SUMMARY_LINES
    )
    private var closed = false

    public init(process: SubProcess) {
        this.process = process
        this.writer = StringWriter(process.stdInPipe)
        let stdoutReader = StringReader<InputStream>(process.stdOutPipe)
        let stderrReader = StringReader<InputStream>(process.stdErrPipe)
        spawn {
            this.readPipeLines(stdoutReader, this.stdoutBuffer)
        }
        spawn {
            this.readPipeLines(stderrReader, this.stderrBuffer)
        }
    }

    public func pid(): Int64 {
        0
    }

    public func writeLine(line: String): Unit {
        this.writer.writeln(line)
        this.writer.flush()
    }

    public func readLine(timeoutMs: Int64): Option<String> {
        this.stdoutBuffer.readLine(timeoutMs)
    }

    public func isAlive(): Bool {
        !this.isClosed() && this.process.isAlive()
    }

    public func wait(timeoutMs: Int64): Option<Int64> {
        try {
            let result = this.process.wait(timeout: Some(Duration.millisecond * if (timeoutMs > 0) { timeoutMs } else { 500 }))
            this.closeBuffers("")
            Some(result)
        } catch (_: Exception) {
            None<Int64>
        }
    }

    public func terminate(force: Bool): Unit {
        this.closeBuffers("terminated")
        try { this.process.terminate(force: force) } catch (_: Exception) { () }
    }

    public func stdoutSummary(): String {
        this.stdoutBuffer.summary()
    }

    public func stderrSummary(): String {
        this.stderrBuffer.summary()
    }

    private func readPipeLines(reader: StringReader<InputStream>, buffer: FeishuSidecarLineBuffer): Unit {
        while (!this.isClosed()) {
            let line = try {
                reader.readln()
            } catch (e: Exception) {
                buffer.close(error: "read failed: ${e.message}")
                return
            }
            match (line) {
                case Some(value) => buffer.appendLine(value)
                case None =>
                    buffer.close()
                    return
            }
        }
    }

    private func closeBuffers(reason: String): Unit {
        synchronized(this.stateLock) {
            this.closed = true
        }
        this.stdoutBuffer.close(error: reason)
        this.stderrBuffer.close(error: reason)
    }

    private func isClosed(): Bool {
        synchronized(this.stateLock) {
            this.closed
        }
    }
}

public class FeishuSidecarStdioRunner <: FeishuSidecarProtocolRunner {
    public init() {}

    public func start(spec: FeishuSidecarLaunchSpec): FeishuSidecarProtocolStartResult {
        if (spec.command.isEmpty() || spec.args.isEmpty()) {
            return FeishuSidecarProtocolStartResult.Failed("not_configured: Feishu sidecar command and args are required")
        }
        try {
            let process = launch(
                spec.command,
                spec.args,
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe,
                workingDirectory: spec.workingDirectory.map({ value => Path(value) }),
                environment: Some(feishuSidecarProcessEnvironment(spec.env))
            )
            FeishuSidecarProtocolStartResult.Started(FeishuSidecarStdioProcess(process))
        } catch (e: Exception) {
            FeishuSidecarProtocolStartResult.Failed("launch_failed: ${e.message}")
        }
    }
}

private class FeishuSidecarProtocolOutcome {
    public let done: Bool
    public let ok: Bool
    public let status: String
    public let error: String

    public init(done!: Bool = false, ok!: Bool = false, status!: String = "", error!: String = "") {
        this.done = done
        this.ok = ok
        this.status = status
        this.error = error
    }
}

public class FeishuSidecarTransport <: FeishuLongConnectTransport {
    private let lock = Mutex()
    private let runner: FeishuSidecarProtocolRunner
    private let options: FeishuSidecarTransportOptions
    private let diagnostics = ArrayList<FeishuSidecarDiagnosticSnapshot>()
    private var process: Option<FeishuSidecarProtocolProcess> = None
    private var handler: Option<(JsonObject) -> Unit> = None
    private var running = false
    private var ready = false
    private var everReady = false
    private var connected = false
    private var pidValue: Int64 = 0
    private var lastError = ""
    private var lastInboundAt = 0
    private var generation: Int64 = 0

    public init(
        runner!: FeishuSidecarProtocolRunner = FeishuSidecarNotConfiguredRunner(),
        options!: FeishuSidecarTransportOptions = FeishuSidecarTransportOptions()
    ) {
        this.runner = runner
        this.options = options
    }

    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        let launch = FeishuSidecarLaunchSpec(
            command: this.options.command,
            args: this.options.args,
            runtimeRoot: this.options.runtimeRoot,
            workingDirectory: Some(this.options.workingDirectory),
            env: this.options.env
        )
        match (this.runner.start(launch)) {
            case FeishuSidecarProtocolStartResult.Failed(reason) =>
                let status = if (reason.contains("not_configured")) { "not_configured" } else { "launch_failed" }
                let error = feishuSidecarTransportRedactSensitiveText(reason)
                this.recordFailure("start", status, error)
                return FeishuLongConnectStartResult(ok: false, status: status, error: error)
            case FeishuSidecarProtocolStartResult.Started(proc) =>
                synchronized(this.lock) {
                    this.process = Some(proc)
                    this.handler = Some(eventHandler)
                    this.running = true
                    this.ready = false
                    this.everReady = false
                    this.connected = false
                    this.pidValue = proc.pid()
                    this.lastError = ""
                    this.lastInboundAt = 0
                    this.generation += 1
                }
                try {
                    proc.writeLine(this.compactJsonLine(this.initFrame(spec, launch).toJsonString()))
                } catch (e: Exception) {
                    let error = feishuSidecarTransportRedactSensitiveText("init write failed: ${e.message}")
                    this.recordFailure("init", "write_failed", error)
                    return FeishuLongConnectStartResult(ok: false, status: "write_failed", error: error)
                }
                let result = this.waitForReady(proc)
                if (result.ok && this.options.startBackgroundReader) {
                    let currentGeneration = this.currentGeneration()
                    spawn {
                        this.readLoop(currentGeneration)
                    }
                }
                result
        }
    }

    public func stop(): Unit {
        let proc = synchronized(this.lock) {
            this.running = false
            this.ready = false
            this.everReady = false
            this.connected = false
            this.generation += 1
            this.process
        }
        if (let Some(p) <- proc) {
            match (p.wait(this.options.stopTimeoutMs)) {
                case Some(_) => ()
                case None => p.terminate(true)
            }
        }
    }

    public func healthSnapshot(): FeishuSidecarHealthSnapshot {
        synchronized(this.lock) {
            FeishuSidecarHealthSnapshot(
                pid: this.pidValue,
                ready: this.ready,
                connected: this.connected,
                lastError: this.lastError,
                lastInboundAt: this.lastInboundAt,
                diagnosticRingSize: this.diagnostics.size
            )
        }
    }

    public func diagnosticsSnapshot(): Array<FeishuSidecarDiagnosticSnapshot> {
        let out = ArrayList<FeishuSidecarDiagnosticSnapshot>()
        synchronized(this.lock) {
            for (entry in this.diagnostics) {
                out.add(entry)
            }
        }
        out.toArray()
    }

    public func debugDrainAvailableForTest(): Unit {
        while (this.drainOne()) {
            ()
        }
        this.recordUnexpectedExitIfNeeded()
    }

    private func drainOne(): Bool {
        let proc = synchronized(this.lock) { this.process }
        match (proc) {
            case Some(p) =>
                match (p.readLine(this.options.readTimeoutMs)) {
                    case Some(line) =>
                        let _ = this.handleLine(line, false)
                        true
                    case None => false
                }
            case None => false
        }
    }

    private func waitForReady(proc: FeishuSidecarProtocolProcess): FeishuLongConnectStartResult {
        let deadline = this.nowMs() + this.options.readyTimeoutMs
        while (this.nowMs() <= deadline) {
            match (proc.readLine(this.options.readTimeoutMs)) {
                case Some(line) =>
                    let outcome = this.handleLine(line, true)
                    if (outcome.done) {
                        return FeishuLongConnectStartResult(ok: outcome.ok, status: outcome.status, error: outcome.error)
                    }
                case None =>
                    if (!proc.isAlive()) {
                        let error = this.processError("sidecar exited before ready", proc)
                        this.recordFailure("start", "unexpected_exit", error)
                        return FeishuLongConnectStartResult(ok: false, status: "unexpected_exit", error: error)
                    }
            }
        }
        let error = this.processError("sidecar ready timeout", proc)
        this.recordFailure("start", "ready_timeout", error)
        FeishuLongConnectStartResult(ok: false, status: "ready_timeout", error: error)
    }

    private func readLoop(expectedGeneration: Int64): Unit {
        while (this.activeGeneration(expectedGeneration)) {
            let proc = synchronized(this.lock) { this.process }
            match (proc) {
                case Some(p) =>
                    match (p.readLine(this.options.readTimeoutMs)) {
                        case Some(line) => let _ = this.handleLine(line, false)
                        case None =>
                            if (!p.isAlive()) {
                                this.recordUnexpectedExitIfNeeded()
                                return
                            }
                    }
                case None => return
            }
        }
    }

    private func handleLine(line: String, readyPhase: Bool): FeishuSidecarProtocolOutcome {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            return FeishuSidecarProtocolOutcome()
        }
        let frame: JsonObject
        try {
            frame = JsonValue.fromStr(trimmed).asObject()
        } catch (_: Exception) {
            let error = "sidecar non-json protocol line"
            this.recordFailure("protocol", "protocol_error", error)
            return FeishuSidecarProtocolOutcome(done: readyPhase, ok: false, status: "protocol_error", error: error)
        }
        let frameType = this.readString(frame, "type")
        if (frameType == "ready") {
            synchronized(this.lock) {
                this.ready = true
                this.everReady = true
                this.connected = true
                this.lastError = ""
            }
            this.recordDiagnostic("info", "ready", "ok", "")
            return FeishuSidecarProtocolOutcome(done: readyPhase, ok: true, status: "ready")
        }
        if (frameType == "diagnostic") {
            let level = this.readString(frame, "level", fallback: "info")
            let phase = this.readString(frame, "phase", fallback: "diagnostic")
            let status = this.readString(frame, "status", fallback: "ok")
            let message = feishuSidecarTransportRedactSensitiveText(this.readString(frame, "message"))
            this.recordDiagnostic(level, phase, status, message)
            if (level == "error" || status == "failed") {
                let error = this.composeError(phase, status, message)
                let callback = synchronized(this.lock) {
                    this.ready = false
                    this.connected = false
                    this.lastError = error
                    this.handler
                }
                if (let Some(h) <- callback) {
                    h(this.diagnosticRoot(level, phase, status, message))
                }
            }
            return FeishuSidecarProtocolOutcome()
        }
        if (frameType == "inbound") {
            this.handleInbound(frame)
            return FeishuSidecarProtocolOutcome()
        }
        if (frameType == "error") {
            let phase = this.readString(frame, "phase", fallback: "error")
            let status = this.readString(frame, "status", fallback: "error")
            let message = feishuSidecarTransportRedactSensitiveText(this.readString(frame, "message", fallback: this.readString(frame, "error")))
            let error = this.composeError(phase, status, message)
            synchronized(this.lock) {
                this.ready = false
                this.connected = false
            }
            this.recordFailure(phase, status, error)
            return FeishuSidecarProtocolOutcome(done: readyPhase, ok: false, status: status, error: error)
        }
        if (frameType == "closed") {
            let reason = feishuSidecarTransportRedactSensitiveText(this.readString(frame, "reason", fallback: "closed"))
            synchronized(this.lock) {
                this.ready = false
                this.connected = false
            }
            let error = "sidecar closed: ${reason}"
            this.recordFailure("closed", "closed", error)
            return FeishuSidecarProtocolOutcome(done: readyPhase, ok: false, status: "closed", error: error)
        }
        let error = "unknown sidecar frame type: ${frameType}"
        this.recordFailure("protocol", "protocol_error", error)
        FeishuSidecarProtocolOutcome(done: readyPhase, ok: false, status: "protocol_error", error: error)
    }

    private func handleInbound(frame: JsonObject): Unit {
        let root = this.inboundRoot(frame)
        let callback = synchronized(this.lock) {
            this.connected = true
            this.lastInboundAt = this.nowMs()
            this.handler
        }
        this.recordDiagnostic("info", "event.dispatch", "ok", this.readString(frame, "eventType"))
        if (let Some(h) <- callback) {
            h(root)
        }
    }

    private func inboundRoot(frame: JsonObject): JsonObject {
        let accountId = this.readString(frame, "accountId")
        let eventType = this.readString(frame, "eventType")
        let event = match (frame.get("event")) {
            case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
            case None => JsonObject()
        }
        let header = JsonObject()
        header.put("event_type", JsonString(eventType))
        header.put("account_id", JsonString(accountId))
        let root = JsonObject()
        root.put("header", header)
        root.put("event", event)
        root
    }

    private func diagnosticRoot(level: String, phase: String, status: String, message: String): JsonObject {
        let header = JsonObject()
        header.put("event_type", JsonString("metis.feishu.sidecar.diagnostic"))
        header.put("account_id", JsonString(""))
        let sidecar = JsonObject()
        sidecar.put("level", JsonString(level))
        sidecar.put("phase", JsonString(phase))
        sidecar.put("status", JsonString(status))
        sidecar.put("message", JsonString(message))
        let root = JsonObject()
        root.put("header", header)
        root.put("sidecar", sidecar)
        root
    }

    private func recordUnexpectedExitIfNeeded(): Unit {
        let shouldRecord = synchronized(this.lock) {
            match (this.process) {
                case Some(p) => this.running && this.everReady && !p.isAlive()
                case None => false
            }
        }
        if (shouldRecord) {
            synchronized(this.lock) {
                this.ready = false
                this.connected = false
            }
            this.recordFailure("process", "unexpected_exit", "sidecar unexpected exit")
        }
    }

    private func recordFailure(phase: String, status: String, message: String): Unit {
        this.setLastError(message)
        this.recordDiagnostic("error", phase, status, message)
    }

    private func recordDiagnostic(level: String, phase: String, status: String, message: String): Unit {
        let entry = FeishuSidecarDiagnosticSnapshot(
            atMs: this.nowMs(),
            level: level,
            phase: phase,
            status: status,
            message: message
        )
        synchronized(this.lock) {
            this.diagnostics.add(entry)
            while (this.diagnostics.size > 64) {
                this.diagnostics.remove(at: 0)
            }
        }
    }

    private func setLastError(message: String): Unit {
        synchronized(this.lock) {
            this.lastError = message.trimAscii()
        }
    }

    private func initFrame(spec: FeishuLongConnectStartSpec, launch: FeishuSidecarLaunchSpec): JsonObject {
        let out = JsonObject()
        out.put("type", JsonString("init"))
        out.put("accountId", JsonString(spec.accountId))
        out.put("appId", JsonString(spec.appId))
        out.put("appSecret", JsonString(spec.appSecret))
        out.put("domain", JsonString(spec.domain))
        out.put("verificationToken", JsonString(spec.verificationToken))
        out.put("encryptKey", JsonString(spec.encryptKey))
        out.put("mode", JsonString("websocket"))
        out.put("runtimeRoot", JsonString(launch.runtimeRoot))
        out
    }

    private func processError(prefix: String, proc: FeishuSidecarProtocolProcess): String {
        let parts = ArrayList<String>()
        let base = feishuSidecarTransportRedactSensitiveText(prefix)
        parts.add(base)
        let stdout = feishuSidecarTransportRedactSensitiveText(proc.stdoutSummary())
        if (!stdout.isEmpty()) {
            parts.add("stdout=${stdout}")
        }
        let stderr = feishuSidecarTransportRedactSensitiveText(proc.stderrSummary())
        if (!stderr.isEmpty()) {
            parts.add("stderr=${stderr}")
        }
        String.join(parts.toArray(), delimiter: "; ")
    }

    private func composeError(phase: String, status: String, message: String): String {
        if (message.trimAscii().isEmpty()) {
            return "${phase}: ${status}"
        }
        "${phase}: ${status}: ${message.trimAscii()}"
    }

    private func readString(obj: JsonObject, key: String, fallback!: String = ""): String {
        match (obj.get(key)) {
            case Some(value) =>
                try {
                    let text = value.asString().getValue().trimAscii()
                    if (text.isEmpty()) { fallback } else { text }
                } catch (_: Exception) {
                    fallback
                }
            case None => fallback
        }
    }

    private func compactJsonLine(raw: String): String {
        let out = StringBuilder()
        var inString = false
        var escaped = false
        for (ch in raw.toRuneArray()) {
            if (escaped) {
                out.append(ch)
                escaped = false
                continue
            }
            if (inString && ch == r'\\') {
                out.append(ch)
                escaped = true
                continue
            }
            if (ch == r'"') {
                out.append(ch)
                inString = !inString
                continue
            }
            if (!inString && (ch == r' ' || ch == r'\n' || ch == r'\r' || ch == r'\t')) {
                continue
            }
            out.append(ch)
        }
        out.toString()
    }

    private func nowMs(): Int64 {
        DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    private func currentGeneration(): Int64 {
        synchronized(this.lock) {
            this.generation
        }
    }

    private func activeGeneration(expected: Int64): Bool {
        synchronized(this.lock) {
            this.running && this.generation == expected
        }
    }
}

private class FeishuSidecarSupervisorAccountState {
    private let lock = Mutex()
    private var condition: Condition
    public let accountId: String
    private let diagnostics = ArrayList<FeishuSidecarDiagnosticSnapshot>()
    private var handler: Option<(JsonObject) -> Unit> = None
    private var startPending = false
    private var ready = false
    private var connected = false
    private var pidValue: Int64 = 0
    private var lastError = ""
    private var lastStatus = ""
    private var lastInboundAt = 0

    public init(accountId: String) {
        this.accountId = accountId.trimAscii()
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    public func beginStart(pid: Int64, eventHandler: (JsonObject) -> Unit): Unit {
        synchronized(this.lock) {
            this.handler = Some(eventHandler)
            this.startPending = true
            this.ready = false
            this.connected = false
            this.pidValue = pid
            this.lastError = ""
            this.lastStatus = ""
            this.lastInboundAt = 0
            this.condition.notifyAll()
        }
    }

    public func markReady(pid: Int64): Unit {
        synchronized(this.lock) {
            this.startPending = false
            this.ready = true
            this.connected = true
            this.pidValue = pid
            this.lastError = ""
            this.lastStatus = "ready"
            this.condition.notifyAll()
        }
    }

    public func markInbound(): Unit {
        synchronized(this.lock) {
            this.connected = true
            this.lastInboundAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        }
    }

    public func markFailure(status: String, message: String): Unit {
        synchronized(this.lock) {
            this.startPending = false
            this.ready = false
            this.connected = false
            this.lastStatus = if (status.trimAscii().isEmpty()) { "error" } else { status.trimAscii() }
            this.lastError = message.trimAscii()
            this.condition.notifyAll()
        }
    }

    public func markStopped(): Unit {
        synchronized(this.lock) {
            this.startPending = false
            this.ready = false
            this.connected = false
            this.condition.notifyAll()
        }
    }

    public func recordDiagnostic(level: String, phase: String, status: String, message: String): Unit {
        let entry = FeishuSidecarDiagnosticSnapshot(
            atMs: DateTime.now().toUnixTimeStamp().toMilliseconds(),
            level: level,
            phase: phase,
            status: status,
            message: message
        )
        synchronized(this.lock) {
            this.diagnostics.add(entry)
            while (this.diagnostics.size > 64) {
                this.diagnostics.remove(at: 0)
            }
        }
    }

    public func waitForReady(timeoutMs: Int64): FeishuLongConnectStartResult {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (this.startPending) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) {
                    this.startPending = false
                    this.ready = false
                    this.connected = false
                    this.lastStatus = "ready_timeout"
                    this.lastError = "sidecar account ready timeout"
                    return FeishuLongConnectStartResult(ok: false, status: "ready_timeout", error: this.lastError)
                }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            if (this.ready) {
                return FeishuLongConnectStartResult(ok: true, status: "ready")
            }
            FeishuLongConnectStartResult(
                ok: false,
                status: if (this.lastStatus.isEmpty()) { "error" } else { this.lastStatus },
                error: this.lastError
            )
        }
    }

    public func startOutcome(): Option<FeishuLongConnectStartResult> {
        synchronized(this.lock) {
            if (this.startPending) {
                return None<FeishuLongConnectStartResult>
            }
            if (this.ready) {
                return Some(FeishuLongConnectStartResult(ok: true, status: "ready"))
            }
            Some(FeishuLongConnectStartResult(
                ok: false,
                status: if (this.lastStatus.isEmpty()) { "error" } else { this.lastStatus },
                error: this.lastError
            ))
        }
    }

    public func handlerSnapshot(): Option<(JsonObject) -> Unit> {
        synchronized(this.lock) {
            this.handler
        }
    }

    public func healthSnapshot(): FeishuSidecarHealthSnapshot {
        synchronized(this.lock) {
            FeishuSidecarHealthSnapshot(
                pid: this.pidValue,
                ready: this.ready,
                connected: this.connected,
                lastError: this.lastError,
                lastInboundAt: this.lastInboundAt,
                diagnosticRingSize: this.diagnostics.size
            )
        }
    }

    public func diagnosticsSnapshot(): Array<FeishuSidecarDiagnosticSnapshot> {
        let out = ArrayList<FeishuSidecarDiagnosticSnapshot>()
        synchronized(this.lock) {
            for (entry in this.diagnostics) {
                out.add(entry)
            }
        }
        out.toArray()
    }
}

public class FeishuSidecarSupervisorRegistry {
    private let lock = Mutex()
    private let runner: FeishuSidecarProtocolRunner
    private let options: FeishuSidecarTransportOptions
    private let accounts = HashMap<String, FeishuSidecarSupervisorAccountState>()
    private var process: Option<FeishuSidecarProtocolProcess> = None
    private var generation: Int64 = 0
    private var processStartCount: Int64 = 0
    private var registryLastError = ""

    public init(
        runner!: FeishuSidecarProtocolRunner = FeishuSidecarNotConfiguredRunner(),
        options!: FeishuSidecarTransportOptions = FeishuSidecarTransportOptions()
    ) {
        this.runner = runner
        this.options = options
    }

    public func startAccount(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        let accountId = this.normalizeAccountId(spec.accountId)
        let state = this.registerAccount(accountId, eventHandler)
        match (this.ensureProcess()) {
            case FeishuSidecarProtocolStartResult.Failed(reason) =>
                let status = if (reason.contains("not_configured")) { "not_configured" } else { "launch_failed" }
                let error = feishuSidecarTransportRedactSensitiveText(reason)
                state.markFailure(status, error)
                state.recordDiagnostic("error", "start", status, error)
                return FeishuLongConnectStartResult(ok: false, status: status, error: error)
            case FeishuSidecarProtocolStartResult.Started(proc) =>
                state.beginStart(proc.pid(), eventHandler)
                try {
                    proc.writeLine(this.compactJsonLine(this.initAccountFrame(spec, accountId).toJsonString()))
                } catch (e: Exception) {
                    let error = feishuSidecarTransportRedactSensitiveText("initAccount write failed: ${e.message}")
                    state.markFailure("write_failed", error)
                    state.recordDiagnostic("error", "initAccount", "write_failed", error)
                    return FeishuLongConnectStartResult(ok: false, status: "write_failed", error: error)
                }
                if (this.options.startBackgroundReader) {
                    let result = state.waitForReady(this.options.readyTimeoutMs)
                    if (!result.ok && result.status == "ready_timeout") {
                        let error = this.processError("sidecar account ready timeout", proc)
                        state.markFailure("ready_timeout", error)
                        state.recordDiagnostic("error", "start", "ready_timeout", error)
                        return FeishuLongConnectStartResult(ok: false, status: "ready_timeout", error: error)
                    }
                    return result
                }
                this.waitForReadyByPolling(proc, state)
        }
    }

    public func stopAccount(accountId: String): Unit {
        let normalized = this.normalizeAccountId(accountId)
        var proc: Option<FeishuSidecarProtocolProcess> = None
        var shouldStopProcess = false
        var state: Option<FeishuSidecarSupervisorAccountState> = None
        synchronized(this.lock) {
            if (this.accounts.contains(normalized)) {
                state = Some(this.accounts[normalized])
                this.accounts.remove(normalized)
            }
            proc = this.process
            shouldStopProcess = this.accounts.isEmpty()
            if (shouldStopProcess) {
                this.process = None<FeishuSidecarProtocolProcess>
                this.generation += 1
            }
        }
        if (let Some(s) <- state) {
            s.markStopped()
        }
        if (let Some(p) <- proc) {
            try {
                p.writeLine(this.compactJsonLine(this.closeAccountFrame(normalized).toJsonString()))
            } catch (_: Exception) {
                ()
            }
            if (shouldStopProcess) {
                match (p.wait(this.options.stopTimeoutMs)) {
                    case Some(_) => ()
                    case None => p.terminate(true)
                }
            }
        }
    }

    public func healthSnapshot(accountId: String): FeishuSidecarHealthSnapshot {
        let normalized = this.normalizeAccountId(accountId)
        let state = synchronized(this.lock) {
            if (this.accounts.contains(normalized)) {
                Some(this.accounts[normalized])
            } else {
                None<FeishuSidecarSupervisorAccountState>
            }
        }
        match (state) {
            case Some(s) => s.healthSnapshot()
            case None => FeishuSidecarHealthSnapshot(lastError: this.registryLastError)
        }
    }

    public func diagnosticsSnapshot(accountId: String): Array<FeishuSidecarDiagnosticSnapshot> {
        let normalized = this.normalizeAccountId(accountId)
        let state = synchronized(this.lock) {
            if (this.accounts.contains(normalized)) {
                Some(this.accounts[normalized])
            } else {
                None<FeishuSidecarSupervisorAccountState>
            }
        }
        match (state) {
            case Some(s) => s.diagnosticsSnapshot()
            case None => Array<FeishuSidecarDiagnosticSnapshot>(0, repeat: FeishuSidecarDiagnosticSnapshot(atMs: 0))
        }
    }

    public func debugProcessStartCountForTest(): Int64 {
        synchronized(this.lock) {
            this.processStartCount
        }
    }

    public func debugDrainAvailableForTest(): Unit {
        while (this.drainOne()) {
            ()
        }
        this.recordUnexpectedExitIfNeeded()
    }

    private func registerAccount(accountId: String, eventHandler: (JsonObject) -> Unit): FeishuSidecarSupervisorAccountState {
        synchronized(this.lock) {
            if (!this.accounts.contains(accountId)) {
                this.accounts[accountId] = FeishuSidecarSupervisorAccountState(accountId)
            }
            let state = this.accounts[accountId]
            state.beginStart(0, eventHandler)
            state
        }
    }

    private func ensureProcess(): FeishuSidecarProtocolStartResult {
        synchronized(this.lock) {
            match (this.process) {
                case Some(p) =>
                    if (p.isAlive()) {
                        return FeishuSidecarProtocolStartResult.Started(p)
                    }
                    this.process = None<FeishuSidecarProtocolProcess>
                case None => ()
            }
            let launch = FeishuSidecarLaunchSpec(
                command: this.options.command,
                args: this.options.args,
                runtimeRoot: this.options.runtimeRoot,
                workingDirectory: Some(this.options.workingDirectory),
                env: this.options.env
            )
            match (this.runner.start(launch)) {
                case FeishuSidecarProtocolStartResult.Failed(reason) =>
                    this.registryLastError = feishuSidecarTransportRedactSensitiveText(reason)
                    return FeishuSidecarProtocolStartResult.Failed(reason)
                case FeishuSidecarProtocolStartResult.Started(proc) =>
                    this.process = Some(proc)
                    this.registryLastError = ""
                    this.processStartCount += 1
                    this.generation += 1
                    if (this.options.startBackgroundReader) {
                        let currentGeneration = this.generation
                        spawn {
                            this.readLoop(currentGeneration)
                        }
                    }
                    return FeishuSidecarProtocolStartResult.Started(proc)
            }
        }
    }

    private func waitForReadyByPolling(
        proc: FeishuSidecarProtocolProcess,
        state: FeishuSidecarSupervisorAccountState
    ): FeishuLongConnectStartResult {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + this.options.readyTimeoutMs
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() <= deadline) {
            match (state.startOutcome()) {
                case Some(result) => return result
                case None => ()
            }
            match (proc.readLine(this.options.readTimeoutMs)) {
                case Some(line) => let _ = this.handleLine(line)
                case None =>
                    if (!proc.isAlive()) {
                        let error = this.processError("sidecar exited before account ready", proc)
                        state.markFailure("unexpected_exit", error)
                        state.recordDiagnostic("error", "process", "unexpected_exit", error)
                        return FeishuLongConnectStartResult(ok: false, status: "unexpected_exit", error: error)
                    }
            }
        }
        let error = this.processError("sidecar account ready timeout", proc)
        state.markFailure("ready_timeout", error)
        state.recordDiagnostic("error", "start", "ready_timeout", error)
        FeishuLongConnectStartResult(ok: false, status: "ready_timeout", error: error)
    }

    private func readLoop(expectedGeneration: Int64): Unit {
        while (this.activeGeneration(expectedGeneration)) {
            let proc = synchronized(this.lock) { this.process }
            match (proc) {
                case Some(p) =>
                    match (p.readLine(this.options.readTimeoutMs)) {
                        case Some(line) => let _ = this.handleLine(line)
                        case None =>
                            if (!p.isAlive()) {
                                this.markAllAccountsFailed("process", "unexpected_exit", this.processError("sidecar unexpected exit", p))
                                return
                            }
                    }
                case None => return
            }
        }
    }

    private func drainOne(): Bool {
        let proc = synchronized(this.lock) { this.process }
        match (proc) {
            case Some(p) =>
                match (p.readLine(this.options.readTimeoutMs)) {
                    case Some(line) =>
                        let _ = this.handleLine(line)
                        true
                    case None => false
                }
            case None => false
        }
    }

    private func handleLine(line: String): Bool {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            return false
        }
        let frame: JsonObject
        try {
            frame = JsonValue.fromStr(trimmed).asObject()
        } catch (_: Exception) {
            this.markAllAccountsFailed("protocol", "protocol_error", "sidecar non-json protocol line")
            return true
        }
        let frameType = this.readString(frame, "type")
        let accountId = this.normalizeAccountId(this.readString(frame, "accountId"))
        if (accountId.isEmpty()) {
            this.registryLastError = "sidecar frame missing accountId"
            return true
        }
        let state = this.accountState(accountId)
        if (state.isNone()) {
            this.registryLastError = "sidecar frame for unknown account: ${accountId}"
            return true
        }
        let accountState = state.getOrThrow()
        if (frameType == "ready") {
            let pid = synchronized(this.lock) {
                match (this.process) {
                    case Some(p) => p.pid()
                    case None => 0
                }
            }
            accountState.markReady(pid)
            accountState.recordDiagnostic("info", "ready", "ok", "")
            return true
        }
        if (frameType == "inbound") {
            accountState.markInbound()
            accountState.recordDiagnostic("info", "event.dispatch", "ok", this.readString(frame, "eventType"))
            this.emit(accountState, this.inboundRoot(frame, accountId))
            return true
        }
        if (frameType == "diagnostic") {
            let level = this.readString(frame, "level", fallback: "info")
            let phase = this.readString(frame, "phase", fallback: "diagnostic")
            let status = this.readString(frame, "status", fallback: "ok")
            let message = feishuSidecarTransportRedactSensitiveText(this.readString(frame, "message"))
            accountState.recordDiagnostic(level, phase, status, message)
            if (level == "error" || status == "failed") {
                let error = this.composeError(phase, status, message)
                accountState.markFailure(status, error)
                this.emit(accountState, this.diagnosticRoot(accountId, level, phase, status, message))
            }
            return true
        }
        if (frameType == "error") {
            let phase = this.readString(frame, "phase", fallback: "error")
            let status = this.readString(frame, "status", fallback: "error")
            let message = feishuSidecarTransportRedactSensitiveText(this.readString(frame, "message", fallback: this.readString(frame, "error")))
            let error = this.composeError(phase, status, message)
            accountState.markFailure(status, error)
            accountState.recordDiagnostic("error", phase, status, error)
            return true
        }
        if (frameType == "closed") {
            let reason = feishuSidecarTransportRedactSensitiveText(this.readString(frame, "reason", fallback: "closed"))
            let error = "sidecar closed: ${reason}"
            accountState.markFailure("closed", error)
            accountState.recordDiagnostic("error", "closed", "closed", error)
            this.emit(accountState, this.diagnosticRoot(accountId, "error", "closed", "closed", reason))
            return true
        }
        let error = "unknown sidecar frame type: ${frameType}"
        accountState.markFailure("protocol_error", error)
        accountState.recordDiagnostic("error", "protocol", "protocol_error", error)
        true
    }

    private func recordUnexpectedExitIfNeeded(): Unit {
        let proc = synchronized(this.lock) { this.process }
        if (let Some(p) <- proc) {
            if (!p.isAlive()) {
                this.markAllAccountsFailed("process", "unexpected_exit", this.processError("sidecar unexpected exit", p))
            }
        }
    }

    private func markAllAccountsFailed(phase: String, status: String, message: String): Unit {
        let states = ArrayList<FeishuSidecarSupervisorAccountState>()
        var proc: Option<FeishuSidecarProtocolProcess> = None
        synchronized(this.lock) {
            this.registryLastError = message
            for ((_, state) in this.accounts) {
                states.add(state)
            }
            proc = this.process
            this.process = None<FeishuSidecarProtocolProcess>
            this.generation += 1
        }
        if (let Some(p) <- proc) {
            if (p.isAlive()) {
                p.terminate(true)
            }
        }
        for (state in states) {
            state.markFailure(status, message)
            state.recordDiagnostic("error", phase, status, message)
            this.emit(state, this.diagnosticRoot(state.accountId, "error", phase, status, message))
        }
    }

    private func accountState(accountId: String): Option<FeishuSidecarSupervisorAccountState> {
        synchronized(this.lock) {
            if (this.accounts.contains(accountId)) {
                Some(this.accounts[accountId])
            } else {
                None<FeishuSidecarSupervisorAccountState>
            }
        }
    }

    private func emit(state: FeishuSidecarSupervisorAccountState, root: JsonObject): Unit {
        match (state.handlerSnapshot()) {
            case Some(h) => h(root)
            case None => ()
        }
    }

    private func initAccountFrame(spec: FeishuLongConnectStartSpec, accountId: String): JsonObject {
        let out = JsonObject()
        out.put("type", JsonString("initAccount"))
        out.put("accountId", JsonString(accountId))
        out.put("appId", JsonString(spec.appId))
        out.put("appSecret", JsonString(spec.appSecret))
        out.put("domain", JsonString(spec.domain))
        out.put("verificationToken", JsonString(spec.verificationToken))
        out.put("encryptKey", JsonString(spec.encryptKey))
        out.put("mode", JsonString("websocket"))
        out.put("runtimeRoot", JsonString(this.options.runtimeRoot))
        out
    }

    private func closeAccountFrame(accountId: String): JsonObject {
        let out = JsonObject()
        out.put("type", JsonString("closeAccount"))
        out.put("accountId", JsonString(accountId))
        out
    }

    private func inboundRoot(frame: JsonObject, accountId: String): JsonObject {
        let eventType = this.readString(frame, "eventType")
        let event = match (frame.get("event")) {
            case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
            case None => JsonObject()
        }
        let header = JsonObject()
        header.put("event_type", JsonString(eventType))
        header.put("account_id", JsonString(accountId))
        let root = JsonObject()
        root.put("header", header)
        root.put("event", event)
        root
    }

    private func diagnosticRoot(accountId: String, level: String, phase: String, status: String, message: String): JsonObject {
        let header = JsonObject()
        header.put("event_type", JsonString("metis.feishu.sidecar.diagnostic"))
        header.put("account_id", JsonString(accountId))
        let sidecar = JsonObject()
        sidecar.put("level", JsonString(level))
        sidecar.put("phase", JsonString(phase))
        sidecar.put("status", JsonString(status))
        sidecar.put("message", JsonString(message))
        let root = JsonObject()
        root.put("header", header)
        root.put("sidecar", sidecar)
        root
    }

    private func processError(prefix: String, proc: FeishuSidecarProtocolProcess): String {
        let parts = ArrayList<String>()
        parts.add(feishuSidecarTransportRedactSensitiveText(prefix))
        let stdout = feishuSidecarTransportRedactSensitiveText(proc.stdoutSummary())
        if (!stdout.isEmpty()) {
            parts.add("stdout=${stdout}")
        }
        let stderr = feishuSidecarTransportRedactSensitiveText(proc.stderrSummary())
        if (!stderr.isEmpty()) {
            parts.add("stderr=${stderr}")
        }
        String.join(parts.toArray(), delimiter: "; ")
    }

    private func composeError(phase: String, status: String, message: String): String {
        if (message.trimAscii().isEmpty()) {
            return "${phase}: ${status}"
        }
        "${phase}: ${status}: ${message.trimAscii()}"
    }

    private func readString(obj: JsonObject, key: String, fallback!: String = ""): String {
        match (obj.get(key)) {
            case Some(value) =>
                try {
                    let text = value.asString().getValue().trimAscii()
                    if (text.isEmpty()) { fallback } else { text }
                } catch (_: Exception) {
                    fallback
                }
            case None => fallback
        }
    }

    private func normalizeAccountId(raw: String): String {
        let trimmed = raw.trimAscii()
        if (trimmed.isEmpty()) { "default" } else { trimmed }
    }

    private func compactJsonLine(raw: String): String {
        let out = StringBuilder()
        var inString = false
        var escaped = false
        for (ch in raw.toRuneArray()) {
            if (escaped) {
                out.append(ch)
                escaped = false
                continue
            }
            if (inString && ch == r'\\') {
                out.append(ch)
                escaped = true
                continue
            }
            if (ch == r'"') {
                out.append(ch)
                inString = !inString
                continue
            }
            if (!inString && (ch == r' ' || ch == r'\n' || ch == r'\r' || ch == r'\t')) {
                continue
            }
            out.append(ch)
        }
        out.toString()
    }

    private func activeGeneration(expected: Int64): Bool {
        synchronized(this.lock) {
            this.generation == expected && this.process.isSome()
        }
    }
}

public class FeishuSidecarSupervisorTransport <: FeishuLongConnectTransport {
    private let registry: FeishuSidecarSupervisorRegistry
    private let lock = Mutex()
    private var accountId = ""

    public init(registry!: FeishuSidecarSupervisorRegistry) {
        this.registry = registry
    }

    public func start(spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        synchronized(this.lock) {
            this.accountId = if (spec.accountId.trimAscii().isEmpty()) { "default" } else { spec.accountId.trimAscii() }
        }
        this.registry.startAccount(spec, eventHandler)
    }

    public func stop(): Unit {
        let id = synchronized(this.lock) { this.accountId }
        if (!id.trimAscii().isEmpty()) {
            this.registry.stopAccount(id)
        }
    }

    public func healthSnapshot(): FeishuSidecarHealthSnapshot {
        this.registry.healthSnapshot(synchronized(this.lock) { this.accountId })
    }

    public func diagnosticsSnapshot(): Array<FeishuSidecarDiagnosticSnapshot> {
        this.registry.diagnosticsSnapshot(synchronized(this.lock) { this.accountId })
    }

    public func debugDrainAvailableForTest(): Unit {
        this.registry.debugDrainAvailableForTest()
    }
}

public func feishuSidecarDefaultWorkingDirectory(): String {
    CliConfig.cwd.toString()
}

public func feishuSidecarDefaultRuntimeRoot(): String {
    CliConfig.cwd.join("tools").join("feishu-sidecar").toString()
}

private func feishuSidecarNormalizeRuntimeRoot(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        feishuSidecarDefaultRuntimeRoot()
    } else {
        trimmed
    }
}

private func feishuSidecarNormalizeWorkingDirectory(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        feishuSidecarDefaultWorkingDirectory()
    } else {
        trimmed
    }
}

private func feishuSidecarNormalizeEnv(raw: Array<(String, String)>, runtimeRoot: String): Array<(String, String)> {
    let out = ArrayList<(String, String)>()
    var hasRuntimeRoot = false
    for (entry in raw) {
        let key = entry[0].trimAscii()
        if (key.isEmpty()) {
            continue
        }
        let value = entry[1].trimAscii()
        if (key == "METIS_FEISHU_SIDECAR_RUNTIME_ROOT") {
            hasRuntimeRoot = true
        }
        out.add((key, value))
    }
    if (!hasRuntimeRoot) {
        out.add(("METIS_FEISHU_SIDECAR_RUNTIME_ROOT", runtimeRoot))
    }
    out.toArray()
}

private func feishuSidecarProcessEnvironment(overrides: Array<(String, String)>): HashMap<String, String> {
    let env = HashMap<String, String>()
    for ((key, value) in getVariables()) {
        env[key] = value
    }
    for (entry in overrides) {
        env[entry[0]] = entry[1]
    }
    env
}

private func feishuSidecarSummarizeText(raw: String): String {
    let text = raw.trimAscii()
    if (text.size <= 512) {
        return text
    }
    "${text[0..512]}..."
}

private func feishuSidecarTransportRedactSensitiveText(raw: String): String {
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return ""
    }
    if (text.startsWith("{") || text.startsWith("[")) {
        return "Feishu sidecar returned structured error."
    }
    var redacted = text
    for (token in text.split(" ")) {
        if (feishuSidecarTransportSensitiveToken(token)) {
            redacted = redacted.replace(token, "[redacted]")
        }
    }
    if (redacted != text) {
        return redacted
    }
    text
}

private func feishuSidecarTransportSensitiveToken(raw: String): Bool {
    let text = raw.trimAscii()
    if (text.isEmpty()) {
        return false
    }
    let lower = text.toAsciiLower()
    lower.contains("authorization:") ||
        lower.contains("\"authorization\"") ||
        lower.contains("bearer ") ||
        lower.contains("access_token") ||
        lower.contains("refresh_token") ||
        lower.contains("tenant_secret") ||
        lower.contains("tenant secret") ||
        lower.contains("appsecret") ||
        lower.contains("app_secret") ||
        lower.contains("client_secret") ||
        lower.contains("secret") ||
        lower.contains("token=") ||
        lower.contains("password")
}

public class FeishuWebhookLongConnectTransport <: FeishuLongConnectTransport {
    public init() {}

    public func start(_spec: FeishuLongConnectStartSpec, _eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        FeishuLongConnectStartResult(status: "webhook_receive_mode", error: "Feishu receiveMode=webhook does not start long-connect transport")
    }

    public func stop(): Unit {}
}
