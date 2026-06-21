package metis.gateway.runtime

import std.collection.ArrayList
import stdx.encoding.json.JsonObject

/** 从 RPC / Dashboard 的 `params` 取字符串字段（与 `dashboard` 的 `rpcString` 行为一致）。 */
public func gatewayCronRpcString(params: JsonObject, key: String): String {
    match (params.get(key)) {
        case Some(v) =>
            try {
                v.asString().getValue()
            } catch (_e: Exception) {
                try { v.toJsonString() } catch (_e2: Exception) { "" }
            }
        case None => ""
    }
}

private func gatewayCronRpcStringForKeys(params: JsonObject, keys: Array<String>): Option<String> {
    for (key in keys) {
        match (params.get(key)) {
            case Some(_) => return Some(gatewayCronRpcString(params, key).trimAscii())
            case None => ()
        }
    }
    None<String>
}

private func gatewayCronRpcStringForKeysOrEmpty(params: JsonObject, keys: Array<String>): String {
    match (gatewayCronRpcStringForKeys(params, keys)) {
        case Some(v) => v
        case None => ""
    }
}

private func gatewayCronAppendStringFlagFromKeys(
    parts: ArrayList<String>,
    params: JsonObject,
    flag: String,
    keys: Array<String>,
    allowEmpty!: Bool = false
): Unit {
    match (gatewayCronRpcStringForKeys(params, keys)) {
        case Some(v) =>
            if (allowEmpty || !v.isEmpty()) {
                parts.add(flag)
                parts.add(v)
            }
        case None => ()
    }
}

private func gatewayCronAppendBoolFlagFromKeys(
    parts: ArrayList<String>,
    params: JsonObject,
    trueFlag: String,
    falseFlag: String,
    keys: Array<String>
): Unit {
    match (gatewayCronRpcStringForKeys(params, keys)) {
        case Some(raw) =>
            let v = raw.trimAscii().toAsciiLower()
            if (v == "true" || v == "1" || v == "yes" || v == "on") {
                parts.add(trueFlag)
            } else if (v == "false" || v == "0" || v == "no" || v == "off") {
                if (!falseFlag.isEmpty()) {
                    parts.add(falseFlag)
                }
            }
        case None => ()
    }
}

/**
 * 追加投递、重试、失败告警等 CLI flags（与 `dashboard.cron` 一致）。
 */
/** 与 `cron.add` 扩展字段一致，供 Dashboard / `cron.add` RPC 写入 CLI argv。 */
public func gatewayCronAppendOptionalJobFieldsFromParams(parts: ArrayList<String>, params: JsonObject): Unit {
    gatewayCronAppendStringFlagFromKeys(parts, params, "--description", ["description"], allowEmpty: true)
    gatewayCronAppendBoolFlagFromKeys(parts, params, "--delete-after-run", "--no-delete-after-run", ["delete_after_run", "deleteAfterRun"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--agent-id", ["agent_id", "agentId"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--session-key", ["session_key", "sessionKey"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--model", ["model", "model_override", "modelOverride"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--thinking-level", ["thinking_level", "thinkingLevel"], allowEmpty: true)
    gatewayCronAppendBoolFlagFromKeys(parts, params, "--light-context", "--no-light-context", ["light_context", "lightContext"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--delivery-account-id", ["delivery_account_id", "deliveryAccountId"], allowEmpty: true)
    gatewayCronAppendBoolFlagFromKeys(parts, params, "--best-effort-deliver", "--no-best-effort-deliver", ["best_effort_deliver", "bestEffortDeliver"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--payload-kind", ["payload_kind", "payloadKind"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--failure-account-id", ["failure_account_id", "failureAccountId"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--failure-alert-after", ["failure_alert_after", "failureAlertAfter"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--failure-alert-cooldown-ms", ["failure_alert_cooldown_ms", "failureAlertCooldownMs"])
}

public func gatewayCronAppendDeliveryArgs(parts: ArrayList<String>, params: JsonObject): Unit {
    gatewayCronAppendStringFlagFromKeys(parts, params, "--system-event", ["system_event", "systemEvent"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--wake-mode", ["wake_mode", "wakeMode"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--delivery-mode", ["delivery_mode", "deliveryMode"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--channel", ["delivery_channel", "deliveryChannel"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--to", ["delivery_to", "deliveryTo"], allowEmpty: true)
    gatewayCronAppendBoolFlagFromKeys(parts, params, "--announce", "--no-announce", ["delivery_announce", "deliveryAnnounce"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--timeout-ms", ["timeout_ms", "timeoutMs"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--timeout-seconds", ["timeout_seconds", "timeoutSeconds"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--max-retries", ["max_retries", "maxRetries"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--retry-backoff-ms", ["retry_backoff_ms", "retryBackoffMs"])
    gatewayCronAppendStringFlagFromKeys(parts, params, "--failure-dest-mode", ["failure_dest_mode", "failureDestMode"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--failure-channel", ["failure_channel", "failureChannel"], allowEmpty: true)
    gatewayCronAppendStringFlagFromKeys(parts, params, "--failure-to", ["failure_to", "failureTo"], allowEmpty: true)
    gatewayCronAppendBoolFlagFromKeys(parts, params, "--failure-announce", "--no-failure-announce", ["failure_announce", "failureAnnounce"])
}

private func gatewayCronAppendOptionalSchedulePatch(
    parts: ArrayList<String>,
    params: JsonObject,
    requireSchedule!: Bool = false
): Option<String> {
    let sk = gatewayCronRpcStringForKeysOrEmpty(params, ["schedule_kind", "scheduleKind"]).trimAscii().toAsciiLower()
    let every = gatewayCronRpcStringForKeysOrEmpty(params, ["every"]).trimAscii()
    let atRaw = gatewayCronRpcStringForKeysOrEmpty(params, ["at"]).trimAscii()
    let cronExpr = gatewayCronRpcStringForKeysOrEmpty(params, ["cron_expr", "cronExpr"]).trimAscii()
    let wantsEvery = sk == "every" || (sk.isEmpty() && !every.isEmpty())
    let wantsAt = sk == "at" || (sk.isEmpty() && !atRaw.isEmpty())
    let wantsCron = sk == "cron" || (sk.isEmpty() && !cronExpr.isEmpty())
    if (wantsEvery) {
        if (every.isEmpty()) {
            return Some("every required")
        }
        parts.add("--every")
        parts.add(every)
        return None
    }
    if (wantsAt) {
        if (atRaw.isEmpty()) {
            return Some("at required")
        }
        parts.add("--at")
        parts.add(atRaw)
        return None
    }
    if (wantsCron) {
        if (cronExpr.isEmpty()) {
            return Some("cron_expr required")
        }
        parts.add("--cron")
        parts.add(cronExpr)
        let tz = if (gatewayCronRpcStringForKeysOrEmpty(params, ["time_zone", "timeZone"]).trimAscii().isEmpty()) {
            "UTC"
        } else {
            gatewayCronRpcStringForKeysOrEmpty(params, ["time_zone", "timeZone"]).trimAscii()
        }
        parts.add("--tz")
        parts.add(tz)
        return None
    }
    if (requireSchedule) {
        return Some("schedule required")
    }
    None
}

/**
 * `parts` 首元素须已为 `cron`。按 dashboard 的 `action` 名追加子命令与参数。
 * 成功返回 `None`；校验失败返回 `Some(错误说明)`。
 */
public func gatewayCronFillArgvForDashboardAction(
    parts: ArrayList<String>,
    action: String,
    params: JsonObject
): Option<String> {
    let act = action.trimAscii().toAsciiLower()
    if (act == "add_every") {
        let name = gatewayCronRpcString(params, "name").trimAscii()
        let every = gatewayCronRpcString(params, "every").trimAscii()
        let session = if (gatewayCronRpcString(params, "session").trimAscii().isEmpty()) {
            "main"
        } else {
            gatewayCronRpcString(params, "session").trimAscii()
        }
        let message = gatewayCronRpcString(params, "message")
        if (name.isEmpty() || every.isEmpty() || message.trimAscii().isEmpty()) {
            return Some("name, every, message required")
        }
        parts.add("add")
        parts.add("--name")
        parts.add(name)
        parts.add("--every")
        parts.add(every)
        parts.add("--session")
        parts.add(session)
        gatewayCronAppendDeliveryArgs(parts, params)
        gatewayCronAppendOptionalJobFieldsFromParams(parts, params)
        parts.add("--message")
        parts.add(message)
        return None
    }
    if (act == "add_at") {
        let name = gatewayCronRpcString(params, "name").trimAscii()
        let atRaw = gatewayCronRpcString(params, "at").trimAscii()
        let session = if (gatewayCronRpcString(params, "session").trimAscii().isEmpty()) {
            "main"
        } else {
            gatewayCronRpcString(params, "session").trimAscii()
        }
        let message = gatewayCronRpcString(params, "message")
        if (name.isEmpty() || atRaw.isEmpty() || message.trimAscii().isEmpty()) {
            return Some("name, at, message required")
        }
        parts.add("add")
        parts.add("--name")
        parts.add(name)
        parts.add("--at")
        parts.add(atRaw)
        parts.add("--session")
        parts.add(session)
        gatewayCronAppendDeliveryArgs(parts, params)
        gatewayCronAppendOptionalJobFieldsFromParams(parts, params)
        parts.add("--message")
        parts.add(message)
        return None
    }
    if (act == "add_cron") {
        let name = gatewayCronRpcString(params, "name").trimAscii()
        let cronExpr = gatewayCronRpcStringForKeysOrEmpty(params, ["cron_expr", "cronExpr"]).trimAscii()
        let tzRaw = gatewayCronRpcStringForKeysOrEmpty(params, ["time_zone", "timeZone"]).trimAscii()
        let tz = if (tzRaw.isEmpty()) {
            "UTC"
        } else {
            tzRaw
        }
        let session = if (gatewayCronRpcString(params, "session").trimAscii().isEmpty()) {
            "main"
        } else {
            gatewayCronRpcString(params, "session").trimAscii()
        }
        let message = gatewayCronRpcString(params, "message")
        if (name.isEmpty() || cronExpr.isEmpty() || message.trimAscii().isEmpty()) {
            return Some("name, cron_expr, message required")
        }
        parts.add("add")
        parts.add("--name")
        parts.add(name)
        parts.add("--cron")
        parts.add(cronExpr)
        parts.add("--tz")
        parts.add(tz)
        parts.add("--session")
        parts.add(session)
        gatewayCronAppendDeliveryArgs(parts, params)
        gatewayCronAppendOptionalJobFieldsFromParams(parts, params)
        parts.add("--message")
        parts.add(message)
        return None
    }
    if (act == "remove" || act == "enable" || act == "disable") {
        let id = gatewayCronRpcString(params, "id").trimAscii()
        if (id.isEmpty()) {
            return Some("id is empty")
        }
        parts.add(act)
        parts.add(id)
        return None
    }
    if (act == "status" || act == "path" || act == "help" || act == "list") {
        parts.add(act)
        return None
    }
    if (act == "update" || act == "save_job") {
        let targetId = if (gatewayCronRpcString(params, "jobId").trimAscii().isEmpty()) {
            gatewayCronRpcString(params, "id").trimAscii()
        } else {
            gatewayCronRpcString(params, "jobId").trimAscii()
        }
        if (targetId.isEmpty()) {
            return Some("jobId is empty")
        }
        parts.add("update")
        parts.add("--job-id")
        parts.add(targetId)
        let en = gatewayCronRpcString(params, "enabled").trimAscii().toAsciiLower()
        let msg = gatewayCronRpcString(params, "message")
        let session = gatewayCronRpcString(params, "session").trimAscii()
        if (!en.isEmpty()) {
            parts.add("--enabled")
            parts.add(en)
        }
        if (!session.isEmpty()) {
            parts.add("--session")
            parts.add(session)
        }
        match (gatewayCronAppendOptionalSchedulePatch(parts, params, requireSchedule: act == "save_job")) {
            case Some(err) => return Some(err)
            case None => ()
        }
        gatewayCronAppendDeliveryArgs(parts, params)
        gatewayCronAppendOptionalJobFieldsFromParams(parts, params)
        if (act == "save_job" && msg.trimAscii().isEmpty()) {
            return Some("id or message empty")
        }
        if (!msg.trimAscii().isEmpty()) {
            parts.add("--message")
            parts.add(msg)
        }
        return None
    }
    if (act == "run") {
        let targetId = if (gatewayCronRpcString(params, "jobId").trimAscii().isEmpty()) {
            gatewayCronRpcString(params, "id").trimAscii()
        } else {
            gatewayCronRpcString(params, "jobId").trimAscii()
        }
        if (targetId.isEmpty()) {
            return Some("jobId is empty")
        }
        parts.add("run")
        parts.add("--job-id")
        parts.add(targetId)
        let dueStr = gatewayCronRpcString(params, "due_only").trimAscii().toAsciiLower()
        if (dueStr == "true" || dueStr == "1" || dueStr == "yes") {
            parts.add("--due")
        }
        return None
    }
    if (act == "runs") {
        parts.add("runs")
        let targetId = if (gatewayCronRpcString(params, "jobId").trimAscii().isEmpty()) {
            gatewayCronRpcString(params, "id").trimAscii()
        } else {
            gatewayCronRpcString(params, "jobId").trimAscii()
        }
        if (!targetId.isEmpty()) {
            parts.add("--job-id")
            parts.add(targetId)
        }
        return None
    }
    if (act == "wake") {
        parts.add("wake")
        let targetId = if (gatewayCronRpcString(params, "jobId").trimAscii().isEmpty()) {
            gatewayCronRpcString(params, "id").trimAscii()
        } else {
            gatewayCronRpcString(params, "jobId").trimAscii()
        }
        if (!targetId.isEmpty()) {
            parts.add("--job-id")
            parts.add(targetId)
        }
        let wakeMode = gatewayCronRpcString(params, "mode").trimAscii()
        if (!wakeMode.isEmpty()) {
            parts.add("--mode")
            parts.add(wakeMode)
        }
        let wakeText = gatewayCronRpcString(params, "text").trimAscii()
        if (!wakeText.isEmpty()) {
            parts.add("--text")
            parts.add(wakeText)
        }
        return None
    }
    if (act == "edit_message") {
        let id = gatewayCronRpcString(params, "id").trimAscii()
        let message = gatewayCronRpcString(params, "message")
        if (id.isEmpty() || message.trimAscii().isEmpty()) {
            return Some("id or message empty")
        }
        parts.add("edit")
        parts.add(id)
        parts.add("--message")
        parts.add(message)
        return None
    }
    if (act == "edit_enabled") {
        let id = gatewayCronRpcString(params, "id").trimAscii()
        let enabled = gatewayCronRpcString(params, "enabled").trimAscii().toAsciiLower()
        if (id.isEmpty() || (enabled != "true" && enabled != "false")) {
            return Some("id or enabled invalid")
        }
        parts.add("edit")
        parts.add(id)
        parts.add("--enabled")
        parts.add(enabled)
        return None
    }
    Some("unknown action")
}

/** 推断 `cron.add` 使用的子类型：显式 `action` 或按 `cron_expr` / `at` / `every` 字段。 */
public func gatewayCronInferAddAction(params: JsonObject): Option<String> {
    let actRaw = gatewayCronRpcString(params, "action").trimAscii().toAsciiLower()
    if (actRaw == "add_every" || actRaw == "add_at" || actRaw == "add_cron") {
        return Some(actRaw)
    }
    let ce = gatewayCronRpcStringForKeysOrEmpty(params, ["cron_expr", "cronExpr"]).trimAscii()
    let at = gatewayCronRpcString(params, "at").trimAscii()
    let ev = gatewayCronRpcString(params, "every").trimAscii()
    if (!ce.isEmpty()) {
        return Some("add_cron")
    }
    if (!at.isEmpty()) {
        return Some("add_at")
    }
    if (!ev.isEmpty()) {
        return Some("add_every")
    }
    None
}
