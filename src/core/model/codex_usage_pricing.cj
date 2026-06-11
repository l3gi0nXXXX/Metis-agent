package metis.core.model

import std.convert.Parsable
import stdx.encoding.json.JsonObject

public class CodexBillingRoute {
    public let provider: String
    public let billingMode: String
    public let costStatus: String
    public let estimatedAmount: Float64

    public init(provider: String, billingMode: String, costStatus: String, estimatedAmount: Float64) {
        this.provider = provider.trimAscii().toAsciiLower()
        this.billingMode = billingMode.trimAscii()
        this.costStatus = costStatus.trimAscii()
        this.estimatedAmount = estimatedAmount
    }
}

public class CodexResponsesUsageSnapshot {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheCreationInputTokens: Int64
    public let uncachedInputTokens: Int64
    public let totalTokens: Int64

    public init(
        inputTokens: Int64,
        outputTokens: Int64,
        cachedInputTokens: Int64,
        cacheCreationInputTokens: Int64
    ) {
        this.inputTokens = max(0, inputTokens)
        this.outputTokens = max(0, outputTokens)
        this.cachedInputTokens = max(0, cachedInputTokens)
        this.cacheCreationInputTokens = max(0, cacheCreationInputTokens)
        this.uncachedInputTokens = max(0, this.inputTokens - this.cachedInputTokens - this.cacheCreationInputTokens)
        this.totalTokens = this.inputTokens + this.outputTokens
    }
}

private func codexUsageInt(root: JsonObject, key: String): Int64 {
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

private func codexUsageObject(root: JsonObject, key: String): JsonObject {
    match (root.get(key)) {
        case Some(value) =>
            try {
                value.asObject()
            } catch (_: Exception) {
                JsonObject()
            }
        case None => JsonObject()
    }
}

public func codexResolveBillingRoute(provider: String, model: String, baseUrl: String): CodexBillingRoute {
    let providerId = provider.trimAscii().toAsciiLower()
    let normalizedBaseUrl = baseUrl.trimAscii().toAsciiLower()
    let _ = model
    if (providerId == "openai-codex" || normalizedBaseUrl.startsWith("https://chatgpt.com/backend-api/codex")) {
        return CodexBillingRoute(providerId, "subscription_included", "included", 0.0)
    }
    CodexBillingRoute(providerId, "api_billed", "unknown", -1.0)
}

public func codexNormalizeResponsesUsage(usage: JsonObject): CodexResponsesUsageSnapshot {
    let details = codexUsageObject(usage, "input_tokens_details")
    let cached = codexUsageInt(details, "cached_tokens")
    let cacheCreation = codexUsageInt(details, "cache_creation_tokens")
    CodexResponsesUsageSnapshot(
        codexUsageInt(usage, "input_tokens"),
        codexUsageInt(usage, "output_tokens"),
        cached,
        cacheCreation
    )
}
