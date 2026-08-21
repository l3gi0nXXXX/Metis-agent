package metis.core.model

import metis.process.{ManagedStdioEvent, ManagedStdioOwnerSpec, managedStdioBroker}

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.sync.*
import std.time.*
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

private const CODEX_APP_SERVER_TIMEOUT_DIAGNOSTIC_GRACE_MS: Int64 = 3000
private const CODEX_APP_SERVER_EVENT_POLL_MS: Int64 = 50
private const CODEX_APP_SERVER_EVENT_JOIN_MS: Int64 = 1000

private let codexAppServerOwnerIdLock = Mutex()
private var codexAppServerOwnerIdSequence: Int64 = 0

private func codexAppServerNextOwnerId(): String {
    synchronized(codexAppServerOwnerIdLock) {
        codexAppServerOwnerIdSequence += 1
        "codex-app-server-${DateTime.now().toUnixTimeStamp().toMilliseconds()}-${codexAppServerOwnerIdSequence}"
    }
}

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
    private let ownerId = codexAppServerNextOwnerId()
    private var ownerGeneration: Int64 = 0
    private var ownerPid: Int64 = 0
    private var eventFuture: Option<Future<Unit>> = None<Future<Unit>>
    private var ownerRunning = false
    private var ownerTerminal = false
    private var closing = false
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
            if (this.ownerRunning && !this.ownerTerminal && !this.closing) {
                return
            }
            if (this.closing || this.ownerTerminal || this.eventFuture.isSome()) {
                throw CodexAppServerProtocolException("codex app-server client is closed", code: -32003)
            }
            let spec = codexAppServerBuildLaunchSpec(codexBin: this.codexBin, extraArgs: this.extraArgs)
            let environment = ArrayList<(String, String)>()
            for ((key, value) in this.env) {
                environment.add((key, value))
            }
            let started = managedStdioBroker().startOwner(
                ManagedStdioOwnerSpec(
                    this.ownerId,
                    spec.command,
                    args: spec.args,
                    workingDirectory: this.cwd,
                    environment: environment.toArray(),
                    stdinMode: "line",
                    outputMode: "line"
                )
            )
            if (!started.ok) {
                throw CodexAppServerProtocolException("Failed to start codex app-server: ${codexAppServerRedactDiagnostic(started.status)}", code: -32000)
            }
            this.ownerGeneration = started.generation
            this.ownerPid = started.pid
            this.ownerRunning = true
            this.ownerTerminal = false
            let generation = started.generation
            this.eventFuture = Some(spawn { this.pumpOwnerEvents(generation) })
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
                let diagnosticsBeforeClose = this.diagnosticsWithGrace(CODEX_APP_SERVER_TIMEOUT_DIAGNOSTIC_GRACE_MS)
                try { this.closeAfterTimeoutForDiagnostics() } catch (_: Exception) { () }
                let diagnosticsAfterClose = codexAppServerMergeDiagnostics(diagnosticsBeforeClose, this.diagnostics())
                let message = codexAppServerTimeoutMessage(method, diagnosticsAfterClose)
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
            this.ownerRunning && !this.ownerTerminal && !this.closing
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
        this.closeInternal(120)
    }

    private func closeAfterTimeoutForDiagnostics(): Unit {
        this.closeInternal(CODEX_APP_SERVER_TIMEOUT_DIAGNOSTIC_GRACE_MS)
    }

    private func closeInternal(diagnosticTailMs: Int64): Unit {
        var shouldStop = false
        var eventToJoin = None<Future<Unit>>
        synchronized(this.lock) {
            if (this.closing && this.eventFuture.isNone()) { return }
            this.closing = true
            shouldStop = this.ownerRunning && !this.ownerTerminal
            eventToJoin = this.eventFuture
        }
        if (shouldStop) {
            let stopped = managedStdioBroker().stopOwner(this.ownerId, timeoutMs: max(1000, diagnosticTailMs))
            if (!stopped.ok) {
                this.diagnosticsBuffer.append(stopped.status)
            }
        }
        this.waitForReaderDiagnosticTail(diagnosticTailMs)
        synchronized(this.lock) {
            this.ownerRunning = false
            this.ownerTerminal = true
            this.ownerPid = 0
        }
        var eventJoined = false
        match (eventToJoin) {
            case Some(future) =>
                try {
                    future.get(Duration.millisecond * CODEX_APP_SERVER_EVENT_JOIN_MS)
                    eventJoined = true
                } catch (_: Exception) { () }
            case None => eventJoined = true
        }
        synchronized(this.lock) {
            if (eventJoined) {
                this.eventFuture = None<Future<Unit>>
            }
        }
        this.responses.close()
        this.serverRequests.close()
        this.notifications.close()
    }

    private func waitForReaderDiagnosticTail(waitMs: Int64): Unit {
        if (waitMs <= 0) {
            return
        }
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var previousCount: Int64 = -1
        var stableTicks: Int64 = 0
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() - started < waitMs) {
            sleep(Duration.millisecond * 20)
            let count = this.diagnostics().size
            if (count > 0 && count == previousCount) {
                stableTicks += 1
                if (stableTicks >= 2) {
                    return
                }
            } else {
                previousCount = count
                stableTicks = 0
            }
        }
    }

    private func send(obj: JsonObject): Unit {
        let generation = synchronized(this.lock) {
            if (!this.ownerRunning || this.ownerTerminal || this.closing) {
                throw CodexAppServerProtocolException("codex app-server is not started", code: -32003)
            }
            this.ownerGeneration
        }
        let written = managedStdioBroker().writeOwnerLine(this.ownerId, codexAppServerFrame(obj).trimAscii())
        if (!written.ok || written.generation != generation) {
            throw CodexAppServerProtocolException(
                "Failed to write codex app-server stdin: ${codexAppServerRedactDiagnostic(written.status)}",
                code: -32002
            )
        }
    }

    private func pumpOwnerEvents(generation: Int64): Unit {
        while (true) {
            let shouldExit = synchronized(this.lock) {
                this.ownerGeneration != generation || this.ownerTerminal
            }
            if (shouldExit) { break }
            match (managedStdioBroker().readOwnerLine(this.ownerId, timeoutMs: CODEX_APP_SERVER_EVENT_POLL_MS)) {
                case Some(event) => if (this.handleOwnerEvent(event, generation)) { break }
                case None => ()
            }
        }
        this.responses.close()
        this.serverRequests.close()
        this.notifications.close()
    }

    private func handleOwnerEvent(event: ManagedStdioEvent, generation: Int64): Bool {
        if (event.eventType == "owner.stdout") {
            let parsed = codexAppServerParseStdoutLine(event.text)
            match (parsed.kind) {
                case "response" => this.responses.append(parsed.message)
                case "server_request" => this.serverRequests.append(parsed.message)
                case "notification" => this.notifications.append(parsed.message)
                case "diagnostic" => this.diagnosticsBuffer.append(parsed.diagnostic)
                case _ => ()
            }
            return false
        }
        if (event.eventType == "owner.stderr") {
            this.diagnosticsBuffer.append(codexAppServerRedactTransportDiagnostic(event.text))
            return false
        }
        if (event.eventType == "owner.error" || event.eventType == "owner.timeout") {
            this.diagnosticsBuffer.append(if (event.status.isEmpty()) { "codex_app_server_transport_error" } else { event.status })
        }
        synchronized(this.lock) {
            if (this.ownerGeneration == generation) {
                this.ownerRunning = false
                this.ownerTerminal = true
                this.ownerPid = 0
            }
        }
        true
    }
}

private func codexAppServerRedactTransportDiagnostic(raw: String): String {
    let redacted = codexAppServerRedactDiagnostic(raw)
    let out = ArrayList<String>()
    for (part in redacted.split(" ")) {
        let lower = part.toAsciiLower()
        if (lower.contains("/users/") || lower.contains("/home/") || lower.contains("/private/") || lower.contains("c:\\users\\")) {
            out.add("[redacted-path]")
        } else {
            out.add(part)
        }
    }
    String.join(out.toArray(), delimiter: " ")
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
        return CodexAppServerParsedLine(
            "diagnostic",
            diagnostic: if (trimmed.startsWith("{") || trimmed.startsWith("[")) { "malformed_json" } else { codexAppServerRedactDiagnostic(trimmed) }
        )
    }
    let obj = try {
        value.asObject()
    } catch (_: Exception) {
        return CodexAppServerParsedLine("diagnostic", diagnostic: "malformed_json")
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

private func codexAppServerMergeDiagnostics(first: Array<String>, second: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (line in first) {
        let text = codexAppServerRedactDiagnostic(line).trimAscii()
        if (!text.isEmpty() && !out.contains(text)) {
            out.add(text)
        }
    }
    for (line in second) {
        let text = codexAppServerRedactDiagnostic(line).trimAscii()
        if (!text.isEmpty() && !out.contains(text)) {
            out.add(text)
        }
    }
    out.toArray()
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
