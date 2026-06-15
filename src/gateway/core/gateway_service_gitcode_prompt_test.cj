package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.gateway.gitcode_plugin.{GITCODE_REVIEW_CONTRACT_VERSION, GitCodeReviewPromptPlan, gitCodeReviewJsonArrayString}
import metis.gateway.model.ChannelPolicyConfig
import metis.gateway.service_plugin.ServicePluginAcceptedGitCodeEvent
import std.collection.HashMap
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private func gitCodePromptTestTempRoot(label: String): Path {
    let root = Path("/tmp/metis-gateway-gitcode-prompt-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try { remove(root, recursive: true) } catch (_: Exception) { () }
    Directory.create(root, recursive: true)
    root
}

private func gitCodePromptTestRestoreEnv(name: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => setVariable(name, v)
        case None => setVariable(name, "")
    }
}

private func gitCodePromptTestWithHome<T>(label: String, block: (Path) -> T): T {
    let home = gitCodePromptTestTempRoot("home-${label}")
    let oldHome = getVariable("METIS_HOME")
    setVariable("METIS_HOME", home.toString())
    CliConfig.invalidatePathCache()
    CliSettingManager.invalidate()
    MetisConfigManager.invalidate()
    try {
        return block(home)
    } finally {
        gitCodePromptTestRestoreEnv("METIS_HOME", oldHome)
        CliConfig.invalidatePathCache()
        CliSettingManager.invalidate()
        MetisConfigManager.invalidate()
        try { remove(home, recursive: true) } catch (_: Exception) { () }
    }
}

private func gitCodePromptTestWriteTemplate(dir: Path, file: String, templateId: String, body: String): Unit {
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)
    }
    File.writeTo(
        dir.join(file),
        ("---\n" +
        "templateId: ${templateId}\n" +
        "contractVersion: gcm-metis-gitcode-review-v1\n" +
        "templateVersion: 1\n" +
        "inputSchema: PromptInputV1\n" +
        "outputSchema: GitCodeGeneratedReplyModelOutputV1\n" +
        "language: zh-CN\n" +
        "---\n\n" + body).toArray()
    )
}

private func gitCodePromptTestWriteSixTemplates(dir: Path, prefix: String): Unit {
    gitCodePromptTestWriteTemplate(dir, "issue-bug.md", "issue_bug", "# Role\n${prefix}-issue-bug\n# Task\nbug")
    gitCodePromptTestWriteTemplate(dir, "issue-feature-request.md", "issue_feature_request", "# Role\n${prefix}-issue-feature\n# Task\nfeature")
    gitCodePromptTestWriteTemplate(dir, "issue-question.md", "issue_question", "# Role\n${prefix}-issue-question\n# Task\nquestion")
    gitCodePromptTestWriteTemplate(dir, "pr-english.md", "pr_english", "# Role\n${prefix}-pr-english\n# Task\npr en")
    gitCodePromptTestWriteTemplate(dir, "pr-chinese.md", "pr_chinese", "# Role\n${prefix}-pr-chinese\n# Task\npr zh")
    gitCodePromptTestWriteTemplate(dir, "comment.md", "comment_reply", "# Role\n${prefix}-comment\n# Task\ncomment")
}

private func gitCodePromptTestInstallConfig(promptDir: Path, reloadPolicy!: String = "on_plugin_load"): Unit {
    let root = JsonObject()
    let gateway = JsonObject()
    let review = JsonObject()
    let templates = JsonObject()
    templates.put("dir", JsonString(promptDir.toString()))
    templates.put("allowUserOverride", JsonBool(true))
    templates.put("reloadPolicy", JsonString(reloadPolicy))
    templates.put("maxTemplateBytes", JsonInt(4096))
    templates.put("strictValidation", JsonBool(true))
    review.put("promptTemplates", templates)
    gateway.put("gitcodeReview", review)
    root.put("gateway", gateway)
    MetisConfigManager.writeRoot(root)
    MetisConfigManager.invalidate()
}

private func gitCodePromptTestString(obj: JsonObject, key: String): String {
    try { obj.get(key).getOrThrow().asString().getValue() } catch (_: Exception) { "" }
}

private func gitCodePromptTestTemplates(snapshot: JsonObject): JsonObject {
    try { snapshot.get("templates").getOrThrow().asObject() } catch (_: Exception) { JsonObject() }
}

private func gitCodePromptTestTemplate(snapshot: JsonObject, templateId: String): JsonObject {
    try { gitCodePromptTestTemplates(snapshot).get(templateId).getOrThrow().asObject() } catch (_: Exception) { JsonObject() }
}

private func gitCodePromptTestService(): GatewayService {
    GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
}

private func gitCodePromptTestReviewRequestRaw(
    eventType: String,
    issueKind!: String = "",
    title!: String = "空参数默认值异常",
    content!: String = "复现步骤",
    commentBody!: String = ""
): String {
    let request = JsonObject()
    request.put("schemaVersion", JsonInt(1))
    let event = JsonObject()
    event.put("eventId", JsonString("gitcode:Cangjie/cangjie_tools:${eventType}:201"))
    event.put("eventType", JsonString(eventType))
    let repo = JsonObject()
    repo.put("fullName", JsonString("Cangjie/cangjie_tools"))
    repo.put("org", JsonString("Cangjie"))
    repo.put("name", JsonString("cangjie_tools"))
    event.put("repo", repo)
    let item = JsonObject()
    item.put("number", JsonString("201"))
    item.put("title", JsonString(title))
    item.put("url", JsonString(if (eventType == "pr") { "https://gitcode.com/Cangjie/cangjie_tools/pulls/201" } else { "https://gitcode.com/Cangjie/cangjie_tools/issues/201" }))
    event.put("item", item)
    if (eventType == "comment") {
        let comment = JsonObject()
        comment.put("commentId", JsonString("9901"))
        comment.put("body", JsonString(commentBody))
        comment.put("url", JsonString("https://gitcode.com/Cangjie/cangjie_tools/issues/201#note_9901"))
        event.put("comment", comment)
    }
    request.put("event", event)
    let author = JsonObject()
    author.put("login", JsonString("alice"))
    request.put("author", author)
    let templates = JsonObject()
    templates.put("issueKind", JsonString(issueKind))
    let fields = JsonObject()
    fields.put("bugDescription", JsonString(content))
    fields.put("featureDescription", JsonString(content))
    fields.put("questionDescription", JsonString(content))
    fields.put("commentBody", JsonString(commentBody))
    fields.put("branchVersions", JsonArray([JsonString("main")]))
    fields.put("cjcVersion", JsonString("cjc 1.0.0"))
    templates.put("fields", fields)
    request.put("templates", templates)
    let contentObj = JsonObject()
    contentObj.put("title", JsonString(title))
    contentObj.put("body", JsonString(content))
    request.put("content", contentObj)
    let pr = JsonObject()
    pr.put("changedFiles", gitCodeReviewJsonArrayString(["src/example.cj"]))
    pr.put("reviewFindings", gitCodeReviewJsonArrayString(["缺少默认值测试"]))
    request.put("pr", pr)
    request.toJsonString()
}

private func gitCodePromptTestEvent(eventType: String, issueKind!: String = "", title!: String = "空参数默认值异常", content!: String = "复现步骤", commentBody!: String = ""): ServicePluginAcceptedGitCodeEvent {
    ServicePluginAcceptedGitCodeEvent(
        jobId: "job-201",
        eventId: "event-201",
        repo: "Cangjie/cangjie_tools",
        kind: if (eventType == "pr") { "pr" } else { eventType },
        number: "201",
        commentId: if (eventType == "comment") { "9901" } else { "" },
        title: title,
        url: if (eventType == "pr") { "https://gitcode.com/Cangjie/cangjie_tools/pulls/201" } else { "https://gitcode.com/Cangjie/cangjie_tools/issues/201" },
        author: "alice",
        content: if (eventType == "comment") { commentBody } else { content },
        contractVersion: GITCODE_REVIEW_CONTRACT_VERSION,
        reviewRequestRaw: gitCodePromptTestReviewRequestRaw(eventType, issueKind: issueKind, title: title, content: content, commentBody: commentBody)
    )
}

@Test
public class GatewayServiceGitCodePromptTest {
    @TestCase
    public func gatewayLoadsGitCodePromptTemplatesOnceAndKeepsCacheUntilRestart(): Unit {
        gitCodePromptTestWithHome<Unit>("p2-cache", { home: Path =>
            let promptDir = home.join("prompt")
            gitCodePromptTestWriteSixTemplates(promptDir, "PROMPT-P2-first")
            gitCodePromptTestInstallConfig(promptDir)

            let service = gitCodePromptTestService()
            service.debugLoadGitCodeReviewPromptRuntimeForTest()
            let snapshot = service.debugGitCodePromptRuntimeSnapshotForTest()
            @Expect(gitCodePromptTestString(snapshot, "reloadPolicy"), "on_plugin_load")
            @Expect(gitCodePromptTestString(gitCodePromptTestTemplate(snapshot, "issue_bug"), "source"), "user")
            @Expect(gitCodePromptTestString(gitCodePromptTestTemplate(snapshot, "comment_reply"), "source"), "user")
            let firstSha = gitCodePromptTestString(gitCodePromptTestTemplate(snapshot, "comment_reply"), "sha12")

            gitCodePromptTestWriteTemplate(promptDir, "comment.md", "comment_reply", "# Role\nPROMPT-P2-second-comment\n# Task\ncomment")
            let cachedPlan = service.debugBuildGitCodePromptPlanForTest(gitCodePromptTestEvent("comment", commentBody: "追问"))
            let cachedSnapshot = service.debugGitCodePromptRuntimeSnapshotForTest()
            @Expect(cachedPlan.prompt.contains("PROMPT-P2-first-comment"), true)
            @Expect(cachedPlan.prompt.contains("PROMPT-P2-second-comment"), false)
            @Expect(gitCodePromptTestString(gitCodePromptTestTemplate(cachedSnapshot, "comment_reply"), "sha12"), firstSha)

            let restarted = gitCodePromptTestService()
            restarted.debugLoadGitCodeReviewPromptRuntimeForTest()
            let restartedSnapshot = restarted.debugGitCodePromptRuntimeSnapshotForTest()
            let restartedSha = gitCodePromptTestString(gitCodePromptTestTemplate(restartedSnapshot, "comment_reply"), "sha12")
            let restartedPlan = restarted.debugBuildGitCodePromptPlanForTest(gitCodePromptTestEvent("comment", commentBody: "追问"))
            @Expect(restartedSha != firstSha, true)
            @Expect(restartedPlan.prompt.contains("PROMPT-P2-second-comment"), true)
        })
    }

    @TestCase
    public func gatewayFallsBackOnInvalidPromptConfigAndSingleTemplateFailures(): Unit {
        gitCodePromptTestWithHome<Unit>("p2-fallback", { home: Path =>
            let promptDir = home.join("prompt")
            gitCodePromptTestWriteSixTemplates(promptDir, "PROMPT-P2-good")
            gitCodePromptTestInstallConfig(promptDir, reloadPolicy: "hot")
            let invalidConfigService = gitCodePromptTestService()
            invalidConfigService.debugLoadGitCodeReviewPromptRuntimeForTest()
            let invalidSnapshot = invalidConfigService.debugGitCodePromptRuntimeSnapshotForTest()
            @Expect(gitCodePromptTestString(invalidSnapshot, "configStatus"), "config_invalid")
            @Expect(gitCodePromptTestString(gitCodePromptTestTemplate(invalidSnapshot, "issue_bug"), "source"), "builtin")

            gitCodePromptTestWriteTemplate(promptDir, "issue-bug.md", "comment_reply", "# Role\nbad id\n# Task\nbad")
            gitCodePromptTestInstallConfig(promptDir)
            let partialService = gitCodePromptTestService()
            partialService.debugLoadGitCodeReviewPromptRuntimeForTest()
            let partial = partialService.debugGitCodePromptRuntimeSnapshotForTest()
            @Expect(gitCodePromptTestString(gitCodePromptTestTemplate(partial, "issue_bug"), "source"), "fallback_builtin")
            @Expect(gitCodePromptTestString(gitCodePromptTestTemplate(partial, "issue_feature_request"), "source"), "user")
        })
    }

    @TestCase
    public func gatewayGitCodeAnswerBridgeUsesJsonModeAndKeepsLegacyPlainDraft(): Unit {
        let service = gitCodePromptTestService()
        let jsonPlan = GitCodeReviewPromptPlan(true, status: "ok", prompt: "json prompt", route: "issue_bug", templateId: "issue_bug", source: "builtin", expectsJsonOutput: true)
        let ok = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":\"结论\",\"result\":\"建议补测试\",\"safety\":\"approved\",\"needsHumanReview\":false}", jsonPlan)
        @Expect(ok.ok, true)
        @Expect(ok.draft, "结论\n\n建议补测试")
        @Expect(ok.needsHumanReview, false)

        let schemaReply = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":{\"taskKind\":\"issue-comment-reply\"},\"result\":{\"replyBody\":\"建议补充复现步骤\"},\"safety\":{\"noSecretsExposed\":true},\"needsHumanReview\":true,\"citations\":[],\"diagnostics\":[]}", jsonPlan)
        @Expect(schemaReply.ok, true)
        @Expect(schemaReply.draft, "建议补充复现步骤")
        @Expect(schemaReply.needsHumanReview, true)
        @Expect(schemaReply.draft.contains("replyBody"), false)
        @Expect(schemaReply.draft.contains("header"), false)
        @Expect(schemaReply.draft.contains("result"), false)

        let fenced = service.debugGitCodeGeneratedReplyResultForTest("```json\n{\"header\":\"结论\",\"result\":\"建议补 fenced JSON\",\"safety\":\"approved\",\"needsHumanReview\":false}\n```", jsonPlan)
        @Expect(fenced.ok, true)
        @Expect(fenced.status, "draft_generated")
        @Expect(fenced.draft, "结论\n\n建议补 fenced JSON")
        @Expect(fenced.diagnostic.contains("llm_output_decode_failed"), false)

        let needsReview = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":\"结论\",\"result\":\"建议人工确认\",\"safety\":\"needs_human_review\",\"needsHumanReview\":true}", jsonPlan)
        @Expect(needsReview.ok, true)
        @Expect(needsReview.needsHumanReview, true)

        let tool = service.debugGitCodeGeneratedReplyResultForTest("{\"tool\":\"functions.answer\",\"reason\":\"x\"}", jsonPlan)
        @Expect(tool.ok, false)
        @Expect(tool.status, "llm_output_invalid_tool_json")
        @Expect(tool.needsHumanReview, true)

        let fencedTool = service.debugGitCodeGeneratedReplyResultForTest("```json\n{\"tool\":\"functions.answer\",\"reason\":\"x\"}\n```", jsonPlan)
        @Expect(fencedTool.ok, false)
        @Expect(fencedTool.status, "llm_output_invalid_tool_json")

        let badFence = service.debugGitCodeGeneratedReplyResultForTest("```json\n{\"header\":\"结论\",\"result\":\"坏 fence\",\"safety\":\"approved\",\"needsHumanReview\":false}", jsonPlan)
        @Expect(badFence.ok, false)
        @Expect(badFence.status, "llm_output_decode_failed")
        @Expect(badFence.needsHumanReview, true)

        let empty = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":\"结论\",\"result\":\"\",\"safety\":\"approved\",\"needsHumanReview\":false}", jsonPlan)
        @Expect(empty.ok, false)
        @Expect(empty.status, "draft_empty")

        let schemaMissingResult = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":{\"taskKind\":\"issue-comment-reply\"},\"needsHumanReview\":false}", jsonPlan)
        @Expect(schemaMissingResult.ok, false)
        @Expect(schemaMissingResult.status, "result_missing")
        @Expect(schemaMissingResult.status != "draft_empty", true)

        let schemaMissingReplyBody = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":{\"taskKind\":\"issue-comment-reply\"},\"result\":{\"summary\":\"只有摘要\"},\"needsHumanReview\":false}", jsonPlan)
        @Expect(schemaMissingReplyBody.ok, false)
        @Expect(schemaMissingReplyBody.status, "result_reply_body_missing")
        @Expect(schemaMissingReplyBody.status != "draft_empty", true)

        let forbiddenMaintainerMention = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":{\"taskKind\":\"issue-comment-reply\"},\"result\":{\"replyBody\":\"请 @Crownoth 看一下\"},\"needsHumanReview\":false}", jsonPlan)
        @Expect(forbiddenMaintainerMention.ok, false)
        @Expect(forbiddenMaintainerMention.status, "draft_contains_forbidden_maintainer_mention")
        @Expect(forbiddenMaintainerMention.needsHumanReview, true)

        let localPath = service.debugGitCodeGeneratedReplyResultForTest("{\"header\":\"h\",\"result\":\"/Users/name/private Authorization: Bearer secret\",\"safety\":\"approved\",\"needsHumanReview\":false}", jsonPlan)
        @Expect(localPath.ok, false)
        @Expect(localPath.diagnostic.contains("/Users/name"), false)
        @Expect(localPath.diagnostic.contains("secret"), false)

        let legacyPlan = GitCodeReviewPromptPlan(true, status: "legacy_fallback", prompt: "legacy prompt", route: "legacy", templateId: "legacy", source: "legacy", expectsJsonOutput: false)
        let legacy = service.debugGitCodeGeneratedReplyResultForTest("建议补充回归测试。", legacyPlan)
        @Expect(legacy.ok, true)
        @Expect(legacy.draft, "建议补充回归测试。")

        let plainReviewPlan = GitCodeReviewPromptPlan(true, status: "ok", prompt: "plain prompt", route: "issue_question", templateId: "issue_question", source: "builtin", expectsJsonOutput: false, needsHumanReview: true)
        let plainReview = service.debugGitCodeGeneratedReplyResultForTest("证据不足，建议维护者人工确认。", plainReviewPlan)
        @Expect(plainReview.ok, true)
        @Expect(plainReview.draft, "证据不足，建议维护者人工确认。")
        @Expect(plainReview.needsHumanReview, true)
    }

    @TestCase
    public func gatewayPendingAndWebhookDebugGenerationUsePlainDraftProductionPath(): Unit {
        gitCodePromptTestWithHome<Unit>("p3-prod-entries", { home: Path =>
            let promptDir = home.join("prompt")
            gitCodePromptTestWriteSixTemplates(promptDir, "PROMPT-P3")
            gitCodePromptTestInstallConfig(promptDir)
            let service = gitCodePromptTestService()
            service.debugLoadGitCodeReviewPromptRuntimeForTest()
            let event = gitCodePromptTestEvent("issue", issueKind: "bug", title: "bug", content: "复现")
            let raw = "建议补测试。"
            let pending = service.debugGenerateGitCodePendingReplyDraftForTest(event, raw)
            let webhook = service.debugGenerateGitCodeWebhookReplyDraftForTest(event, raw)
            @Expect(pending.ok, true)
            @Expect(webhook.ok, true)
            @Expect(pending.draft, "建议补测试。")
            @Expect(webhook.draft, "建议补测试。")

            let plan = service.debugBuildGitCodePromptPlanForTest(event)
            @Expect(plan.expectsJsonOutput, false)
            @Expect(plan.prompt.contains("只输出裸 JSON object"), false)
            @Expect(plan.prompt.contains("只输出可直接发送的中文回复草稿正文"), true)

            let badFence = service.debugGenerateGitCodeWebhookReplyDraftForTest(event, "```json\n{\"header\":\"结论\",\"result\":\"坏 fence\",\"safety\":\"approved\",\"needsHumanReview\":false}")
            @Expect(badFence.ok, false)
            @Expect(badFence.status, "draft_contains_forbidden_marker")
            @Expect(badFence.needsHumanReview, true)

            let fencedTool = service.debugGenerateGitCodeWebhookReplyDraftForTest(event, "```json\n{\"tool\":\"functions.answer\",\"reason\":\"x\"}\n```")
            @Expect(fencedTool.ok, false)
            @Expect(fencedTool.status, "draft_contains_forbidden_marker")
        })
    }
}
