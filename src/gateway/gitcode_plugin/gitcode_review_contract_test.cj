package metis.gateway.gitcode_plugin

import std.unittest.testmacro.*

@Test
public class GitCodeReviewContractTest {
    private func repeatText(text: String, count: Int64): String {
        let out = StringBuilder()
        for (_ in 0..count) {
            out.append(text)
        }
        out.toString()
    }

    private func issueBugPayload(extra!: String = ""): String {
        "{" +
            "\"jobId\":\"webhook-d1\"," +
            "\"eventId\":\"gitcode:Cangjie/cangjie_tools:issue:123\"," +
            "\"repo\":\"Cangjie/cangjie_tools\"," +
            "\"kind\":\"issue\"," +
            "\"number\":\"123\"," +
            "\"author\":\"external_user\"," +
            "\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"," +
            "\"title\":\"[Bug]: build failed\"," +
            "\"content\":\"redacted compact legacy content\"," +
            "\"contractVersion\":\"gcm-metis-gitcode-review-v1\"," +
            "\"reviewRequest\":{" +
                "\"schemaVersion\":1," +
                "\"event\":{" +
                    "\"eventId\":\"gitcode:Cangjie/cangjie_tools:issue:123\"," +
                    "\"eventType\":\"issue\"," +
                    "\"action\":\"open\"," +
                    "\"repo\":{\"org\":\"Cangjie\",\"name\":\"cangjie_tools\",\"fullName\":\"Cangjie/cangjie_tools\",\"webUrl\":\"https://gitcode.com/Cangjie/cangjie_tools\"}," +
                    "\"item\":{\"number\":\"123\",\"title\":\"[Bug]: build failed\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"}," +
                    "\"comment\":{\"commentId\":\"\",\"body\":\"\",\"url\":\"\"}" +
                "}," +
                "\"author\":{\"login\":\"external_user\",\"decision\":\"process\"}," +
                "\"maintainers\":{\"teamLeaders\":[],\"codeowners\":[],\"teamLeaderStatus\":\"missing\",\"codeownerStatus\":\"not_applicable\",\"diagnostics\":[\"team_leader_missing\"]}," +
                "\"templates\":{\"issueKind\":\"bug\",\"fields\":{\"bugDescription\":\"build fails\",\"cjcVersion\":\"cjc 1.0.0\",\"branchVersions\":[\"main\"]},\"diagnostics\":[]}," +
                "\"pr\":{\"changedFiles\":[],\"reviewFindings\":[]}," +
                "\"policy\":{\"requiresCkb\":true,\"requiresSourceWorkspace\":true,\"requiresCodeReview\":false,\"writebackMode\":\"configured-by-gcm\"}," +
                "\"diagnostics\":[\"content_redacted\"]" +
                extra +
            "}" +
        "}"
    }

    private func prPayload(): String {
        this.issueBugPayload(
            extra: ",\"overrideEventType\":\"ignored\""
        ).replace("\"kind\":\"issue\"", "\"kind\":\"pr\"")
            .replace("\"eventType\":\"issue\"", "\"eventType\":\"pr\"")
            .replace("\"number\":\"123\"", "\"number\":\"99\"")
            .replace("\"issueKind\":\"bug\"", "\"issueKind\":\"\"")
            .replace("\"requiresCodeReview\":false", "\"requiresCodeReview\":true")
            .replace("\"changedFiles\":[]", "\"changedFiles\":[\"src/main.cj\"]")
            .replace("\"codeowners\":[]", "\"codeowners\":[{\"login\":\"owner\",\"mention\":\"@owner\"}]")
            .replace("/issues/123", "/pulls/99")
    }

    @TestCase
    public func tMetisContract001ParsesV1IssueBugAndValidates(): Unit {
        let parsed = parseGitCodeReviewRequest(this.issueBugPayload())
        @Expect(parsed.ok, true)
        @Expect(parsed.request.eventType, "issue")
        @Expect(parsed.request.issueKind, "bug")
        @Expect(parsed.request.repoFullName, "Cangjie/cangjie_tools")
        @Expect(validateGitCodeReviewRequest(parsed.request).ok, true)
    }

    @TestCase
    public func tMetisContract002And003InvalidPayloadRendersHumanDiagnostic(): Unit {
        let parsed = parseGitCodeReviewRequest("not-json")
        @Expect(parsed.ok, false)
        @Expect(parsed.status, "payload_decode_failed")
        let text = renderGitCodeReviewDiagnostic(parsed)
        @Expect(text.contains("GitCode review 请求无法解析"), true)
        @Expect(text.contains("\"ok\""), false)
        @Expect(text.contains("\"result\""), false)
    }

    @TestCase
    public func tMetisContract004MissingTeamLeaderIsDiagnosticButValid(): Unit {
        let parsed = parseGitCodeReviewRequest(this.issueBugPayload())
        @Expect(parsed.ok, true)
        @Expect(parsed.request.diagnostics.contains("team_leader_missing"), true)
        @Expect(parsed.request.needsHumanReview, false)
    }

    @TestCase
    public func tMetisContract005LegacyPayloadFallsBack(): Unit {
        let parsed = parseGitCodeReviewRequest("{\"jobId\":\"webhook-old\",\"eventId\":\"legacy-1\",\"repo\":\"Cangjie/cangjie_tools\",\"kind\":\"issue\",\"number\":\"7\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/7\",\"content\":\"legacy\"}")
        @Expect(parsed.ok, true)
        @Expect(parsed.request.legacy, true)
        @Expect(parsed.request.routeHint, "issue_generic")
    }

    @TestCase
    public func tMetisContract006RejectsTraversalRepo(): Unit {
        let parsed = parseGitCodeReviewRequest(this.issueBugPayload().replace("Cangjie/cangjie_tools", "../secret/repo"))
        @Expect(parsed.ok, false)
        @Expect(parsed.status, "repo_invalid")
    }

    @TestCase
    public func tMetisContract007MarksContentRedacted(): Unit {
        let parsed = parseGitCodeReviewRequest(this.issueBugPayload())
        @Expect(parsed.ok, true)
        @Expect(parsed.request.contentRedacted, true)
    }

    @TestCase
    public func tMetisContract008PrPreservesCodeownersOutsideDraft(): Unit {
        let parsed = parseGitCodeReviewRequest(this.prPayload())
        @Expect(parsed.ok, true)
        @Expect(parsed.request.eventType, "pr")
        @Expect(parsed.request.codeowners.contains("@owner"), true)
        @Expect(parsed.request.draftContext.contains("@owner"), false)
    }

    @TestCase
    public func tMetisContract009RejectsLocalPath(): Unit {
        let parsed = parseGitCodeReviewRequest(this.issueBugPayload(extra: ",\"leak\":\"/Users/name/private/worktree\""))
        @Expect(parsed.ok, false)
        @Expect(parsed.status, "payload_contains_local_path")
    }

    @TestCase
    public func tMetisContract010ParsesCommentContract(): Unit {
        let payload = this.issueBugPayload()
            .replace("\"kind\":\"issue\"", "\"kind\":\"comment\"")
            .replace("\"eventType\":\"issue\"", "\"eventType\":\"comment\"")
            .replace("\"commentId\":\"\",\"body\":\"\",\"url\":\"\"", "\"commentId\":\"9001\",\"body\":\"please explain\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/pulls/99#note_9001\"")
            .replace("\"item\":{\"number\":\"123\",\"title\":\"[Bug]: build failed\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/123\"}", "\"item\":{\"number\":\"99\",\"title\":\"PR title\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/pulls/99\"}")
        let parsed = parseGitCodeReviewRequest(payload)
        @Expect(parsed.ok, true)
        @Expect(parsed.request.eventType, "comment")
        @Expect(parsed.request.commentBody, "please explain")
        @Expect(parsed.request.parentUrl.contains("/pulls/99"), true)
    }

    @TestCase
    public func tMetisContract011UnicodeFieldTruncationDoesNotBreakUtf8(): Unit {
        let req = GitCodeReviewRequest(
            eventId: "gitcode:Cangjie/community:issue:3",
            eventType: "issue",
            repoFullName: "Cangjie/community",
            repoOrg: "Cangjie",
            repoName: "community",
            number: "3",
            url: "https://gitcode.com/Cangjie/community/issues/3",
            title: this.repeatText("中文🙂", 120),
            content: this.repeatText("复现步骤🙂", 900)
        )
        @Expect(req.title.contains("中文"), true)
        @Expect(req.content.contains("复现步骤"), true)
        @Expect(validateGitCodeReviewRequest(req).ok, true)
    }

    @TestCase
    public func tDiag008WebhookStatusRemainsHumanReadable(): Unit {
        let text = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"receiver\":\"running\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"queue\":{\"pending\":0,\"processing\":0,\"processed\":3,\"deadLetter\":0},\"dispatch\":{\"latestStatus\":\"generated_reply_delivered\",\"telegram\":1,\"feishu\":1,\"failed\":0},\"subscribers\":{\"total\":2,\"telegram\":1,\"feishu\":1},\"token\":\"must-not-show\"}")
        @Expect(text.contains("GitCode Webhook 状态"), true)
        @Expect(text.contains("投递"), true)
        @Expect(text.contains("\"status\""), false)
        @Expect(text.contains("must-not-show"), false)
    }
}
