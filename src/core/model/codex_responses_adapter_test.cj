package metis.core.model

import metis.core.config.OpenAICodexOAuthTransportConfig

import magic.core.message.Message
import magic.core.model.ChatRequest
import magic.core.tool.{Tool, ToolParameter, ToolResponse}
import magic.jsonable.TypeSchema

import std.collection.{ArrayList, HashMap}
import std.core.Duration
import std.net.*
import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.testmacro.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.*

private var m2CallCount: Int64 = 0
private var m2LastUrl: String = ""
private var m2LastAuth: String = ""
private var m2LastAccept: String = ""
private var m2LastSession: String = ""
private var m2LastRequestBody = JsonObject()

private class M2FakeTool <: Tool {
    public prop name: String {
        get() { "inspect_file" }
    }

    public prop description: String {
        get() { "Inspect a file" }
    }

    public prop parameters: Array<ToolParameter> {
        get() { [ToolParameter("path", "file path", TypeSchema.Str)] }
    }

    public prop retType: TypeSchema {
        get() { TypeSchema.Str }
    }

    public prop examples: Array<String> {
        get() { [] }
    }

    public prop extra: HashMap<String, String> {
        get() { HashMap<String, String>() }
    }

    public func invoke(_args: HashMap<String, JsonValue>): ToolResponse {
        return ToolResponse("ok")
    }

    public func toJsonValue(): JsonValue {
        let properties = JsonObject()
        let path = JsonObject()
        path.put("type", JsonString("string"))
        path.put("description", JsonString("file path"))
        properties.put("path", path)
        let parameters = JsonObject()
        parameters.put("type", JsonString("object"))
        parameters.put("properties", properties)
        let required = JsonArray()
        required.add(JsonString("path"))
        parameters.put("required", required)
        let out = JsonObject()
        out.put("name", JsonString(this.name))
        out.put("description", JsonString(this.description))
        out.put("parameters", parameters)
        return out
    }
}

private func m2String(obj: JsonObject, key: String): String {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asString().getValue()
        }
    } catch (_: Exception) { () }
    return ""
}

private func m2Bool(obj: JsonObject, key: String): Bool {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asBool().getValue()
        }
    } catch (_: Exception) { () }
    return false
}

private func m2Obj(obj: JsonObject, key: String): JsonObject {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asObject()
        }
    } catch (_: Exception) { () }
    return JsonObject()
}

private func m2Arr(obj: JsonObject, key: String): JsonArray {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asArray()
        }
    } catch (_: Exception) { () }
    return JsonArray()
}

private func m2Event(eventType: String): JsonObject {
    let out = JsonObject()
    out.put("type", JsonString(eventType))
    return out
}

private func m2MessageItem(text: String): JsonObject {
    let item = JsonObject()
    item.put("type", JsonString("message"))
    item.put("role", JsonString("assistant"))
    let content = JsonArray()
    let part = JsonObject()
    part.put("type", JsonString("output_text"))
    part.put("text", JsonString(text))
    content.add(part)
    item.put("content", content)
    return item
}

private func m2FunctionCall(name: String, args: String): JsonObject {
    let item = JsonObject()
    item.put("type", JsonString("function_call"))
    item.put("call_id", JsonString("call_1"))
    item.put("name", JsonString(name))
    item.put("arguments", JsonString(args))
    return item
}

private func m2ResponseFromOutput(output: JsonArray): JsonObject {
    let response = JsonObject()
    response.put("model", JsonString("gpt-5.5"))
    response.put("status", JsonString("completed"))
    response.put("output", output)
    return response
}

private func m2ResponseFromOutputText(text: String): JsonObject {
    let response = JsonObject()
    response.put("model", JsonString("gpt-5.5"))
    response.put("status", JsonString("completed"))
    response.put("output_text", JsonString(text))
    return response
}

private func m2CompletedEvent(output: JsonArray): JsonObject {
    let response = JsonObject()
    response.put("model", JsonString("gpt-5.5"))
    response.put("status", JsonString("completed"))
    response.put("output", output)
    let event = m2Event("response.completed")
    event.put("response", response)
    return event
}

private func m2ResetHttpCapture(): Unit {
    m2CallCount = 0
    m2LastUrl = ""
    m2LastAuth = ""
    m2LastAccept = ""
    m2LastSession = ""
    m2LastRequestBody = JsonObject()
}

private func s4AResponsesPayload(): JsonObject {
    let payload = JsonObject()
    payload.put("model", JsonString("gpt-test"))
    payload.put("instructions", JsonString("bounded"))
    let input = JsonArray()
    input.add(m2MessageItem("bounded"))
    payload.put("input", input)
    payload
}

private func s4AResponsesLoopbackClient(): CodexResponsesHttpClient {
    CodexResponsesHttpClient(
        transportConfig: Some(OpenAICodexOAuthTransportConfig(envProxyEnabled: false, timeoutMs: 2000))
    )
}

private class S4ARawHttpReply {
    let status: Int64
    let body: Array<Byte>
    let contentType: String
    let dropWithoutResponse: Bool
    let delayMs: Int64
    let onAccepted: Option<() -> Unit>

    init(
        status: Int64,
        body: Array<Byte>,
        contentType!: String = "application/json",
        dropWithoutResponse!: Bool = false,
        delayMs!: Int64 = 0,
        onAccepted!: Option<() -> Unit> = None<() -> Unit>
    ) {
        this.status = status
        this.body = body
        this.contentType = contentType
        this.dropWithoutResponse = dropWithoutResponse
        this.delayMs = delayMs
        this.onAccepted = onAccepted
    }
}

private class S4AStringTruth {
    var value: String = ""
}

private class S4ARawHttpFixture {
    private let listener = TcpServerSocket(bindAt: 0u16)
    private let replies: Array<S4ARawHttpReply>
    let accepted = AtomicInt64(0)
    let closedByClient = AtomicInt64(0)

    init(replies: Array<S4ARawHttpReply>) {
        this.replies = replies
        this.listener.bind()
    }

    prop port: Int64 {
        get() { Int64((this.listener.localAddress as IPSocketAddress)?.port ?? 0u16) }
    }

    func serve(): Bool {
        for (reply in this.replies) {
            try (client = this.listener.accept(timeout: Some(Duration.second * 3))) {
                this.accepted.fetchAdd(1)
                if (let Some(notify) <- reply.onAccepted) {
                    notify()
                }
                client.readTimeout = Some(Duration.second)
                let request = Array<Byte>(16384, repeat: 0)
                let _ = client.read(request)
                if (reply.delayMs > 0) {
                    sleep(Duration.millisecond * reply.delayMs)
                }
                if (reply.dropWithoutResponse) {
                    continue
                }
                let reason = if (reply.status == 200) { "OK" } else { "Bad Request" }
                let header = "HTTP/1.1 ${reply.status} ${reason}\r\ncontent-type: ${reply.contentType}\r\ncontent-length: ${reply.body.size}\r\nconnection: close\r\n\r\n"
                try {
                    client.write(header.toArray())
                    let split = reply.body.size / 2
                    if (split > 0) {
                        client.write(reply.body[..split])
                        sleep(Duration.millisecond)
                    }
                    client.write(reply.body[split..])
                    let eofProbe = Array<Byte>(1, repeat: 0)
                    if (client.read(eofProbe) <= 0) {
                        this.closedByClient.fetchAdd(1)
                    }
                } catch (_: Exception) {
                    this.closedByClient.fetchAdd(1)
                }
            }
        }
        true
    }

    func close(): Unit {
        this.listener.close()
    }
}

private func s4AWithRawResponsesLoopback<T>(replies: Array<S4ARawHttpReply>, block: (String, S4ARawHttpFixture) -> T): T {
    let fixture = S4ARawHttpFixture(replies)
    @Expect(fixture.port > 0, true)
    @Expect(fixture.port == 18080 || fixture.port == 18788, false)
    if (fixture.port <= 0 || fixture.port == 18080 || fixture.port == 18788) {
        fixture.close()
        throw Exception("S4A owned loopback listener unavailable")
    }
    let serving = spawn { fixture.serve() }
    var expectedClientCloses: Int64 = 0
    for (reply in replies) {
        if (!reply.dropWithoutResponse) {
            expectedClientCloses += 1
        }
    }
    var result = None<T>
    var primaryFailure = None<Exception>
    try {
        result = Some(block("http://127.0.0.1:${fixture.port}", fixture))
    } catch (ex: Exception) {
        primaryFailure = Some(ex)
    }
    var joined = false
    var cleanupFailure = ""
    try {
        fixture.close()
        let served = serving.get(Duration.second * 4)
        joined = true
        let closed = fixture.closedByClient.load()
        @Expect(served, true)
        @Expect(closed, expectedClientCloses)
        if (!served || closed != expectedClientCloses) {
            cleanupFailure = "S4A loopback resource terminal truth failed"
        }
    } catch (_: Exception) {
        cleanupFailure = "S4A loopback resource cleanup failed"
    } finally {
        try {
            fixture.close()
        } catch (_: Exception) {
            if (cleanupFailure.isEmpty()) {
                cleanupFailure = "S4A loopback listener close failed"
            }
        }
        if (!joined) {
            let reaped = try {
                let _ = serving.get(Duration.second * 2)
                true
            } catch (_: Exception) {
                false
            }
            @Expect(reaped, true)
            if (!reaped && cleanupFailure.isEmpty()) {
                cleanupFailure = "S4A loopback server future did not settle"
            }
        }
    }
    if (let Some(ex) <- primaryFailure) {
        throw ex
    }
    if (!cleanupFailure.isEmpty()) {
        throw Exception(cleanupFailure)
    }
    match (result) {
        case Some(value) => value
        case None => throw Exception("S4A loopback block returned no result")
    }
}

private func s4AVerifyChatModelCreateAndAsyncDeadline(): Unit {
        let capturedTimeouts = ArrayList<Int64>()
        let calls = AtomicInt64(0)
        let output = JsonArray()
        output.add(m2MessageItem("bounded"))
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            capturedTimeouts.add(request.timeoutMs)
            calls.fetchAdd(1)
            CodexResponsesHttpResult(200, streamEvents: [m2CompletedEvent(output)])
        }))
        let model = CodexResponsesChatModel(
            "gpt-test",
            "https://api.openai.com/v1",
            "test-token",
            client: CodexResponsesHttpClient()
        )
        try {
            let active = pushModelExecutionRemainingMsScope({ => 37 })
            try {
                @Expect(model.create(ChatRequest("sync")).message.content, "bounded")
                var asyncCode = ""
                try {
                    let _ = model.asyncCreate(ChatRequest("async"))
                } catch (ex: CodexResponsesException) {
                    asyncCode = ex.code
                }
                @Expect(asyncCode, "async_response_factory_unavailable")
            } finally {
                @Expect(popModelExecutionRemainingMsScope(active), true)
            }
            @Expect(currentModelExecutionDeadlineSnapshot().status, "absent")
            @Expect(capturedTimeouts.size, 2)
            @Expect(capturedTimeouts[0], 37)
            @Expect(capturedTimeouts[1], 37)

            let beforeExpired = calls.load()
            let expired = pushModelExecutionRemainingMsScope({ => 0 })
            try {
                for (mode in ["create", "asyncCreate"]) {
                    var code = ""
                    try {
                        if (mode == "create") {
                            let _ = model.create(ChatRequest("expired"))
                        } else {
                            let _ = model.asyncCreate(ChatRequest("expired"))
                        }
                    } catch (ex: CodexResponsesException) {
                        code = ex.code
                    }
                    @Expect(code, "transport_deadline_exhausted")
                }
            } finally {
                @Expect(popModelExecutionRemainingMsScope(expired), true)
            }
            @Expect(calls.load(), beforeExpired)
            @Expect(currentModelExecutionDeadlineSnapshot().status, "absent")
        } finally {
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }
}

@Test
public class CodexResponsesAdapterTest {
    @TestCase
    public func s4AP1LoopbackSyncStreamAndHundredTimeoutsSettleWithoutRetainedGrowth(): Unit {
        s4AVerifyChatModelCreateAndAsyncDeadline()
        let syncBody = "{\"status\":\"completed\",\"model\":\"gpt-test\",\"output_text\":\"同步中文🙂\"}"
        let syncText = s4AWithRawResponsesLoopback([S4ARawHttpReply(200, syncBody.toArray())], { baseUrl, fixture =>
            let response = s4AResponsesLoopbackClient().postResponses(baseUrl, "test-token", s4AResponsesPayload())
            @Expect(fixture.accepted.load(), 1)
            m2String(response, "output_text")
        })
        @Expect(syncText, "同步中文🙂")

        let streamOutput = JsonArray()
        streamOutput.add(m2MessageItem("同步中文🙂"))
        let eventJson = m2CompletedEvent(streamOutput).toJsonString()
        let eventWire = eventJson.replace("\n", "").replace("\r", "")
        @Expect(eventWire.isEmpty(), false)
        @Expect(eventWire.contains("\n") || eventWire.contains("\r"), false)
        if (eventWire.isEmpty() || eventWire.contains("\n") || eventWire.contains("\r")) {
            throw Exception("S4A SSE event wire must be one line")
        }
        let streamText = s4AWithRawResponsesLoopback(
            [S4ARawHttpReply(200, "data: ${eventWire}\n\n".toArray(), contentType: "text/event-stream")],
            { baseUrl, fixture =>
                let content = s4AResponsesLoopbackClient().streamResponses(
                    baseUrl,
                    "test-token",
                    s4AResponsesPayload(),
                    model: "gpt-test"
                ).content
                @Expect(fixture.accepted.load(), 1)
                content
            }
        )
        @Expect(streamText, "同步中文🙂")

        let nativeRetry = s4AWithRawResponsesLoopback(
            [
                S4ARawHttpReply(0, [], dropWithoutResponse: true),
                S4ARawHttpReply(200, "data: ${eventWire}\n\n".toArray(), contentType: "text/event-stream")
            ],
            { baseUrl, fixture =>
                let scope = pushModelExecutionRemainingMsScope({ =>
                    if (fixture.accepted.load() == 0) { 90 } else { 70 }
                })
                try {
                    s4AResponsesLoopbackClient().streamResponses(
                        baseUrl,
                        "test-token",
                        s4AResponsesPayload(),
                        model: "gpt-test"
                    ).content
                } finally {
                    @Expect(popModelExecutionRemainingMsScope(scope), true)
                }
            }
        )
        @Expect(nativeRetry, "同步中文🙂")

        let retryEncoding = S4AStringTruth()
        s4AWithRawResponsesLoopback(
            [
                S4ARawHttpReply(0, [], dropWithoutResponse: true),
                S4ARawHttpReply(200, [0xffu8], contentType: "text/event-stream")
            ],
            { baseUrl, fixture =>
                try {
                    let _ = s4AResponsesLoopbackClient().streamResponses(
                        baseUrl,
                        "test-token",
                        s4AResponsesPayload(),
                        model: "gpt-test"
                    )
                } catch (ex: CodexResponsesException) {
                    retryEncoding.value = ex.code
                }
                @Expect(fixture.accepted.load(), 2)
            }
        )
        @Expect(retryEncoding.value, "invalid_response_encoding")

        resetCodexResponsesHttpRegistryTruthForTest()
        let proxyCode = S4AStringTruth()
        let proxyMessage = S4AStringTruth()
        let proxyClient = CodexResponsesHttpClient(transportConfig: Some(OpenAICodexOAuthTransportConfig(
            proxy: "https://user:secret@127.0.0.1:7897",
            envProxyEnabled: false,
            timeoutMs: 2000,
            proxySource: "test"
        )))
        try {
            let _ = proxyClient.streamResponses(
                "https://api.openai.com/v1",
                "test-token-never-print",
                s4AResponsesPayload(),
                model: "gpt-test"
            )
        } catch (ex: CodexResponsesException) {
            proxyCode.value = ex.code
            proxyMessage.value = ex.message
        }
        @Expect(proxyCode.value, "http_error")
        @Expect(proxyMessage.value.contains("true HTTPS proxy is not implemented"), true)
        @Expect(proxyMessage.value.contains("unsupportedHttpsProxy"), true)
        @Expect(proxyMessage.value.contains("[redacted]@127.0.0.1:7897"), true)
        @Expect(proxyMessage.value.contains("secret"), false)
        @Expect(proxyMessage.value.contains("test-token-never-print"), false)
        let proxyTruth = codexResponsesHttpRegistryTruthForTest()
        @Expect(proxyTruth.registered, 1)
        @Expect(proxyTruth.settled, 1)
        @Expect(proxyTruth.active, 0)
        @Expect(proxyTruth.retained, 0)

        let exhaustedTransport = S4AStringTruth()
        s4AWithRawResponsesLoopback(
            [
                S4ARawHttpReply(0, [], dropWithoutResponse: true),
                S4ARawHttpReply(0, [], dropWithoutResponse: true)
            ],
            { baseUrl, fixture =>
                try {
                    let _ = s4AResponsesLoopbackClient().streamResponses(
                        baseUrl,
                        "test-token",
                        s4AResponsesPayload(),
                        model: "gpt-test"
                    )
                } catch (ex: CodexResponsesException) {
                    exhaustedTransport.value = "${ex.code}:${ex.message}"
                }
                @Expect(fixture.accepted.load(), 2)
            }
        )
        @Expect(exhaustedTransport.value, "stream_transport_error:Codex Responses stream transport failed after retry")

        let nativeTimeoutRemaining = AtomicInt64(20)
        let nativeTimeoutCode = S4AStringTruth()
        s4AWithRawResponsesLoopback(
            [S4ARawHttpReply(
                200,
                syncBody.toArray(),
                delayMs: 50,
                onAccepted: Some({ => nativeTimeoutRemaining.store(0) })
            )],
            { baseUrl, fixture =>
                let timeoutScope = pushModelExecutionRemainingMsScope({ => nativeTimeoutRemaining.load() })
                try {
                    try {
                        let _ = s4AResponsesLoopbackClient().postResponses(
                            baseUrl,
                            "test-token",
                            s4AResponsesPayload()
                        )
                    } catch (ex: CodexResponsesException) {
                        nativeTimeoutCode.value = ex.code
                    }
                    @Expect(fixture.accepted.load(), 1)
                } finally {
                    @Expect(popModelExecutionRemainingMsScope(timeoutScope), true)
                }
            }
        )
        @Expect(nativeTimeoutCode.value, "transport_deadline_exhausted")

        let remaining = AtomicInt64(90)
        let timeouts = ArrayList<Int64>()
        let retryCalls = AtomicInt64(0)
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            timeouts.add(request.timeoutMs)
            if (retryCalls.fetchAdd(1) == 0) {
                remaining.store(70)
                CodexResponsesHttpResult(0, error: "temporary")
            } else {
                CodexResponsesHttpResult(200, streamEvents: [m2CompletedEvent(JsonArray())])
            }
        }))
        let retryScope = pushModelExecutionRemainingMsScope({ => remaining.load() })
        try {
            let _ = CodexResponsesHttpClient().streamResponses(
                "https://api.openai.com/v1",
                "test-token",
                s4AResponsesPayload(),
                model: "gpt-test"
            )
            @Expect(timeouts.size, 2)
            @Expect(timeouts[0], 90)
            @Expect(timeouts[1], 70)
        } finally {
            @Expect(popModelExecutionRemainingMsScope(retryScope), true)
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }

        let syncRemaining = AtomicInt64(90)
        let syncTimeouts = ArrayList<Int64>()
        let syncRetryCalls = AtomicInt64(0)
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            syncTimeouts.add(request.timeoutMs)
            if (syncRetryCalls.fetchAdd(1) == 0) {
                syncRemaining.store(70)
                CodexResponsesHttpResult(400, body: "unsupported parameter: service_tier")
            } else {
                CodexResponsesHttpResult(200, body: "{\"status\":\"completed\",\"output\":[]}")
            }
        }))
        let syncRetryPayload = s4AResponsesPayload()
        syncRetryPayload.put("service_tier", JsonString("priority"))
        let syncRetryScope = pushModelExecutionRemainingMsScope({ => syncRemaining.load() })
        try {
            let _ = CodexResponsesHttpClient().postResponses(
                "https://api.openai.com/v1",
                "test-token",
                syncRetryPayload
            )
            @Expect(syncTimeouts.size, 2)
            @Expect(syncTimeouts[0], 90)
            @Expect(syncTimeouts[1], 70)
        } finally {
            @Expect(popModelExecutionRemainingMsScope(syncRetryScope), true)
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }

        resetCodexResponsesHttpRegistryTruthForTest()
        let retainedBefore = codexResponsesHttpRegistryTruthForTest()
        @Expect(retainedBefore.active, 0)
        @Expect(retainedBefore.retained, 0)
        let startedTimeouts = AtomicInt64(0)
        let releasedTimeouts = AtomicInt64(0)
        let timeoutReplies = ArrayList<S4ARawHttpReply>()
        for (_ in 0..100) {
            timeoutReplies.add(S4ARawHttpReply(
                200,
                "{\"status\":\"completed\",\"output\":[]}".toArray(),
                onAccepted: Some({ =>
                    let ordinal = startedTimeouts.fetchAdd(1) + 1
                    while (releasedTimeouts.load() < ordinal) {
                        sleep(Duration.millisecond)
                    }
                })
            ))
        }
        try {
            s4AWithRawResponsesLoopback(timeoutReplies.toArray(), { baseUrl, _ =>
                for (i in 0..100) {
                    let remainingTimeout = AtomicInt64(500)
                    let timedCall = spawn {
                        let scope = pushModelExecutionRemainingMsScope({ => remainingTimeout.load() })
                        try {
                            try {
                                let _ = s4AResponsesLoopbackClient().postResponses(
                                    baseUrl,
                                    "test-token",
                                    s4AResponsesPayload()
                                )
                                "unexpected_success"
                            } catch (ex: CodexResponsesException) {
                                ex.code
                            }
                        } finally {
                            let _ = popModelExecutionRemainingMsScope(scope)
                        }
                    }
                    var polls: Int64 = 0
                    while (startedTimeouts.load() < Int64(i + 1) && polls < 2000) {
                        sleep(Duration.millisecond)
                        polls += 1
                    }
                    @Expect(startedTimeouts.load(), Int64(i + 1))
                    if (startedTimeouts.load() != Int64(i + 1)) {
                        remainingTimeout.store(0)
                        releasedTimeouts.store(Int64(i + 1))
                        let _ = try { timedCall.get(Duration.second) } catch (_: Exception) { "reap_failed" }
                        throw Exception("S4A controlled timeout did not start")
                    }
                    let inFlight = codexResponsesHttpRegistryTruthForTest()
                    @Expect(inFlight.active, 1)
                    @Expect(inFlight.retained, 1)
                    remainingTimeout.store(0)
                    releasedTimeouts.store(Int64(i + 1))
                    var joined = false
                    try {
                        @Expect(timedCall.get(Duration.second * 2), "transport_deadline_exhausted")
                        joined = true
                    } finally {
                        remainingTimeout.store(0)
                        releasedTimeouts.store(Int64(i + 1))
                        if (!joined) {
                            let reaped = try {
                                let _ = timedCall.get(Duration.second * 2)
                                true
                            } catch (_: Exception) {
                                false
                            }
                            @Expect(reaped, true)
                            if (!reaped) {
                                throw Exception("S4A controlled timeout future did not settle")
                            }
                        }
                    }
                }
            })
            let truth = codexResponsesHttpRegistryTruthForTest()
            @Expect(truth.registered, 100)
            @Expect(truth.settled, 100)
            @Expect(truth.active, 0)
            @Expect(truth.retained, 0)
            @Expect(truth.maxActive, 1)
        } finally {
            resetCodexResponsesHttpRegistryTruthForTest()
        }
    }

    @TestCase
    public func s4AN1LateHttpResultSettlesAfterTurnTerminalWithoutBusinessEffect(): Unit {
        let started = AtomicBool(false)
        let release = AtomicBool(false)
        let remaining = AtomicInt64(20)
        resetCodexResponsesHttpRegistryTruthForTest()
        setCodexResponsesHttpRunnerForTest(Some({ _: CodexResponsesHttpRequest =>
            started.store(true)
            while (!release.load()) {
                sleep(Duration.millisecond)
            }
            CodexResponsesHttpResult(200, body: "{\"status\":\"completed\",\"output_text\":\"late-private\"}")
        }))
        let call = spawn {
            let scope = pushModelExecutionRemainingMsScope({ => remaining.load() })
            try {
                try {
                    let _ = CodexResponsesHttpClient().postResponses(
                        "https://api.openai.com/v1",
                        "test-token",
                        s4AResponsesPayload()
                    )
                    "unexpected_success"
                } catch (ex: CodexResponsesException) {
                    ex.code
                }
            } finally {
                let _ = popModelExecutionRemainingMsScope(scope)
            }
        }
        var joined = false
        try {
            var polls: Int64 = 0
            while (!started.load() && polls < 1000) {
                sleep(Duration.millisecond)
                polls += 1
            }
            @Expect(started.load(), true)
            let inFlight = codexResponsesHttpRegistryTruthForTest()
            @Expect(inFlight.active, 1)
            @Expect(inFlight.retained, 1)
            @Expect(inFlight.registered, 1)
            @Expect(inFlight.settled, 0)
            remaining.store(0)
            release.store(true)
            let terminal = call.get(Duration.second * 2)
            joined = true
            @Expect(terminal, "transport_deadline_exhausted")
            let truth = codexResponsesHttpRegistryTruthForTest()
            @Expect(truth.active, 0)
            @Expect(truth.retained, 0)
            @Expect(truth.registered, 1)
            @Expect(truth.settled, 1)
        } finally {
            release.store(true)
            if (!joined) {
                let reaped = try {
                    let _ = call.get(Duration.second * 2)
                    true
                } catch (_: Exception) {
                    false
                }
                @Expect(reaped, true)
                if (!reaped) {
                    throw Exception("S4A late transport future did not settle")
                }
            }
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
            resetCodexResponsesHttpRegistryTruthForTest()
        }
    }

    @TestCase
    public func s4AH3LoopbackUnicodeEmojiInvalidUtf8AndClientCloseAreDeterministic(): Unit {
        let body = "{\"status\":\"completed\",\"model\":\"gpt-test\",\"output_text\":\"中文🙂\"}"
        let content = s4AWithRawResponsesLoopback([S4ARawHttpReply(200, body.toArray())], { baseUrl, fixture =>
            let text = m2String(s4AResponsesLoopbackClient().postResponses(baseUrl, "test-token", s4AResponsesPayload()), "output_text")
            @Expect(fixture.accepted.load(), 1)
            text
        })
        @Expect(content, "中文🙂")
        let code = S4AStringTruth()
        s4AWithRawResponsesLoopback([S4ARawHttpReply(200, [0xffu8])], { baseUrl, fixture =>
            try {
                let _ = s4AResponsesLoopbackClient().postResponses(baseUrl, "test-token", s4AResponsesPayload())
            } catch (ex: CodexResponsesException) {
                code.value = ex.code
            }
            @Expect(fixture.accepted.load(), 1)
        })
        @Expect(code.value, "invalid_response_encoding")
        @Expect(codexResponsesHttpRegistryTruthForTest().active, 0)
    }

    @TestCase
    public func m3N5ResponsesUsesCronRemainingTransportDeadlineAndClearsThreadScope(): Unit {
        let captured = JsonObject()
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            captured.put("timeoutMs", JsonInt(request.timeoutMs))
            CodexResponsesHttpResult(200, body: "{\"status\":\"completed\",\"output\":[]}")
        }))
        try {
            pushModelExecutionRemainingMs({ => 37 })
            let payload = JsonObject()
            payload.put("model", JsonString("gpt-test"))
            payload.put("instructions", JsonString("return a test response"))
            let input = JsonArray()
            input.add(m2MessageItem("test input"))
            payload.put("input", input)
            let _ = CodexResponsesHttpClient().postResponses(
                "https://api.openai.com/v1",
                "test-token",
                payload
            )
            @Expect(captured.get("timeoutMs").getOrThrow().asInt().getValue(), 37)
        } finally {
            popModelExecutionRemainingMs()
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }
        @Expect(currentModelExecutionRemainingMs(), 0)
    }

    @TestCase
    public func m2U1PayloadBuilderMapsMessagesImagesToolsAndUnknownTools(): Unit {
        let request = ChatRequest(
            [
                Message.system("system rules"),
                Message.user("look", image: Some("data:image/png;base64,AAAA")),
                Message.assistant("done")
            ],
            tools: [M2FakeTool()]
        )
        let payload = codexBuildResponsesPayload("gpt-5.5", request, options: CodexResponsesBuildOptions(sessionId: "session-a"))
        @Expect(m2String(payload, "instructions"), "system rules")
        @Expect(m2Bool(payload, "store"), false)
        @Expect(m2String(payload, "prompt_cache_key"), "session-a")
        @Expect(m2Arr(payload, "input").size(), 2)
        let firstInput = m2Arr(payload, "input")[0].asObject()
        @Expect(firstInput.get("type").isNone(), true)
        let firstContent = m2Arr(firstInput, "content")
        @Expect(m2String(firstContent[0].asObject(), "type"), "input_text")
        @Expect(m2String(firstContent[1].asObject(), "type"), "input_image")
        let assistantInput = m2Arr(payload, "input")[1].asObject()
        @Expect(assistantInput.get("type").isNone(), true)
        @Expect(m2String(assistantInput, "content"), "done")
        let tool = m2Arr(payload, "tools")[0].asObject()
        @Expect(m2String(tool, "type"), "function")
        @Expect(m2String(tool, "name"), "inspect_file")
        @Expect(m2Bool(tool, "strict"), false)
        @Expect(m2String(payload, "tool_choice"), "auto")
        @Expect(m2Bool(payload, "parallel_tool_calls"), true)

        let rawTools = JsonArray()
        let unknown = JsonObject()
        unknown.put("type", JsonString("web_search"))
        rawTools.add(unknown)
        let valid = JsonObject()
        valid.put("type", JsonString("function"))
        valid.put("function", M2FakeTool().toJsonValue())
        rawTools.add(valid)
        @Expect(codexJsonToolsToResponsesTools(rawTools).size(), 1)

        let textOnly = codexBuildResponsesPayload("gpt-5.5", ChatRequest("hello"))
        let textOnlyInput = m2Arr(textOnly, "input")[0].asObject()
        @Expect(textOnlyInput.get("type").isNone(), true)
        @Expect(m2String(textOnlyInput, "content"), "hello")
    }

    @TestCase
    public func m2U2B1B4NormalizeMessagesToolsReasoningAndErrors(): Unit {
        let output = JsonArray()
        let tmp = JsonObject()
        tmp.put("type", JsonString("reasoning"))
        tmp.put("id", JsonString("rs_tmp_1"))
        tmp.put("encrypted_content", JsonString("tmp-secret"))
        output.add(tmp)
        let reasoning = JsonObject()
        reasoning.put("type", JsonString("reasoning"))
        reasoning.put("id", JsonString("rs_1"))
        reasoning.put("encrypted_content", JsonString("cipher"))
        let summary = JsonArray()
        let summaryText = JsonObject()
        summaryText.put("text", JsonString("why"))
        summary.add(summaryText)
        reasoning.put("summary", summary)
        output.add(reasoning)
        output.add(m2MessageItem("hello"))
        output.add(m2FunctionCall("inspect_file", "{\"path\":\"README.md\"}"))
        let custom = JsonObject()
        custom.put("type", JsonString("custom_tool_call"))
        custom.put("name", JsonString("shell"))
        custom.put("input", JsonString("{\"cmd\":\"pwd\"}"))
        output.add(custom)
        let response = JsonObject()
        response.put("model", JsonString("gpt-5.5"))
        response.put("status", JsonString("completed"))
        response.put("output", output)

        let normalized = codexNormalizeResponses(response)
        @Expect(normalized.content.contains("hello"), true)
        @Expect(normalized.toolRequests.size, 2)
        @Expect(normalized.toolRequests[0].name, "inspect_file")
        @Expect(normalized.reasoningItems.size(), 1)
        @Expect(m2String(normalized.reasoningItems[0].asObject(), "_issuer_kind"), "codex_backend")
        @Expect(normalized.finishReason, "tool_calls")

        let fallback = JsonObject()
        fallback.put("model", JsonString("gpt-5.5"))
        fallback.put("status", JsonString("completed"))
        fallback.put("output", JsonArray())
        fallback.put("output_text", JsonString("fallback text"))
        @Expect(codexNormalizeResponses(fallback).content, "fallback text")

        let failed = JsonObject()
        failed.put("status", JsonString("failed"))
        let err = JsonObject()
        err.put("code", JsonString("bad_request"))
        err.put("message", JsonString("bad"))
        failed.put("error", err)
        var failedCode = ""
        try {
            let _ = codexNormalizeResponses(failed)
        } catch (ex: CodexResponsesException) {
            failedCode = ex.code
        }
        @Expect(failedCode, "bad_request")
    }

    @TestCase
    public func r1U001StructuredFunctionCallStillReturnsToolCalls(): Unit {
        let output = JsonArray()
        output.add(m2FunctionCall("search", "{\"query\":\"cangjie\"}"))
        let normalized = codexNormalizeResponses(m2ResponseFromOutput(output))
        @Expect(normalized.toolRequests.size, 1)
        @Expect(normalized.toolRequests[0].name, "search")
        @Expect(normalized.finishReason, "tool_calls")
    }

    @TestCase
    public func r1U002LeakedToolProtocolTextBecomesIncompleteAndRedacted(): Unit {
        let normalized = codexNormalizeResponses(
            m2ResponseFromOutputText("assistant to=functions.search {\"query\":\"cangjie\"}")
        )
        @Expect(normalized.toolRequests.size, 0)
        @Expect(normalized.finishReason, "incomplete")
        @Expect(normalized.content.contains("functions.search"), false)
    }

    @TestCase
    public func r1B001OrdinaryChineseAndJsonDraftsAreNotMisclassified(): Unit {
        let chineseDraft = "这是普通中文草稿，提到工具二字，但不是工具调用协议。"
        let normalizedChinese = codexNormalizeResponses(m2ResponseFromOutputText(chineseDraft))
        @Expect(normalizedChinese.finishReason, "stop")
        @Expect(normalizedChinese.content, chineseDraft)

        let jsonDraft = "{\"summary\":\"这是普通 JSON 草稿\",\"tool\":\"普通工具说明\"}"
        let normalizedJson = codexNormalizeResponses(m2ResponseFromOutputText(jsonDraft))
        @Expect(normalizedJson.finishReason, "stop")
        @Expect(normalizedJson.content, jsonDraft)
    }

    @TestCase
    public func r1B002ProviderIncompleteKeepsOrdinaryContent(): Unit {
        let response = m2ResponseFromOutputText("普通未完成响应片段")
        response.put("status", JsonString("incomplete"))
        let normalized = codexNormalizeResponses(response)
        @Expect(normalized.finishReason, "incomplete")
        @Expect(normalized.content, "普通未完成响应片段")
    }

    @TestCase
    public func m2U3U5U6HistoryProviderDataRoundTripAndSanitize(): Unit {
        let messages = JsonArray()
        let assistant = JsonObject()
        assistant.put("role", JsonString("assistant"))
        let reasoningItems = JsonArray()
        let same = JsonObject()
        same.put("type", JsonString("reasoning"))
        same.put("id", JsonString("rs_same"))
        same.put("encrypted_content", JsonString("cipher"))
        same.put("_issuer_kind", JsonString("codex_backend"))
        reasoningItems.add(same)
        let cross = JsonObject()
        cross.put("type", JsonString("reasoning"))
        cross.put("id", JsonString("rs_cross"))
        cross.put("encrypted_content", JsonString("cipher2"))
        cross.put("_issuer_kind", JsonString("xai_responses"))
        reasoningItems.add(cross)
        assistant.put("codex_reasoning_items", reasoningItems)
        assistant.put("call_id", JsonString("private-call"))
        assistant.put("_private", JsonString("private"))
        messages.add(assistant)

        let replay = codexMessagesToResponsesInput(messages, currentIssuerKind: "codex_backend")
        @Expect(replay.size(), 1)
        @Expect(m2String(replay[0].asObject(), "encrypted_content"), "cipher")
        @Expect(replay[0].asObject().get("_issuer_kind").isNone(), true)
        @Expect(replay[0].asObject().get("id").isNone(), true)

        let encoded = codexEncodeProviderData(reasoningItems, JsonArray())
        let decoded = codexDecodeProviderData(encoded.toJsonString())
        @Expect(m2Arr(decoded, "codex_reasoning_items").size(), 2)
        @Expect(m2Arr(codexDecodeProviderData("not-json"), "codex_reasoning_items").size(), 0)

        let clean = codexSanitizeHistoryForProvider("openai", "chat_completions", messages)
        let cleanMsg = clean[0].asObject()
        @Expect(cleanMsg.get("codex_reasoning_items").isNone(), true)
        @Expect(cleanMsg.get("call_id").isNone(), true)
        @Expect(cleanMsg.get("_private").isNone(), true)
        @Expect(m2String(cleanMsg, "role"), "assistant")
    }

    @TestCase
    public func m2U7U8U9N3PolicyAndOptionsAreDeterministic(): Unit {
        let payload = JsonObject()
        payload.put("model", JsonString("gpt-5.5"))
        payload.put("max_output_tokens", JsonInt(123))
        payload.put("service_tier", JsonString("priority"))
        let codexMerged = codexMergeResponsesRequestOptions(payload, providerId: "openai-codex", model: "gpt-5.5", isCodexBackend: true, serviceTier: "priority")
        @Expect(codexMerged.get("max_output_tokens").isNone(), true)
        @Expect(m2String(codexMerged, "service_tier"), "priority")
        let xaiMerged = codexMergeResponsesRequestOptions(payload, providerId: "xai", model: "grok", isCodexBackend: false, isXaiResponses: true, serviceTier: "priority")
        @Expect(xaiMerged.get("service_tier").isNone(), true)
        let fastMerged = codexMergeResponsesRequestOptions(payload, providerId: "openai", model: "gpt-5.5", isCodexBackend: false, globalFastMode: true, serviceTier: "priority")
        @Expect(fastMerged.get("service_tier").isNone(), true)

        let kwargs = JsonObject()
        kwargs.put("instructions", JsonString("x"))
        kwargs.put("input", JsonArray())
        kwargs.put("store", JsonBool(false))
        kwargs.put("timeout", JsonInt(90))
        kwargs.put("temperature", JsonFloat(0.2))
        kwargs.put("headers", JsonObject())
        let sanitized = codexSanitizeRequestKwargsForProvider("openai", kwargs)
        @Expect(sanitized.get("instructions").isNone(), true)
        @Expect(sanitized.get("input").isNone(), true)
        @Expect(sanitized.get("timeout").isSome(), true)
        @Expect(sanitized.get("temperature").isSome(), true)

        let messages = JsonArray()
        let system = JsonObject()
        system.put("role", JsonString("system"))
        system.put("content", JsonString("rules"))
        messages.add(system)
        let chatPolicy = codexApplyPromptPolicy(messages, "chat_completions", "gpt-5.5")
        @Expect(m2String(chatPolicy[0].asObject(), "role"), "developer")
        @Expect(m2String(chatPolicy[0].asObject(), "content").contains("Use available tools"), true)
        let responsesPolicy = codexApplyPromptPolicy(messages, "codex_responses", "gpt-5.5")
        @Expect(m2String(responsesPolicy[0].asObject(), "role"), "system")

        @Expect(codexContinuationNeeded("Inspect the repo files", "I'll inspect the repository now.", 0), true)
        @Expect(codexContinuationNeeded("Inspect the repo files", "Done.", 1), false)
        @Expect(codexContinuationPrompt("promise", 1).contains("Continuation 1/2"), true)
    }

    @TestCase
    public func m2U4B2B5StreamEventsWatchdogsAndTerminalFallbacks(): Unit {
        let delta1 = m2Event("response.output_text.delta")
        delta1.put("delta", JsonString("hel"))
        let delta2 = m2Event("response.output_text.delta")
        delta2.put("delta", JsonString("lo"))
        let synthesized = codexNormalizeResponsesEvents([delta1, delta2], model: "gpt-5.5")
        @Expect(synthesized.content, "hello")

        var missingCode = ""
        try {
            let _ = codexNormalizeResponsesEvents([], model: "gpt-5.5")
        } catch (ex: CodexResponsesException) {
            missingCode = ex.code
        }
        @Expect(missingCode, "missing_terminal")

        let done = m2Event("response.output_item.done")
        done.put("item", m2FunctionCall("inspect_file", "{\"path\":\"README.md\"}"))
        let terminal = m2CompletedEvent(JsonArray())
        let withTool = codexNormalizeResponsesEvents([done, terminal], model: "gpt-5.5")
        @Expect(withTool.toolRequests.size, 1)

        @Expect(codexResponsesWatchdogDecision([]).closeReason, "codex_ttfb_kill")
        let first = m2Event("response.created")
        first.put("delay_seconds", JsonFloat(1.0))
        let idle = m2Event("response.output_text.delta")
        idle.put("gap_seconds", JsonFloat(60.0))
        @Expect(codexResponsesWatchdogDecision([first, idle], idleTimeoutSeconds: 45.0).closeReason, "codex_stream_idle_kill")
        @Expect(codexResponsesRunStreamWithWatchdog([first]).statusCode, 200)
    }

    @TestCase
    public func r1P001ChatModelContinuesAfterLeakedProtocolText(): Unit {
        m2ResetHttpCapture()
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            m2CallCount += 1
            m2LastRequestBody = request.body
            let output = JsonArray()
            if (m2CallCount == 1) {
                output.add(m2MessageItem("assistant to=functions.search {\"query\":\"cangjie\"}"))
            } else {
                output.add(m2MessageItem("最终答复"))
            }
            CodexResponsesHttpResult(200, streamEvents: [m2CompletedEvent(output)])
        }))
        try {
            let model = CodexResponsesChatModel("gpt-5.5", "https://chatgpt.example/backend", "test-token", sessionId: "session-a")
            let response = model.create(ChatRequest("请检索仓颉文档", tools: [M2FakeTool()]))
            @Expect(response.message.content, "最终答复")
            @Expect(response.toolRequests.size, 0)
            @Expect(m2CallCount, 2)
        } finally {
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }
    }

    @TestCase
    public func r1N001ChatModelThrowsWhenLeakedProtocolDoesNotConverge(): Unit {
        m2ResetHttpCapture()
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            m2CallCount += 1
            m2LastRequestBody = request.body
            let output = JsonArray()
            output.add(m2MessageItem("assistant to=functions.search {\"query\":\"cangjie\"}"))
            CodexResponsesHttpResult(200, streamEvents: [m2CompletedEvent(output)])
        }))
        var code = ""
        try {
            let model = CodexResponsesChatModel("gpt-5.5", "https://chatgpt.example/backend", "test-token", sessionId: "session-a")
            let _ = model.create(ChatRequest("请检索仓颉文档", tools: [M2FakeTool()]))
        } catch (ex: CodexResponsesException) {
            code = ex.code
        } finally {
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }
        @Expect(code, "tool_protocol_unfinalized")
        @Expect(m2CallCount, 3)
    }

    @TestCase
    public func m2P1N1N2U10HttpClientPreflightRetriesAndNoTokenLeak(): Unit {
        m2ResetHttpCapture()
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            m2CallCount += 1
            m2LastUrl = request.url
            m2LastAuth = request.headers.get("Authorization").getOrThrow()
            m2LastAccept = request.headers.get("Accept").getOrThrow()
            m2LastSession = request.headers.get("session_id").getOrThrow()
            m2LastRequestBody = request.body
            let output = JsonArray()
            output.add(m2MessageItem("model ok"))
            CodexResponsesHttpResult(200, streamEvents: [m2CompletedEvent(output)])
        }))
        try {
            let model = CodexResponsesChatModel("gpt-5.5", "https://chatgpt.example/backend", "test-token", sessionId: "session-a")
            let response = model.create(ChatRequest("hello"))
            @Expect(response.message.content, "model ok")
            @Expect(m2LastUrl, "https://chatgpt.example/backend/responses")
            @Expect(m2LastAuth, "Bearer test-token")
            @Expect(m2LastAccept, "text/event-stream")
            @Expect(m2LastSession, "session-a")
            @Expect(m2String(m2LastRequestBody, "model"), "gpt-5.5")
            @Expect(m2Bool(m2LastRequestBody, "stream"), true)
        } finally {
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }

        let client = CodexResponsesHttpClient()
        let payload = JsonObject()
        payload.put("model", JsonString("gpt-5.5"))
        payload.put("instructions", JsonString("rules"))
        let input = JsonArray()
        input.add(m2MessageItem("hello"))
        payload.put("input", input)
        payload.put("store", JsonBool(false))
        var missingTokenMessage = ""
        try {
            let _ = client.postResponses("https://base", "", payload)
        } catch (ex: CodexResponsesException) {
            missingTokenMessage = ex.message
        }
        @Expect(missingTokenMessage.contains("test-token"), false)

        m2ResetHttpCapture()
        payload.put("service_tier", JsonString("priority"))
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            m2CallCount += 1
            m2LastRequestBody = request.body
            if (m2CallCount == 1) {
                CodexResponsesHttpResult(400, body: "unsupported parameter: service_tier")
            } else {
                CodexResponsesHttpResult(200, body: "{\"model\":\"gpt-5.5\",\"status\":\"completed\",\"output_text\":\"retry ok\"}")
            }
        }))
        try {
            @Expect(m2String(client.postResponses("https://base", "test-token", payload), "output_text"), "retry ok")
            @Expect(m2CallCount, 2)
            @Expect(m2LastRequestBody.get("service_tier").isNone(), true)
        } finally {
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }

        @Expect(codexClassifyResponsesError(401, "bad"), "auth_error")
        @Expect(codexClassifyResponsesError(429, "slow"), "rate_limit")
        @Expect(codexClassifyResponsesError(500, "boom"), "server_error")
        @Expect(codexClassifyResponsesError(400, "invalid image format"), "image_rejection")
        @Expect(codexClassifyResponsesError(400, "invalid_encrypted_content"), "invalid_encrypted_content")
    }

    @TestCase
    public func m2P3P4P5P6N6U11U12U13AuxiliaryHeadersAndTimeouts(): Unit {
        @Expect(codexAuxiliaryProviderChain(["openai", "openai-codex", "anthropic"]).contains("openai-codex"), false)
        let pool = JsonArray()
        let expired = JsonObject()
        expired.put("token", JsonString("expired-token"))
        expired.put("expired", JsonBool(true))
        pool.add(expired)
        let fresh = JsonObject()
        fresh.put("token", JsonString("fresh-token"))
        fresh.put("expired", JsonBool(false))
        pool.add(fresh)
        let decision = codexAuxiliaryClientDecision(
            "openai-codex",
            explicitModel: "gpt-5.5",
            tokenPool: pool,
            singletonToken: "singleton",
            customEndpoint: "https://custom",
            apiMode: "codex_responses"
        )
        @Expect(decision.available, true)
        @Expect(decision.clientKind, "wrapped_codex_responses")
        @Expect(decision.reason, "pool_token")
        @Expect(codexAuxiliaryClientDecision("openai-codex", explicitModel: "").available, false)
        @Expect(codexAuxiliaryClientDecision("openai", explicitModel: "").reason, "codex_not_in_auto_chain")
        @Expect(codexAuxiliaryClientDecision("openai-codex", explicitModel: "gpt-5.5", singletonToken: "s", rawCodex: true).clientKind, "raw_codex")
        @Expect(codexAuxiliaryRecoveryAction("auth_error"), "refresh_once_rebuild")
        @Expect(codexAuxiliaryRecoveryAction("rate_limit"), "rotate_same_provider_pool")
        @Expect(codexAuxiliaryRecoveryAction("timeout"), "evict_sync_async_wrapper_cache")

        let jwtPayload = "{\"https://api.openai.com/auth.chatgpt_account_id\":\"acct_123\"}"
        let token = "head.${toBase64String(jwtPayload.toArray())}.sig"
        let headers = codexCloudflareHeaders(token)
        @Expect(m2String(headers, "originator"), "codex_cli_rs")
        @Expect(m2String(headers, "User-Agent").startsWith("codex_cli_rs/"), true)
        @Expect(m2String(headers, "ChatGPT-Account-ID"), "acct_123")
        @Expect(codexCloudflareHeaders("bad-token").get("ChatGPT-Account-ID").isNone(), true)

        let small = JsonObject()
        small.put("input", JsonString("tiny"))
        @Expect(codexNonStreamStaleTimeoutSeconds(small), 90.0)
        @Expect(codexNonStreamStaleTimeoutSeconds(small, modelTimeoutSeconds: 12.0), 12.0)
        @Expect(codexNonStreamStaleTimeoutSeconds(small, providerTimeoutSeconds: 13.0), 13.0)
        @Expect(codexNonStreamStaleTimeoutSeconds(small, envTimeoutSeconds: 14.0), 14.0)
        @Expect(codexNonStreamStaleTimeoutSeconds(small, baseUrl: "http://127.0.0.1:8080") > 1000000.0, true)
        @Expect(codexSilentHangHint("codex_responses", "openai-codex", "gpt-5.5").contains("gpt-5.4"), true)
        @Expect(codexSilentHangHint("chat_completions", "openai-codex", "gpt-5.5"), "")
    }

    @TestCase
    public func m2N7PreflightRejectsUserTypeMessageInput(): Unit {
        let payload = JsonObject()
        payload.put("model", JsonString("gpt-5.5"))
        payload.put("instructions", JsonString("rules"))
        payload.put("store", JsonBool(false))
        let input = JsonArray()
        let badUserMessage = JsonObject()
        badUserMessage.put("type", JsonString("message"))
        badUserMessage.put("role", JsonString("user"))
        let content = JsonArray()
        let text = JsonObject()
        text.put("type", JsonString("input_text"))
        text.put("text", JsonString("hello"))
        content.add(text)
        badUserMessage.put("content", content)
        input.add(badUserMessage)
        payload.put("input", input)

        var code = ""
        try {
            let _ = codexPreflightResponsesPayload(payload)
        } catch (ex: CodexResponsesException) {
            code = ex.code
        }
        @Expect(code, "invalid_input")
    }
}
