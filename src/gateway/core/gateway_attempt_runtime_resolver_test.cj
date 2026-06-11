package metis.gateway.core

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private func gatewayAttemptRuntimeTestProviderState(
    providerId: String,
    apiMode: String,
    runtimeMode: String,
    baseUrl: String
): JsonObject {
    let root = JsonObject()
    let providers = JsonArray([])
    let row = JsonObject()
    row.put("provider", JsonString(providerId))
    row.put("runtimeProvider", JsonString(providerId))
    row.put("apiMode", JsonString(apiMode))
    row.put("runtimeMode", JsonString(runtimeMode))
    row.put("baseUrl", JsonString(baseUrl))
    providers.add(row)
    root.put("providers", providers)
    root
}

private func gatewayAttemptRuntimeTestScope(openaiRuntime: String): JsonObject {
    let scope = JsonObject()
    let model = JsonObject()
    let raw = JsonObject()
    raw.put("openaiRuntime", JsonString(openaiRuntime))
    model.put("raw", raw)
    scope.put("model", model)
    scope
}

@Test
public class GatewayAttemptRuntimeResolverTest {
    @TestCase
    public func resolvesCodexResponsesSameAcrossImChannels(): Unit {
        let providerState = gatewayAttemptRuntimeTestProviderState(
            "openai-codex",
            "codex_responses",
            "metis_tool_loop",
            "https://chatgpt.com/backend-api/codex"
        )
        let scope = gatewayAttemptRuntimeTestScope("auto")

        for (_channel in ["telegram", "feishu", "qq"]) {
            let runtime = gatewayResolveAttemptRuntime(
                "openai-codex:gpt-5.5",
                scope,
                providerState: providerState
            )
            @Expect(runtime.providerId, "openai-codex")
            @Expect(runtime.apiMode, "codex_responses")
            @Expect(runtime.runtimeMode, "metis_tool_loop")
            @Expect(runtime.openaiRuntime, "auto")
            @Expect(runtime.baseUrl, "https://chatgpt.com/backend-api/codex")
            @Expect(runtime.providerDetectionMode, "explicit")
        }
    }

    @TestCase
    public func codexAppServerGateOnlyAllowsOpenAiProviders(): Unit {
        let scope = gatewayAttemptRuntimeTestScope("codex_app_server")
        let openai = gatewayResolveAttemptRuntime(
            "openai:gpt-5.4",
            scope,
            providerState: gatewayAttemptRuntimeTestProviderState("openai", "chat_completions", "metis_tool_loop", "https://api.openai.com/v1")
        )
        let codex = gatewayResolveAttemptRuntime(
            "openai-codex:gpt-5.5",
            scope,
            providerState: gatewayAttemptRuntimeTestProviderState("openai-codex", "codex_responses", "metis_tool_loop", "https://chatgpt.com/backend-api/codex")
        )
        let anthropic = gatewayResolveAttemptRuntime(
            "anthropic:claude-sonnet-4-6",
            scope,
            providerState: gatewayAttemptRuntimeTestProviderState("anthropic", "chat_completions", "metis_tool_loop", "https://api.anthropic.com/v1")
        )

        @Expect(gatewayCodexAppServerGate(openai).enabled, true)
        @Expect(gatewayCodexAppServerGate(codex).enabled, true)
        @Expect(gatewayCodexAppServerGate(anthropic).enabled, false)
        @Expect(gatewayCodexAppServerGate(anthropic).reason, "provider-not-openai")
    }

    @TestCase
    public func explicitCodexAuthFailureDoesNotUseAutoFallback(): Unit {
        let explicit = gatewayHandleOpenAICodexAuthResolutionFailure("explicit", ["openrouter"])
        let auto = gatewayHandleOpenAICodexAuthResolutionFailure("auto", ["openrouter"])

        @Expect(explicit.allowFallback, false)
        @Expect(explicit.message.contains("metis models auth openai-codex login"), true)
        @Expect(auto.allowFallback, true)
        @Expect(auto.message.contains("continuing auto provider fallback"), true)
    }

    @TestCase
    public func fallbackRuntimeRecomputesProviderAndClearsMismatchedPool(): Unit {
        let scope = gatewayAttemptRuntimeTestScope("codex_app_server")
        let primary = gatewayResolveAttemptRuntime(
            "openai-codex:gpt-5.5",
            scope,
            providerState: gatewayAttemptRuntimeTestProviderState("openai-codex", "codex_responses", "metis_tool_loop", "https://chatgpt.com/backend-api/codex")
        )
        let fallback = gatewayActivateFallbackRuntime(
            "anthropic:claude-sonnet-4-6",
            primary,
            agentScope: scope,
            providerState: gatewayAttemptRuntimeTestProviderState("anthropic", "chat_completions", "metis_tool_loop", "https://api.anthropic.com/v1")
        )

        @Expect(fallback.providerId, "anthropic")
        @Expect(fallback.apiMode, "chat_completions")
        @Expect(fallback.openaiRuntime, "auto")
        @Expect(gatewayClearMismatchedCredentialPool(primary.providerId, fallback.providerId), true)
    }

    @TestCase
    public func defaultModelForEmptyProviderUsesCatalogFirstEntry(): Unit {
        @Expect(gatewayDefaultModelForEmptyResolvedProvider("openai-codex", "", ["gpt-5.5", "gpt-5.4"]), "gpt-5.5")
        @Expect(gatewayDefaultModelForEmptyResolvedProvider("openai-codex", "gpt-5.4", ["gpt-5.5"]), "gpt-5.4")
        @Expect(gatewayDefaultModelForEmptyResolvedProvider("openai-codex", "", []), "")
    }
}
