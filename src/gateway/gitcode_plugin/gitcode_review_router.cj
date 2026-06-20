package metis.gateway.gitcode_plugin

import std.collection.ArrayList

public class GitCodeReviewTask {
    public let taskType: String
    public let eventId: String
    public let repo: String
    public let number: String
    public let url: String
    public let title: String
    public let parentKind: String
    public let requiresCkb: Bool
    public let requiresSourceWorkspace: Bool
    public let requiresCodeReview: Bool
    public let needsHumanReview: Bool
    public let taskBrief: String
    public let diagnostics: Array<String>

    public init(
        taskType!: String = "",
        eventId!: String = "",
        repo!: String = "",
        number!: String = "",
        url!: String = "",
        title!: String = "",
        parentKind!: String = "",
        requiresCkb!: Bool = false,
        requiresSourceWorkspace!: Bool = false,
        requiresCodeReview!: Bool = false,
        needsHumanReview!: Bool = false,
        taskBrief!: String = "",
        diagnostics!: Array<String> = []
    ) {
        this.taskType = taskType.trimAscii()
        this.eventId = eventId.trimAscii()
        this.repo = repo.trimAscii()
        this.number = number.trimAscii()
        this.url = url.trimAscii()
        this.title = title.trimAscii()
        this.parentKind = parentKind.trimAscii()
        this.requiresCkb = requiresCkb
        this.requiresSourceWorkspace = requiresSourceWorkspace
        this.requiresCodeReview = requiresCodeReview
        this.needsHumanReview = needsHumanReview
        this.taskBrief = taskBrief.trimAscii()
        this.diagnostics = diagnostics
    }
}

public class GitCodeReviewRouteResult {
    public let ok: Bool
    public let status: String
    public let route: String
    public let degraded: Bool
    public let needsHumanReview: Bool
    public let allowWriteback: Bool
    public let task: GitCodeReviewTask
    public let diagnostic: String

    public init(
        ok: Bool,
        status!: String = "ok",
        route!: String = "",
        degraded!: Bool = false,
        needsHumanReview!: Bool = false,
        allowWriteback!: Bool = true,
        task!: GitCodeReviewTask = GitCodeReviewTask(),
        diagnostic!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.route = route.trimAscii()
        this.degraded = degraded
        this.needsHumanReview = needsHumanReview
        this.allowWriteback = allowWriteback
        this.task = task
        this.diagnostic = diagnostic.trimAscii()
    }
}

public func routeGitCodeReviewRequest(request: GitCodeReviewRequest): GitCodeReviewRouteResult {
    let timeout = request.diagnostics.contains("handler_timeout") || request.diagnostics.contains("llm_timeout")
    if (timeout) {
        let task = buildIssueBugTask(request)
        return GitCodeReviewRouteResult(false, status: "llm_degraded", route: task.taskType, degraded: true, needsHumanReview: true, allowWriteback: false, task: task, diagnostic: "handler timeout")
    }
    match (request.eventType) {
        case "comment" =>
            let task = buildCommentReplyTask(request)
            return routeFromTask(task, degraded: reviewRouteIsDegraded(request), needsHumanReview: reviewRouteNeedsHumanReview(request))
        case "pr" =>
            let task = buildPrReviewTask(request)
            return routeFromTask(task, degraded: reviewRouteIsDegraded(request), needsHumanReview: reviewRouteNeedsHumanReview(request))
        case "issue" =>
            match (request.issueKind) {
                case "bug" => return routeFromTask(buildIssueBugTask(request), degraded: reviewRouteIsDegraded(request), needsHumanReview: reviewRouteNeedsHumanReview(request))
                case "feature-request" => return routeFromTask(buildIssueFeatureTask(request), degraded: reviewRouteIsDegraded(request), needsHumanReview: reviewRouteNeedsHumanReview(request))
                case "question" =>
                    let degraded = reviewRouteIsDegraded(request) || request.diagnostics.contains("ckb_unavailable")
                    return routeFromTask(buildIssueQuestionTask(request), degraded: degraded, needsHumanReview: degraded || reviewRouteNeedsHumanReview(request))
                case _ =>
                    let task = buildIssueGenericTask(request)
                    return GitCodeReviewRouteResult(true, route: "issue_generic", needsHumanReview: true, allowWriteback: false, task: task)
            }
        case _ =>
            let task = buildIssueGenericTask(request)
            GitCodeReviewRouteResult(false, status: "unsupported_event_type", route: task.taskType, needsHumanReview: true, allowWriteback: false, task: task, diagnostic: "unsupported GitCode review event type")
    }
}

public func buildIssueBugTask(request: GitCodeReviewRequest): GitCodeReviewTask {
    baseReviewTask(
        request,
        "issue_bug",
        requiresCkb: true,
        requiresSourceWorkspace: true,
        requiresCodeReview: false,
        taskBrief: reviewTaskBrief(request, "bug issue")
    )
}

public func buildIssueFeatureTask(request: GitCodeReviewRequest): GitCodeReviewTask {
    baseReviewTask(
        request,
        "issue_feature",
        requiresCkb: true,
        requiresSourceWorkspace: true,
        requiresCodeReview: false,
        taskBrief: reviewTaskBrief(request, "feature issue")
    )
}

public func buildIssueQuestionTask(request: GitCodeReviewRequest): GitCodeReviewTask {
    baseReviewTask(
        request,
        "issue_question",
        requiresCkb: true,
        requiresSourceWorkspace: request.requiresSourceWorkspace,
        requiresCodeReview: false,
        taskBrief: reviewTaskBrief(request, "question issue")
    )
}

public func buildPrReviewTask(request: GitCodeReviewRequest): GitCodeReviewTask {
    baseReviewTask(
        request,
        "pr_review",
        requiresCkb: request.requiresCkb,
        requiresSourceWorkspace: request.requiresSourceWorkspace,
        requiresCodeReview: true,
        taskBrief: reviewTaskBrief(request, "pull request")
    )
}

public func buildCommentReplyTask(request: GitCodeReviewRequest): GitCodeReviewTask {
    let parentKind = if (request.hasDiscussionContext && request.discussionContext.parent.kind == "pr") {
        "pr"
    } else if (request.parentUrl.contains("/pulls/") || request.url.contains("/pulls/")) {
        "pr"
    } else {
        "issue"
    }
    let requiresCkb = request.requiresCkb || gitCodeCommentNeedsCangjieKnowledgeCkb(request)
    GitCodeReviewTask(
        taskType: "comment_reply",
        eventId: request.eventId,
        repo: request.repoFullName,
        number: request.number,
        url: request.url,
        title: request.title,
        parentKind: parentKind,
        requiresCkb: requiresCkb,
        requiresSourceWorkspace: request.requiresSourceWorkspace,
        requiresCodeReview: parentKind == "pr",
        needsHumanReview: request.needsHumanReview,
        taskBrief: reviewTaskBrief(request, "comment reply"),
        diagnostics: request.diagnostics
    )
}

private func buildIssueGenericTask(request: GitCodeReviewRequest): GitCodeReviewTask {
    baseReviewTask(
        request,
        "issue_generic",
        requiresCkb: request.requiresCkb,
        requiresSourceWorkspace: request.requiresSourceWorkspace,
        requiresCodeReview: false,
        needsHumanReview: true,
        taskBrief: reviewTaskBrief(request, "generic issue")
    )
}

private func routeFromTask(task: GitCodeReviewTask, degraded!: Bool = false, needsHumanReview!: Bool = false): GitCodeReviewRouteResult {
    GitCodeReviewRouteResult(true, route: task.taskType, degraded: degraded, needsHumanReview: needsHumanReview, allowWriteback: !needsHumanReview, task: GitCodeReviewTask(
        taskType: task.taskType,
        eventId: task.eventId,
        repo: task.repo,
        number: task.number,
        url: task.url,
        title: task.title,
        parentKind: task.parentKind,
        requiresCkb: task.requiresCkb,
        requiresSourceWorkspace: task.requiresSourceWorkspace,
        requiresCodeReview: task.requiresCodeReview,
        needsHumanReview: task.needsHumanReview || needsHumanReview,
        taskBrief: task.taskBrief,
        diagnostics: task.diagnostics
    ))
}

private func baseReviewTask(
    request: GitCodeReviewRequest,
    taskType: String,
    requiresCkb!: Bool,
    requiresSourceWorkspace!: Bool,
    requiresCodeReview!: Bool,
    needsHumanReview!: Bool = false,
    taskBrief!: String
): GitCodeReviewTask {
    GitCodeReviewTask(
        taskType: taskType,
        eventId: request.eventId,
        repo: request.repoFullName,
        number: request.number,
        url: request.url,
        title: request.title,
        requiresCkb: requiresCkb,
        requiresSourceWorkspace: requiresSourceWorkspace,
        requiresCodeReview: requiresCodeReview,
        needsHumanReview: needsHumanReview || request.needsHumanReview,
        taskBrief: taskBrief,
        diagnostics: request.diagnostics
    )
}

private func reviewTaskBrief(request: GitCodeReviewRequest, label: String): String {
    let parts = ArrayList<String>()
    parts.add("${label} ${request.repoFullName} #${request.number}")
    if (!request.title.isEmpty()) { parts.add("title=${request.title}") }
    if (!request.cjcVersion.isEmpty()) { parts.add("cjc=${request.cjcVersion}") }
    if (request.branchVersions.size > 0) { parts.add("branches=${String.join(request.branchVersions, delimiter: ",")}") }
    if (request.changedFiles.size > 0) { parts.add("changedFiles=${String.join(request.changedFiles, delimiter: ",")}") }
    if (request.reviewFindings.size > 0) { parts.add("reviewFindings=${String.join(request.reviewFindings, delimiter: ";")}") }
    if (request.requiresSourceWorkspace) { parts.add("sourcePolicy=required") }
    String.join(parts.toArray(), delimiter: " ")
}

private func gitCodeCommentNeedsCangjieKnowledgeCkb(request: GitCodeReviewRequest): Bool {
    if (request.eventType != "comment") {
        return false
    }
    let text = gitCodeCommentKnowledgeText(request)
    if (text.trimAscii().isEmpty()) {
        return false
    }
    let lower = text.toAsciiLower()
    if (gitCodeReviewTextContainsAny(text, ["仓颉语法", "仓颉标准库", "标准库", "工具链", "编译器", "包管理", "知识库"]) ||
        gitCodeReviewTextContainsAny(lower, ["cjpm", "cjc", "ckb", "stdx", "std.collection", "std.regex", "std.time", "cangjie docs", "cangjie doc", "cangjie standard library"])) {
        return true
    }
    let mentionsCangjie = text.contains("仓颉") || lower.contains("cangjie")
    mentionsCangjie && (
        gitCodeReviewTextContainsAny(text, ["语法", "标准库", "文档", "用法", "怎么", "如何", "知识", "工具"]) ||
        gitCodeReviewTextContainsAny(lower, ["syntax", "stdlib", "standard library", "docs", "documentation", "api", "tool", "ckb"])
    )
}

private func gitCodeCommentKnowledgeText(request: GitCodeReviewRequest): String {
    let parts = ArrayList<String>()
    if (!request.commentBody.trimAscii().isEmpty()) {
        parts.add(request.commentBody)
    } else if (!request.content.trimAscii().isEmpty()) {
        parts.add(request.content)
    }
    if (request.hasDiscussionContext && !request.discussionContext.triggerComment.body.trimAscii().isEmpty()) {
        parts.add(request.discussionContext.triggerComment.body)
    }
    String.join(parts.toArray(), delimiter: "\n")
}

private func gitCodeReviewTextContainsAny(text: String, needles: Array<String>): Bool {
    for (needle in needles) {
        if (text.contains(needle)) {
            return true
        }
    }
    false
}

private func reviewRouteIsDegraded(request: GitCodeReviewRequest): Bool {
    request.diagnostics.contains("ckb_unavailable") ||
        request.diagnostics.contains("source_unavailable") ||
        request.diagnostics.contains("pr_review_timeout") ||
        request.diagnostics.contains("review_adapter_timeout") ||
        request.diagnostics.contains("comment_context_missing") ||
        request.diagnostics.contains("comment_context_malformed") ||
        request.diagnostics.contains("comment_context_incomplete") ||
        request.diagnostics.contains("comment_context_degraded") ||
        request.diagnostics.contains("comment_context_truncated")
}

private func reviewRouteNeedsHumanReview(request: GitCodeReviewRequest): Bool {
    request.needsHumanReview || reviewRouteIsDegraded(request)
}
