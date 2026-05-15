package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayCurrentToolRuntimeContext}

import std.collection.ArrayList
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private var gatewayFeishuOapiRepairMergerForToolset = FeishuOapiAuthRequestMerger()

public func debugResetGatewayFeishuOapiRepairForTest(): Unit {
    gatewayFeishuOapiRepairMergerForToolset = FeishuOapiAuthRequestMerger()
}

private func feishuOapiRepairJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func feishuOapiRepairNormalizeAccountId(accountId: String): String {
    let clean = accountId.trimAscii()
    if (clean.isEmpty()) { "default" } else { clean }
}

private func feishuOapiRepairJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func feishuOapiRepairJsonStringArray(obj: JsonObject, key: String): Array<String> {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let arr = v.asArray()
                let out = ArrayList<String>()
                for (i in 0..arr.size()) {
                    try {
                        let value = arr[i].asString().getValue().trimAscii()
                        if (!value.isEmpty() && !out.contains(value)) {
                            out.add(value)
                        }
                    } catch (_e: Exception) {
                        ()
                    }
                }
                out.toArray()
            } catch (_e: Exception) {
                []
            }
        case None => []
    }
}

private func feishuOapiRepairMergedScopes(result: JsonObject, request: FeishuOapiRequest): Array<String> {
    let out = ArrayList<String>()
    let missing = feishuOapiRepairJsonStringArray(result, "missing_scopes")
    for (scope in missing) {
        if (!scope.trimAscii().isEmpty() && !out.contains(scope.trimAscii())) {
            out.add(scope.trimAscii())
        }
    }
    if (out.size == 0) {
        for (scope in request.requiredScopes) {
            let clean = scope.trimAscii()
            if (!clean.isEmpty() && !out.contains(clean)) {
                out.add(clean)
            }
        }
    }
    out.toArray()
}

private class FeishuOapiRepairContext {
    let turnKey: String
    let accountId: String
    let chatId: String
    let userId: String
    let ticketId: String
    let complete: Bool

    init(turnKey: String, accountId: String, chatId: String, userId: String, ticketId: String) {
        this.turnKey = turnKey.trimAscii()
        this.accountId = feishuOapiRepairNormalizeAccountId(accountId)
        this.chatId = chatId.trimAscii()
        this.userId = userId.trimAscii()
        this.ticketId = ticketId.trimAscii()
        this.complete = !this.turnKey.isEmpty() && !this.accountId.isEmpty() && !this.chatId.isEmpty() && !this.userId.isEmpty() && !this.ticketId.isEmpty()
    }
}

private func feishuOapiRepairContextFromRuntime(request: FeishuOapiRequest): FeishuOapiRepairContext {
    match (gatewayCurrentToolRuntimeContext()) {
        case Some(ctx) => feishuOapiRepairContextFromRuntimeContext(ctx, request)
        case None => FeishuOapiRepairContext("", request.accountId, "", "", "")
    }
}

private func feishuOapiRepairContextFromRuntimeContext(ctx: GatewayToolRuntimeContext, request: FeishuOapiRequest): FeishuOapiRepairContext {
    let media = ctx.mediaContext
    let mediaContext = feishuOapiRepairJsonObject(media, "context")
    let route = feishuOapiRepairJsonObject(mediaContext, "imRoute")

    let accountId = if (!feishuOapiRepairJsonString(route, "accountId").isEmpty()) {
        feishuOapiRepairJsonString(route, "accountId")
    } else if (!feishuOapiRepairJsonString(media, "accountId").isEmpty()) {
        feishuOapiRepairJsonString(media, "accountId")
    } else {
        request.accountId
    }
    let chatId = if (!feishuOapiRepairJsonString(route, "parentPeerId").isEmpty()) {
        feishuOapiRepairJsonString(route, "parentPeerId")
    } else if (!feishuOapiRepairJsonString(route, "peerId").isEmpty()) {
        feishuOapiRepairJsonString(route, "peerId")
    } else {
        feishuOapiRepairJsonString(media, "peerId")
    }
    let userId = if (!feishuOapiRepairJsonString(route, "senderId").isEmpty()) {
        feishuOapiRepairJsonString(route, "senderId")
    } else {
        ctx.senderId
    }
    let ticketId = feishuOapiRepairJsonString(route, "messageId")
    let turnKey = if (!ctx.sessionKey.isEmpty()) { ctx.sessionKey } else { ticketId }
    FeishuOapiRepairContext(turnKey, accountId, chatId, userId, ticketId)
}

private func feishuOapiRepairStatusSupportsAction(status: String): Bool {
    let clean = status.trimAscii()
    clean == "auth_required" || clean == "scope_missing" || clean == "app_scope_missing"
}

public func gatewayFeishuOapiAttachRepairActionForToolResult(result: JsonObject, request: FeishuOapiRequest): JsonObject {
    let status = feishuOapiRepairJsonString(result, "status")
    if (!feishuOapiRepairStatusSupportsAction(status)) {
        return result
    }

    let scopes = feishuOapiRepairMergedScopes(result, request)
    let ctx = feishuOapiRepairContextFromRuntime(request)
    let repair = JsonObject()
    repair.put("kind", JsonString(if (status == "app_scope_missing") { "feishu_oapi_app_scope_repair" } else { "feishu_oapi_auth_repair" }))
    repair.put("trigger_status", JsonString(status))
    repair.put("account_id", JsonString(request.accountId))
    repair.put("token_mode", JsonString(request.tokenMode))
    repair.put("tool", JsonString(request.toolName))
    repair.put("action", JsonString(request.action))
    repair.put("scopes", feishuOapiJsonStringArray(scopes))
    repair.put("redacted", JsonBool(true))

    if (!ctx.complete) {
        repair.put("status", JsonString("diagnostic_only"))
        repair.put("can_start", JsonBool(false))
        repair.put("reason", JsonString("missing_ticket_chat_or_user_context"))
        repair.put("network", JsonString("not_started"))
        result.put("repair_action", repair)
        return result
    }

    repair.put("chat_id", JsonString(ctx.chatId))
    repair.put("user_id", JsonString(ctx.userId))
    repair.put("ticket_id", JsonString(ctx.ticketId))
    repair.put("turn_key", JsonString(ctx.turnKey))
    repair.put(
        "merge",
        gatewayFeishuOapiRepairMergerForToolset.merge(ctx.turnKey, ctx.accountId, ctx.userId, scopes, status)
    )
    if (status == "app_scope_missing") {
        repair.put("status", JsonString("operator_required"))
        repair.put("can_start", JsonBool(false))
        repair.put("repair_method", JsonString("feishu_developer_console_scope_grant"))
    } else {
        repair.put("status", JsonString("ready"))
        repair.put("can_start", JsonBool(true))
        repair.put("repair_method", JsonString("channels.feishu.auth.start"))
    }
    repair.put("network", JsonString("not_started"))
    result.put("repair_action", repair)
    result
}
