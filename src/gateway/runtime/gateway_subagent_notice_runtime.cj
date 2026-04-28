package metis.gateway.runtime

import metis.core.gatewayRegisterSubagentNoticeEventHook

import std.sync.Mutex

private let gatewaySubagentNoticeEventRuntimeLock = Mutex()
private var gatewaySubagentNoticeEventRuntimeRegistered = false

public func gatewayEnsureSubagentNoticeEventPublisherRegistered(): Unit {
    synchronized(gatewaySubagentNoticeEventRuntimeLock) {
        if (gatewaySubagentNoticeEventRuntimeRegistered) {
            return
        }
        gatewayRegisterSubagentNoticeEventHook({ sessionKey, runId, status, notice =>
            gatewayServerPublishSubagentNoticeEvent(sessionKey, runId, status, notice)
        })
        gatewaySubagentNoticeEventRuntimeRegistered = true
    }
}

public func gatewayResetSubagentNoticeEventPublisherRegistration(): Unit {
    synchronized(gatewaySubagentNoticeEventRuntimeLock) {
        gatewaySubagentNoticeEventRuntimeRegistered = false
    }
}
