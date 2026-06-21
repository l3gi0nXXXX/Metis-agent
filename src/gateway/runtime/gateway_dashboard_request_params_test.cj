package metis.gateway.runtime

import metis.gateway.session.GatewayIngressSource

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private func dashboardRequestStringField(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewayDashboardRequestParamsTest {
    @TestCase
    public func normalizeChatSendUsesUnifiedSourceAndFields(): Unit {
        let params = JsonObject()
        params.put("session", JsonString("agent:general:main"))
        params.put("message", JsonString("hello"))
        params.put("deliver", JsonString("true"))
        let request = gatewayDashboardRequestParams("dashboard.chat.send", params, source: GatewayIngressSource.ControlUi)
        @Expect(dashboardRequestStringField(request, "source"), "control-ui")
        @Expect(dashboardRequestStringField(request, "session"), "agent:general:main")
        @Expect(dashboardRequestStringField(request, "text"), "hello")
        @Expect(request.get("deliver").getOrThrow().asBool().getValue(), true)
    }

    @TestCase
    public func normalizeConfigAndChannelsReuseDashboardBuilders(): Unit {
        let channelsParams = JsonObject()
        channelsParams.put("probe", JsonString("true"))
        channelsParams.put("timeoutMs", JsonString("9000"))
        let channels = gatewayDashboardRequestParams("channels.status", channelsParams)
        @Expect(channels.get("probe").getOrThrow().asBool().getValue(), true)
        @Expect(channels.get("timeoutMs").getOrThrow().toJsonString(), "9000")

        let runtimeParams = JsonObject()
        runtimeParams.put("channel", JsonString("telegram"))
        let runtime = gatewayDashboardRequestParams("channels.runtime", runtimeParams)
        @Expect(dashboardRequestStringField(runtime, "channelId"), "telegram")

        let health = gatewayDashboardRequestParams("channels.health", JsonObject())
        @Expect(health.size(), 0)

        let auditParams = JsonObject()
        auditParams.put("id", JsonString("telegram"))
        let audit = gatewayDashboardRequestParams("channels.audit", auditParams)
        @Expect(dashboardRequestStringField(audit, "channelId"), "telegram")

        let configParams = JsonObject()
        let configGet = gatewayDashboardRequestParams("config.get", configParams)
        @Expect(dashboardRequestStringField(configGet, "path"), "gateway")
    }

    @TestCase
    public func normalizeDashboardCronPreservesAdvancedCamelAliases(): Unit {
        let params = JsonObject()
        params.put("action", JsonString("save_job"))
        params.put("id", JsonString("job-1"))
        params.put("session", JsonString("isolated"))
        params.put("message", JsonString("hello cron"))
        params.put("deliveryMode", JsonString("announce"))
        params.put("deliveryAccountId", JsonString("tenant-a"))
        params.put("bestEffortDeliver", JsonString("true"))
        params.put("failureDestMode", JsonString("announce"))
        params.put("failureAccountId", JsonString("bot-a"))
        params.put("failureAlertAfter", JsonString("2"))
        params.put("failureAlertCooldownMs", JsonString("60000"))
        params.put("thinkingLevel", JsonString("high"))
        params.put("lightContext", JsonString("true"))
        params.put("timeoutSeconds", JsonString("15"))
        params.put("maxRetries", JsonString("2"))
        params.put("retryBackoffMs", JsonString("300"))

        let request = gatewayDashboardRequestParams("dashboard.cron", params)

        @Expect(dashboardRequestStringField(request, "action"), "save_job")
        @Expect(dashboardRequestStringField(request, "delivery_mode"), "announce")
        @Expect(dashboardRequestStringField(request, "delivery_account_id"), "tenant-a")
        @Expect(dashboardRequestStringField(request, "best_effort_deliver"), "true")
        @Expect(dashboardRequestStringField(request, "failure_dest_mode"), "announce")
        @Expect(dashboardRequestStringField(request, "failure_account_id"), "bot-a")
        @Expect(dashboardRequestStringField(request, "failure_alert_after"), "2")
        @Expect(dashboardRequestStringField(request, "failure_alert_cooldown_ms"), "60000")
        @Expect(dashboardRequestStringField(request, "thinking_level"), "high")
        @Expect(dashboardRequestStringField(request, "light_context"), "true")
        @Expect(dashboardRequestStringField(request, "timeout_seconds"), "15")
        @Expect(dashboardRequestStringField(request, "max_retries"), "2")
        @Expect(dashboardRequestStringField(request, "retry_backoff_ms"), "300")
    }

    @TestCase
    public func normalizeGatewayHttpChatSendCanReuseSharedBuilder(): Unit {
        let params = JsonObject()
        params.put("session", JsonString("agent:main:main"))
        params.put("text", JsonString("ping"))
        params.put("deliver", JsonString("false"))
        let request = gatewayDashboardRequestParams(
            "dashboard.chat.send",
            params,
            source: GatewayIngressSource.Unknown("gateway-http")
        )
        @Expect(dashboardRequestStringField(request, "source"), "gateway-http")
        @Expect(dashboardRequestStringField(request, "session"), "agent:main:main")
        @Expect(dashboardRequestStringField(request, "text"), "ping")
        @Expect(request.get("deliver").getOrThrow().asBool().getValue(), false)
    }
}
