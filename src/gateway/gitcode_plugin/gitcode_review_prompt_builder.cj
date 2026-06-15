package metis.gateway.gitcode_plugin

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString, JsonValue}

private let GENERATED_REPLY_JSON_FENCE = "```"

public class PromptInputV1 {
    public let role: String
    public let event: JsonObject
    public let author: JsonObject
    public let templateFields: JsonObject
    public let maintainers: JsonObject
    public let sourceContext: JsonObject
    public let ckbEvidence: JsonObject
    public let reviewFindings: JsonObject
    public let discussionContext: JsonObject
    public let diagnostics: Array<String>

    public init(
        event: JsonObject,
        templateFields: JsonObject,
        author!: JsonObject = JsonObject(),
        maintainers!: JsonObject = JsonObject(),
        sourceContext!: JsonObject = JsonObject(),
        ckbEvidence!: JsonObject = JsonObject(),
        reviewFindings!: JsonObject = JsonObject(),
        discussionContext!: JsonObject = JsonObject(),
        diagnostics!: Array<String> = []
    ) {
        this.role = "cangjie_community_technical_expert"
        this.event = event
        this.author = author
        this.templateFields = templateFields
        this.maintainers = maintainers
        this.sourceContext = sourceContext
        this.ckbEvidence = ckbEvidence
        this.reviewFindings = reviewFindings
        this.discussionContext = discussionContext
        this.diagnostics = diagnostics
    }
}

public class GitCodeGeneratedReplyModelOutputV1 {
    public let ok: Bool
    public let status: String
    public let header: String
    public let result: String
    public let safety: String
    public let needsHumanReview: Bool
    public let citations: JsonArray
    public let diagnostics: JsonArray

    public init(
        ok: Bool,
        status: String,
        header!: String = "",
        result!: String = "",
        safety!: String = "needs_human_review",
        needsHumanReview!: Bool = true,
        citations!: JsonArray = JsonArray([]),
        diagnostics!: JsonArray = JsonArray([])
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.header = gitCodeReviewRedactSensitiveText(header.trimAscii())
        this.result = gitCodeReviewRedactSensitiveText(result.trimAscii())
        this.safety = safety.trimAscii()
        this.needsHumanReview = needsHumanReview
        this.citations = citations
        this.diagnostics = diagnostics
    }
}

private func promptStr(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func promptStatus(obj: JsonObject): String {
    promptStr(obj, "status")
}

private func safePromptJson(obj: JsonObject, maxChars!: Int64 = 6000): String {
    var safe = gitCodeReviewRedactSensitiveText(obj.toJsonString())
    if (Int64(safe.size) > maxChars) {
        safe = safe[..maxChars] + "\ntruncated=true"
    }
    safe
}

private func promptJsonObjectHasFields(obj: JsonObject): Bool {
    obj.toJsonString() != "{}"
}

private func buildPrompt(template: GitCodePromptTemplate, input: PromptInputV1, extra: Array<String>): String {
    let lines = ArrayList<String>()
    lines.add(renderPromptTemplate(template, input))
    lines.add("")
    lines.add("StructuredTask")
    for (line in extra) {
        lines.add(line)
    }
    if (safePromptJson(input.sourceContext).contains("truncated=true")) {
        lines.add("sourceContext truncated=true")
    }
    if (safePromptJson(input.ckbEvidence).contains("truncated=true")) {
        lines.add("ckbEvidence truncated=true")
    }
    if (safePromptJson(input.reviewFindings).contains("truncated=true")) {
        lines.add("reviewFindings truncated=true")
    }
    gitCodeReviewRedactSensitiveText(String.join(lines.toArray(), delimiter: "\n"))
}

public func buildBugIssuePrompt(input: PromptInputV1, templates: GitCodePromptTemplateSet): String {
    let extra = ArrayList<String>()
    extra.add("bugDescription=${promptStr(input.templateFields, "bugDescription")}")
    extra.add("expectedBehavior=${promptStr(input.templateFields, "expectedBehavior")}")
    extra.add("reproduction=${promptStr(input.templateFields, "reproduction")}")
    extra.add("cjcVersion=${promptStr(input.templateFields, "cjcVersion")}")
    if (promptStr(input.templateFields, "cjcVersion").isEmpty()) { extra.add("missing_cjc_version") }
    let branchJson = match (input.templateFields.get("branchVersions")) {
        case Some(v) => v.toJsonString()
        case None => "[]"
    }
    extra.add("branchVersions=${branchJson}")
    if (branchJson == "[]") { extra.add("missing_branch_versions") }
    extra.add("sourceContext=${safePromptJson(input.sourceContext)}")
    extra.add("CKB evidence=${safePromptJson(input.ckbEvidence)}")
    extra.add("output schema: header/result/safety/needsHumanReview/citations/diagnostics")
    buildPrompt(templates.issueBug, input, extra.toArray())
}

public func buildFeatureIssuePrompt(input: PromptInputV1, templates: GitCodePromptTemplateSet): String {
    let extra = ArrayList<String>()
    extra.add("featureDescription=${promptStr(input.templateFields, "featureDescription")}")
    extra.add("valueAndScenarios=${promptStr(input.templateFields, "valueAndScenarios")}")
    extra.add("任务：评估合理性、可行性、兼容性风险和维护成本。")
    extra.add("sourceContext=${safePromptJson(input.sourceContext)}")
    if (promptStatus(input.sourceContext) != "resolved") {
        extra.add("源码证据不足：必须保守评估，不能声称已审源码。")
    }
    extra.add("output schema: header/result/safety")
    buildPrompt(templates.issueFeatureRequest, input, extra.toArray())
}

public func buildQuestionIssuePrompt(input: PromptInputV1, templates: GitCodePromptTemplateSet): String {
    let extra = ArrayList<String>()
    extra.add("questionDescription=${promptStr(input.templateFields, "questionDescription")}")
    extra.add("branchVersions=${match (input.templateFields.get("branchVersions")) { case Some(v) => v.toJsonString() case None => "[]" }}")
    extra.add("CKB evidence=${safePromptJson(input.ckbEvidence)}")
    extra.add("必须优先基于 CKB evidence；不得伪造 CKB 引用。")
    if (promptStatus(input.ckbEvidence) != "resolved") {
        extra.add("needsHumanReview=true；证据不足时必须明确说明不足。")
    }
    buildPrompt(templates.issueQuestion, input, extra.toArray())
}

public func buildPrEnglishPrompt(input: PromptInputV1, templates: GitCodePromptTemplateSet): String {
    let extra = ArrayList<String>()
    extra.add("English PR fields")
    extra.add("changedFiles=${safePromptJson(input.event)}")
    extra.add("reviewFindings=${safePromptJson(input.reviewFindings)}")
    extra.add("中文输出偏好：用中文总结审查结论。")
    if (promptStatus(input.reviewFindings) == "timeout") {
        extra.add("review 阶段超时：不得伪造 findings，needsHumanReview=true。")
    }
    buildPrompt(templates.prEnglish, input, extra.toArray())
}

public func buildPrChinesePrompt(input: PromptInputV1, templates: GitCodePromptTemplateSet): String {
    let extra = ArrayList<String>()
    extra.add("中文 PR 字段")
    extra.add("变更类型：Bugfix / 问题修复 / feature")
    extra.add("编译自验证=${promptStr(input.templateFields, "buildSelfCheck")}")
    extra.add("测试自验证=${promptStr(input.templateFields, "testSelfCheck")}")
    extra.add("reviewFindings=${safePromptJson(input.reviewFindings)}")
    if (promptStatus(input.reviewFindings) == "timeout") {
        extra.add("review 阶段超时：不得伪造 findings，needsHumanReview=true。")
    }
    buildPrompt(templates.prChinese, input, extra.toArray())
}

public func buildCommentPrompt(input: PromptInputV1, templates: GitCodePromptTemplateSet): String {
    let kind = promptStr(input.event, "kind")
    let extra = ArrayList<String>()
    extra.add("comment body=${promptStr(input.templateFields, "commentBody")}")
    if (kind.contains("pr")) {
        extra.add("parent PR summary=${promptStr(input.templateFields, "parentPrSummary")}")
        extra.add("changedFiles=${safePromptJson(input.event)}")
        extra.add("reviewFindings=${safePromptJson(input.reviewFindings)}")
    } else {
        extra.add("parent issue title=${promptStr(input.templateFields, "parentIssueTitle")}")
        extra.add("parent issue url=${promptStr(input.templateFields, "parentIssueUrl")}")
        extra.add("parent issue body summary=${promptStr(input.event, "body")}")
    }
    if (promptJsonObjectHasFields(input.discussionContext)) {
        extra.add("discussionContext=${safePromptJson(input.discussionContext, maxChars: 12000)}")
    }
    extra.add("CKB evidence=${safePromptJson(input.ckbEvidence)}")
    buildPrompt(templates.commentReply, input, extra.toArray())
}

private func replyArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func generatedReplyFenceLanguageAllowed(firstLine: String): Bool {
    let trimmed = firstLine.trimAscii()
    if (!trimmed.startsWith(GENERATED_REPLY_JSON_FENCE)) {
        return false
    }
    let language = trimmed[GENERATED_REPLY_JSON_FENCE.size..].trimAscii()
    language.isEmpty() || language.toAsciiLower() == "json"
}

private func normalizeGeneratedReplyJsonPayload(raw: String): String {
    let trimmed = raw.trimAscii()
    if (!trimmed.startsWith(GENERATED_REPLY_JSON_FENCE)) {
        return trimmed
    }

    let lines = trimmed.split("\n")
    if (lines.size < 2) {
        return trimmed
    }
    if (!generatedReplyFenceLanguageAllowed(lines[0])) {
        return trimmed
    }

    var end = lines.size - 1
    while (end > 0 && lines[end].trimAscii().isEmpty()) {
        end--
    }
    if (end <= 0 || lines[end].trimAscii() != GENERATED_REPLY_JSON_FENCE) {
        return trimmed
    }

    let bodyLines = ArrayList<String>()
    for (i in 1..end) {
        bodyLines.add(lines[i])
    }
    let body = String.join(bodyLines.toArray(), delimiter: "\n").trimAscii()
    if (body.isEmpty()) {
        return trimmed
    }
    body
}

public func parseGeneratedReplyModelOutput(raw: String): GitCodeGeneratedReplyModelOutputV1 {
    let normalized = normalizeGeneratedReplyJsonPayload(raw)
    let obj = try { JsonValue.fromStr(normalized).asObject() } catch (_: Exception) {
        return GitCodeGeneratedReplyModelOutputV1(false, "llm_output_decode_failed", needsHumanReview: true)
    }
    if (generatedReplyJsonObjectHasToolShape(obj)) {
        return GitCodeGeneratedReplyModelOutputV1(false, "llm_output_invalid_tool_json", needsHumanReview: true)
    }
    let header = promptStr(obj, "header")
    let result = promptStr(obj, "result")
    if (result.trimAscii().isEmpty()) {
        return GitCodeGeneratedReplyModelOutputV1(false, "draft_empty", header: "", result: "", needsHumanReview: true)
    }
    let draft = "${header}\n\n${result}"
    if (draft.contains("/Users/")) {
        return GitCodeGeneratedReplyModelOutputV1(false, "draft_contains_local_path", header: "", result: "", needsHumanReview: true)
    }
    if (draft.contains("@") || draft.contains("维护者：") || draft.contains("Reviewer:") || draft.contains("角色：")) {
        return GitCodeGeneratedReplyModelOutputV1(false, "draft_contains_forbidden_maintainer_mention", header: "", result: "", needsHumanReview: true)
    }
    if (draft.toAsciiLower().contains("auto-reply") || draft.toAsciiLower().contains("gitcodemonitor")) {
        return GitCodeGeneratedReplyModelOutputV1(false, "draft_contains_forbidden_marker", header: "", result: "", needsHumanReview: true)
    }
    if (gitCodeReviewContainsForbiddenContent(draft)) {
        return GitCodeGeneratedReplyModelOutputV1(false, "draft_contains_secret", header: "", result: "", needsHumanReview: true)
    }
    let safety = promptStr(obj, "safety")
    let needs = try { obj.get("needsHumanReview").getOrThrow().asBool().getValue() } catch (_: Exception) { safety != "approved" }
    GitCodeGeneratedReplyModelOutputV1(true, "ok", header: header, result: result, safety: safety, needsHumanReview: needs, citations: replyArray(obj, "citations"), diagnostics: replyArray(obj, "diagnostics"))
}

public func renderGeneratedReplyDraft(reply: GitCodeGeneratedReplyModelOutputV1): String {
    if (!reply.ok) {
        return "需要人工确认\n\n${reply.status}"
    }
    "${reply.header}\n\n${reply.result}"
}

private func generatedReplyJsonObjectHasToolShape(obj: JsonObject): Bool {
    for ((key, value) in obj.getFields()) {
        let normalized = key.trimAscii()
        if (normalized == "tool" ||
            normalized == "name" ||
            normalized == "arguments" ||
            normalized == "function_call" ||
            normalized == "tool_calls") {
            return true
        }
        if (generatedReplyJsonValueContainsToolShape(value)) {
            return true
        }
    }
    false
}

private func generatedReplyJsonValueContainsToolShape(value: JsonValue): Bool {
    let text = try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
    if (!text.isEmpty() && (text.contains("_answer_") || text.contains("functions.") || text.contains("tool_call"))) {
        return true
    }
    let obj = try { value.asObject() } catch (_: Exception) { JsonObject() }
    if (!obj.getFields().isEmpty()) {
        return generatedReplyJsonObjectHasToolShape(obj)
    }
    let arr = try { value.asArray() } catch (_: Exception) { JsonArray([]) }
    for (item in arr.getItems()) {
        if (generatedReplyJsonValueContainsToolShape(item)) {
            return true
        }
    }
    false
}
