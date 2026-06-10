package metis.gateway.gitcode_plugin

import std.unittest.testmacro.*

@Test
public class GitCodeReviewRouterTest {
    private func request(eventType!: String = "issue", issueKind!: String = "bug", diagnostics!: Array<String> = []): GitCodeReviewRequest {
        GitCodeReviewRequest(
            eventId: "gitcode:Cangjie/cangjie_tools:${eventType}:1",
            eventType: eventType,
            action: "open",
            repoFullName: "Cangjie/cangjie_tools",
            number: "1",
            url: if (eventType == "pr") { "https://gitcode.com/Cangjie/cangjie_tools/pulls/1" } else { "https://gitcode.com/Cangjie/cangjie_tools/issues/1" },
            title: "title",
            content: "body",
            issueKind: issueKind,
            cjcVersion: "cjc 1.0.0",
            branchVersions: ["main"],
            changedFiles: ["src/main.cj"],
            reviewFindings: ["src/main.cj: suspicious branch"],
            diagnostics: diagnostics
        )
    }

    @TestCase
    public func tRouter001BugIssueRoutesToBugTask(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "bug"))
        @Expect(route.ok, true)
        @Expect(route.route, "issue_bug")
        @Expect(route.task.taskType, "issue_bug")
    }

    @TestCase
    public func tRouter002FeatureRoutesToFeatureTask(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "feature-request"))
        @Expect(route.route, "issue_feature")
        @Expect(route.task.taskType, "issue_feature")
    }

    @TestCase
    public func tRouter003QuestionRoutesToQuestionTask(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "question"))
        @Expect(route.route, "issue_question")
        @Expect(route.task.taskType, "issue_question")
    }

    @TestCase
    public func tRouter004PrRoutesToReviewTask(): Unit {
        let route = routeGitCodeReviewRequest(this.request(eventType: "pr", issueKind: ""))
        @Expect(route.route, "pr_review")
        @Expect(route.task.taskType, "pr_review")
    }

    @TestCase
    public func tRouter005CommentOnPrRoutesToCommentReply(): Unit {
        let req = GitCodeReviewRequest(
            eventId: "comment-1",
            eventType: "comment",
            repoFullName: "Cangjie/cangjie_tools",
            number: "1",
            url: "https://gitcode.com/Cangjie/cangjie_tools/pulls/1#note_9",
            parentUrl: "https://gitcode.com/Cangjie/cangjie_tools/pulls/1",
            commentBody: "please explain"
        )
        let route = routeGitCodeReviewRequest(req)
        @Expect(route.route, "comment_reply")
        @Expect(route.task.parentKind, "pr")
    }

    @TestCase
    public func tRouter011CommentParentKindPrefersDiscussionContext(): Unit {
        let req = GitCodeReviewRequest(
            eventId: "comment-context-pr",
            eventType: "comment",
            repoFullName: "Cangjie/cangjie_tools",
            number: "7",
            url: "https://gitcode.com/Cangjie/cangjie_tools/issues/7#note_9",
            parentUrl: "https://gitcode.com/Cangjie/cangjie_tools/issues/7",
            commentBody: "please explain",
            hasDiscussionContext: true,
            discussionContext: GitCodeReviewDiscussionContext(
                parent: GitCodeReviewDiscussionParent(kind: "pr", number: "7", url: "https://gitcode.com/Cangjie/cangjie_tools/pulls/7"),
                triggerComment: GitCodeReviewDiscussionComment(id: "9", body: "please explain")
            )
        )
        let route = routeGitCodeReviewRequest(req)
        @Expect(route.route, "comment_reply")
        @Expect(route.task.parentKind, "pr")
        @Expect(route.task.requiresCodeReview, true)
    }

    @TestCase
    public func tRouter012MissingCommentContextDegradesWriteback(): Unit {
        let req = GitCodeReviewRequest(
            eventId: "comment-missing-context",
            eventType: "comment",
            repoFullName: "Cangjie/cangjie_tools",
            number: "8",
            url: "https://gitcode.com/Cangjie/cangjie_tools/issues/8#note_9",
            parentUrl: "https://gitcode.com/Cangjie/cangjie_tools/issues/8",
            commentBody: "please explain",
            diagnostics: ["comment_context_missing"]
        )
        let route = routeGitCodeReviewRequest(req)
        @Expect(route.route, "comment_reply")
        @Expect(route.degraded, true)
        @Expect(route.needsHumanReview, true)
        @Expect(route.allowWriteback, false)
    }

    @TestCase
    public func tRouter006UnknownIssueKindNeedsHumanReview(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "support"))
        @Expect(route.route, "issue_generic")
        @Expect(route.needsHumanReview, true)
    }

    @TestCase
    public func tRouter007CkbUnavailableQuestionIsDegraded(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "question", diagnostics: ["ckb_unavailable"]))
        @Expect(route.route, "issue_question")
        @Expect(route.degraded, true)
        @Expect(route.needsHumanReview, true)
    }

    @TestCase
    public func tRouter008BugTaskCarriesBranchCjcAndSourcePolicy(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "bug"))
        @Expect(route.task.taskBrief.contains("main"), true)
        @Expect(route.task.taskBrief.contains("cjc 1.0.0"), true)
        @Expect(route.task.requiresSourceWorkspace, true)
    }

    @TestCase
    public func tRouter009PrTaskCarriesReviewFindingsAndChangedFiles(): Unit {
        let route = routeGitCodeReviewRequest(this.request(eventType: "pr", issueKind: ""))
        @Expect(route.task.taskBrief.contains("src/main.cj"), true)
        @Expect(route.task.taskBrief.contains("suspicious branch"), true)
    }

    @TestCase
    public func tRouter010HandlerTimeoutDisablesWriteback(): Unit {
        let route = routeGitCodeReviewRequest(this.request(issueKind: "bug", diagnostics: ["handler_timeout"]))
        @Expect(route.status, "llm_degraded")
        @Expect(route.needsHumanReview, true)
        @Expect(route.allowWriteback, false)
    }
}
