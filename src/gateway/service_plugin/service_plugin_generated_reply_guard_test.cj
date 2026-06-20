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

    @TestCase
    public func draftM2U001GatewayAgentFailureIsLlmDegraded(): Unit {
        let result = servicePluginGeneratedReplyResultFromAgentAnswer("Gateway agent failed: timeout")

        @Expect(result.ok, false)
        @Expect(result.status, "llm_degraded")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM2B001EmptyAgentAnswerIsRejected(): Unit {
        let result = servicePluginGeneratedReplyResultFromAgentAnswer("")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_empty")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM2P001NormalChineseAgentAnswerPasses(): Unit {
        let result = servicePluginGeneratedReplyResultFromAgentAnswer("建议补充回归测试。")

        @Expect(result.ok, true)
        @Expect(result.status, "draft_generated")
        @Expect(result.draft, "建议补充回归测试。")
        @Expect(result.needsHumanReview, false)
    }

    @TestCase
    public func draftM2N001Pr1036ToolJsonAgentAnswerIsRejected(): Unit {
        let result = servicePluginGeneratedReplyResultFromAgentAnswer("{\"tool\":\"functions._answer_\",\"reason\":\"当前任务只需要输出中文回复草稿\"}")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_invalid_tool_json")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM3U001NormalizeRejectsToolJsonDraftResult(): Unit {
        // DRAFT-M3-U-001.
        let result = normalizeServicePluginGeneratedReplyResult(ServicePluginGeneratedReplyResult(true, status: "draft_generated", draft: "{\"tool\":\"functions._answer_\"}"))

        @Expect(result.ok, false)
        @Expect(result.status, "draft_invalid_tool_json")
        @Expect(result.draft, "")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func m3U001RejectsAnswerToolJsonEnvelope(): Unit {
        // M3-U-001.
        let result = validateServicePluginGeneratedDraft("{\"tool\":\"functions._answer_\",\"arguments\":{\"answer\":\"草稿\"}}")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_invalid_tool_json")
        @Expect(result.draft, "")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func m3U002RejectsCompleteJsonScalars(): Unit {
        // M3-U-002.
        let jsonString = validateServicePluginGeneratedDraft("\"这是一段被 JSON string 包裹的草稿\"")
        let jsonNumber = validateServicePluginGeneratedDraft("123")
        let jsonBool = validateServicePluginGeneratedDraft("true")
        let jsonNull = validateServicePluginGeneratedDraft("null")

        @Expect(jsonString.ok, false)
        @Expect(jsonString.status, "draft_raw_json_scalar")
        @Expect(jsonString.draft, "")
        @Expect(jsonString.needsHumanReview, true)
        @Expect(jsonNumber.ok, false)
        @Expect(jsonNumber.status, "draft_raw_json_scalar")
        @Expect(jsonBool.ok, false)
        @Expect(jsonBool.status, "draft_raw_json_scalar")
        @Expect(jsonNull.ok, false)
        @Expect(jsonNull.status, "draft_raw_json_scalar")
    }

    @TestCase
    public func m3B001RejectsMarkdownFencedJson(): Unit {
        // M3-B-001.
        let result = validateServicePluginGeneratedDraft("```json\n{\"draft\":\"建议补充测试\"}\n```")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_forbidden_marker")
        @Expect(result.draft, "")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func m3P001AcceptsChineseDraftWithListAndNonJsonCode(): Unit {
        // M3-P-001.
        let text = "建议这样处理：\n- 保留现有测试；\n- 补充边界用例。\n\n```cangjie\nmain() { println(\"ok\") }\n```"
        let result = validateServicePluginGeneratedDraft(text)

        @Expect(result.ok, true)
        @Expect(result.status, "draft_generated")
        @Expect(result.draft, text)
        @Expect(result.needsHumanReview, false)
    }

    @TestCase
    public func m3N001RejectsPlainTextToolMarkers(): Unit {
        // M3-N-001.
        let functionAnswer = validateServicePluginGeneratedDraft("functions._answer_ 已经生成草稿")
        let functionPlain = validateServicePluginGeneratedDraft("functions.answer 已经生成草稿")
        let quotedAnswer = validateServicePluginGeneratedDraft("\"_answer_\" 已经生成草稿")
        let snakeToolCall = validateServicePluginGeneratedDraft("tool_call 已经生成草稿")
        let camelToolCalls = validateServicePluginGeneratedDraft("toolCalls 已经生成草稿")

        @Expect(functionAnswer.ok, false)
        @Expect(functionAnswer.status, "draft_forbidden_marker")
        @Expect(functionPlain.ok, false)
        @Expect(functionPlain.status, "draft_forbidden_marker")
        @Expect(quotedAnswer.ok, false)
        @Expect(quotedAnswer.status, "draft_forbidden_marker")
        @Expect(snakeToolCall.ok, false)
        @Expect(snakeToolCall.status, "draft_forbidden_marker")
        @Expect(camelToolCalls.ok, false)
        @Expect(camelToolCalls.status, "draft_forbidden_marker")
    }

    @TestCase
    public func draftM5B001TerminalAnswerEnvelopeStillNeedsHumanReview(): Unit {
        // T5-B-001.
        let result = validateServicePluginGeneratedDraft("{\"name\":\"answer\",\"arguments\":{\"result\":\"建议补充测试。\"}}")

        @Expect(result.ok, false)
        @Expect(result.status, "draft_invalid_tool_json")
        @Expect(result.draft, "")
        @Expect(result.needsHumanReview, true)
    }

    @TestCase
    public func draftM5P001NormalChineseDraftStillPasses(): Unit {
        // T5-P-001.
        let result = validateServicePluginGeneratedDraft("建议补充中文回归测试，保持人工审核路径。")

        @Expect(result.ok, true)
        @Expect(result.status, "draft_generated")
        @Expect(result.draft, "建议补充中文回归测试，保持人工审核路径。")
        @Expect(result.needsHumanReview, false)
    }

    @TestCase
    public func draftM5N001ToolJsonRawJsonScalarAndFenceKeepStatuses(): Unit {
        // T5-N-001.
        let toolObject = validateServicePluginGeneratedDraft("{\"tool\":\"functions._answer_\",\"arguments\":{\"answer\":\"草稿\"}}")
        let toolArray = validateServicePluginGeneratedDraft("[{\"name\":\"session_status\",\"arguments\":{}}]")
        let rawObject = validateServicePluginGeneratedDraft("{\"draft\":\"建议补充测试\"}")
        let rawArray = validateServicePluginGeneratedDraft("[\"建议补充测试\"]")
        let rawScalar = validateServicePluginGeneratedDraft("\"建议补充测试\"")
        let jsonFence = validateServicePluginGeneratedDraft("```json\n{\"draft\":\"建议补充测试\"}\n```")

        @Expect(toolObject.ok, false)
        @Expect(toolObject.status, "draft_invalid_tool_json")
        @Expect(toolObject.needsHumanReview, true)
        @Expect(toolArray.ok, false)
        @Expect(toolArray.status, "draft_invalid_tool_json")
        @Expect(toolArray.needsHumanReview, true)
        @Expect(rawObject.ok, false)
        @Expect(rawObject.status, "draft_raw_json")
        @Expect(rawObject.needsHumanReview, true)
        @Expect(rawArray.ok, false)
        @Expect(rawArray.status, "draft_raw_json")
        @Expect(rawArray.needsHumanReview, true)
        @Expect(rawScalar.ok, false)
        @Expect(rawScalar.status, "draft_raw_json_scalar")
        @Expect(rawScalar.needsHumanReview, true)
        @Expect(jsonFence.ok, false)
        @Expect(jsonFence.status, "draft_forbidden_marker")
        @Expect(jsonFence.needsHumanReview, true)
    }
}
