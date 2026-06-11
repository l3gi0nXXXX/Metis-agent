package metis.core.model

public class CodexAuxiliaryRuntimeDecision {
    public let applicable: Bool
    public let mode: String
    public let reason: String

    public init(applicable: Bool, mode: String, reason: String) {
        this.applicable = applicable
        this.mode = mode.trimAscii()
        this.reason = reason.trimAscii()
    }
}

public func codexAuxiliaryRuntimeMode(parentRuntime: String): CodexAuxiliaryRuntimeDecision {
    let runtime = parentRuntime.trimAscii().toAsciiLower()
    if (runtime == "codex_app_server") {
        return CodexAuxiliaryRuntimeDecision(
            true,
            "codex_responses",
            "auxiliary tasks must not inherit the native codex app-server process"
        )
    }
    if (runtime == "codex_responses") {
        return CodexAuxiliaryRuntimeDecision(true, "codex_responses", "parent runtime already uses codex_responses")
    }
    CodexAuxiliaryRuntimeDecision(true, "metis_tool_loop", "parent runtime uses the default Metis tool loop")
}

public func codexAuxiliaryProviderFromBaseUrl(baseUrl: String): String {
    let normalized = baseUrl.trimAscii().toAsciiLower()
    if (normalized == "https://chatgpt.com/backend-api/codex" ||
        normalized.startsWith("https://chatgpt.com/backend-api/codex/")) {
        return "codex"
    }
    ""
}
