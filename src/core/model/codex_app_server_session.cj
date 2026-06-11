package metis.core.model

import std.collection.ArrayList
import std.convert.Parsable
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

public class CodexAppServerTurnResult {
    public let finalText: String
    public let projectedMessages: Array<JsonObject>
    public let toolIterations: Int64
    public let interrupted: Bool
    public let completed: Bool
    public let error: String
    public let turnId: String
    public let threadId: String
    public let usage: Option<JsonObject>
    public let shouldRetire: Bool
    public let retireReason: String

    public init(
        finalText!: String = "",
        projectedMessages!: Array<JsonObject> = [],
        toolIterations!: Int64 = 0,
        interrupted!: Bool = false,
        completed!: Bool = false,
        error!: String = "",
        turnId!: String = "",
        threadId!: String = "",
        usage!: Option<JsonObject> = None<JsonObject>,
        shouldRetire!: Bool = false,
        retireReason!: String = ""
    ) {
        this.finalText = finalText
        this.projectedMessages = projectedMessages
        this.toolIterations = toolIterations
        this.interrupted = interrupted
        this.completed = completed
        this.error = error.trimAscii()
        this.turnId = turnId.trimAscii()
        this.threadId = threadId.trimAscii()
        this.usage = usage
        this.shouldRetire = shouldRetire
        this.retireReason = retireReason.trimAscii()
    }
}

public class CodexAppServerServerRequestDecision {
    public let handled: Bool
    public let method: String
    public let status: String
    public let errorCode: Int64

    public init(handled: Bool, method: String, status!: String = "", errorCode!: Int64 = 0) {
        this.handled = handled
        this.method = method.trimAscii()
        this.status = status.trimAscii()
        this.errorCode = errorCode
    }
}

public class CodexAppServerSession {
    private let client: CodexAppServerTransport
    private let projector: CodexEventProjector
    private var started = false
    private var threadId = ""
    private var lastUsage: Option<JsonObject> = None<JsonObject>

    public init(client: CodexAppServerTransport, projector!: CodexEventProjector = CodexEventProjector()) {
        this.client = client
        this.projector = projector
    }

    public func ensureStarted(cwd: String): String {
        if (this.started && !this.threadId.isEmpty()) {
            return this.threadId
        }
        this.client.start()
        let initParams = JsonObject()
        let clientInfo = JsonObject()
        clientInfo.put("name", JsonString("Metis"))
        clientInfo.put("version", JsonString("m5"))
        initParams.put("clientInfo", clientInfo)
        initParams.put("capabilities", JsonObject())
        let _ = this.client.request("initialize", initParams, 30000)
        this.client.notify("initialized", JsonObject())
        let thread = this.client.request("thread/start", codexAppServerBuildThreadStartParams(cwd), 30000)
        this.threadId = codexAppServerExtractThreadId(thread)
        this.started = true
        this.threadId
    }

    public func runTurn(
        cwd: String,
        inputText: String,
        timeoutMs!: Int64 = 600000,
        pollMs!: Int64 = 10,
        postToolQuietMs!: Int64 = 90000
    ): CodexAppServerTurnResult {
        let tid = try {
            this.ensureStarted(cwd)
        } catch (e: Exception) {
            let msg = if (codexAppServerLooksLikeAuthFailure(e.message)) { codexAppServerLoginHint(message: e.message) } else { codexAppServerRedactDiagnostic(e.message) }
            let retire = codexAppServerRetireForFailure(if (codexAppServerLooksLikeAuthFailure(e.message)) { "oauth_failure" } else { "startup_failure" }, message: e.message)
            return CodexAppServerTurnResult(error: msg, shouldRetire: retire.shouldRetire, retireReason: retire.reason)
        }
        if (!this.client.isAlive()) {
            return CodexAppServerTurnResult(error: "codex app-server process exited before turn/start", threadId: tid, shouldRetire: true, retireReason: "process_dead")
        }
        let startResult = try {
            this.client.request("turn/start", codexAppServerBuildTurnStartParams(tid, inputText), 30000)
        } catch (e: Exception) {
            let auth = codexAppServerLooksLikeAuthFailure(e.message)
            let status = if (auth) { "oauth_failure" } else { "turn_start_failed" }
            let msg = if (auth) { codexAppServerLoginHint(message: e.message) } else { codexAppServerRedactDiagnostic(e.message) }
            let retire = codexAppServerRetireForFailure(status, message: e.message)
            return CodexAppServerTurnResult(error: msg, threadId: tid, shouldRetire: retire.shouldRetire, retireReason: retire.reason)
        }
        let turnId = codexSessionJsonStringAny(startResult, ["turnId", "id", "turn_id"])
        let messages = ArrayList<JsonObject>()
        var finalText = ""
        var toolIterations: Int64 = 0
        let startedAt = codexSessionNowMs()
        var lastToolAt: Int64 = 0
        var idleIterations: Int64 = 0
        while (true) {
            if (!this.client.isAlive()) {
                return CodexAppServerTurnResult(
                    finalText: finalText,
                    projectedMessages: messages.toArray(),
                    toolIterations: toolIterations,
                    error: "codex app-server process exited",
                    turnId: turnId,
                    threadId: tid,
                    usage: this.lastUsage,
                    shouldRetire: true,
                    retireReason: "process_dead"
                )
            }
            let now = codexSessionNowMs()
            if (timeoutMs > 0 && now - startedAt >= timeoutMs) {
                this.interruptTurn(tid, turnId)
                return CodexAppServerTurnResult(
                    finalText: finalText,
                    projectedMessages: messages.toArray(),
                    toolIterations: toolIterations,
                    interrupted: true,
                    error: "codex app-server turn timed out",
                    turnId: turnId,
                    threadId: tid,
                    usage: this.lastUsage,
                    shouldRetire: true,
                    retireReason: "turn_timeout"
                )
            }
            match (this.client.takeServerRequest(0)) {
                case Some(request) =>
                    let _ = this.handleServerRequest(request)
                    idleIterations = 0
                    continue
                case None => ()
            }
            match (this.client.takeNotification(0)) {
                case Some(notification) =>
                    idleIterations = 0
                    let method = codexSessionJsonString(notification, "method")
                    if (method == "thread/tokenUsage/updated") {
                        this.lastUsage = Some(codexAppServerNormalizeUsageNotification(notification))
                        continue
                    }
                    if (method == "turn/completed" || method == "thread/turn/completed") {
                        return CodexAppServerTurnResult(
                            finalText: finalText,
                            projectedMessages: messages.toArray(),
                            toolIterations: toolIterations,
                            completed: true,
                            turnId: turnId,
                            threadId: tid,
                            usage: this.lastUsage
                        )
                    }
                    let projected = this.projector.project(notification)
                    for (msg in projected.messages) {
                        messages.add(msg)
                    }
                    if (projected.hasFinalText) {
                        finalText = projected.finalText
                    }
                    if (projected.isToolIteration) {
                        toolIterations += 1
                        lastToolAt = codexSessionNowMs()
                    }
                    match (projected.usage) {
                        case Some(usage) => this.lastUsage = Some(usage)
                        case None => ()
                    }
                    if (notification.toJsonString().contains("<turn_aborted>")) {
                        return CodexAppServerTurnResult(
                            finalText: finalText,
                            projectedMessages: messages.toArray(),
                            toolIterations: toolIterations,
                            interrupted: true,
                            error: "codex app-server turn aborted",
                            turnId: turnId,
                            threadId: tid,
                            usage: this.lastUsage,
                            shouldRetire: true,
                            retireReason: "turn_aborted"
                        )
                    }
                case None =>
                    idleIterations += 1
                    if (lastToolAt > 0 && postToolQuietMs >= 0 && codexSessionNowMs() - lastToolAt >= postToolQuietMs) {
                        this.interruptTurn(tid, turnId)
                        return CodexAppServerTurnResult(
                            finalText: finalText,
                            projectedMessages: messages.toArray(),
                            toolIterations: toolIterations,
                            interrupted: true,
                            error: "codex app-server quiet timeout after tool activity",
                            turnId: turnId,
                            threadId: tid,
                            usage: this.lastUsage,
                            shouldRetire: true,
                            retireReason: "post_tool_quiet_timeout"
                        )
                    }
                    if (idleIterations > 2 && pollMs <= 0 && timeoutMs <= 0) {
                        this.interruptTurn(tid, turnId)
                        return CodexAppServerTurnResult(
                            finalText: finalText,
                            projectedMessages: messages.toArray(),
                            toolIterations: toolIterations,
                            interrupted: true,
                            error: "codex app-server turn interrupted by idle watchdog",
                            turnId: turnId,
                            threadId: tid,
                            usage: this.lastUsage,
                            shouldRetire: true,
                            retireReason: "turn_timeout"
                        )
                    }
                    sleep(Duration.millisecond * if (pollMs > 0) { pollMs } else { 1 })
            }
        }
        CodexAppServerTurnResult()
    }

    public func handleServerRequest(request: JsonObject): CodexAppServerServerRequestDecision {
        let id = codexSessionJsonInt(request, "id", -1)
        let method = codexSessionJsonString(request, "method")
        let lower = method.toAsciiLower()
        if (id < 0) {
            return CodexAppServerServerRequestDecision(false, method, status: "missing_id", errorCode: -32600)
        }
        if (lower.contains("commandexecution") || lower.contains("command_execution")) {
            this.client.respond(id, codexAppServerDeclineApproval("commandExecution"))
            return CodexAppServerServerRequestDecision(true, method, status: "declined")
        }
        if (lower.contains("filechange") || lower.contains("file_change")) {
            this.client.respond(id, codexAppServerDeclineApproval("fileChange"))
            return CodexAppServerServerRequestDecision(true, method, status: "declined")
        }
        if (lower.contains("permissions") || lower.contains("permission")) {
            this.client.respond(id, codexAppServerDeclineApproval("permissions"))
            return CodexAppServerServerRequestDecision(true, method, status: "declined")
        }
        if (lower.contains("mcp") || lower.contains("elicitation")) {
            let params = codexSessionJsonObject(request, "params")
            let serverName = codexSessionJsonString(params, "serverName")
            if (serverName == "metis-tools") {
                let out = JsonObject()
                out.put("approved", JsonBool(true))
                out.put("decision", JsonString("accept"))
                this.client.respond(id, out)
                return CodexAppServerServerRequestDecision(true, method, status: "accepted")
            }
            this.client.respond(id, codexAppServerDeclineApproval("mcp:${serverName}"))
            return CodexAppServerServerRequestDecision(true, method, status: "declined")
        }
        this.client.respondError(id, -32601, "Method not found")
        CodexAppServerServerRequestDecision(false, method, status: "method_not_found", errorCode: -32601)
    }

    private func interruptTurn(threadId: String, turnId: String): Unit {
        let params = JsonObject()
        params.put("threadId", JsonString(threadId))
        if (!turnId.trimAscii().isEmpty()) {
            params.put("turnId", JsonString(turnId))
        }
        try { this.client.notify("turn/interrupt", params) } catch (_: Exception) { () }
    }
}

public func codexAppServerBuildThreadStartParams(cwd: String): JsonObject {
    let params = JsonObject()
    params.put("cwd", JsonString(cwd))
    params
}

public func codexAppServerBuildTurnStartParams(threadId: String, inputText: String): JsonObject {
    let params = JsonObject()
    params.put("threadId", JsonString(threadId))
    let input = JsonArray()
    let item = JsonObject()
    item.put("type", JsonString("text"))
    item.put("text", JsonString(inputText))
    input.add(item)
    params.put("input", input)
    params
}

public func codexAppServerExtractThreadId(result: JsonObject): String {
    let thread = codexSessionJsonObject(result, "thread")
    let fromThread = codexSessionJsonStringAny(thread, ["id", "sessionId"])
    if (!fromThread.isEmpty()) {
        return fromThread
    }
    let direct = codexSessionJsonStringAny(result, ["sessionId", "threadId"])
    if (!direct.isEmpty()) {
        return direct
    }
    throw CodexAppServerProtocolException("codex app-server thread/start response did not include a thread id", code: -32004)
}

public func codexAppServerDeclineApproval(kind: String): JsonObject {
    let result = JsonObject()
    result.put("approved", JsonBool(false))
    result.put("decision", JsonString("decline"))
    result.put("message", JsonString("Metis does not grant ${kind} approval through Codex app-server by default."))
    result
}

private func codexSessionNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func codexSessionJsonStringAny(obj: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        let value = codexSessionJsonString(obj, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    ""
}

private func codexSessionJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asString().getValue().trimAscii() } catch (_: Exception) { () }
        case None => ()
    }
    ""
}

private func codexSessionJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asInt().getValue() } catch (_: Exception) { () }
            try { return Int64.parse(value.asString().getValue().trimAscii()) } catch (_: Exception) { () }
        case None => ()
    }
    fallback
}

private func codexSessionJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asObject() } catch (_: Exception) { () }
        case None => ()
    }
    JsonObject()
}
