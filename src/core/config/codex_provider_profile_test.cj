package metis.core.config

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private func codexProfileTestObject(root: JsonObject, key: String): JsonObject {
    match (root.get(key)) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func codexProfileTestString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(value) =>
            try { value.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class CodexProviderProfileTest {
    @TestCase
    public func openAICodexDescriptorSeparatesOAuthBackendFromOpenAIApiKeyProvider(): Unit {
        match (cliFindModelProviderDescriptor("openai")) {
            case Some(openai) =>
                @Expect(openai.runtimeProviderId, "openai")
                @Expect(openai.apiKeyEnv, "OPENAI_API_KEY")
                @Expect(openai.baseUrlEnv, "OPENAI_BASE_URL")
                @Expect(cliProviderApiMode("openai"), "chat_completions")
                @Expect(cliProviderAuthKind("openai"), "api_key")
                @Expect(cliProviderRequiresApiKey("openai"), true)
            case None => @Expect("missing-openai", "present")
        }

        match (cliFindModelProviderDescriptor("openai-codex")) {
            case Some(codex) =>
                @Expect(codex.runtimeProviderId, "openai-codex")
                @Expect(codex.apiKeyEnv, "")
                @Expect(codex.baseUrlEnv, "")
                @Expect(codex.defaultModelRef, "openai-codex:gpt-5.5")
                @Expect(codex.defaultBaseUrl, "https://chatgpt.com/backend-api/codex")
                @Expect(cliProviderApiMode("codex"), "codex_responses")
                @Expect(cliProviderAuthKind("openai-codex"), "oauth_external")
                @Expect(cliProviderRequiresApiKey("openai-codex"), false)
            case None => @Expect("missing-openai-codex", "present")
        }
    }

    @TestCase
    public func detectApiModeForBaseUrlUsesExactHostsAndKnownAnthropicPaths(): Unit {
        @Expect(detectApiModeForBaseUrl("https://api.openai.com/v1").getOrDefault { "" }, "codex_responses")
        @Expect(detectApiModeForBaseUrl("https://api.x.ai/v1").getOrDefault { "" }, "codex_responses")
        @Expect(detectApiModeForBaseUrl("https://openrouter.ai/api/v1").isNone(), true)
        @Expect(detectApiModeForBaseUrl("https://api.openai.com.example/v1").isNone(), true)
        @Expect(detectApiModeForBaseUrl("https://proxy.example/api.openai.com/v1").isNone(), true)
        @Expect(detectApiModeForBaseUrl("https://api.minimax.io/anthropic/").getOrDefault { "" }, "anthropic_messages")
        @Expect(detectApiModeForBaseUrl("https://api.kimi.com/coding/v1").getOrDefault { "" }, "anthropic_messages")
        @Expect(detectApiModeForBaseUrl("").isNone(), true)
    }

    @TestCase
    public func providerApiModeResolverAndSwitchCleanupRespectProviderBoundary(): Unit {
        @Expect(resolveProviderApiMode("openai-codex", "openai-codex", "codex_responses"), "codex_responses")
        @Expect(resolveProviderApiMode("openai", "openai-codex", "codex_responses"), "codex_responses")
        @Expect(resolveProviderApiMode("openai-codex", "openai-codex", "bad-mode"), "codex_responses")
        @Expect(resolveProviderApiMode("custom", "custom", "codex_responses"), "codex_responses")

        let root = JsonObject()
        let models = JsonObject()
        let providers = JsonObject()
        let openai = JsonObject()
        openai.put("apiKey", JsonString("stale-key"))
        openai.put("apiMode", JsonString("codex_responses"))
        openai.put("baseUrl", JsonString("https://api.openai.com/v1"))
        providers.put("openai", openai)
        let custom = JsonObject()
        custom.put("apiKey", JsonString("custom-key"))
        custom.put("apiMode", JsonString("codex_responses"))
        providers.put("custom", custom)
        models.put("providers", providers)
        root.put("models", models)

        clearStaleProviderAuthFieldsOnSwitch(root, "openai")
        let openaiAfter = codexProfileTestObject(codexProfileTestObject(codexProfileTestObject(root, "models"), "providers"), "openai")
        @Expect(openaiAfter.get("apiKey").isNone(), true)
        @Expect(openaiAfter.get("apiMode").isNone(), true)
        @Expect(codexProfileTestString(openaiAfter, "baseUrl"), "https://api.openai.com/v1")

        clearStaleProviderAuthFieldsOnSwitch(root, "custom")
        let customAfter = codexProfileTestObject(codexProfileTestObject(codexProfileTestObject(root, "models"), "providers"), "custom")
        @Expect(codexProfileTestString(customAfter, "apiKey"), "custom-key")
        @Expect(codexProfileTestString(customAfter, "apiMode"), "codex_responses")
    }

    @TestCase
    public func openAICodexSetupModelChoiceEncodesLoginCatalogValidatePersistOrder(): Unit {
        let catalog = ["gpt-5.5", "gpt-5.4"]
        let existing = openAICodexSetupModelChoice("logged_in", "use_existing", "openai/gpt-5.4", catalog)
        @Expect(existing.status, "persisted")
        @Expect(existing.shouldLogin, false)
        @Expect(existing.forceNewLogin, false)
        @Expect(existing.providerId, "openai-codex")
        @Expect(existing.baseUrl, "https://chatgpt.com/backend-api/codex")
        @Expect(existing.modelId, "gpt-5.4")
        @Expect(existing.transcript[1], "use_existing")

        let reauth = openAICodexSetupModelChoice("logged_in", "reauth", "", catalog)
        @Expect(reauth.shouldLogin, true)
        @Expect(reauth.forceNewLogin, true)
        @Expect(reauth.modelId, "gpt-5.5")

        let cancel = openAICodexSetupModelChoice("logged_in", "cancel", "gpt-5.5", catalog)
        @Expect(cancel.status, "canceled")
        @Expect(cancel.providerId, "")

        let loggedOut = openAICodexSetupModelChoice("logged_out", "", "gpt_5.4", catalog)
        @Expect(loggedOut.shouldLogin, true)
        @Expect(loggedOut.forceNewLogin, false)
        @Expect(loggedOut.modelId, "gpt-5.4")
        @Expect(loggedOut.transcript[1], "login")
    }
}
