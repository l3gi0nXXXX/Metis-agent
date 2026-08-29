package metis.gateway.core

import metis.gateway.reply_guard.{GatewayAssistantReplyGuardResult, normalizeGatewayAssistantFinalReply}

public class GatewayAgentReplyOutcome {
    public let status: String
    public let text: String
    public let diagnosticCode: String
    public let recoverable: Bool
    public let explicitSilent: Bool
    public let modelAttempts: Int64
    public let toolExecutionObserved: Bool
    public var memoryTurnSequence: Int64 = -1
    public var memorySampled: Bool = false
    public var memoryBaselineRssKb: Int64 = -1

    public init(
        status: String,
        text!: String = "",
        diagnosticCode!: String = "",
        recoverable!: Bool = false,
        explicitSilent!: Bool = false,
        modelAttempts!: Int64 = 1,
        toolExecutionObserved!: Bool = false
    ) {
        this.status = status.trimAscii()
        this.text = text
        this.diagnosticCode = diagnosticCode.trimAscii()
        this.recoverable = recoverable
        this.explicitSilent = explicitSilent
        this.modelAttempts = modelAttempts
        this.toolExecutionObserved = toolExecutionObserved
    }
}

private func gatewayIsExplicitSilentFinalReply(raw: String): Bool {
    let normalized = raw.trimAscii().toAsciiLower()
    normalized == "<silent_reply>" || normalized == "silent_reply"
}

public func gatewayFinalOutcomeFromGuard(
    guard: GatewayAssistantReplyGuardResult,
    raw: String,
    modelAttempts!: Int64 = 1,
    toolExecutionObserved!: Bool = false
): GatewayAgentReplyOutcome {
    if (gatewayIsExplicitSilentFinalReply(raw)) {
        return GatewayAgentReplyOutcome(
            "explicit_silent",
            explicitSilent: true,
            modelAttempts: modelAttempts,
            toolExecutionObserved: toolExecutionObserved
        )
    }
    if (guard.ok) {
        return GatewayAgentReplyOutcome(
            "valid_text",
            text: guard.text,
            modelAttempts: modelAttempts,
            toolExecutionObserved: toolExecutionObserved
        )
    }
    if (guard.status == "empty" || guard.status == "terminal_answer_empty") {
        return GatewayAgentReplyOutcome(
            "incomplete",
            diagnosticCode: guard.status,
            modelAttempts: modelAttempts,
            toolExecutionObserved: toolExecutionObserved
        )
    }
    GatewayAgentReplyOutcome(
        "recoverable_tool_protocol",
        diagnosticCode: guard.status,
        recoverable: guard.needsRepair,
        modelAttempts: modelAttempts,
        toolExecutionObserved: toolExecutionObserved
    )
}

public func gatewayBuildFinalAnswerCorrectionPrompt(existingContext: String): String {
    """
只根据本轮对话中已经存在的上下文和已完成的工具结果，输出给用户的最终正文。
禁止调用任何工具，禁止输出工具名数组、tool_call、函数调用参数或协议帧。
如果不需要发送用户可见正文，只输出 <SILENT_REPLY>。

已有上下文：
${existingContext}
"""
}

public func gatewayRunFinalAnswerCorrection(
    initialRaw: String,
    registeredToolNames: Array<String>,
    correctionRunner: (String) -> String,
    toolExecutionObserved!: Bool = false,
    existingContext!: String = ""
): GatewayAgentReplyOutcome {
    let firstGuard = normalizeGatewayAssistantFinalReply(initialRaw, registeredToolNames: registeredToolNames)
    let first = gatewayFinalOutcomeFromGuard(
        firstGuard,
        initialRaw,
        toolExecutionObserved: toolExecutionObserved
    )
    if (!first.recoverable) {
        return first
    }
    let correctionContext = if (existingContext.isEmpty()) { initialRaw } else { existingContext }
    let correctedRaw = try {
        correctionRunner(gatewayBuildFinalAnswerCorrectionPrompt(correctionContext))
    } catch (_: Exception) {
        ""
    }
    let correctedGuard = normalizeGatewayAssistantFinalReply(correctedRaw, registeredToolNames: registeredToolNames)
    let corrected = gatewayFinalOutcomeFromGuard(
        correctedGuard,
        correctedRaw,
        modelAttempts: 2,
        toolExecutionObserved: toolExecutionObserved
    )
    if (corrected.status == "recoverable_tool_protocol") {
        return GatewayAgentReplyOutcome(
            "incomplete_tool_protocol",
            diagnosticCode: if (corrected.diagnosticCode.isEmpty()) { "tool_protocol" } else { corrected.diagnosticCode },
            modelAttempts: 2,
            toolExecutionObserved: toolExecutionObserved
        )
    }
    corrected
}
