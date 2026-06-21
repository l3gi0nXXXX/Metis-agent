package metis.gateway.runtime

import metis.cron.{CronJob, CronSchedule}
import metis.gateway.session.GatewayIngressSource

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private func dashboardApiStringField(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewayDashboardApiTest {
    @TestCase
    public func statusAndChannelsParamsReuseSmallBuilders(): Unit {
        let status = gatewayDashboardBuildStatusParams(limit: 120)
        @Expect(dashboardApiStringField(status, "limit"), "120")

        let channels = gatewayDashboardBuildChannelsStatusParams(true, 8000)
        @Expect(channels.get("probe").getOrThrow().asBool().getValue(), true)
        @Expect(channels.get("timeoutMs").getOrThrow().toJsonString(), "8000")
    }

    @TestCase
    public func configAndSkillParamsNormalizeDashboardInputs(): Unit {
        let skill = gatewayDashboardBuildSkillSetParams(" review ", true)
        @Expect(dashboardApiStringField(skill, "skillKey"), "review")
        @Expect(skill.get("enabled").getOrThrow().asBool().getValue(), true)

        let skillRequest = gatewayDashboardBuildSkillSetRequestParams(" review ", true, apiKey: " sk-123 ")
        @Expect(dashboardApiStringField(skillRequest, "skillKey"), "review")
        @Expect(skillRequest.get("enabled").getOrThrow().asBool().getValue(), true)
        @Expect(dashboardApiStringField(skillRequest, "apiKey"), "sk-123")

        let getParams = gatewayDashboardBuildConfigGetParams(" gateway.http ")
        @Expect(dashboardApiStringField(getParams, "path"), "gateway.http")

        let schemaLookup = gatewayDashboardBuildConfigSchemaLookupParams(" ")
        @Expect(dashboardApiStringField(schemaLookup, "path"), "gateway")

        let patch = gatewayDashboardBuildConfigPatchParams(" gateway.http ", "{\"enabled\":true}")
        @Expect(dashboardApiStringField(patch, "path"), "gateway.http")
        @Expect(dashboardApiStringField(patch, "raw"), "{\"enabled\":true}")
    }

    @TestCase
    public func memoryStatusParamsNormalizeAgentAndBackend(): Unit {
        let params = gatewayDashboardBuildMemoryStatusParams(" general ", " sqlite-fts+local-file ")
        @Expect(dashboardApiStringField(params, "agentId"), "general")
        @Expect(dashboardApiStringField(params, "backend"), "sqlite-fts+local-file")

        let empty = gatewayDashboardBuildMemoryStatusParams(" ", " ")
        @Expect(empty.get("agentId").isSome(), false)
        @Expect(empty.get("backend").isSome(), false)
    }

    @TestCase
    public func cronPostParamsSkipEmptyFieldsAndPreserveMappedKeys(): Unit {
        let params = gatewayDashboardBuildCronPostParams(
            action: "save",
            name: "daily report",
            session: "agent:general:main",
            message: "hello",
            deliveryChannel: "feishu",
            deliveryTo: "chat-1",
            deliveryAnnounce: "true",
            systemEvent: "",
            wakeMode: "",
            scheduleKind: "every",
            model: "openai:gpt-test",
            thinkingLevel: "high",
            lightContext: "true",
            deliveryMode: "announce",
            deliveryAccountId: "tenant-a",
            bestEffortDeliver: "true",
            timeoutMs: "1500",
            maxRetries: "2",
            retryBackoffMs: "300",
            failureDestMode: "announce",
            failureAccountId: "bot-a",
            failureAlertAfter: "2",
            failureAlertCooldownMs: "60000"
        )
        @Expect(dashboardApiStringField(params, "action"), "save")
        @Expect(dashboardApiStringField(params, "delivery_channel"), "feishu")
        @Expect(dashboardApiStringField(params, "delivery_to"), "chat-1")
        @Expect(dashboardApiStringField(params, "schedule_kind"), "every")
        @Expect(dashboardApiStringField(params, "model"), "openai:gpt-test")
        @Expect(dashboardApiStringField(params, "thinking_level"), "high")
        @Expect(dashboardApiStringField(params, "light_context"), "true")
        @Expect(dashboardApiStringField(params, "delivery_mode"), "announce")
        @Expect(dashboardApiStringField(params, "delivery_account_id"), "tenant-a")
        @Expect(dashboardApiStringField(params, "best_effort_deliver"), "true")
        @Expect(dashboardApiStringField(params, "timeout_ms"), "1500")
        @Expect(dashboardApiStringField(params, "max_retries"), "2")
        @Expect(dashboardApiStringField(params, "retry_backoff_ms"), "300")
        @Expect(dashboardApiStringField(params, "failure_dest_mode"), "announce")
        @Expect(dashboardApiStringField(params, "failure_account_id"), "bot-a")
        @Expect(dashboardApiStringField(params, "failure_alert_after"), "2")
        @Expect(dashboardApiStringField(params, "failure_alert_cooldown_ms"), "60000")
        @Expect(params.get("system_event").isSome(), false)
        @Expect(params.get("wake_mode").isSome(), false)
    }

    @TestCase
    public func cronRunNowParamsUseUnifiedIngressShape(): Unit {
        let job = CronJob(
            "job-1",
            "hello cron",
            CronSchedule.every(60000),
            sessionTarget: "main",
            agentId: "general",
            deliveryChannel: "feishu",
            deliveryTo: "chat-id",
            deliveryAccountId: "app-1",
            bestEffortDeliver: true,
            thinkingLevel: "high",
            timeoutMs: 5000
        )
        let params = gatewayDashboardBuildCronRunNowParams(job)
        @Expect(dashboardApiStringField(params, "source"), "cron")
        @Expect(dashboardApiStringField(params, "channel"), "cron")
        @Expect(dashboardApiStringField(params, "agentId"), "general")
        @Expect(dashboardApiStringField(params, "text"), "hello cron")
        @Expect(dashboardApiStringField(params, "replyChannel"), "feishu")
        @Expect(dashboardApiStringField(params, "replyTo"), "chat-id")
        @Expect(dashboardApiStringField(params, "replyAccount"), "app-1")
        @Expect(params.get("deliver").getOrThrow().asBool().getValue(), true)
        @Expect(params.get("bestEffortDeliver").getOrThrow().asBool().getValue(), true)
    }

    @TestCase
    public func requestParamsFromFormReusesSharedRequestNormalization(): Unit {
        let raw = JsonObject()
        raw.put("session", JsonString("agent:general:main"))
        raw.put("text", JsonString("hello"))
        raw.put("deliver", JsonString("true"))
        raw.put("replyToMessageId", JsonString("msg-11"))
        raw.put("replyInThread", JsonString("true"))
        let params = gatewayDashboardRequestParams(
            "dashboard.chat.send",
            raw,
            source: GatewayIngressSource.ControlUi
        )
        @Expect(dashboardApiStringField(params, "source"), "control-ui")
        @Expect(dashboardApiStringField(params, "session"), "agent:general:main")
        @Expect(dashboardApiStringField(params, "text"), "hello")
        @Expect(dashboardApiStringField(params, "replyToMessageId"), "msg-11")
        @Expect(params.get("replyInThread").getOrThrow().asBool().getValue(), true)
        @Expect(params.get("deliver").getOrThrow().asBool().getValue(), true)
    }

    @TestCase
    public func dashboardChatSendPropagatesChatTurnErrorAsRpcFailure(): Unit {
        let params = JsonObject()
        params.put("session", JsonString("agent:general:main"))
        params.put("text", JsonString("   "))
        let response = handleGatewayDashboardFamily(
            "dashboard.chat.send",
            GatewayRpcRequest("dashboard.chat.send", params: params)
        ).getOrThrow()
        @Expect(response.ok, false)
        @Expect(response.error.contains("text must be non-empty"), true)
    }
}
