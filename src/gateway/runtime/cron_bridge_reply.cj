package metis.gateway.runtime

import metis.gateway.core.{AgentBridge, GatewayExecutionControl, gatewayExecuteSessionRequestTurn}
import metis.gateway.session.{GatewaySessionRequest, GatewayTurnContext}
import magic.prelude.*

import std.core.Duration
import std.time.DateTime

/** 定时任务执行超时文案。 */
public let CRON_JOB_TIMEOUT_MESSAGE: String = "cron: job execution timed out"

public func cronBridgeEpochMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

public func cronBridgeReply(
    bridge: AgentBridge,
    request: GatewaySessionRequest,
    prompt: String,
    options: CronSessionExecutionOptions,
    executionControl: GatewayExecutionControl,
    turnContextOverride!: Option<GatewayTurnContext> = None<GatewayTurnContext>
): String {
    executionControl.throwIfCancelled()
    let out = gatewayExecuteSessionRequestTurn(
        bridge,
        request,
        prompt,
        timeoutSeconds: options.timeoutSeconds,
        bestEffortDeliver: options.bestEffortDeliver,
        turnContextOverride: turnContextOverride,
        executionControl: Some<GatewayExecutionControl>(executionControl)
    ).execution.answer
    executionControl.throwIfCancelled()
    out
}
