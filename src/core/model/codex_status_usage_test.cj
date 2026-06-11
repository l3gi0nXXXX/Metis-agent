package metis.core.model

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonFloat, JsonInt, JsonObject, JsonString}

private func codexStatusUsageStatus(loggedIn: Bool, token!: String = "", error!: String = ""): JsonObject {
    let status = JsonObject()
    status.put("loggedIn", JsonBool(loggedIn))
    status.put("sourceLabel", JsonString("Metis OAuth profile"))
    status.put("lastRefresh", JsonString("2026-06-11T00:00:00Z"))
    if (!token.trimAscii().isEmpty()) {
        status.put("accessToken", JsonString(token))
    }
    if (!error.trimAscii().isEmpty()) {
        status.put("error", JsonString(error))
    }
    status
}

@Test
public class CodexStatusUsageTest {
    @TestCase
    public func statusDashboardDoctorAndBannerStayRedacted(): Unit {
        let loggedIn = codexStatusUsageStatus(true, token: "sk-codex-secret-token-value")
        let loggedOut = codexStatusUsageStatus(false, error: "missing oauth profile")
        let line = renderOpenAICodexStatusLine(loggedIn)
        let dashboard = renderOpenAICodexDashboardStatus(loggedIn)
        let doctorMissingCli = renderOpenAICodexDoctorStatus(loggedOut, false)
        let doctorLoggedInNoCli = renderOpenAICodexDoctorStatus(loggedIn, false)
        let banner = renderCodexRuntimeBanner("codex_app_server")

        @Expect(line.contains("logged in"), true)
        @Expect(line.contains("secret-token-value"), false)
        @Expect(dashboard.toJsonString().contains("sk-codex-secret-token-value"), false)
        @Expect(dashboard.get("tokenPreview").getOrThrow().asString().getValue(), "sk-cod...alue")
        @Expect(doctorMissingCli.contains("optional"), true)
        @Expect(doctorMissingCli.contains("metis models auth openai-codex login"), true)
        @Expect(doctorLoggedInNoCli.contains("optional"), false)
        @Expect(banner.contains("Runtime: codex app-server"), true)
        @Expect(renderCodexRuntimeBanner("auto"), "")
    }

    @TestCase
    public func billingAndResponsesUsageFollowSubscriptionSemantics(): Unit {
        let route = codexResolveBillingRoute("openai-codex", "gpt-5.5", "https://chatgpt.com/backend-api/codex")
        @Expect(route.billingMode, "subscription_included")
        @Expect(route.costStatus, "included")
        @Expect(route.estimatedAmount, 0.0)

        let usage = JsonObject()
        usage.put("input_tokens", JsonInt(1000))
        usage.put("output_tokens", JsonInt(200))
        let details = JsonObject()
        details.put("cached_tokens", JsonInt(300))
        details.put("cache_creation_tokens", JsonInt(100))
        usage.put("input_tokens_details", details)
        let normalized = codexNormalizeResponsesUsage(usage)
        @Expect(normalized.inputTokens, 1000)
        @Expect(normalized.outputTokens, 200)
        @Expect(normalized.cachedInputTokens, 300)
        @Expect(normalized.cacheCreationInputTokens, 100)
        @Expect(normalized.uncachedInputTokens, 600)
        @Expect(normalized.totalTokens, 1200)
    }

    @TestCase
    public func accountUsageUrlParserAndNotApplicableAreDeterministic(): Unit {
        @Expect(resolveOpenAICodexUsageUrl("https://chatgpt.com/backend-api/codex"), "https://chatgpt.com/backend-api/codex/wham/usage")
        @Expect(resolveOpenAICodexUsageUrl("https://chatgpt.com/backend-api"), "https://chatgpt.com/backend-api/codex/wham/usage")
        @Expect(resolveOpenAICodexUsageUrl("https://example.test/base"), "https://example.test/base/api/codex/usage")

        let payload = JsonObject()
        payload.put("plan", JsonString("plus"))
        payload.put("sessionLimit", JsonInt(30))
        payload.put("weeklyLimit", JsonInt(120))
        payload.put("credits", JsonFloat(42.5))
        let snapshot = parseOpenAICodexAccountUsage(payload)
        let rendered = renderOpenAICodexUsage(snapshot)
        @Expect(rendered.contains("plan=plus"), true)
        @Expect(rendered.contains("sessionLimit=30"), true)
        @Expect(rendered.contains("credits=42.5"), true)

        let na = codexAccountUsageNotApplicable()
        @Expect(renderOpenAICodexUsage(na).contains("not applicable"), true)
    }

    @TestCase
    public func auxiliaryRuntimePolicyDoesNotInheritAppServer(): Unit {
        let appServer = codexAuxiliaryRuntimeMode("codex_app_server")
        let responses = codexAuxiliaryRuntimeMode("codex_responses")
        let metis = codexAuxiliaryRuntimeMode("metis_tool_loop")

        @Expect(appServer.applicable, true)
        @Expect(appServer.mode, "codex_responses")
        @Expect(appServer.reason.contains("must not inherit"), true)
        @Expect(responses.mode, "codex_responses")
        @Expect(metis.mode, "metis_tool_loop")
        @Expect(codexAuxiliaryProviderFromBaseUrl("https://chatgpt.com/backend-api/codex"), "codex")
        @Expect(codexAuxiliaryProviderFromBaseUrl("https://api.openai.com/v1"), "")
    }
}
