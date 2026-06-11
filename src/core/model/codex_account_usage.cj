package metis.core.model

import std.convert.Parsable
import stdx.encoding.json.{JsonFloat, JsonInt, JsonObject, JsonString}

private func codexUsageTrimBaseUrl(raw: String): String {
    var value = raw.trimAscii()
    while (value.size > 1 && value.endsWith("/")) {
        value = value[..value.size - 1]
    }
    value
}

private func codexAccountUsageString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(value) =>
            try {
                value.asString().getValue().trimAscii()
            } catch (_: Exception) {
                ""
            }
        case None => ""
    }
}

private func codexAccountUsageInt(root: JsonObject, key: String): Int64 {
    match (root.get(key)) {
        case Some(value) =>
            try {
                return value.asInt().getValue()
            } catch (_: Exception) {
                ()
            }
            try {
                return Int64.parse(value.asString().getValue().trimAscii())
            } catch (_: Exception) {
                ()
            }
            0
        case None => 0
    }
}

private func codexAccountUsageFloat(root: JsonObject, key: String): Float64 {
    match (root.get(key)) {
        case Some(value) =>
            try {
                return Float64.parse(value.toJsonString())
            } catch (_: Exception) {
                ()
            }
            try {
                return Float64.parse(value.asString().getValue().trimAscii())
            } catch (_: Exception) {
                ()
            }
            0.0
        case None => 0.0
    }
}

public func resolveOpenAICodexUsageUrl(baseUrl: String): String {
    let normalized = codexUsageTrimBaseUrl(baseUrl)
    let lower = normalized.toAsciiLower()
    if (lower == "https://chatgpt.com/backend-api" || lower.startsWith("https://chatgpt.com/backend-api/codex")) {
        return "https://chatgpt.com/backend-api/codex/wham/usage"
    }
    if (normalized.isEmpty()) {
        return "https://chatgpt.com/backend-api/codex/wham/usage"
    }
    "${normalized}/api/codex/usage"
}

public func parseOpenAICodexAccountUsage(payload: JsonObject): JsonObject {
    let out = JsonObject()
    let plan = codexAccountUsageString(payload, "plan")
    out.put("plan", JsonString(if (plan.isEmpty()) { "unknown" } else { plan }))
    let sessionLimit = codexAccountUsageInt(payload, "sessionLimit")
    let weeklyLimit = codexAccountUsageInt(payload, "weeklyLimit")
    let credits = codexAccountUsageFloat(payload, "credits")
    out.put("sessionLimit", JsonInt(sessionLimit))
    out.put("weeklyLimit", JsonInt(weeklyLimit))
    out.put("credits", JsonFloat(credits))
    out
}

public func codexAccountUsageNotApplicable(): JsonObject {
    let out = JsonObject()
    out.put("status", JsonString("not-applicable"))
    out.put("reason", JsonString("Metis does not expose a user-facing OpenAI Codex account usage command yet."))
    out
}

public func renderOpenAICodexUsage(snapshot: JsonObject): String {
    let status = codexAccountUsageString(snapshot, "status")
    if (status == "not-applicable") {
        return "OpenAI Codex usage: not applicable - ${codexAccountUsageString(snapshot, "reason")}"
    }
    let plan = codexAccountUsageString(snapshot, "plan")
    let sessionLimit = codexAccountUsageInt(snapshot, "sessionLimit")
    let weeklyLimit = codexAccountUsageInt(snapshot, "weeklyLimit")
    let credits = codexAccountUsageFloat(snapshot, "credits")
    "OpenAI Codex usage: plan=${if (plan.isEmpty()) { "unknown" } else { plan }}, sessionLimit=${sessionLimit}, weeklyLimit=${weeklyLimit}, credits=${credits}"
}
