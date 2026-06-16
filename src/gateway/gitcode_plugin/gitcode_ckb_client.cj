package metis.gateway.gitcode_plugin

import std.collection.ArrayList
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.net.http.*

public const GITCODE_CKB_EVIDENCE_PACK_CAPABILITY: String = "cangjie.evidence_pack"
public const GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY: String = "cangjie.source_analysis"

public class GitCodeCkbDiagnostic {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let degraded: Bool

    public init(code: String, message: String, retryable!: Bool = false, degraded!: Bool = false) {
        this.code = code.trimAscii()
        this.message = gitCodeReviewRedactSensitiveText(message.trimAscii())
        this.retryable = retryable
        this.degraded = degraded
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.put("code", JsonString(this.code))
        obj.put("message", JsonString(this.message))
        obj.put("retryable", JsonBool(this.retryable))
        obj.put("degraded", JsonBool(this.degraded))
        obj
    }
}

public class GitCodeCkbClientResult {
    public let ok: Bool
    public let status: String
    public let capabilityId: String
    public let payload: JsonObject
    public let retryable: Bool
    public let degraded: Bool
    public let diagnostics: Array<GitCodeCkbDiagnostic>

    public init(
        ok: Bool,
        status: String,
        capabilityId!: String = "",
        payload!: JsonObject = JsonObject(),
        retryable!: Bool = false,
        degraded!: Bool = false,
        diagnostics!: Array<GitCodeCkbDiagnostic> = []
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.payload = payload
        this.retryable = retryable
        this.degraded = degraded
        this.diagnostics = diagnostics
    }
}

public class GitCodeCkbHttpRequest {
    public let method: String
    public let path: String
    public let url: String
    public let body: String
    public let timeoutMs: Int64

    public init(method: String, path: String, url: String, body: String, timeoutMs: Int64) {
        this.method = method.trimAscii()
        this.path = path.trimAscii()
        this.url = url.trimAscii()
        this.body = gitCodeReviewRedactSensitiveText(body.trimAscii())
        this.timeoutMs = timeoutMs
    }
}

public class GitCodeCkbHttpResponse {
    public let statusCode: Int64
    public let body: String
    public let error: String

    public init(statusCode: Int64, body!: String = "", error!: String = "") {
        this.statusCode = statusCode
        this.body = gitCodeReviewRedactSensitiveText(body.trimAscii())
        this.error = gitCodeReviewRedactSensitiveText(error.trimAscii())
    }
}

public class GitCodeCkbResolvedContext {
    public let ckbEvidence: JsonObject
    public let sourceContext: JsonObject
    public let degraded: Bool
    public let needsHumanReview: Bool

    public init(
        ckbEvidence: JsonObject,
        sourceContext: JsonObject,
        degraded!: Bool = false,
        needsHumanReview!: Bool = false
    ) {
        this.ckbEvidence = ckbEvidence
        this.sourceContext = sourceContext
        this.degraded = degraded
        this.needsHumanReview = needsHumanReview
    }
}

private var gitCodeCkbClientRunnerForTest: Option<(String, JsonObject) -> GitCodeCkbClientResult> =
    None<(String, JsonObject) -> GitCodeCkbClientResult>

private var gitCodeCkbHttpRunnerForTest: Option<(GitCodeCkbHttpRequest) -> GitCodeCkbHttpResponse> =
    None<(GitCodeCkbHttpRequest) -> GitCodeCkbHttpResponse>

public func setGitCodeCkbClientRunnerForTest(runner: Option<(String, JsonObject) -> GitCodeCkbClientResult>): Unit {
    gitCodeCkbClientRunnerForTest = runner
}

public func setGitCodeCkbHttpRunnerForTest(runner: Option<(GitCodeCkbHttpRequest) -> GitCodeCkbHttpResponse>): Unit {
    gitCodeCkbHttpRunnerForTest = runner
}

private func ckbInvoke(capabilityId: String, request: JsonObject): GitCodeCkbClientResult {
    match (gitCodeCkbClientRunnerForTest) {
        case Some(runner) =>
            let result = runner(capabilityId, request)
            if (result.ok) {
                return GitCodeCkbClientResult(true, "resolved", capabilityId: capabilityId, payload: result.payload, diagnostics: result.diagnostics)
            }
            let status = match (result.status) {
                case "timeout" => "ckb_timeout"
                case "capability_missing" => "ckb_capability_missing"
                case "disabled" => "source_analysis_disabled"
                case _ => "ckb_unavailable"
            }
            GitCodeCkbClientResult(false, status, capabilityId: capabilityId, retryable: status == "ckb_timeout", degraded: true, diagnostics: [
                GitCodeCkbDiagnostic(status, "CKB capability ${capabilityId} returned ${result.status}", retryable: status == "ckb_timeout", degraded: true)
            ])
        case None =>
            GitCodeCkbClientResult(false, "ckb_unavailable", capabilityId: capabilityId, degraded: true, diagnostics: [
                GitCodeCkbDiagnostic("ckb_unavailable", "CKB client runner is not configured.", degraded: true)
            ])
    }
}

public func queryCkbEvidencePack(q: String, budget!: Int64 = 5, includeCandidates!: Bool = false, parentUrl!: String = ""): GitCodeCkbClientResult {
    let request = JsonObject()
    request.put("q", JsonString(gitCodeReviewRedactSensitiveText(q)))
    request.put("budget", JsonInt(budget))
    request.put("includeCandidates", JsonBool(includeCandidates))
    if (!parentUrl.trimAscii().isEmpty()) {
        request.put("parentUrl", JsonString(parentUrl.trimAscii()))
    }
    ckbInvoke(GITCODE_CKB_EVIDENCE_PACK_CAPABILITY, request)
}

private func ckbReadAllBytes(response: HttpResponse): Array<Byte> {
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

private func ckbEndpointUrl(endpoint: String, path: String): String {
    let base = endpoint.trimAscii()
    if (base.endsWith("/")) {
        base[..base.size - 1] + path
    } else {
        base + path
    }
}

private func ckbNativePost(request: GitCodeCkbHttpRequest): GitCodeCkbHttpResponse {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * request.timeoutMs)
    let client = builder.build()
    try {
        let reqBuilder = HttpRequestBuilder().url(request.url).post().body(request.body)
        reqBuilder.header("Content-Type", "application/json")
        reqBuilder.header("Accept", "application/json")
        let response = client.send(reqBuilder.build())
        let body = try { String.fromUtf8(ckbReadAllBytes(response)) } catch (_: Exception) { "" }
        GitCodeCkbHttpResponse(Int64(response.status), body: body)
    } catch (e: Exception) {
        GitCodeCkbHttpResponse(0, error: e.message)
    } finally {
        client.close()
    }
}

public class GitCodeCkbHttpClient {
    public let config: GitCodeCkbServiceConfig

    public init(config: GitCodeCkbServiceConfig) {
        this.config = config
    }

    public func post(path: String, body: JsonObject): GitCodeCkbHttpResponse {
        if (path != "/v1/evidence-pack" && path != "/v1/source-analysis") {
            return GitCodeCkbHttpResponse(0, error: "ckb path is not allowed")
        }
        let request = GitCodeCkbHttpRequest("POST", path, ckbEndpointUrl(this.config.endpoint, path), body.toJsonString(), this.config.timeoutMs)
        match (gitCodeCkbHttpRunnerForTest) {
            case Some(runner) => runner(request)
            case None => ckbNativePost(request)
        }
    }
}

private func ckbObjectString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func ckbVisibilityPrivate(obj: JsonObject): Bool {
    let visibility = ckbObjectString(obj, "visibility").toAsciiLower()
    visibility == "private" || visibility == "internal"
}

private func ckbSanitizedObject(obj: JsonObject): JsonObject {
    try { JsonValue.fromStr(gitCodeReviewRedactSensitiveText(obj.toJsonString())).asObject() } catch (_: Exception) { JsonObject() }
}

private func ckbFilterTrustedArray(value: JsonValue): JsonArray {
    let out = JsonArray([])
    let arr = try { value.asArray() } catch (_: Exception) { return out }
    for (item in arr.getItems()) {
        try {
            let itemObj = item.asObject()
            if (!ckbVisibilityPrivate(itemObj)) {
                out.add(ckbSanitizedObject(itemObj))
            }
        } catch (_: Exception) { () }
    }
    out
}

private func ckbTrustedPayload(payload: JsonObject, capabilityId: String): GitCodeCkbClientResult {
    if (ckbVisibilityPrivate(payload)) {
        return GitCodeCkbClientResult(false, "private_or_internal_visibility", capabilityId: capabilityId, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("private_or_internal_visibility", "CKB returned private/internal visibility data.", degraded: true)
        ])
    }
    let safe = ckbSanitizedObject(payload)
    var privateFiltered = false
    match (payload.get("items")) {
        case Some(itemsValue) =>
            let filtered = ckbFilterTrustedArray(itemsValue)
            privateFiltered = filtered.size() != (try { itemsValue.asArray().size() } catch (_: Exception) { filtered.size() })
            safe.put("items", filtered)
        case None => ()
    }
    match (payload.get("candidates")) {
        case Some(candidatesValue) =>
            let filtered = ckbFilterTrustedArray(candidatesValue)
            privateFiltered = privateFiltered || filtered.size() != (try { candidatesValue.asArray().size() } catch (_: Exception) { filtered.size() })
            safe.put("candidates", filtered)
        case None => ()
    }
    if (privateFiltered && (try { safe.get("items").getOrThrow().asArray().size() } catch (_: Exception) { 1 }) == 0) {
        return GitCodeCkbClientResult(false, "private_or_internal_visibility", capabilityId: capabilityId, payload: safe, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("private_or_internal_visibility", "CKB returned only private/internal visibility data.", degraded: true)
        ])
    }
    GitCodeCkbClientResult(true, "resolved", capabilityId: capabilityId, payload: safe)
}

public func parseCkbEnvelope(response: GitCodeCkbHttpResponse, capabilityId: String): GitCodeCkbClientResult {
    if (response.statusCode == 0) {
        let isTimeout = response.error.toAsciiLower().contains("timeout")
        let status = if (isTimeout) { "ckb_timeout" } else { "ckb_unavailable" }
        return GitCodeCkbClientResult(false, status, capabilityId: capabilityId, retryable: isTimeout, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic(status, if (response.error.isEmpty()) { "CKB HTTP request failed." } else { response.error }, retryable: isTimeout, degraded: true)
        ])
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
        return GitCodeCkbClientResult(false, "ckb_unavailable", capabilityId: capabilityId, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("ckb_unavailable", "CKB HTTP service returned status ${response.statusCode}.", degraded: true)
        ])
    }
    let root = try { JsonValue.fromStr(response.body).asObject() } catch (_: Exception) {
        return GitCodeCkbClientResult(false, "ckb_malformed", capabilityId: capabilityId, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("ckb_malformed", "CKB HTTP response envelope is malformed.", degraded: true)
        ])
    }
    let ok = try { root.get("ok").getOrThrow().asBool().getValue() } catch (_: Exception) { false }
    if (!ok) {
        let message = try { root.get("error").getOrThrow().asObject().get("message").getOrThrow().asString().getValue() } catch (_: Exception) { "CKB HTTP response ok=false." }
        return GitCodeCkbClientResult(false, "ckb_unavailable", capabilityId: capabilityId, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("ckb_unavailable", message, degraded: true)
        ])
    }
    let result = try { root.get("result").getOrThrow().asObject() } catch (_: Exception) {
        return GitCodeCkbClientResult(false, "ckb_malformed", capabilityId: capabilityId, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("ckb_malformed", "CKB HTTP response result is malformed.", degraded: true)
        ])
    }
    ckbTrustedPayload(result, capabilityId)
}

private func ckbBudget(config: GitCodeCkbServiceConfig, budget: Int64): Int64 {
    let requested = if (budget > 0) { budget } else { config.defaultBudget }
    min(max(requested, 1), config.maxBudget)
}

public func queryEvidencePack(
    config: GitCodeCkbServiceConfig,
    q: String,
    budget!: Int64 = 0,
    includeCandidates!: Bool = false,
    parentUrl!: String = ""
): GitCodeCkbClientResult {
    if (!config.enabled) {
        return GitCodeCkbClientResult(false, "ckb_disabled", capabilityId: GITCODE_CKB_EVIDENCE_PACK_CAPABILITY)
    }
    let body = JsonObject()
    body.put("q", JsonString(gitCodeReviewRedactSensitiveText(q)))
    body.put("budget", JsonInt(ckbBudget(config, budget)))
    body.put("includeCandidates", JsonBool(includeCandidates))
    if (!parentUrl.trimAscii().isEmpty()) {
        body.put("parentUrl", JsonString(parentUrl.trimAscii()))
    }
    parseCkbEnvelope(GitCodeCkbHttpClient(config).post("/v1/evidence-pack", body), GITCODE_CKB_EVIDENCE_PACK_CAPABILITY)
}

public func querySourceAnalysis(
    config: GitCodeCkbServiceConfig,
    repo: String,
    ref: String,
    changedFiles: Array<String>
): GitCodeCkbClientResult {
    if (!config.enabled) {
        return GitCodeCkbClientResult(false, "ckb_disabled", capabilityId: GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY)
    }
    let body = JsonObject()
    body.put("repo", JsonString(repo.trimAscii()))
    body.put("ref", JsonString(resolveSourceRef(ref)))
    body.put("changedFiles", gitCodeReviewJsonArrayString(changedFiles))
    parseCkbEnvelope(GitCodeCkbHttpClient(config).post("/v1/source-analysis", body), GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY)
}

public func queryCkbSourceAnalysis(repo: String, ref: String, query: String, requiresSourceAnalysis!: Bool, sourceAvailable!: Bool): GitCodeCkbClientResult {
    if (!requiresSourceAnalysis) {
        return GitCodeCkbClientResult(false, "source_analysis_disabled", capabilityId: GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("source_analysis_disabled", "Task policy does not require source analysis.", degraded: true)
        ])
    }
    if (!sourceAvailable) {
        return GitCodeCkbClientResult(false, "source_analysis_disabled", capabilityId: GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY, degraded: true, diagnostics: [
            GitCodeCkbDiagnostic("source_analysis_disabled", "Source context is unavailable for source analysis.", degraded: true)
        ])
    }
    let request = JsonObject()
    request.put("repo", JsonString(repo.trimAscii()))
    request.put("ref", JsonString(resolveSourceRef(ref)))
    request.put("query", JsonString(gitCodeReviewRedactSensitiveText(query)))
    ckbInvoke(GITCODE_CKB_SOURCE_ANALYSIS_CAPABILITY, request)
}

public func renderCkbDiagnostics(diagnostics: Array<GitCodeCkbDiagnostic>): String {
    let lines = ArrayList<String>()
    for (diag in diagnostics) {
        lines.add("${diag.code}: ${diag.message}")
    }
    gitCodeReviewRedactSensitiveText(String.join(lines.toArray(), delimiter: "\n"))
}

public func gitCodeCkbResultToContext(result: GitCodeCkbClientResult): JsonObject {
    let out = JsonObject()
    out.put("status", JsonString(result.status))
    out.put("capabilityId", JsonString(result.capabilityId))
    out.put("degraded", JsonBool(result.degraded))
    let diags = JsonArray([])
    for (diag in result.diagnostics) {
        diags.add(diag.toJson())
    }
    out.put("diagnostics", diags)
    match (result.payload.get("items")) {
        case Some(v) => out.put("items", v)
        case None => out.put("items", JsonArray([]))
    }
    match (result.payload.get("knowledgeVersion")) {
        case Some(v) => out.put("knowledgeVersion", v)
        case None => ()
    }
    match (result.payload.get("citations")) {
        case Some(v) => out.put("citations", v)
        case None => ()
    }
    match (result.payload.get("candidates")) {
        case Some(v) => out.put("candidates", v)
        case None => ()
    }
    match (result.payload.get("summary")) {
        case Some(v) => out.put("summary", v)
        case None => ()
    }
    match (result.payload.get("analysis")) {
        case Some(v) => out.put("analysis", v)
        case None => ()
    }
    out
}

private func ckbUnavailableContext(status: String, diagnostic: String): JsonObject {
    let out = JsonObject()
    out.put("status", JsonString(status))
    out.put("degraded", JsonBool(true))
    out.put("diagnostic", JsonString(gitCodeReviewRedactSensitiveText(diagnostic)))
    out
}

private func ckbNotRequiredContext(): JsonObject {
    let out = JsonObject()
    out.put("status", JsonString("not_required"))
    out.put("degraded", JsonBool(false))
    out
}

private func ckbEvidenceInsufficient(context: JsonObject): Bool {
    let status = ckbObjectString(context, "status")
    if (status != "resolved") {
        return true
    }
    let itemCount = try { context.get("items").getOrThrow().asArray().size() } catch (_: Exception) { 0 }
    itemCount == 0
}

private func ckbSourceRefForRequest(request: GitCodeReviewRequest): String {
    if (request.branchVersions.size > 0 && !request.branchVersions[0].trimAscii().isEmpty()) {
        request.branchVersions[0]
    } else {
        "main"
    }
}

public func resolveGitCodeCkbContextForRequest(
    request: GitCodeReviewRequest,
    config: GitCodeReviewRuntimeConfig
): GitCodeCkbResolvedContext {
    var ckbContext = ckbNotRequiredContext()
    var sourceContext = ckbNotRequiredContext()
    var degraded = false
    var needsHumanReview = false

    if (request.requiresCkb) {
        let q = "${request.title}\n${request.content}\n${request.commentBody}".trimAscii()
        let evidence = queryEvidencePack(
            config.ckbService,
            q,
            budget: config.ckbService.defaultBudget,
            includeCandidates: config.ckbService.includeCandidates,
            parentUrl: request.parentUrl
        )
        ckbContext = gitCodeCkbResultToContext(evidence)
        degraded = degraded || evidence.degraded || !evidence.ok
        needsHumanReview = needsHumanReview || !evidence.ok
    }

    let shouldQuerySource =
        config.ckbService.sourceAnalysisEnabled &&
        (request.requiresSourceWorkspace || (request.requiresCkb && ckbEvidenceInsufficient(ckbContext)))
    if (shouldQuerySource) {
        let source = querySourceAnalysis(config.ckbService, request.repoFullName, ckbSourceRefForRequest(request), request.changedFiles)
        sourceContext = gitCodeCkbResultToContext(source)
        degraded = degraded || source.degraded || !source.ok
        needsHumanReview = needsHumanReview || (request.requiresSourceWorkspace && !source.ok)
    } else if (request.requiresSourceWorkspace) {
        sourceContext = ckbUnavailableContext("source_analysis_disabled", "CKB source analysis is disabled.")
        degraded = true
        needsHumanReview = true
    }

    GitCodeCkbResolvedContext(ckbContext, sourceContext, degraded: degraded, needsHumanReview: needsHumanReview)
}
