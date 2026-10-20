package metis.core.model

import metis.process.{ManagedStdioEvent, managedStdioBroker}

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.fs.{Directory, File, Path, canonicalize, exists, remove}
import std.process.executeWithOutput
import std.sync.{AtomicBool, AtomicInt64}
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private class M5FakeCodexTransport <: CodexAppServerTransport {
    public let requests = ArrayList<JsonObject>()
    public let requestTimeouts = ArrayList<Int64>()
    public let startTimeouts = ArrayList<Int64>()
    public let readTimeouts = ArrayList<Int64>()
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
        this.start(0)
    }

    public func start(timeoutMs: Int64): Unit {
        this.startTimeouts.add(timeoutMs)
        this.started = true
    }

    public func request(method: String, params: JsonObject, _timeoutMs: Int64): JsonObject {
        this.requestTimeouts.add(_timeoutMs)
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
        this.readTimeouts.add(_timeoutMs)
        if (this.serverRequests.isEmpty()) {
            return None<JsonObject>
        }
        let item = this.serverRequests[0]
        this.serverRequests.remove(at: 0)
        Some(item)
    }

    public func takeNotification(_timeoutMs: Int64): Option<JsonObject> {
        this.readTimeouts.add(_timeoutMs)
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
        var parentPid: Int64 = 0
        var childPid: Int64 = 0
        var parentGone = false
        var childGone = false
        try {
            let setupDeadline = MonoTime.now() + Duration.second * 5
            client.start(5000)
            let startupMarker = "startup diagnostic from fake codex"
            var startupReady = false
            while (!startupReady && MonoTime.now() < setupDeadline) {
                startupReady = client.diagnostics().toString().contains(startupMarker)
                if (!startupReady && MonoTime.now() < setupDeadline) {
                    sleep(Duration.millisecond * 10)
                }
            }
            @Expect(startupReady, true)
            if (!startupReady) { throw Exception("M5 client startup diagnostic not ready") }

            parentPid = m5ReadPid(parentPidPath)
            childPid = m5ReadPid(childPidPath)
            @Expect(parentPid > 1, true)
            @Expect(childPid > 1, true)
            if (parentPid <= 1 || childPid <= 1) { throw Exception("M5 client descendant identity invalid") }

            try {
                let _ = client.request("initialize", JsonObject(), 80)
            } catch (e: Exception) {
                error = e.message
            }
        } finally {
            try {
                client.close()
            } finally {
                parentGone = m5WaitPidGone(parentPid, 5000)
                childGone = m5WaitPidGone(childPid, 5000)
                if (!parentGone) { m5KillPid(parentPid) }
                if (!childGone) { m5KillPid(childPid) }
                try { remove(root, recursive: true) } catch (_: Exception) { () }
            }
        }

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
        let brokerReady = managedStdioBroker().probeBroker(timeoutMs: 2000)
        @Expect(brokerReady.ok, true)
        if (!brokerReady.ok) { throw Exception("P3 broker warmup failed") }
        m5WarmBrokerDispatcher()
        let brokerBaseline = managedStdioBroker().debugSnapshotForTest()
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
            env: m5FakeCodexEnvironment("delayed-response", "after", delayMs: Some<Int64>(500))
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
                    let _ = afterDeadline.request("initialize", JsonObject(), 200)
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
        let brokerAfter = managedStdioBroker().debugSnapshotForTest()

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
        @Expect(brokerAfter.generation, brokerBaseline.generation)
        @Expect(brokerAfter.brokerPid, brokerBaseline.brokerPid)
        @Expect(brokerAfter.ownerCount, brokerBaseline.ownerCount)
        @Expect(brokerAfter.readerCount, brokerBaseline.readerCount)
        @Expect(brokerAfter.dispatcherCount, brokerBaseline.dispatcherCount)
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

    @TestCase
    public func v4U1ExpiredPollsKeepLateFramesQueuedWithoutStartingOwner(): Unit {
        let before = managedStdioBroker().debugSnapshotForTest()
        let client = CodexAppServerClient(absoluteDeadlineMs: 1)
        client.onManagedStdioEvent(ManagedStdioEvent("owner.stdout", text: "{\"id\":9,\"method\":\"approval\"}"))
        client.onManagedStdioEvent(ManagedStdioEvent("owner.stdout", text: "{\"method\":\"turn/completed\"}"))
        try {
            for (cap in [1, 0, -1]) {
                @Expect(client.takeServerRequest(cap).isNone(), true)
                @Expect(client.takeNotification(cap).isNone(), true)
            }
            @Expect(client.debugPendingNotificationCountForTest(), 1)
            for (operation in 0..3) {
                var strictTimeout = false
                try {
                    if (operation == 0) { client.start(1) }
                    else if (operation == 1) { let _ = client.request("initialize", JsonObject(), 1) }
                    else { client.respond(9, JsonObject()) }
                } catch (e: CodexAppServerProtocolException) {
                    strictTimeout = e.code == -32001 && e.message == "codex app-server work deadline exhausted"
                }
                @Expect(strictTimeout, true)
            }
            let after = managedStdioBroker().debugSnapshotForTest()
            @Expect(after.ownerCount, before.ownerCount)
            @Expect(after.readerCount, before.readerCount)
            @Expect(after.dispatcherCount, before.dispatcherCount)
            @Expect(after.generation, before.generation)
            @Expect(after.brokerPid, before.brokerPid)
        } finally { client.close() }
    }

    @TestCase
    public func v4B1LivePollsPreserveDefaultAndCappedQueueReads(): Unit {
        for (absolute in [0, codexAppServerAbsoluteDeadlineMs(5000)]) {
            let client = CodexAppServerClient(absoluteDeadlineMs: absolute)
            try {
                for (cap in [1, 0, -1]) {
                    client.onManagedStdioEvent(ManagedStdioEvent("owner.stdout", text: "{\"id\":9,\"method\":\"approval\"}"))
                    client.onManagedStdioEvent(ManagedStdioEvent("owner.stdout", text: "{\"method\":\"turn/completed\"}"))
                    @Expect(client.takeServerRequest(cap).isSome(), true)
                    @Expect(client.takeNotification(cap).isSome(), true)
                }
                @Expect(client.takeServerRequest(1).isNone(), true)
                @Expect(client.takeNotification(1).isNone(), true)
            } finally { client.close() }
        }
    }

    @TestCase
    public func s4BU1AllSetupPollAndTerminalWaitsUseSeparateDecreasingBudgets(): Unit {
        @Expect(codexAppServerAbsoluteDeadlineMs(500, nowMs: Int64.Max - 100), Int64.Max)
        @Expect(codexAppServerWorkRemainingMs(10000, nowMs: 0), 9000)
        @Expect(codexAppServerWorkRemainingMs(10000, nowMs: 100), 8900)
        @Expect(codexAppServerWorkRemainingMs(10000, nowMs: 9000), 0)
        @Expect(codexAppServerTerminalRemainingMs(10000, nowMs: 9000), 1000)
        @Expect(codexAppServerTerminalRemainingMs(10000, nowMs: 10000), 0)

        let fake = M5FakeCodexTransport()
        fake.enqueueRequestResult(JsonObject())
        fake.enqueueRequestResult(m5ThreadResultFromThread("thread.id", "s4b-thread"))
        fake.enqueueRequestResult(m5TurnStartResult("s4b-turn"))
        fake.enqueueNotification(m5TurnCompleted())
        let absolute = codexAppServerAbsoluteDeadlineMs(5000)
        let result = CodexAppServerSession(fake).runTurn(
            "/repo",
            "bounded",
            timeoutMs: 5000,
            pollMs: 10,
            absoluteDeadlineMs: absolute
        )
        @Expect(result.completed, true)
        @Expect(fake.startTimeouts.isEmpty(), false)
        @Expect(fake.requestTimeouts.size, 3)
        for (timeout in fake.startTimeouts) {
            @Expect(timeout > 0 && timeout <= 4000, true)
        }
        for (timeout in fake.requestTimeouts) {
            @Expect(timeout > 0 && timeout <= 4000, true)
        }
        for (timeout in fake.readTimeouts) {
            @Expect(timeout > 0 && timeout <= 10, true)
        }
        if (fake.requestTimeouts.size != 3 || fake.readTimeouts.isEmpty()) {
            throw Exception("S4B phase budget observations missing")
        }
        @Expect(fake.requestTimeouts[1] <= fake.requestTimeouts[0], true)
        @Expect(fake.requestTimeouts[2] <= fake.requestTimeouts[1], true)
        @Expect(fake.readTimeouts[0] <= fake.requestTimeouts[2], true)
    }

    @TestCase
    public func s4BP1HundredTimeoutsLeaveOwnerPipeCloserAndRegistryZero(): Unit {
        var interrupted: Int64 = 0
        for (_ in 0..100) {
            let fake = M5FakeCodexTransport()
            fake.enqueueRequestResult(JsonObject())
            fake.enqueueRequestResult(m5ThreadResultFromThread("thread.id", "s4b-thread"))
            fake.enqueueRequestResult(m5TurnStartResult("s4b-turn"))
            let result = CodexAppServerSession(fake).runTurn(
                "/repo", "bounded", timeoutMs: 1050, pollMs: 0,
                absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(1050)
            )
            if (result.interrupted && result.retireReason == "turn_timeout") {
                interrupted += 1
            }
            @Expect(fake.notificationsSent.isEmpty(), false)
            if (fake.notificationsSent.isEmpty()) {
                throw Exception("S4B timeout did not emit terminal interrupt")
            }
            @Expect(m5JsonString(fake.notificationsSent[fake.notificationsSent.size - 1], "method"), "turn/interrupt")
        }
        @Expect(interrupted, 100)

        let brokerReady = managedStdioBroker().probeBroker(timeoutMs: 2000)
        @Expect(brokerReady.ok, true)
        if (!brokerReady.ok) { throw Exception("S4B broker warmup failed") }
        m5WarmBrokerDispatcher()
        let baseline = managedStdioBroker().debugSnapshotForTest()
        let successRoot = m5TempRoot("s4b-success-owner")
        let successPidPath = successRoot.join("owner.pid")
        let successClient = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("session", "s4b-success", parentPidPath: Some(successPidPath.toString())),
            cwd: Some(successRoot.toString()),
            absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(5000)
        )
        var successCompleted = false
        var successPid: Int64 = 0
        var successPgid: Int64 = 0
        var successGone = false
        var successGroupGone = false
        try {
            let result = CodexAppServerSession(successClient).runTurn(
                successRoot.toString(), "bounded", absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(5000)
            )
            successCompleted = result.completed
            successPid = m5ReadPid(successPidPath)
            let ownerIdentity = successClient.debugOwnerIdentityForTest()
            successPgid = ownerIdentity[2]
        } finally {
            try {
                successClient.close()
            } finally {
                successGone = m5WaitPidGone(successPid, 2000)
                successGroupGone = m5WaitPgidGone(successPgid, 2000)
                if (!successGone) { m5KillPid(successPid) }
                try { remove(successRoot, recursive: true) } catch (_: Exception) { () }
            }
        }
        @Expect(successCompleted, true)
        @Expect(successPid > 0, true)
        @Expect(successPgid > 0, true)
        @Expect(successGone, true)
        @Expect(successGroupGone, true)

        let failureRoot = m5TempRoot("s4b-setup-owner")
        let failurePidPath = failureRoot.join("owner.pid")
        let client = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("malformed-json", "s4b-owner", parentPidPath: Some(failurePidPath.toString())),
            cwd: Some(failureRoot.toString()),
            absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(3000)
        )
        var typedFailure = false
        var failurePid: Int64 = 0
        var failurePgid: Int64 = 0
        var failureGone = false
        var failureGroupGone = false
        try {
            client.start(1000)
            let ownerIdentity = client.debugOwnerIdentityForTest()
            failurePgid = ownerIdentity[2]
            let _ = client.request("initialize", JsonObject(), 100)
        } catch (e: CodexAppServerProtocolException) {
            typedFailure = e.code == -32001 && e.message.contains("malformed_json")
        } finally {
            failurePid = m5ReadPid(failurePidPath)
            try {
                client.close()
            } finally {
                failureGone = m5WaitPidGone(failurePid, 2000)
                failureGroupGone = m5WaitPgidGone(failurePgid, 2000)
                if (!failureGone) { m5KillPid(failurePid) }
                try { remove(failureRoot, recursive: true) } catch (_: Exception) { () }
            }
        }
        let after = managedStdioBroker().debugSnapshotForTest()
        @Expect(typedFailure, true)
        @Expect(failurePid > 0, true)
        @Expect(failurePgid > 0, true)
        @Expect(failureGone, true)
        @Expect(failureGroupGone, true)
        @Expect(after.ownerCount, baseline.ownerCount)
        @Expect(after.readerCount, baseline.readerCount)
        @Expect(after.dispatcherCount, baseline.dispatcherCount)
        @Expect(after.generation, baseline.generation)
        @Expect(after.brokerPid, baseline.brokerPid)
    }

    @TestCase
    public func s4BN1IgnoredInterruptMarksTurnTerminalThenSettlesWithoutLateAnswer(): Unit {
        let root = m5TempRoot("s4b-ignored-late")
        let codex = root.join("codex")
        let pidPath = root.join("owner.pid")
        let latePath = root.join("late-written")
        File.writeTo(codex, (
            "#!/bin/sh\n" +
            "echo $$ > '${pidPath.toString()}'\n" +
            "while IFS= read -r line; do\n" +
            "  if printf '%s' \"$line\" | grep -Eq '\"method\"[[:space:]]*:[[:space:]]*\"initialize\"'; then printf '%s\\n' '{\"id\":1,\"result\":{}}'; fi\n" +
            "  if printf '%s' \"$line\" | grep -Eq '\"method\"[[:space:]]*:[[:space:]]*\"thread/start\"'; then printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"s4b-late-thread\"}}}'; fi\n" +
            "  if printf '%s' \"$line\" | grep -Eq '\"method\"[[:space:]]*:[[:space:]]*\"turn/start\"'; then printf '%s\\n' '{\"id\":3,\"result\":{\"turnId\":\"s4b-late-turn\"}}'; fi\n" +
            "  if printf '%s' \"$line\" | grep -Eq '\"method\"[[:space:]]*:[[:space:]]*\"turn/interrupt\"'; then sleep 0.05; printf '%s\\n' '{\"method\":\"thread/item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"text\":\"late-private-answer\"}}}' '{\"method\":\"turn/completed\",\"params\":{}}'; : > '${latePath.toString()}'; fi\n" +
            "done\n"
        ).toArray())
        let (_chmodCode, _, _) = executeWithOutput("chmod", ["+x", codex.toString()])
        let brokerReady = managedStdioBroker().probeBroker(timeoutMs: 2000)
        @Expect(brokerReady.ok, true)
        if (!brokerReady.ok) { throw Exception("S4B broker warmup failed") }
        m5WarmBrokerDispatcher()
        let baseline = managedStdioBroker().debugSnapshotForTest()
        let absoluteDeadlineMs = codexAppServerAbsoluteDeadlineMs(3000)
        let client = CodexAppServerClient(
            codexBin: codex.toString(), cwd: Some(root.toString()), absoluteDeadlineMs: absoluteDeadlineMs)
        var result = CodexAppServerTurnResult(error: "fixture_not_run")
        var lateWritten = false
        var lateConsumed = false
        var ownerGone = false
        var ownerPid: Int64 = 0
        var ownerPgid: Int64 = 0
        var ownerGroupGone = false
        try {
            result = CodexAppServerSession(client).runTurn(
                root.toString(), "bounded", timeoutMs: 3000, pollMs: 5, absoluteDeadlineMs: absoluteDeadlineMs)
            let observationDeadlineMs = codexAppServerAbsoluteDeadlineMs(200)
            while (true) {
                lateWritten = exists(latePath)
                lateConsumed = client.debugPendingNotificationCountForTest() >= 2
                if (lateWritten && lateConsumed) {
                    break
                }
                let localRemainingMs = codexAppServerTerminalRemainingMs(observationDeadlineMs)
                let globalRemainingMs = codexAppServerTerminalRemainingMs(absoluteDeadlineMs)
                if (localRemainingMs <= 0 || globalRemainingMs <= 800) { break }
                sleep(Duration.millisecond * min(10, min(localRemainingMs, globalRemainingMs - 800)))
            }
            ownerPid = m5ReadPid(pidPath)
            ownerPgid = client.debugOwnerIdentityForTest()[2]
        } finally {
            try {
                client.close()
            } finally {
                ownerGone = m5WaitPidGone(ownerPid, 2000)
                ownerGroupGone = m5WaitPgidGone(ownerPgid, 2000)
                if (!ownerGone) { m5KillPid(ownerPid) }
                try { remove(root, recursive: true) } catch (_: Exception) { () }
            }
        }
        @Expect(result.interrupted, true)
        @Expect(result.completed, false)
        @Expect(result.finalText, "")
        @Expect(result.error, "codex app-server turn timed out")
        @Expect(lateWritten, true)
        @Expect(lateConsumed, true)
        @Expect(ownerGone, true)
        @Expect(ownerPgid > 0, true)
        @Expect(ownerGroupGone, true)
        let after = managedStdioBroker().debugSnapshotForTest()
        @Expect(after.ownerCount, baseline.ownerCount)
        @Expect(after.readerCount, baseline.readerCount)
        @Expect(after.dispatcherCount, baseline.dispatcherCount)
        @Expect(after.generation, baseline.generation)
        @Expect(after.brokerPid, baseline.brokerPid)
    }

    @TestCase
    public func s4BH1ConcurrentCloserAndSetupFailureKillOnlyExactOwnerTree(): Unit {
        let root = m5TempRoot("s4b-concurrent-close")
        let parentPidPath = root.join("parent.pid")
        let childPidPath = root.join("child.pid")
        let brokerReady = managedStdioBroker().probeBroker(timeoutMs: 2000)
        @Expect(brokerReady.ok, true)
        if (!brokerReady.ok) { throw Exception("S4B broker warmup failed") }
        m5WarmBrokerDispatcher()
        let baseline = managedStdioBroker().debugSnapshotForTest()
        let client = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment(
                "hang-tree",
                "s4b-concurrent",
                parentPidPath: Some(parentPidPath.toString()),
                childPidPath: Some(childPidPath.toString())
            ),
            cwd: Some(root.toString()),
            absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(5000)
        )
        var filesReady = false
        var parentPid: Int64 = 0
        var childPid: Int64 = 0
        var parentGone = false
        var childGone = false
        var firstJoined = false
        var secondJoined = false
        var firstReaped = false
        var secondReaped = false
        var firstFuture: Option<Future<Unit>> = None<Future<Unit>>
        var secondFuture: Option<Future<Unit>> = None<Future<Unit>>
        try {
            client.start(1000)
            filesReady = m5WaitPathsExist([parentPidPath, childPidPath], 2000)
            @Expect(filesReady, true)
            if (!filesReady) {
                throw Exception("S4B owner tree identity files missing")
            }
            parentPid = m5ReadPid(parentPidPath)
            childPid = m5ReadPid(childPidPath)
            let first = spawn { client.close() }
            let second = spawn { client.close() }
            firstFuture = Some(first)
            secondFuture = Some(second)
            firstJoined = try { let _ = first.get(Duration.second * 4); true } catch (_: Exception) { false }
            secondJoined = try { let _ = second.get(Duration.second * 4); true } catch (_: Exception) { false }
            firstReaped = firstJoined
            secondReaped = secondJoined
            parentGone = m5WaitPidGone(parentPid, 1000)
            childGone = m5WaitPidGone(childPid, 1000)
        } finally {
            try { client.close() } catch (_: Exception) { () }
            if (!firstReaped) { firstReaped = m5FutureSettled(firstFuture, 1000) }
            if (!secondReaped) { secondReaped = m5FutureSettled(secondFuture, 1000) }
            if (!parentGone) { m5KillPid(parentPid) }
            if (!childGone) { m5KillPid(childPid) }
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
        let after = managedStdioBroker().debugSnapshotForTest()
        @Expect(filesReady, true)
        @Expect(firstJoined, true)
        @Expect(secondJoined, true)
        @Expect(firstReaped, true)
        @Expect(secondReaped, true)
        @Expect(parentGone, true)
        @Expect(childGone, true)
        @Expect(client.isAlive(), false)
        @Expect(after.ownerCount, baseline.ownerCount)
        @Expect(after.readerCount, baseline.readerCount)
        @Expect(after.dispatcherCount, baseline.dispatcherCount)
        @Expect(after.generation, baseline.generation)
        @Expect(after.brokerPid, baseline.brokerPid)

        let missing = CodexAppServerClient(
            codexBin: root.join("missing-codex-app-server").toString(),
            absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(2000)
        )
        var setupFailed = false
        try {
            missing.start(500)
        } catch (_: Exception) {
            setupFailed = true
        } finally {
            missing.close()
        }
        @Expect(setupFailed, true)
        @Expect(missing.isAlive(), false)
        @Expect(managedStdioBroker().debugSnapshotForTest().ownerCount, baseline.ownerCount)

        let unsafeRoot = m5TempRoot("s4b-unsafe-stop")
        let unsafePidPath = unsafeRoot.join("owner.pid")
        let unsafeClient = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("session", "s4b-unsafe", parentPidPath: Some(unsafePidPath.toString())),
            cwd: Some(unsafeRoot.toString()),
            absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(5000)
        )
        let unsafeCode = AtomicInt64(0)
        let waiterCode = AtomicInt64(0)
        var retained = false
        var retryClosed = false
        var retryIdentityCleared = false
        var unsafePid: Int64 = 0
        var unsafePgid: Int64 = 0
        var unsafePidGoneBeforeRetry = false
        var unsafePgidGoneBeforeRetry = false
        var goneBeforeFallback = false
        var closerReaped = false
        var waiterReaped = false
        var closerFuture: Option<Future<Unit>> = None<Future<Unit>>
        var waiterFuture: Option<Future<Unit>> = None<Future<Unit>>
        let stopEntered = AtomicBool(false)
        let waiterEntered = AtomicBool(false)
        let releaseStop = AtomicBool(false)
        try {
            unsafeClient.start(1000)
            let beforeUnsafe = unsafeClient.debugOwnerIdentityForTest()
            unsafePid = beforeUnsafe[1]
            unsafePgid = beforeUnsafe[2]
            let injected = unsafeClient.debugSetPostStopDowngradeForTest(Some("broker_exited"))
            @Expect(injected, true)
            if (!injected) { throw Exception("S4B unsafe stop seam unavailable") }
            unsafeClient.debugSetBeforeStopForTest(Some({ =>
                stopEntered.store(true)
                while (!releaseStop.load()) { sleep(Duration.millisecond) }
            }))
            unsafeClient.debugSetBeforeWaitForCloserForTest(Some({ => waiterEntered.store(true) }))
            let closer = spawn {
                try { unsafeClient.close() } catch (e: CodexAppServerProtocolException) { unsafeCode.store(e.code) }
            }
            closerFuture = Some(closer)
            let stopGateDeadline = codexAppServerAbsoluteDeadlineMs(1000)
            while (!stopEntered.load() && codexAppServerTerminalRemainingMs(stopGateDeadline) > 0) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(stopEntered.load(), true)
            if (!stopEntered.load()) { throw Exception("S4B close gate was not entered") }
            let waiter = spawn {
                try { unsafeClient.close() } catch (e: CodexAppServerProtocolException) { waiterCode.store(e.code) }
            }
            waiterFuture = Some(waiter)
            let waiterGateDeadline = codexAppServerAbsoluteDeadlineMs(1000)
            while (!waiterEntered.load() && codexAppServerTerminalRemainingMs(waiterGateDeadline) > 0) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(waiterEntered.load(), true)
            if (!waiterEntered.load()) { throw Exception("S4B concurrent close waiter was not entered") }
            releaseStop.store(true)
            closerReaped = m5FutureSettled(closerFuture, 2000)
            waiterReaped = m5FutureSettled(waiterFuture, 2000)
            unsafeClient.debugSetBeforeStopForTest(None<() -> Unit>)
            unsafeClient.debugSetBeforeWaitForCloserForTest(None<() -> Unit>)
            let afterUnsafe = unsafeClient.debugOwnerIdentityForTest()
            retained = afterUnsafe[0] == beforeUnsafe[0] && afterUnsafe[0] > 0 && afterUnsafe[1] == 0 &&
                afterUnsafe[2] == 0 && unsafeClient.debugLifecycleForTest() == "cleanup_failed"
            unsafePidGoneBeforeRetry = m5WaitPidGone(unsafePid, 1000)
            unsafePgidGoneBeforeRetry = m5WaitPgidGone(unsafePgid, 1000)
            unsafeClient.close()
            retryClosed = unsafeClient.debugLifecycleForTest() == "closed"
            let retryIdentity = unsafeClient.debugOwnerIdentityForTest()
            retryIdentityCleared = retryIdentity[0] == 0 && retryIdentity[1] == 0 && retryIdentity[2] == 0
        } finally {
            releaseStop.store(true)
            unsafeClient.debugSetBeforeStopForTest(None<() -> Unit>)
            unsafeClient.debugSetBeforeWaitForCloserForTest(None<() -> Unit>)
            let _ = unsafeClient.debugSetPostStopDowngradeForTest(None<String>)
            if (!closerReaped) { closerReaped = m5FutureSettled(closerFuture, 1000) }
            if (!waiterReaped) { waiterReaped = m5FutureSettled(waiterFuture, 1000) }
            try { unsafeClient.close() } catch (_: Exception) { () }
            goneBeforeFallback = m5WaitPidGone(unsafePid, 1000)
            if (!goneBeforeFallback) { m5KillPid(unsafePid) }
            try { remove(unsafeRoot, recursive: true) } catch (_: Exception) { () }
        }
        @Expect(unsafeCode.load(), -32004)
        @Expect(waiterCode.load(), -32004)
        @Expect(closerReaped, true)
        @Expect(waiterReaped, true)
        @Expect(retained, true)
        @Expect(unsafePidGoneBeforeRetry, true)
        @Expect(unsafePgidGoneBeforeRetry, true)
        @Expect(retryClosed, true)
        @Expect(retryIdentityCleared, true)
        @Expect(goneBeforeFallback, true)
        @Expect(managedStdioBroker().debugSnapshotForTest().ownerCount, baseline.ownerCount)
    }

    @TestCase
    public func s4BH3AppServerUtf8DiagnosticsAndTailStayBoundedRedacted(): Unit {
        let parsed = codexAppServerParseStdoutLine("{\"id\":3,\"result\":{\"text\":\"中文🙂\"}}")
        let malformed = codexAppServerParseStdoutLine("{not-json Authorization=private-token 中文🙂")
        let redacted = codexAppServerRedactDiagnostic(
            "Authorization=private-token " + m5RepeatedText(r'中', 512)
        )
        let client = CodexAppServerClient(
            codexBin: m5FakeCodexScript(),
            env: m5FakeCodexEnvironment("stderr-burst", "s4b-tail"),
            absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(5000)
        )
        var result = JsonObject()
        try {
            result = client.request("initialize", JsonObject(), 3000)
        } finally {
            client.close()
        }
        let diagnostics = client.diagnostics().toString()
        @Expect(parsed.kind, "response")
        @Expect(parsed.message.toJsonString().contains("中文🙂"), true)
        @Expect(malformed.kind, "diagnostic")
        @Expect(malformed.diagnostic, "malformed_json")
        @Expect(redacted.contains("private-token"), false)
        @Expect(redacted.size <= 512, true)
        @Expect(m5JsonString(result, "label"), "s4b-tail")
        @Expect(diagnostics.contains("secret-codex-token"), false)
        @Expect(diagnostics.contains("/Users/"), false)
        @Expect(diagnostics.contains("/private/"), false)
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

private func m5FutureSettled<T>(future: Option<Future<T>>, timeoutMs: Int64): Bool {
    match (future) {
        case Some(value) => try { let _ = value.get(Duration.millisecond * timeoutMs); true } catch (_: Exception) { false }
        case None => true
    }
}

private func m5FakeCodexScript(): String {
    canonicalize(Path("scripts").join("gateway-stdio-fake-codex-app-server.mjs")).toString()
}

private func m5WarmBrokerDispatcher(): Unit {
    let before = managedStdioBroker().debugSnapshotForTest()
    let root = m5TempRoot("s4b-dispatcher-warmup")
    let pidPath = root.join("owner.pid")
    let client = CodexAppServerClient(
        codexBin: m5FakeCodexScript(),
        env: m5FakeCodexEnvironment("session", "s4b-dispatcher-warmup", parentPidPath: Some(pidPath.toString())),
        cwd: Some(root.toString()),
        absoluteDeadlineMs: codexAppServerAbsoluteDeadlineMs(3000)
    )
    var pid: Int64 = 0
    var pgid: Int64 = 0
    var pidGone = false
    var pgidGone = false
    try {
        client.start(1000)
        if (!m5WaitPathsExist([pidPath], 1000)) {
            throw Exception("S4B dispatcher warmup pid missing")
        }
        pid = m5ReadPid(pidPath)
        pgid = client.debugOwnerIdentityForTest()[2]
        if (pid <= 0 || pgid <= 0) {
            throw Exception("S4B dispatcher warmup identity missing")
        }
    } finally {
        try {
            client.close()
        } finally {
            pidGone = m5WaitPidGone(pid, 2000)
            pgidGone = m5WaitPgidGone(pgid, 2000)
            if (!pidGone) { m5KillPid(pid) }
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }
    let after = managedStdioBroker().debugSnapshotForTest()
    if (!pidGone || !pgidGone || after.ownerCount != before.ownerCount ||
        after.readerCount != before.readerCount || after.generation != before.generation ||
        after.brokerPid != before.brokerPid || after.dispatcherCount <= 0) {
        throw Exception("S4B dispatcher warmup did not return to broker baseline")
    }
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

private func m5PgidAlive(pgid: Int64): Bool {
    if (pgid <= 0) { return false }
    let (exitCode, _, _) = executeWithOutput("kill", ["-0", "-${pgid}"])
    exitCode == 0
}

private func m5WaitPgidGone(pgid: Int64, timeoutMs: Int64): Bool {
    if (pgid <= 0) { return true }
    let deadline = codexAppServerAbsoluteDeadlineMs(timeoutMs)
    while (codexAppServerTerminalRemainingMs(deadline) > 0) {
        if (!m5PgidAlive(pgid)) { return true }
        sleep(Duration.millisecond * 25)
    }
    !m5PgidAlive(pgid)
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
