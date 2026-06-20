package metis.gateway.reply_guard

import stdx.encoding.json.{JsonArray, JsonObject, JsonValue}

public class GatewayToolProtocolDetection {
    public let detected: Bool
    public let status: String
    public let terminalAnswer: Bool

    public init(detected: Bool, status!: String = "", terminalAnswer!: Bool = false) {
        this.detected = detected
        this.status = status.trimAscii()
        this.terminalAnswer = terminalAnswer
    }
}

public class GatewayAssistantReplyGuardResult {
    public let ok: Bool
    public let status: String
    public let text: String
    public let blocked: Bool
    public let needsRepair: Bool
    public let diagnostic: String
    public let diagnosticHash: String

    public init(
        ok: Bool,
        status!: String = "ok",
        text!: String = "",
        blocked!: Bool = false,
        needsRepair!: Bool = false,
        diagnostic!: String = "",
        diagnosticHash!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.text = text
        this.blocked = blocked
        this.needsRepair = needsRepair
        this.diagnostic = diagnostic.trimAscii()
        this.diagnosticHash = diagnosticHash.trimAscii()
    }
}

public func normalizeGatewayAssistantFinalReply(raw: String): GatewayAssistantReplyGuardResult {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return GatewayAssistantReplyGuardResult(false, status: "empty", text: "", blocked: true, needsRepair: false, diagnostic: "assistant reply is empty", diagnosticHash: gatewayAssistantReplyDiagnosticHash(raw))
    }
    match (extractTerminalAnswerEnvelope(trimmed, depth: 3)) {
        case Some(answer) =>
            let unwrapped = answer.trimAscii()
            if (unwrapped.isEmpty()) {
                return GatewayAssistantReplyGuardResult(false, status: "terminal_answer_empty", text: "", blocked: true, needsRepair: true, diagnostic: "terminal answer envelope contained empty text", diagnosticHash: gatewayAssistantReplyDiagnosticHash(raw))
            }
            return GatewayAssistantReplyGuardResult(true, status: "ok", text: stripAssistantToolXmlBlocks(unwrapped))
        case None => ()
    }

    let xmlStripped = stripAssistantToolXmlBlocks(trimmed)
    if (xmlStripped.trimAscii().isEmpty() && trimmed != xmlStripped) {
        return GatewayAssistantReplyGuardResult(false, status: "tool_xml_blocked", text: "", blocked: true, needsRepair: true, diagnostic: "assistant reply contained only tool XML", diagnosticHash: gatewayAssistantReplyDiagnosticHash(raw))
    }

    let detection = detectToolProtocolJson(trimmed)
    if (detection.detected) {
        return GatewayAssistantReplyGuardResult(false, status: detection.status, text: "", blocked: true, needsRepair: true, diagnostic: "assistant reply is tool protocol", diagnosticHash: gatewayAssistantReplyDiagnosticHash(raw))
    }
    if (detectHarmonyToolLeak(trimmed)) {
        return GatewayAssistantReplyGuardResult(false, status: "harmony_tool_leak", text: "", blocked: true, needsRepair: true, diagnostic: "assistant reply is harmony tool protocol", diagnosticHash: gatewayAssistantReplyDiagnosticHash(raw))
    }
    GatewayAssistantReplyGuardResult(true, status: "ok", text: xmlStripped)
}

public func normalizeGatewayAssistantVisibleTextForDelivery(raw: String, partial!: Bool = false): GatewayAssistantReplyGuardResult {
    if (partial && gatewayAssistantReplyLooksLikeToolProtocolPrefix(raw)) {
        return GatewayAssistantReplyGuardResult(false, status: "tool_protocol_prefix", text: "", blocked: true, needsRepair: true, diagnostic: "assistant partial reply is tool protocol prefix", diagnosticHash: gatewayAssistantReplyDiagnosticHash(raw))
    }
    let result = normalizeGatewayAssistantFinalReply(raw)
    if (result.ok) {
        return result
    }
    if (partial) {
        return GatewayAssistantReplyGuardResult(false, status: result.status, text: "", blocked: true, needsRepair: result.needsRepair, diagnostic: result.diagnostic, diagnosticHash: result.diagnosticHash)
    }
    GatewayAssistantReplyGuardResult(true, status: result.status, text: safeFallbackTextForBlockedAssistantReply(result.status), blocked: true, needsRepair: result.needsRepair, diagnostic: result.diagnostic, diagnosticHash: result.diagnosticHash)
}

public func extractTerminalAnswerEnvelope(raw: String, depth!: Int64): ?String {
    if (depth <= 0) {
        return None<String>
    }
    let value = gatewayAssistantReplyParseFullJson(raw.trimAscii())
    if (value.isNone()) {
        return None<String>
    }
    let obj = try {
        value.getOrThrow().asObject()
    } catch (_: Exception) {
        return None<String>
    }
    let extracted = gatewayAssistantReplyExtractTerminalAnswerFromObject(obj)
    match (extracted) {
        case Some(answer) =>
            match (extractTerminalAnswerEnvelope(answer.trimAscii(), depth: depth - 1)) {
                case Some(nested) => Some(nested)
                case None => Some(answer)
            }
        case None => None<String>
    }
}

public func detectToolProtocolJson(raw: String): GatewayToolProtocolDetection {
    let trimmed = raw.trimAscii()
    let value = gatewayAssistantReplyParseFullJson(trimmed)
    if (value.isNone()) {
        return GatewayToolProtocolDetection(false)
    }
    let root = value.getOrThrow()
    let obj = try {
        root.asObject()
    } catch (_: Exception) {
        let arr = try {
            root.asArray()
        } catch (_: Exception) {
            return GatewayToolProtocolDetection(false)
        }
        if (gatewayAssistantReplyArrayHasToolShape(arr)) {
            return GatewayToolProtocolDetection(true, status: "tool_protocol_json")
        }
        return GatewayToolProtocolDetection(false)
    }
    if (gatewayAssistantReplyExtractTerminalAnswerFromObject(obj).isSome()) {
        return GatewayToolProtocolDetection(true, status: "terminal_answer_envelope", terminalAnswer: true)
    }
    if (gatewayAssistantReplyObjectHasToolShape(obj)) {
        return GatewayToolProtocolDetection(true, status: "tool_protocol_json")
    }
    GatewayToolProtocolDetection(false)
}

public func detectHarmonyToolLeak(raw: String): Bool {
    let lower = raw.trimAscii().toAsciiLower()
    lower.contains("to=functions.") ||
        lower.contains("assistant to=functions.") ||
        lower.contains("<|channel|>commentary to=functions.")
}

public func stripAssistantToolXmlBlocks(raw: String): String {
    let lines = raw.split("\n")
    let out = StringBuilder()
    var inCodeFence = false
    var inToolBlock = false
    for (line in lines) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("```")) {
            if (!inToolBlock) {
                if (out.size > 0) { out.append("\n") }
                out.append(line)
            }
            inCodeFence = !inCodeFence
            continue
        }
        if (!inCodeFence && gatewayAssistantReplyLineStartsToolXmlBlock(trimmed)) {
            if (!gatewayAssistantReplyLineEndsToolXmlBlock(trimmed)) {
                inToolBlock = true
            }
            continue
        }
        if (inToolBlock) {
            if (gatewayAssistantReplyLineEndsToolXmlBlock(trimmed)) {
                inToolBlock = false
            }
            continue
        }
        if (out.size > 0) { out.append("\n") }
        out.append(line)
    }
    out.toString().trimAscii()
}

public func safeFallbackTextForBlockedAssistantReply(status: String): String {
    "模型返回了工具调用协议而不是最终回复，已拦截。请重试或切换模型。"
}

public func gatewayAssistantReplyDiagnosticHash(raw: String): String {
    "reply-${raw.size}-${raw.toRuneArray().size}"
}

private func gatewayAssistantReplyParseFullJson(trimmed: String): ?JsonValue {
    if (trimmed.isEmpty()) {
        return None<JsonValue>
    }
    try {
        Some(JsonValue.fromStr(trimmed))
    } catch (_: Exception) {
        None<JsonValue>
    }
}

private func gatewayAssistantReplyExtractTerminalAnswerFromObject(obj: JsonObject): ?String {
    let name = gatewayAssistantReplyJsonString(obj, "name").toAsciiLower()
    if (name == "_answer_" || name == "answer") {
        match (obj.get("arguments")) {
            case Some(argsValue) =>
                let args = try { argsValue.asObject() } catch (_: Exception) { JsonObject() }
                let result = gatewayAssistantReplyJsonString(args, "result")
                if (!result.isEmpty()) { return Some(result) }
                let answer = gatewayAssistantReplyJsonString(args, "answer")
                if (!answer.isEmpty()) { return Some(answer) }
            case None => ()
        }
    }
    let tool = gatewayAssistantReplyJsonString(obj, "tool").toAsciiLower()
    if (tool == "final_answer" || tool == "functions.final_answer" || tool == "_answer_" || tool == "functions._answer_") {
        let answer = gatewayAssistantReplyJsonString(obj, "answer")
        if (!answer.isEmpty()) { return Some(answer) }
        let result = gatewayAssistantReplyJsonString(obj, "result")
        if (!result.isEmpty()) { return Some(result) }
        match (obj.get("arguments")) {
            case Some(argsValue) =>
                let args = try { argsValue.asObject() } catch (_: Exception) { JsonObject() }
                let argsAnswer = gatewayAssistantReplyJsonString(args, "answer")
                if (!argsAnswer.isEmpty()) { return Some(argsAnswer) }
                let argsResult = gatewayAssistantReplyJsonString(args, "result")
                if (!argsResult.isEmpty()) { return Some(argsResult) }
            case None => ()
        }
    }
    None<String>
}

private func gatewayAssistantReplyJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayAssistantReplyObjectHasToolShape(obj: JsonObject): Bool {
    for ((key, value) in obj.getFields()) {
        let normalizedKey = key.trimAscii()
        if (normalizedKey == "tool" ||
            normalizedKey == "name" ||
            normalizedKey == "arguments" ||
            normalizedKey == "function_call" ||
            normalizedKey == "tool_calls") {
            return true
        }
        if (gatewayAssistantReplyValueHasToolShape(value)) {
            return true
        }
    }
    false
}

private func gatewayAssistantReplyArrayHasToolShape(arr: JsonArray): Bool {
    for (item in arr.getItems()) {
        if (gatewayAssistantReplyValueHasToolShape(item)) {
            return true
        }
    }
    false
}

private func gatewayAssistantReplyValueHasToolShape(value: JsonValue): Bool {
    let text = try { value.asString().getValue().trimAscii().toAsciiLower() } catch (_: Exception) { "" }
    if (!text.isEmpty()) {
        return text.contains("functions._answer_") ||
            text.contains("functions.answer") ||
            text.contains("to=functions.") ||
            text.contains("\"tool\"") ||
            text.contains("\"tool_calls\"") ||
            text.contains("\"function_call\"")
    }
    let obj = try { value.asObject() } catch (_: Exception) { JsonObject() }
    if (!obj.getFields().isEmpty()) {
        return gatewayAssistantReplyObjectHasToolShape(obj)
    }
    let arr = try { value.asArray() } catch (_: Exception) { JsonArray([]) }
    gatewayAssistantReplyArrayHasToolShape(arr)
}

private func gatewayAssistantReplyLineStartsToolXmlBlock(trimmed: String): Bool {
    let lower = trimmed.toAsciiLower()
    lower.startsWith("<tool_call") ||
        lower.startsWith("<tool_calls") ||
        lower.startsWith("<function_call") ||
        lower.startsWith("<function_calls")
}

private func gatewayAssistantReplyLineEndsToolXmlBlock(trimmed: String): Bool {
    let lower = trimmed.toAsciiLower()
    lower.contains("</tool_call>") ||
        lower.contains("</tool_calls>") ||
        lower.contains("</function_call>") ||
        lower.contains("</function_calls>")
}

private func gatewayAssistantReplyLooksLikeToolProtocolPrefix(raw: String): Bool {
    let lower = raw.trimAscii().toAsciiLower()
    if (lower.startsWith("{\"name\":\"") ||
        lower.startsWith("{\"tool\":\"") ||
        lower.startsWith("{\"arguments\"") ||
        lower.startsWith("{\"function_call\"") ||
        lower.startsWith("{\"tool_calls\"")) {
        return true
    }
    lower.startsWith("<tool_call") ||
        lower.startsWith("<tool_calls") ||
        lower.startsWith("<function_call") ||
        lower.startsWith("<function_calls") ||
        detectHarmonyToolLeak(lower)
}
