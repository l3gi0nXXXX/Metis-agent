package metis.gateway.tools

import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private class FeishuOapiToolsetFakeClient <: FeishuOapiClient {
    let captured = ArrayList<String>()

    public init() {}

    public func invoke(request: FeishuOapiRequest): JsonObject {
        this.captured.add(request.toolName)
        this.captured.add(request.category)
        this.captured.add(request.domain)
        this.captured.add(request.action)
        this.captured.add(request.accountId)
        this.captured.add(request.path)
        this.captured.add(request.requiredScopes[0])
        this.captured.add(request.params.get("message").getOrThrow().asString().getValue())

        let data = JsonObject()
        data.put("message_id", JsonString("om_success"))
        return FeishuOapiResult.success(request, data).toJson()
    }
}

private class FeishuOapiToolsetScopeMissingTokenProvider <: FeishuOapiTokenProvider {
    public init() {}

    public func userAccessToken(_accountId: String, requiredScopes: Array<String>): FeishuOapiTokenLookup {
        FeishuOapiTokenLookup("scope_missing", missingScopes: requiredScopes, error: "missing test scope")
    }
}

private class FeishuOapiToolsetOkTokenProvider <: FeishuOapiTokenProvider {
    public init() {}

    public func userAccessToken(_accountId: String, _requiredScopes: Array<String>): FeishuOapiTokenLookup {
        FeishuOapiTokenLookup("authorized", accessToken: "fake-access-token")
    }
}

private class FeishuOapiToolsetErrorHttpClient <: FeishuOapiHttpClient {
    public let captured = ArrayList<String>()

    public init() {}

    public func request(request: FeishuOapiRequest, accessToken: String): FeishuOapiHttpResponse {
        this.captured.add(request.accountId)
        this.captured.add(request.path)
        this.captured.add(accessToken)
        let body = JsonObject()
        body.put("code", JsonString("99991672"))
        FeishuOapiHttpResponse(false, statusCode: 403, body: body, error: "forbidden")
    }
}

@Test
public class GatewayFeishuOapiToolsetTest {
    @TestCase
    public func defaultClientReturnsStructuredAuthRequiredThroughNativeBoundary(): Unit {
        let out = GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
            "feishu_fetch_doc",
            "fetch",
            Some("default"),
            Some("{\"doc_id\":\"doccn_demo\"}")
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "auth_required")
        @Expect(json.get("tool").getOrThrow().asString().getValue(), "feishu_fetch_doc")
        @Expect(json.get("category").getOrThrow().asString().getValue(), "docs")
        @Expect(json.get("domain").getOrThrow().asString().getValue(), "docs")
        @Expect(json.get("action").getOrThrow().asString().getValue(), "fetch")
        @Expect(json.get("path").getOrThrow().asString().getValue(), "/open-apis/docx/v1/documents/:document_id/raw_content")
        @Expect(json.get("client").getOrThrow().asString().getValue(), "metis_feishu_oapi_client")
        @Expect(json.get("account_id").getOrThrow().asString().getValue(), "default")
        let auth = json.get("auth").getOrThrow().asObject()
        @Expect(auth.get("required").getOrThrow().asBool().getValue(), true)
        @Expect(auth.get("state").getOrThrow().asString().getValue(), "absent")
        @Expect(json.get("required_scopes").getOrThrow().asArray()[0].asString().getValue(), "docx:document:readonly")
    }

    @TestCase
    public func typedClientReceivesDomainPathScopesAndCanReturnSuccess(): Unit {
        let fake = FeishuOapiToolsetFakeClient()
        debugSetGatewayFeishuOapiClientForTest(Some<FeishuOapiClient>(fake))
        try {
            let out = GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
                "feishu_im_user_message",
                "create",
                Some("team-a"),
                Some("{\"message\":\"hello\"}")
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(json.get("status").getOrThrow().asString().getValue(), "success")
            @Expect(json.get("tool").getOrThrow().asString().getValue(), "feishu_im_user_message")
            @Expect(json.get("category").getOrThrow().asString().getValue(), "im")
            @Expect(json.get("domain").getOrThrow().asString().getValue(), "im")
            @Expect(json.get("path").getOrThrow().asString().getValue(), "/open-apis/im/v1/messages")
            @Expect(json.get("account_id").getOrThrow().asString().getValue(), "team-a")
            @Expect(json.get("data").getOrThrow().asObject().get("message_id").getOrThrow().asString().getValue(), "om_success")
            @Expect(fake.captured[0], "feishu_im_user_message")
            @Expect(fake.captured[1], "im")
            @Expect(fake.captured[2], "im")
            @Expect(fake.captured[3], "create")
            @Expect(fake.captured[4], "team-a")
            @Expect(fake.captured[5], "/open-apis/im/v1/messages")
            @Expect(fake.captured[6], "im:message")
            @Expect(fake.captured[7], "hello")
        } finally {
            debugSetGatewayFeishuOapiClientForTest(None<FeishuOapiClient>)
        }
    }

    @TestCase
    public func fakeClientReceivesStructuredRequestAndCanReportScopeMissing(): Unit {
        let captured = ArrayList<String>()
        debugSetGatewayFeishuOapiToolCallRunnerForTest(Some({ method: String, payload: JsonObject =>
            captured.add(method)
            captured.add(payload.get("tool").getOrThrow().asString().getValue())
            captured.add(payload.get("category").getOrThrow().asString().getValue())
            captured.add(payload.get("action").getOrThrow().asString().getValue())
            captured.add(payload.get("account_id").getOrThrow().asString().getValue())
            captured.add(payload.get("params").getOrThrow().asObject().get("summary").getOrThrow().asString().getValue())

            let out = JsonObject()
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("scope_missing"))
            out.put("missing_scopes", JsonArray([JsonString("calendar:calendar:readonly")]))
            out
        }))
        try {
            let out = GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
                "feishu_calendar_event",
                "list",
                Some("work"),
                Some("{\"summary\":\"standup\"}")
            )
            let json = JsonValue.fromStr(out).asObject()
            @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(json.get("status").getOrThrow().asString().getValue(), "scope_missing")
            @Expect(json.get("tool").getOrThrow().asString().getValue(), "feishu_calendar_event")
            @Expect(json.get("category").getOrThrow().asString().getValue(), "calendar")
            @Expect(json.get("missing_scopes").getOrThrow().asArray()[0].asString().getValue(), "calendar:calendar:readonly")
            @Expect(captured[0], "feishu_calendar_event")
            @Expect(captured[1], "feishu_calendar_event")
            @Expect(captured[2], "calendar")
            @Expect(captured[3], "list")
            @Expect(captured[4], "work")
            @Expect(captured[5], "standup")
        } finally {
            debugSetGatewayFeishuOapiToolCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
        }
    }

    @TestCase
    public func invalidParamsJsonReturnsStructuredInvalidRequest(): Unit {
        let out = GatewayFeishuOapiToolset().debugFeishuOapiInvokeForTest(
            "feishu_bitable_app",
            "list",
            None<String>,
            Some("not-json")
        )
        let json = JsonValue.fromStr(out).asObject()
        @Expect(json.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(json.get("status").getOrThrow().asString().getValue(), "invalid_request")
        @Expect(json.get("tool").getOrThrow().asString().getValue(), "feishu_bitable_app")
        @Expect(json.get("reason").getOrThrow().asString().getValue().contains("params_json must be a JSON object"), true)
    }

    @TestCase
    public func nativeBoundaryCanReturnScopeMissingAndApiError(): Unit {
        let scopeRequest = feishuOapiBuildRequest("feishu_calendar_event", "list", "work", JsonObject())
        let scopeJson = MetisFeishuOapiClient(
            tokenProvider: Some<FeishuOapiTokenProvider>(FeishuOapiToolsetScopeMissingTokenProvider())
        ).invoke(scopeRequest)
        @Expect(scopeJson.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(scopeJson.get("status").getOrThrow().asString().getValue(), "scope_missing")
        @Expect(scopeJson.get("missing_scopes").getOrThrow().asArray()[0].asString().getValue(), "calendar:calendar:readonly")

        let http = FeishuOapiToolsetErrorHttpClient()
        let apiRequest = feishuOapiBuildRequest("feishu_chat", "list", "ops", JsonObject())
        let apiJson = MetisFeishuOapiClient(
            tokenProvider: Some<FeishuOapiTokenProvider>(FeishuOapiToolsetOkTokenProvider()),
            httpClient: Some<FeishuOapiHttpClient>(http)
        ).invoke(apiRequest)
        @Expect(apiJson.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(apiJson.get("status").getOrThrow().asString().getValue(), "api_error")
        @Expect(apiJson.get("error").getOrThrow().asString().getValue(), "forbidden")
        @Expect(http.captured[0], "ops")
        @Expect(http.captured[1], "/open-apis/im/v1/chats")
        @Expect(http.captured[2], "fake-access-token")
    }

    @TestCase
    public func requestBoundaryMapsOpenClawDomains(): Unit {
        let common = feishuOapiBuildRequest("feishu_get_user", "get", "a", JsonObject())
        @Expect(common.category, "user")
        @Expect(common.domain, "common")
        @Expect(common.requiredScopes[0], "contact:contact.base:readonly")

        let chat = feishuOapiBuildRequest("feishu_chat_members", "list", "a", JsonObject())
        @Expect(chat.category, "chat")
        @Expect(chat.domain, "chat")

        let im = feishuOapiBuildRequest("feishu_im_user_get_messages", "list", "a", JsonObject())
        @Expect(im.category, "im")
        @Expect(im.domain, "im")

        let docs = feishuOapiBuildRequest("feishu_fetch_doc", "fetch", "a", JsonObject())
        @Expect(docs.category, "docs")
        @Expect(docs.domain, "docs")

        let wiki = feishuOapiBuildRequest("feishu_wiki_space", "list", "a", JsonObject())
        @Expect(wiki.category, "wiki")
        @Expect(wiki.domain, "wiki")

        let drive = feishuOapiBuildRequest("feishu_drive_file", "list", "a", JsonObject())
        @Expect(drive.category, "drive")
        @Expect(drive.domain, "drive")

        let search = feishuOapiBuildRequest("feishu_search_doc_wiki", "search", "a", JsonObject())
        @Expect(search.category, "search")
        @Expect(search.domain, "search")

        let calendar = feishuOapiBuildRequest("feishu_calendar_calendar", "list", "a", JsonObject())
        @Expect(calendar.category, "calendar")
        @Expect(calendar.domain, "calendar")

        let task = feishuOapiBuildRequest("feishu_task_task", "list", "a", JsonObject())
        @Expect(task.category, "task")
        @Expect(task.domain, "task")

        let sheets = feishuOapiBuildRequest("feishu_sheet", "get", "a", JsonObject())
        @Expect(sheets.category, "sheets")
        @Expect(sheets.domain, "sheets")

        let bitable = feishuOapiBuildRequest("feishu_bitable_app", "list", "a", JsonObject())
        @Expect(bitable.category, "bitable")
        @Expect(bitable.domain, "bitable")
    }
}
