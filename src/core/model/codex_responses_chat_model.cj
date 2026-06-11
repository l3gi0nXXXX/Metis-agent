package metis.core.model

import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}

import stdx.encoding.json.{JsonInt, JsonObject}

public class CodexResponsesChatModel <: ChatModel {
    private let _provider: String
    private let _name: String
    private let baseUrl: String
    private let accessToken: String
    private let sessionId: String
    private let client: CodexResponsesHttpClient
    private var _maxTokens: Option<Int64> = None
    private let _contextLength: Int64

    public init(
        model: String,
        baseUrl: String,
        accessToken: String,
        provider!: String = "openai-codex",
        sessionId!: String = "",
        contextLength!: Int64 = 0,
        client!: CodexResponsesHttpClient = CodexResponsesHttpClient()
    ) {
        this._provider = provider
        this._name = model
        this.baseUrl = baseUrl
        this.accessToken = accessToken
        this.sessionId = sessionId
        this.client = client
        this._contextLength = if (contextLength > 0) {
            contextLength
        } else {
            codexResolveDisplayContextLength(provider, "${provider}:${model}")
        }
    }

    override public prop provider: String {
        get() { this._provider }
    }

    override public prop name: String {
        get() { this._name }
    }

    override public prop contextLength: Int64 {
        get() { this._contextLength }
    }

    override public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(value) { this._maxTokens = value }
    }

    private func buildPayload(request: ChatRequest): JsonObject {
        let options = CodexResponsesBuildOptions(
            providerId: this.provider,
            baseUrl: this.baseUrl,
            sessionId: this.sessionId,
            isCodexBackend: this.provider == "openai-codex"
        )
        let payload = codexBuildResponsesPayload(this.name, request, options: options)
        if (payload.get("max_output_tokens").isNone()) {
            if (let Some(tokens) <- this._maxTokens) {
                if (this.provider != "openai-codex") {
                    payload.put("max_output_tokens", JsonInt(tokens))
                }
            }
        }
        return payload
    }

    override public func create(request: ChatRequest): ChatResponse {
        let payload = this.buildPayload(request)
        let response = this.client.postResponses(
            this.baseUrl,
            this.accessToken,
            payload,
            extraHeaders: codexResponsesExtraHeaders(this.sessionId)
        )
        let normalized = codexNormalizeResponses(
            response,
            issuerKind: codexResponsesIssuerKind(this.provider, baseUrl: this.baseUrl)
        )
        return ChatResponse(
            if (normalized.model.isEmpty()) { this.fullName } else { normalized.model },
            Message.assistant(normalized.content),
            toolRequests: normalized.toolRequests,
            usage: normalized.usage
        )
    }

    override public func asyncCreate(request: ChatRequest): AsyncChatResponse {
        let payload = this.buildPayload(request)
        let _normalized = this.client.streamResponses(
            this.baseUrl,
            this.accessToken,
            payload,
            extraHeaders: codexResponsesExtraHeaders(this.sessionId),
            model: this.name
        )
        throw CodexResponsesException("async_response_factory_unavailable", "Codex Responses stream normalized successfully, but Magic AsyncChatResponse has no public constructor in the Metis module")
    }
}

public func createCodexResponsesChatModel(
    model: String,
    baseUrl: String,
    accessToken: String,
    provider!: String = "openai-codex",
    sessionId!: String = ""
): ChatModel {
    return CodexResponsesChatModel(model, baseUrl, accessToken, provider: provider, sessionId: sessionId)
}

public func shouldBuildCodexResponsesModel(provider: String, apiMode: String): Bool {
    return provider.toAsciiLower() == "openai-codex" || apiMode == "codex_responses"
}
