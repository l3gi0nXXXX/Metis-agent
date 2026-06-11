package metis.core.model

import magic.core.model.ChatUsage
import magic.core.tool.ToolRequest

import std.collection.HashMap
import stdx.encoding.json.{JsonArray, JsonObject}

public class CodexResponsesException <: Exception {
    public let code: String

    public CodexResponsesException(
        code: String,
        message: String
    ) {
        super(message)
        this.code = code
    }
}

public struct CodexResponsesHttpRequest {
    public CodexResponsesHttpRequest(
        public let method: String,
        public let url: String,
        public let headers: HashMap<String, String>,
        public let body: JsonObject,
        public let stream!: Bool = false,
        public let timeoutMs!: Int64 = 0
    ) { }
}

public struct CodexResponsesHttpResult {
    public CodexResponsesHttpResult(
        public let statusCode: Int64,
        public let body!: String = "",
        public let streamEvents!: Array<JsonObject> = [],
        public let closeReason!: String = "",
        public let retryCount!: Int64 = 0,
        public let error!: String = ""
    ) { }
}

public struct CodexResponsesBuildOptions {
    public CodexResponsesBuildOptions(
        public let providerId!: String = "openai-codex",
        public let apiMode!: String = "codex_responses",
        public let baseUrl!: String = "https://chatgpt.com/backend-api/codex",
        public let sessionId!: String = "",
        public let reasoningEffort!: String = "medium",
        public let replayEncryptedReasoning!: Bool = true,
        public let isCodexBackend!: Bool = true,
        public let isXaiResponses!: Bool = false,
        public let isGithubResponses!: Bool = false,
        public let globalFastMode!: Bool = false,
        public let timeoutMs!: Int64 = 0
    ) { }
}

public struct CodexResponsesNormalized {
    public CodexResponsesNormalized(
        public let model: String,
        public let content: String,
        public let toolRequests: Array<ToolRequest>,
        public let reasoningItems: JsonArray,
        public let messageItems: JsonArray,
        public let finishReason: String,
        public let usage!: Option<ChatUsage> = None
    ) { }
}

public struct CodexResponsesWatchdogDecision {
    public CodexResponsesWatchdogDecision(
        public let action: String,
        public let closeReason: String,
        public let timeoutSeconds: Float64,
        public let message: String
    ) { }
}

public struct CodexAuxiliaryClientDecision {
    public CodexAuxiliaryClientDecision(
        public let provider: String,
        public let model: String,
        public let clientKind: String,
        public let available: Bool,
        public let reason: String,
        public let headers!: JsonObject = JsonObject()
    ) { }
}
