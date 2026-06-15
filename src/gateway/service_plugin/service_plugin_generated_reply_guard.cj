package metis.gateway.service_plugin

import stdx.encoding.json.{JsonArray, JsonObject, JsonValue}

public class ServicePluginGeneratedReplyGuardResult {
    public let ok: Bool
    public let status: String
    public let draft: String
    public let diagnostic: String
    public let needsHumanReview: Bool
    public let diagnosticHash: String

    public init(
        ok: Bool,
        status!: String = "",
        draft!: String = "",
        diagnostic!: String = "",
        needsHumanReview!: Bool = false,
        diagnosticHash!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.draft = draft.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.needsHumanReview = needsHumanReview
        this.diagnosticHash = diagnosticHash.trimAscii()
    }
}

public func validateServicePluginGeneratedDraft(rawDraft: String): ServicePluginGeneratedReplyGuardResult {
    let trimmed = rawDraft.trimAscii()
    if (trimmed.isEmpty()) {
        return servicePluginDraftGuardRejected("draft_empty", "", diagnostic: "Agent Runtime returned empty draft")
    }
    if (trimmed.startsWith("Gateway agent failed:")) {
        let redacted = redactServicePayload(trimmed)
        return servicePluginDraftGuardRejected("llm_degraded", "", diagnostic: "Agent Runtime failed; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
    }

    let redacted = redactServicePayload(trimmed)
    if (redacted.text == "[REDACTED_LOCAL_PATH]") {
        return servicePluginDraftGuardRejected("draft_contains_local_path", "", diagnostic: "Generated draft contains a local path; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
    }
    if (redacted.text == "[REDACTED]") {
        return servicePluginDraftGuardRejected("draft_contains_secret", "", diagnostic: "Generated draft contains sensitive content; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
    }

    match (servicePluginDraftParseFullJson(trimmed)) {
        case Some(value) =>
            if (servicePluginDraftJsonValueIsObject(value)) {
                let obj = value.asObject()
                if (servicePluginDraftJsonObjectHasToolShape(obj)) {
                    return servicePluginDraftGuardRejected("draft_invalid_tool_json", "", diagnostic: "Generated draft is tool-call JSON; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
                }
                return servicePluginDraftGuardRejected("draft_raw_json", "", diagnostic: "Generated draft is raw JSON; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
            }
            if (servicePluginDraftJsonValueIsArray(value)) {
                return servicePluginDraftGuardRejected("draft_raw_json", "", diagnostic: "Generated draft is raw JSON array; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
            }
            return servicePluginDraftGuardRejected("draft_raw_json_scalar", "", diagnostic: "Generated draft is raw JSON scalar; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
        case None => ()
    }

    if (servicePluginDraftContainsForbiddenMarker(trimmed)) {
        return servicePluginDraftGuardRejected("draft_forbidden_marker", "", diagnostic: "Generated draft contains forbidden service marker; diagnosticHash=${redacted.rawHash}", diagnosticHash: redacted.rawHash)
    }

    ServicePluginGeneratedReplyGuardResult(true, status: "draft_generated", draft: trimmed, needsHumanReview: false, diagnosticHash: redacted.rawHash)
}

public func servicePluginGeneratedReplyResultFromAgentAnswer(rawAnswer: String): ServicePluginGeneratedReplyResult {
    let guard = validateServicePluginGeneratedDraft(rawAnswer)
    if (guard.ok) {
        return ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: guard.draft)
    }
    ServicePluginGeneratedReplyResult(false, status: guard.status, diagnostic: guard.diagnostic, needsHumanReview: true)
}

public func normalizeServicePluginGeneratedReplyResult(result: ServicePluginGeneratedReplyResult): ServicePluginGeneratedReplyResult {
    if (result.ok && !result.needsHumanReview) {
        let guard = validateServicePluginGeneratedDraft(result.draft)
        if (!guard.ok) {
            return ServicePluginGeneratedReplyResult(false, status: guard.status, diagnostic: guard.diagnostic, needsHumanReview: true)
        }
        return ServicePluginGeneratedReplyResult(true, status: result.status, draft: guard.draft, diagnostic: result.diagnostic, needsHumanReview: false)
    }
    result
}

private func servicePluginDraftGuardRejected(
    status: String,
    draft: String,
    diagnostic!: String,
    diagnosticHash!: String = ""
): ServicePluginGeneratedReplyGuardResult {
    ServicePluginGeneratedReplyGuardResult(false, status: status, draft: draft, diagnostic: diagnostic, needsHumanReview: true, diagnosticHash: diagnosticHash)
}

private func servicePluginDraftParseFullJson(trimmed: String): ?JsonValue {
    try {
        Some(JsonValue.fromStr(trimmed))
    } catch (_: Exception) {
        None<JsonValue>
    }
}

private func servicePluginDraftJsonValueIsObject(value: JsonValue): Bool {
    try {
        let _ = value.asObject()
        true
    } catch (_: Exception) {
        false
    }
}

private func servicePluginDraftJsonValueIsArray(value: JsonValue): Bool {
    try {
        let _ = value.asArray()
        true
    } catch (_: Exception) {
        false
    }
}

private func servicePluginDraftJsonObjectHasToolShape(obj: JsonObject): Bool {
    for ((key, value) in obj.getFields()) {
        let normalizedKey = key.trimAscii()
        if (normalizedKey == "tool" ||
            normalizedKey == "name" ||
            normalizedKey == "arguments" ||
            normalizedKey == "function_call" ||
            normalizedKey == "tool_calls") {
            return true
        }
        if (servicePluginDraftJsonValueContainsAnswerTool(value)) {
            return true
        }
    }
    false
}

private func servicePluginDraftJsonValueContainsAnswerTool(value: JsonValue): Bool {
    let text = try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
    if (!text.isEmpty() && (text.contains("_answer_") || text.contains("functions._answer_"))) {
        return true
    }
    let obj = try { value.asObject() } catch (_: Exception) { JsonObject() }
    if (!obj.getFields().isEmpty()) {
        return servicePluginDraftJsonObjectHasToolShape(obj)
    }
    let arr = try { value.asArray() } catch (_: Exception) { JsonArray([]) }
    for (item in arr.getItems()) {
        if (servicePluginDraftJsonValueContainsAnswerTool(item)) {
            return true
        }
    }
    false
}

private func servicePluginDraftContainsForbiddenMarker(text: String): Bool {
    let lower = text.toAsciiLower()
    lower.contains("auto-reply") ||
        lower.contains("gitcodemonitor") ||
        lower.contains("<!--") ||
        lower.contains("hidden marker") ||
        lower.contains("bot attribution") ||
        lower.contains("functions._answer_") ||
        lower.contains("functions.answer") ||
        lower.contains("\"_answer_\"") ||
        lower.contains("tool_call") ||
        lower.contains("toolcalls") ||
        servicePluginDraftLooksLikeJsonFence(lower)
}

private func servicePluginDraftLooksLikeJsonFence(lower: String): Bool {
    let trimmed = lower.trimAscii()
    if (trimmed.startsWith("```json")) {
        return true
    }
    trimmed.startsWith("```\n{") || trimmed.startsWith("```\n[")
}
