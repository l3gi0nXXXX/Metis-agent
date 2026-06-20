package metis.core.model

import magic.core.message.{Message, MessageRole}
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}

import std.collection.ArrayList
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

    private func createFromNormalized(normalized: CodexResponsesNormalized): ChatResponse {
        return ChatResponse(
            if (normalized.model.isEmpty()) { this.fullName } else { normalized.model },
            Message.assistant(normalized.content),
            toolRequests: normalized.toolRequests,
            usage: normalized.usage
        )
    }

    private prop usesCodexStreamingBackend: Bool {
        get() {
            codexResponsesIssuerKind(this.provider, baseUrl: this.baseUrl) == "codex_backend"
        }
    }

    private func normalizeRequest(request: ChatRequest): CodexResponsesNormalized {
        let payload = this.buildPayload(request)
        if (this.usesCodexStreamingBackend) {
            return this.client.streamResponses(
                this.baseUrl,
                this.accessToken,
                payload,
                extraHeaders: codexResponsesExtraHeaders(this.sessionId),
                model: this.name
            )
        }
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
        return normalized
    }

    private func lastUserPrompt(request: ChatRequest): String {
        var prompt = ""
        for (message in request.messageList) {
            if (message.role == MessageRole.User) {
                prompt = message.content
            }
        }
        return prompt
    }

    private func continuationRequest(request: ChatRequest, previousContent: String, attempt: Int64): ChatRequest {
        let messages = ArrayList<Message>()
        for (message in request.messageList) {
            messages.add(message)
        }
        if (!previousContent.trimAscii().isEmpty()) {
            messages.add(Message.assistant(previousContent))
        }
        messages.add(Message.user(codexContinuationPrompt(previousContent, attempt)))
        return ChatRequest(
            messages.toArray(),
            temperature: request.temperature,
            stop: request.stop,
            tools: request.tools,
            maxTokens: request.maxTokens
        )
    }

    private func continuationNeeded(originalRequest: ChatRequest, normalized: CodexResponsesNormalized): Bool {
        if (normalized.toolRequests.size > 0) {
            return false
        }
        if (normalized.finishReason == "incomplete") {
            return true
        }
        return codexContinuationNeeded(this.lastUserPrompt(originalRequest), normalized.content, normalized.toolRequests.size)
    }

    override public func create(request: ChatRequest): ChatResponse {
        var currentRequest = request
        var normalized = this.normalizeRequest(currentRequest)
        var attempt: Int64 = 0
        while (this.continuationNeeded(request, normalized) && attempt < 2) {
            attempt += 1
            currentRequest = this.continuationRequest(currentRequest, normalized.content, attempt)
            normalized = this.normalizeRequest(currentRequest)
        }
        if (normalized.finishReason == "incomplete" && normalized.toolRequests.size == 0) {
            throw CodexResponsesException(
                "tool_protocol_unfinalized",
                "Codex Responses did not converge to a structured tool call or final assistant text"
            )
        }
        return this.createFromNormalized(normalized)
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
