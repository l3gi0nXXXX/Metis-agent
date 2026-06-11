package metis.gateway.core

import metis.core.model.CodexRuntimeSwitchResult

public class GatewayRuntimeCacheInvalidationDecision {
    public let shouldInvalidate: Bool
    public let sessionKey: String
    public let runtime: String
    public let reason: String

    public init(
        shouldInvalidate: Bool,
        sessionKey!: String = "",
        runtime!: String = "",
        reason!: String = ""
    ) {
        this.shouldInvalidate = shouldInvalidate
        this.sessionKey = sessionKey.trimAscii()
        this.runtime = runtime.trimAscii()
        this.reason = reason.trimAscii()
    }
}

public func gatewayRuntimeCacheInvalidationForSwitch(
    result: CodexRuntimeSwitchResult,
    sessionKey!: String = ""
): GatewayRuntimeCacheInvalidationDecision {
    if (!result.success || !result.mutated || !result.requiresCacheInvalidation) {
        return GatewayRuntimeCacheInvalidationDecision(false, sessionKey: sessionKey, runtime: result.newValue, reason: "not-needed")
    }
    GatewayRuntimeCacheInvalidationDecision(
        true,
        sessionKey: sessionKey,
        runtime: result.newValue,
        reason: "codex-runtime-switch"
    )
}
