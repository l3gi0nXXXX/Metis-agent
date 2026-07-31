package metis.gateway.outcome_tests

import std.unittest.testmacro.*
import std.fs.Path
import metis.gateway.core.*
import metis.gateway.session.{GatewayDeliveryTarget, GatewayIngressSource, GatewaySessionContext}

private class GatewayOutcomeTestCounter {
    public var value: Int64
    public init(value!: Int64 = 0) { this.value = value }
}

@Test
public class GatewayAgentReplyOutcomeTest {
    @TestCase
    public func c4U01ProtocolReplyGetsOneCorrectionWithoutToolReplay(): Unit {
        let bridge = AgentBridge(sessionStore: GatewaySessionStore(Path("."), enabled: false))
        setGatewayAgentBridgeFinalReplySequenceForTest(Some((
            ["[\"web_fetch\"]", "今日体育摘要"],
            ["web_fetch"],
            true
        )))
        try {
            let outcome = bridge.replyWithOutcome("c4-u-01", "生成摘要")
            @Expect(outcome.status, "valid_text")
            @Expect(outcome.text, "今日体育摘要")
            @Expect(outcome.modelAttempts, 2)
            @Expect(outcome.toolExecutionObserved, true)
            @Expect(bridge.getHistory("c4-u-01").size, 2)
            @Expect(bridge.getHistory("c4-u-01")[1], "assistant: 今日体育摘要")
            @Expect(bridge.getHistory("c4-u-01").contains("assistant: [\"web_fetch\"]"), false)
        } finally {
            setGatewayAgentBridgeFinalReplySequenceForTest(None<(Array<String>, Array<String>, Bool)>)
        }
    }

    @TestCase
    public func c4B01CorrectionIsBoundedAndUtf8Safe(): Unit {
        let repeatedCalls = GatewayOutcomeTestCounter(value: 1)
        let repeated = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String =>
                repeatedCalls.value += 1
                "[\"web_fetch\"]"
            }
        )
        @Expect(repeated.status, "incomplete_tool_protocol")
        @Expect(repeated.modelAttempts, 2)
        @Expect(repeatedCalls.value, 2)

        let empty = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String => "" }
        )
        @Expect(empty.status, "incomplete")
        @Expect(empty.modelAttempts, 2)

        let silent = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String => "<SILENT_REPLY>" }
        )
        @Expect(silent.status, "explicit_silent")
        @Expect(silent.explicitSilent, true)

        let longText = "中文😀" * 4096
        let utf8 = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String => longText }
        )
        @Expect(utf8.status, "valid_text")
        @Expect(utf8.text, longText)
        @Expect(utf8.text.toRuneArray().size, longText.toRuneArray().size)
    }

    @TestCase
    public func c4P01NormalTextKeepsHistoricalOneAttemptBehavior(): Unit {
        let bridge = AgentBridge(sessionStore: GatewaySessionStore(Path("."), enabled: false))
        setGatewayAgentBridgeFinalReplySequenceForTest(Some((
            ["正常中文正文😀"],
            ["web_fetch"],
            false
        )))
        try {
            let outcome = bridge.replyWithOutcome("c4-p-01", "正常问题")
            @Expect(outcome.status, "valid_text")
            @Expect(outcome.text, "正常中文正文😀")
            @Expect(outcome.modelAttempts, 1)
            @Expect(bridge.getHistory("c4-p-01")[1], "assistant: 正常中文正文😀")
        } finally {
            setGatewayAgentBridgeFinalReplySequenceForTest(None<(Array<String>, Array<String>, Bool)>)
        }
    }

    @TestCase
    public func c4N01FailedCorrectionKeepsSideEffectCountAndTypedStatus(): Unit {
        let bridge = AgentBridge(sessionStore: GatewaySessionStore(Path("."), enabled: false))
        setGatewayAgentBridgeFinalReplySequenceForTest(Some((
            ["[\"web_fetch\"]", "[\"web_fetch\"]"],
            ["web_fetch"],
            true
        )))
        try {
            let outcome = bridge.replyWithOutcome("c4-n-01", "执行副作用任务")
            @Expect(outcome.status, "incomplete_tool_protocol")
            @Expect(outcome.text, "")
            @Expect(outcome.modelAttempts, 2)
            @Expect(outcome.toolExecutionObserved, true)
            @Expect(bridge.getHistory("c4-n-01").size, 1)
            @Expect(bridge.getHistory("c4-n-01")[0], "user: 执行副作用任务")
        } finally {
            setGatewayAgentBridgeFinalReplySequenceForTest(None<(Array<String>, Array<String>, Bool)>)
        }

        setGatewayAgentBridgeFinalReplySequenceForTest(Some((
            ["渲染前的有效正文"],
            ["web_fetch"],
            false
        )))
        try {
            let context = GatewaySessionContext(
                GatewayIngressSource.Channel("telegram"),
                "telegram",
                "telegram",
                "c4-n-01-render",
                "main",
                deliveryTarget: Some(GatewayDeliveryTarget("telegram", "peer"))
            )
            let execution = gatewayExecuteSessionTurn(
                bridge,
                context,
                "测试渲染隔离",
                deliver: true,
                bestEffortDeliver: true,
                deliverHook: Some({
                    _channel: String,
                    _account: String,
                    _peer: String,
                    _text: String,
                    _replyTo: Option<String>,
                    _inThread: Bool => "message-id"
                }),
                finalRenderHook: Some({ _text: String =>
                    throw Exception("render failed")
                })
            )
            @Expect(execution.finalStatus, "valid_text")
            @Expect(execution.diagnosticCode, "")
            @Expect(execution.delivered, false)
            @Expect(execution.deliveryStatus, "best-effort-failed")
        } finally {
            setGatewayAgentBridgeFinalReplySequenceForTest(None<(Array<String>, Array<String>, Bool)>)
        }
    }
}
