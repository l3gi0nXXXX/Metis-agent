package metis.core.model

import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}

import metis.core.config.{MetisConfigManager, readOpenAICodexOAuthProfile}

import std.time.DateTime

public class CodexAuthUnavailableChatModel <: ChatModel {
    private let _provider: String
    private let _name: String
    private let reason: String
    private var _maxTokens: Option<Int64> = None

    public init(provider: String, modelName: String, reason: String) {
        this._provider = provider.trimAscii()
        this._name = modelName.trimAscii()
        this.reason = reason.trimAscii()
    }

    override public prop provider: String {
        get() { this._provider }
    }

    override public prop name: String {
        get() { this._name }
    }

    override public prop contextLength: Int64 {
        get() { codexResolveDisplayContextLength(this._provider, this.fullName) }
    }

    override public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(value) { this._maxTokens = value }
    }

    override public func create(_request: ChatRequest): ChatResponse {
        throw Exception(this.reason)
    }

    override public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception(this.reason)
    }
}

private func codexFactoryProviderAndModel(modelRef: String): (String, String) {
    let canonical = MetisConfigManager.canonicalModelRef(modelRef).trimAscii()
    if (canonical.contains(":")) {
        let parts = canonical.split(":")
        if (parts.size >= 2) {
            return (parts[0].trimAscii().toAsciiLower(), String.join(parts[1..parts.size], delimiter: ":").trimAscii())
        }
    }
    if (canonical.contains("/")) {
        let parts = canonical.split("/")
        if (parts.size >= 2) {
            return (parts[0].trimAscii().toAsciiLower(), String.join(parts[1..parts.size], delimiter: "/").trimAscii())
        }
    }
    ("", canonical)
}

public func codexResponsesModelProviderId(modelRef: String): String {
    codexFactoryProviderAndModel(modelRef)[0]
}

public func codexResponsesModelName(modelRef: String): String {
    codexFactoryProviderAndModel(modelRef)[1]
}

public func buildOpenAICodexResponsesChatModelForRef(modelRef: String): ChatModel {
    let parsed = codexFactoryProviderAndModel(modelRef)
    let provider = if (parsed[0].isEmpty()) { "openai-codex" } else { parsed[0] }
    let modelName = parsed[1]
    match (readOpenAICodexOAuthProfile()) {
        case Some(profile) =>
            let now = DateTime.now().toUnixTimeStamp().toSeconds()
            if (profile.expiresAtUnixSeconds <= now) {
                return CodexAuthUnavailableChatModel(
                    provider,
                    modelName,
                    "OpenAI Codex OAuth token is expired. Run `metis models auth openai-codex login`."
                )
            }
            return CodexResponsesChatModel(
                modelName,
                if (profile.baseUrl.trimAscii().isEmpty()) { "https://chatgpt.com/backend-api/codex" } else { profile.baseUrl },
                profile.accessToken,
                provider: provider
            )
        case None =>
            CodexAuthUnavailableChatModel(
                provider,
                modelName,
                "OpenAI Codex OAuth is not configured. Run `metis models auth openai-codex login`."
            )
    }
}
