package metis.gateway.tools

import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

public class FeishuOapiRequest {
    public let toolName: String
    public let category: String
    public let domain: String
    public let action: String
    public let accountId: String
    public let path: String
    public let method: String
    public let tokenMode: String
    public let params: JsonObject
    public let requiredScopes: Array<String>

    public init(
        toolName: String,
        category: String,
        domain: String,
        action: String,
        accountId: String,
        path: String,
        method: String,
        tokenMode: String,
        params: JsonObject,
        requiredScopes: Array<String>
    ) {
        this.toolName = toolName.trimAscii()
        this.category = category.trimAscii()
        this.domain = domain.trimAscii()
        this.action = action.trimAscii()
        this.accountId = accountId.trimAscii()
        this.path = path.trimAscii()
        this.method = method.trimAscii()
        this.tokenMode = tokenMode.trimAscii()
        this.params = params
        this.requiredScopes = requiredScopes
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("tool", JsonString(this.toolName))
        out.put("category", JsonString(this.category))
        out.put("domain", JsonString(this.domain))
        out.put("action", JsonString(this.action))
        out.put("account_id", JsonString(this.accountId))
        out.put("path", JsonString(this.path))
        out.put("method", JsonString(this.method))
        out.put("token_mode", JsonString(this.tokenMode))
        out.put("required_scopes", feishuOapiJsonStringArray(this.requiredScopes))
        out.put("params", this.params)
        out
    }
}

public class FeishuOapiResult {
    private let request: FeishuOapiRequest
    private let ok: Bool
    private let status: String
    private let data: Option<JsonValue>
    private let error: String
    private let missingScopes: Array<String>
    private let authState: String

    public init(
        request: FeishuOapiRequest,
        ok: Bool,
        status: String,
        data!: Option<JsonValue> = None<JsonValue>,
        error!: String = "",
        missingScopes!: Array<String> = [],
        authState!: String = ""
    ) {
        this.request = request
        this.ok = ok
        this.status = status.trimAscii()
        this.data = data
        this.error = error.trimAscii()
        this.missingScopes = missingScopes
        this.authState = authState.trimAscii()
    }

    public static func success(request: FeishuOapiRequest, data: JsonValue): FeishuOapiResult {
        FeishuOapiResult(request, true, "success", data: Some(data))
    }

    public static func authRequired(request: FeishuOapiRequest, authState!: String = "absent", error!: String = ""): FeishuOapiResult {
        FeishuOapiResult(
            request,
            false,
            "auth_required",
            error: if (error.trimAscii().isEmpty()) {
                "Feishu OAPI user authorization is not configured in this runtime. Configure account auth before calling this tool against Feishu."
            } else {
                error.trimAscii()
            },
            authState: if (authState.trimAscii().isEmpty()) { "absent" } else { authState.trimAscii() }
        )
    }

    public static func scopeMissing(request: FeishuOapiRequest, missingScopes: Array<String>, error!: String = ""): FeishuOapiResult {
        FeishuOapiResult(
            request,
            false,
            "scope_missing",
            error: if (error.trimAscii().isEmpty()) { "Feishu OAPI required scope is missing." } else { error.trimAscii() },
            missingScopes: missingScopes
        )
    }

    public static func apiError(request: FeishuOapiRequest, error: String, data!: Option<JsonValue> = None<JsonValue>): FeishuOapiResult {
        FeishuOapiResult(request, false, "api_error", data: data, error: error)
    }

    public static func invalidRequest(request: FeishuOapiRequest, error: String): FeishuOapiResult {
        FeishuOapiResult(request, false, "invalid_request", error: error)
    }

    public func toJson(): JsonObject {
        let out = this.request.toJson()
        out.put("ok", JsonBool(this.ok))
        out.put("status", JsonString(this.status))
        out.put("client", JsonString("metis_feishu_oapi_client"))
        if (!this.error.isEmpty()) {
            out.put("error", JsonString(this.error))
            if (this.status == "invalid_request") {
                out.put("reason", JsonString(this.error))
            }
        }
        if (this.missingScopes.size > 0) {
            out.put("missing_scopes", feishuOapiJsonStringArray(this.missingScopes))
        }
        match (this.data) {
            case Some(v) => out.put("data", v)
            case None => ()
        }
        if (this.status == "auth_required") {
            let auth = JsonObject()
            auth.put("required", JsonBool(true))
            auth.put("state", JsonString(if (this.authState.isEmpty()) { "absent" } else { this.authState }))
            auth.put("mode", JsonString(this.request.tokenMode))
            out.put("auth", auth)
        }
        out
    }
}

public class FeishuOapiTokenLookup {
    public let status: String
    public let accessToken: String
    public let missingScopes: Array<String>
    public let error: String

    public init(status: String, accessToken!: String = "", missingScopes!: Array<String> = [], error!: String = "") {
        this.status = status.trimAscii()
        this.accessToken = accessToken.trimAscii()
        this.missingScopes = missingScopes
        this.error = error.trimAscii()
    }
}

public class FeishuOapiHttpResponse {
    public let ok: Bool
    public let statusCode: Int64
    public let body: JsonValue
    public let error: String

    public init(ok: Bool, statusCode!: Int64 = 0, body!: JsonValue = JsonObject(), error!: String = "") {
        this.ok = ok
        this.statusCode = statusCode
        this.body = body
        this.error = error.trimAscii()
    }
}

public interface FeishuOapiTokenProvider {
    func userAccessToken(accountId: String, requiredScopes: Array<String>): FeishuOapiTokenLookup
}

public interface FeishuOapiHttpClient {
    func request(request: FeishuOapiRequest, accessToken: String): FeishuOapiHttpResponse
}

public interface FeishuOapiClient {
    func invoke(request: FeishuOapiRequest): JsonObject
}

public class MetisFeishuOapiClient <: FeishuOapiClient {
    private let tokenProvider: Option<FeishuOapiTokenProvider>
    private let httpClient: Option<FeishuOapiHttpClient>

    public init(
        tokenProvider!: Option<FeishuOapiTokenProvider> = None<FeishuOapiTokenProvider>,
        httpClient!: Option<FeishuOapiHttpClient> = None<FeishuOapiHttpClient>
    ) {
        this.tokenProvider = tokenProvider
        this.httpClient = httpClient
    }

    public func invoke(request: FeishuOapiRequest): JsonObject {
        let token = match (this.tokenProvider) {
            case Some(provider) => provider.userAccessToken(request.accountId, request.requiredScopes)
            case None => return FeishuOapiResult.authRequired(request).toJson()
        }
        if (token.status == "scope_missing") {
            return FeishuOapiResult.scopeMissing(request, token.missingScopes, error: token.error).toJson()
        }
        if (token.status == "auth_required" || token.accessToken.isEmpty()) {
            return FeishuOapiResult.authRequired(request, authState: token.status, error: token.error).toJson()
        }
        match (this.httpClient) {
            case Some(http) =>
                let response = http.request(request, token.accessToken)
                if (response.ok) {
                    return FeishuOapiResult.success(request, response.body).toJson()
                }
                return FeishuOapiResult.apiError(
                    request,
                    if (response.error.isEmpty()) { "Feishu OAPI request failed with HTTP ${response.statusCode}." } else { response.error },
                    data: Some(response.body)
                ).toJson()
            case None =>
                FeishuOapiResult.apiError(request, "Feishu OAPI HTTP client is not configured for this runtime.").toJson()
        }
    }
}

public func feishuOapiBuildRequest(toolName: String, action: String, accountId: String, params: JsonObject): FeishuOapiRequest {
    let cleanTool = toolName.trimAscii()
    let cleanAction = if (action.trimAscii().isEmpty()) { "default" } else { action.trimAscii() }
    let category = feishuOapiCategoryForTool(cleanTool)
    FeishuOapiRequest(
        cleanTool,
        category,
        feishuOapiDomainForCategory(category),
        cleanAction,
        if (accountId.trimAscii().isEmpty()) { "default" } else { accountId.trimAscii() },
        feishuOapiPathForTool(cleanTool, cleanAction),
        feishuOapiMethodForAction(cleanAction),
        "user_access_token",
        params,
        feishuOapiRequiredScopesForTool(cleanTool, category, cleanAction)
    )
}

public func feishuOapiJsonStringArray(values: Array<String>): JsonArray {
    let arr = JsonArray([])
    for (value in values) {
        arr.add(JsonString(value.trimAscii()))
    }
    arr
}

public func feishuOapiCategoryForTool(toolName: String): String {
    let name = toolName.trimAscii()
    if (name == "feishu_fetch_doc" || name == "feishu_create_doc" || name == "feishu_update_doc" || name.startsWith("feishu_doc_")) {
        return "docs"
    }
    if (name.startsWith("feishu_wiki_")) {
        return "wiki"
    }
    if (name.startsWith("feishu_drive_")) {
        return "drive"
    }
    if (name.startsWith("feishu_search_doc")) {
        return "search"
    }
    if (name.startsWith("feishu_bitable_")) {
        return "bitable"
    }
    if (name.startsWith("feishu_calendar_")) {
        return "calendar"
    }
    if (name.startsWith("feishu_task_")) {
        return "task"
    }
    if (name == "feishu_sheet") {
        return "sheets"
    }
    if (name.startsWith("feishu_chat")) {
        return "chat"
    }
    if (name == "feishu_get_user" || name == "feishu_search_user") {
        return "user"
    }
    if (name.startsWith("feishu_im_")) {
        return "im"
    }
    "oapi"
}

public func feishuOapiDomainForCategory(category: String): String {
    match (category.trimAscii()) {
        case "user" => "common"
        case "chat" => "chat"
        case "im" => "im"
        case "docs" => "docs"
        case "wiki" => "wiki"
        case "drive" => "drive"
        case "search" => "search"
        case "calendar" => "calendar"
        case "task" => "task"
        case "sheets" => "sheets"
        case "bitable" => "bitable"
        case _ => "common"
    }
}

public func feishuOapiRequiredScopesForTool(toolName: String, category: String, _action: String): Array<String> {
    let name = toolName.trimAscii()
    match (category.trimAscii()) {
        case "docs" =>
            if (name == "feishu_create_doc" || name == "feishu_update_doc") {
                return ["docx:document"]
            }
            ["docx:document:readonly"]
        case "wiki" => ["wiki:wiki:readonly"]
        case "drive" => ["drive:drive:readonly"]
        case "search" => ["docx:document:readonly", "wiki:wiki:readonly"]
        case "bitable" => ["bitable:app:readonly"]
        case "calendar" => ["calendar:calendar:readonly"]
        case "task" => ["task:task:readonly"]
        case "sheets" => ["sheets:spreadsheet:readonly"]
        case "chat" => ["im:chat:readonly"]
        case "user" => ["contact:contact.base:readonly"]
        case "im" =>
            if (name == "feishu_im_user_message") {
                return ["im:message"]
            }
            ["im:message:readonly"]
        case _ => []
    }
}

private func feishuOapiMethodForAction(action: String): String {
    let clean = action.trimAscii().toAsciiLower()
    if (clean == "create" || clean == "send" || clean == "search") {
        return "POST"
    }
    if (clean == "update" || clean == "patch") {
        return "PATCH"
    }
    if (clean == "delete" || clean == "remove") {
        return "DELETE"
    }
    "GET"
}

private func feishuOapiPathForTool(toolName: String, _action: String): String {
    let name = toolName.trimAscii()
    if (name == "feishu_fetch_doc") {
        return "/open-apis/docx/v1/documents/:document_id/raw_content"
    }
    if (name == "feishu_create_doc" || name == "feishu_update_doc") {
        return "/open-apis/docx/v1/documents"
    }
    if (name == "feishu_doc_comments") {
        return "/open-apis/docx/v1/documents/:document_id/comments"
    }
    if (name == "feishu_doc_media") {
        return "/open-apis/docx/v1/documents/:document_id/media"
    }
    if (name == "feishu_wiki_space_node") {
        return "/open-apis/wiki/v2/spaces/:space_id/nodes"
    }
    if (name == "feishu_wiki_space") {
        return "/open-apis/wiki/v2/spaces"
    }
    if (name == "feishu_drive_file") {
        return "/open-apis/drive/v1/files"
    }
    if (name == "feishu_search_doc_wiki") {
        return "/open-apis/search/v2/data_sources/:data_source_id/search"
    }
    if (name == "feishu_bitable_app_table_record") {
        return "/open-apis/bitable/v1/apps/:app_token/tables/:table_id/records"
    }
    if (name == "feishu_bitable_app_table_field") {
        return "/open-apis/bitable/v1/apps/:app_token/tables/:table_id/fields"
    }
    if (name == "feishu_bitable_app_table_view") {
        return "/open-apis/bitable/v1/apps/:app_token/tables/:table_id/views"
    }
    if (name == "feishu_bitable_app_table") {
        return "/open-apis/bitable/v1/apps/:app_token/tables"
    }
    if (name == "feishu_bitable_app") {
        return "/open-apis/bitable/v1/apps"
    }
    if (name == "feishu_calendar_event_attendee") {
        return "/open-apis/calendar/v4/calendars/:calendar_id/events/:event_id/attendees"
    }
    if (name == "feishu_calendar_event") {
        return "/open-apis/calendar/v4/calendars/:calendar_id/events"
    }
    if (name == "feishu_calendar_freebusy") {
        return "/open-apis/calendar/v4/freebusy/list"
    }
    if (name == "feishu_calendar_calendar") {
        return "/open-apis/calendar/v4/calendars"
    }
    if (name == "feishu_task_tasklist") {
        return "/open-apis/task/v2/tasklists"
    }
    if (name == "feishu_task_attachment") {
        return "/open-apis/task/v2/tasks/:task_guid/attachments"
    }
    if (name == "feishu_task_section") {
        return "/open-apis/task/v2/tasklists/:tasklist_guid/sections"
    }
    if (name == "feishu_task_comment") {
        return "/open-apis/task/v2/tasks/:task_guid/comments"
    }
    if (name == "feishu_task_subtask") {
        return "/open-apis/task/v2/tasks/:task_guid/subtasks"
    }
    if (name == "feishu_task_agent") {
        return "/open-apis/task/v2/tasks/:task_guid/collaborators"
    }
    if (name == "feishu_task_task") {
        return "/open-apis/task/v2/tasks"
    }
    if (name == "feishu_sheet") {
        return "/open-apis/sheets/v3/spreadsheets"
    }
    if (name == "feishu_chat_members") {
        return "/open-apis/im/v1/chats/:chat_id/members"
    }
    if (name == "feishu_chat") {
        return "/open-apis/im/v1/chats"
    }
    if (name == "feishu_get_user") {
        return "/open-apis/contact/v3/users/:user_id"
    }
    if (name == "feishu_search_user") {
        return "/open-apis/contact/v3/users/batch_get_id"
    }
    if (name == "feishu_im_user_get_thread_messages") {
        return "/open-apis/im/v1/messages/:message_id/replies"
    }
    if (name == "feishu_im_user_search_messages") {
        return "/open-apis/search/v2/data_sources/im_message/search"
    }
    if (name == "feishu_im_user_fetch_resource") {
        return "/open-apis/im/v1/messages/:message_id/resources/:file_key"
    }
    if (name == "feishu_im_user_get_messages" || name == "feishu_im_user_message") {
        return "/open-apis/im/v1/messages"
    }
    "/open-apis/${feishuOapiDomainForCategory(feishuOapiCategoryForTool(name))}/generic"
}
