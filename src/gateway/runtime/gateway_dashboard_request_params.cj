package metis.gateway.runtime

import metis.gateway.session.{GatewayIngressSource, gatewayBuildChatHistoryRpcParams, gatewayBuildChatSendRpcParams, gatewayBuildSessionsDeleteRpcParams}

import std.convert.Parsable
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}

private func gatewayDashboardParamString(params: JsonObject, key: String): String {
    match (params.get(key)) {
        case Some(v) =>
            try {
                v.asString().getValue().trimAscii()
            } catch (_e: Exception) {
                try { v.toJsonString().trimAscii() } catch (_e2: Exception) { "" }
            }
        case None => ""
    }
}

private func gatewayDashboardParamFirstString(params: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        let value = gatewayDashboardParamString(params, key)
        if (!value.isEmpty()) {
            return value
        }
    }
    ""
}

private func gatewayDashboardParamBool(params: JsonObject, key: String): Bool {
    match (params.get(key)) {
        case Some(v) =>
            try { v.asBool().getValue() } catch (_e: Exception) {
                let raw = try { v.asString().getValue().trimAscii().toAsciiLower() } catch (_inner: Exception) { "" }
                raw == "true" || raw == "1" || raw == "yes" || raw == "on"
            }
        case None => false
    }
}

private func gatewayDashboardParamInt(params: JsonObject, key: String, defaultValue: Int64): Int64 {
    match (params.get(key)) {
        case Some(v) =>
            try {
                Int64.parse(v.toJsonString().trimAscii().replace("\"", ""))
            } catch (_e: Exception) {
                let raw = try { v.asString().getValue().trimAscii() } catch (_inner: Exception) { "" }
                if (raw.isEmpty()) {
                    defaultValue
                } else {
                    try { Int64.parse(raw) } catch (_inner: Exception) { defaultValue }
                }
            }
        case None => defaultValue
    }
}

public func gatewayDashboardRequestParams(
    method: String,
    params: JsonObject,
    source!: GatewayIngressSource = GatewayIngressSource.ControlUi
): JsonObject {
    let normalized = method.trimAscii().toAsciiLower()
    if (normalized == "dashboard.chat.history") {
        let sessionKey = gatewayDashboardParamString(params, "sessionKey")
        let session = if (!sessionKey.isEmpty()) { sessionKey } else { gatewayDashboardParamString(params, "session") }
        return gatewayBuildChatHistoryRpcParams(session: session)
    }
    if (normalized == "dashboard.chat.send") {
        let sessionKey = gatewayDashboardParamString(params, "sessionKey")
        let session = if (!sessionKey.isEmpty()) { sessionKey } else { gatewayDashboardParamString(params, "session") }
        let message = gatewayDashboardParamString(params, "message")
        let text = if (!message.trimAscii().isEmpty()) { message } else { gatewayDashboardParamString(params, "text") }
        return gatewayBuildChatSendRpcParams(
            source,
            session: session,
            text: text,
            deliver: gatewayDashboardParamBool(params, "deliver"),
            thinking: gatewayDashboardParamString(params, "thinking"),
            conversationId: gatewayDashboardParamString(params, "conversationId"),
            threadId: gatewayDashboardParamString(params, "threadId"),
            sourceMessageId: gatewayDashboardParamString(params, "sourceMessageId"),
            replyChannel: gatewayDashboardParamString(params, "replyChannel"),
            replyTo: gatewayDashboardParamString(params, "replyTo"),
            replyAccount: gatewayDashboardParamString(params, "replyAccount"),
            replyToMessageId: gatewayDashboardParamString(params, "replyToMessageId"),
            replyInThread: gatewayDashboardParamBool(params, "replyInThread"),
            idempotencyKey: gatewayDashboardParamString(params, "idempotencyKey")
        )
    }
    if (normalized == "dashboard.skills.set" || normalized == "skills.update") {
        let skillKey = gatewayDashboardParamString(params, "skillKey")
        let name = if (!skillKey.isEmpty()) { skillKey } else { gatewayDashboardParamString(params, "name") }
        let apiKey = gatewayDashboardParamString(params, "apiKey")
        let enabled = gatewayDashboardParamBool(params, "enabled")
        return gatewayDashboardBuildSkillSetRequestParams(name, enabled, apiKey: apiKey)
    }
    if (normalized == "dashboard.model.switch") {
        return gatewayDashboardBuildModelSwitchParams(gatewayDashboardParamString(params, "model"))
    }
    if (normalized == "dashboard.sessions.delete") {
        return gatewayBuildSessionsDeleteRpcParams(keys: gatewayDashboardParamString(params, "keys"))
    }
    if (normalized == "channels.status") {
        return gatewayDashboardBuildChannelsStatusParams(
            gatewayDashboardParamBool(params, "probe"),
            gatewayDashboardParamInt(params, "timeoutMs", 8000)
        )
    }
    if (normalized == "channels.feishu.auth.start") {
        let out = JsonObject()
        let accountId = gatewayDashboardParamString(params, "accountId")
        let account = gatewayDashboardParamString(params, "account")
        if (!accountId.isEmpty()) {
            out.put("accountId", JsonString(accountId))
        } else if (!account.isEmpty()) {
            out.put("accountId", JsonString(account))
        }
        return out
    }
    if (normalized == "channels.runtime") {
        let out = JsonObject()
        let channelId = gatewayDashboardParamString(params, "channelId")
        let id = gatewayDashboardParamString(params, "id")
        let channel = gatewayDashboardParamString(params, "channel")
        if (!channelId.isEmpty()) {
            out.put("channelId", JsonString(channelId))
        } else if (!id.isEmpty()) {
            out.put("channelId", JsonString(id))
        } else if (!channel.isEmpty()) {
            out.put("channelId", JsonString(channel))
        }
        return out
    }
    if (normalized == "channels.health") {
        return JsonObject()
    }
    if (normalized == "channels.audit") {
        let out = JsonObject()
        let channelId = gatewayDashboardParamString(params, "channelId")
        let id = gatewayDashboardParamString(params, "id")
        let channel = gatewayDashboardParamString(params, "channel")
        if (!channelId.isEmpty()) {
            out.put("channelId", JsonString(channelId))
        } else if (!id.isEmpty()) {
            out.put("channelId", JsonString(id))
        } else if (!channel.isEmpty()) {
            out.put("channelId", JsonString(channel))
        }
        return out
    }
    if (normalized == "dashboard.cron") {
        return gatewayDashboardBuildCronPostParams(
            action: gatewayDashboardParamString(params, "action"),
            name: gatewayDashboardParamString(params, "name"),
            every: gatewayDashboardParamString(params, "every"),
            session: gatewayDashboardParamString(params, "session"),
            message: gatewayDashboardParamString(params, "message"),
            deliveryChannel: gatewayDashboardParamString(params, "delivery_channel"),
            deliveryTo: gatewayDashboardParamString(params, "delivery_to"),
            deliveryAnnounce: gatewayDashboardParamString(params, "delivery_announce"),
            systemEvent: gatewayDashboardParamString(params, "system_event"),
            wakeMode: gatewayDashboardParamString(params, "wake_mode"),
            at: gatewayDashboardParamString(params, "at"),
            cronExpr: gatewayDashboardParamString(params, "cron_expr"),
            timeZone: gatewayDashboardParamString(params, "time_zone"),
            id: gatewayDashboardParamString(params, "id"),
            enabled: gatewayDashboardParamString(params, "enabled"),
            scheduleKind: gatewayDashboardParamString(params, "schedule_kind"),
            description: gatewayDashboardParamString(params, "description"),
            deleteAfterRun: gatewayDashboardParamFirstString(params, ["delete_after_run", "deleteAfterRun"]),
            agentId: gatewayDashboardParamFirstString(params, ["agent_id", "agentId"]),
            sessionKey: gatewayDashboardParamFirstString(params, ["session_key", "sessionKey"]),
            model: gatewayDashboardParamString(params, "model"),
            modelOverride: gatewayDashboardParamFirstString(params, ["model_override", "modelOverride"]),
            thinkingLevel: gatewayDashboardParamFirstString(params, ["thinking_level", "thinkingLevel"]),
            lightContext: gatewayDashboardParamFirstString(params, ["light_context", "lightContext"]),
            deliveryMode: gatewayDashboardParamFirstString(params, ["delivery_mode", "deliveryMode"]),
            deliveryAccountId: gatewayDashboardParamFirstString(params, ["delivery_account_id", "deliveryAccountId"]),
            bestEffortDeliver: gatewayDashboardParamFirstString(params, ["best_effort_deliver", "bestEffortDeliver"]),
            payloadKind: gatewayDashboardParamFirstString(params, ["payload_kind", "payloadKind"]),
            timeoutMs: gatewayDashboardParamFirstString(params, ["timeout_ms", "timeoutMs"]),
            timeoutSeconds: gatewayDashboardParamFirstString(params, ["timeout_seconds", "timeoutSeconds"]),
            maxRetries: gatewayDashboardParamFirstString(params, ["max_retries", "maxRetries"]),
            retryBackoffMs: gatewayDashboardParamFirstString(params, ["retry_backoff_ms", "retryBackoffMs"]),
            failureDestMode: gatewayDashboardParamFirstString(params, ["failure_dest_mode", "failureDestMode"]),
            failureChannel: gatewayDashboardParamFirstString(params, ["failure_channel", "failureChannel"]),
            failureTo: gatewayDashboardParamFirstString(params, ["failure_to", "failureTo"]),
            failureAnnounce: gatewayDashboardParamFirstString(params, ["failure_announce", "failureAnnounce"]),
            failureAccountId: gatewayDashboardParamFirstString(params, ["failure_account_id", "failureAccountId"]),
            failureAlertAfter: gatewayDashboardParamFirstString(params, ["failure_alert_after", "failureAlertAfter"]),
            failureAlertCooldownMs: gatewayDashboardParamFirstString(params, ["failure_alert_cooldown_ms", "failureAlertCooldownMs"])
        )
    }
    if (normalized == "config.get") {
        let path = gatewayDashboardParamString(params, "path")
        return gatewayDashboardBuildConfigGetParams(if (path.isEmpty()) { "gateway" } else { path })
    }
    if (normalized == "config.patch" || normalized == "config.apply") {
        return gatewayDashboardBuildConfigPatchParams(
            gatewayDashboardParamString(params, "path"),
            gatewayDashboardParamString(params, "raw")
        )
    }
    if (normalized == "config.schema.lookup") {
        return gatewayDashboardBuildConfigSchemaLookupParams(gatewayDashboardParamString(params, "path"))
    }
    params
}
