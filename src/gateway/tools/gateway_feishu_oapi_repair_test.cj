package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private func feishuOapiRepairTestMediaContext(accountId: String, chatId: String, userId: String, messageId: String): JsonObject {
    let route = JsonObject()
    route.put("channel", JsonString("feishu"))
    route.put("accountId", JsonString(accountId))
    route.put("peerKind", JsonString("group"))
    route.put("peerId", JsonString(chatId))
    route.put("senderId", JsonString(userId))
    route.put("messageId", JsonString(messageId))

    let context = JsonObject()
    context.put("imRoute", route)

    let media = JsonObject()
    media.put("channel", JsonString("feishu"))
    media.put("accountId", JsonString(accountId))
    media.put("peerId", JsonString(chatId))
    media.put("context", context)
    media
}

private func feishuOapiRepairTestRunner(status: String, scopes: Array<String>, secretMarker!: String = ""): (String, JsonObject) -> JsonObject {
    { _method: String, _payload: JsonObject =>
        let out = JsonObject()
        out.put("ok", JsonBool(false))
        out.put("status", JsonString(status))
        let arr = JsonArray([])
        for (scope in scopes) {
            arr.add(JsonString(scope))
        }
        out.put("missing_scopes", arr)
        if (!secretMarker.isEmpty()) {
            out.put("error", JsonString("token=${secretMarker}; refresh_token=${secretMarker}"))
        }
        out
    }
}

@Test
public class GatewayFeishuOapiRepairTest {
    @TestCase
    public func authRequiredResultIncludesReadyRedactedRepairActionWithContext(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("auth_required", ["im:message"])))
        try {
            let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_user", "om_turn")
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "agent:main:feishu:oc_chat", senderId: "ou_user", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
                        "feishu_im_user_message",
                        "send",
                        Some("tenant-a"),
                        Some("{\"body\":{\"content\":\"hello\"}}")
                    )
                }
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("status").getOrThrow().asString().getValue(), "auth_required")
            let repair = json.get("repair_action").getOrThrow().asObject()
            @Expect(repair.get("status").getOrThrow().asString().getValue(), "ready")
            @Expect(repair.get("kind").getOrThrow().asString().getValue(), "feishu_oapi_auth_repair")
            @Expect(repair.get("account_id").getOrThrow().asString().getValue(), "tenant-a")
            @Expect(repair.get("chat_id").getOrThrow().asString().getValue(), "oc_chat")
            @Expect(repair.get("user_id").getOrThrow().asString().getValue(), "ou_user")
            @Expect(repair.get("redacted").getOrThrow().asBool().getValue(), true)
            @Expect(repair.get("can_start").getOrThrow().asBool().getValue(), true)
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func scopeMissingRepairMergesScopesForSameTurnAccountAndUser(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_user", "om_turn")
        try {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("scope_missing", ["im:message"])))
            let first = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-merge", senderId: "ou_user", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_im_user_message", "send", Some("tenant-a"), Some("{}"))
                }
            )
            let firstRepair = JsonValue.fromStr(first).asObject().get("repair_action").getOrThrow().asObject()
            @Expect(firstRepair.get("merge").getOrThrow().asObject().get("request_count").getOrThrow().asInt().getValue(), 1)

            debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("scope_missing", ["contact:user:search"])))
            let second = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-merge", senderId: "ou_user", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_search_user", "search", Some("tenant-a"), Some("{}"))
                }
            )
            let repair = JsonValue.fromStr(second).asObject().get("repair_action").getOrThrow().asObject()
            let merge = repair.get("merge").getOrThrow().asObject()
            @Expect(merge.get("request_count").getOrThrow().asInt().getValue(), 2)
            @Expect(merge.get("merged").getOrThrow().asBool().getValue(), true)
            let mergedScopes = merge.get("merged_scopes").getOrThrow().asArray().toJsonString()
            @Expect(mergedScopes.contains("im:message"), true)
            @Expect(mergedScopes.contains("contact:user:search"), true)
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func appScopeMissingRepairActionIsOperatorRequiredAndRedacted(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("app_scope_missing", ["calendar:calendar.event:write"])))
        try {
            let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_admin", "om_turn")
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-app-scope", senderId: "ou_admin", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_calendar_event", "create", Some("tenant-a"), Some("{}"))
                }
            )
            let repair = JsonValue.fromStr(out).asObject().get("repair_action").getOrThrow().asObject()
            @Expect(repair.get("kind").getOrThrow().asString().getValue(), "feishu_oapi_app_scope_repair")
            @Expect(repair.get("status").getOrThrow().asString().getValue(), "operator_required")
            @Expect(repair.get("can_start").getOrThrow().asBool().getValue(), false)
            @Expect(repair.get("redacted").getOrThrow().asBool().getValue(), true)
            @Expect(repair.get("scopes").getOrThrow().asArray()[0].asString().getValue(), "calendar:calendar.event:write")
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func missingCredentialResultIncludesOperatorRepairActionWithoutStartingNetwork(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("missing_credential", ["task:task:write"])))
        try {
            let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_admin", "om_turn")
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-credential", senderId: "ou_admin", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_task_task", "append_steps", Some("tenant-a"), Some("{}"))
                }
            )
            let repair = JsonValue.fromStr(out).asObject().get("repair_action").getOrThrow().asObject()
            @Expect(repair.get("kind").getOrThrow().asString().getValue(), "feishu_oapi_credential_repair")
            @Expect(repair.get("token_mode").getOrThrow().asString().getValue(), "tenant_access_token")
            @Expect(repair.get("status").getOrThrow().asString().getValue(), "operator_required")
            @Expect(repair.get("can_start").getOrThrow().asBool().getValue(), false)
            @Expect(repair.get("repair_method").getOrThrow().asString().getValue(), "configure_feishu_app_credentials")
            @Expect(repair.get("network").getOrThrow().asString().getValue(), "not_started")
            @Expect(repair.get("redacted").getOrThrow().asBool().getValue(), true)
            @Expect(repair.get("missing_fields").getOrThrow().asArray()[0].asString().getValue(), "app_id")
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func oauthAppTokenMissingCredentialRepairActionIsOperatorRequiredAndRedacted(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("missing_credential", ["offline_access"])))
        try {
            let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_admin", "om_turn")
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-oauth-app-token", senderId: "ou_admin", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_oauth", "default", Some("tenant-a"), Some("{}"))
                }
            )
            let repair = JsonValue.fromStr(out).asObject().get("repair_action").getOrThrow().asObject()
            @Expect(repair.get("kind").getOrThrow().asString().getValue(), "feishu_oapi_credential_repair")
            @Expect(repair.get("token_mode").getOrThrow().asString().getValue(), "app_access_token")
            @Expect(repair.get("status").getOrThrow().asString().getValue(), "operator_required")
            @Expect(repair.get("can_start").getOrThrow().asBool().getValue(), false)
            @Expect(repair.get("repair_method").getOrThrow().asString().getValue(), "configure_feishu_app_credentials")
            @Expect(repair.get("network").getOrThrow().asString().getValue(), "not_started")
            @Expect(repair.toJsonString().contains("accessToken"), false)
            @Expect(repair.toJsonString().contains("Authorization"), false)
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func uatScopeMissingRepairActionStartsNativeAuthMethod(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("scope_missing", ["im:message"])))
        try {
            let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_user", "om_turn")
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-uat-scope", senderId: "ou_user", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_im_user_message", "send", Some("tenant-a"), Some("{}"))
                }
            )
            let repair = JsonValue.fromStr(out).asObject().get("repair_action").getOrThrow().asObject()
            @Expect(repair.get("kind").getOrThrow().asString().getValue(), "feishu_oapi_auth_repair")
            @Expect(repair.get("token_mode").getOrThrow().asString().getValue(), "user_access_token")
            @Expect(repair.get("status").getOrThrow().asString().getValue(), "ready")
            @Expect(repair.get("can_start").getOrThrow().asBool().getValue(), true)
            @Expect(repair.get("repair_method").getOrThrow().asString().getValue(), "channels.feishu.auth.start")
            @Expect(repair.get("network").getOrThrow().asString().getValue(), "not_started")
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func missingTicketChatOrUserContextReturnsDiagnosticOnlyRepairAction(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("scope_missing", ["docx:document:readonly"])))
        try {
            let out = GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
                "feishu_fetch_doc",
                "fetch",
                Some("tenant-a"),
                Some("{\"doc_id\":\"doccn_demo\"}")
            )
            let repair = JsonValue.fromStr(out).asObject().get("repair_action").getOrThrow().asObject()
            @Expect(repair.get("status").getOrThrow().asString().getValue(), "diagnostic_only")
            @Expect(repair.get("can_start").getOrThrow().asBool().getValue(), false)
            @Expect(repair.get("reason").getOrThrow().asString().getValue(), "missing_ticket_chat_or_user_context")
            @Expect(repair.get("redacted").getOrThrow().asBool().getValue(), true)
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }

    @TestCase
    public func repairActionDoesNotEchoTokensSecretsOrRefreshTokens(): Unit {
        debugResetGatewayFeishuOapiRepairForTest()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some(feishuOapiRepairTestRunner("auth_required", ["im:message"], secretMarker: "secret-token-value")))
        try {
            let media = feishuOapiRepairTestMediaContext("tenant-a", "oc_chat", "ou_user", "om_turn")
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("feishu", channelName: "feishu", sessionKey: "turn-redact", senderId: "ou_user", mediaContext: media),
                { =>
                    GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest("feishu_im_user_message", "send", Some("tenant-a"), Some("{}"))
                }
            )
            let repair = JsonValue.fromStr(out).asObject().get("repair_action").getOrThrow().asObject().toJsonString()
            @Expect(repair.contains("secret-token-value"), false)
            @Expect(repair.contains("refresh_token"), false)
            @Expect(repair.contains("accessToken"), false)
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            debugResetGatewayFeishuOapiRepairForTest()
        }
    }
}
