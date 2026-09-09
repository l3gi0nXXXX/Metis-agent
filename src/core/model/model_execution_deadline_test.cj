package metis.core.model

import std.core.Duration
import std.sync.AtomicBool
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

@Test
public class ModelExecutionDeadlineTest {
    @TestCase
    public func s4AU1DeadlineScopeAbsentExpiredNestedAndCrossThreadRestore(): Unit {
        @Expect(currentModelExecutionDeadlineSnapshot().status, "absent")
        let outer = pushModelExecutionRemainingMsScope({ => 50 })
        try {
            @Expect(currentModelExecutionDeadlineSnapshot().status, "active")
            @Expect(currentModelExecutionRemainingMs(), 50)
            let inner = pushModelExecutionRemainingMsScope({ => 20 })
            try {
                @Expect(currentModelExecutionRemainingMs(), 20)
                @Expect(popModelExecutionRemainingMsScope(outer), false)
                let wrongThread = spawn { popModelExecutionRemainingMsScope(inner) }
                @Expect(wrongThread.get(Duration.second), false)
                @Expect(currentModelExecutionRemainingMs(), 20)
            } finally {
                @Expect(popModelExecutionRemainingMsScope(inner), true)
            }
            @Expect(currentModelExecutionRemainingMs(), 50)
        } finally {
            @Expect(popModelExecutionRemainingMsScope(outer), true)
        }
        @Expect(currentModelExecutionDeadlineSnapshot().status, "absent")

        let expired = pushModelExecutionRemainingMsScope({ => 0 })
        try {
            @Expect(currentModelExecutionDeadlineSnapshot().status, "expired")
            @Expect(currentModelExecutionRemainingMs(), 0)
        } finally {
            @Expect(popModelExecutionRemainingMsScope(expired), true)
        }
        let failed = pushModelExecutionRemainingMsScope({ => throw Exception("private deadline source") })
        try {
            @Expect(currentModelExecutionDeadlineSnapshot().status, "expired")
        } finally {
            @Expect(popModelExecutionRemainingMsScope(failed), true)
        }
    }

    @TestCase
    public func s4AB1ZeroNegativeOneMsAndOverflowNeverSendUnbounded(): Unit {
        let calls = AtomicBool(false)
        setCodexResponsesHttpRunnerForTest(Some({ request: CodexResponsesHttpRequest =>
            calls.store(true)
            CodexResponsesHttpResult(200, body: "{\"status\":\"completed\",\"output\":[]}")
        }))
        try {
            for (remaining in [0, -1]) {
                let scope = pushModelExecutionRemainingMsScope({ => remaining })
                try {
                    var code = ""
                    try {
                        let _ = CodexResponsesHttpClient().postResponses(
                            "https://api.openai.com/v1",
                            "test-token",
                            s4ADeadlinePayload()
                        )
                    } catch (ex: CodexResponsesException) {
                        code = ex.code
                    }
                    @Expect(code, "transport_deadline_exhausted")
                    @Expect(calls.load(), false)
                } finally {
                    @Expect(popModelExecutionRemainingMsScope(scope), true)
                }
            }
            let one = pushModelExecutionRemainingMsScope({ => 1 })
            try {
                let request = CodexResponsesHttpClient().preparePostRequest(
                    "https://api.openai.com/v1",
                    "test-token",
                    s4ADeadlinePayload()
                )
                @Expect(request.timeoutMs, 1)
            } finally {
                @Expect(popModelExecutionRemainingMsScope(one), true)
            }
            let large = pushModelExecutionRemainingMsScope({ => Int64.Max })
            try {
                let request = CodexResponsesHttpClient().preparePostRequest(
                    "https://api.openai.com/v1",
                    "test-token",
                    s4ADeadlinePayload()
                )
                @Expect(request.timeoutMs, 120000)
            } finally {
                @Expect(popModelExecutionRemainingMsScope(large), true)
            }
        } finally {
            setCodexResponsesHttpRunnerForTest(None<CodexResponsesHttpRunner>)
        }
    }
}

private func s4ADeadlinePayload(): JsonObject {
    let payload = JsonObject()
    payload.put("model", JsonString("gpt-test"))
    payload.put("instructions", JsonString("bounded"))
    let item = JsonObject()
    item.put("role", JsonString("user"))
    item.put("content", JsonString("bounded"))
    let input = JsonArray()
    input.add(item)
    payload.put("input", input)
    payload
}
