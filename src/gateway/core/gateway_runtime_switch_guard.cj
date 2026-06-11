package metis.gateway.core

import metis.core.model.{
    CodexAppServerBinaryCheck,
    CodexRuntimeSwitchResult,
    applyCodexRuntimeSwitch,
    parseCodexRuntimeSwitchArgs,
    renderCodexRuntimeSwitchResult
}
import metis.gateway.model.ChannelPolicyConfig

public class GatewayRuntimeSwitchGuardRequest {
    public let rawArgs: String
    public let channelPolicy: ChannelPolicyConfig
    public let senderId: String
    public let operatorScopes: Array<String>
    public let chatType: String
    public let currentRuntime: String
    public let binaryCheck: CodexAppServerBinaryCheck
    public let running: Bool
    public let readOnly: Bool
    public let sessionKey: String

    public init(
        rawArgs!: String = "",
        channelPolicy!: ChannelPolicyConfig = ChannelPolicyConfig(),
        senderId!: String = "",
        operatorScopes!: Array<String> = [],
        chatType!: String = "direct",
        currentRuntime!: String = "auto",
        binaryCheck!: CodexAppServerBinaryCheck = CodexAppServerBinaryCheck(false, status: "not-checked"),
        running!: Bool = false,
        readOnly!: Bool = false,
        sessionKey!: String = ""
    ) {
        this.rawArgs = rawArgs.trimAscii()
        this.channelPolicy = channelPolicy
        this.senderId = senderId.trimAscii()
        this.operatorScopes = operatorScopes
        this.chatType = chatType.trimAscii().toAsciiLower()
        this.currentRuntime = currentRuntime.trimAscii()
        this.binaryCheck = binaryCheck
        this.running = running
        this.readOnly = readOnly
        this.sessionKey = sessionKey.trimAscii()
    }
}

public class GatewayRuntimeSwitchGuardResult {
    public let allowed: Bool
    public let success: Bool
    public let status: String
    public let oldValue: String
    public let newValue: String
    public let mutated: Bool
    public let requiresCacheInvalidation: Bool
    public let message: String
    public let switchResult: Option<CodexRuntimeSwitchResult>
    public let cacheInvalidation: GatewayRuntimeCacheInvalidationDecision

    public init(
        allowed: Bool,
        success: Bool,
        status: String,
        oldValue!: String = "auto",
        newValue!: String = "auto",
        mutated!: Bool = false,
        requiresCacheInvalidation!: Bool = false,
        message!: String = "",
        switchResult!: Option<CodexRuntimeSwitchResult> = None<CodexRuntimeSwitchResult>,
        cacheInvalidation!: GatewayRuntimeCacheInvalidationDecision = GatewayRuntimeCacheInvalidationDecision(false)
    ) {
        this.allowed = allowed
        this.success = success
        this.status = status.trimAscii()
        this.oldValue = oldValue.trimAscii()
        this.newValue = newValue.trimAscii()
        this.mutated = mutated
        this.requiresCacheInvalidation = requiresCacheInvalidation
        this.message = message.trimAscii()
        this.switchResult = switchResult
        this.cacheInvalidation = cacheInvalidation
    }
}

private func gatewayRuntimeSwitchRejected(
    status: String,
    message: String,
    currentRuntime: String
): GatewayRuntimeSwitchGuardResult {
    GatewayRuntimeSwitchGuardResult(
        false,
        false,
        status,
        oldValue: currentRuntime,
        newValue: currentRuntime,
        message: message
    )
}

public func gatewayApplyRuntimeSwitchGuard(request: GatewayRuntimeSwitchGuardRequest): GatewayRuntimeSwitchGuardResult {
    let access = gatewayCheckSlashAccess(
        request.channelPolicy,
        request.chatType,
        request.senderId,
        "codex-runtime"
    )
    if (!access.allowed) {
        return gatewayRuntimeSwitchRejected(
            "slash-access-denied",
            gatewaySlashAccessDeniedMessage(access),
            request.currentRuntime
        )
    }

    let parsed = parseCodexRuntimeSwitchArgs(request.rawArgs)
    if (!parsed.errors.isEmpty()) {
        return GatewayRuntimeSwitchGuardResult(
            true,
            false,
            "invalid-args",
            oldValue: request.currentRuntime,
            newValue: request.currentRuntime,
            message: parsed.errors[0]
        )
    }

    match (parsed.desiredRuntime) {
        case Some(_) =>
            if (request.senderId.isEmpty()) {
                return GatewayRuntimeSwitchGuardResult(
                    true,
                    false,
                    "missing-identity",
                    oldValue: request.currentRuntime,
                    newValue: request.currentRuntime,
                    message: "Cannot change Codex runtime without sender identity."
                )
            }
            if (request.readOnly) {
                return GatewayRuntimeSwitchGuardResult(
                    true,
                    false,
                    "read-only",
                    oldValue: request.currentRuntime,
                    newValue: request.currentRuntime,
                    message: "Cannot change Codex runtime from a read-only Gateway context."
                )
            }
            if (request.running) {
                return GatewayRuntimeSwitchGuardResult(
                    true,
                    false,
                    "running",
                    oldValue: request.currentRuntime,
                    newValue: request.currentRuntime,
                    message: "Cannot change Codex runtime while a session or turn is running. Stop it or wait for it to finish first."
                )
            }
        case None => ()
    }

    let switchResult = applyCodexRuntimeSwitch(
        request.currentRuntime,
        parsed.desiredRuntime,
        binaryCheck: request.binaryCheck
    )
    let invalidation = gatewayRuntimeCacheInvalidationForSwitch(switchResult, sessionKey: request.sessionKey)
    GatewayRuntimeSwitchGuardResult(
        true,
        switchResult.success,
        switchResult.status,
        oldValue: switchResult.oldValue,
        newValue: switchResult.newValue,
        mutated: switchResult.mutated,
        requiresCacheInvalidation: switchResult.requiresCacheInvalidation,
        message: renderCodexRuntimeSwitchResult(switchResult),
        switchResult: Some(switchResult),
        cacheInvalidation: invalidation
    )
}
