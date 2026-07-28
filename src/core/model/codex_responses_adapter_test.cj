package metis.core.model

import magic.core.message.Message
import magic.core.model.ChatRequest
import magic.core.tool.{Tool, ToolParameter, ToolResponse}
import magic.jsonable.TypeSchema

import std.collection.HashMap
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

@Test
public class CodexResponsesAdapterTest {
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
