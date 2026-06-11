package metis.core.model

import magic.core.message.{Message, MessageRole}
import magic.core.model.ChatRequest
import magic.core.tool.{Tool, ToolRequest}

import std.collection.{ArrayList, HashMap}
import stdx.encoding.base64.fromBase64String
import stdx.encoding.json.*

private let CODEX_DEFAULT_INSTRUCTIONS = "You are Codex, a coding agent running inside Metis."
private let CODEX_TOOL_GUIDANCE = "Use available tools when the user asks you to inspect, edit, run, or verify repository state. Do not promise future inspection without issuing the needed tool call."

private func crJsonString(obj: JsonObject, key: String): String {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asString().getValue()
        }
    } catch (_: Exception) { () }
    return ""
}

private func crJsonBool(obj: JsonObject, key: String): Bool {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asBool().getValue()
        }
    } catch (_: Exception) { () }
    return false
}

private func crJsonInt(obj: JsonObject, key: String): Int64 {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asInt().getValue()
        }
    } catch (_: Exception) { () }
    return 0
}

private func crJsonFloat(obj: JsonObject, key: String): Float64 {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asFloat().getValue()
        }
    } catch (_: Exception) {
        try {
            if (let Some(value) <- obj.get(key)) {
                return Float64(value.asInt().getValue())
            }
        } catch (_inner: Exception) { () }
    }
    return 0.0
}

private func crJsonObject(obj: JsonObject, key: String): JsonObject {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asObject()
        }
    } catch (_: Exception) { () }
    return JsonObject()
}

private func crJsonArray(obj: JsonObject, key: String): JsonArray {
    try {
        if (let Some(value) <- obj.get(key)) {
            return value.asArray()
        }
    } catch (_: Exception) { () }
    return JsonArray()
}

private func codexCloneValue(value: JsonValue): JsonValue {
    try {
        return JsonValue.fromStr(value.toJsonString())
    } catch (_: Exception) {
        return JsonString(value.toString())
    }
}

private func codexCloneObject(obj: JsonObject): JsonObject {
    try {
        return JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_: Exception) {
        return JsonObject()
    }
}

private func codexCloneObjectWithout(obj: JsonObject, excludedKeys: Array<String>): JsonObject {
    let out = JsonObject()
    for ((key, value) in obj.getFields()) {
        if (!excludedKeys.contains(key)) {
            out.put(key, codexCloneValue(value))
        }
    }
    return out
}

private func codexCloneArray(arr: JsonArray): JsonArray {
    try {
        return JsonValue.fromStr(arr.toJsonString()).asArray()
    } catch (_: Exception) {
        return JsonArray()
    }
}

private func codexAppendText(builder: StringBuilder, value: String): Unit {
    if (!value.isEmpty()) {
        builder.append(value)
    }
}

private func crJsonStringArray(values: Array<String>): JsonArray {
    let out = JsonArray()
    for (value in values) {
        out.add(JsonString(value))
    }
    return out
}

private func codexInputTextPart(text: String, output!: Bool = false): JsonObject {
    let part = JsonObject()
    part.put("type", JsonString(if (output) { "output_text" } else { "input_text" }))
    part.put("text", JsonString(text))
    return part
}

private func codexInputImagePart(image: String): JsonObject {
    let part = JsonObject()
    part.put("type", JsonString("input_image"))
    part.put("image_url", JsonString(image))
    return part
}

private func codexMessageInputItem(role: String, content: JsonArray): JsonObject {
    let item = JsonObject()
    // Fresh user/assistant turns use the role/content Responses item shape.
    // Provider-returned assistant message items keep type="message" when replayed.
    item.put("role", JsonString(role))
    item.put("content", content)
    return item
}

private func codexTextInputItem(role: String, text: String): JsonObject {
    let item = JsonObject()
    item.put("role", JsonString(role))
    item.put("content", JsonString(text))
    return item
}

private func codexRoleString(message: Message): String {
    return message.role.toString()
}

private func codexIsCodexLikeModel(model: String): Bool {
    let lower = model.toAsciiLower()
    return lower.contains("codex") || lower.contains("gpt-5")
}

private func codexIsLocalEndpoint(baseUrl: String): Bool {
    let lower = baseUrl.toAsciiLower()
    return lower.contains("127.0.0.1") || lower.contains("localhost") || lower.contains("::1")
}

public func codexResponsesIssuerKind(providerId: String, baseUrl!: String = "", isXaiResponses!: Bool = false, isGithubResponses!: Bool = false): String {
    if (isXaiResponses || providerId.toAsciiLower().contains("xai")) {
        return "xai_responses"
    }
    if (isGithubResponses || providerId.toAsciiLower().contains("github")) {
        return "github_responses"
    }
    if (providerId.toAsciiLower() == "openai-codex" || baseUrl.toAsciiLower().contains("chatgpt.com")) {
        return "codex_backend"
    }
    return "openai_responses"
}

public func codexChatRequestToMessages(request: ChatRequest): JsonArray {
    let out = JsonArray()
    for (message in request.messageList) {
        let obj = JsonObject()
        obj.put("role", JsonString(codexRoleString(message)))
        obj.put("content", JsonString(message.content))
        if (let Some(image) <- message.image) {
            obj.put("image", JsonString(image))
        }
        if (let Some(reason) <- message.reason) {
            obj.put("reason", JsonString(reason))
        }
        out.add(obj)
    }
    return out
}

public func codexMessagesToResponsesInput(
    messages: JsonArray,
    currentIssuerKind!: String = "codex_backend",
    replayEncryptedReasoning!: Bool = true
): JsonArray {
    let out = JsonArray()
    let seenReasoningIds = ArrayList<String>()
    for (value in messages.getItems()) {
        let msg = try { value.asObject() } catch (_: Exception) { continue }
        let role = crJsonString(msg, "role")
        if (role == "system") {
            continue
        }

        if (role == "assistant" && replayEncryptedReasoning) {
            for (reasoningValue in crJsonArray(msg, "codex_reasoning_items").getItems()) {
                let reasoning = try { reasoningValue.asObject() } catch (_: Exception) { continue }
                let encrypted = crJsonString(reasoning, "encrypted_content")
                if (encrypted.isEmpty()) {
                    continue
                }
                let issuer = crJsonString(reasoning, "_issuer_kind")
                if (!issuer.isEmpty() && issuer != currentIssuerKind) {
                    continue
                }
                let id = crJsonString(reasoning, "id")
                if (!id.isEmpty() && seenReasoningIds.contains(id)) {
                    continue
                }
                if (!id.isEmpty()) {
                    seenReasoningIds.add(id)
                }
                let replay = codexCloneObjectWithout(reasoning, ["_issuer_kind", "id"])
                out.add(replay)
            }
            for (messageValue in crJsonArray(msg, "codex_message_items").getItems()) {
                let item = try { messageValue.asObject() } catch (_: Exception) { continue }
                out.add(codexCloneObject(item))
            }
        }

        for (toolCallValue in crJsonArray(msg, "tool_calls").getItems()) {
            let toolCall = try { toolCallValue.asObject() } catch (_: Exception) { continue }
            let call = JsonObject()
            call.put("type", JsonString("function_call"))
            call.put("call_id", JsonString(crJsonString(toolCall, "id")))
            let function = crJsonObject(toolCall, "function")
            let name = if (function.getFields().isEmpty()) { crJsonString(toolCall, "name") } else { crJsonString(function, "name") }
            let arguments = if (function.getFields().isEmpty()) { crJsonString(toolCall, "arguments") } else { crJsonString(function, "arguments") }
            call.put("name", JsonString(name))
            call.put("arguments", JsonString(arguments))
            out.add(call)
        }

        if (role == "tool") {
            let output = JsonObject()
            output.put("type", JsonString("function_call_output"))
            output.put("call_id", JsonString(crJsonString(msg, "tool_call_id")))
            output.put("output", JsonString(crJsonString(msg, "content")))
            out.add(output)
            continue
        }

        let output = role == "assistant"
        let text = crJsonString(msg, "content")
        let image = crJsonString(msg, "image")
        if (!image.isEmpty()) {
            let content = JsonArray()
            if (!text.isEmpty()) {
                content.add(codexInputTextPart(text, output: output))
            }
            content.add(codexInputImagePart(image))
            out.add(codexMessageInputItem(role, content))
        } else if (!text.isEmpty()) {
            out.add(codexTextInputItem(role, text))
        }
    }
    return out
}

public func codexChatRequestToResponsesInput(
    request: ChatRequest,
    currentIssuerKind!: String = "codex_backend",
    replayEncryptedReasoning!: Bool = true
): JsonArray {
    return codexMessagesToResponsesInput(
        codexChatRequestToMessages(request),
        currentIssuerKind: currentIssuerKind,
        replayEncryptedReasoning: replayEncryptedReasoning
    )
}

public func codexJsonToolsToResponsesTools(toolsJson: JsonArray): JsonArray {
    let out = JsonArray()
    for (value in toolsJson.getItems()) {
        let raw = try { value.asObject() } catch (_: Exception) { continue }
        var function = JsonObject()
        let toolType = crJsonString(raw, "type")
        if (toolType == "function") {
            function = crJsonObject(raw, "function")
        } else if (toolType.isEmpty() && raw.get("name").isSome()) {
            function = raw
        } else {
            continue
        }
        let name = crJsonString(function, "name")
        if (name.isEmpty()) {
            continue
        }
        let converted = JsonObject()
        converted.put("type", JsonString("function"))
        converted.put("name", JsonString(name))
        converted.put("description", JsonString(crJsonString(function, "description")))
        converted.put("strict", JsonBool(false))
        let parameters = crJsonObject(function, "parameters")
        if (parameters.getFields().isEmpty()) {
            let emptyParams = JsonObject()
            emptyParams.put("type", JsonString("object"))
            emptyParams.put("properties", JsonObject())
            converted.put("parameters", emptyParams)
        } else {
            converted.put("parameters", codexCloneObject(parameters))
        }
        out.add(converted)
    }
    return out
}

public func codexToolsToResponsesTools(tools: Array<Tool>): JsonArray {
    let raw = JsonArray()
    for (tool in tools) {
        let item = JsonObject()
        item.put("type", JsonString("function"))
        item.put("function", tool.toJsonValue())
        raw.add(item)
    }
    return codexJsonToolsToResponsesTools(raw)
}

private func codexInstructionsFromMessages(messages: JsonArray): String {
    for (value in messages.getItems()) {
        let msg = try { value.asObject() } catch (_: Exception) { continue }
        if (crJsonString(msg, "role") == "system") {
            let text = crJsonString(msg, "content")
            if (!text.isEmpty()) {
                return text
            }
        }
    }
    return CODEX_DEFAULT_INSTRUCTIONS
}

public func codexBuildResponsesPayload(
    model: String,
    request: ChatRequest,
    options!: CodexResponsesBuildOptions = CodexResponsesBuildOptions()
): JsonObject {
    let messages = codexChatRequestToMessages(request)
    let payload = JsonObject()
    payload.put("model", JsonString(model))
    payload.put("instructions", JsonString(codexInstructionsFromMessages(messages)))
    payload.put(
        "input",
        codexMessagesToResponsesInput(
            messages,
            currentIssuerKind: codexResponsesIssuerKind(
                options.providerId,
                baseUrl: options.baseUrl,
                isXaiResponses: options.isXaiResponses,
                isGithubResponses: options.isGithubResponses
            ),
            replayEncryptedReasoning: options.replayEncryptedReasoning
        )
    )
    payload.put("store", JsonBool(false))
    let reasoning = JsonObject()
    reasoning.put("effort", JsonString(options.reasoningEffort))
    reasoning.put("summary", JsonString("auto"))
    payload.put("reasoning", reasoning)
    payload.put("include", crJsonStringArray(["reasoning.encrypted_content"]))
    if (!options.sessionId.isEmpty()) {
        payload.put("prompt_cache_key", JsonString(options.sessionId))
    }
    if (let Some(temp) <- request.temperature) {
        payload.put("temperature", JsonFloat(temp))
    }
    let tools = codexToolsToResponsesTools(request.tools)
    if (tools.size() > 0) {
        payload.put("tools", tools)
        payload.put("tool_choice", JsonString("auto"))
        payload.put("parallel_tool_calls", JsonBool(true))
    }
    if (!options.isCodexBackend) {
        if (let Some(maxTokens) <- request.maxTokens) {
            payload.put("max_output_tokens", JsonInt(maxTokens))
        }
    }
    return codexMergeResponsesRequestOptions(
        payload,
        providerId: options.providerId,
        model: model,
        isCodexBackend: options.isCodexBackend,
        isXaiResponses: options.isXaiResponses,
        globalFastMode: options.globalFastMode
    )
}

public func codexResponsesExtraHeaders(sessionId: String, requestId!: String = ""): HashMap<String, String> {
    let headers = HashMap<String, String>()
    if (!sessionId.isEmpty()) {
        headers.add("session_id", sessionId)
        headers.add("x-client-request-id", if (requestId.isEmpty()) { sessionId } else { requestId })
    }
    return headers
}

public func codexPreflightResponsesPayload(payload: JsonObject, allowStream!: Bool = false): JsonObject {
    let model = crJsonString(payload, "model")
    if (model.isEmpty()) {
        throw CodexResponsesException("missing_model", "Codex Responses request is missing model")
    }
    if (crJsonString(payload, "instructions").isEmpty()) {
        throw CodexResponsesException("missing_instructions", "Codex Responses request is missing instructions")
    }
    if (crJsonArray(payload, "input").size() == 0) {
        throw CodexResponsesException("missing_input", "Codex Responses request is missing input")
    }
    codexPreflightResponsesInputItems(crJsonArray(payload, "input"))
    if (crJsonBool(payload, "store")) {
        throw CodexResponsesException("invalid_store", "Codex Responses request must use store=false")
    }
    if (payload.get("stream").isSome() && !allowStream) {
        throw CodexResponsesException("unsupported_parameter", "Codex Responses request stream is not allowed for this path")
    }
    if (payload.get("tools").isSome()) {
        for (value in crJsonArray(payload, "tools").getItems()) {
            let tool = try { value.asObject() } catch (_: Exception) {
                throw CodexResponsesException("invalid_tool", "Codex Responses tool must be an object")
            }
            if (crJsonString(tool, "type") != "function" || crJsonString(tool, "name").isEmpty()) {
                throw CodexResponsesException("invalid_tool", "Codex Responses only supports named function tools")
            }
        }
    }
    return payload
}

private func codexPreflightResponsesInputItems(input: JsonArray): Unit {
    for (value in input.getItems()) {
        let item = try { value.asObject() } catch (_: Exception) {
            throw CodexResponsesException("invalid_input", "Codex Responses input items must be objects")
        }
        let itemType = crJsonString(item, "type")
        if (itemType == "function_call") {
            if (crJsonString(item, "call_id").trimAscii().isEmpty() || crJsonString(item, "name").trimAscii().isEmpty()) {
                throw CodexResponsesException("invalid_input", "Codex Responses function_call input is missing call_id or name")
            }
            continue
        }
        if (itemType == "function_call_output") {
            if (crJsonString(item, "call_id").trimAscii().isEmpty()) {
                throw CodexResponsesException("invalid_input", "Codex Responses function_call_output input is missing call_id")
            }
            continue
        }
        if (itemType == "reasoning") {
            if (crJsonString(item, "encrypted_content").trimAscii().isEmpty()) {
                throw CodexResponsesException("invalid_input", "Codex Responses reasoning input is missing encrypted_content")
            }
            continue
        }
        if (itemType == "message") {
            if (crJsonString(item, "role") != "assistant") {
                throw CodexResponsesException("invalid_input", "Codex Responses type=message input is only valid for replayed assistant messages")
            }
            codexPreflightResponsesContent(item, "assistant", replayedMessage: true)
            continue
        }
        let role = crJsonString(item, "role")
        if (role == "user" || role == "assistant") {
            codexPreflightResponsesContent(item, role)
            continue
        }
        throw CodexResponsesException("invalid_input", "Codex Responses input item has unsupported type or role")
    }
}

private func codexPreflightResponsesContent(
    item: JsonObject,
    role: String,
    replayedMessage!: Bool = false
): Unit {
    let contentValue = match (item.get("content")) {
        case Some(value) => value
        case None => throw CodexResponsesException("invalid_input", "Codex Responses message input is missing content")
    }
    if (replayedMessage) {
        let content = try { contentValue.asArray() } catch (_: Exception) {
            throw CodexResponsesException("invalid_input", "Codex Responses replayed assistant message content must be an array")
        }
        if (content.size() == 0) {
            throw CodexResponsesException("invalid_input", "Codex Responses replayed assistant message content is empty")
        }
        for (partValue in content.getItems()) {
            let part = try { partValue.asObject() } catch (_: Exception) {
                throw CodexResponsesException("invalid_input", "Codex Responses content parts must be objects")
            }
            let partType = crJsonString(part, "type")
            if (partType != "output_text" && partType != "text") {
                throw CodexResponsesException("invalid_input", "Codex Responses replayed assistant message content has unsupported part type")
            }
        }
        return
    }
    try {
        let _ = contentValue.asString()
        return
    } catch (_: Exception) { () }

    let content = try { contentValue.asArray() } catch (_: Exception) {
        throw CodexResponsesException("invalid_input", "Codex Responses message content must be a string or array")
    }
    let expectedTextType = if (role == "assistant") { "output_text" } else { "input_text" }
    for (partValue in content.getItems()) {
        let part = try { partValue.asObject() } catch (_: Exception) {
            throw CodexResponsesException("invalid_input", "Codex Responses content parts must be objects")
        }
        let partType = crJsonString(part, "type")
        if (partType == expectedTextType || partType == "text") {
            continue
        }
        if (!replayedMessage && role == "user" && partType == "input_image" && !crJsonString(part, "image_url").trimAscii().isEmpty()) {
            continue
        }
        throw CodexResponsesException("invalid_input", "Codex Responses message content has unsupported part type")
    }
}

private func codexArgumentsToJsonObject(argumentsValue: JsonValue): JsonObject {
    try {
        return argumentsValue.asObject()
    } catch (_: Exception) { () }
    try {
        let raw = argumentsValue.asString().getValue()
        if (!raw.trimAscii().isEmpty()) {
            return JsonValue.fromStr(raw).asObject()
        }
    } catch (_: Exception) { () }
    return JsonObject()
}

private func codexReadTextFromContent(content: JsonArray, outputOnly!: Bool = false): String {
    let builder = StringBuilder()
    for (partValue in content.getItems()) {
        let part = try { partValue.asObject() } catch (_: Exception) { continue }
        let partType = crJsonString(part, "type")
        if (partType == "output_text" || (!outputOnly && partType == "input_text") || partType == "text") {
            codexAppendText(builder, crJsonString(part, "text"))
        }
    }
    return builder.toString()
}

private func codexNormalizeOutputItem(
    item: JsonObject,
    issuerKind: String,
    content: StringBuilder,
    reasoningItems: JsonArray,
    messageItems: JsonArray,
    toolRequests: ArrayList<ToolRequest>
): Unit {
    let itemType = crJsonString(item, "type")
    if (itemType == "message") {
        let text = codexReadTextFromContent(crJsonArray(item, "content"), outputOnly: true)
        codexAppendText(content, text)
        messageItems.add(codexCloneObject(item))
    } else if (itemType == "reasoning") {
        let id = crJsonString(item, "id")
        if (id.startsWith("rs_tmp_")) {
            return
        }
        let reason = codexCloneObject(item)
        reason.put("_issuer_kind", JsonString(issuerKind))
        reasoningItems.add(reason)
        let summary = crJsonArray(item, "summary")
        for (summaryValue in summary.getItems()) {
            let summaryObj = try { summaryValue.asObject() } catch (_: Exception) { continue }
            codexAppendText(content, crJsonString(summaryObj, "text"))
        }
    } else if (itemType == "function_call" || itemType == "custom_tool_call") {
        let name = crJsonString(item, "name")
        if (name.isEmpty()) {
            return
        }
        var args = JsonObject()
        if (let Some(argumentsValue) <- item.get("arguments")) {
            args = codexArgumentsToJsonObject(argumentsValue)
        } else if (let Some(inputValue) <- item.get("input")) {
            args = codexArgumentsToJsonObject(inputValue)
        }
        toolRequests.add(ToolRequest(name: name, args: args))
    }
}

public func codexNormalizeResponses(
    response: JsonObject,
    issuerKind!: String = "codex_backend"
): CodexResponsesNormalized {
    let status = crJsonString(response, "status")
    if (status == "failed" || status == "cancelled") {
        let error = crJsonObject(response, "error")
        let code = crJsonString(error, "code")
        let message = crJsonString(error, "message")
        throw CodexResponsesException(
            if (code.isEmpty()) { status } else { code },
            "Codex Responses ${status}: ${if (message.isEmpty()) { "no provider error message" } else { message }}"
        )
    }

    let content = StringBuilder()
    let reasoningItems = JsonArray()
    let messageItems = JsonArray()
    let toolRequests = ArrayList<ToolRequest>()
    var output = crJsonArray(response, "output")
    if (output.size() == 0) {
        let outputText = crJsonString(response, "output_text")
        if (!outputText.isEmpty()) {
            let message = JsonObject()
            message.put("type", JsonString("message"))
            message.put("role", JsonString("assistant"))
            let parts = JsonArray()
            parts.add(codexInputTextPart(outputText, output: true))
            message.put("content", parts)
            output = JsonArray()
            output.add(message)
        }
    }
    for (itemValue in output.getItems()) {
        let item = try { itemValue.asObject() } catch (_: Exception) { continue }
        codexNormalizeOutputItem(item, issuerKind, content, reasoningItems, messageItems, toolRequests)
    }

    let finish = if (toolRequests.size > 0) {
        "tool_calls"
    } else if (status == "incomplete") {
        "incomplete"
    } else {
        "stop"
    }
    return CodexResponsesNormalized(
        crJsonString(response, "model"),
        content.toString(),
        toolRequests.toArray(),
        reasoningItems,
        messageItems,
        finish
    )
}

public func codexResponsesEventsToResponse(events: Array<JsonObject>, model!: String = ""): JsonObject {
    var output = JsonArray()
    let text = StringBuilder()
    var responseModel = model
    var terminal = false
    for (event in events) {
        let eventType = crJsonString(event, "type")
        if (eventType == "response.output_text.delta") {
            codexAppendText(text, crJsonString(event, "delta"))
        } else if (eventType == "response.output_item.done") {
            let item = crJsonObject(event, "item")
            if (!item.getFields().isEmpty()) {
                output.add(item)
            }
        } else if (eventType == "response.completed" || eventType == "response.failed" || eventType == "response.cancelled" || eventType == "response.incomplete") {
            terminal = true
            let response = crJsonObject(event, "response")
            if (!response.getFields().isEmpty()) {
                if (output.size() == 0) {
                    output = crJsonArray(response, "output")
                }
                if (responseModel.isEmpty() && !crJsonString(response, "model").isEmpty()) {
                    responseModel = crJsonString(response, "model")
                }
            }
        }
    }
    if (output.size() == 0 && !text.toString().isEmpty()) {
        let message = JsonObject()
        message.put("type", JsonString("message"))
        message.put("role", JsonString("assistant"))
        let parts = JsonArray()
        parts.add(codexInputTextPart(text.toString(), output: true))
        message.put("content", parts)
        output.add(message)
    }
    if (!terminal && output.size() == 0) {
        throw CodexResponsesException("missing_terminal", "Codex Responses stream did not emit a terminal response")
    }
    let response = JsonObject()
    response.put("status", JsonString("completed"))
    response.put("model", JsonString(responseModel))
    response.put("output", output)
    if (!terminal) {
        response.put("synthesized_terminal", JsonBool(true))
    }
    return response
}

public func codexNormalizeResponsesEvents(
    events: Array<JsonObject>,
    model!: String = "",
    issuerKind!: String = "codex_backend"
): CodexResponsesNormalized {
    return codexNormalizeResponses(codexResponsesEventsToResponse(events, model: model), issuerKind: issuerKind)
}

public func codexClassifyResponsesError(statusCode: Int64, body: String, contextTokens!: Int64 = 0): String {
    let lower = body.toAsciiLower()
    if (lower.contains("invalid_encrypted_content")) {
        return "invalid_encrypted_content"
    }
    if (lower.contains("content policy") || lower.contains("safety") || lower.contains("policy_violation")) {
        return "content_policy"
    }
    if (lower.contains("invalid image") || lower.contains("image format") || lower.contains("unsupported image")) {
        return "image_rejection"
    }
    if (statusCode == 401 || statusCode == 403) {
        return "auth_error"
    }
    if (statusCode == 429) {
        return "rate_limit"
    }
    if (statusCode >= 500) {
        return "server_error"
    }
    if (lower.contains("context") || lower.contains("maximum context") || contextTokens > 100000) {
        return "context_overflow"
    }
    if (statusCode == 400) {
        return "format_error"
    }
    if (lower.contains("json") || lower.contains("parse")) {
        return "parse_error"
    }
    return "provider_error"
}

public func codexShouldRetryWithoutEncryptedReasoning(errorClass: String): Bool {
    return errorClass == "invalid_encrypted_content"
}

public func codexStripReasoningReplayForRetry(payload: JsonObject): JsonObject {
    let cloned = codexCloneObject(payload)
    let input = crJsonArray(cloned, "input")
    let strippedInput = JsonArray()
    for (value in input.getItems()) {
        let item = try { value.asObject() } catch (_: Exception) { continue }
        if (crJsonString(item, "type") == "reasoning") {
            strippedInput.add(codexCloneObjectWithout(item, ["encrypted_content"]))
        } else {
            strippedInput.add(codexCloneObject(item))
        }
    }
    let include = JsonArray()
    for (value in crJsonArray(cloned, "include").getItems()) {
        let s = try { value.asString().getValue() } catch (_: Exception) { "" }
        if (s != "reasoning.encrypted_content") {
            include.add(JsonString(s))
        }
    }
    cloned.put("include", include)
    cloned.put("input", strippedInput)
    cloned.put("replay_encrypted_reasoning", JsonBool(false))
    return cloned
}

public func codexUnsupportedParameterRetryPayload(payload: JsonObject, errorMessage: String): JsonObject {
    let lower = errorMessage.toAsciiLower()
    let candidates = ["service_tier", "max_output_tokens", "parallel_tool_calls", "tool_choice", "temperature"]
    let out = JsonObject()
    out.put("shouldRetry", JsonBool(false))
    out.put("payload", codexCloneObject(payload))
    out.put("removedParameter", JsonString(""))
    for (candidate in candidates) {
        if (payload.get(candidate).isSome() && lower.contains(candidate.toAsciiLower())) {
            let retryPayload = codexCloneObjectWithout(payload, [candidate])
            out.put("shouldRetry", JsonBool(true))
            out.put("payload", retryPayload)
            out.put("removedParameter", JsonString(candidate))
            return out
        }
    }
    return out
}

public func codexContinuationNeeded(userPrompt: String, content: String, toolCallCount: Int64): Bool {
    if (toolCallCount > 0) {
        return false
    }
    let prompt = userPrompt.toAsciiLower()
    let answer = content.toAsciiLower()
    let asksRepoWork = prompt.contains("repo") || prompt.contains("file") || prompt.contains("inspect") || prompt.contains("edit")
    let promisesWork = answer.contains("i'll inspect") || answer.contains("i will inspect") || answer.contains("i'll check") || answer.contains("i will check")
    return asksRepoWork && promisesWork
}

public func codexContinuationPrompt(previousContent: String, attempt: Int64): String {
    return "Continue by issuing the necessary tool call now. Do not answer with another promise. Continuation ${attempt}/2. Previous assistant text: ${previousContent}"
}

public func codexShouldInjectToolUseGuidance(modelRef: String): Bool {
    return codexIsCodexLikeModel(modelRef)
}

public func codexApplyPromptPolicy(messages: JsonArray, apiMode: String, modelRef: String): JsonArray {
    let out = codexCloneArray(messages)
    if (out.size() == 0) {
        return out
    }
    let first = try { out[0].asObject() } catch (_: Exception) { return out }
    if (crJsonString(first, "role") == "system" && apiMode == "chat_completions" && codexIsCodexLikeModel(modelRef)) {
        first.put("role", JsonString("developer"))
    }
    if (codexShouldInjectToolUseGuidance(modelRef)) {
        if (crJsonString(first, "role") == "system" || crJsonString(first, "role") == "developer") {
            let old = crJsonString(first, "content")
            first.put("content", JsonString(if (old.isEmpty()) { CODEX_TOOL_GUIDANCE } else { "${old}\n\n${CODEX_TOOL_GUIDANCE}" }))
        }
    }
    return out
}

public func codexMergeResponsesRequestOptions(
    payload: JsonObject,
    providerId!: String = "openai-codex",
    model!: String = "",
    isCodexBackend!: Bool = true,
    isXaiResponses!: Bool = false,
    globalFastMode!: Bool = false,
    serviceTier!: String = "",
    maxOutputTokens!: Int64 = 0
): JsonObject {
    let excluded = ArrayList<String>()
    let providerLower = providerId.toAsciiLower()
    if (isCodexBackend) {
        excluded.add("max_output_tokens")
    }
    if (isXaiResponses || providerLower.contains("xai") || (globalFastMode && codexIsCodexLikeModel(model))) {
        excluded.add("service_tier")
    }
    let out = codexCloneObjectWithout(payload, excluded.toArray())
    if (maxOutputTokens > 0 && !isCodexBackend) {
        out.put("max_output_tokens", JsonInt(maxOutputTokens))
    }
    if (!serviceTier.isEmpty()) {
        if (!(isXaiResponses || providerLower.contains("xai") || (globalFastMode && codexIsCodexLikeModel(model)))) {
            out.put("service_tier", JsonString(serviceTier))
        }
    }
    return out
}

public func codexSanitizeRequestKwargsForProvider(providerId: String, kwargs: JsonObject): JsonObject {
    if (providerId.toAsciiLower() == "openai-codex") {
        return codexCloneObject(kwargs)
    }
    return codexCloneObjectWithout(kwargs, ["instructions", "input", "store", "parallel_tool_calls", "tools", "tool_choice"])
}

public func codexSanitizeHistoryForProvider(providerId: String, apiMode: String, messages: JsonArray): JsonArray {
    if (providerId.toAsciiLower() == "openai-codex" || apiMode == "codex_responses") {
        return codexCloneArray(messages)
    }
    let out = JsonArray()
    for (value in messages.getItems()) {
        let msg = try { value.asObject() } catch (_: Exception) { continue }
        let clean = JsonObject()
        for ((key, field) in msg.getFields()) {
            if (key == "codex_reasoning_items" || key == "codex_message_items" || key == "call_id" ||
                key == "response_item_id" || key == "tool_name" || key.startsWith("_")) {
                continue
            }
            clean.put(key, codexCloneValue(field))
        }
        out.add(clean)
    }
    return out
}

public func codexEncodeProviderData(reasoningItems: JsonArray, messageItems: JsonArray): JsonObject {
    let out = JsonObject()
    out.put("codex_reasoning_items", codexCloneArray(reasoningItems))
    out.put("codex_message_items", codexCloneArray(messageItems))
    return out
}

public func codexDecodeProviderData(raw: String): JsonObject {
    try {
        let obj = JsonValue.fromStr(raw).asObject()
        let out = JsonObject()
        out.put("codex_reasoning_items", crJsonArray(obj, "codex_reasoning_items"))
        out.put("codex_message_items", crJsonArray(obj, "codex_message_items"))
        return out
    } catch (_: Exception) {
        return codexEncodeProviderData(JsonArray(), JsonArray())
    }
}

public func codexEstimateRequestContextTokens(value: JsonValue): Int64 {
    let size = value.toJsonString().size
    let estimated = Int64(size / 4)
    return if (estimated < 1) { 1 } else { estimated }
}

public func codexNonStreamStaleTimeoutSeconds(
    payload: JsonObject,
    baseUrl!: String = "",
    modelTimeoutSeconds!: Float64 = 0.0,
    providerTimeoutSeconds!: Float64 = 0.0,
    envTimeoutSeconds!: Float64 = 0.0
): Float64 {
    if (modelTimeoutSeconds > 0.0) {
        return modelTimeoutSeconds
    }
    if (providerTimeoutSeconds > 0.0) {
        return providerTimeoutSeconds
    }
    if (envTimeoutSeconds > 0.0) {
        return envTimeoutSeconds
    }
    if (codexIsLocalEndpoint(baseUrl)) {
        return 999999999.0
    }
    let tokens = codexEstimateRequestContextTokens(payload)
    if (tokens > 100000) {
        return 240.0
    }
    if (tokens > 50000) {
        return 150.0
    }
    return 90.0
}

public func codexResponsesWatchdogDecision(
    events: Array<JsonObject>,
    ttfbTimeoutSeconds!: Float64 = 45.0,
    idleTimeoutSeconds!: Float64 = 45.0
): CodexResponsesWatchdogDecision {
    if (events.isEmpty()) {
        return CodexResponsesWatchdogDecision("kill", "codex_ttfb_kill", ttfbTimeoutSeconds, "Codex Responses stream produced no first event")
    }
    let firstDelay = crJsonFloat(events[0], "delay_seconds")
    if (firstDelay > ttfbTimeoutSeconds) {
        return CodexResponsesWatchdogDecision("kill", "codex_ttfb_kill", ttfbTimeoutSeconds, "Codex Responses stream exceeded time-to-first-event watchdog")
    }
    for (event in events[1..events.size]) {
        let gap = crJsonFloat(event, "gap_seconds")
        if (gap > idleTimeoutSeconds) {
            return CodexResponsesWatchdogDecision("kill", "codex_stream_idle_kill", idleTimeoutSeconds, "Codex Responses stream exceeded idle watchdog")
        }
    }
    return CodexResponsesWatchdogDecision("continue", "", 0.0, "")
}

public func codexSilentHangHint(apiMode: String, providerId: String, model: String): String {
    let lowerModel = model.toAsciiLower()
    let lowerProvider = providerId.toAsciiLower()
    if (apiMode != "codex_responses") {
        return ""
    }
    if (!(lowerProvider == "openai-codex" || lowerProvider.contains("chatgpt"))) {
        return ""
    }
    if ((lowerModel == "gpt-5.5" || lowerModel.contains("/gpt-5.5") || lowerModel.contains("-gpt-5.5")) && !lowerModel.contains("gpt-5.50")) {
        return "Codex Responses gpt-5.5 can hang before the first event. Try gpt-5.4, gpt-5.3-codex, or the configured fallback chain."
    }
    return ""
}

public func codexAuxiliaryProviderChain(candidates: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (candidate in candidates) {
        if (candidate.toAsciiLower() != "openai-codex" && !out.contains(candidate)) {
            out.add(candidate)
        }
    }
    return out.toArray()
}

private func codexTokenPoolHasUsableToken(tokenPool: JsonArray): Bool {
    for (value in tokenPool.getItems()) {
        let entry = try { value.asObject() } catch (_: Exception) { continue }
        if (!crJsonString(entry, "token").isEmpty() && !crJsonBool(entry, "expired")) {
            return true
        }
    }
    return false
}

public func codexAuxiliaryClientDecision(
    mainProvider: String,
    explicitProvider!: String = "",
    explicitModel!: String = "",
    tokenPool!: JsonArray = JsonArray(),
    singletonToken!: String = "",
    rawCodex!: Bool = false,
    customEndpoint!: String = "",
    apiMode!: String = "codex_responses"
): CodexAuxiliaryClientDecision {
    let provider = if (!explicitProvider.isEmpty()) { explicitProvider } else { mainProvider }
    let codexRequested = provider.toAsciiLower() == "openai-codex" || !explicitModel.isEmpty()
    if (!codexRequested) {
        return CodexAuxiliaryClientDecision(provider, explicitModel, "none", false, "codex_not_in_auto_chain")
    }
    if (explicitModel.isEmpty()) {
        return CodexAuxiliaryClientDecision(provider, explicitModel, "none", false, "missing_model")
    }
    let hasPoolToken = codexTokenPoolHasUsableToken(tokenPool)
    let hasToken = hasPoolToken || !singletonToken.isEmpty()
    if (!hasToken) {
        return CodexAuxiliaryClientDecision(provider, explicitModel, "none", false, "missing_token")
    }
    let kind = if (rawCodex) {
        "raw_codex"
    } else if (!customEndpoint.isEmpty() && apiMode == "codex_responses") {
        "wrapped_codex_responses"
    } else {
        "codex_responses"
    }
    return CodexAuxiliaryClientDecision(provider, explicitModel, kind, true, if (hasPoolToken) { "pool_token" } else { "singleton_token" })
}

public func codexAuxiliaryRecoveryAction(errorClass: String): String {
    if (errorClass == "auth_error" || errorClass == "401") {
        return "refresh_once_rebuild"
    }
    if (errorClass == "rate_limit" || errorClass == "429") {
        return "rotate_same_provider_pool"
    }
    if (errorClass == "timeout" || errorClass == "connection") {
        return "evict_sync_async_wrapper_cache"
    }
    return "fallback"
}

public func codexCloudflareHeaders(accessToken: String): JsonObject {
    let headers = JsonObject()
    headers.put("originator", JsonString("codex_cli_rs"))
    headers.put("User-Agent", JsonString("codex_cli_rs/0.0.0 Metis"))
    let parts = accessToken.split(".")
    if (parts.size < 2) {
        return headers
    }
    var payload = parts[1].replace("-", "+").replace("_", "/")
    while (payload.size % 4 != 0) {
        payload += "="
    }
    try {
        if (let Some(bytes) <- fromBase64String(payload)) {
            let obj = JsonValue.fromStr(String.fromUtf8(bytes)).asObject()
            let accountId = crJsonString(obj, "https://api.openai.com/auth.chatgpt_account_id")
            if (!accountId.isEmpty()) {
                headers.put("ChatGPT-Account-ID", JsonString(accountId))
            }
        }
    } catch (_: Exception) { () }
    return headers
}
