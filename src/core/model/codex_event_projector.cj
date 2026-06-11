package metis.core.model

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public class CodexProjectionResult {
    public let messages: Array<JsonObject>
    public let finalText: String
    public let hasFinalText: Bool
    public let isToolIteration: Bool
    public let usage: Option<JsonObject>

    public init(
        messages!: Array<JsonObject> = [],
        finalText!: String = "",
        hasFinalText!: Bool = false,
        isToolIteration!: Bool = false,
        usage!: Option<JsonObject> = None<JsonObject>
    ) {
        this.messages = messages
        this.finalText = finalText
        this.hasFinalText = hasFinalText
        this.isToolIteration = isToolIteration
        this.usage = usage
    }
}

public class CodexEventProjector {
    private let pendingReasoning = ArrayList<String>()

    public init() {}

    public func project(notification: JsonObject): CodexProjectionResult {
        let method = codexProjectorJsonString(notification, "method")
        if (method == "thread/tokenUsage/updated") {
            return CodexProjectionResult(usage: Some(codexAppServerNormalizeUsageNotification(notification)))
        }
        if (method != "thread/item/completed" && method != "item/completed") {
            return CodexProjectionResult()
        }
        let params = codexProjectorJsonObject(notification, "params")
        let item = codexProjectorJsonObject(params, "item")
        this.projectItem(item)
    }

    public func projectItem(item: JsonObject): CodexProjectionResult {
        let itemType = codexProjectorItemType(item)
        match (itemType) {
            case "agentMessage" => this.projectAgentMessage(item)
            case "reasoning" => this.projectReasoning(item)
            case "userMessage" => this.projectUserMessage(item)
            case "commandExecution" => this.projectCommandExecution(item)
            case "fileChange" => this.projectFileChange(item)
            case "mcpToolCall" => this.projectMcpToolCall(item)
            case "dynamicToolCall" => this.projectDynamicToolCall(item)
            case "error" => this.projectError(item)
            case _ => this.projectUnknown(itemType, item)
        }
    }

    private func projectAgentMessage(item: JsonObject): CodexProjectionResult {
        let text = codexProjectorItemText(item)
        let msg = codexProjectorMessage("assistant", text)
        let reasoning = JsonArray()
        for (entry in this.pendingReasoning) {
            reasoning.add(JsonString(entry))
        }
        if (reasoning.size() > 0) {
            msg.put("reasoning", reasoning)
            this.pendingReasoning.clear()
        }
        CodexProjectionResult(messages: [msg], finalText: text, hasFinalText: !text.isEmpty())
    }

    private func projectReasoning(item: JsonObject): CodexProjectionResult {
        let text = codexProjectorItemText(item)
        if (!text.isEmpty()) {
            this.pendingReasoning.add(text)
        }
        let msg = codexProjectorMessage("assistant", text)
        msg.put("kind", JsonString("reasoning"))
        CodexProjectionResult(messages: if (text.isEmpty()) { [] } else { [msg] })
    }

    private func projectUserMessage(item: JsonObject): CodexProjectionResult {
        let text = codexProjectorItemText(item)
        CodexProjectionResult(messages: if (text.isEmpty()) { [] } else { [codexProjectorMessage("user", text)] })
    }

    private func projectCommandExecution(item: JsonObject): CodexProjectionResult {
        let toolCall = codexProjectorToolCall("exec_command", item)
        let result = codexProjectorToolResult(item)
        result.put("tool", JsonString("exec_command"))
        CodexProjectionResult(messages: [toolCall, result], isToolIteration: true)
    }

    private func projectFileChange(item: JsonObject): CodexProjectionResult {
        let toolCall = codexProjectorToolCall("apply_patch", item)
        let result = codexProjectorToolResult(item)
        result.put("tool", JsonString("apply_patch"))
        result.put("summary", JsonString(codexProjectorFileSummary(item)))
        CodexProjectionResult(messages: [toolCall, result], isToolIteration: true)
    }

    private func projectMcpToolCall(item: JsonObject): CodexProjectionResult {
        let server = codexProjectorJsonString(item, "serverName")
        let name = codexProjectorJsonString(item, "toolName")
        let tool = if (server.isEmpty()) { name } else { "${server}.${name}" }
        let toolCall = codexProjectorToolCall(tool, item)
        let result = codexProjectorToolResult(item)
        result.put("tool", JsonString(tool))
        CodexProjectionResult(messages: [toolCall, result], isToolIteration: true)
    }

    private func projectDynamicToolCall(item: JsonObject): CodexProjectionResult {
        let name = codexProjectorJsonString(item, "name")
        let toolCall = codexProjectorToolCall(if (name.isEmpty()) { "dynamic_tool" } else { name }, item)
        let result = codexProjectorToolResult(item)
        result.put("tool", JsonString(codexProjectorJsonString(toolCall, "tool")))
        CodexProjectionResult(messages: [toolCall, result], isToolIteration: true)
    }

    private func projectError(item: JsonObject): CodexProjectionResult {
        let text = codexProjectorItemText(item)
        let msg = codexProjectorMessage("assistant", if (text.isEmpty()) { "Codex app-server returned an error item." } else { text })
        msg.put("kind", JsonString("error"))
        CodexProjectionResult(messages: [msg])
    }

    private func projectUnknown(itemType: String, item: JsonObject): CodexProjectionResult {
        let label = if (itemType.isEmpty()) { "unknown" } else { itemType }
        let msg = codexProjectorMessage("assistant", "[codex ${label}] ${codexProjectorItemText(item)}".trimAscii())
        msg.put("kind", JsonString("codex_item"))
        msg.put("itemType", JsonString(label))
        CodexProjectionResult(messages: [msg])
    }
}

public func codexAppServerNormalizeUsageNotification(notification: JsonObject): JsonObject {
    let params = codexProjectorJsonObject(notification, "params")
    let usage = codexProjectorFirstObject(params, ["tokenUsage", "usage"])
    let last = codexProjectorJsonObject(usage, "last")
    let total = codexProjectorJsonObject(usage, "total")
    let source = if (last.getFields().isEmpty()) { usage } else { last }
    let inputTokens = codexProjectorJsonIntAny(source, ["inputTokens", "input_tokens", "promptTokens", "prompt_tokens"])
    let cachedTokens = codexProjectorCachedTokens(source)
    let outputTokens = codexProjectorJsonIntAny(source, ["outputTokens", "output_tokens", "completionTokens", "completion_tokens"])
    let reasoningTokens = codexProjectorJsonIntAny(source, ["reasoningTokens", "reasoning_tokens"])
    let totalTokens = codexProjectorJsonIntAny(source, ["totalTokens", "total_tokens"])
    let out = JsonObject()
    out.put("inputTokens", JsonInt(inputTokens))
    out.put("promptTokens", JsonInt(inputTokens))
    out.put("cachedInputTokens", JsonInt(cachedTokens))
    out.put("cacheWriteTokens", JsonInt(0))
    out.put("outputTokens", JsonInt(outputTokens))
    out.put("reasoningTokens", JsonInt(reasoningTokens))
    out.put("totalTokens", JsonInt(totalTokens))
    out.put("billingMode", JsonString("subscription_included"))
    out.put("callCount", JsonInt(1))
    out.put("last", source)
    if (!total.getFields().isEmpty()) {
        out.put("total", total)
    }
    let window = codexProjectorJsonIntAny(usage, ["modelContextWindow", "model_context_window"])
    if (window > 0) {
        out.put("modelContextWindow", JsonInt(window))
    }
    out
}

private func codexProjectorMessage(role: String, content: String): JsonObject {
    let msg = JsonObject()
    msg.put("role", JsonString(role))
    msg.put("content", JsonString(content))
    msg
}

private func codexProjectorToolCall(tool: String, item: JsonObject): JsonObject {
    let msg = JsonObject()
    msg.put("role", JsonString("assistant"))
    msg.put("kind", JsonString("tool_call"))
    msg.put("tool", JsonString(tool))
    msg.put("callId", JsonString(codexProjectorCallId(item)))
    msg.put("arguments", codexProjectorJsonObjectOrValue(item, ["arguments", "input", "command"]))
    return msg
}

private func codexProjectorToolResult(item: JsonObject): JsonObject {
    let msg = JsonObject()
    msg.put("role", JsonString("tool"))
    msg.put("kind", JsonString("tool_result"))
    msg.put("callId", JsonString(codexProjectorCallId(item)))
    msg.put("content", JsonString(codexProjectorToolResultText(item)))
    return msg
}

private func codexProjectorCallId(item: JsonObject): String {
    let id = codexProjectorJsonStringAny(item, ["callId", "call_id", "id"])
    if (!id.isEmpty()) {
        return "codex-${id}"
    }
    let itemType = codexProjectorItemType(item)
    "codex-${itemType}-${codexProjectorItemText(item).hashCode().toString()}"
}

private func codexProjectorItemType(item: JsonObject): String {
    codexProjectorJsonStringAny(item, ["type", "itemType", "kind"])
}

private func codexProjectorItemText(item: JsonObject): String {
    let direct = codexProjectorJsonStringAny(item, ["text", "message", "content", "summary", "error"])
    if (!direct.isEmpty()) {
        return direct
    }
    match (item.get("content")) {
        case Some(value) =>
            try {
                let arr = value.asArray()
                let parts = ArrayList<String>()
                for (entry in arr.getItems()) {
                    try {
                        let text = codexProjectorJsonStringAny(entry.asObject(), ["text", "message", "content"])
                        if (!text.isEmpty()) {
                            parts.add(text)
                        }
                    } catch (_: Exception) {
                        try { parts.add(entry.asString().getValue()) } catch (_inner: Exception) { () }
                    }
                }
                return String.join(parts.toArray(), delimiter: "\n")
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    ""
}

private func codexProjectorToolResultText(item: JsonObject): String {
    let text = codexProjectorJsonStringAny(item, ["output", "stdout", "stderr", "result", "summary", "text", "error"])
    if (!text.isEmpty()) {
        return text
    }
    ""
}

private func codexProjectorFileSummary(item: JsonObject): String {
    let summary = codexProjectorJsonStringAny(item, ["summary", "description"])
    if (!summary.isEmpty()) {
        return summary
    }
    let path = codexProjectorJsonStringAny(item, ["path", "file", "filePath"])
    if (!path.isEmpty()) {
        return "file changed: ${path}"
    }
    "file change"
}

private func codexProjectorJsonObjectOrValue(item: JsonObject, keys: Array<String>): JsonValue {
    for (key in keys) {
        match (item.get(key)) {
            case Some(value) => return value
            case None => ()
        }
    }
    JsonObject()
}

private func codexProjectorFirstObject(obj: JsonObject, keys: Array<String>): JsonObject {
    for (key in keys) {
        let value = codexProjectorJsonObject(obj, key)
        if (!value.getFields().isEmpty()) {
            return value
        }
    }
    JsonObject()
}

private func codexProjectorJsonStringAny(obj: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        let value = codexProjectorJsonString(obj, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    ""
}

private func codexProjectorJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asString().getValue().trimAscii() } catch (_: Exception) { () }
        case None => ()
    }
    ""
}

private func codexProjectorJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(value) =>
            try { return value.asObject() } catch (_: Exception) { () }
        case None => ()
    }
    JsonObject()
}

private func codexProjectorJsonIntAny(obj: JsonObject, keys: Array<String>): Int64 {
    for (key in keys) {
        match (obj.get(key)) {
            case Some(value) =>
                try { return value.asInt().getValue() } catch (_: Exception) { () }
            case None => ()
        }
    }
    0
}

private func codexProjectorCachedTokens(obj: JsonObject): Int64 {
    let direct = codexProjectorJsonIntAny(obj, ["cachedInputTokens", "cached_input_tokens", "cachedTokens", "cached_tokens"])
    if (direct > 0) {
        return direct
    }
    match (obj.get("input_tokens_details")) {
        case Some(value) =>
            try { return codexProjectorJsonIntAny(value.asObject(), ["cached_tokens", "cachedTokens"]) } catch (_: Exception) { () }
        case None => ()
    }
    0
}
