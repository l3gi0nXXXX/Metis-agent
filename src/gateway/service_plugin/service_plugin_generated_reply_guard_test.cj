package metis.gateway.service_plugin

import std.unittest.testmacro.*

@Test
public class ServicePluginGeneratedReplyGuardTest {
    @TestCase
    public func draftM1U001NormalChineseDraftPasses(): Unit {
        let result = validateServicePluginGeneratedDraft("建议补充回归测试。")

        @Expect(result.ok, true)
        @Expect(result.status, "draft_generated")
        @Expect(result.draft, "建议补充回归测试。")
        @Expect(result.needsHumanReview, false)
    }

    @TestCase
    public func draftM1U002Pr1036ToolJsonIsRejected(): Unit {
        let result = servicePluginGeneratedReplyResultFromAgentAnswer("{\"tool\":\"functions._answer_\",\"reason\":\"当前任务只需要输出中文回复草稿\"}")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_invalid_tool_json")
        @Expect(result.draft, "")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM1B001BlankDraftIsRejected(): Unit {
        let result = validateServicePluginGeneratedDraft("   \n\t ")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_empty")
        @Expect(result.draft, "")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM1B002JsonArrayIsRejectedAsRawJson(): Unit {
        let result = validateServicePluginGeneratedDraft("[\"草稿\"]")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_raw_json")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM1P001CodeSnippetDraftPasses(): Unit {
        let text = "建议补充测试：main() { println(\"ok\") }"
        let result = validateServicePluginGeneratedDraft(text)

        @Expect(result.ok, true)
        @Expect(result.status, "draft_generated")
        @Expect(result.draft, text)
    }

    @TestCase
    public func draftM1N001SecretDraftIsRejectedWithoutLeakingDiagnostic(): Unit {
        let result = validateServicePluginGeneratedDraft("Authorization: Bearer secret")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_contains_secret")
        @Expect(result.needsHumanReview, true)
        @Expect(result.diagnostic.contains("secret"), false)
    }

    @TestCase
    public func draftM1N002LocalPathDraftIsRejectedWithoutLeakingDiagnostic(): Unit {
        let result = validateServicePluginGeneratedDraft("/Users/l3gi0n/work/private")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_contains_local_path")
        @Expect(result.needsHumanReview, true)
        @Expect(result.diagnostic.contains("/Users/l3gi0n/work/private"), false)
    }

    @TestCase
    public func draftM1N003ForbiddenMarkerDraftIsRejected(): Unit {
        let result = validateServicePluginGeneratedDraft("auto-reply by gitcodemonitor")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_forbidden_marker")
        @Expect(result.needsHumanReview, true)
    }
}
