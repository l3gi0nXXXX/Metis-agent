package metis.gateway.channels.feishu

import metis.core.config.CliConfig

import std.collection.{ArrayList, HashMap}
import std.env.getVariables
import std.fs.Path
import std.io.*
import std.process.*
import std.sync.Mutex
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
        args!: Array<String> = ["scripts/feishu-openclaw-sidecar.mjs"],
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

public class FeishuSidecarStdioProcess <: FeishuSidecarProtocolProcess {
    private let process: SubProcess
    private let reader: StringReader<InputStream>
    private let writer: StringWriter<OutputStream>
    private let outputLock = Mutex()
    private let stdoutLines = ArrayList<String>()
    private var stderrText = ""
    private var closed = false

    public init(process: SubProcess) {
        this.process = process
        this.reader = StringReader<InputStream>(process.stdOutPipe)
        this.writer = StringWriter(process.stdInPipe)
        spawn {
            let stderrReader = StringReader<InputStream>(process.stdErrPipe)
            let text = try { stderrReader.readToEnd() } catch (_: Exception) { "" }
            synchronized(this.outputLock) {
                this.stderrText = text
            }
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
        if (this.closed) {
            return None<String>
        }
        let effectiveTimeoutMs = if (timeoutMs > 0) { timeoutMs } else { 250 }
        let fut = spawn {
            try { this.reader.readln() } catch (_: Exception) { None<String> }
        }
        let watchdog = spawn {
            sleep(Duration.millisecond * effectiveTimeoutMs)
            fut.cancel()
        }
        try {
            let line = fut.get()
            watchdog.cancel()
            match (line) {
                case Some(value) => this.rememberStdout(value)
                case None => ()
            }
            line
        } catch (_: Exception) {
            try { watchdog.cancel() } catch (_e: Exception) { () }
            None<String>
        }
    }

    public func isAlive(): Bool {
        !this.closed && this.process.isAlive()
    }

    public func wait(timeoutMs: Int64): Option<Int64> {
        try {
            Some(this.process.wait(timeout: Some(Duration.millisecond * if (timeoutMs > 0) { timeoutMs } else { 500 })))
        } catch (_: Exception) {
            None<Int64>
        }
    }

    public func terminate(force: Bool): Unit {
        this.closed = true
        try { this.process.terminate(force: force) } catch (_: Exception) { () }
    }

    public func stdoutSummary(): String {
        synchronized(this.outputLock) {
            feishuSidecarSummarizeText(String.join(this.stdoutLines.toArray(), delimiter: "\n"))
        }
    }

    public func stderrSummary(): String {
        synchronized(this.outputLock) {
            feishuSidecarSummarizeText(this.stderrText)
        }
    }

    private func rememberStdout(line: String): Unit {
        synchronized(this.outputLock) {
            this.stdoutLines.add(line)
            while (this.stdoutLines.size > 16) {
                this.stdoutLines.remove(at: 0)
            }
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
                    break
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
                this.setLastError(this.composeError(phase, status, message))
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

public func feishuSidecarDefaultWorkingDirectory(): String {
    CliConfig.cwd.toString()
}

public func feishuSidecarDefaultRuntimeRoot(): String {
    CliConfig.cwd.join("tools").join("feishu-openclaw-sidecar").toString()
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
