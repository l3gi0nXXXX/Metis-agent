package metis.gateway.reply_guard

import std.unittest.testmacro.*

@Test
public class GatewayAssistantReplyGuardTest {
    private func repeatText(text: String, count: Int64): String {
        let out = StringBuilder()
        for (_ in 0..count) {
            out.append(text)
        }
        out.toString()
    }

    @TestCase
    public func terminalAnswerEnvelopeIsUnwrapped(): Unit {
        let result = normalizeGatewayAssistantFinalReply("{\"name\":\"answer\",\"arguments\":{\"result\":\"当前状态已获取成功\"}}")

        @Expect(result.ok, true)
        @Expect(result.status, "ok")
        @Expect(result.text, "当前状态已获取成功")
        @Expect(result.text.contains("\"arguments\""), false)
    }

    @TestCase
    public func finalAnswerToolEnvelopeIsUnwrapped(): Unit {
        let result = normalizeGatewayAssistantFinalReply("{\"tool\":\"final_answer\",\"answer\":\"当前模型路由为 openai-codex:gpt-5.5。\"}")

        @Expect(result.ok, true)
        @Expect(result.text, "当前模型路由为 openai-codex:gpt-5.5。")
        @Expect(result.text.contains("\"tool\""), false)
    }

    @TestCase
    public func nestedTerminalAnswerEnvelopeIsUnwrapped(): Unit {
        let result = normalizeGatewayAssistantFinalReply("{\"name\":\"_answer_\",\"arguments\":{\"result\":\"{\\\"tool\\\":\\\"final_answer\\\",\\\"answer\\\":\\\"嵌套文本🙂\\\"}\"}}")

        @Expect(result.ok, true)
        @Expect(result.text, "嵌套文本🙂")
    }

    @TestCase
    public func nonTerminalToolJsonIsBlockedForRepair(): Unit {
        let result = normalizeGatewayAssistantFinalReply("{\"name\":\"session_status\",\"arguments\":{}}")

        @Expect(result.ok, false)
        @Expect(result.status, "tool_protocol_json")
        @Expect(result.blocked, true)
        @Expect(result.needsRepair, true)
        @Expect(result.text, "")
        @Expect(result.diagnosticHash.startsWith("reply-"), true)
    }

    @TestCase
    public func harmonyToolLeakIsBlocked(): Unit {
        let result = normalizeGatewayAssistantFinalReply("assistant to=functions.exec_command {\"cmd\":\"date\"}")

        @Expect(result.ok, false)
        @Expect(result.status, "harmony_tool_leak")
        @Expect(result.text, "")
    }

    @TestCase
    public func visibleDeliveryUsesFallbackForBlockedFinal(): Unit {
        let result = normalizeGatewayAssistantVisibleTextForDelivery("{\"name\":\"session_status\",\"arguments\":{}}")

        @Expect(result.ok, true)
        @Expect(result.blocked, true)
        @Expect(result.text.contains("工具调用协议"), true)
        @Expect(result.text.contains("\"arguments\""), false)
    }

    @TestCase
    public func visiblePartialSuppressesBlockedProtocol(): Unit {
        let result = normalizeGatewayAssistantVisibleTextForDelivery("{\"name\":\"session_status\"", partial: true)

        @Expect(result.ok, false)
        @Expect(result.status, "tool_protocol_prefix")
        @Expect(result.text, "")
    }

    @TestCase
    public func toolXmlBlocksAreStrippedOutsideCodeFence(): Unit {
        let result = normalizeGatewayAssistantFinalReply("前文\n<tool_call>\n{\"name\":\"session_status\"}\n</tool_call>\n后文")

        @Expect(result.ok, true)
        @Expect(result.text, "前文\n后文")
        @Expect(result.text.contains("session_status"), false)
    }

    @TestCase
    public func toolXmlInsideCodeFenceIsPreserved(): Unit {
        let text = "示例：\n```json\n<tool_call>{\"name\":\"session_status\"}</tool_call>\n```"
        let result = normalizeGatewayAssistantFinalReply(text)

        @Expect(result.ok, true)
        @Expect(result.text, text)
    }

    @TestCase
    public func normalJsonExampleIsNotBlocked(): Unit {
        let text = "可以这样写：{\"ok\":true,\"message\":\"done\"}"
        let result = normalizeGatewayAssistantFinalReply(text)

        @Expect(result.ok, true)
        @Expect(result.text, text)
    }

    @TestCase
    public func utf8TerminalTextKeepsRuneBoundaries(): Unit {
        let longText = this.repeatText("中文🙂", 80)
        let raw = "{\"name\":\"answer\",\"arguments\":{\"result\":\"${longText}\"}}"
        let result = normalizeGatewayAssistantFinalReply(raw)

        @Expect(result.ok, true)
        @Expect(result.text, longText)
        @Expect(result.text.toRuneArray().size, longText.toRuneArray().size)
    }
}
