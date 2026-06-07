package metis.gateway.gitcode_plugin

import std.collection.ArrayList
import std.env.getVariable
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.net.http.*
import stdx.net.tls.*
import std.time.*

public class ChangedFileV1 {
    public let path: String
    public let status: String
    public let additions: Int64
    public let deletions: Int64
    public let patchSummary: String
    public let diffHunks: Array<String>
    public let truncated: Bool

    public init(path: String, status!: String = "", additions!: Int64 = 0, deletions!: Int64 = 0, patchSummary!: String = "", diffHunks!: Array<String> = [], truncated!: Bool = false) {
        this.path = path.trimAscii()
        this.status = status.trimAscii()
        this.additions = additions
        this.deletions = deletions
        this.patchSummary = gitCodeReviewRedactSensitiveText(patchSummary.trimAscii())
        this.diffHunks = diffHunks
        this.truncated = truncated
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.put("path", JsonString(this.path))
        obj.put("status", JsonString(this.status))
        obj.put("additions", JsonInt(this.additions))
        obj.put("deletions", JsonInt(this.deletions))
        obj.put("patchSummary", JsonString(this.patchSummary))
        obj.put("diffHunks", gitCodeReviewJsonArrayString(this.diffHunks))
        obj.put("truncated", JsonBool(this.truncated))
        obj
    }
}

public class PrReviewAdapterRequestV1 {
    public let schemaVersion: Int64
    public let requestId: String
    public let eventId: String
    public let repo: JsonObject
    public let pr: JsonObject
    public let changedFiles: Array<ChangedFileV1>
    public let sourceContext: JsonObject
    public let ckbContext: JsonObject
    public let limits: JsonObject
    public let diagnostics: Array<String>

    public init(
        requestId: String,
        eventId: String,
        repo: JsonObject,
        pr: JsonObject,
        changedFiles: Array<ChangedFileV1>,
        sourceContext: JsonObject,
        ckbContext: JsonObject,
        limits: JsonObject,
        diagnostics!: Array<String> = []
    ) {
        this.schemaVersion = 1
        this.requestId = requestId.trimAscii()
        this.eventId = eventId.trimAscii()
        this.repo = repo
        this.pr = pr
        this.changedFiles = changedFiles
        this.sourceContext = sourceContext
        this.ckbContext = ckbContext
        this.limits = limits
        this.diagnostics = diagnostics
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("schemaVersion", JsonInt(this.schemaVersion))
        out.put("requestId", JsonString(this.requestId))
        out.put("eventId", JsonString(this.eventId))
        out.put("repo", this.repo)
        out.put("pr", this.pr)
        let files = JsonArray([])
        for (file in this.changedFiles) {
            files.add(file.toJson())
        }
        out.put("changedFiles", files)
        out.put("sourceContext", this.sourceContext)
        out.put("ckbContext", this.ckbContext)
        out.put("limits", this.limits)
        out.put("diagnostics", gitCodeReviewJsonArrayString(this.diagnostics))
        out
    }
}

public class ReviewFindingV1 {
    public let findingId: String
    public let severity: String
    public let category: String
    public let path: String
    public let line: Int64
    public let endLine: Int64
    public let title: String
    public let detail: String
    public let evidence: String
    public let recommendation: String
    public let confidence: String
    public let truncated: Bool
    public let diagnostics: Array<String>

    public init(
        findingId: String,
        severity: String,
        category: String,
        path: String,
        line!: Int64 = 0,
        endLine!: Int64 = 0,
        title!: String = "",
        detail!: String = "",
        evidence!: String = "",
        recommendation!: String = "",
        confidence!: String = "medium",
        truncated!: Bool = false,
        diagnostics!: Array<String> = []
    ) {
        this.findingId = findingId.trimAscii()
        this.severity = severity.trimAscii()
        this.category = category.trimAscii()
        this.path = path.trimAscii()
        this.line = line
        this.endLine = endLine
        this.title = gitCodeReviewRedactSensitiveText(title.trimAscii())
        this.detail = gitCodeReviewRedactSensitiveText(detail.trimAscii())
        this.evidence = gitCodeReviewRedactSensitiveText(evidence.trimAscii())
        this.recommendation = gitCodeReviewRedactSensitiveText(recommendation.trimAscii())
        this.confidence = confidence.trimAscii()
        this.truncated = truncated
        this.diagnostics = diagnostics
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("findingId", JsonString(this.findingId))
        out.put("severity", JsonString(this.severity))
        out.put("category", JsonString(this.category))
        out.put("path", JsonString(this.path))
        if (this.line > 0) { out.put("line", JsonInt(this.line)) }
        if (this.endLine > 0) { out.put("endLine", JsonInt(this.endLine)) }
        out.put("title", JsonString(this.title))
        out.put("detail", JsonString(this.detail))
        out.put("evidence", JsonString(this.evidence))
        out.put("recommendation", JsonString(this.recommendation))
        out.put("confidence", JsonString(this.confidence))
        out.put("truncated", JsonBool(this.truncated))
        out.put("diagnostics", gitCodeReviewJsonArrayString(this.diagnostics))
        out
    }
}

public class PrReviewAdapterResponseV1 {
    public let schemaVersion: Int64
    public let requestId: String
    public let adapterMode: String
    public let engineId: String
    public let status: String
    public let summary: String
    public let findings: Array<ReviewFindingV1>
    public let elapsedMs: Int64
    public let truncated: Bool
    public let retryable: Bool
    public let degraded: Bool
    public let needsHumanReview: Bool
    public let diagnostics: Array<String>

    public init(
        status: String,
        requestId!: String = "",
        adapterMode!: String = "",
        engineId!: String = "",
        summary!: String = "",
        findings!: Array<ReviewFindingV1> = [],
        elapsedMs!: Int64 = 0,
        truncated!: Bool = false,
        retryable!: Bool = false,
        degraded!: Bool = false,
        needsHumanReview!: Bool = false,
        diagnostics!: Array<String> = []
    ) {
        this.schemaVersion = 1
        this.requestId = requestId.trimAscii()
        this.adapterMode = adapterMode.trimAscii()
        this.engineId = engineId.trimAscii()
        this.status = status.trimAscii()
        this.summary = gitCodeReviewRedactSensitiveText(summary.trimAscii())
        this.findings = findings
        this.elapsedMs = elapsedMs
        this.truncated = truncated
        this.retryable = retryable
        this.degraded = degraded
        this.needsHumanReview = needsHumanReview
        this.diagnostics = diagnostics
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("schemaVersion", JsonInt(1))
        out.put("requestId", JsonString(this.requestId))
        out.put("adapterMode", JsonString(this.adapterMode))
        out.put("engineId", JsonString(this.engineId))
        out.put("status", JsonString(this.status))
        out.put("summary", JsonString(this.summary))
        let arr = JsonArray([])
        for (finding in this.findings) {
            arr.add(finding.toJson())
        }
        out.put("findings", arr)
        out.put("elapsedMs", JsonInt(this.elapsedMs))
        out.put("truncated", JsonBool(this.truncated))
        out.put("retryable", JsonBool(this.retryable))
        out.put("degraded", JsonBool(this.degraded))
        out.put("needsHumanReview", JsonBool(this.needsHumanReview))
        out.put("diagnostics", gitCodeReviewJsonArrayString(this.diagnostics))
        out
    }
}

public class GitCodePrReviewHttpResult {
    public let statusCode: Int64
    public let body: String
    public let error: String

    public init(statusCode: Int64, body!: String = "", error!: String = "") {
        this.statusCode = statusCode
        this.body = body
        this.error = gitCodeReviewRedactSensitiveText(error.trimAscii())
    }
}

private var gitCodePrReviewAdapterHttpRunnerForTest: Option<(JsonObject) -> GitCodePrReviewHttpResult> =
    None<(JsonObject) -> GitCodePrReviewHttpResult>

public func setGitCodePrReviewAdapterHttpRunnerForTest(runner: Option<(JsonObject) -> GitCodePrReviewHttpResult>): Unit {
    gitCodePrReviewAdapterHttpRunnerForTest = runner
}

private func prObj(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func prStr(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func prInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func prArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func prCloneStringObject(input: JsonObject, keys: Array<String>, diagnostics: ArrayList<String>): JsonObject {
    let out = JsonObject()
    for (key in keys) {
        let value = gitCodeReviewRedactSensitiveText(prStr(input, key))
        if (value != prStr(input, key)) { diagnostics.add("secret_redacted") }
        out.put(key, JsonString(value))
    }
    out
}

public func buildPrReviewRequest(request: JsonObject, sourceContext: JsonObject, ckbContext: JsonObject): PrReviewAdapterRequestV1 {
    let diagnostics = ArrayList<String>()
    let eventId = prStr(request, "eventId")
    let rawRepo = prObj(request, "repo")
    let rawPr = prObj(request, "pr")
    let repo = prCloneStringObject(rawRepo, ["fullName", "webUrl", "defaultBranch", "targetBranch", "sourceBranch", "diffRef"], diagnostics)
    let pr = prCloneStringObject(rawPr, ["number", "title", "url", "authorLogin", "templateLanguage", "buildSelfCheck", "testSelfCheck"], diagnostics)
    let changeTypes = prArray(rawPr, "changeTypes")
    pr.put("changeTypes", changeTypes)
    let selfCheck = JsonObject()
    selfCheck.put("build", JsonString(gitCodeReviewRedactSensitiveText(prStr(rawPr, "buildSelfCheck"))))
    selfCheck.put("test", JsonString(gitCodeReviewRedactSensitiveText(prStr(rawPr, "testSelfCheck"))))
    pr.put("selfCheck", selfCheck)

    let changed = ArrayList<ChangedFileV1>()
    for (item in prArray(request, "changedFiles").getItems()) {
        let f = try { item.asObject() } catch (_: Exception) { continue }
        let path = prStr(f, "path")
        if (!gitCodeReviewIsRepoRelativePath(path)) {
            diagnostics.add("path_invalid")
            continue
        }
        let hunks = ArrayList<String>()
        for (h in prArray(f, "diffHunks").getItems()) {
            try { hunks.add(gitCodeReviewRedactSensitiveText(h.asString().getValue())) } catch (_: Exception) { () }
        }
        changed.add(ChangedFileV1(
            path,
            status: prStr(f, "status"),
            additions: prInt(f, "additions"),
            deletions: prInt(f, "deletions"),
            patchSummary: prStr(f, "patchSummary"),
            diffHunks: hunks.toArray(),
            truncated: false
        ))
    }

    let limits = JsonObject()
    limits.put("maxFindings", JsonInt(20))
    limits.put("maxFindingChars", JsonInt(2000))
    limits.put("timeoutMs", JsonInt(15000))
    let requestId = "pr-review:${eventId}"
    PrReviewAdapterRequestV1(requestId, eventId, repo, pr, changed.toArray(), sanitizePrReviewContext(sourceContext, diagnostics), sanitizePrReviewContext(ckbContext, diagnostics), limits, diagnostics: diagnostics.toArray())
}

private func sanitizePrReviewContext(ctx: JsonObject, diagnostics: ArrayList<String>): JsonObject {
    let raw = ctx.toJsonString()
    let safe = gitCodeReviewRedactSensitiveText(raw)
    if (safe != raw) { diagnostics.add("secret_redacted") }
    try { JsonValue.fromStr(safe).asObject() } catch (_: Exception) { JsonObject() }
}

private func allowedSeverity(value: String): String {
    match (value) {
        case "critical" | "high" | "medium" | "low" | "info" => value
        case _ => "info"
    }
}

private func allowedCategory(value: String): String {
    match (value) {
        case "correctness" | "compatibility" | "architecture" | "security" | "test_coverage" | "performance" | "docs" | "style" | "unknown" => value
        case _ => "unknown"
    }
}

private func allowedConfidence(value: String): String {
    match (value) {
        case "high" | "medium" | "low" => value
        case _ => "low"
    }
}

private func truncateFindingText(text: String, maxChars: Int64, truncated: ArrayList<String>): String {
    let safe = gitCodeReviewRedactSensitiveText(text)
    if (Int64(safe.size) <= maxChars) { return safe }
    truncated.add("finding_truncated")
    safe[..maxChars]
}

public func normalizeReviewFinding(finding: ReviewFindingV1, maxFindingChars!: Int64 = 2000): ReviewFindingV1 {
    let diagnostics = ArrayList<String>()
    var path = finding.path
    if (!path.isEmpty() && !gitCodeReviewIsRepoRelativePath(path)) {
        path = ""
        diagnostics.add("finding_path_invalid")
    }
    var line = finding.line
    var endLine = finding.endLine
    if (line < 1) {
        line = 0
        if (finding.line != 0) { diagnostics.add("finding_line_invalid") }
    }
    if (endLine > 0 && line > 0 && endLine < line) {
        endLine = 0
        diagnostics.add("finding_end_line_invalid")
    }
    let trunc = ArrayList<String>()
    let title = truncateFindingText(finding.title, 240, trunc)
    let detail = truncateFindingText(finding.detail, maxFindingChars, trunc)
    let evidence = truncateFindingText(finding.evidence, maxFindingChars, trunc)
    let recommendation = truncateFindingText(finding.recommendation, maxFindingChars, trunc)
    for (d in finding.diagnostics) { diagnostics.add(d) }
    for (d in trunc) { diagnostics.add(d) }
    ReviewFindingV1(
        if (finding.findingId.isEmpty()) { "finding-generated" } else { finding.findingId },
        allowedSeverity(finding.severity),
        allowedCategory(finding.category),
        path,
        line: line,
        endLine: endLine,
        title: title,
        detail: detail,
        evidence: evidence,
        recommendation: recommendation,
        confidence: allowedConfidence(finding.confidence),
        truncated: finding.truncated || trunc.size > 0,
        diagnostics: diagnostics.toArray()
    )
}

private func findingFromJson(obj: JsonObject, index: Int64, requestId: String): ReviewFindingV1 {
    normalizeReviewFinding(ReviewFindingV1(
        if (prStr(obj, "findingId").isEmpty()) { "${requestId}:finding:${index}" } else { prStr(obj, "findingId") },
        prStr(obj, "severity"),
        prStr(obj, "category"),
        prStr(obj, "path"),
        line: prInt(obj, "line"),
        endLine: prInt(obj, "endLine"),
        title: prStr(obj, "title"),
        detail: prStr(obj, "detail"),
        evidence: prStr(obj, "evidence"),
        recommendation: prStr(obj, "recommendation"),
        confidence: prStr(obj, "confidence"),
        truncated: false
    ))
}

public func parsePrReviewAdapterResponse(responseText: String, requestId!: String = "", adapterMode!: String = "external"): PrReviewAdapterResponseV1 {
    let raw = responseText.trimAscii()
    if (!(raw.startsWith("{") && raw.endsWith("}"))) {
        return PrReviewAdapterResponseV1("decode_failed", requestId: requestId, adapterMode: adapterMode, degraded: true, needsHumanReview: true, diagnostics: ["decode_failed"])
    }
    let obj = try { JsonValue.fromStr(raw).asObject() } catch (_: Exception) {
        return PrReviewAdapterResponseV1("decode_failed", requestId: requestId, adapterMode: adapterMode, degraded: true, needsHumanReview: true, diagnostics: ["decode_failed"])
    }
    if (prInt(obj, "schemaVersion") != 1) {
        return PrReviewAdapterResponseV1("malformed", requestId: requestId, adapterMode: adapterMode, degraded: true, needsHumanReview: true, diagnostics: ["adapter_contract_version_unsupported"])
    }
    let status = prStr(obj, "status")
    if (status.isEmpty()) {
        return PrReviewAdapterResponseV1("malformed", requestId: requestId, adapterMode: adapterMode, degraded: true, needsHumanReview: true, diagnostics: ["status_missing"])
    }
    let findings = ArrayList<ReviewFindingV1>()
    var index: Int64 = 0
    for (item in prArray(obj, "findings").getItems()) {
        let f = try { item.asObject() } catch (_: Exception) {
            return PrReviewAdapterResponseV1("malformed", requestId: requestId, adapterMode: adapterMode, degraded: true, needsHumanReview: true, diagnostics: ["findings_malformed"])
        }
        findings.add(findingFromJson(f, index, requestId))
        index += 1
    }
    let degraded = status != "resolved" && status != "no_findings"
    PrReviewAdapterResponseV1(
        status,
        requestId: if (prStr(obj, "requestId").isEmpty()) { requestId } else { prStr(obj, "requestId") },
        adapterMode: if (prStr(obj, "adapterMode").isEmpty()) { adapterMode } else { prStr(obj, "adapterMode") },
        engineId: prStr(obj, "engineId"),
        summary: prStr(obj, "summary"),
        findings: findings.toArray(),
        elapsedMs: prInt(obj, "elapsedMs"),
        truncated: try { obj.get("truncated").getOrThrow().asBool().getValue() } catch (_: Exception) { false },
        retryable: status == "timeout" || status == "unavailable",
        degraded: degraded,
        needsHumanReview: degraded,
        diagnostics: []
    )
}

public func invokeMockPrReviewAdapterForTest(request: PrReviewAdapterRequestV1, scenario: String): PrReviewAdapterResponseV1 {
    match (scenario) {
        case "success_no_findings" =>
            PrReviewAdapterResponseV1("no_findings", requestId: request.requestId, adapterMode: "mock", engineId: "mock-pr-review-adapter-v1", summary: "Mock review found no clear issues.")
        case "timeout" =>
            PrReviewAdapterResponseV1("timeout", requestId: request.requestId, adapterMode: "mock", engineId: "mock-pr-review-adapter-v1", summary: "Mock timeout.", retryable: true, degraded: true, needsHumanReview: true, diagnostics: ["adapter_timeout"])
        case "unavailable" =>
            PrReviewAdapterResponseV1("unavailable", requestId: request.requestId, adapterMode: "mock", engineId: "mock-pr-review-adapter-v1", summary: "Mock unavailable.", retryable: true, degraded: true, needsHumanReview: true, diagnostics: ["adapter_unavailable"])
        case "secret_in_finding" =>
            PrReviewAdapterResponseV1("resolved", requestId: request.requestId, adapterMode: "mock", engineId: "mock-pr-review-adapter-v1", summary: "Mock finding redacted.", findings: [
                normalizeReviewFinding(ReviewFindingV1("mock-secret", "medium", "security", "src/example.cj", line: 7, title: "Secret", detail: "Authorization: Bearer review-secret", recommendation: "Remove secret."))
            ])
        case "oversized_findings" =>
            PrReviewAdapterResponseV1("resolved", requestId: request.requestId, adapterMode: "mock", engineId: "mock-pr-review-adapter-v1", summary: "Mock oversized finding.", findings: [
                normalizeReviewFinding(ReviewFindingV1("mock-big", "medium", "correctness", "src/example.cj", line: 7, title: "Large", detail: gitCodeReviewRepeat("x", 6000), recommendation: "Trim."), maxFindingChars: 1000)
            ], truncated: true)
        case _ =>
            PrReviewAdapterResponseV1("resolved", requestId: request.requestId, adapterMode: "mock", engineId: "mock-pr-review-adapter-v1", summary: "Mock review found one potential issue.", findings: [
                normalizeReviewFinding(ReviewFindingV1("mock-finding-1", "medium", "correctness", "src/example.cj", line: 42, endLine: 44, title: "参数为空时可能走错分支", detail: "当 args 为空时，当前分支可能跳过默认值处理。", evidence: "changedFiles includes src/example.cj", recommendation: "建议补充空参数数组的单元测试。", confidence: "medium"))
            ])
    }
}

private func adapterEndpointPath(endpoint: String): String {
    let raw = endpoint.trimAscii()
    let withoutScheme = if (raw.startsWith("http://")) { raw["http://".size..] } else if (raw.startsWith("https://")) { raw["https://".size..] } else { raw }
    match (withoutScheme.indexOf("/")) {
        case Some(slash) => withoutScheme[slash..]
        case None => "/"
    }
}

private func adapterNativeHttpPost(config: GitCodePrReviewAdapterConfig, request: PrReviewAdapterRequestV1): GitCodePrReviewHttpResult {
    try {
        let builder = ClientBuilder()
        builder.readTimeout(Duration.millisecond * config.timeoutMs)
        if (config.endpoint.startsWith("https://")) {
            var tlsConfig = TlsClientConfig()
            tlsConfig.domain = config.endpoint
            tlsConfig.alpnProtocolsList = ["http/1.1"]
            builder.tlsConfig(tlsConfig)
        }
        let client = builder.build()
        try {
            let req = HttpRequestBuilder().url(config.endpoint).post().body(request.toJson().toJsonString())
            req.header("Content-Type", "application/json")
            req.header("Accept", "application/json")
            if (!config.authHeaderEnv.isEmpty()) {
                let secret = getVariable(config.authHeaderEnv) ?? ""
                if (!secret.trimAscii().isEmpty()) {
                    req.header("Authorization", secret)
                }
            }
            let response = client.send(req.build())
            var body = ""
            try {
                let bytes = ArrayList<Byte>()
                let stream = response.body
                let buffer = Array<Byte>(4096, repeat: 0)
                var n = stream.read(buffer)
                while (n > 0) {
                    bytes.add(all: buffer[..n])
                    n = stream.read(buffer)
                }
                body = String.fromUtf8(bytes.toArray())
            } catch (_: Exception) { body = "" }
            GitCodePrReviewHttpResult(Int64(response.status), body: body)
        } finally {
            client.close()
        }
    } catch (e: Exception) {
        GitCodePrReviewHttpResult(0, error: e.message)
    }
}

public func invokePrReviewAdapter(config: GitCodeReviewRuntimeConfig, reviewRequest: PrReviewAdapterRequestV1): PrReviewAdapterResponseV1 {
    let adapter = config.prReviewAdapter
    if (adapter.mode == "disabled" || adapter.endpoint.isEmpty()) {
        return PrReviewAdapterResponseV1("not_configured", requestId: reviewRequest.requestId, adapterMode: "disabled", degraded: true, needsHumanReview: true, diagnostics: ["adapter_not_configured"])
    }
    if (adapter.mode != "external") {
        return PrReviewAdapterResponseV1("not_configured", requestId: reviewRequest.requestId, adapterMode: adapter.mode, degraded: true, needsHumanReview: true, diagnostics: ["adapter_not_configured"])
    }
    let httpRequest = JsonObject()
    httpRequest.put("method", JsonString("POST"))
    httpRequest.put("url", JsonString(adapter.endpoint))
    httpRequest.put("path", JsonString(adapterEndpointPath(adapter.endpoint)))
    httpRequest.put("timeoutMs", JsonInt(adapter.timeoutMs))
    httpRequest.put("body", JsonString(reviewRequest.toJson().toJsonString()))
    let httpResult = match (gitCodePrReviewAdapterHttpRunnerForTest) {
        case Some(runner) => runner(httpRequest)
        case None => adapterNativeHttpPost(adapter, reviewRequest)
    }
    if (httpResult.statusCode == 0) {
        let low = httpResult.error.toAsciiLower()
        if (low.contains("timeout") || low.contains("timed out")) {
            return PrReviewAdapterResponseV1("timeout", requestId: reviewRequest.requestId, adapterMode: "external", retryable: true, degraded: true, needsHumanReview: true, diagnostics: ["adapter_timeout"])
        }
        return PrReviewAdapterResponseV1("unavailable", requestId: reviewRequest.requestId, adapterMode: "external", retryable: true, degraded: true, needsHumanReview: true, diagnostics: ["adapter_unavailable"])
    }
    if (httpResult.statusCode == 404 || httpResult.statusCode == 501) {
        return PrReviewAdapterResponseV1("unavailable", requestId: reviewRequest.requestId, adapterMode: "external", retryable: false, degraded: true, needsHumanReview: true, diagnostics: ["adapter_endpoint_not_found_or_not_implemented"])
    }
    if (httpResult.statusCode >= 500) {
        return PrReviewAdapterResponseV1("unavailable", requestId: reviewRequest.requestId, adapterMode: "external", retryable: true, degraded: true, needsHumanReview: true, diagnostics: ["adapter_5xx"])
    }
    if (httpResult.statusCode < 200 || httpResult.statusCode >= 300) {
        return PrReviewAdapterResponseV1("rejected", requestId: reviewRequest.requestId, adapterMode: "external", degraded: true, needsHumanReview: true, diagnostics: ["adapter_http_${httpResult.statusCode}"])
    }
    let parsed = parsePrReviewAdapterResponse(httpResult.body, requestId: reviewRequest.requestId, adapterMode: "external")
    PrReviewAdapterResponseV1(
        parsed.status,
        requestId: parsed.requestId,
        adapterMode: "external",
        engineId: if (parsed.engineId.isEmpty()) { "external_pr_review_engine" } else { parsed.engineId },
        summary: parsed.summary,
        findings: parsed.findings,
        elapsedMs: parsed.elapsedMs,
        truncated: parsed.truncated,
        retryable: parsed.retryable,
        degraded: parsed.degraded,
        needsHumanReview: parsed.needsHumanReview,
        diagnostics: parsed.diagnostics
    )
}

public func prReviewResponseToPromptContext(response: PrReviewAdapterResponseV1): JsonObject {
    let out = JsonObject()
    out.put("status", JsonString(response.status))
    out.put("adapterMode", JsonString(response.adapterMode))
    out.put("summary", JsonString(response.summary))
    out.put("needsHumanReview", JsonBool(response.needsHumanReview))
    let items = JsonArray([])
    for (finding in response.findings) {
        items.add(finding.toJson())
    }
    out.put("items", items)
    out.put("diagnostics", gitCodeReviewJsonArrayString(response.diagnostics))
    out
}
