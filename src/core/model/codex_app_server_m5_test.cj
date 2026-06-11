package metis.core.model

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private class M5FakeCodexTransport <: CodexAppServerTransport {
    public let requests = ArrayList<JsonObject>()
    public let notificationsSent = ArrayList<JsonObject>()
    public let responsesSent = ArrayList<JsonObject>()
    public let responseErrorsSent = ArrayList<JsonObject>()
    private let requestResults = ArrayList<JsonObject>()
    private let requestErrors = ArrayList<String>()
    private let serverRequests = ArrayList<JsonObject>()
    private let notifications = ArrayList<JsonObject>()
    public var alive = true
    public var started = false

    public init() {}

    public func enqueueRequestResult(result: JsonObject): Unit {
        this.requestResults.add(result)
    }

    public func enqueueRequestError(message: String): Unit {
        this.requestErrors.add(message)
    }

    public func enqueueServerRequest(request: JsonObject): Unit {
        this.serverRequests.add(request)
    }

    public func enqueueNotification(notification: JsonObject): Unit {
        this.notifications.add(notification)
    }

    public func start(): Unit {
        this.started = true
    }

    public func request(method: String, params: JsonObject, _timeoutMs: Int64): JsonObject {
        let record = JsonObject()
        record.put("method", JsonString(method))
        record.put("params", params)
        this.requests.add(record)
        if (!this.requestErrors.isEmpty()) {
            let msg = this.requestErrors[0]
            this.requestErrors.remove(at: 0)
            throw CodexAppServerProtocolException(msg)
        }
        if (this.requestResults.isEmpty()) {
            return JsonObject()
        }
        let result = this.requestResults[0]
        this.requestResults.remove(at: 0)
        result
    }

    public func notify(method: String, params: JsonObject): Unit {
        let record = JsonObject()
        record.put("method", JsonString(method))
        record.put("params", params)
        this.notificationsSent.add(record)
    }

    public func respond(id: Int64, result: JsonObject): Unit {
        let record = JsonObject()
        record.put("id", JsonInt(id))
        record.put("result", result)
        this.responsesSent.add(record)
    }

    public func respondError(id: Int64, code: Int64, message: String): Unit {
        let error = JsonObject()
        error.put("code", JsonInt(code))
        error.put("message", JsonString(message))
        let record = JsonObject()
        record.put("id", JsonInt(id))
        record.put("error", error)
        this.responseErrorsSent.add(record)
    }

    public func takeServerRequest(_timeoutMs: Int64): Option<JsonObject> {
        if (this.serverRequests.isEmpty()) {
            return None<JsonObject>
        }
        let item = this.serverRequests[0]
        this.serverRequests.remove(at: 0)
        Some(item)
    }

    public func takeNotification(_timeoutMs: Int64): Option<JsonObject> {
        if (this.notifications.isEmpty()) {
            return None<JsonObject>
        }
        let item = this.notifications[0]
        this.notifications.remove(at: 0)
        Some(item)
    }

    public func isAlive(): Bool {
        this.alive
    }

    public func diagnostics(): Array<String> {
        []
    }

    public func close(): Unit {
        this.alive = false
    }
}

@Test
public class CodexAppServerM5Test {
    @TestCase
    public func m5U1U2B1ProtocolFramingThreadIdAndReaderClassification(): Unit {
        let req = JsonObject()
        req.put("id", JsonInt(7))
        req.put("method", JsonString("initialize"))
        req.put("params", JsonObject())
        let frame = codexAppServerFrame(req)
        @Expect(frame.endsWith("\n"), true)
        @Expect(frame.trimAscii().contains("\n"), false)
        @Expect(frame.contains("Content-Length"), false)
        @Expect(frame.contains("\"jsonrpc\""), false)

        @Expect(codexAppServerParseStdoutLine("{\"id\":7,\"result\":{}}").kind, "response")
        @Expect(codexAppServerParseStdoutLine("{\"id\":8,\"method\":\"commandExecution\",\"params\":{}}").kind, "server_request")
        @Expect(codexAppServerParseStdoutLine("{\"method\":\"thread/item/completed\",\"params\":{}}").kind, "notification")
        let diag = codexAppServerParseStdoutLine("oauth failed access_token=secret-codex-token")
        @Expect(diag.kind, "diagnostic")
        @Expect(diag.diagnostic.contains("secret-codex-token"), false)

        @Expect(codexAppServerExtractThreadId(m5ThreadResultFromThread("thread.id", "t1")), "t1")
        @Expect(codexAppServerExtractThreadId(m5ThreadResultFromThread("thread.sessionId", "s1")), "s1")
        @Expect(codexAppServerExtractThreadId(m5ThreadResultDirect("sessionId", "s2")), "s2")
        @Expect(codexAppServerExtractThreadId(m5ThreadResultDirect("threadId", "t2")), "t2")
    }

    @TestCase
    public func m5B2P1RunTurnInitializesThreadAndProjectsCompletion(): Unit {
        let fake = M5FakeCodexTransport()
        fake.enqueueRequestResult(JsonObject())
        fake.enqueueRequestResult(m5ThreadResultFromThread("thread.id", "thread-1"))
        fake.enqueueRequestResult(m5TurnStartResult("turn-1"))
        fake.enqueueNotification(m5ItemCompleted("agentMessage", "hello from codex"))
        fake.enqueueNotification(m5TurnCompleted())

        let session = CodexAppServerSession(fake)
        let result = session.runTurn("/repo", "hello", timeoutMs: 1000, pollMs: 0, postToolQuietMs: 10000)
        @Expect(result.completed, true)
        @Expect(result.finalText, "hello from codex")
        @Expect(result.threadId, "thread-1")
        @Expect(result.turnId, "turn-1")
        @Expect(result.shouldRetire, false)

        @Expect(m5JsonString(fake.requests[0], "method"), "initialize")
        @Expect(m5JsonString(fake.notificationsSent[0], "method"), "initialized")
        @Expect(m5JsonString(fake.requests[1], "method"), "thread/start")
        let threadParams = m5JsonObject(fake.requests[1], "params")
        @Expect(threadParams.getFields().size, 1)
        @Expect(m5JsonString(threadParams, "cwd"), "/repo")
        @Expect(threadParams.toJsonString().contains("permissions"), false)
        @Expect(threadParams.toJsonString().contains("operatorScopes"), false)

        @Expect(m5JsonString(fake.requests[2], "method"), "turn/start")
        let turnParams = m5JsonObject(fake.requests[2], "params")
        @Expect(m5JsonString(turnParams, "threadId"), "thread-1")
        let input = turnParams.get("input").getOrThrow().asArray()
        @Expect(input.size(), 1)
        @Expect(m5JsonString(input[0].asObject(), "type"), "text")
        @Expect(m5JsonString(input[0].asObject(), "text"), "hello")
    }

    @TestCase
    public func m5N2N3U4ServerRequestsFailClosedAndUnknownUsesMethodNotFound(): Unit {
        let fake = M5FakeCodexTransport()
        let session = CodexAppServerSession(fake)
        @Expect(session.handleServerRequest(m5ServerRequest(1, "commandExecution/approval", JsonObject())).status, "declined")
        @Expect(session.handleServerRequest(m5ServerRequest(2, "fileChange/approval", JsonObject())).status, "declined")
        @Expect(session.handleServerRequest(m5ServerRequest(3, "permissions/request", JsonObject())).status, "declined")

        let metisParams = JsonObject()
        metisParams.put("serverName", JsonString("metis-tools"))
        @Expect(session.handleServerRequest(m5ServerRequest(4, "mcp/elicitation", metisParams)).status, "accepted")

        let otherParams = JsonObject()
        otherParams.put("serverName", JsonString("other-tools"))
        @Expect(session.handleServerRequest(m5ServerRequest(5, "mcp/elicitation", otherParams)).status, "declined")

        let unknown = session.handleServerRequest(m5ServerRequest(6, "unknown/request", JsonObject()))
        @Expect(unknown.errorCode, -32601)
        @Expect(fake.responsesSent.size, 5)
        @Expect(m5JsonBool(m5JsonObject(fake.responsesSent[0], "result"), "approved"), false)
        @Expect(m5JsonString(m5JsonObject(fake.responsesSent[4], "result"), "decision"), "decline")
        @Expect(m5JsonInt(m5JsonObject(fake.responseErrorsSent[0], "error"), "code"), -32601)
    }

    @TestCase
    public func m5U3UsageProjectionRecordsSubscriptionIncludedWithoutCacheWrite(): Unit {
        let usage = JsonObject()
        let last = JsonObject()
        last.put("inputTokens", JsonInt(12))
        last.put("cachedInputTokens", JsonInt(5))
        last.put("outputTokens", JsonInt(7))
        last.put("reasoningTokens", JsonInt(2))
        last.put("totalTokens", JsonInt(19))
        usage.put("last", last)
        usage.put("modelContextWindow", JsonInt(272000))
        let note = JsonObject()
        note.put("method", JsonString("thread/tokenUsage/updated"))
        let params = JsonObject()
        params.put("tokenUsage", usage)
        note.put("params", params)

        let normalized = codexAppServerNormalizeUsageNotification(note)
        @Expect(m5JsonInt(normalized, "promptTokens"), 12)
        @Expect(m5JsonInt(normalized, "cachedInputTokens"), 5)
        @Expect(m5JsonInt(normalized, "cacheWriteTokens"), 0)
        @Expect(m5JsonString(normalized, "billingMode"), "subscription_included")
        @Expect(m5JsonInt(normalized, "callCount"), 1)
        @Expect(m5JsonInt(normalized, "modelContextWindow"), 272000)
    }

    @TestCase
    public func m5P2U7ProjectorCoversVisibleTextReasoningToolsAndErrors(): Unit {
        let projector = CodexEventProjector()
        let reasoning = projector.projectItem(m5Item("reasoning", "plan text"))
        @Expect(reasoning.messages.size, 1)
        @Expect(m5JsonString(reasoning.messages[0], "kind"), "reasoning")
        let answer = projector.projectItem(m5Item("agentMessage", "answer text"))
        @Expect(answer.hasFinalText, true)
        @Expect(answer.finalText, "answer text")
        @Expect(answer.messages[0].get("reasoning").getOrThrow().asArray().size(), 1)

        @Expect(projector.projectItem(m5Item("userMessage", "user text")).messages[0].get("role").getOrThrow().asString().getValue(), "user")
        @Expect(projector.projectItem(m5Item("commandExecution", "ls")).isToolIteration, true)
        @Expect(projector.projectItem(m5Item("fileChange", "patch")).isToolIteration, true)
        let mcp = m5Item("mcpToolCall", "tool")
        mcp.put("serverName", JsonString("metis-tools"))
        mcp.put("toolName", JsonString("web_search"))
        @Expect(projector.projectItem(mcp).messages[0].get("tool").getOrThrow().asString().getValue(), "metis-tools.web_search")
        @Expect(projector.projectItem(m5Item("dynamicToolCall", "dyn")).isToolIteration, true)
        @Expect(m5JsonString(projector.projectItem(m5Item("error", "boom")).messages[0], "kind"), "error")
    }

    @TestCase
    public func m5B3SessionInterruptsOnPostToolQuietTimeout(): Unit {
        let fake = M5FakeCodexTransport()
        fake.enqueueRequestResult(JsonObject())
        fake.enqueueRequestResult(m5ThreadResultFromThread("thread.id", "thread-quiet"))
        fake.enqueueRequestResult(m5TurnStartResult("turn-quiet"))
        fake.enqueueNotification(m5ItemCompleted("commandExecution", "ran tool"))

        let result = CodexAppServerSession(fake).runTurn("/repo", "do it", timeoutMs: 1000, pollMs: 0, postToolQuietMs: 0)
        @Expect(result.interrupted, true)
        @Expect(result.shouldRetire, true)
        @Expect(result.retireReason, "post_tool_quiet_timeout")
        @Expect(m5JsonString(fake.notificationsSent[fake.notificationsSent.size - 1], "method"), "turn/interrupt")
    }

    @TestCase
    public func m5N1U6AuthFailuresProduceCodexLoginHintAndRetireOnlyForLifecycleFailures(): Unit {
        let fake = M5FakeCodexTransport()
        fake.enqueueRequestError("invalid_grant access_token=secret-codex-token")
        let result = CodexAppServerSession(fake).runTurn("/repo", "hello", timeoutMs: 100, pollMs: 0)
        @Expect(result.shouldRetire, true)
        @Expect(result.error.contains("codex login"), true)
        @Expect(result.error.contains("secret-codex-token"), false)

        @Expect(codexAppServerRetireForFailure("process_dead").shouldRetire, true)
        @Expect(codexAppServerRetireForFailure("turn_timeout").shouldRetire, true)
        @Expect(codexAppServerRetireForFailure("model_failure").shouldRetire, false)
        @Expect(codexAppServerRetireForFailure("error", message: "<turn_aborted>").shouldRetire, true)
    }

    @TestCase
    public func m5U5U8N4LaunchEnvAndMcpSurfaceDoNotInjectMetisTokens(): Unit {
        let spec = codexAppServerBuildLaunchSpec(codexBin: "/usr/local/bin/codex", extraArgs: ["--sandbox", "read-only"])
        @Expect(spec.command, "/usr/local/bin/codex")
        @Expect(spec.args[0], "app-server")
        @Expect(spec.args[1], "--sandbox")

        let parent = HashMap<String, String>()
        parent["HOME"] = "/tmp/metis-home"
        parent["METIS_OPENAI_CODEX_ACCESS_TOKEN"] = "secret-codex-token"
        let env = codexAppServerBuildEnvironment(parentEnv: parent, codexHome: Some("/tmp/codex-home"))
        @Expect(env["HOME"], "/tmp/metis-home")
        @Expect(env["CODEX_HOME"], "/tmp/codex-home")
        @Expect(env["RUST_LOG"], "warn")
        @Expect(env.contains("METIS_OPENAI_CODEX_ACCESS_TOKEN"), false)
        @Expect(env.toString().contains("secret-codex-token"), false)

        @Expect(codexAppServerMcpExposedTools().contains("web_search"), true)
        @Expect(codexAppServerMcpForbiddenTools().contains("shell"), true)
        @Expect(codexAppServerDispatchMetisMcpTool("web_search").ok, true)
        @Expect(codexAppServerDispatchMetisMcpTool("shell").status, "forbidden")
        @Expect(codexAppServerDispatchMetisMcpTool("delegate_task").status, "forbidden")
        @Expect(codexAppServerDispatchMetisMcpTool("unknown_tool").status, "not_applicable")
    }

    @TestCase
    public func m5N5ClientCloseTerminatesWrapperDescendantsAfterInitializeTimeout(): Unit {
        let root = m5TempRoot("client-close-tree")
        let codex = root.join("codex")
        let parentPidPath = root.join("parent.pid")
        let childPidPath = root.join("child.pid")
        File.writeTo(codex, (
            "#!/bin/sh\n" +
            "if [ \"$1\" != \"app-server\" ]; then exit 2; fi\n" +
            "echo $$ > \"${parentPidPath.toString()}\"\n" +
            "(while :; do sleep 60; done) &\n" +
            "echo $! > \"${childPidPath.toString()}\"\n" +
            "printf '%s\\n' 'startup diagnostic from fake codex' >&2\n" +
            "while :; do sleep 60; done\n"
        ).toArray())
        let (_chmodCode, _, _) = executeWithOutput("chmod", ["+x", codex.toString()])

        let client = CodexAppServerClient(codexBin: codex.toString(), cwd: Some(root.toString()))
        var error = ""
        try {
            let _ = client.request("initialize", JsonObject(), 80)
        } catch (e: Exception) {
            error = e.message
        }
        client.close()

        let parentPid = m5ReadPid(parentPidPath)
        let childPid = m5ReadPid(childPidPath)
        let parentGone = m5WaitPidGone(parentPid, 1000)
        let childGone = m5WaitPidGone(childPid, 1000)
        if (!parentGone) { m5KillPid(parentPid) }
        if (!childGone) { m5KillPid(childPid) }
        try { remove(root, recursive: true) } catch (_: Exception) { () }

        @Expect(error.contains("initialize"), true)
        @Expect(error.contains("startup diagnostic from fake codex"), true)
        @Expect(parentGone, true)
        @Expect(childGone, true)
    }
}

private func m5TempRoot(label: String): Path {
    let root = Path("/tmp/metis-codex-app-server-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
    if (exists(root)) {
        remove(root, recursive: true)
    }
    Directory.create(root, recursive: true)
    root
}

private func m5ReadPid(path: Path): Int64 {
    try {
        Int64.parse(String.fromUtf8(File.readFrom(path)).trimAscii())
    } catch (_: Exception) {
        0
    }
}

private func m5PidAlive(pid: Int64): Bool {
    if (pid <= 0) {
        return false
    }
    let (exitCode, _, _) = executeWithOutput("kill", ["-0", "${pid}"])
    exitCode == 0
}

private func m5KillPid(pid: Int64): Unit {
    if (pid <= 0) {
        return
    }
    let _ = executeWithOutput("kill", ["-KILL", "${pid}"])
}

private func m5WaitPidGone(pid: Int64, timeoutMs: Int64): Bool {
    if (pid <= 0) {
        return true
    }
    let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() - started < timeoutMs) {
        if (!m5PidAlive(pid)) {
            return true
        }
        sleep(Duration.millisecond * 25)
    }
    !m5PidAlive(pid)
}

private func m5ThreadResultFromThread(field: String, value: String): JsonObject {
    let root = JsonObject()
    let thread = JsonObject()
    if (field == "thread.sessionId") {
        thread.put("sessionId", JsonString(value))
    } else {
        thread.put("id", JsonString(value))
    }
    root.put("thread", thread)
    root
}

private func m5ThreadResultDirect(field: String, value: String): JsonObject {
    let root = JsonObject()
    root.put(field, JsonString(value))
    root
}

private func m5TurnStartResult(turnId: String): JsonObject {
    let root = JsonObject()
    root.put("turnId", JsonString(turnId))
    root
}

private func m5TurnCompleted(): JsonObject {
    let note = JsonObject()
    note.put("method", JsonString("turn/completed"))
    note.put("params", JsonObject())
    note
}

private func m5ItemCompleted(itemType: String, text: String): JsonObject {
    let note = JsonObject()
    note.put("method", JsonString("thread/item/completed"))
    let params = JsonObject()
    params.put("item", m5Item(itemType, text))
    note.put("params", params)
    note
}

private func m5Item(itemType: String, text: String): JsonObject {
    let item = JsonObject()
    item.put("type", JsonString(itemType))
    item.put("id", JsonString("${itemType}-${text}"))
    item.put("text", JsonString(text))
    item
}

private func m5ServerRequest(id: Int64, method: String, params: JsonObject): JsonObject {
    let req = JsonObject()
    req.put("id", JsonInt(id))
    req.put("method", JsonString(method))
    req.put("params", params)
    req
}

private func m5JsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(value) => try { return value.asObject() } catch (_: Exception) { () }
        case None => ()
    }
    JsonObject()
}

private func m5JsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try { return value.asString().getValue() } catch (_: Exception) { () }
        case None => ()
    }
    ""
}

private func m5JsonInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(value) => try { return value.asInt().getValue() } catch (_: Exception) { () }
        case None => ()
    }
    0
}

private func m5JsonBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(value) => try { return value.asBool().getValue() } catch (_: Exception) { () }
        case None => ()
    }
    false
}
