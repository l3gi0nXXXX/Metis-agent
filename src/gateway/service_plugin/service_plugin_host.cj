package metis.gateway.service_plugin

import std.collection.{ArrayList, HashMap, HashSet}

public class ServicePluginConfigRef {
    public let configPath: String
    public let secretRef: String

    public init(configPath!: String = "", secretRef!: String = "") {
        this.configPath = configPath.trimAscii()
        this.secretRef = secretRef.trimAscii()
    }

    public func redacted(): String {
        if (!secretRef.isEmpty()) {
            return "configPath=present secretRef=present"
        }
        if (!configPath.isEmpty()) {
            return "configPath=present secretRef=absent"
        }
        "configPath=absent secretRef=absent"
    }
}

public class ServicePluginRegistration {
    public let manifest: ServicePluginManifest
    public let configRef: ServicePluginConfigRef
    public let enabled: Bool
    public let grants: Array<String>

    public init(
        manifest: ServicePluginManifest,
        configRef!: ServicePluginConfigRef = ServicePluginConfigRef(),
        enabled!: Bool = true,
        grants!: Array<String> = []
    ) {
        this.manifest = manifest
        this.configRef = configRef
        this.enabled = enabled
        this.grants = grants
    }
}

public class ServicePluginListFilter {
    public let status: String
    public init(status!: String = "") {
        this.status = status.trimAscii()
    }
}

public class ServicePluginSnapshot {
    public let serviceId: String
    public let displayName: String
    public let status: String
    public let degradedReason: String
    public let enabled: Bool
    public let configSummary: String
    public let capabilityIds: Array<String>
    public let lastHeartbeatAtMillis: Int64
    public let instanceId: String

    public init(
        serviceId: String,
        displayName: String,
        status: String,
        degradedReason!: String = "",
        enabled!: Bool = true,
        configSummary!: String = "",
        capabilityIds!: Array<String> = [],
        lastHeartbeatAtMillis!: Int64 = -1,
        instanceId!: String = ""
    ) {
        this.serviceId = serviceId
        this.displayName = displayName
        this.status = status
        this.degradedReason = degradedReason
        this.enabled = enabled
        this.configSummary = configSummary
        this.capabilityIds = capabilityIds
        this.lastHeartbeatAtMillis = lastHeartbeatAtMillis
        this.instanceId = instanceId
    }
}

public class ServicePluginRegistrationResult {
    public let ok: Bool
    public let status: String
    public let serviceId: String
    public let diagnostics: Array<String>
    public let snapshot: ServicePluginSnapshot

    public init(
        ok: Bool,
        status: String,
        serviceId!: String = "",
        diagnostics!: Array<String> = [],
        snapshot!: ServicePluginSnapshot = ServicePluginSnapshot("", "", "missing")
    ) {
        this.ok = ok
        this.status = status
        this.serviceId = serviceId
        this.diagnostics = diagnostics
        this.snapshot = snapshot
    }
}

public class CapabilityCaller {
    public let callerId: String
    public let grantedHostApis: Array<String>
    public let isOperator: Bool

    public init(callerId!: String = "gateway", grantedHostApis!: Array<String> = [], isOperator!: Bool = false) {
        this.callerId = callerId.trimAscii()
        this.grantedHostApis = grantedHostApis
        this.isOperator = isOperator
    }
}

public class CapabilityRouteResult {
    public let ok: Bool
    public let capabilityId: String
    public let serviceId: String
    public let status: String
    public let diagnostics: Array<String>

    public init(ok: Bool, capabilityId: String, serviceId!: String = "", status!: String = "ok", diagnostics!: Array<String> = []) {
        this.ok = ok
        this.capabilityId = capabilityId
        this.serviceId = serviceId
        this.status = status
        this.diagnostics = diagnostics
    }
}

public class CapabilityRouteResolution {
    public let ok: Bool
    public let capabilityId: String
    public let serviceId: String
    public let status: String
    public let reason: String
    public let record: ServiceCapabilityRecord

    public init(
        ok: Bool,
        capabilityId: String,
        serviceId!: String = "",
        status!: String = "ok",
        reason!: String = "",
        record!: ServiceCapabilityRecord = ServiceCapabilityRecord("", "")
    ) {
        this.ok = ok
        this.capabilityId = capabilityId
        this.serviceId = serviceId
        this.status = status
        this.reason = reason
        this.record = record
    }
}

public class CapabilityInvokeRequest {
    public let capabilityId: String
    public let payload: String
    public let caller: CapabilityCaller
    public let timeoutMillis: Int64

    public init(capabilityId: String, payload!: String = "{}", caller!: CapabilityCaller = CapabilityCaller(), timeoutMillis!: Int64 = 30000) {
        this.capabilityId = capabilityId.trimAscii()
        this.payload = payload
        this.caller = caller
        this.timeoutMillis = timeoutMillis
    }
}

public class CapabilityInvokeResult {
    public let ok: Bool
    public let status: String
    public let serviceId: String
    public let capabilityId: String
    public let payload: String
    public let diagnostic: String

    public init(ok: Bool, status: String, serviceId!: String = "", capabilityId!: String = "", payload!: String = "{}", diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.serviceId = serviceId
        this.capabilityId = capabilityId
        this.payload = payload
        this.diagnostic = diagnostic
    }
}

public class ServiceStartContext {
    public let nowMillis: Int64
    public init(nowMillis!: Int64 = 0) {
        this.nowMillis = nowMillis
    }
}

public class ServiceStartResult {
    public let ok: Bool
    public let serviceId: String
    public let status: String
    public let instanceId: String
    public let diagnostic: String

    public init(ok: Bool, serviceId: String, status: String, instanceId!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.serviceId = serviceId
        this.status = status
        this.instanceId = instanceId
        this.diagnostic = diagnostic
    }
}

public class ServiceStopResult {
    public let ok: Bool
    public let serviceId: String
    public let status: String
    public let stateFlushed: Bool
    public let diagnostic: String

    public init(ok: Bool, serviceId: String, status: String, stateFlushed!: Bool = false, diagnostic!: String = "") {
        this.ok = ok
        this.serviceId = serviceId
        this.status = status
        this.stateFlushed = stateFlushed
        this.diagnostic = diagnostic
    }
}

public class ServiceRestartResult {
    public let ok: Bool
    public let serviceId: String
    public let status: String
    public let previousInstanceId: String
    public let instanceId: String
    public let diagnostic: String

    public init(ok: Bool, serviceId: String, status: String, previousInstanceId!: String = "", instanceId!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.serviceId = serviceId
        this.status = status
        this.previousInstanceId = previousInstanceId
        this.instanceId = instanceId
        this.diagnostic = diagnostic
    }
}

public class ServicePluginStatus {
    public let serviceId: String
    public let status: String
    public let degradedReason: String
    public let running: Bool

    public init(serviceId: String, status: String, degradedReason!: String = "", running!: Bool = false) {
        this.serviceId = serviceId
        this.status = status
        this.degradedReason = degradedReason
        this.running = running
    }
}

public class HeartbeatProbeResult {
    public let ok: Bool
    public let serviceId: String
    public let status: String
    public let frame: ServiceFrame

    public init(ok: Bool, serviceId: String, status: String, frame!: ServiceFrame = ServiceFrame("", "", "")) {
        this.ok = ok
        this.serviceId = serviceId
        this.status = status
        this.frame = frame
    }
}

public class HeartbeatHandleResult {
    public let ok: Bool
    public let serviceId: String
    public let status: String
    public let diagnostic: String

    public init(ok: Bool, serviceId: String, status: String, diagnostic!: String = "") {
        this.ok = ok
        this.serviceId = serviceId
        this.status = status
        this.diagnostic = diagnostic
    }
}

public class ServiceHealth {
    public let status: String
    public let reason: String
    public init(status: String, reason!: String = "") {
        this.status = status.trimAscii()
        this.reason = reason.trimAscii()
    }
}

public class ServiceEventReadResult {
    public let ok: Bool
    public let status: String
    public let frame: ServiceFrame
    public let diagnostic: String

    public init(ok: Bool, status: String, frame!: ServiceFrame = ServiceFrame("", "", ""), diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.frame = frame
        this.diagnostic = diagnostic
    }
}

public class ServiceCapabilityEvent {
    public let serviceId: String
    public let capabilityId: String
    public let payload: String

    public init(serviceId: String, capabilityId: String, payload!: String = "{}") {
        this.serviceId = serviceId.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.payload = payload
    }
}

public class CapabilityEventHandleResult {
    public let ok: Bool
    public let status: String
    public let serviceId: String
    public let capabilityId: String
    public let diagnostic: String

    public init(ok: Bool, status: String, serviceId!: String = "", capabilityId!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.serviceId = serviceId
        this.capabilityId = capabilityId
        this.diagnostic = diagnostic
    }
}

public class ServiceHostApiRequest {
    public let serviceId: String
    public let hostApi: String
    public let payload: String

    public init(serviceId: String, hostApi: String, payload!: String = "{}") {
        this.serviceId = serviceId.trimAscii()
        this.hostApi = hostApi.trimAscii()
        this.payload = payload
    }
}

public class ServiceHostApiResult {
    public let ok: Bool
    public let status: String
    public let hostApi: String
    public let payload: String
    public let diagnostic: String

    public init(ok: Bool, status: String, hostApi!: String = "", payload!: String = "{}", diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.hostApi = hostApi
        this.payload = payload
        this.diagnostic = diagnostic
    }
}

public class ServicePluginControlSnapshot {
    public let plugins: ArrayList<ServicePluginSnapshot>
    public init(plugins: ArrayList<ServicePluginSnapshot>) {
        this.plugins = plugins
    }
}

public class ServicePluginControlAction {
    public let action: String
    public let serviceId: String
    public let capabilityId: String
    public let payload: String
    public let caller: CapabilityCaller

    public init(action: String, serviceId!: String = "", capabilityId!: String = "", payload!: String = "{}", caller!: CapabilityCaller = CapabilityCaller()) {
        this.action = action.trimAscii()
        this.serviceId = serviceId.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.payload = payload
        this.caller = caller
    }
}

public class ServicePluginControlResult {
    public let ok: Bool
    public let status: String
    public let message: String
    public let snapshot: ServicePluginSnapshot
    public let invokeResult: CapabilityInvokeResult

    public init(
        ok: Bool,
        status: String,
        message!: String = "",
        snapshot!: ServicePluginSnapshot = ServicePluginSnapshot("", "", "missing"),
        invokeResult!: CapabilityInvokeResult = CapabilityInvokeResult(false, "not_invoked")
    ) {
        this.ok = ok
        this.status = status
        this.message = message
        this.snapshot = snapshot
        this.invokeResult = invokeResult
    }
}

private class ServicePluginRuntimeRecord {
    public let registration: ServicePluginRegistration
    public var status: String
    public var degradedReason: String
    public var lastHeartbeatAtMillis: Int64
    public var instanceSeq: Int64
    public var instanceId: String
    public var stateFlushed: Bool
    public let eventFrames: ArrayList<ServiceFrame>

    public init(registration: ServicePluginRegistration) {
        this.registration = registration
        this.status = if (registration.enabled) { "registered" } else { "disabled" }
        this.degradedReason = if (registration.enabled) { "" } else { "plugin disabled" }
        this.lastHeartbeatAtMillis = -1
        this.instanceSeq = 0
        this.instanceId = ""
        this.stateFlushed = false
        this.eventFrames = ArrayList<ServiceFrame>()
    }
}

private var servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
private var serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()

public func resetServicePluginHostForTest(): Unit {
    servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
    serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()
}

public func registerServicePlugin(registration: ServicePluginRegistration): ServicePluginRegistrationResult {
    let manifestValidation = validateServicePluginManifest(registration.manifest)
    let serviceId = registration.manifest.pluginId
    if (!manifestValidation.ok) {
        let snapshot = ServicePluginSnapshot(serviceId, registration.manifest.displayName, "setup-required", degradedReason: serviceJoinStrings(manifestValidation.diagnostics, ", "))
        return ServicePluginRegistrationResult(false, "setup-required", serviceId: serviceId, diagnostics: manifestValidation.diagnostics, snapshot: snapshot)
    }
    if (servicePluginRegistry.contains(serviceId)) {
        return ServicePluginRegistrationResult(false, "conflict", serviceId: serviceId, diagnostics: ["service plugin already registered: ${serviceId}"])
    }
    let record = ServicePluginRuntimeRecord(registration)
    servicePluginRegistry[serviceId] = record
    for (capability in registration.manifest.capabilityDeclarations) {
        let _ = registerCapabilityRoute(serviceId, capability)
    }
    ServicePluginRegistrationResult(true, record.status, serviceId: serviceId, snapshot: serviceSnapshot(record))
}

public func listServicePlugins(filter!: ServicePluginListFilter = ServicePluginListFilter()): ArrayList<ServicePluginSnapshot> {
    let out = ArrayList<ServicePluginSnapshot>()
    for ((_, record) in servicePluginRegistry) {
        if (filter.status.isEmpty() || record.status == filter.status) {
            out.add(serviceSnapshot(record))
        }
    }
    out
}

public func getServicePluginSnapshot(serviceId: String): ?ServicePluginSnapshot {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) => Some(serviceSnapshot(record))
        case None => None<ServicePluginSnapshot>
    }
}

public func registerCapabilityRoute(serviceId: String, record: ServiceCapabilityRecord): CapabilityRouteResult {
    let sid = serviceId.trimAscii()
    if (!servicePluginRegistry.contains(sid)) {
        return CapabilityRouteResult(false, record.capabilityId, serviceId: sid, status: "service_missing", diagnostics: ["service plugin is not registered"])
    }
    let validation = validateCapabilityRecord(record)
    if (!validation.ok) {
        return CapabilityRouteResult(false, record.capabilityId, serviceId: sid, status: "invalid_capability", diagnostics: validation.diagnostics)
    }
    if (serviceCapabilityRoutes.contains(record.capabilityId)) {
        let existing = serviceCapabilityRoutes[record.capabilityId]
        if (existing[0] != sid) {
            return CapabilityRouteResult(false, record.capabilityId, serviceId: sid, status: "route_conflict", diagnostics: ["capability route already owned by ${existing[0]}"])
        }
    }
    serviceCapabilityRoutes[record.capabilityId] = (sid, record)
    CapabilityRouteResult(true, record.capabilityId, serviceId: sid)
}

public func resolveCapabilityRoute(capabilityId: String, caller: CapabilityCaller): CapabilityRouteResolution {
    let id = capabilityId.trimAscii()
    match (serviceCapabilityRoutes.get(id)) {
        case Some(route) =>
            let serviceId = route[0]
            let record = route[1]
            match (servicePluginRegistry.get(serviceId)) {
                case Some(plugin) =>
                    if (!plugin.registration.enabled || plugin.status == "disabled") {
                        return CapabilityRouteResolution(false, id, serviceId: serviceId, status: "service_disabled", reason: "service plugin is disabled", record: record)
                    }
                    for (required in record.requiredHostApis) {
                        if (!serviceArrayContains(caller.grantedHostApis, required)) {
                            return CapabilityRouteResolution(false, id, serviceId: serviceId, status: "missing_grant", reason: "caller missing grant: ${required}", record: record)
                        }
                    }
                    CapabilityRouteResolution(true, id, serviceId: serviceId, record: record)
                case None => CapabilityRouteResolution(false, id, status: "service_missing", reason: "registered route points to missing service", record: record)
            }
        case None => CapabilityRouteResolution(false, id, status: "capability_missing", reason: "capability route is not registered")
    }
}

public func invokeRegisteredCapability(request: CapabilityInvokeRequest): CapabilityInvokeResult {
    let resolution = resolveCapabilityRoute(request.capabilityId, request.caller)
    if (!resolution.ok) {
        return CapabilityInvokeResult(false, resolution.status, serviceId: resolution.serviceId, capabilityId: request.capabilityId, diagnostic: resolution.reason)
    }
    let frame = ServiceFrame(
        "request",
        "invoke-${request.capabilityId}",
        resolution.serviceId,
        method: "invokeCapability",
        capabilityId: request.capabilityId,
        payload: request.payload
    )
    let limit = enforceServiceFrameLimits(frame)
    if (!limit.ok) {
        return CapabilityInvokeResult(false, limit.reason, serviceId: resolution.serviceId, capabilityId: request.capabilityId, diagnostic: limit.payloadHash)
    }
    CapabilityInvokeResult(true, "queued", serviceId: resolution.serviceId, capabilityId: request.capabilityId, payload: redactServicePayload(request.payload).text)
}

public func startServicePlugin(serviceId: String, context!: ServiceStartContext = ServiceStartContext()): ServiceStartResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            if (!record.registration.enabled) {
                record.status = "disabled"
                record.degradedReason = "plugin disabled"
                return ServiceStartResult(false, serviceId.trimAscii(), "disabled", diagnostic: record.degradedReason)
            }
            if (record.registration.manifest.entryCommand.isEmpty()) {
                record.status = "degraded"
                record.degradedReason = "missing entry command"
                return ServiceStartResult(false, serviceId.trimAscii(), "degraded", diagnostic: record.degradedReason)
            }
            record.instanceSeq++
            record.instanceId = "${serviceId.trimAscii()}-${record.instanceSeq}"
            record.status = "running"
            record.degradedReason = ""
            record.lastHeartbeatAtMillis = context.nowMillis
            record.stateFlushed = false
            ServiceStartResult(true, serviceId.trimAscii(), "running", instanceId: record.instanceId)
        case None => ServiceStartResult(false, serviceId.trimAscii(), "missing", diagnostic: "service plugin is not registered")
    }
}

public func stopServicePlugin(serviceId: String, reason!: String = "", timeoutMillis!: Int64 = 30000): ServiceStopResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            if (timeoutMillis <= 0) {
                record.status = "degraded"
                record.degradedReason = "stop timeout"
                return ServiceStopResult(false, serviceId.trimAscii(), "degraded", diagnostic: record.degradedReason)
            }
            record.status = "stopped"
            record.degradedReason = reason.trimAscii()
            record.stateFlushed = true
            ServiceStopResult(true, serviceId.trimAscii(), "stopped", stateFlushed: true)
        case None => ServiceStopResult(false, serviceId.trimAscii(), "missing", diagnostic: "service plugin is not registered")
    }
}

public func restartServicePlugin(serviceId: String, reason!: String = ""): ServiceRestartResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            let previous = record.instanceId
            let stopped = stopServicePlugin(serviceId, reason: reason)
            if (!stopped.ok) {
                return ServiceRestartResult(false, serviceId.trimAscii(), stopped.status, previousInstanceId: previous, diagnostic: stopped.diagnostic)
            }
            let started = startServicePlugin(serviceId)
            ServiceRestartResult(started.ok, serviceId.trimAscii(), started.status, previousInstanceId: previous, instanceId: started.instanceId, diagnostic: started.diagnostic)
        case None => ServiceRestartResult(false, serviceId.trimAscii(), "missing", diagnostic: "service plugin is not registered")
    }
}

public func queryServicePluginStatus(serviceId: String): ServicePluginStatus {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) => ServicePluginStatus(serviceId.trimAscii(), record.status, degradedReason: record.degradedReason, running: record.status == "running")
        case None => ServicePluginStatus(serviceId.trimAscii(), "missing", degradedReason: "service plugin is not registered")
    }
}

public func sendServiceHeartbeatProbe(serviceId: String): HeartbeatProbeResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            if (record.status != "running") {
                return HeartbeatProbeResult(false, serviceId.trimAscii(), record.status)
            }
            let frame = ServiceFrame("request", "heartbeat-${record.instanceId}", serviceId.trimAscii(), method: "heartbeat", payload: "{}")
            HeartbeatProbeResult(true, serviceId.trimAscii(), "sent", frame: frame)
        case None => HeartbeatProbeResult(false, serviceId.trimAscii(), "missing")
    }
}

public func handleServiceHeartbeat(frame: ServiceFrame): HeartbeatHandleResult {
    if (frame.frameType != "heartbeat" && frame.method != "heartbeat") {
        return HeartbeatHandleResult(false, frame.serviceId, "invalid", diagnostic: "frame is not heartbeat")
    }
    match (servicePluginRegistry.get(frame.serviceId)) {
        case Some(record) =>
            record.status = "running"
            record.degradedReason = ""
            record.lastHeartbeatAtMillis++
            HeartbeatHandleResult(true, frame.serviceId, "running")
        case None => HeartbeatHandleResult(false, frame.serviceId, "missing", diagnostic: "service plugin is not registered")
    }
}

public func markServiceHealth(serviceId: String, health: ServiceHealth): Unit {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            let status = health.status.toAsciiLower()
            if (status == "ok" || status == "running") {
                record.status = "running"
                record.degradedReason = ""
            } else {
                record.status = "degraded"
                record.degradedReason = if (health.reason.isEmpty()) { status } else { health.reason }
            }
        case None => ()
    }
}

public func enqueueServiceEventFrameForTest(frame: ServiceFrame): Unit {
    match (servicePluginRegistry.get(frame.serviceId)) {
        case Some(record) => record.eventFrames.add(frame)
        case None => ()
    }
}

public func readServiceEventFrame(serviceId: String, timeoutMillis!: Int64 = 1000): ServiceEventReadResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            if (record.eventFrames.size == 0) {
                return ServiceEventReadResult(false, "timeout", diagnostic: "no service event frame available")
            }
            let frame = record.eventFrames[0]
            record.eventFrames.remove(at: 0)
            let decoded = decodeServiceFrame(encodeServiceFrame(frame).trimAscii())
            if (!decoded.ok) {
                return ServiceEventReadResult(false, decoded.errorKind, diagnostic: decoded.diagnostic)
            }
            ServiceEventReadResult(true, "ok", frame: decoded.frame)
        case None => ServiceEventReadResult(false, "missing", diagnostic: "service plugin is not registered")
    }
}

public func handleServiceCapabilityEvent(event: ServiceCapabilityEvent): CapabilityEventHandleResult {
    match (serviceCapabilityRoutes.get(event.capabilityId)) {
        case Some(route) =>
            if (route[0] != event.serviceId) {
                return CapabilityEventHandleResult(false, "service_mismatch", serviceId: event.serviceId, capabilityId: event.capabilityId, diagnostic: "capability belongs to ${route[0]}")
            }
            if (route[1].kind != "event") {
                return CapabilityEventHandleResult(false, "not_event_capability", serviceId: event.serviceId, capabilityId: event.capabilityId)
            }
            let limit = enforceServiceFrameLimits(ServiceFrame("event", "event-${event.capabilityId}", event.serviceId, capabilityId: event.capabilityId, payload: event.payload))
            if (!limit.ok) {
                return CapabilityEventHandleResult(false, limit.reason, serviceId: event.serviceId, capabilityId: event.capabilityId, diagnostic: limit.payloadHash)
            }
            CapabilityEventHandleResult(true, "accepted", serviceId: event.serviceId, capabilityId: event.capabilityId)
        case None => CapabilityEventHandleResult(false, "capability_missing", serviceId: event.serviceId, capabilityId: event.capabilityId)
    }
}

public func handleServiceHostApiRequest(request: ServiceHostApiRequest): ServiceHostApiResult {
    match (servicePluginRegistry.get(request.serviceId)) {
        case Some(record) =>
            if (!serviceArrayContains(record.registration.grants, request.hostApi)) {
                return ServiceHostApiResult(false, "missing_grant", hostApi: request.hostApi, diagnostic: "service is not granted ${request.hostApi}")
            }
            let limit = enforceServiceFrameLimits(ServiceFrame("request", "host-api-${request.hostApi}", request.serviceId, method: "requestHostApi", payload: request.payload))
            if (!limit.ok) {
                return ServiceHostApiResult(false, limit.reason, hostApi: request.hostApi, diagnostic: limit.payloadHash)
            }
            ServiceHostApiResult(true, "accepted", hostApi: request.hostApi, payload: redactServicePayload(request.payload).text)
        case None => ServiceHostApiResult(false, "service_missing", hostApi: request.hostApi, diagnostic: "service plugin is not registered")
    }
}

public func buildServicePluginControlSnapshot(): ServicePluginControlSnapshot {
    ServicePluginControlSnapshot(listServicePlugins())
}

public func handleServicePluginControlAction(action: ServicePluginControlAction): ServicePluginControlResult {
    let normalized = action.action.toAsciiLower()
    if (normalized == "status") {
        match (getServicePluginSnapshot(action.serviceId)) {
            case Some(snapshot) => return ServicePluginControlResult(true, "ok", snapshot: snapshot)
            case None => return ServicePluginControlResult(false, "missing", message: "service plugin is not registered")
        }
    }
    if (normalized == "start") {
        let result = startServicePlugin(action.serviceId)
        return ServicePluginControlResult(result.ok, result.status, message: result.diagnostic, snapshot: getServicePluginSnapshot(action.serviceId) ?? ServicePluginSnapshot("", "", "missing"))
    }
    if (normalized == "stop") {
        let result = stopServicePlugin(action.serviceId, reason: "control_action")
        return ServicePluginControlResult(result.ok, result.status, message: result.diagnostic, snapshot: getServicePluginSnapshot(action.serviceId) ?? ServicePluginSnapshot("", "", "missing"))
    }
    if (normalized == "restart") {
        if (!action.caller.isOperator) {
            return ServicePluginControlResult(false, "unauthorized", message: "operator permission required")
        }
        let result = restartServicePlugin(action.serviceId, reason: "control_action")
        return ServicePluginControlResult(result.ok, result.status, message: result.diagnostic, snapshot: getServicePluginSnapshot(action.serviceId) ?? ServicePluginSnapshot("", "", "missing"))
    }
    if (normalized == "invoke") {
        let result = invokeRegisteredCapability(CapabilityInvokeRequest(action.capabilityId, payload: action.payload, caller: action.caller))
        return ServicePluginControlResult(result.ok, result.status, message: result.diagnostic, invokeResult: result)
    }
    ServicePluginControlResult(false, "unknown_action", message: "unsupported service plugin control action")
}

public func renderServicePluginDiagnostics(snapshot: ServicePluginSnapshot): String {
    let redactedReason = redactServicePayload(snapshot.degradedReason).text
    "serviceId=${snapshot.serviceId} status=${snapshot.status} enabled=${snapshot.enabled} capabilities=${serviceJoinStrings(snapshot.capabilityIds, ",")} config=${snapshot.configSummary} degradedReason=${redactedReason}"
}

private func serviceSnapshot(record: ServicePluginRuntimeRecord): ServicePluginSnapshot {
    let caps = ArrayList<String>()
    for (capability in record.registration.manifest.capabilityDeclarations) {
        caps.add(capability.capabilityId)
    }
    ServicePluginSnapshot(
        record.registration.manifest.pluginId,
        record.registration.manifest.displayName,
        record.status,
        degradedReason: record.degradedReason,
        enabled: record.registration.enabled,
        configSummary: record.registration.configRef.redacted(),
        capabilityIds: caps.toArray(),
        lastHeartbeatAtMillis: record.lastHeartbeatAtMillis,
        instanceId: record.instanceId
    )
}

private func serviceArrayContains(items: Array<String>, needle: String): Bool {
    for (item in items) {
        if (item.trimAscii() == needle.trimAscii()) {
            return true
        }
    }
    false
}

private func serviceJoinStrings(items: Array<String>, separator: String): String {
    var out = ""
    for (item in items) {
        if (out.isEmpty()) {
            out = item
        } else {
            out += separator + item
        }
    }
    out
}
