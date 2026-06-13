package metis.core.model

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.fs.Path
import std.io.*
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class CodexAppServerProtocolException <: Exception {
    public let code: Int64
    public let data: JsonObject

    public init(message: String, code!: Int64 = 0, data!: JsonObject = JsonObject()) {
        super(message)
        this.code = code
        this.data = data
    }
}

public class CodexAppServerParsedLine {
    public let kind: String
    public let message: JsonObject
    public let diagnostic: String

    public init(kind: String, message!: JsonObject = JsonObject(), diagnostic!: String = "") {
        this.kind = kind.trimAscii()
        this.message = message
        this.diagnostic = diagnostic.trimAscii()
    }
}

public interface CodexAppServerTransport {
    func start(): Unit
    func request(method: String, params: JsonObject, timeoutMs: Int64): JsonObject
    func notify(method: String, params: JsonObject): Unit
    func respond(id: Int64, result: JsonObject): Unit
    func respondError(id: Int64, code: Int64, message: String): Unit
    func takeServerRequest(timeoutMs: Int64): Option<JsonObject>
    func takeNotification(timeoutMs: Int64): Option<JsonObject>
    func isAlive(): Bool
    func diagnostics(): Array<String>
    func close(): Unit
}

public class CodexAppServerClient <: CodexAppServerTransport {
    private let codexBin: String
    private let extraArgs: Array<String>
    private let env: HashMap<String, String>
    private let cwd: Option<String>
    private let responses = CodexAppServerJsonQueue()
    private let serverRequests = CodexAppServerJsonQueue()
    private let notifications = CodexAppServerJsonQueue()
    private let diagnosticsBuffer = CodexAppServerStringRing(32)
    private var process: Option<SubProcess> = None<SubProcess>
    private var writer: Option<StringWriter<OutputStream>> = None<StringWriter<OutputStream>>
    private var stdoutFuture: Option<Future<Unit>> = None<Future<Unit>>
    private var stderrFuture: Option<Future<Unit>> = None<Future<Unit>>
    private var nextId: Int64 = 1
    private let lock = Mutex()

    public init(
        codexBin!: String = "codex",
        extraArgs!: Array<String> = [],
        env!: HashMap<String, String> = codexAppServerBuildEnvironment(),
        cwd!: Option<String> = None<String>
    ) {
        this.codexBin = if (codexBin.trimAscii().isEmpty()) { "codex" } else { codexBin.trimAscii() }
        this.extraArgs = extraArgs
        this.env = env
        this.cwd = cwd
    }

    public func start(): Unit {
        synchronized(this.lock) {
            match (this.process) {
                case Some(proc) =>
                    if (proc.isAlive()) {
                        return
                    }
                case None => ()
            }
            let spec = codexAppServerBuildLaunchSpec(codexBin: this.codexBin, extraArgs: this.extraArgs)
            let proc = try {
                launch(
                    spec.command,
                    spec.args,
                    stdIn: ProcessRedirect.Pipe,
                    stdOut: ProcessRedirect.Pipe,
                    stdErr: ProcessRedirect.Pipe,
                    workingDirectory: this.cwd.map({ value => Path(value) }),
                    environment: Some(this.env)
                )
            } catch (e: Exception) {
                throw CodexAppServerProtocolException("Failed to start codex app-server: ${codexAppServerRedactDiagnostic(e.message)}", code: -32000)
            }
            this.process = Some(proc)
            this.writer = Some(StringWriter(proc.stdInPipe))
            let stdoutReader = StringReader<InputStream>(proc.stdOutPipe)
            let stderrReader = StringReader<InputStream>(proc.stdErrPipe)
            this.stdoutFuture = Some(spawn { this.readStdout(stdoutReader) })
            this.stderrFuture = Some(spawn { this.readStderr(stderrReader) })
        }
    }

    public func request(method: String, params: JsonObject, timeoutMs: Int64): JsonObject {
        this.start()
        let requestId = synchronized(this.lock) {
            let id = this.nextId
            this.nextId += 1
            id
        }
        let obj = JsonObject()
        obj.put("id", JsonInt(requestId))
        obj.put("method", JsonString(method))
        obj.put("params", params)
        this.send(obj)
        let response = this.responses.readMatchingId(requestId, timeoutMs)
        match (response) {
            case Some(resp) =>
                match (resp.get("error")) {
                    case Some(value) =>
                        let err = try { value.asObject() } catch (_: Exception) { JsonObject() }
                        let code = codexClientJsonInt(err, "code", -32000)
                        let message = codexClientJsonString(err, "message")
                        throw CodexAppServerProtocolException(if (message.isEmpty()) { "codex app-server request failed" } else { message }, code: code, data: err)
                    case None => ()
                }
                match (resp.get("result")) {
                    case Some(value) =>
                        try { return value.asObject() } catch (_: Exception) {
                            let wrapper = JsonObject()
                            wrapper.put("value", value)
                            return wrapper
                        }
                    case None => return JsonObject()
                }
            case None =>
                let message = codexAppServerTimeoutMessage(method, this.diagnosticsWithGrace(2000))
                try { this.close() } catch (_: Exception) { () }
                throw CodexAppServerProtocolException(message, code: -32001)
        }
    }

    public func notify(method: String, params: JsonObject): Unit {
        this.start()
        let obj = JsonObject()
        obj.put("method", JsonString(method))
        obj.put("params", params)
        this.send(obj)
    }

    public func respond(id: Int64, result: JsonObject): Unit {
        let obj = JsonObject()
        obj.put("id", JsonInt(id))
        obj.put("result", result)
        this.send(obj)
    }

    public func respondError(id: Int64, code: Int64, message: String): Unit {
        let error = JsonObject()
        error.put("code", JsonInt(code))
        error.put("message", JsonString(message))
        let obj = JsonObject()
        obj.put("id", JsonInt(id))
        obj.put("error", error)
        this.send(obj)
    }

    public func takeServerRequest(timeoutMs: Int64): Option<JsonObject> {
        this.serverRequests.read(timeoutMs)
    }

    public func takeNotification(timeoutMs: Int64): Option<JsonObject> {
        this.notifications.read(timeoutMs)
    }

    public func isAlive(): Bool {
        synchronized(this.lock) {
            match (this.process) {
                case Some(proc) => proc.isAlive()
                case None => false
            }
        }
    }

    public func diagnostics(): Array<String> {
        this.diagnosticsBuffer.snapshot()
    }

    private func diagnosticsWithGrace(waitMs: Int64): Array<String> {
        var items = this.diagnostics()
        if (!items.isEmpty() || waitMs <= 0) {
            return items
        }
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() - started < waitMs) {
            sleep(Duration.millisecond * 10)
            items = this.diagnostics()
            if (!items.isEmpty()) {
                return items
            }
        }
        items
    }

    public func close(): Unit {
        var processToStop = None<SubProcess>
        var rootPid: Int64 = 0
        synchronized(this.lock) {
            try { this.stdoutFuture?.cancel() } catch (_: Exception) { () }
            try { this.stderrFuture?.cancel() } catch (_: Exception) { () }
            match (this.process) {
                case Some(proc) =>
                    processToStop = Some(proc)
                    rootPid = proc.pid
                case None => ()
            }
            this.process = None<SubProcess>
            this.writer = None<StringWriter<OutputStream>>
        }
        match (processToStop) {
            case Some(proc) => codexAppServerTerminateProcessTree(proc, rootPid)
            case None => ()
        }
        this.responses.close()
        this.serverRequests.close()
        this.notifications.close()
    }

    private func send(obj: JsonObject): Unit {
        let frame = codexAppServerFrame(obj)
        synchronized(this.lock) {
            match (this.writer) {
                case Some(w) =>
                    try {
                        w.write(frame)
                        w.flush()
                    } catch (e: Exception) {
                        throw CodexAppServerProtocolException("Failed to write codex app-server stdin: ${codexAppServerRedactDiagnostic(e.message)}", code: -32002)
                    }
                case None =>
                    throw CodexAppServerProtocolException("codex app-server is not started", code: -32003)
            }
        }
    }

    private func readStdout(reader: StringReader<InputStream>): Unit {
        while (true) {
            if (Thread.currentThread.hasPendingCancellation) {
                break
            }
            let line = try { reader.readln() ?? "" } catch (_: Exception) { "" }
            if (line.isEmpty()) {
                if (!this.isAlive()) {
                    break
                }
                sleep(Duration.millisecond * 10)
                continue
            }
            let parsed = codexAppServerParseStdoutLine(line)
            match (parsed.kind) {
                case "response" => this.responses.append(parsed.message)
                case "server_request" => this.serverRequests.append(parsed.message)
                case "notification" => this.notifications.append(parsed.message)
                case "diagnostic" => this.diagnosticsBuffer.append(parsed.diagnostic)
                case _ => ()
            }
        }
        this.responses.close()
        this.serverRequests.close()
        this.notifications.close()
    }

    private func readStderr(reader: StringReader<InputStream>): Unit {
        while (true) {
            if (Thread.currentThread.hasPendingCancellation) {
                break
            }
            let line = try { reader.readln() ?? "" } catch (_: Exception) { "" }
            if (line.isEmpty()) {
                if (!this.isAlive()) {
                    break
                }
                sleep(Duration.millisecond * 10)
                continue
            }
            this.diagnosticsBuffer.append(codexAppServerRedactDiagnostic(line))
        }
    }
}

public func codexAppServerFrame(obj: JsonObject): String {
    codexAppServerCompactJsonLine(obj.toJsonString()) + "\n"
}

private func codexAppServerCompactJsonLine(raw: String): String {
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

public func codexAppServerParseStdoutLine(line: String): CodexAppServerParsedLine {
    let trimmed = line.trimAscii()
    if (trimmed.isEmpty()) {
        return CodexAppServerParsedLine("empty")
    }
    let value = try {
        JsonValue.fromStr(trimmed)
    } catch (_: Exception) {
        return CodexAppServerParsedLine("diagnostic", diagnostic: codexAppServerRedactDiagnostic(trimmed))
    }
    let obj = try {
        value.asObject()
    } catch (_: Exception) {
        return CodexAppServerParsedLine("diagnostic", diagnostic: codexAppServerRedactDiagnostic(trimmed))
    }
    if (obj.containsKey("id") && (obj.containsKey("result") || obj.containsKey("error"))) {
        return CodexAppServerParsedLine("response", message: obj)
    }
    if (obj.containsKey("id") && obj.containsKey("method")) {
        return CodexAppServerParsedLine("server_request", message: obj)
    }
    if (obj.containsKey("method")) {
        return CodexAppServerParsedLine("notification", message: obj)
    }
    CodexAppServerParsedLine("diagnostic", diagnostic: codexAppServerRedactDiagnostic(trimmed))
}

private class CodexAppServerJsonQueue {
    private let lock = Mutex()
    private let condition: Condition
    private let items = ArrayList<JsonObject>()
    private var closed = false

    public init() {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    public func append(item: JsonObject): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
            this.items.add(item)
            this.condition.notifyAll()
        }
    }

    public func read(timeoutMs: Int64): Option<JsonObject> {
        let effective = if (timeoutMs > 0) { timeoutMs } else { 1 }
        synchronized(this.lock) {
            if (this.items.isEmpty() && !this.closed) {
                let _ = this.condition.waitUntil({ => !this.items.isEmpty() || this.closed }, timeout: Duration.millisecond * effective)
            }
            if (this.items.isEmpty()) {
                return None<JsonObject>
            }
            let item = this.items[0]
            this.items.remove(at: 0)
            Some(item)
        }
    }

    public func readMatchingId(id: Int64, timeoutMs: Int64): Option<JsonObject> {
        let effective = if (timeoutMs > 0) { timeoutMs } else { 30000 }
        synchronized(this.lock) {
            let _ = this.condition.waitUntil({ => this.closed || this.findIndex(id) >= 0 }, timeout: Duration.millisecond * effective)
            let idx = this.findIndex(id)
            if (idx < 0) {
                return None<JsonObject>
            }
            let item = this.items[idx]
            this.items.remove(at: idx)
            Some(item)
        }
    }

    public func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.condition.notifyAll()
        }
    }

    private func findIndex(id: Int64): Int64 {
        for (i in 0..this.items.size) {
            if (codexClientJsonInt(this.items[i], "id", -1) == id) {
                return i
            }
        }
        -1
    }
}

private class CodexAppServerStringRing {
    private let lock = Mutex()
    private let maxItems: Int64
    private let items = ArrayList<String>()

    public init(maxItems: Int64) {
        this.maxItems = if (maxItems > 0) { maxItems } else { 32 }
    }

    public func append(line: String): Unit {
        let text = codexAppServerRedactDiagnostic(line)
        if (text.trimAscii().isEmpty()) {
            return
        }
        synchronized(this.lock) {
            while (this.items.size >= this.maxItems) {
                this.items.remove(at: 0)
            }
            this.items.add(text)
        }
    }

    public func snapshot(): Array<String> {
        synchronized(this.lock) {
            this.items.toArray()
        }
    }
}

private func codexClientJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asString().getValue().trimAscii() } catch (_: Exception) { () }
        case None => ()
    }
    ""
}

private func codexClientJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asInt().getValue() } catch (_: Exception) { () }
            try { return Int64.parse(value.asString().getValue().trimAscii()) } catch (_: Exception) { () }
        case None => ()
    }
    fallback
}

private func codexAppServerTimeoutMessage(method: String, diagnostics: Array<String>): String {
    let base = "Timed out waiting for codex app-server response to ${method}"
    let diag = codexAppServerJoinDiagnostics(diagnostics)
    if (diag.isEmpty()) {
        return base
    }
    "${base}; diagnostics: ${diag}"
}

private func codexAppServerJoinDiagnostics(diagnostics: Array<String>): String {
    let parts = ArrayList<String>()
    for (line in diagnostics) {
        let text = codexAppServerRedactDiagnostic(line).trimAscii()
        if (!text.isEmpty()) {
            parts.add(text)
        }
    }
    if (parts.isEmpty()) {
        return ""
    }
    String.join(parts.toArray(), delimiter: " | ")
}

private func codexAppServerTerminateProcessTree(proc: SubProcess, rootPid: Int64): Unit {
    let descendants = codexAppServerCollectDescendantPids(rootPid)
    for (pid in descendants) {
        codexAppServerSignalPid(pid, "-TERM")
    }
    try { proc.terminate(force: false) } catch (_: Exception) { () }
    if (!codexAppServerWaitProcessExit(proc, 250)) {
        for (pid in descendants) {
            codexAppServerSignalPid(pid, "-KILL")
        }
        try { proc.terminate(force: true) } catch (_: Exception) { () }
        let _ = codexAppServerWaitProcessExit(proc, 250)
    } else {
        for (pid in descendants) {
            if (codexAppServerPidAlive(pid)) {
                codexAppServerSignalPid(pid, "-KILL")
            }
        }
    }
}

private func codexAppServerWaitProcessExit(proc: SubProcess, timeoutMs: Int64): Bool {
    let effective = if (timeoutMs > 0) { timeoutMs } else { 250 }
    try {
        let _ = proc.wait(timeout: Some(Duration.millisecond * effective))
        return true
    } catch (_: Exception) {
        return !proc.isAlive()
    }
}

private func codexAppServerCollectDescendantPids(rootPid: Int64): Array<Int64> {
    let out = ArrayList<Int64>()
    codexAppServerCollectDescendantPidsInto(rootPid, out, 0)
    out.toArray()
}

private func codexAppServerCollectDescendantPidsInto(pid: Int64, out: ArrayList<Int64>, depth: Int64): Unit {
    if (pid <= 0 || depth >= 8) {
        return
    }
    for (child in codexAppServerChildPids(pid)) {
        if (child <= 0 || codexAppServerPidListContains(out, child)) {
            continue
        }
        out.add(child)
        codexAppServerCollectDescendantPidsInto(child, out, depth + 1)
    }
}

private func codexAppServerChildPids(pid: Int64): Array<Int64> {
    if (pid <= 0) {
        return []
    }
    let (exitCode, stdoutBytes, _) = try {
        executeWithOutput("pgrep", ["-P", "${pid}"])
    } catch (_: Exception) {
        return []
    }
    if (exitCode != 0) {
        return []
    }
    let out = ArrayList<Int64>()
    let text = try { String.fromUtf8(stdoutBytes) } catch (_: Exception) { "" }
    for (line in text.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            continue
        }
        try {
            let child = Int64.parse(trimmed)
            if (child > 0) {
                out.add(child)
            }
        } catch (_: Exception) {
            ()
        }
    }
    out.toArray()
}

private func codexAppServerPidListContains(items: ArrayList<Int64>, pid: Int64): Bool {
    for (item in items) {
        if (item == pid) {
            return true
        }
    }
    false
}

private func codexAppServerSignalPid(pid: Int64, signal: String): Unit {
    if (pid <= 0) {
        return
    }
    try {
        let _ = executeWithOutput("kill", [signal, "${pid}"])
    } catch (_: Exception) {
        ()
    }
}

private func codexAppServerPidAlive(pid: Int64): Bool {
    if (pid <= 0) {
        return false
    }
    let (exitCode, _, _) = try {
        executeWithOutput("kill", ["-0", "${pid}"])
    } catch (_: Exception) {
        return false
    }
    exitCode == 0
}
