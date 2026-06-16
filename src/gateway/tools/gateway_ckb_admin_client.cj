package metis.gateway.tools

import metis.gateway.model.{GatewayCkbAdminConfig, gatewayCkbAdminDefaultAllowedTasks}

import std.collection.ArrayList
import std.fs.{File, Path}
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.net.http.*

public class GatewayCkbRefreshModeMapping {
    public let ok: Bool
    public let taskNames: Array<String>
    public let statusOnly: Bool
    public let status: String

    public init(ok: Bool, taskNames!: Array<String> = [], statusOnly!: Bool = false, status!: String = "ok") {
        this.ok = ok
        this.taskNames = taskNames
        this.statusOnly = statusOnly
        this.status = status
    }
}

public class GatewayCkbAdminHttpRequest {
    public let method: String
    public let path: String
    public let url: String
    public let body: String
    public let timeoutMs: Int64
    public let authorizationHeader: String

    public init(method: String, path: String, url: String, body!: String = "", timeoutMs!: Int64 = 5000, authorizationHeader!: String = "") {
        this.method = method.trimAscii()
        this.path = path.trimAscii()
        this.url = url.trimAscii()
        this.body = body.trimAscii()
        this.timeoutMs = if (timeoutMs > 0) { timeoutMs } else { 5000 }
        this.authorizationHeader = authorizationHeader.trimAscii()
    }
}

public class GatewayCkbAdminHttpResponse {
    public let statusCode: Int64
    public let body: String
    public let error: String

    public init(statusCode: Int64, body!: String = "", error!: String = "") {
        this.statusCode = statusCode
        this.body = ckbAdminRedact(body.trimAscii())
        this.error = ckbAdminRedact(error.trimAscii())
    }
}

public class GatewayCkbAdminCommandResult {
    public let ok: Bool
    public let action: String
    public let status: String
    public let message: String
    public let result: JsonObject
    public let statusPayload: JsonObject
    public let schedulesPayload: JsonObject
    public let httpStatus: Int64

    public init(
        ok: Bool,
        action!: String = "ckb-refresh",
        status!: String = "ok",
        message!: String = "",
        result!: JsonObject = JsonObject(),
        statusPayload!: JsonObject = JsonObject(),
        schedulesPayload!: JsonObject = JsonObject(),
        httpStatus!: Int64 = 0
    ) {
        this.ok = ok
        this.action = action
        this.status = status.trimAscii()
        this.message = ckbAdminRedact(message.trimAscii())
        this.result = result
        this.statusPayload = statusPayload
        this.schedulesPayload = schedulesPayload
        this.httpStatus = httpStatus
    }
}

private var gatewayCkbAdminHttpRunnerForTest: Option<(GatewayCkbAdminHttpRequest) -> GatewayCkbAdminHttpResponse> =
    None<(GatewayCkbAdminHttpRequest) -> GatewayCkbAdminHttpResponse>

public func setGatewayCkbAdminHttpRunnerForTest(runner: Option<(GatewayCkbAdminHttpRequest) -> GatewayCkbAdminHttpResponse>): Unit {
    gatewayCkbAdminHttpRunnerForTest = runner
}

private func ckbAdminRedact(raw: String): String {
    raw.replace("Authorization: Bearer", "Authorization: [redacted]")
        .replace("Authorization", "[redacted-header]")
        .replace("admin-test-token", "[redacted-token]")
}

private func ckbAdminEndpointUrl(endpoint: String, path: String): String {
    let base = endpoint.trimAscii()
    if (base.endsWith("/")) {
        base[..base.size - 1] + path
    } else {
        base + path
    }
}

private func ckbAdminReadAllBytes(response: HttpResponse): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
    }
    out.toArray()
}

private func ckbAdminNativeSend(request: GatewayCkbAdminHttpRequest): GatewayCkbAdminHttpResponse {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * request.timeoutMs)
    let client = builder.build()
    try {
        let reqBuilder = if (request.method == "GET") {
            HttpRequestBuilder().url(request.url).get()
        } else {
            HttpRequestBuilder().url(request.url).post().body(request.body)
        }
        reqBuilder.header("Accept", "application/json")
        if (request.method == "POST") {
            reqBuilder.header("Content-Type", "application/json")
        }
        if (!request.authorizationHeader.isEmpty()) {
            reqBuilder.header("Authorization", request.authorizationHeader)
        }
        let response = client.send(reqBuilder.build())
        let body = try { String.fromUtf8(ckbAdminReadAllBytes(response)) } catch (_: Exception) { "" }
        GatewayCkbAdminHttpResponse(Int64(response.status), body: body)
    } catch (e: Exception) {
        GatewayCkbAdminHttpResponse(0, error: e.message)
    } finally {
        client.close()
    }
}

private func ckbAdminSend(request: GatewayCkbAdminHttpRequest): GatewayCkbAdminHttpResponse {
    match (gatewayCkbAdminHttpRunnerForTest) {
        case Some(runner) => runner(request)
        case None => ckbAdminNativeSend(request)
    }
}

private func ckbAdminJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func ckbAdminJsonIntText(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => v.toJsonString()
        case None => ""
    }
}

private func ckbAdminResultObject(response: GatewayCkbAdminHttpResponse): Option<JsonObject> {
    if (response.statusCode < 200 || response.statusCode >= 300) {
        return None<JsonObject>
    }
    let root = try { JsonValue.fromStr(response.body).asObject() } catch (_: Exception) { return None<JsonObject> }
    let ok = try { root.get("ok").getOrThrow().asBool().getValue() } catch (_: Exception) { false }
    if (!ok) {
        return None<JsonObject>
    }
    match (root.get("result")) {
        case Some(v) => try { Some<JsonObject>(v.asObject()) } catch (_: Exception) { None<JsonObject> }
        case None => None<JsonObject>
    }
}

private func ckbAdminToken(config: GatewayCkbAdminConfig): String {
    if (!config.adminToken.trimAscii().isEmpty()) {
        return config.adminToken.trimAscii()
    }
    if (config.adminTokenFile.trimAscii().isEmpty()) {
        return ""
    }
    try { String.fromUtf8(File.readFrom(Path(config.adminTokenFile))).trimAscii() } catch (_: Exception) { "" }
}

private func ckbAdminTaskAllowed(config: GatewayCkbAdminConfig, task: String): Bool {
    config.allowedTasks.contains(task.trimAscii())
}

private func ckbAdminConfigReady(config: GatewayCkbAdminConfig): GatewayCkbAdminCommandResult {
    if (!config.enabled) {
        return GatewayCkbAdminCommandResult(false, status: "disabled", message: "CKB admin integration is disabled.")
    }
    if (config.endpoint.trimAscii().isEmpty()) {
        return GatewayCkbAdminCommandResult(false, status: "not_configured", message: "CKB admin endpoint is not configured.")
    }
    if (ckbAdminToken(config).isEmpty()) {
        return GatewayCkbAdminCommandResult(false, status: "not_configured", message: "CKB admin token is not configured.")
    }
    GatewayCkbAdminCommandResult(true)
}

public func gatewayCkbRefreshModeToTaskNames(mode: String): GatewayCkbRefreshModeMapping {
    match (mode.trimAscii().toAsciiLower()) {
        case "repo-catalog" => GatewayCkbRefreshModeMapping(true, taskNames: ["community_repo_discovery_30d"])
        case "docs" => GatewayCkbRefreshModeMapping(true, taskNames: ["docs_probe_30d"])
        case "website-probe" => GatewayCkbRefreshModeMapping(true, taskNames: ["website_probe_weekly"])
        case "website-full" => GatewayCkbRefreshModeMapping(true, taskNames: ["website_full_weekly"])
        case "web-candidates" => GatewayCkbRefreshModeMapping(true, taskNames: ["web_candidate_weekly"])
        case "web-candidates-recrawl" => GatewayCkbRefreshModeMapping(true, taskNames: ["web_candidate_recrawl_30d"])
        case "rebuild" => GatewayCkbRefreshModeMapping(true, taskNames: ["weekly_full_rebuild"])
        case "both" => GatewayCkbRefreshModeMapping(true, taskNames: ["community_repo_discovery_30d", "docs_probe_30d"])
        case "status" => GatewayCkbRefreshModeMapping(true, statusOnly: true)
        case _ => GatewayCkbRefreshModeMapping(false, status: "unsupported")
    }
}

private func ckbAdminPost(config: GatewayCkbAdminConfig, path: String, body: JsonObject): GatewayCkbAdminHttpResponse {
    let token = ckbAdminToken(config)
    ckbAdminSend(GatewayCkbAdminHttpRequest(
        "POST",
        path,
        ckbAdminEndpointUrl(config.endpoint, path),
        body: body.toJsonString(),
        timeoutMs: config.timeoutMs,
        authorizationHeader: if (token.isEmpty()) { "" } else { "Bearer ${token}" }
    ))
}

private func ckbAdminGet(config: GatewayCkbAdminConfig, path: String): GatewayCkbAdminHttpResponse {
    let token = ckbAdminToken(config)
    ckbAdminSend(GatewayCkbAdminHttpRequest(
        "GET",
        path,
        ckbAdminEndpointUrl(config.endpoint, path),
        timeoutMs: config.timeoutMs,
        authorizationHeader: if (token.isEmpty()) { "" } else { "Bearer ${token}" }
    ))
}

public func gatewayCkbAdminRunSchedulerTasks(
    config: GatewayCkbAdminConfig,
    taskNames: Array<String>,
    source: String,
    requestedBy: String
): GatewayCkbAdminCommandResult {
    let ready = ckbAdminConfigReady(config)
    if (!ready.ok) {
        return ready
    }
    if (taskNames.size == 0) {
        return GatewayCkbAdminCommandResult(false, status: "usage", message: "Usage: /ckb-refresh <target>")
    }
    for (task in taskNames) {
        if (!ckbAdminTaskAllowed(config, task)) {
            return GatewayCkbAdminCommandResult(false, status: "unsupported", message: "unsupported CKB refresh task: ${task}")
        }
    }
    let arr = JsonArray([])
    for (task in taskNames) {
        arr.add(JsonString(task))
    }
    let body = JsonObject()
    body.put("taskNames", arr)
    body.put("force", JsonBool(true))
    body.put("reason", JsonString("operator_requested"))
    body.put("source", JsonString(source.trimAscii()))
    body.put("requestedBy", JsonString(requestedBy.trimAscii()))
    let response = ckbAdminPost(config, "/v1/admin/scheduler/run", body)
    match (ckbAdminResultObject(response)) {
        case Some(result) =>
            GatewayCkbAdminCommandResult(true, status: ckbAdminJsonString(result, "status"), result: result, httpStatus: response.statusCode)
        case None =>
            GatewayCkbAdminCommandResult(false, status: "http_error", message: if (response.statusCode == 0) { response.error } else { "CKB admin HTTP ${response.statusCode}" }, httpStatus: response.statusCode)
    }
}

public func gatewayCkbAdminStatus(config: GatewayCkbAdminConfig): GatewayCkbAdminCommandResult {
    let ready = ckbAdminConfigReady(config)
    if (!ready.ok) {
        return ready
    }
    let statusResponse = ckbAdminGet(config, "/v1/status")
    match (ckbAdminResultObject(statusResponse)) {
        case Some(statusPayload) =>
            let schedulesResponse = ckbAdminGet(config, "/v1/schedules")
            match (ckbAdminResultObject(schedulesResponse)) {
                case Some(schedulesPayload) =>
                    GatewayCkbAdminCommandResult(true, status: "status", statusPayload: statusPayload, schedulesPayload: schedulesPayload, httpStatus: schedulesResponse.statusCode)
                case None =>
                    GatewayCkbAdminCommandResult(false, status: "http_error", message: if (schedulesResponse.statusCode == 0) { schedulesResponse.error } else { "CKB schedules HTTP ${schedulesResponse.statusCode}" }, httpStatus: schedulesResponse.statusCode)
            }
        case None =>
            GatewayCkbAdminCommandResult(false, status: "http_error", message: if (statusResponse.statusCode == 0) { statusResponse.error } else { "CKB status HTTP ${statusResponse.statusCode}" }, httpStatus: statusResponse.statusCode)
    }
}

public func gatewayCkbAdminCommand(
    config: GatewayCkbAdminConfig,
    commandText: String,
    source: String,
    requestedBy: String
): GatewayCkbAdminCommandResult {
    let parts = commandText.trimAscii().split(" ", 2)
    if (parts.size < 2 || parts[1].trimAscii().isEmpty()) {
        return GatewayCkbAdminCommandResult(false, status: "usage", message: "Usage: /ckb-refresh <repo-catalog|docs|website-probe|website-full|web-candidates|web-candidates-recrawl|rebuild|both|status>")
    }
    let mapped = gatewayCkbRefreshModeToTaskNames(parts[1].trimAscii())
    if (!mapped.ok) {
        return GatewayCkbAdminCommandResult(false, status: mapped.status, message: "unsupported CKB refresh target: ${parts[1].trimAscii()}")
    }
    if (mapped.statusOnly) {
        return gatewayCkbAdminStatus(config)
    }
    gatewayCkbAdminRunSchedulerTasks(config, mapped.taskNames, source, requestedBy)
}

private func ckbAdminRenderTaskNames(result: JsonObject): String {
    match (result.get("taskNames")) {
        case Some(v) => v.toJsonString()
        case None => "[]"
    }
}

private func ckbAdminRenderScheduleLine(schedules: JsonObject, task: String): String {
    match (schedules.get(task)) {
        case Some(v) =>
            let obj = try { v.asObject() } catch (_: Exception) { return "" }
            let last = ckbAdminJsonString(obj, "lastSuccessAt")
            if (last.isEmpty()) {
                ""
            } else {
                "${task}.lastSuccessAt: ${last}"
            }
        case None => ""
    }
}

public func gatewayRenderCkbAdminCommandResult(result: GatewayCkbAdminCommandResult): String {
    if (!result.ok) {
        let detail = if (result.httpStatus > 0) { "HTTP ${result.httpStatus}" } else { result.message }
        return "CKB refresh failed: ${result.status}\n${ckbAdminRedact(detail)}"
    }
    if (result.status == "status") {
        let lines = ArrayList<String>()
        lines.add("CKB status")
        let repoCatalogVersion = ckbAdminJsonString(result.statusPayload, "repoCatalogVersion")
        if (!repoCatalogVersion.isEmpty()) {
            lines.add("repoCatalogVersion: ${repoCatalogVersion}")
        }
        let repoCount = ckbAdminJsonIntText(result.statusPayload, "repoCount")
        if (!repoCount.isEmpty()) {
            lines.add("repoCount: ${repoCount}")
        }
        for (task in gatewayCkbAdminDefaultAllowedTasks()) {
            let line = ckbAdminRenderScheduleLine(result.schedulesPayload, task)
            if (!line.isEmpty()) {
                lines.add(line)
            }
        }
        return ckbAdminRedact(String.join(lines.toArray(), delimiter: "\n"))
    }
    let status = if (result.status.isEmpty()) { "ok" } else { result.status }
    let lines = ArrayList<String>()
    lines.add("CKB refresh: ${status}")
    lines.add("taskNames: ${ckbAdminRenderTaskNames(result.result)}")
    let ran = ckbAdminJsonIntText(result.result, "ran")
    if (!ran.isEmpty()) {
        lines.add("ran: ${ran}")
    }
    let succeeded = ckbAdminJsonIntText(result.result, "succeeded")
    if (!succeeded.isEmpty()) {
        lines.add("succeeded: ${succeeded}")
    }
    let repoCount = ckbAdminJsonIntText(result.result, "repoCount")
    if (!repoCount.isEmpty()) {
        lines.add("repoCount: ${repoCount}")
    }
    let knowledgeVersion = ckbAdminJsonString(result.result, "knowledgeVersion")
    if (!knowledgeVersion.isEmpty()) {
        lines.add("knowledgeVersion: ${knowledgeVersion}")
    }
    ckbAdminRedact(String.join(lines.toArray(), delimiter: "\n"))
}
