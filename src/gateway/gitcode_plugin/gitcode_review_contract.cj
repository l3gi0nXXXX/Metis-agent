package metis.gateway.gitcode_plugin

import metis.core.metisSafeUtf8Prefix
import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public const GITCODE_REVIEW_CONTRACT_VERSION: String = "gcm-metis-gitcode-review-v1"

public class GitCodeReviewValidationResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class GitCodeReviewRequest {
    public let contractVersion: String
    public let schemaVersion: Int64
    public let legacy: Bool
    public let eventId: String
    public let eventType: String
    public let action: String
    public let repoFullName: String
    public let repoOrg: String
    public let repoName: String
    public let number: String
    public let commentId: String
    public let url: String
    public let title: String
    public let author: String
    public let content: String
    public let issueKind: String
    public let cjcVersion: String
    public let branchVersions: Array<String>
    public let changedFiles: Array<String>
    public let reviewFindings: Array<String>
    public let teamLeaders: Array<String>
    public let codeowners: Array<String>
    public let commentBody: String
    public let parentUrl: String
    public let requiresCkb: Bool
    public let requiresSourceWorkspace: Bool
    public let requiresCodeReview: Bool
    public let contentRedacted: Bool
    public let needsHumanReview: Bool
    public let diagnostics: Array<String>
    public let routeHint: String
    public let draftContext: String

    public init(
        contractVersion!: String = GITCODE_REVIEW_CONTRACT_VERSION,
        schemaVersion!: Int64 = 1,
        legacy!: Bool = false,
        eventId!: String = "",
        eventType!: String = "",
        action!: String = "",
        repoFullName!: String = "",
        repoOrg!: String = "",
        repoName!: String = "",
        number!: String = "",
        commentId!: String = "",
        url!: String = "",
        title!: String = "",
        author!: String = "",
        content!: String = "",
        issueKind!: String = "",
        cjcVersion!: String = "",
        branchVersions!: Array<String> = [],
        changedFiles!: Array<String> = [],
        reviewFindings!: Array<String> = [],
        teamLeaders!: Array<String> = [],
        codeowners!: Array<String> = [],
        commentBody!: String = "",
        parentUrl!: String = "",
        requiresCkb!: Bool = false,
        requiresSourceWorkspace!: Bool = false,
        requiresCodeReview!: Bool = false,
        contentRedacted!: Bool = false,
        needsHumanReview!: Bool = false,
        diagnostics!: Array<String> = [],
        routeHint!: String = "",
        draftContext!: String = ""
    ) {
        this.contractVersion = reviewSafeField(contractVersion, maxBytes: 128)
        this.schemaVersion = schemaVersion
        this.legacy = legacy
        this.eventId = reviewSafeField(eventId, maxBytes: 180)
        this.eventType = normalizeReviewEventType(eventType)
        this.action = reviewSafeField(action, maxBytes: 48).toAsciiLower()
        this.repoFullName = reviewSafeField(repoFullName, maxBytes: 180)
        this.repoOrg = reviewSafeField(repoOrg, maxBytes: 96)
        this.repoName = reviewSafeField(repoName, maxBytes: 96)
        this.number = reviewSafeField(number, maxBytes: 64)
        this.commentId = reviewSafeField(commentId, maxBytes: 64)
        this.url = reviewSafeField(url, maxBytes: 320)
        this.title = reviewSafeField(title, maxBytes: 240)
        this.author = reviewSafeField(author, maxBytes: 120)
        this.content = reviewSafeField(content, maxBytes: 2400)
        this.issueKind = normalizeIssueKind(issueKind)
        this.cjcVersion = reviewSafeField(cjcVersion, maxBytes: 240)
        this.branchVersions = reviewSafeArray(branchVersions, maxBytes: 120)
        this.changedFiles = reviewSafeArray(changedFiles, maxBytes: 240)
        this.reviewFindings = reviewSafeArray(reviewFindings, maxBytes: 500)
        this.teamLeaders = reviewSafeArray(teamLeaders, maxBytes: 120)
        this.codeowners = reviewSafeArray(codeowners, maxBytes: 120)
        this.commentBody = reviewSafeField(commentBody, maxBytes: 2400)
        this.parentUrl = reviewSafeField(parentUrl, maxBytes: 320)
        this.requiresCkb = requiresCkb
        this.requiresSourceWorkspace = requiresSourceWorkspace
        this.requiresCodeReview = requiresCodeReview
        this.contentRedacted = contentRedacted
        this.needsHumanReview = needsHumanReview
        this.diagnostics = reviewSafeArray(reviewDedupeArray(diagnostics), maxBytes: 160)
        this.routeHint = routeHint.trimAscii()
        this.draftContext = draftContext.trimAscii()
    }
}

public class GitCodeReviewRequestParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let request: GitCodeReviewRequest

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", request!: GitCodeReviewRequest = GitCodeReviewRequest()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.request = request
    }
}

public class GitCodeGeneratedReply {
    public let contractVersion: String
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let commentId: String
    public let url: String
    public let draft: String
    public let summary: String
    public let safety: String
    public let needsHumanReview: Bool
    public let diagnostics: Array<String>

    public init(
        contractVersion!: String = GITCODE_REVIEW_CONTRACT_VERSION,
        eventId!: String = "",
        repo!: String = "",
        kind!: String = "",
        number!: String = "",
        commentId!: String = "",
        url!: String = "",
        draft!: String = "",
        summary!: String = "",
        safety!: String = "approved",
        needsHumanReview!: Bool = false,
        diagnostics!: Array<String> = []
    ) {
        this.contractVersion = reviewSafeField(contractVersion, maxBytes: 128)
        this.eventId = reviewSafeField(eventId, maxBytes: 180)
        this.repo = reviewSafeField(repo, maxBytes: 180)
        this.kind = normalizeReviewEventType(kind)
        this.number = reviewSafeField(number, maxBytes: 64)
        this.commentId = reviewSafeField(commentId, maxBytes: 64)
        this.url = reviewSafeField(url, maxBytes: 320)
        this.draft = reviewSafeField(draft, maxBytes: 6000)
        this.summary = reviewSafeField(summary, maxBytes: 800)
        this.safety = reviewSafeField(safety, maxBytes: 64).toAsciiLower()
        this.needsHumanReview = needsHumanReview
        this.diagnostics = reviewSafeArray(reviewDedupeArray(diagnostics), maxBytes: 160)
    }

    public func toJsonString(): String {
        let root = JsonObject()
        root.put("contractVersion", JsonString(this.contractVersion))
        root.put("eventId", JsonString(this.eventId))
        root.put("repo", JsonString(this.repo))
        root.put("kind", JsonString(this.kind))
        root.put("number", JsonString(this.number))
        root.put("commentId", JsonString(this.commentId))
        root.put("url", JsonString(this.url))
        root.put("draft", JsonString(this.draft))
        root.put("summary", JsonString(this.summary))
        root.put("safety", JsonString(this.safety))
        root.put("needsHumanReview", JsonBool(this.needsHumanReview))
        root.put("diagnostics", reviewStringArrayToJson(this.diagnostics))
        root.toJsonString()
    }
}

public class GitCodeGeneratedReplyParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let reply: GitCodeGeneratedReply

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", reply!: GitCodeGeneratedReply = GitCodeGeneratedReply()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.reply = reply
    }
}

public func parseGitCodeReviewRequest(payload: String): GitCodeReviewRequestParseResult {
    let raw = payload.trimAscii()
    let root = try {
        JsonValue.fromStr(raw).asObject()
    } catch (_: Exception) {
        return GitCodeReviewRequestParseResult(false, status: "payload_decode_failed", diagnostic: "accepted event payload must be a JSON object")
    }
    if (reviewContainsLocalPath(raw)) {
        return GitCodeReviewRequestParseResult(false, status: "payload_contains_local_path", diagnostic: "contract contains a local filesystem path")
    }
    if (reviewContainsSecret(raw)) {
        return GitCodeReviewRequestParseResult(false, status: "payload_contains_secret", diagnostic: "contract contains secret-like text")
    }
    let hasReviewRequest = root.get("reviewRequest").isSome()
    if (!hasReviewRequest) {
        let legacy = parseLegacyReviewRequest(root)
        let validation = validateGitCodeReviewRequest(legacy)
        if (!validation.ok) {
            return GitCodeReviewRequestParseResult(false, status: validation.status, diagnostic: validation.diagnostic, request: legacy)
        }
        return GitCodeReviewRequestParseResult(true, request: legacy)
    }
    let contractVersion = reviewString(root, "contractVersion")
    if (contractVersion.isEmpty()) {
        return GitCodeReviewRequestParseResult(false, status: "contract_version_missing", diagnostic: "contractVersion is required")
    }
    if (contractVersion != GITCODE_REVIEW_CONTRACT_VERSION) {
        return GitCodeReviewRequestParseResult(false, status: "contract_version_unsupported", diagnostic: "unsupported GitCode review contract version")
    }
    let requestObj = reviewObject(root, "reviewRequest")
    let eventObj = reviewObject(requestObj, "event")
    let repoObj = reviewObject(eventObj, "repo")
    let itemObj = reviewObject(eventObj, "item")
    let commentObj = reviewObject(eventObj, "comment")
    let authorObj = reviewObject(requestObj, "author")
    let maintainersObj = reviewObject(requestObj, "maintainers")
    let templatesObj = reviewObject(requestObj, "templates")
    let fieldsObj = reviewObject(templatesObj, "fields")
    let prObj = reviewObject(requestObj, "pr")
    let policyObj = reviewObject(requestObj, "policy")
    let diagnostics = ArrayList<String>()
    reviewAppendStrings(diagnostics, reviewStringArray(maintainersObj, "diagnostics"))
    reviewAppendStrings(diagnostics, reviewStringArray(templatesObj, "diagnostics"))
    reviewAppendStrings(diagnostics, reviewStringArray(requestObj, "diagnostics"))
    if (reviewString(maintainersObj, "teamLeaderStatus") == "missing" || reviewString(maintainersObj, "teamLeaderStatus") == "failed") {
        diagnostics.add("team_leader_missing")
    }
    let issueKind = reviewString(templatesObj, "issueKind")
    let content = reviewFirstNonEmpty([reviewString(root, "content"), reviewString(fieldsObj, "bugDescription"), reviewString(commentObj, "body")])
    let redacted = diagnostics.contains("content_redacted") || content.toAsciiLower().contains("redacted")
    let request = GitCodeReviewRequest(
        contractVersion: contractVersion,
        schemaVersion: reviewInt(requestObj, "schemaVersion", fallback: 1),
        legacy: false,
        eventId: reviewFirstNonEmpty([reviewString(eventObj, "eventId"), reviewString(root, "eventId")]),
        eventType: reviewFirstNonEmpty([reviewString(eventObj, "eventType"), reviewString(root, "kind")]),
        action: reviewString(eventObj, "action"),
        repoFullName: reviewFirstNonEmpty([reviewString(repoObj, "fullName"), reviewString(root, "repo")]),
        repoOrg: reviewString(repoObj, "org"),
        repoName: reviewString(repoObj, "name"),
        number: reviewFirstNonEmpty([reviewString(itemObj, "number"), reviewAnyString(root, "number")]),
        commentId: reviewFirstNonEmpty([reviewString(commentObj, "commentId"), reviewAnyString(root, "commentId")]),
        url: reviewFirstNonEmpty([reviewString(itemObj, "url"), reviewString(root, "url")]),
        title: reviewFirstNonEmpty([reviewString(itemObj, "title"), reviewString(root, "title")]),
        author: reviewFirstNonEmpty([reviewString(authorObj, "login"), reviewString(root, "author")]),
        content: content,
        issueKind: issueKind,
        cjcVersion: reviewString(fieldsObj, "cjcVersion"),
        branchVersions: reviewStringArray(fieldsObj, "branchVersions"),
        changedFiles: reviewStringArray(prObj, "changedFiles"),
        reviewFindings: reviewStringArray(prObj, "reviewFindings"),
        teamLeaders: reviewMentionArray(maintainersObj, "teamLeaders"),
        codeowners: reviewMentionArray(maintainersObj, "codeowners"),
        commentBody: reviewString(commentObj, "body"),
        parentUrl: reviewString(itemObj, "url"),
        requiresCkb: reviewBool(policyObj, "requiresCkb"),
        requiresSourceWorkspace: reviewBool(policyObj, "requiresSourceWorkspace"),
        requiresCodeReview: reviewBool(policyObj, "requiresCodeReview"),
        contentRedacted: redacted,
        diagnostics: diagnostics.toArray(),
        draftContext: buildReviewDraftContext(issueKind, reviewStringArray(fieldsObj, "branchVersions"), reviewString(fieldsObj, "cjcVersion"), reviewStringArray(prObj, "changedFiles"), reviewStringArray(prObj, "reviewFindings"))
    )
    let validation = validateGitCodeReviewRequest(request)
    if (!validation.ok) {
        return GitCodeReviewRequestParseResult(false, status: validation.status, diagnostic: validation.diagnostic, request: request)
    }
    GitCodeReviewRequestParseResult(true, request: request)
}

public func validateGitCodeReviewRequest(request: GitCodeReviewRequest): GitCodeReviewValidationResult {
    if (!request.legacy && request.contractVersion.isEmpty()) {
        return GitCodeReviewValidationResult(false, status: "contract_version_missing", diagnostic: "contractVersion is required")
    }
    if (!request.legacy && request.contractVersion != GITCODE_REVIEW_CONTRACT_VERSION) {
        return GitCodeReviewValidationResult(false, status: "contract_version_unsupported", diagnostic: "unsupported GitCode review contract version")
    }
    if (!reviewRepoValid(request.repoFullName)) {
        return GitCodeReviewValidationResult(false, status: "repo_invalid", diagnostic: "repo must be org/name without traversal")
    }
    if (!reviewUrlValid(request.url)) {
        return GitCodeReviewValidationResult(false, status: "url_invalid", diagnostic: "GitCode URL must be an https://gitcode.com URL")
    }
    let text = "${request.repoFullName}\n${request.url}\n${request.content}\n${request.commentBody}\n${request.parentUrl}\n${request.draftContext}"
    if (reviewContainsLocalPath(text)) {
        return GitCodeReviewValidationResult(false, status: "payload_contains_local_path", diagnostic: "contract contains a local filesystem path")
    }
    if (reviewContainsSecret(text)) {
        return GitCodeReviewValidationResult(false, status: "payload_contains_secret", diagnostic: "contract contains secret-like text")
    }
    GitCodeReviewValidationResult(true)
}

public func parseGeneratedReply(payload: String): GitCodeGeneratedReplyParseResult {
    let root = try {
        JsonValue.fromStr(payload.trimAscii()).asObject()
    } catch (_: Exception) {
        return GitCodeGeneratedReplyParseResult(false, status: "payload_decode_failed", diagnostic: "generated reply payload must be a JSON object")
    }
    let version = reviewString(root, "contractVersion")
    if (version.isEmpty()) {
        return GitCodeGeneratedReplyParseResult(false, status: "contract_version_missing", diagnostic: "contractVersion is required")
    }
    if (version != GITCODE_REVIEW_CONTRACT_VERSION) {
        return GitCodeGeneratedReplyParseResult(false, status: "contract_version_unsupported", diagnostic: "unsupported generated reply version")
    }
    let reply = GitCodeGeneratedReply(
        contractVersion: version,
        eventId: reviewString(root, "eventId"),
        repo: reviewString(root, "repo"),
        kind: reviewString(root, "kind"),
        number: reviewAnyString(root, "number"),
        commentId: reviewAnyString(root, "commentId"),
        url: reviewString(root, "url"),
        draft: reviewString(root, "draft"),
        summary: reviewString(root, "summary"),
        safety: reviewString(root, "safety"),
        needsHumanReview: reviewBool(root, "needsHumanReview"),
        diagnostics: reviewStringArray(root, "diagnostics")
    )
    if (reply.draft.isEmpty()) {
        return GitCodeGeneratedReplyParseResult(false, status: "draft_empty", diagnostic: "generated reply draft is empty", reply: reply)
    }
    if (reviewContainsLocalPath(reply.toJsonString())) {
        return GitCodeGeneratedReplyParseResult(false, status: "payload_contains_local_path", diagnostic: "generated reply contains a local filesystem path", reply: reply)
    }
    if (reviewContainsSecret(reply.toJsonString())) {
        return GitCodeGeneratedReplyParseResult(false, status: "payload_contains_secret", diagnostic: "generated reply contains secret-like text", reply: reply)
    }
    GitCodeGeneratedReplyParseResult(true, reply: reply)
}

public func renderGitCodeReviewDiagnostic(result: GitCodeReviewRequestParseResult): String {
    let reason = match (result.status) {
        case "payload_decode_failed" => "GitCode review 请求无法解析，请检查 GCM 发送的契约 JSON。"
        case "contract_version_missing" => "GitCode review 请求缺少契约版本，已拒绝处理。"
        case "contract_version_unsupported" => "GitCode review 请求契约版本不受支持，已拒绝处理。"
        case "repo_invalid" => "GitCode review 请求中的仓库名不安全，已拒绝处理。"
        case "url_invalid" => "GitCode review 请求中的链接不是合法 GitCode HTTPS 地址，已拒绝处理。"
        case "payload_contains_local_path" => "GitCode review 请求包含本机路径，已拒绝处理。"
        case "payload_contains_secret" => "GitCode review 请求包含疑似 secret，已拒绝处理。"
        case _ => "GitCode review 请求校验失败，已拒绝处理。"
    }
    if (result.diagnostic.isEmpty()) { reason } else { "${reason}\n诊断: ${reviewSafeField(result.diagnostic, maxBytes: 240)}" }
}

private func parseLegacyReviewRequest(root: JsonObject): GitCodeReviewRequest {
    let kind = reviewString(root, "kind")
    let repo = reviewString(root, "repo")
    let issueKind = if (kind == "issue") { "generic" } else { "" }
    GitCodeReviewRequest(
        legacy: true,
        eventId: reviewString(root, "eventId"),
        eventType: kind,
        repoFullName: repo,
        number: reviewAnyString(root, "number"),
        commentId: reviewAnyString(root, "commentId"),
        url: reviewString(root, "url"),
        title: reviewString(root, "title"),
        author: reviewString(root, "author"),
        content: reviewString(root, "content"),
        issueKind: issueKind,
        diagnostics: ["legacy_payload"],
        routeHint: if (kind == "pr") { "pr_review" } else if (kind == "comment") { "comment_reply" } else { "issue_generic" },
        draftContext: reviewString(root, "content")
    )
}

private func normalizeReviewEventType(raw: String): String {
    match (raw.trimAscii().toAsciiLower()) {
        case "pull_request" | "pullrequest" => "pr"
        case other => other
    }
}

private func normalizeIssueKind(raw: String): String {
    match (raw.trimAscii().toAsciiLower()) {
        case "feature" | "feature_request" => "feature-request"
        case "bug-report" | "bug_report" => "bug"
        case other => other
    }
}

private func reviewObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func reviewArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func reviewString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { reviewSafeField(v.asString().getValue()) } catch (_: Exception) { "" }
        case None => ""
    }
}

private func reviewAnyString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try { return reviewSafeField(v.asString().getValue()) } catch (_: Exception) { () }
            try { return "${v.asInt().getValue()}" } catch (_: Exception) { () }
            ""
        case None => ""
    }
}

private func reviewInt(obj: JsonObject, key: String, fallback!: Int64 = 0): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func reviewBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func reviewStringArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    for (item in reviewArray(obj, key).getItems()) {
        let value = try { item.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        if (!value.isEmpty()) { out.add(reviewSafeField(value, maxBytes: 300)) }
    }
    out.toArray()
}

private func reviewMentionArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    for (item in reviewArray(obj, key).getItems()) {
        let row = try { item.asObject() } catch (_: Exception) { JsonObject() }
        var mention = reviewString(row, "mention")
        if (mention.isEmpty()) {
            let login = reviewString(row, "login")
            if (!login.isEmpty()) { mention = "@${login}" }
        }
        if (!mention.isEmpty()) { out.add(mention) }
    }
    reviewDedupeArray(out.toArray())
}

private func reviewStringArrayToJson(values: Array<String>): JsonArray {
    let out = ArrayList<JsonValue>()
    for (value in values) {
        out.add(JsonString(value))
    }
    JsonArray(out)
}

private func reviewAppendStrings(target: ArrayList<String>, values: Array<String>): Unit {
    for (value in values) {
        if (!value.trimAscii().isEmpty()) { target.add(value.trimAscii()) }
    }
}

private func reviewFirstNonEmpty(values: Array<String>): String {
    for (value in values) {
        let text = value.trimAscii()
        if (!text.isEmpty()) { return text }
    }
    ""
}

private func reviewDedupeArray(values: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (value in values) {
        let text = value.trimAscii()
        if (!text.isEmpty() && !out.contains(text)) {
            out.add(text)
        }
    }
    out.toArray()
}

private func reviewSafeArray(values: Array<String>, maxBytes!: Int64 = 160): Array<String> {
    let out = ArrayList<String>()
    for (value in values) {
        let text = reviewSafeField(value, maxBytes: maxBytes)
        if (!text.isEmpty()) { out.add(text) }
    }
    out.toArray()
}

private func buildReviewDraftContext(issueKind: String, branches: Array<String>, cjcVersion: String, changedFiles: Array<String>, findings: Array<String>): String {
    let parts = ArrayList<String>()
    if (!issueKind.trimAscii().isEmpty()) { parts.add("issueKind=${issueKind}") }
    if (branches.size > 0) { parts.add("branches=${String.join(branches, delimiter: ",")}") }
    if (!cjcVersion.trimAscii().isEmpty()) { parts.add("cjc=${cjcVersion}") }
    if (changedFiles.size > 0) { parts.add("changedFiles=${String.join(changedFiles, delimiter: ",")}") }
    if (findings.size > 0) { parts.add("reviewFindings=${String.join(findings, delimiter: ";")}") }
    String.join(parts.toArray(), delimiter: " ")
}

private func reviewRepoValid(repo: String): Bool {
    let text = repo.trimAscii()
    if (text.isEmpty() || text.startsWith("/") || text.contains("..") || text.contains("\\") || text.contains(" ") || text.contains(":")) {
        return false
    }
    let parts = text.split("/")
    parts.size == 2 && !parts[0].isEmpty() && !parts[1].isEmpty()
}

private func reviewUrlValid(url: String): Bool {
    let text = url.trimAscii()
    text.startsWith("https://gitcode.com/") && !text.contains(" ") && !text.contains("/../")
}

private func reviewContainsLocalPath(text: String): Bool {
    let lower = text.toAsciiLower()
    lower.contains("/users/") || lower.contains("/var/folders/") || lower.contains("/tmp/metis") || lower.contains("c:\\") || lower.contains("file://")
}

private func reviewContainsSecret(text: String): Bool {
    let lower = text.toAsciiLower()
    lower.contains("authorization:") || lower.contains("bearer ") || lower.contains("cookie:") || lower.contains("token=") || lower.contains("\"token\"") || lower.contains("\"authorization\"") || lower.contains("\"cookie\"")
}

private func reviewSafeField(raw: String, maxBytes!: Int64 = 512): String {
    var text = raw.trimAscii()
    text = text.replace("\r", " ").replace("\u{0000}", "")
    metisSafeUtf8Prefix(text, maxBytes)
}
