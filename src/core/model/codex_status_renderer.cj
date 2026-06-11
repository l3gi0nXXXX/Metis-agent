package metis.core.model

import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

private func codexStatusString(root: JsonObject, key: String): String {
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

private func codexStatusBool(root: JsonObject, key: String): Bool {
    match (root.get(key)) {
        case Some(value) =>
            try {
                value.asBool().getValue()
            } catch (_: Exception) {
                false
            }
        case None => false
    }
}

public func redactOpenAICodexTokenPreview(token: String): String {
    let trimmed = token.trimAscii()
    if (trimmed.isEmpty()) {
        return ""
    }
    if (trimmed.size <= 10) {
        return "redacted"
    }
    "${trimmed[0..6]}...${trimmed[trimmed.size - 4..trimmed.size]}"
}

public func renderOpenAICodexStatusLine(status: JsonObject): String {
    let loggedIn = codexStatusBool(status, "loggedIn") || codexStatusString(status, "status").toAsciiLower() == "logged_in"
    let sourceLabel = codexStatusString(status, "sourceLabel")
    let source = if (!sourceLabel.isEmpty()) { sourceLabel } else { codexStatusString(status, "source") }
    let refreshed = codexStatusString(status, "lastRefresh")
    if (loggedIn) {
        let sb = StringBuilder()
        sb.append("OpenAI Codex: logged in")
        if (!source.isEmpty()) {
            sb.append(" (")
            sb.append(source)
            sb.append(")")
        }
        if (!refreshed.isEmpty()) {
            sb.append("; refreshed ")
            sb.append(refreshed)
        }
        return sb.toString()
    }
    let error = codexStatusString(status, "error")
    if (!error.isEmpty()) {
        return "OpenAI Codex: not logged in (run: metis models auth openai-codex login); ${error}"
    }
    "OpenAI Codex: not logged in (run: metis models auth openai-codex login)"
}

public func renderOpenAICodexDashboardStatus(status: JsonObject): JsonObject {
    let out = JsonObject()
    let loggedIn = codexStatusBool(status, "loggedIn") || codexStatusString(status, "status").toAsciiLower() == "logged_in"
    out.put("provider", JsonString("openai-codex"))
    out.put("loggedIn", JsonBool(loggedIn))
    out.put("status", JsonString(if (loggedIn) { "logged_in" } else { "not_logged_in" }))
    out.put("message", JsonString(renderOpenAICodexStatusLine(status)))
    let preview = codexStatusString(status, "tokenPreview")
    let token = codexStatusString(status, "accessToken")
    let safePreview = if (!preview.isEmpty()) { preview } else { redactOpenAICodexTokenPreview(token) }
    if (!safePreview.isEmpty()) {
        out.put("tokenPreview", JsonString(safePreview))
    }
    out
}

public func renderOpenAICodexDoctorStatus(status: JsonObject, codexCliPresent: Bool): String {
    let loggedIn = codexStatusBool(status, "loggedIn") || codexStatusString(status, "status").toAsciiLower() == "logged_in"
    let base = renderOpenAICodexStatusLine(status)
    if (!loggedIn && !codexCliPresent) {
        return "${base}\nCodex CLI: optional, only needed to import tokens from an existing `codex login` or to use codex_app_server runtime."
    }
    base
}

public func renderCodexRuntimeBanner(openaiRuntime: String): String {
    if (openaiRuntime.trimAscii().toAsciiLower() != "codex_app_server") {
        return ""
    }
    "Runtime: codex app-server\nTerminal, file operations, and MCP tools run inside the Codex app-server process for this runtime."
}
