package metis.gateway.core

import metis.core.config.{MetisConfigManager, cliProviderApiMode, cliProviderRuntimeMode, cliRuntimeModelProviderId, codexProviderDefaultBaseUrl, resolveProviderApiMode}

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

public class GatewayAttemptRuntime {
    public let modelRef: String
    public let providerId: String
    public let apiMode: String
    public let runtimeMode: String
    public let openaiRuntime: String
    public let baseUrl: String
    public let providerDetectionMode: String

    public init(
        modelRef: String,
        providerId: String,
        apiMode: String,
        runtimeMode: String,
        openaiRuntime: String,
        baseUrl: String,
        providerDetectionMode: String
    ) {
        this.modelRef = modelRef.trimAscii()
        this.providerId = providerId.trimAscii().toAsciiLower()
        this.apiMode = gatewayNormalizeApiMode(apiMode)
        this.runtimeMode = if (runtimeMode.trimAscii().isEmpty()) { "metis_tool_loop" } else { runtimeMode.trimAscii() }
        this.openaiRuntime = gatewayNormalizeOpenAIRuntime(openaiRuntime)
        this.baseUrl = baseUrl.trimAscii()
        this.providerDetectionMode = gatewayNormalizeProviderDetectionMode(providerDetectionMode)
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("modelRef", JsonString(this.modelRef))
        out.put("providerId", JsonString(this.providerId))
        out.put("apiMode", JsonString(this.apiMode))
        out.put("runtimeMode", JsonString(this.runtimeMode))
        out.put("openaiRuntime", JsonString(this.openaiRuntime))
        out.put("baseUrl", JsonString(this.baseUrl))
        out.put("providerDetectionMode", JsonString(this.providerDetectionMode))
        out
    }
}

public class GatewayRuntimeGateDecision {
    public let enabled: Bool
    public let reason: String

    public init(enabled: Bool, reason: String) {
        this.enabled = enabled
        this.reason = reason.trimAscii()
    }
}

public class GatewayOpenAICodexAuthFailureDecision {
    public let allowFallback: Bool
    public let message: String

    public init(allowFallback: Bool, message: String) {
        this.allowFallback = allowFallback
        this.message = message.trimAscii()
    }
}

public class GatewayRuntimeSnapshot {
    public let runtime: GatewayAttemptRuntime
    public let fallbackChain: Array<String>

    public init(runtime: GatewayAttemptRuntime, fallbackChain!: Array<String> = []) {
        this.runtime = runtime
        this.fallbackChain = fallbackChain
    }
}

private func gatewayNormalizeApiMode(raw: String): String {
    let value = raw.trimAscii().toAsciiLower()
    if (value == "codex_responses" || value == "anthropic_messages" || value == "codex_app_server") {
        return value
    }
    "chat_completions"
}

private func gatewayNormalizeOpenAIRuntime(raw: String): String {
    let value = raw.trimAscii().toAsciiLower()
    if (value == "codex_app_server") {
        return value
    }
    "auto"
}

private func gatewayNormalizeProviderDetectionMode(raw: String): String {
    let value = raw.trimAscii().toAsciiLower()
    if (value == "explicit") {
        return "explicit"
    }
    "auto"
}

private func gatewayRuntimeString(root: JsonObject, key: String): String {
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

private func gatewayRuntimeObject(root: JsonObject, key: String): JsonObject {
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

private func gatewayRuntimeArray(root: JsonObject, key: String): JsonArray {
    match (root.get(key)) {
        case Some(value) =>
            try {
                value.asArray()
            } catch (_: Exception) {
                JsonArray([])
            }
        case None => JsonArray([])
    }
}

private func gatewayProviderIdFromModelRef(raw: String): String {
    let canonical = MetisConfigManager.canonicalModelRef(raw).trimAscii()
    if (canonical.isEmpty()) {
        return ""
    }
    var provider = canonical
    if (canonical.contains(":")) {
        let parts = canonical.split(":")
        if (parts.size > 0) {
            provider = parts[0]
        }
    } else if (canonical.contains("/")) {
        let parts = canonical.split("/")
        if (parts.size > 0) {
            provider = parts[0]
        }
    }
    cliRuntimeModelProviderId(provider.trimAscii().toAsciiLower())
}

private func gatewayProviderRow(providerState: JsonObject, providerId: String): JsonObject {
    let wanted = providerId.trimAscii().toAsciiLower()
    for (item in gatewayRuntimeArray(providerState, "providers").getItems()) {
        let row = try { item.asObject() } catch (_: Exception) { JsonObject() }
        let provider = gatewayRuntimeString(row, "provider").toAsciiLower()
        let runtimeProvider = gatewayRuntimeString(row, "runtimeProvider").toAsciiLower()
        if (provider == wanted || runtimeProvider == wanted) {
            return row
        }
    }
    let providersObj = gatewayRuntimeObject(providerState, "providersById")
    match (providersObj.get(wanted)) {
        case Some(value) =>
            try {
                return value.asObject()
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    JsonObject()
}

private func gatewayProviderStateString(providerState: JsonObject, providerId: String, key: String): String {
    let row = gatewayProviderRow(providerState, providerId)
    gatewayRuntimeString(row, key)
}

private func gatewayScopedOpenAIRuntime(agentScope: JsonObject): String {
    let model = gatewayRuntimeObject(agentScope, "model")
    let direct = gatewayRuntimeString(model, "openaiRuntime")
    if (!direct.isEmpty()) {
        return gatewayNormalizeOpenAIRuntime(direct)
    }
    let raw = gatewayRuntimeObject(model, "raw")
    let rawValue = gatewayRuntimeString(raw, "openaiRuntime")
    if (!rawValue.isEmpty()) {
        return gatewayNormalizeOpenAIRuntime(rawValue)
    }
    let runtimeDefaults = gatewayRuntimeObject(agentScope, "runtimeDefaults")
    let defaultValue = gatewayRuntimeString(runtimeDefaults, "openaiRuntime")
    gatewayNormalizeOpenAIRuntime(defaultValue)
}

private func gatewayResolvedProviderBaseUrl(providerId: String, providerState: JsonObject): String {
    let stateBaseUrl = gatewayProviderStateString(providerState, providerId, "baseUrl")
    if (!stateBaseUrl.isEmpty()) {
        return stateBaseUrl
    }
    let configured = MetisConfigManager.readProviderBaseUrl(providerId).trimAscii()
    if (!configured.isEmpty()) {
        return configured
    }
    codexProviderDefaultBaseUrl(providerId)
}

public func gatewayResolveProviderDetectionMode(modelRef: String, config!: JsonObject = JsonObject()): String {
    let trimmed = modelRef.trimAscii()
    if (trimmed.isEmpty()) {
        return "auto"
    }
    let canonical = MetisConfigManager.canonicalModelRef(trimmed).trimAscii()
    if (canonical.isEmpty() || canonical == "auto") {
        return "auto"
    }
    if (canonical.contains(":") || canonical.contains("/")) {
        return "explicit"
    }
    match (config.get("requestedProvider")) {
        case Some(value) =>
            try {
                let requested = value.asString().getValue().trimAscii().toAsciiLower()
                if (requested == "auto" || requested.isEmpty()) {
                    return "auto"
                }
                return "explicit"
            } catch (_: Exception) {
                ()
            }
        case None => ()
    }
    "auto"
}

public func gatewayResolveAttemptRuntime(
    modelRef: String,
    agentScope: JsonObject,
    providerState!: JsonObject = JsonObject()
): GatewayAttemptRuntime {
    let normalizedModelRef = MetisConfigManager.normalizeModelRef(modelRef).trimAscii()
    let providerId = gatewayProviderIdFromModelRef(if (normalizedModelRef.isEmpty()) { modelRef } else { normalizedModelRef })
    let runtimeProvider = if (providerId.isEmpty()) { "" } else { providerId }
    let explicitApiMode = gatewayProviderStateString(providerState, runtimeProvider, "apiMode")
    let apiMode = if (runtimeProvider.isEmpty()) {
        "chat_completions"
    } else if (!explicitApiMode.isEmpty()) {
        resolveProviderApiMode(runtimeProvider, runtimeProvider, explicitApiMode)
    } else {
        cliProviderApiMode(runtimeProvider)
    }
    let runtimeModeFromState = gatewayProviderStateString(providerState, runtimeProvider, "runtimeMode")
    let runtimeMode = if (!runtimeModeFromState.isEmpty()) {
        runtimeModeFromState
    } else if (runtimeProvider.isEmpty()) {
        "metis_tool_loop"
    } else {
        cliProviderRuntimeMode(runtimeProvider)
    }
    GatewayAttemptRuntime(
        if (normalizedModelRef.isEmpty()) { modelRef.trimAscii() } else { normalizedModelRef },
        runtimeProvider,
        apiMode,
        runtimeMode,
        gatewayScopedOpenAIRuntime(agentScope),
        if (runtimeProvider.isEmpty()) { "" } else { gatewayResolvedProviderBaseUrl(runtimeProvider, providerState) },
        gatewayResolveProviderDetectionMode(modelRef)
    )
}

public func gatewayShouldUseCodexAppServer(runtime: GatewayAttemptRuntime): Bool {
    gatewayCodexAppServerGate(runtime).enabled
}

public func gatewayCodexAppServerGate(runtime: GatewayAttemptRuntime): GatewayRuntimeGateDecision {
    if (runtime.openaiRuntime != "codex_app_server") {
        return GatewayRuntimeGateDecision(false, "openai-runtime-auto")
    }
    if (runtime.providerId == "openai" || runtime.providerId == "openai-codex") {
        return GatewayRuntimeGateDecision(true, "enabled")
    }
    GatewayRuntimeGateDecision(false, "provider-not-openai")
}

public func gatewayHandleOpenAICodexAuthResolutionFailure(
    mode: String,
    fallbackProviders: Array<String>
): GatewayOpenAICodexAuthFailureDecision {
    if (gatewayNormalizeProviderDetectionMode(mode) == "explicit") {
        return GatewayOpenAICodexAuthFailureDecision(
            false,
            "OpenAI Codex OAuth is not configured. Run `metis models auth openai-codex login`."
        )
    }
    let available = ArrayList<String>()
    for (provider in fallbackProviders) {
        let trimmed = provider.trimAscii()
        if (!trimmed.isEmpty()) {
            available.add(trimmed)
        }
    }
    if (available.isEmpty()) {
        return GatewayOpenAICodexAuthFailureDecision(
            false,
            "OpenAI Codex OAuth is not configured and no auto provider fallback is available."
        )
    }
    GatewayOpenAICodexAuthFailureDecision(
        true,
        "OpenAI Codex OAuth is not configured; continuing auto provider fallback."
    )
}

public func gatewayDefaultModelForEmptyResolvedProvider(
    providerId: String,
    currentModel: String,
    catalog: Array<String>
): String {
    if (!currentModel.trimAscii().isEmpty()) {
        return currentModel.trimAscii()
    }
    for (candidate in catalog) {
        let trimmed = candidate.trimAscii()
        if (!trimmed.isEmpty()) {
            return trimmed
        }
    }
    let _ = providerId
    ""
}

public func gatewaySnapshotPrimaryRuntime(runtime: GatewayAttemptRuntime, fallbackChain!: Array<String> = []): GatewayRuntimeSnapshot {
    GatewayRuntimeSnapshot(runtime, fallbackChain: fallbackChain)
}

public func gatewayClearMismatchedCredentialPool(previousProvider: String, nextProvider: String): Bool {
    let previous = previousProvider.trimAscii().toAsciiLower()
    let next = nextProvider.trimAscii().toAsciiLower()
    !previous.isEmpty() && !next.isEmpty() && previous != next
}

public func gatewayActivateFallbackRuntime(
    fallbackModel: String,
    previousRuntime: GatewayAttemptRuntime,
    agentScope!: JsonObject = JsonObject(),
    providerState!: JsonObject = JsonObject()
): GatewayAttemptRuntime {
    let resolved = gatewayResolveAttemptRuntime(fallbackModel, agentScope, providerState: providerState)
    GatewayAttemptRuntime(
        resolved.modelRef,
        resolved.providerId,
        resolved.apiMode,
        resolved.runtimeMode,
        if (resolved.providerId == "openai" || resolved.providerId == "openai-codex") { previousRuntime.openaiRuntime } else { "auto" },
        resolved.baseUrl,
        resolved.providerDetectionMode
    )
}
