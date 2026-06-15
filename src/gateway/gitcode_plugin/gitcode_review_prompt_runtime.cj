package metis.gateway.gitcode_plugin

import metis.gateway.service_plugin.ServicePluginAcceptedGitCodeEvent
import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

public class GitCodeReviewPromptPlan {
    public let ok: Bool
    public let status: String
    public let prompt: String
    public let route: String
    public let templateId: String
    public let source: String
    public let expectsJsonOutput: Bool
    public let diagnostic: String

    public init(
        ok: Bool,
        status!: String = "ok",
        prompt!: String = "",
        route!: String = "",
        templateId!: String = "",
        source!: String = "",
        expectsJsonOutput!: Bool = false,
        diagnostic!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.prompt = prompt
        this.route = route.trimAscii()
        this.templateId = templateId.trimAscii()
        this.source = source.trimAscii()
        this.expectsJsonOutput = expectsJsonOutput
        this.diagnostic = diagnostic.trimAscii()
    }
}

public func buildGitCodeReplyPromptForServicePluginEvent(
    event: ServicePluginAcceptedGitCodeEvent,
    templates: GitCodePromptTemplateSet
): GitCodeReviewPromptPlan {
    if (event.reviewRequestRaw.isEmpty()) {
        return legacyGitCodeReplyPromptPlan(event, "legacy_fallback", diagnostic: "reviewRequest missing")
    }
    if (!reviewRequestRawLooksLikeContractFragment(event.reviewRequestRaw)) {
        return legacyGitCodeReplyPromptPlan(event, "legacy_fallback_parse_failed", diagnostic: "reviewRequest schema missing")
    }
    let parsed = parseGitCodeReviewRequest(contractPayloadForServicePluginEvent(event))
    if (!parsed.ok) {
        return legacyGitCodeReplyPromptPlan(event, "legacy_fallback_parse_failed", diagnostic: parsed.status)
    }
    if (parsed.request.legacy) {
        return legacyGitCodeReplyPromptPlan(event, "legacy_fallback_parse_failed", diagnostic: "reviewRequest schema missing")
    }
    buildGitCodeReviewPromptForRequest(parsed.request, templates)
}

private func reviewRequestRawLooksLikeContractFragment(raw: String): Bool {
    let obj = try { JsonValue.fromStr(raw).asObject() } catch (_: Exception) { JsonObject() }
    obj.get("event").isSome() && obj.get("content").isSome() && obj.get("templates").isSome()
}

public func buildGitCodeReviewPromptForRequest(
    request: GitCodeReviewRequest,
    templates: GitCodePromptTemplateSet
): GitCodeReviewPromptPlan {
    let route = routeGitCodeReviewRequest(request)
    if (!route.ok || route.route == "issue_generic") {
        return legacyGitCodeReplyPromptPlan(
            servicePluginEventFromRequest(request),
            "legacy_fallback_unsupported_route",
            diagnostic: if (route.diagnostic.isEmpty()) { route.route } else { route.diagnostic }
        )
    }
    let input = buildGitCodeReviewPromptInput(request)
    let templateId = match (route.route) {
        case "issue_bug" => "issue_bug"
        case "issue_feature" => "issue_feature_request"
        case "issue_question" => "issue_question"
        case "comment_reply" => "comment_reply"
        case "pr_review" => gitCodeReviewPrPromptTemplateId(request)
        case _ => ""
    }
    if (templateId.isEmpty()) {
        return legacyGitCodeReplyPromptPlan(servicePluginEventFromRequest(request), "legacy_fallback_unsupported_route", diagnostic: route.route)
    }
    let prompt = match (templateId) {
        case "issue_bug" => buildBugIssuePrompt(input, templates)
        case "issue_feature_request" => buildFeatureIssuePrompt(input, templates)
        case "issue_question" => buildQuestionIssuePrompt(input, templates)
        case "comment_reply" => buildCommentPrompt(input, templates)
        case "pr_chinese" => buildPrChinesePrompt(input, templates)
        case "pr_english" => buildPrEnglishPrompt(input, templates)
        case _ => legacyGitCodeReplyPromptForServicePluginEvent(servicePluginEventFromRequest(request))
    }
    let template = templates.get(templateId)
    GitCodeReviewPromptPlan(
        true,
        status: if (template.source == "fallback_builtin") { "template_fallback_builtin" } else { "ok" },
        prompt: prompt,
        route: route.route,
        templateId: templateId,
        source: template.source,
        expectsJsonOutput: true,
        diagnostic: template.reason
    )
}

public func buildGitCodeReviewPromptInput(request: GitCodeReviewRequest): PromptInputV1 {
    let event = JsonObject()
    event.put("kind", JsonString(request.eventType))
    event.put("repo", JsonString(request.repoFullName))
    event.put("number", JsonString(request.number))
    event.put("commentId", JsonString(request.commentId))
    event.put("title", JsonString(request.title))
    event.put("body", JsonString(request.content))
    event.put("url", JsonString(request.url))
    event.put("parentUrl", JsonString(request.parentUrl))
    event.put("changedFiles", gitCodeReviewJsonArrayString(request.changedFiles))

    let fields = JsonObject()
    fields.put("bugDescription", JsonString(request.content))
    fields.put("expectedBehavior", JsonString(""))
    fields.put("reproduction", JsonString(request.content))
    fields.put("featureDescription", JsonString(request.content))
    fields.put("valueAndScenarios", JsonString(request.content))
    fields.put("questionDescription", JsonString(request.content))
    fields.put("commentBody", JsonString(if (request.commentBody.isEmpty()) { request.content } else { request.commentBody }))
    fields.put("cjcVersion", JsonString(request.cjcVersion))
    fields.put("branchVersions", gitCodeReviewJsonArrayString(request.branchVersions))
    fields.put("buildSelfCheck", JsonString(reviewSelfCheckValue(request.buildSelfCheck, request.draftContext, ["buildSelfCheck", "build"])))
    fields.put("testSelfCheck", JsonString(reviewSelfCheckValue(request.testSelfCheck, request.draftContext, ["testSelfCheck", "test"])))
    fields.put("parentIssueTitle", JsonString(if (request.hasDiscussionContext) { request.discussionContext.parent.title } else { request.title }))
    fields.put("parentIssueUrl", JsonString(if (request.parentUrl.isEmpty()) { request.url } else { request.parentUrl }))
    fields.put("parentPrSummary", JsonString(request.draftContext))

    let author = JsonObject()
    author.put("login", JsonString(request.author))

    let maintainers = JsonObject()
    maintainers.put("teamLeaders", gitCodeReviewJsonArrayString(request.teamLeaders))
    maintainers.put("codeowners", gitCodeReviewJsonArrayString(request.codeowners))
    maintainers.put("status", JsonString(if (request.teamLeaders.size + request.codeowners.size > 0) { "resolved" } else { "not_configured" }))

    let source = JsonObject()
    source.put("status", JsonString(if (request.requiresSourceWorkspace) { "unavailable" } else { "not_required" }))
    source.put("diagnostic", JsonString("source context is not attached to service-plugin reviewRequest"))

    let ckb = JsonObject()
    ckb.put("status", JsonString(if (request.requiresCkb) { "unavailable" } else { "not_required" }))
    ckb.put("diagnostic", JsonString("CKB evidence is not attached to service-plugin reviewRequest"))

    let review = JsonObject()
    review.put("status", JsonString(if (request.reviewFindings.size > 0) { "resolved" } else if (request.requiresCodeReview) { "unavailable" } else { "not_required" }))
    review.put("items", gitCodeReviewJsonArrayString(request.reviewFindings))

    PromptInputV1(
        event,
        fields,
        author: author,
        maintainers: maintainers,
        sourceContext: source,
        ckbEvidence: ckb,
        reviewFindings: review,
        discussionContext: gitCodeReviewDiscussionContextToJson(request),
        diagnostics: request.diagnostics
    )
}

public func gitCodeReviewPrPromptTemplateId(request: GitCodeReviewRequest): String {
    if (gitCodeReviewContainsCjk("${request.title}\n${request.content}\n${request.draftContext}")) {
        "pr_chinese"
    } else {
        "pr_english"
    }
}

public func legacyGitCodeReplyPromptForServicePluginEvent(event: ServicePluginAcceptedGitCodeEvent): String {
    let source = if (event.url.isEmpty()) { "${event.repo} ${event.kind} #${event.number}" } else { "${event.repo} ${event.kind} #${event.number} ${event.url}" }
    let title = if (event.title.isEmpty()) { "(no title)" } else { event.title }
    let content = if (event.content.isEmpty()) { "(no content)" } else { event.content }
    "你是 Metis 的 GitCode 回复草稿生成器。请基于下面的 GitCode PR/Issue/comment 生成一段可以发给维护者人工确认的中文回复草稿。只输出草稿正文，不要输出 JSON，不要输出 {\"tool\":...}、{\"name\":\"_answer_\",...}、{\"arguments\":...} 或任何工具调用描述，不要声称已经写回 GitCode，不要泄露任何 token、cookie、Authorization header 或本机路径。\n\n来源: ${source}\n标题: ${title}\n作者: ${event.author}\n内容:\n${content}"
}

public func contractPayloadForServicePluginEvent(event: ServicePluginAcceptedGitCodeEvent): String {
    "{" +
        "\"jobId\":${JsonString(event.jobId).toJsonString()}," +
        "\"eventId\":${JsonString(event.eventId).toJsonString()}," +
        "\"repo\":${JsonString(event.repo).toJsonString()}," +
        "\"kind\":${JsonString(event.kind).toJsonString()}," +
        "\"number\":${JsonString(event.number).toJsonString()}," +
        "\"commentId\":${JsonString(event.commentId).toJsonString()}," +
        "\"title\":${JsonString(event.title).toJsonString()}," +
        "\"url\":${JsonString(event.url).toJsonString()}," +
        "\"author\":${JsonString(event.author).toJsonString()}," +
        "\"content\":${JsonString(event.content).toJsonString()}," +
        "\"contractVersion\":${JsonString(event.contractVersion).toJsonString()}," +
        "\"reviewRequest\":${event.reviewRequestRaw}" +
    "}"
}

private func legacyGitCodeReplyPromptPlan(
    event: ServicePluginAcceptedGitCodeEvent,
    status: String,
    diagnostic!: String = ""
): GitCodeReviewPromptPlan {
    GitCodeReviewPromptPlan(
        true,
        status: status,
        prompt: legacyGitCodeReplyPromptForServicePluginEvent(event),
        route: "legacy",
        templateId: "legacy",
        source: "legacy",
        expectsJsonOutput: false,
        diagnostic: diagnostic
    )
}

private func servicePluginEventFromRequest(request: GitCodeReviewRequest): ServicePluginAcceptedGitCodeEvent {
    ServicePluginAcceptedGitCodeEvent(
        eventId: request.eventId,
        repo: request.repoFullName,
        kind: request.eventType,
        number: request.number,
        commentId: request.commentId,
        title: request.title,
        url: request.url,
        author: request.author,
        content: if (request.commentBody.isEmpty()) { request.content } else { request.commentBody },
        contractVersion: request.contractVersion
    )
}

private func gitCodeReviewContainsCjk(text: String): Bool {
    for (r in text.toRuneArray()) {
        if ((r >= r'\u{4E00}' && r <= r'\u{9FFF}') ||
            (r >= r'\u{3400}' && r <= r'\u{4DBF}') ||
            (r >= r'\u{3040}' && r <= r'\u{30FF}') ||
            (r >= r'\u{AC00}' && r <= r'\u{D7AF}')) {
            return true
        }
    }
    false
}

private func reviewSelfCheckValue(value: String, context: String, keys: Array<String>): String {
    let direct = value.trimAscii()
    if (!direct.isEmpty()) {
        return direct
    }
    reviewDraftContextValue(context, keys)
}

private func reviewDraftContextValue(context: String, keys: Array<String>): String {
    let text = context.trimAscii()
    if (text.isEmpty()) {
        return ""
    }
    for (token in text.split(" ")) {
        let clean = token.trimAscii()
        for (key in keys) {
            let prefix = "${key.trimAscii()}="
            if (clean.startsWith(prefix) && clean.size > prefix.size) {
                return clean[prefix.size..clean.size].trimAscii()
            }
        }
    }
    ""
}

private func gitCodeReviewDiscussionContextToJson(request: GitCodeReviewRequest): JsonObject {
    let out = JsonObject()
    if (!request.hasDiscussionContext) {
        return out
    }
    let context = request.discussionContext
    out.put("status", JsonString(context.status))
    out.put("kind", JsonString(context.kind))
    out.put("number", JsonString(context.number))
    out.put("commentId", JsonString(context.commentId))

    let parent = JsonObject()
    parent.put("kind", JsonString(context.parent.kind))
    parent.put("number", JsonString(context.parent.number))
    parent.put("title", JsonString(context.parent.title))
    parent.put("body", JsonString(context.parent.body))
    parent.put("url", JsonString(context.parent.url))
    parent.put("author", JsonString(context.parent.author))
    out.put("parent", parent)

    let trigger = JsonObject()
    trigger.put("id", JsonString(context.triggerComment.id))
    trigger.put("body", JsonString(context.triggerComment.body))
    trigger.put("url", JsonString(context.triggerComment.url))
    trigger.put("author", JsonString(context.triggerComment.author))
    out.put("triggerComment", trigger)

    let previous = JsonArray([])
    for (comment in context.previousComments) {
        let row = JsonObject()
        row.put("id", JsonString(comment.id))
        row.put("body", JsonString(comment.body))
        row.put("url", JsonString(comment.url))
        row.put("author", JsonString(comment.author))
        previous.add(row)
    }
    out.put("previousComments", previous)
    out.put("truncated", JsonBool(context.truncated))
    out.put("diagnostics", gitCodeReviewJsonArrayString(context.diagnostics))
    out
}
