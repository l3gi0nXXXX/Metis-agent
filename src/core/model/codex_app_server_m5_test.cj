package metis.core.model

import metis.process.managedStdioBroker

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
        let parentGone = m5WaitPidGone(parentPid, 5000)
        let childGone = m5WaitPidGone(childPid, 5000)
        if (!parentGone) { m5KillPid(parentPid) }
        if (!childGone) { m5KillPid(childPid) }
        try { remove(root, recursive: true) } catch (_: Exception) { () }

        @Expect(error.contains("initialize"), true)
        @Expect(error.contains("startup diagnostic from fake codex"), true)
        @Expect(parentGone, true)
        @Expect(childGone, true)
    }

    @TestCase
    public func p3U3BrokerRoutesInterleavedCodexFramesWithoutCrossOwnerLeakage(): Unit {
        let script = m5FakeCodexScript()
        let first = CodexAppServerClient(
            codexBin: script,
            env: m5FakeCodexEnvironment("session", "first")
        )
        let second = CodexAppServerClient(
            codexBin: script,
            env: m5FakeCodexEnvironment("session", "second")
        )
        var firstResult = JsonObject()
        var secondResult = JsonObject()
        var firstRequest = JsonObject()
        var secondRequest = JsonObject()
        var firstNotification = JsonObject()
        var secondNotification = JsonObject()
        var snapshot = managedStdioBroker().debugSnapshotForTest()
        var firstDiagnostics = ""
        var secondDiagnostics = ""
        var firstFuture = None<Future<JsonObject>>
        var secondFuture = None<Future<JsonObject>>
        try {
            first.start()
            second.start()
            firstFuture = Some(spawn { first.request("initialize", JsonObject(), 3000) })
            secondFuture = Some(spawn { second.request("initialize", JsonObject(), 3000) })
            firstResult = firstFuture.getOrThrow().get(Duration.second * 5)
            secondResult = secondFuture.getOrThrow().get(Duration.second * 5)
            firstRequest = first.takeServerRequest(1000).getOrThrow()
            secondRequest = second.takeServerRequest(1000).getOrThrow()
            firstNotification = first.takeNotification(1000).getOrThrow()
            secondNotification = second.takeNotification(1000).getOrThrow()
            snapshot = managedStdioBroker().debugSnapshotForTest()
            firstDiagnostics = first.diagnostics().toString()
            secondDiagnostics = second.diagnostics().toString()
        } finally {
            m5JoinFuture(firstFuture, 5000)
            m5JoinFuture(secondFuture, 5000)
            first.close()
            second.close()
        }

        @Expect(m5JsonString(firstResult, "label"), "first")
        @Expect(m5JsonString(secondResult, "label"), "second")
        @Expect(firstResult.toJsonString().contains("second"), false)
        @Expect(secondResult.toJsonString().contains("first"), false)
        @Expect(m5JsonInt(firstRequest, "id"), 9000)
        @Expect(m5JsonInt(secondRequest, "id"), 9000)
        @Expect(m5JsonString(m5JsonObject(firstNotification, "params"), "label"), "first")
        @Expect(m5JsonString(m5JsonObject(secondNotification, "params"), "label"), "second")
        @Expect(snapshot.readerCount, 1)
        @Expect(snapshot.dispatcherCount, 1)
        @Expect(snapshot.ownerCount >= 2, true)
        @Expect(firstDiagnostics.contains("secret-codex-token"), false)
        @Expect(secondDiagnostics.contains("secret-codex-token"), false)
        @Expect(firstDiagnostics.contains("/Users/"), false)
        @Expect(firstDiagnostics.contains("/private/"), false)
        @Expect(firstDiagnostics.toAsciiLower().contains("c:\\users\\"), false)
        @Expect(firstDiagnostics.contains("中文🙂"), true)
    }

    @TestCase
    public func p3B3Utf8MalformedTimeoutAndDiagnosticsAreStableAndRedacted(): Unit {
        let unicode = codexAppServerParseStdoutLine("{\"id\":3,\"result\":{\"text\":\"中文🙂\"}}")
        let malformed = codexAppServerParseStdoutLine("{not-json 中文🙂")
        let longText = m5RepeatedText(r'x', 256)
        let oversizedSecret = "access_token=secret-codex-token " + longText
        let redacted = codexAppServerRedactDiagnostic(oversizedSecret)

        let invalid = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("invalid-utf8", "invalid")
        )
        var invalidError = ""
        try {
            let _ = invalid.request("initialize", JsonObject(), 100)
        } catch (e: Exception) {
            invalidError = e.message
        } finally {
            invalid.close()
        }
        let invalidDiagnostics = invalid.diagnostics().toString()

        let tooLong = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("long-line", "long")
        )
        var tooLongError = ""
        try {
            let _ = tooLong.request("initialize", JsonObject(), 100)
        } catch (e: Exception) {
            tooLongError = e.message
        } finally {
            tooLong.close()
        }
        let tooLongDiagnostics = tooLong.diagnostics().toString()

        let malformedClient = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("malformed-json", "malformed")
        )
        var malformedError = ""
        try {
            let _ = malformedClient.request("initialize", JsonObject(), 100)
        } catch (e: Exception) {
            malformedError = e.message
        } finally {
            malformedClient.close()
        }

        let beforeDeadline = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("delayed-response", "before", delayMs: Some<Int64>(20))
        )
        var beforeResult = JsonObject()
        try {
            beforeResult = beforeDeadline.request("initialize", JsonObject(), 500)
        } finally {
            beforeDeadline.close()
        }

        let afterDeadline = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("delayed-response", "after", delayMs: Some<Int64>(200))
        )
        let alongside = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("session", "alongside")
        )
        var afterError = ""
        var alongsideResult = JsonObject()
        var afterFuture = None<Future<String>>
        var alongsideFuture = None<Future<JsonObject>>
        var firstClose = None<Future<Unit>>
        var secondClose = None<Future<Unit>>
        try {
            afterFuture = Some(spawn {
                try {
                    let _ = afterDeadline.request("initialize", JsonObject(), 30)
                    "unexpected_success"
                } catch (e: Exception) { e.message }
            })
            alongsideFuture = Some(spawn { alongside.request("initialize", JsonObject(), 3000) })
            afterError = afterFuture.getOrThrow().get(Duration.second * 5)
            alongsideResult = alongsideFuture.getOrThrow().get(Duration.second * 5)
        } finally {
            m5JoinFuture(afterFuture, 5000)
            m5JoinFuture(alongsideFuture, 5000)
            firstClose = Some(spawn { afterDeadline.close() })
            secondClose = Some(spawn { afterDeadline.close() })
            m5JoinFuture(firstClose, 2000)
            m5JoinFuture(secondClose, 2000)
            alongside.close()
        }
        sleep(Duration.millisecond * 250)
        var lateRequestError = ""
        try { let _ = afterDeadline.request("initialize", JsonObject(), 100) } catch (e: Exception) { lateRequestError = e.message }

        let timeout = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("no-response", "timeout")
        )
        var timeoutError = ""
        try {
            let _ = timeout.request("initialize", JsonObject(), 80)
        } catch (e: Exception) {
            timeoutError = e.message
        } finally {
            timeout.close()
        }

        let stderrBurst = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("stderr-burst", "burst")
        )
        var burstResult = JsonObject()
        try {
            burstResult = stderrBurst.request("initialize", JsonObject(), 3000)
        } finally {
            stderrBurst.close()
        }
        let burstDiagnostics = stderrBurst.diagnostics().toString()

        @Expect(unicode.kind, "response")
        @Expect(unicode.message.toJsonString().contains("中文🙂"), true)
        @Expect(malformed.kind, "diagnostic")
        @Expect(malformed.diagnostic, "malformed_json")
        @Expect(redacted.contains("secret-codex-token"), false)
        @Expect(redacted.contains(m5RepeatedText(r'x', 128)), false)
        @Expect(invalidError.contains("invalid_response_encoding") || invalidDiagnostics.contains("invalid_response_encoding"), true)
        @Expect(invalidError.contains("secret-codex-token"), false)
        @Expect(tooLongError.contains("line_too_large") || tooLongDiagnostics.contains("line_too_large"), true)
        @Expect(tooLongDiagnostics.contains(m5RepeatedText(r'中', 32)), false)
        @Expect(malformedError.contains("malformed_json"), true)
        @Expect(m5JsonString(beforeResult, "label"), "before")
        @Expect(afterError.contains("initialize"), true)
        @Expect(m5JsonString(alongsideResult, "label"), "alongside")
        @Expect(lateRequestError.contains("closed"), true)
        @Expect(timeoutError.contains("initialize"), true)
        @Expect(timeoutError.contains("secret-codex-token"), false)
        @Expect(m5JsonString(burstResult, "label"), "burst")
        @Expect(burstDiagnostics.contains("中文🙂"), true)
        @Expect(burstDiagnostics.contains("secret-codex-token"), false)
        @Expect(burstDiagnostics.contains("/Users/"), false)
    }

    @TestCase
    public func p3P3RealBrokerConcurrentSessionsPreserveAnswersAndUsage(): Unit {
        let firstClient = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("session", "session-a")
        )
        let secondClient = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("session", "session-b")
        )
        var first = CodexAppServerTurnResult()
        var second = CodexAppServerTurnResult()
        var snapshot = managedStdioBroker().debugSnapshotForTest()
        var firstFuture = None<Future<CodexAppServerTurnResult>>
        var secondFuture = None<Future<CodexAppServerTurnResult>>
        try {
            firstFuture = Some(spawn {
                CodexAppServerSession(firstClient).runTurn("/tmp/session-a", "first 中文🙂", timeoutMs: 5000)
            })
            secondFuture = Some(spawn {
                CodexAppServerSession(secondClient).runTurn("/tmp/session-b", "second 中文🙂", timeoutMs: 5000)
            })
            first = firstFuture.getOrThrow().get(Duration.second * 8)
            second = secondFuture.getOrThrow().get(Duration.second * 8)
            snapshot = managedStdioBroker().debugSnapshotForTest()
        } finally {
            m5JoinFuture(firstFuture, 8000)
            m5JoinFuture(secondFuture, 8000)
            firstClient.close()
            secondClient.close()
        }

        @Expect(first.completed, true)
        @Expect(second.completed, true)
        @Expect(first.finalText, "answer-session-a-中文🙂")
        @Expect(second.finalText, "answer-session-b-中文🙂")
        @Expect(first.threadId, "thread-session-a")
        @Expect(second.threadId, "thread-session-b")
        @Expect(m5JsonInt(first.usage.getOrThrow(), "promptTokens"), 12)
        @Expect(m5JsonInt(first.usage.getOrThrow(), "cachedInputTokens"), 3)
        @Expect(m5JsonInt(first.usage.getOrThrow(), "outputTokens"), 7)
        @Expect(m5JsonInt(first.usage.getOrThrow(), "cacheWriteTokens"), 0)
        @Expect(m5JsonString(first.usage.getOrThrow(), "billingMode"), "subscription_included")
        @Expect(m5JsonInt(second.usage.getOrThrow(), "promptTokens"), 12)
        @Expect(m5JsonInt(second.usage.getOrThrow(), "cachedInputTokens"), 3)
        @Expect(m5JsonInt(second.usage.getOrThrow(), "outputTokens"), 7)
        @Expect(m5JsonInt(second.usage.getOrThrow(), "cacheWriteTokens"), 0)
        @Expect(m5JsonString(second.usage.getOrThrow(), "billingMode"), "subscription_included")
        @Expect(snapshot.readerCount, 1)
        @Expect(snapshot.dispatcherCount, 1)
        @Expect(snapshot.ownerCount >= 2, true)
    }

    @TestCase
    public func p3N3BrokerKillReapsCodexTreeAndNextGenerationRecovers(): Unit {
        let root = m5TempRoot("broker-kill-tree")
        let parentPidPath = root.join("parent.pid")
        let childPidPath = root.join("child.pid")
        let hanging = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment(
                "hang-tree",
                "hanging",
                parentPidPath: Some(parentPidPath.toString()),
                childPidPath: Some(childPidPath.toString())
            )
        )
        let recovered = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("session", "recovered")
        )
        var filesReady = false
        var parentPid: Int64 = 0
        var childPid: Int64 = 0
        var parentGone = false
        var childGone = false
        var hangingError = ""
        var result = JsonObject()
        var before = managedStdioBroker().debugSnapshotForTest()
        var after = before
        var hangingRequest = None<Future<String>>
        var recoveryFuture = None<Future<JsonObject>>
        try {
            hanging.start()
            filesReady = m5WaitPathsExist([parentPidPath, childPidPath], 3000)
            parentPid = m5ReadPid(parentPidPath)
            childPid = m5ReadPid(childPidPath)
            hangingRequest = Some(spawn {
                try {
                    let _ = hanging.request("initialize", JsonObject(), 5000)
                    "unexpected_success"
                } catch (e: Exception) { e.message }
            })
            sleep(Duration.millisecond * 50)
            before = managedStdioBroker().debugSnapshotForTest()
            let _ = executeWithOutput("kill", ["-KILL", "${before.brokerPid}"])
            recoveryFuture = Some(spawn {
                sleep(Duration.millisecond * 50)
                recovered.request("initialize", JsonObject(), 4000)
            })
            hangingError = hangingRequest.getOrThrow().get(Duration.second * 6)
            result = recoveryFuture.getOrThrow().get(Duration.second * 6)
            parentGone = m5WaitPidGone(parentPid, 5000)
            childGone = m5WaitPidGone(childPid, 5000)
            after = managedStdioBroker().debugSnapshotForTest()
        } finally {
            m5JoinFuture(hangingRequest, 6000)
            m5JoinFuture(recoveryFuture, 6000)
            hanging.close()
            recovered.close()
            if (!m5WaitPidGone(parentPid, 200)) { m5KillPid(parentPid) }
            if (!m5WaitPidGone(childPid, 200)) { m5KillPid(childPid) }
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }

        @Expect(filesReady, true)
        @Expect(parentGone, true)
        @Expect(childGone, true)
        @Expect(hangingError.contains("broker_exited"), true)
        @Expect(hangingError.contains("secret-codex-token"), false)
        @Expect(hangingError.contains("/Users/"), false)
        @Expect(hangingError.contains("/private/"), false)
        @Expect(hangingError.toAsciiLower().contains("c:\\users\\"), false)
        @Expect(m5JsonString(result, "label"), "recovered")
        @Expect(after.generation > before.generation, true)
        @Expect(after.readerCount, 1)
        @Expect(after.dispatcherCount, 1)
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

private func m5JoinFuture<T>(future: Option<Future<T>>, timeoutMs: Int64): Unit {
    match (future) {
        case Some(value) => try { let _ = value.get(Duration.millisecond * timeoutMs) } catch (_: Exception) { () }
        case None => ()
    }
}

private func m5FakeCodexScript(): String {
    Path("scripts").join("gateway-stdio-fake-codex-app-server.mjs").toString()
}

private func m5FakeCodexEnvironment(
    mode: String,
    label: String,
    parentPidPath!: Option<String> = None<String>,
    childPidPath!: Option<String> = None<String>,
    delayMs!: Option<Int64> = None<Int64>
): HashMap<String, String> {
    let env = codexAppServerCurrentEnvironment()
    env["METIS_CODEX_FAKE_MODE"] = mode
    env["METIS_CODEX_FAKE_LABEL"] = label
    match (parentPidPath) {
        case Some(value) => env["METIS_CODEX_FAKE_PID_FILE"] = value
        case None => ()
    }
    match (childPidPath) {
        case Some(value) => env["METIS_CODEX_FAKE_CHILD_PID_FILE"] = value
        case None => ()
    }
    match (delayMs) {
        case Some(value) => env["METIS_CODEX_FAKE_DELAY_MS"] = "${value}"
        case None => ()
    }
    env
}

private func m5WaitPathsExist(paths: Array<Path>, timeoutMs: Int64): Bool {
    let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() - started < timeoutMs) {
        var allExist = true
        for (path in paths) {
            if (!exists(path)) { allExist = false }
        }
        if (allExist) { return true }
        sleep(Duration.millisecond * 20)
    }
    false
}

private func m5RepeatedText(value: Rune, count: Int64): String {
    let out = StringBuilder()
    for (_ in 0..count) { out.append(value) }
    out.toString()
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
