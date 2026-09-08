package metis.gateway.outcome_tests

import std.unittest.testmacro.*
import std.fs.Path
import metis.gateway.core.*
import metis.gateway.session.{GatewayDeliveryTarget, GatewayIngressSource, GatewaySessionContext}

private class GatewayOutcomeTestCounter {
    public var value: Int64
    public init(value!: Int64 = 0) { this.value = value }
}

private class GatewayOutcomeC2Capture {
    public var builderCalls: Int64 = 0
    public var runnerCalls: Int64 = 0
    public var budget: Int64 = -1
    public var prompt: String = ""
    public var builderCompleted: Bool = false
    public var runnerObservedBuilderCompleted: Bool = false
}

@Test
public class GatewayAgentReplyOutcomeTest {
    @TestCase
    public func s2C2U1BudgetBuilderRunsOnlyForRecoverableAndSomeEmptyIsAuthoritative(): Unit {
        let normal = GatewayOutcomeC2Capture()
        let normalOutcome = gatewayRunFinalAnswerCorrection(
            "正常正文🙂",
            ["web_fetch"],
            { _prompt: String =>
                normal.runnerCalls += 1
                "must-not-run"
            },
            existingContextBuilder: Some({ _budget: Int64 =>
                normal.builderCalls += 1
                "must-not-build"
            })
        )
        @Expect(normalOutcome.status, "valid_text")
        @Expect(normalOutcome.modelAttempts, 1)
        @Expect(normal.builderCalls, 0)
        @Expect(normal.runnerCalls, 0)

        let recoverable = GatewayOutcomeC2Capture()
        let recoverableOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                recoverable.runnerCalls += 1
                recoverable.prompt = prompt
                recoverable.runnerObservedBuilderCompleted = recoverable.builderCompleted
                "修正正文🙂"
            },
            existingContext: "legacy-must-not-appear",
            existingContextBuilder: Some({ budget: Int64 =>
                recoverable.builderCalls += 1
                recoverable.budget = budget
                recoverable.builderCompleted = true
                "builder-context-中文"
            })
        )
        @Expect(recoverableOutcome.status, "valid_text")
        @Expect(recoverableOutcome.modelAttempts, 2)
        @Expect(recoverable.builderCalls, 1)
        @Expect(recoverable.runnerCalls, 1)
        @Expect(recoverable.runnerObservedBuilderCompleted, true)
        @Expect(recoverable.budget > 0, true)
        @Expect(recoverable.prompt.contains("builder-context-中文"), true)
        @Expect(recoverable.prompt.contains("legacy-must-not-appear"), false)
        @Expect(recoverable.prompt.size <= 64 * 1024, true)

        let empty = GatewayOutcomeC2Capture()
        let emptyOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                empty.runnerCalls += 1
                empty.prompt = prompt
                "empty-builder-corrected"
            },
            existingContext: "legacy-empty-fallback-must-not-appear",
            existingContextBuilder: Some({ budget: Int64 =>
                empty.builderCalls += 1
                empty.budget = budget
                ""
            })
        )
        @Expect(emptyOutcome.status, "valid_text")
        @Expect(empty.builderCalls, 1)
        @Expect(empty.runnerCalls, 1)
        @Expect(empty.prompt, gatewayBuildFinalAnswerCorrectionPrompt(""))
        @Expect(empty.prompt.contains("legacy-empty-fallback-must-not-appear"), false)
        @Expect(empty.prompt.contains("[\"web_fetch\"]"), false)
    }

    @TestCase
    public func s2C2B1CompletePromptIsClampedAtExactSixtyFourKiBUtf8Boundary(): Unit {
        let exact = GatewayOutcomeC2Capture()
        let exactOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                exact.runnerCalls += 1
                exact.prompt = prompt
                "exact-corrected"
            },
            existingContextBuilder: Some({ budget: Int64 =>
                exact.builderCalls += 1
                exact.budget = budget
                "x" * budget
            })
        )
        @Expect(exactOutcome.status, "valid_text")
        @Expect(exact.builderCalls, 1)
        @Expect(exact.runnerCalls, 1)
        @Expect(exact.prompt.size, 64 * 1024)

        let over = GatewayOutcomeC2Capture()
        let overOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                over.runnerCalls += 1
                over.prompt = prompt
                "over-corrected"
            },
            existingContextBuilder: Some({ budget: Int64 =>
                over.builderCalls += 1
                over.budget = budget
                "y" * (budget + 1)
            })
        )
        @Expect(overOutcome.status, "valid_text")
        @Expect(over.builderCalls, 1)
        @Expect(over.runnerCalls, 1)
        @Expect(over.prompt.size, 64 * 1024)

        let utf8 = GatewayOutcomeC2Capture()
        let utf8Outcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                utf8.runnerCalls += 1
                utf8.prompt = prompt
                "utf8-corrected"
            },
            existingContextBuilder: Some({ budget: Int64 =>
                utf8.builderCalls += 1
                utf8.budget = budget
                ("z" * (budget - 3)) + "🙂"
            })
        )
        @Expect(utf8Outcome.status, "valid_text")
        @Expect(utf8.builderCalls, 1)
        @Expect(utf8.runnerCalls, 1)
        @Expect(utf8.prompt, gatewayBuildFinalAnswerCorrectionPrompt("z" * (utf8.budget - 3)))
        @Expect(utf8.prompt.contains("�"), false)

        let largeCorrected = "修🙂" * 24000
        let largeOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String => largeCorrected },
            existingContextBuilder: Some({ _budget: Int64 => "bounded-context" })
        )
        @Expect(Int64(largeCorrected.size) > 64 * 1024, true)
        @Expect(largeOutcome.status, "valid_text")
        @Expect(largeOutcome.text, largeCorrected)
        @Expect(Int64(largeOutcome.text.size), Int64(largeCorrected.size))
    }

    @TestCase
    public func s2C2P1LegacyExistingContextRemainsCompatibleAndBounded(): Unit {
        let legacy = GatewayOutcomeC2Capture()
        let outcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                legacy.runnerCalls += 1
                legacy.prompt = prompt
                "legacy-corrected"
            },
            toolExecutionObserved: true,
            existingContext: "legacy-context-中文🙂"
        )
        @Expect(outcome.status, "valid_text")
        @Expect(outcome.text, "legacy-corrected")
        @Expect(outcome.modelAttempts, 2)
        @Expect(outcome.toolExecutionObserved, true)
        @Expect(legacy.runnerCalls, 1)
        @Expect(legacy.prompt.contains("legacy-context-中文🙂"), true)
        @Expect(legacy.prompt.size <= 64 * 1024, true)

        let contextBudget = Int64(64 * 1024 - gatewayBuildFinalAnswerCorrectionPrompt("").size)
        let boundary = GatewayOutcomeC2Capture()
        let boundaryOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { prompt: String =>
                boundary.runnerCalls += 1
                boundary.prompt = prompt
                "legacy-boundary-corrected"
            },
            existingContext: ("x" * (contextBudget - 1)) + "🙂tail"
        )
        @Expect(boundaryOutcome.status, "valid_text")
        @Expect(boundary.runnerCalls, 1)
        @Expect(boundary.prompt.size <= 64 * 1024, true)
        @Expect(boundary.prompt, gatewayBuildFinalAnswerCorrectionPrompt("x" * (contextBudget - 1)))
        @Expect(boundary.prompt.contains("🙂"), false)
        @Expect(boundary.prompt.contains("�"), false)
    }

    @TestCase
    public func s2C2N1BuilderAndRunnerFailureKeepDistinctTypedAttemptTruth(): Unit {
        let builderFailure = GatewayOutcomeC2Capture()
        let builderOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String =>
                builderFailure.runnerCalls += 1
                "must-not-run"
            },
            toolExecutionObserved: true,
            existingContextBuilder: Some({ budget: Int64 =>
                builderFailure.builderCalls += 1
                builderFailure.budget = budget
                throw Exception("s2_c2_builder_failure")
            })
        )
        @Expect(builderOutcome.status, "incomplete_tool_protocol")
        @Expect(builderOutcome.diagnosticCode, "tool_name_array_protocol")
        @Expect(builderOutcome.modelAttempts, 1)
        @Expect(builderOutcome.toolExecutionObserved, true)
        @Expect(builderFailure.builderCalls, 1)
        @Expect(builderFailure.runnerCalls, 0)

        let runnerFailure = GatewayOutcomeC2Capture()
        let runnerOutcome = gatewayRunFinalAnswerCorrection(
            "[\"web_fetch\"]",
            ["web_fetch"],
            { _prompt: String =>
                runnerFailure.runnerCalls += 1
                throw Exception("s2_c2_runner_failure")
            },
            toolExecutionObserved: true,
            existingContextBuilder: Some({ budget: Int64 =>
                runnerFailure.builderCalls += 1
                runnerFailure.budget = budget
                "runner-context"
            })
        )
        @Expect(runnerOutcome.status, "incomplete")
        @Expect(runnerOutcome.diagnosticCode, "empty")
        @Expect(runnerOutcome.modelAttempts, 2)
        @Expect(runnerOutcome.toolExecutionObserved, true)
        @Expect(runnerFailure.builderCalls, 1)
        @Expect(runnerFailure.runnerCalls, 1)
    }

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
