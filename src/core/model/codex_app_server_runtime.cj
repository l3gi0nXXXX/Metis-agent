package metis.core.model

import std.collection.{ArrayList, HashMap}
import std.env.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public class CodexAppServerLaunchSpec {
    public let command: String
    public let args: Array<String>

    public init(command: String, args: Array<String>) {
        this.command = command.trimAscii()
        this.args = args
    }
}

public class CodexAppServerRetireDecision {
    public let shouldRetire: Bool
    public let reason: String

    public init(shouldRetire: Bool, reason!: String = "") {
        this.shouldRetire = shouldRetire
        this.reason = reason.trimAscii()
    }
}

public class CodexAppServerMcpDispatchResult {
    public let ok: Bool
    public let status: String
    public let result: JsonObject
    public let error: String

    public init(ok: Bool, status!: String = "ok", result!: JsonObject = JsonObject(), error!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.result = result
        this.error = error.trimAscii()
    }
}

public func codexAppServerBuildLaunchSpec(codexBin!: String = "codex", extraArgs!: Array<String> = []): CodexAppServerLaunchSpec {
    let bin = if (codexBin.trimAscii().isEmpty()) { "codex" } else { codexBin.trimAscii() }
    let args = ArrayList<String>()
    args.add("app-server")
    for (arg in extraArgs) {
        args.add(arg)
    }
    CodexAppServerLaunchSpec(bin, args.toArray())
}

public func codexAppServerBuildEnvironment(
    parentEnv!: HashMap<String, String> = codexAppServerCurrentEnvironment(),
    codexHome!: Option<String> = None<String>
): HashMap<String, String> {
    let env = HashMap<String, String>()
    for ((key, value) in parentEnv) {
        let normalized = key.trimAscii()
        if (normalized.isEmpty() || codexAppServerIsForbiddenTokenEnvKey(normalized)) {
            continue
        }
        env[normalized] = value
    }
    if (!env.contains("RUST_LOG")) {
        env["RUST_LOG"] = "warn"
    }
    match (codexHome) {
        case Some(home) =>
            let normalizedHome = home.trimAscii()
            if (!normalizedHome.isEmpty()) {
                env["CODEX_HOME"] = normalizedHome
            }
        case None => ()
    }
    env
}

public func codexAppServerCurrentEnvironment(): HashMap<String, String> {
    let env = HashMap<String, String>()
    for ((key, value) in getVariables()) {
        env[key] = value
    }
    env
}

public func codexAppServerLoginHint(message!: String = ""): String {
    let details = message.trimAscii()
    if (details.isEmpty()) {
        return "Codex app-server authentication failed. Run `codex login` and retry."
    }
    "Codex app-server authentication failed: ${codexAppServerRedactDiagnostic(details)}. Run `codex login` and retry."
}

public func codexAppServerLooksLikeAuthFailure(message: String): Bool {
    let lower = message.toAsciiLower()
    lower.contains("invalid_grant") ||
        lower.contains("refresh token") ||
        lower.contains("token expired") ||
        lower.contains("expired token") ||
        lower.contains("not authenticated") ||
        lower.contains("unauthorized") ||
        lower.contains("oauth") ||
        lower.contains("login required") ||
        lower.contains("authentication")
}

public func codexAppServerRetireForFailure(status: String, message!: String = ""): CodexAppServerRetireDecision {
    let lowerStatus = status.trimAscii().toAsciiLower()
    let lowerMessage = message.trimAscii().toAsciiLower()
    if (lowerStatus == "startup_failure" || lowerStatus == "process_dead" || lowerStatus == "turn_timeout" ||
        lowerStatus == "post_tool_quiet_timeout" || lowerStatus == "turn_aborted" ||
        lowerMessage.contains("<turn_aborted>") || codexAppServerLooksLikeAuthFailure(message)) {
        return CodexAppServerRetireDecision(true, reason: if (status.trimAscii().isEmpty()) { "codex_app_server_failure" } else { status.trimAscii() })
    }
    CodexAppServerRetireDecision(false, reason: if (status.trimAscii().isEmpty()) { "model_failure" } else { status.trimAscii() })
}

public func codexAppServerRedactDiagnostic(raw: String): String {
    let parts = raw.replace("\n", " ").replace("\r", " ").split(" ")
    let out = ArrayList<String>()
    var redactNext = false
    for (part in parts) {
        if (part.isEmpty()) {
            continue
        }
        let lower = part.toAsciiLower()
        if (redactNext) {
            out.add("[redacted]")
            redactNext = false
            continue
        }
        if (lower == "bearer" || lower == "authorization:" || lower == "authorization") {
            out.add(part)
            redactNext = true
            continue
        }
        if (lower.contains("token=") || lower.contains("access_token=") || lower.contains("refresh_token=") ||
            lower.contains("authorization=") || lower.startsWith("sk-") || part.size > 96) {
            out.add("[redacted]")
            continue
        }
        out.add(part)
    }
    String.join(out.toArray(), delimiter: " ")
}

public func codexAppServerMcpExposedTools(): Array<String> {
    [
        "web_search",
        "web_extract",
        "browser_open",
        "browser_click",
        "browser_type",
        "browser_screenshot",
        "vision_analyze",
        "image_generate",
        "skill_list",
        "skill_view",
        "text_to_speech",
        "kanban_list",
        "kanban_update"
    ]
}

public func codexAppServerMcpForbiddenTools(): Array<String> {
    [
        "shell",
        "terminal",
        "exec",
        "read_file",
        "write_file",
        "apply_patch",
        "search_files",
        "process",
        "delegate_task",
        "memory",
        "session_search",
        "todo"
    ]
}

public func codexAppServerDispatchMetisMcpTool(toolName: String, arguments!: JsonObject = JsonObject()): CodexAppServerMcpDispatchResult {
    let normalized = toolName.trimAscii()
    let lower = normalized.toAsciiLower()
    for (forbidden in codexAppServerMcpForbiddenTools()) {
        if (lower == forbidden || lower.contains(forbidden)) {
            return CodexAppServerMcpDispatchResult(false, status: "forbidden", error: "tool is not exposed to Codex app-server")
        }
    }
    for (allowed in codexAppServerMcpExposedTools()) {
        if (lower == allowed) {
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("status", JsonString("accepted_for_gateway_integration"))
            out.put("tool", JsonString(normalized))
            out.put("arguments", arguments)
            return CodexAppServerMcpDispatchResult(true, result: out)
        }
    }
    CodexAppServerMcpDispatchResult(false, status: "not_applicable", error: "tool is not registered for Metis Codex app-server")
}

private func codexAppServerIsForbiddenTokenEnvKey(key: String): Bool {
    let lower = key.toAsciiLower()
    lower == "metis_openai_codex_access_token" ||
        lower == "openai_codex_access_token" ||
        lower == "openai_access_token" ||
        lower == "authorization" ||
        lower == "oauth_access_token" ||
        lower == "oauth_refresh_token"
}
