package metis.gateway.service_plugin

import metis.core.metisSafeUtf8Prefix
import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import metis.gateway.logging.{MetisLogEvent, metisCreateSubsystemLogger}
import metis.gateway.process.gatewayStdioBroker
import metis.process.{ManagedStdioBrokerClient, ManagedStdioEvent, ManagedStdioOwnerSpec}
import metis.utils.{SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, ShellUtils}
import std.collection.{ArrayList, HashMap, HashSet}
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists, remove}
import std.io.*
import std.env.{getProcessId, getVariable, getVariables, setVariable}
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.json.{JsonObject, JsonString, JsonValue}
import stdx.net.http.*

public class ServicePluginConfigRef {
    public let configPath: String
    public let secretRef: String
    public let manifestPath: String
    public let workingDirectory: String

    public init(configPath!: String = "", secretRef!: String = "", manifestPath!: String = "", workingDirectory!: String = "") {
        this.configPath = configPath.trimAscii()
        this.secretRef = secretRef.trimAscii()
        this.manifestPath = manifestPath.trimAscii()
        this.workingDirectory = workingDirectory.trimAscii()
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

public class ServicePluginDispatchSnapshot {
    public let active: Int64
    public let queued: Int64
    public let highWater: Int64
    public let queueFull: Int64
    public let admissionAccepted: Int64
    public let admissionRetried: Int64
    public let completionAck: Int64
    public let fenced: Bool

    public init(
        active!: Int64 = 0,
        queued!: Int64 = 0,
        highWater!: Int64 = 0,
        queueFull!: Int64 = 0,
        admissionAccepted!: Int64 = 0,
        admissionRetried!: Int64 = 0,
        completionAck!: Int64 = 0,
        fenced!: Bool = true
    ) {
        this.active = active
        this.queued = queued
        this.highWater = highWater
        this.queueFull = queueFull
        this.admissionAccepted = admissionAccepted
        this.admissionRetried = admissionRetried
        this.completionAck = completionAck
        this.fenced = fenced
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
    public let pid: Int64
    public let lastError: String
    public let supervisorLastProbe: String
    public let supervisorFailureCount: Int64
    public let supervisorRestartCount: Int64
    public let supervisorDegradedReason: String
    public let dispatch: ServicePluginDispatchSnapshot
    public let retainedEventFrames: Int64
    public let eventFrameEvictions: Int64

    public init(
        serviceId: String,
        displayName: String,
        status: String,
        degradedReason!: String = "",
        enabled!: Bool = true,
        configSummary!: String = "",
        capabilityIds!: Array<String> = [],
        lastHeartbeatAtMillis!: Int64 = -1,
        instanceId!: String = "",
        pid!: Int64 = 0,
        lastError!: String = "",
        supervisorLastProbe!: String = "",
        supervisorFailureCount!: Int64 = 0,
        supervisorRestartCount!: Int64 = 0,
        supervisorDegradedReason!: String = "",
        dispatch!: ServicePluginDispatchSnapshot = ServicePluginDispatchSnapshot(),
        retainedEventFrames!: Int64 = 0,
        eventFrameEvictions!: Int64 = 0
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
        this.pid = pid
        this.lastError = lastError
        this.supervisorLastProbe = supervisorLastProbe
        this.supervisorFailureCount = supervisorFailureCount
        this.supervisorRestartCount = supervisorRestartCount
        this.supervisorDegradedReason = supervisorDegradedReason
        this.dispatch = dispatch
        this.retainedEventFrames = retainedEventFrames
        this.eventFrameEvictions = eventFrameEvictions
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
    public let ingressStopStatus: String
    public let dispatchStatus: String
    public let ownerStopStatus: String
    public let leaseStatus: String
    public let portStatus: String

    public init(
        ok: Bool,
        serviceId: String,
        status: String,
        stateFlushed!: Bool = false,
        diagnostic!: String = "",
        ingressStopStatus!: String = "not_started",
        dispatchStatus!: String = "not_started",
        ownerStopStatus!: String = "not_started",
        leaseStatus!: String = "not_checked",
        portStatus!: String = "not_checked"
    ) {
        this.ok = ok
        this.serviceId = serviceId
        this.status = status
        this.stateFlushed = stateFlushed
        this.diagnostic = diagnostic
        this.ingressStopStatus = ingressStopStatus.trimAscii()
        this.dispatchStatus = dispatchStatus.trimAscii()
        this.ownerStopStatus = ownerStopStatus.trimAscii()
        this.leaseStatus = leaseStatus.trimAscii()
        this.portStatus = portStatus.trimAscii()
    }
}

public class ServicePluginHostShutdownResult {
    public let ok: Bool
    public let status: String
    public let results: ArrayList<ServiceStopResult>

    public init(ok: Bool, status: String, results: ArrayList<ServiceStopResult>) {
        this.ok = ok
        this.status = status.trimAscii()
        this.results = results
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

public class ServicePluginSupervisorConfig {
    public let enabled: Bool
    public let intervalMs: Int64
    public let healthTimeoutMs: Int64
    public let failureThreshold: Int64
    public let restartCooldownMs: Int64

    public init(
        enabled!: Bool = true,
        intervalMs!: Int64 = 60000,
        healthTimeoutMs!: Int64 = 2000,
        failureThreshold!: Int64 = 3,
        restartCooldownMs!: Int64 = 60000
    ) {
        this.enabled = enabled
        this.intervalMs = max(100, intervalMs)
        this.healthTimeoutMs = max(1, healthTimeoutMs)
        this.failureThreshold = max(1, failureThreshold)
        this.restartCooldownMs = max(0, restartCooldownMs)
    }
}

public class ServicePluginHealthProbeResult {
    public let pidAlive: Bool
    public let stdioAlive: Bool
    public let leaseState: String
    public let leaseAgeMs: Int64
    public let healthzOk: Bool
    public let healthzDurationMs: Int64
    public let port: Int64
    public let diagnostic: String

    public init(
        pidAlive!: Bool = false,
        stdioAlive!: Bool = false,
        leaseState!: String = "",
        leaseAgeMs!: Int64 = -1,
        healthzOk!: Bool = true,
        healthzDurationMs!: Int64 = -1,
        port!: Int64 = 0,
        diagnostic!: String = ""
    ) {
        this.pidAlive = pidAlive
        this.stdioAlive = stdioAlive
        this.leaseState = leaseState.trimAscii()
        this.leaseAgeMs = leaseAgeMs
        this.healthzOk = healthzOk
        this.healthzDurationMs = healthzDurationMs
        this.port = port
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class ServicePluginHealthzProbeResult {
    public let ok: Bool
    public let statusCode: Int64
    public let durationMs: Int64
    public let diagnostic: String

    public init(ok: Bool, statusCode!: Int64 = 0, durationMs!: Int64 = -1, diagnostic!: String = "") {
        this.ok = ok
        this.statusCode = statusCode
        this.durationMs = durationMs
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class ServicePluginHealthClassification {
    public let status: String
    public let reason: String
    public let failureCount: Int64
    public let shouldRecover: Bool
    public let diagnostic: String

    public init(status: String, reason!: String = "", failureCount!: Int64 = 0, shouldRecover!: Bool = false, diagnostic!: String = "") {
        this.status = status.trimAscii()
        this.reason = reason.trimAscii()
        this.failureCount = failureCount
        this.shouldRecover = shouldRecover
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class ServicePluginSupervisorTickResult {
    public let ok: Bool
    public let status: String
    public let probe: ServicePluginHealthProbeResult
    public let classification: ServicePluginHealthClassification
    public let recovered: Bool
    public let diagnostic: String

    public init(
        ok: Bool,
        status: String,
        probe!: ServicePluginHealthProbeResult = ServicePluginHealthProbeResult(),
        classification!: ServicePluginHealthClassification = ServicePluginHealthClassification("healthy"),
        recovered!: Bool = false,
        diagnostic!: String = ""
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.probe = probe
        this.classification = classification
        this.recovered = recovered
        this.diagnostic = diagnostic.trimAscii()
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
    public var pid: Int64
    public var lastError: String
    public var lastInvokeAtMillis: Int64
    public var supervisorFailureCount: Int64
    public var supervisorRestartCount: Int64
    public var supervisorLastProbe: String
    public var supervisorLastDegradedReason: String
    public var supervisorLastProbeAtMs: Int64
    public var supervisorLastRestartAtMs: Int64
    public let eventFrames: ArrayList<ServiceFrame>
    public var eventFrameEvictions: Int64

    public init(registration: ServicePluginRegistration) {
        this.registration = registration
        this.status = if (registration.enabled) { "registered" } else { "disabled" }
        this.degradedReason = if (registration.enabled) { "" } else { "plugin disabled" }
        this.lastHeartbeatAtMillis = -1
        this.instanceSeq = 0
        this.instanceId = ""
        this.stateFlushed = false
        this.pid = 0
        this.lastError = ""
        this.lastInvokeAtMillis = -1
        this.supervisorFailureCount = 0
        this.supervisorRestartCount = 0
        this.supervisorLastProbe = ""
        this.supervisorLastDegradedReason = ""
        this.supervisorLastProbeAtMs = -1
        this.supervisorLastRestartAtMs = -1
        this.eventFrames = ArrayList<ServiceFrame>()
        this.eventFrameEvictions = 0
    }
}

private class ServicePluginSupervisorStopFlag {
    private let lock = Mutex()
    private var stoppedValue = false

    public func stop(): Unit {
        synchronized(this.lock) {
            this.stoppedValue = true
        }
    }

    public func stopped(): Bool {
        synchronized(this.lock) { this.stoppedValue }
    }
}

private var servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
private var serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()
private var servicePluginCapabilityInvokerForTest: Option<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult> =
    None<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult>
private var servicePluginSupervisorConfig = ServicePluginSupervisorConfig()
private var servicePluginHealthzProbeForTest: Option<(String, Int64) -> ServicePluginHealthzProbeResult> =
    None<(String, Int64) -> ServicePluginHealthzProbeResult>
private var servicePluginPortOwnerProbeForTest: Option<(Int64, Int64) -> Bool> =
    None<(Int64, Int64) -> Bool>
private var servicePluginPortReleaseCommandForTest: Option<(Int64, Int64, Int64) -> (Int64, String, String)> =
    None<(Int64, Int64, Int64) -> (Int64, String, String)>
private var servicePluginPidProbeCommandForTest: Option<(Int64, Int64) -> (Int64, String, String)> =
    None<(Int64, Int64) -> (Int64, String, String)>
private let servicePluginMonotonicOrigin = MonoTime.now()
private var servicePluginMonotonicNowForTest: Option<() -> Int64> = None<() -> Int64>
private let servicePluginDeadlineClockLock = Mutex()
private var servicePluginLastDeadlineNowMs: Int64 = 0
private var servicePluginDispatchRemainingForTest: Option<() -> Int64> = None<() -> Int64>
private var servicePluginBeforeDispatchWaitForTest: Option<(Int64) -> Unit> = None<(Int64) -> Unit>
private var servicePluginDispatchSettledHookForTest: Option<() -> Unit> = None<() -> Unit>
private var servicePluginCleanupFinalizeHookForTest: Option<(String, Int64) -> Unit> = None<(String, Int64) -> Unit>
private var servicePluginSupervisorAutoStartForTest = true
private var servicePluginSupervisorWorkers = HashMap<String, ServicePluginSupervisorStopFlag>()
private let servicePluginSupervisorLock = Mutex()

private class ServicePluginLineBuffer {
    private let lock = Mutex()
    private let condition: Condition
    private let lines = ArrayList<String>()
    private let summaryLines = ArrayList<String>()
    private var closed = false
    private var errorText = ""

    public init() {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    public func appendLine(line: String): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
            while (this.lines.size >= 256) {
                this.lines.remove(at: 0)
            }
            let stored = metisSafeUtf8Prefix(line, 65537, marker: "...[TRUNCATED]")
            let clipped = metisSafeUtf8Prefix(line, 4096, marker: "...[TRUNCATED]")
            this.lines.add(stored)
            this.summaryLines.add(clipped)
            while (this.summaryLines.size > 8) {
                this.summaryLines.remove(at: 0)
            }
            this.condition.notifyAll()
        }
    }

    public func readLine(timeoutMs: Int64): Option<String> {
        let effective = if (timeoutMs > 0) { timeoutMs } else { 1000 }
        synchronized(this.lock) {
            if (this.lines.isEmpty() && !this.closed) {
                let _ = this.condition.waitUntil({ => !this.lines.isEmpty() || this.closed }, timeout: Duration.millisecond * effective)
            }
            if (this.lines.isEmpty()) {
                return None<String>
            }
            let line = this.lines[0]
            this.lines.remove(at: 0)
            Some(line)
        }
    }

    public func isClosed(): Bool {
        synchronized(this.lock) { this.closed }
    }

    public func close(error!: String = ""): Unit {
        synchronized(this.lock) {
            this.closed = true
            if (this.errorText.isEmpty()) {
                this.errorText = error.trimAscii()
            }
            this.condition.notifyAll()
        }
    }

    public func summary(): String {
        synchronized(this.lock) {
            let text = String.join(this.summaryLines.toArray(), delimiter: "\n")
            if (this.errorText.isEmpty()) {
                return text
            }
            if (text.isEmpty()) {
                return this.errorText
            }
            text + "\n" + this.errorText
        }
    }
}

private class ServicePluginBrokerProcessState {
    private let lock = Mutex()
    private let condition: Condition
    private var alive = true
    private var stopping = false
    private var activeReaders: Int64 = 0
    private var terminalStatus = ""

    public init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    public func isAlive(): Bool { synchronized(this.lock) { this.alive && !this.stopping } }

    public func beginRead(): Bool {
        synchronized(this.lock) {
            if (this.stopping) { return false }
            this.activeReaders++
            true
        }
    }

    public func endRead(): Unit {
        synchronized(this.lock) {
            this.activeReaders = max(0, this.activeReaders - 1)
            this.condition.notifyAll()
        }
    }

    public func shouldStop(): Bool { synchronized(this.lock) { this.stopping } }

    public func cacheTerminal(status: String): Unit {
        synchronized(this.lock) {
            this.alive = false
            if (this.terminalStatus.isEmpty()) { this.terminalStatus = status.trimAscii() }
            this.condition.notifyAll()
        }
    }

    public func terminal(): String { synchronized(this.lock) { this.terminalStatus } }

    public func waitTerminal(timeoutMs: Int64): Bool {
        synchronized(this.lock) {
            if (!this.terminalStatus.isEmpty()) { return true }
            let _ = this.condition.waitUntil(
                { => !this.terminalStatus.isEmpty() },
                timeout: Duration.millisecond * max(1, timeoutMs)
            )
            !this.terminalStatus.isEmpty()
        }
    }

    public func stopReaders(timeoutMs: Int64): Unit {
        synchronized(this.lock) {
            this.stopping = true
            this.alive = false
            if (this.activeReaders > 0) {
                let _ = this.condition.waitUntil(
                    { => this.activeReaders == 0 },
                    timeout: Duration.millisecond * max(1, timeoutMs)
                )
            }
        }
    }

    public func readersSettled(): Bool { synchronized(this.lock) { this.activeReaders == 0 } }
}

private class ServicePluginBrokerProcessHandle {
    public let pid: Int64
    private let state: ServicePluginBrokerProcessState

    public init(pid: Int64, state: ServicePluginBrokerProcessState) {
        this.pid = pid
        this.state = state
    }

    public func isAlive(): Bool { this.state.isAlive() }
}

private const SERVICE_PLUGIN_DISPATCH_MAX_ACTIVE: Int64 = 2
private const SERVICE_PLUGIN_DISPATCH_MAX_QUEUED: Int64 = 128
private const SERVICE_PLUGIN_RETAINED_EVENT_FRAME_LIMIT: Int64 = 128

private func servicePluginAckJsonString(root: JsonObject, key: String): String {
    match (root.get(key)) {
        case Some(value) => try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private class ServicePluginDispatchTask {
    let record: ServicePluginRuntimeRecord
    let frame: ServiceFrame
    let deliveryId: String
    let eventId: String
    let attemptToken: String
    let deliveryIdPresent: Bool
    let attemptTokenPresent: Bool
    let identityValid: Bool
    var admissionSequence: Int64 = 0
    var dequeueSequence: Int64 = 0
    var admissionConfirmed: Bool = false
    var reservationKind: String = "none"
    var reservationState: String = "new"

    init(record: ServicePluginRuntimeRecord, frame: ServiceFrame) {
        this.record = record
        this.frame = frame
        let root = try { JsonValue.fromStr(frame.payload).asObject() } catch (_: Exception) { JsonObject() }
        this.deliveryId = servicePluginAckJsonString(root, "deliveryId")
        this.eventId = servicePluginAckJsonString(root, "eventId")
        this.attemptToken = servicePluginAckJsonString(root, "attemptToken")
        this.deliveryIdPresent = root.get("deliveryId").isSome()
        this.attemptTokenPresent = root.get("attemptToken").isSome()
        this.identityValid = this.deliveryId.size > 0 && this.deliveryId.size <= 4096 &&
            this.eventId.size > 0 && this.eventId.size <= 4096 && this.attemptToken.size > 0 &&
            this.attemptToken.size <= 4096 && this.attemptToken == frame.correlationId.trimAscii()
    }

    func ackable(): Bool {
        this.identityValid && this.frame.frameType == "event" && this.frame.method == "emitCapabilityEvent" &&
            this.frame.capabilityId == "gitcode.event.accepted" &&
            this.frame.serviceId == this.record.registration.manifest.pluginId
    }

    func hasAckIdentity(): Bool { this.deliveryIdPresent || this.attemptTokenPresent }
}

public class ServicePluginDispatchSchedulerSnapshotForTest {
    public let ownerId: String
    public let generation: Int64
    public let active: Int64
    public let queued: Int64
    public let accepted: Int64
    public let futures: Int64
    public let queueHighWatermark: Int64
    public let queueFull: Int64
    public let cancelled: Int64
    public let accepting: Bool
    public let settled: Bool

    public init(ownerId: String, generation: Int64, active: Int64, queued: Int64, accepted: Int64, futures: Int64,
        queueHighWatermark: Int64, queueFull: Int64, cancelled: Int64, accepting: Bool, settled: Bool) {
        this.ownerId = ownerId
        this.generation = generation
        this.active = active
        this.queued = queued
        this.accepted = accepted
        this.futures = futures
        this.queueHighWatermark = queueHighWatermark
        this.queueFull = queueFull
        this.cancelled = cancelled
        this.accepting = accepting
        this.settled = settled
    }
}

public class ServicePluginDispatchMemorySnapshot {
    public let active: Int64
    public let queued: Int64
    public let accepted: Int64
    public let futures: Int64
    public let highWater: Int64
    public let queueFull: Int64
    public let fenced: Bool

    public init(active: Int64, queued: Int64, accepted: Int64, futures: Int64, highWater: Int64, queueFull: Int64, fenced: Bool) {
        this.active = active
        this.queued = queued
        this.accepted = accepted
        this.futures = futures
        this.highWater = highWater
        this.queueFull = queueFull
        this.fenced = fenced
    }
}

private class ServicePluginStdioProcess {
    public let serviceId: String
    public let process: ServicePluginBrokerProcessHandle
    public let generation: Int64
    public let ownerId: String
    public let claimToken: Int64
    private let broker: ManagedStdioBrokerClient
    private let state = ServicePluginBrokerProcessState()
    private let stdoutBuffer = ServicePluginLineBuffer()
    private let stderrBuffer = ServicePluginLineBuffer()
    private let dispatchLock = Mutex()
    private let dispatchCondition: Condition
    private var dispatchFenced = false
    private var acceptedDispatches: Int64 = 0
    private var activeDispatches: Int64 = 0
    private var dispatchFutureSequence: Int64 = 0
    private var dispatchAdmissionSequence: Int64 = 0
    private var dispatchDequeueSequence: Int64 = 0
    private var invokeSequence: Int64 = 0
    private let dispatchFutures = HashMap<Int64, Future<Unit>>()
    private let dispatchQueue = ArrayList<ServicePluginDispatchTask>()
    private var dispatchQueueHighWatermark: Int64 = 0
    private var dispatchQueueFull: Int64 = 0
    private var cancelledDispatches: Int64 = 0
    private var admissionAcceptedAcks: Int64 = 0
    private var admissionRetriedAcks: Int64 = 0
    private var completionAcks: Int64 = 0
    private var highWaterDiagnosticActive = false
    private var queueFullDiagnosticActive = false
    private var highWaterEnteredDiagnosticEmitted = false
    private var highWaterExitedDiagnosticEmitted = false
    private var queueFullEnteredDiagnosticEmitted = false
    private var queueFullExitedDiagnosticEmitted = false
    private var fenceDiagnosticEmitted = false
    private let dispatchDiagnosticTransitions = ArrayList<String>()

    public init(broker: ManagedStdioBrokerClient, serviceId: String, ownerId: String, generation: Int64, pid: Int64, claimToken!: Int64 = 0) {
        this.broker = broker
        this.serviceId = serviceId
        this.ownerId = ownerId
        this.generation = generation
        this.claimToken = claimToken
        this.process = ServicePluginBrokerProcessHandle(pid, this.state)
        synchronized(this.dispatchLock) { this.dispatchCondition = this.dispatchLock.condition() }
    }

    public func dispatchAllowed(): Bool { synchronized(this.dispatchLock) { !this.dispatchFenced } }
    private func refreshDispatchDiagnosticStateLocked(): Unit {
        let atHighWater = Int64(this.dispatchQueue.size) >= SERVICE_PLUGIN_DISPATCH_MAX_QUEUED
        if (atHighWater && !this.highWaterDiagnosticActive) {
            this.highWaterDiagnosticActive = true
            if (!this.highWaterEnteredDiagnosticEmitted) {
                this.highWaterEnteredDiagnosticEmitted = true
                this.dispatchDiagnosticTransitions.add("high_water_entered")
            }
        } else if (!atHighWater && this.highWaterDiagnosticActive) {
            this.highWaterDiagnosticActive = false
            if (!this.highWaterExitedDiagnosticEmitted) {
                this.highWaterExitedDiagnosticEmitted = true
                this.dispatchDiagnosticTransitions.add("high_water_exited")
            }
        }
        if (this.queueFullDiagnosticActive && !atHighWater) {
            this.queueFullDiagnosticActive = false
            if (!this.queueFullExitedDiagnosticEmitted) {
                this.queueFullExitedDiagnosticEmitted = true
                this.dispatchDiagnosticTransitions.add("queue_full_exited")
            }
        }
        if (this.dispatchFenced && !this.fenceDiagnosticEmitted) {
            this.fenceDiagnosticEmitted = true
            this.dispatchDiagnosticTransitions.add("fenced")
        }
    }
    public func dispatchSnapshot(): ServicePluginDispatchSnapshot {
        synchronized(this.dispatchLock) {
            ServicePluginDispatchSnapshot(
                active: this.activeDispatches,
                queued: Int64(this.dispatchQueue.size),
                highWater: this.dispatchQueueHighWatermark,
                queueFull: this.dispatchQueueFull,
                admissionAccepted: this.admissionAcceptedAcks,
                admissionRetried: this.admissionRetriedAcks,
                completionAck: this.completionAcks,
                fenced: this.dispatchFenced
            )
        }
    }
    public func takeDispatchDiagnosticTransitions(): ArrayList<String> {
        synchronized(this.dispatchLock) {
            let rows = ArrayList<String>()
            for (state in this.dispatchDiagnosticTransitions) { rows.add(state) }
            this.dispatchDiagnosticTransitions.clear()
            rows
        }
    }
    public func recordEventAckWritten(phase: String, status: String): Unit {
        synchronized(this.dispatchLock) {
            if (phase == "admission" && status == "accepted") {
                this.admissionAcceptedAcks++
            } else if (phase == "admission" && (status == "queue_full" || status == "retry" || status == "cancelled")) {
                this.admissionRetriedAcks++
            } else if (phase == "completion" && status == "completed") {
                this.completionAcks++
            }
        }
    }
    public func recordCompletionConfirmed(): Unit {
        synchronized(this.dispatchLock) { this.completionAcks++ }
    }
    public func dispatchCountsForTest(): (String, Int64, Int64, Int64) {
        synchronized(this.dispatchLock) {
            (this.ownerId, this.generation, this.acceptedDispatches, Int64(this.dispatchFutures.size))
        }
    }
    public func dispatchSchedulerSnapshotForTest(): ServicePluginDispatchSchedulerSnapshotForTest {
        synchronized(this.dispatchLock) {
            ServicePluginDispatchSchedulerSnapshotForTest(
                this.ownerId, this.generation, this.activeDispatches, Int64(this.dispatchQueue.size),
                this.acceptedDispatches, Int64(this.dispatchFutures.size), this.dispatchQueueHighWatermark,
                this.dispatchQueueFull, this.cancelledDispatches, !this.dispatchFenced,
                this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0 && this.acceptedDispatches == 0
            )
        }
    }
    public func memoryDiagnosticSnapshot(): ServicePluginDispatchMemorySnapshot {
        synchronized(this.dispatchLock) {
            ServicePluginDispatchMemorySnapshot(
                this.activeDispatches,
                Int64(this.dispatchQueue.size),
                this.acceptedDispatches,
                Int64(this.dispatchFutures.size),
                this.dispatchQueueHighWatermark,
                this.dispatchQueueFull,
                this.dispatchFenced
            )
        }
    }
    public func trySubmitDispatch(task: ServicePluginDispatchTask): String {
        synchronized(this.dispatchLock) {
            if (this.dispatchFenced) { task.reservationState = "cancelled"; return "cancelled" }
            this.dispatchAdmissionSequence++
            task.admissionSequence = this.dispatchAdmissionSequence
            if (this.activeDispatches < SERVICE_PLUGIN_DISPATCH_MAX_ACTIVE) {
                task.reservationKind = "active"
                task.reservationState = "reserved"
                this.activeDispatches++
                this.acceptedDispatches++
                return "started"
            }
            if (Int64(this.dispatchQueue.size) < SERVICE_PLUGIN_DISPATCH_MAX_QUEUED) {
                task.reservationKind = "queued"
                task.reservationState = "reserved"
                this.dispatchQueue.add(task)
                this.acceptedDispatches++
                this.dispatchQueueHighWatermark = max(this.dispatchQueueHighWatermark, Int64(this.dispatchQueue.size))
                this.refreshDispatchDiagnosticStateLocked()
                return "queued"
            }
            this.dispatchQueueFull++
            if (!this.queueFullDiagnosticActive) {
                this.queueFullDiagnosticActive = true
                if (!this.queueFullEnteredDiagnosticEmitted) {
                    this.queueFullEnteredDiagnosticEmitted = true
                    this.dispatchDiagnosticTransitions.add("queue_full_entered")
                }
            }
            "queue_full"
        }
    }
    public func nextInvokeSequence(): Int64 { synchronized(this.dispatchLock) { this.invokeSequence++; this.invokeSequence } }
    public func confirmAdmission(task: ServicePluginDispatchTask): String {
        synchronized(this.dispatchLock) {
            if (task.reservationState == "fenced") { return "cancelled_acknowledged" }
            if (task.reservationState != "reserved") { return "cancelled" }
            if (this.dispatchFenced) {
                if (task.reservationKind == "active") {
                    this.activeDispatches = max(0, this.activeDispatches - 1)
                    this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
                } else if (task.reservationKind == "queued") {
                    for (index in 0..this.dispatchQueue.size) {
                        if (this.dispatchQueue[index].admissionSequence == task.admissionSequence) {
                            this.dispatchQueue.remove(at: index)
                            this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
                            break
                        }
                    }
                }
                task.reservationState = "cancelled"
                this.refreshDispatchDiagnosticStateLocked()
                this.dispatchCondition.notifyAll()
                return "cancelled"
            }
            task.admissionConfirmed = true
            task.reservationState = "confirmed"
            if (task.reservationKind == "active") { return "started" }
            for (index in 0..this.dispatchQueue.size) {
                if (this.dispatchQueue[index].admissionSequence == task.admissionSequence) {
                    if (index == 0 && this.activeDispatches < SERVICE_PLUGIN_DISPATCH_MAX_ACTIVE) {
                        let queued = this.dispatchQueue.remove(at: index)
                        queued.reservationKind = "active"
                        this.activeDispatches++
                        this.dispatchDequeueSequence++
                        queued.dequeueSequence = this.dispatchDequeueSequence
                        this.refreshDispatchDiagnosticStateLocked()
                        return "started"
                    }
                    return "queued"
                }
            }
            task.reservationState = "cancelled"
            this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
            this.refreshDispatchDiagnosticStateLocked()
            this.dispatchCondition.notifyAll()
            "cancelled"
        }
    }
    public func nextDispatchFutureToken(): Int64 { synchronized(this.dispatchLock) { this.dispatchFutureSequence++; this.dispatchFutureSequence } }
    public func registerDispatchFuture(token: Int64, future: Future<Unit>): Unit { synchronized(this.dispatchLock) { this.dispatchFutures[token] = future } }
    public func rollbackDispatchLaunch(): Option<ServicePluginDispatchTask> {
        var next = None<ServicePluginDispatchTask>
        synchronized(this.dispatchLock) {
            this.activeDispatches = max(0, this.activeDispatches - 1)
            this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
            if (!this.dispatchFenced && this.dispatchQueue.size > 0 && this.dispatchQueue[0].admissionConfirmed) {
                let task = this.dispatchQueue.remove(at: 0)
                task.reservationKind = "active"
                this.activeDispatches++
                this.dispatchDequeueSequence++
                task.dequeueSequence = this.dispatchDequeueSequence
                next = Some(task)
            }
            this.refreshDispatchDiagnosticStateLocked()
            this.dispatchCondition.notifyAll()
        }
        next
    }
    public func rollbackAdmittedTask(task: ServicePluginDispatchTask): Option<ServicePluginDispatchTask> {
        var next = None<ServicePluginDispatchTask>
        synchronized(this.dispatchLock) {
            if (task.reservationState != "reserved") { return next }
            var queuedIndex: Int64 = -1
            if (task.reservationKind == "queued") {
                for (index in 0..this.dispatchQueue.size) {
                    if (this.dispatchQueue[index].admissionSequence == task.admissionSequence) { queuedIndex = Int64(index); break }
                }
            }
            if (queuedIndex >= 0) {
                this.dispatchQueue.remove(at: queuedIndex)
                this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
            } else if (task.reservationKind == "active") {
                this.activeDispatches = max(0, this.activeDispatches - 1)
                this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
                if (!this.dispatchFenced && this.dispatchQueue.size > 0 && this.dispatchQueue[0].admissionConfirmed) {
                    let queued = this.dispatchQueue.remove(at: 0)
                    queued.reservationKind = "active"
                    this.activeDispatches++
                    this.dispatchDequeueSequence++
                    queued.dequeueSequence = this.dispatchDequeueSequence
                    next = Some(queued)
                }
            }
            task.reservationState = "rolled_back"
            this.refreshDispatchDiagnosticStateLocked()
            this.dispatchCondition.notifyAll()
        }
        next
    }
    public func finishDispatchFuture(token: Int64): Option<ServicePluginDispatchTask> {
        var next = None<ServicePluginDispatchTask>
        var settled = false
        synchronized(this.dispatchLock) {
            this.dispatchFutures.remove(token)
            this.activeDispatches = max(0, this.activeDispatches - 1)
            this.acceptedDispatches = max(0, this.acceptedDispatches - 1)
            if (!this.dispatchFenced && this.dispatchQueue.size > 0 && this.dispatchQueue[0].admissionConfirmed) {
                let task = this.dispatchQueue.remove(at: 0)
                task.reservationKind = "active"
                this.activeDispatches++
                this.dispatchDequeueSequence++
                task.dequeueSequence = this.dispatchDequeueSequence
                next = Some(task)
            }
            settled = this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0 && this.acceptedDispatches == 0
            this.refreshDispatchDiagnosticStateLocked()
            this.dispatchCondition.notifyAll()
        }
        if (settled) {
            match (servicePluginDispatchSettledHookForTest) { case Some(hook) => hook() case None => () }
        }
        next
    }
    public func fenceDispatch(): ArrayList<ServicePluginDispatchTask> {
        synchronized(this.dispatchLock) {
            this.dispatchFenced = true
            let cancelled = ArrayList<ServicePluginDispatchTask>()
            for (task in this.dispatchQueue) {
                task.reservationState = "fenced"
                cancelled.add(task)
            }
            this.cancelledDispatches += Int64(cancelled.size)
            this.acceptedDispatches = max(0, this.acceptedDispatches - Int64(cancelled.size))
            this.dispatchQueue.clear()
            this.refreshDispatchDiagnosticStateLocked()
            this.dispatchCondition.notifyAll()
            cancelled
        }
    }
    public func waitDispatches(timeoutMs: Int64): Bool {
        synchronized(this.dispatchLock) {
            if (this.acceptedDispatches == 0 && this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0) { return true }
            let _ = this.dispatchCondition.waitUntil(
                { => this.acceptedDispatches == 0 && this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0 },
                timeout: Duration.millisecond * max(1, timeoutMs)
            )
            this.acceptedDispatches == 0 && this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0
        }
    }
    public func dispatchesSettled(): Bool { synchronized(this.dispatchLock) { this.acceptedDispatches == 0 && this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0 } }
    public func cancelDispatches(timeoutMs: Int64): Bool {
        let futures = synchronized(this.dispatchLock) {
            let rows = ArrayList<Future<Unit>>()
            for ((_, future) in this.dispatchFutures) { rows.add(future) }
            rows
        }
        for (future in futures) { try { future.cancel() } catch (_: Exception) { () } }
        let deadlineMs = servicePluginDeadlineNowMs() + max(1, timeoutMs)
        for (future in futures) {
            let remaining = servicePluginDeadlineRemaining(deadlineMs)
            if (remaining <= 0) { break }
            try { let _ = future.get(Duration.millisecond * remaining) } catch (_: Exception) { () }
        }
        synchronized(this.dispatchLock) { this.acceptedDispatches == 0 && this.activeDispatches == 0 && this.dispatchQueue.size == 0 && this.dispatchFutures.size == 0 }
    }

    public func writeLine(line: String, timeoutMs!: Int64 = 1000): Unit {
        let written = this.broker.writeOwnerLine(
            this.ownerId,
            line,
            timeoutMs: max(1, timeoutMs),
            expectedGeneration: Some(this.generation)
        )
        if (!written.ok) {
            throw Exception("service plugin broker write failed: ${written.status}")
        }
    }

    public func readStdoutLine(timeoutMs: Int64): Option<String> {
        if (!this.state.beginRead()) { return None<String> }
        try {
            let deadline = servicePluginDeadlineNowMs() + max(1, timeoutMs)
            while (!this.state.shouldStop()) {
                let remaining = deadline - servicePluginDeadlineNowMs()
                if (remaining <= 0) { return None<String> }
                match (this.broker.readOwnerLine(this.ownerId, timeoutMs: remaining)) {
                    case Some(event) =>
                        match (this.readLines(event)) {
                            case Some(line) => return Some(line)
                            case None =>
                                if (!this.state.terminal().isEmpty()) { return None<String> }
                        }
                    case None => return None<String>
                }
            }
            None<String>
        } finally {
            this.state.endRead()
        }
    }

    public func stdoutClosed(): Bool {
        this.stdoutBuffer.isClosed()
    }

    public func stderrSummary(): String {
        redactServicePayload(this.stderrBuffer.summary()).text
    }

    public func stdoutSummary(): String {
        redactServicePayload(this.stdoutBuffer.summary()).text
    }

    public func terminalStatus(): String { this.state.terminal() }

    public func waitTerminal(timeoutMs: Int64): Bool { this.state.waitTerminal(timeoutMs) }

    public func stopReaders(timeoutMs: Int64): Unit {
        this.state.stopReaders(timeoutMs)
        this.stdoutBuffer.close(error: this.state.terminal())
        this.stderrBuffer.close(error: this.state.terminal())
    }

    public func stop(timeoutMs!: Int64 = 500): ServicePluginProcessStopResult {
        let effective = if (timeoutMs > 0) { timeoutMs } else { 500 }
        let deadlineMs = servicePluginDeadlineNowMs() + effective
        this.state.stopReaders(min(50, max(1, effective / 4)))
        let remaining = max(0, deadlineMs - servicePluginDeadlineNowMs())
        if (remaining <= 0) {
            this.state.cacheTerminal("stop_timeout")
            this.stdoutBuffer.close()
            this.stderrBuffer.close()
            return ServicePluginProcessStopResult(false, "still_alive")
        }
        let stopped = this.broker.stopOwner(
            this.ownerId,
            timeoutMs: remaining,
            expectedGeneration: Some(this.generation)
        )
        var drained = this.state.readersSettled()
        while (drained) {
            let drainRemaining = max(0, deadlineMs - servicePluginDeadlineNowMs())
            if (drainRemaining <= 0) {
                drained = false
                break
            }
            if (this.broker.snapshot().generation != this.generation) {
                drained = false
                break
            }
            match (this.broker.readOwnerLine(this.ownerId, timeoutMs: min(25, drainRemaining))) {
                case Some(event) => let _ = this.readLines(event)
                case None => break
            }
        }
        let cached = this.state.terminal()
        if (cached.isEmpty()) {
            this.state.cacheTerminal(if (stopped.ok) { "stopped" } else { stopped.status })
        }
        this.stdoutBuffer.close()
        this.stderrBuffer.close()
        ServicePluginProcessStopResult(
            stopped.ok && drained,
            if (!stopped.ok || !drained) { "still_alive" } else if (stopped.status == "already_stopped") { "terminated" } else { "force_terminated" }
        )
    }

    private func readLines(event: ManagedStdioEvent): Option<String> {
        if (event.eventType == "owner.stdout") {
            this.stdoutBuffer.appendLine(event.text)
            return this.stdoutBuffer.readLine(1)
        }
        if (event.eventType == "owner.stderr") {
            this.stderrBuffer.appendLine(event.text)
            return None<String>
        }
        if (event.eventType == "owner.exit") {
            this.state.cacheTerminal("process_exited")
        } else if (event.eventType == "owner.timeout") {
            this.state.cacheTerminal(if (event.status.isEmpty()) { "timed_out" } else { event.status })
        } else if (event.eventType == "owner.error") {
            this.state.cacheTerminal(if (event.status.isEmpty()) { "process_error" } else { event.status })
        } else {
            this.state.cacheTerminal("broker_protocol_error")
        }
        let status = this.state.terminal()
        this.stdoutBuffer.close(error: status)
        this.stderrBuffer.close(error: status)
        None<String>
    }
}

private class ServicePluginStartClaim {
    public let token: Int64
    public let ownerId: String
    public let instanceId: String
    private let lock = Mutex()
    private let condition: Condition
    private var state = "registered"
    private var cancelRequested = false
    private var resultStatus = ""
    private var resultDiagnostic = ""

    public init(token: Int64, ownerId: String, instanceId: String) {
        this.token = token
        this.ownerId = ownerId
        this.instanceId = instanceId
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    public func transition(next: String): Bool { synchronized(this.lock) { if (this.cancelRequested || this.state == "settled") { false } else { this.state = next; true } } }
    public func cancel(): Unit { synchronized(this.lock) { this.cancelRequested = true; this.condition.notifyAll() } }
    public func cancelled(): Bool { synchronized(this.lock) { this.cancelRequested } }
    public func settle(status: String, diagnostic: String): Unit { synchronized(this.lock) { this.state = "settled"; this.resultStatus = status; this.resultDiagnostic = diagnostic; this.condition.notifyAll() } }
    public func waitSettled(timeoutMs: Int64): Bool { synchronized(this.lock) { if (this.state == "settled") { return true }; let _ = this.condition.waitUntil({ => this.state == "settled" }, timeout: Duration.millisecond * max(1, timeoutMs)); this.state == "settled" } }
    public func outcome(): (String, String) { synchronized(this.lock) { (this.resultStatus, this.resultDiagnostic) } }
}

private class ServicePluginEventPumpGate {
    private let lock = Mutex()
    private let condition: Condition
    private var opened = false
    private var cancelled = false
    private var workerSettled = false

    public init() { synchronized(this.lock) { this.condition = this.lock.condition() } }

    public func open(): Unit {
        synchronized(this.lock) {
            this.opened = true
            this.condition.notifyAll()
        }
    }

    public func cancel(): Unit {
        synchronized(this.lock) {
            this.cancelled = true
            this.condition.notifyAll()
        }
    }

    public func waitOpen(): Bool {
        synchronized(this.lock) {
            while (!this.opened && !this.cancelled) { this.condition.wait() }
            this.opened && !this.cancelled
        }
    }

    public func markWorkerSettled(): Unit { synchronized(this.lock) { this.workerSettled = true; this.condition.notifyAll() } }
    public func waitWorkerSettled(): Unit { synchronized(this.lock) { while (!this.workerSettled) { this.condition.wait() } } }
}

private class ServicePluginDispatchGuardHookGate {
    private let lock = Mutex()
    private var pending = true

    public func take(): Bool {
        synchronized(this.lock) {
            if (!this.pending) { return false }
            this.pending = false
            true
        }
    }
}

private class ServicePluginDetachedOwner {
    public let process: Option<ServicePluginStdioProcess>
    public let queue: Option<ServicePluginResponseQueue>
    public let pump: Option<Future<Unit>>

    public init(
        process!: Option<ServicePluginStdioProcess> = None<ServicePluginStdioProcess>,
        queue!: Option<ServicePluginResponseQueue> = None<ServicePluginResponseQueue>,
        pump!: Option<Future<Unit>> = None<Future<Unit>>
    ) {
        this.process = process
        this.queue = queue
        this.pump = pump
    }
}

private class ServicePluginCleanupFinalizeResult {
    public let finalized: Bool
    public let ingressStopStatus: String
    public let dispatchStatus: String
    public let ownerStopStatus: String
    public let leaseStatus: String
    public let portStatus: String
    public let diagnostic: String

    public init(
        finalized: Bool,
        ingressStopStatus: String,
        dispatchStatus: String,
        ownerStopStatus: String,
        leaseStatus: String,
        portStatus: String,
        diagnostic: String
    ) {
        this.finalized = finalized
        this.ingressStopStatus = ingressStopStatus.trimAscii()
        this.dispatchStatus = dispatchStatus.trimAscii()
        this.ownerStopStatus = ownerStopStatus.trimAscii()
        this.leaseStatus = leaseStatus.trimAscii()
        this.portStatus = portStatus.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

private class ServicePluginCleanupPendingSlot {
    public let serviceId: String
    public let detached: ServicePluginDetachedOwner
    public let ownerId: String
    public let generation: Int64
    public let claimToken: Int64
    public let stopStatus: String
    public let diagnostic: String
    public let finalStatus: String
    public let finalReason: String
    public let stateFlushed: Bool
    public let ingressStopStatus: String
    public var dispatchStatus: String
    public var ownerStopStatus: String
    public var leaseStatus: String
    public var portStatus: String
    public var terminalDiagnostic: String
    public let cleanupToken: Int64
    private let finalizeLock = Mutex()
    private let finalizeCondition: Condition
    private var finalizeInProgress = false
    private var finalizeCompleted = false
    private var finalizeResult = ServicePluginCleanupFinalizeResult(
        false,
        "not_started",
        "not_started",
        "not_started",
        "not_checked",
        "not_checked",
        "cleanup_not_started"
    )

    public init(
        serviceId: String,
        detached: ServicePluginDetachedOwner,
        process: ServicePluginStdioProcess,
        stopStatus: String,
        diagnostic: String,
        finalStatus: String,
        finalReason: String,
        stateFlushed: Bool,
        ingressStopStatus: String,
        dispatchStatus: String,
        leaseStatus: String,
        portStatus: String,
        cleanupToken: Int64
    ) {
        this.serviceId = serviceId.trimAscii()
        this.detached = detached
        this.ownerId = process.ownerId
        this.generation = process.generation
        this.claimToken = process.claimToken
        this.stopStatus = stopStatus.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.finalStatus = finalStatus.trimAscii()
        this.finalReason = finalReason.trimAscii()
        this.stateFlushed = stateFlushed
        this.ingressStopStatus = ingressStopStatus.trimAscii()
        this.dispatchStatus = dispatchStatus.trimAscii()
        this.ownerStopStatus = stopStatus.trimAscii()
        this.leaseStatus = leaseStatus.trimAscii()
        this.portStatus = portStatus.trimAscii()
        this.terminalDiagnostic = diagnostic.trimAscii()
        this.cleanupToken = cleanupToken
        synchronized(this.finalizeLock) { this.finalizeCondition = this.finalizeLock.condition() }
    }

    public func claimFinalize(deadlineMs: Int64): (Bool, Option<ServicePluginCleanupFinalizeResult>) {
        synchronized(this.finalizeLock) {
            while (this.finalizeInProgress && !this.finalizeCompleted) {
                let remaining = max(0, deadlineMs - servicePluginDeadlineNowMs())
                if (remaining <= 0) { return (false, None<ServicePluginCleanupFinalizeResult>) }
                let _ = this.finalizeCondition.wait(timeout: Duration.millisecond * remaining)
            }
            if (this.finalizeCompleted) { return (false, Some(this.finalizeResult)) }
            this.finalizeInProgress = true
            (true, None<ServicePluginCleanupFinalizeResult>)
        }
    }

    public func finishFinalize(result: ServicePluginCleanupFinalizeResult): Unit {
        synchronized(this.finalizeLock) {
            this.finalizeResult = result
            this.finalizeCompleted = result.finalized
            this.finalizeInProgress = false
            this.finalizeCondition.notifyAll()
        }
    }
}

private class ServicePluginProcessStopResult {
    public let ok: Bool
    public let status: String

    public init(ok: Bool, status: String) {
        this.ok = ok
        this.status = status.trimAscii()
    }
}

private class ServicePluginStdoutReadPolicy {
    public let timeoutMs: Int64
    public let maxNoiseLines: Int64
    public let maxNoiseBytes: Int64
    public let expectedServiceId: String
    public let expectedMethod: String
    public let expectedCapabilityId: String
    public let expectedCorrelationId: String

    public init(
        timeoutMs: Int64,
        expectedServiceId: String,
        expectedMethod: String,
        expectedCapabilityId!: String = "",
        expectedCorrelationId!: String = "",
        maxNoiseLines!: Int64 = 8,
        maxNoiseBytes!: Int64 = 8192
    ) {
        this.timeoutMs = timeoutMs
        this.maxNoiseLines = maxNoiseLines
        this.maxNoiseBytes = maxNoiseBytes
        this.expectedServiceId = expectedServiceId.trimAscii()
        this.expectedMethod = expectedMethod.trimAscii()
        this.expectedCapabilityId = expectedCapabilityId.trimAscii()
        this.expectedCorrelationId = expectedCorrelationId.trimAscii()
    }
}

private class ServicePluginStdoutReadResult {
    public let ok: Bool
    public let frame: ServiceFrame
    public let status: String
    public let diagnostic: String
    public let noiseLineCount: Int64
    public let noiseHash: String

    public init(
        ok: Bool,
        frame!: ServiceFrame = ServiceFrame("", "", ""),
        status!: String = "ok",
        diagnostic!: String = "",
        noiseLineCount!: Int64 = 0,
        noiseHash!: String = ""
    ) {
        this.ok = ok
        this.frame = frame
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.noiseLineCount = noiseLineCount
        this.noiseHash = noiseHash.trimAscii()
    }
}

private class ServicePluginResponseQueue {
    private let lock = Mutex()
    private let condition: Condition
    private let responses = ArrayList<ServiceFrame>()
    private let activeCorrelations = HashSet<String>()
    private let expiredCorrelations = HashSet<String>()
    private let expiredCorrelationOrder = ArrayList<String>()
    private var closed = false
    private var closeStatus = "process_exited"
    private var closeDiagnostic = ""

    public init() {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    public func append(frame: ServiceFrame): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
            if (this.expiredCorrelations.contains(frame.correlationId)) {
                this.expiredCorrelations.remove(frame.correlationId)
                for (index in 0..this.expiredCorrelationOrder.size) {
                    if (this.expiredCorrelationOrder[index] == frame.correlationId) {
                        this.expiredCorrelationOrder.remove(at: index)
                        break
                    }
                }
                return
            }
            if (!this.activeCorrelations.contains(frame.correlationId)) { return }
            if (this.responses.size >= 128) { return }
            this.responses.add(frame)
            this.condition.notifyAll()
        }
    }

    public func close(status!: String = "process_exited", diagnostic!: String = ""): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.closeStatus = status.trimAscii()
            if (this.closeDiagnostic.isEmpty()) {
                this.closeDiagnostic = diagnostic.trimAscii()
            }
            this.condition.notifyAll()
        }
    }

    public func isClosed(): Bool {
        synchronized(this.lock) { this.closed }
    }

    public func registerCorrelation(correlationId: String): Bool {
        let corr = correlationId.trimAscii()
        if (corr.isEmpty()) { return false }
        synchronized(this.lock) {
            if (this.closed || this.activeCorrelations.contains(corr)) { return false }
            this.activeCorrelations.add(corr)
            true
        }
    }

    public func cancelCorrelation(correlationId: String, status!: String = "cancelled"): Unit {
        synchronized(this.lock) {
            let corr = correlationId.trimAscii()
            this.activeCorrelations.remove(corr)
            this.removeResponseLocked(corr)
            this.rememberExpiredLocked(corr)
            if (!status.trimAscii().isEmpty()) { this.closeDiagnostic = status.trimAscii() }
            this.condition.notifyAll()
        }
    }

    public func cancelCorrelationsWithPrefix(prefix: String): Int64 {
        synchronized(this.lock) {
            let cancelled = ArrayList<String>()
            for (corr in this.activeCorrelations) { if (corr.startsWith(prefix)) { cancelled.add(corr) } }
            for (corr in cancelled) {
                this.activeCorrelations.remove(corr)
                this.removeResponseLocked(corr)
                this.rememberExpiredLocked(corr)
            }
            if (cancelled.size > 0) { this.condition.notifyAll() }
            Int64(cancelled.size)
        }
    }

    public func readResponse(
        correlationId: String,
        expectedServiceId: String,
        expectedMethod: String,
        expectedCapabilityId: String,
        timeoutMs: Int64
    ): ServicePluginStdoutReadResult {
        let corr = correlationId.trimAscii()
        let effective = if (timeoutMs > 0) { timeoutMs } else { 30000 }
        synchronized(this.lock) {
            let _ = this.condition.waitUntil({ => this.closed || !this.activeCorrelations.contains(corr) || this.findResponseIndex(corr) >= 0 }, timeout: Duration.millisecond * effective)
            let responseIndex = this.findResponseIndex(corr)
            if (responseIndex >= 0) {
                let frame = this.responses[responseIndex]
                this.responses.remove(at: responseIndex)
                let validation = validateServicePluginResponseFrame(
                    frame,
                    expectedServiceId,
                    expectedMethod,
                    expectedCapabilityId: expectedCapabilityId,
                    expectedCorrelationId: corr
                )
                if (!validation.ok) {
                    this.activeCorrelations.remove(corr)
                    this.rememberExpiredLocked(corr)
                    return ServicePluginStdoutReadResult(false, frame: frame, status: validation.status, diagnostic: validation.diagnostic)
                }
                this.activeCorrelations.remove(corr)
                this.rememberExpiredLocked(corr)
                return ServicePluginStdoutReadResult(true, frame: frame)
            }
            if (!this.activeCorrelations.contains(corr)) {
                return ServicePluginStdoutReadResult(false, status: "cancelled", diagnostic: "response wait cancelled")
            }
            if (this.closed) {
                this.activeCorrelations.remove(corr)
                return ServicePluginStdoutReadResult(false, status: if (this.closeStatus.isEmpty()) { "process_exited" } else { this.closeStatus }, diagnostic: this.closeDiagnostic)
            }
            this.activeCorrelations.remove(corr)
            this.rememberExpiredLocked(corr)
            ServicePluginStdoutReadResult(false, status: "timeout", diagnostic: "timeout waiting for response correlationId=${corr}")
        }
    }

    public func pendingCountForTest(): Int64 { synchronized(this.lock) { Int64(this.responses.size) } }
    public func activeCountForTest(): Int64 { synchronized(this.lock) { Int64(this.activeCorrelations.size) } }

    private func removeResponseLocked(correlationId: String): Unit {
        var idx: Int64 = this.responses.size - 1
        while (idx >= 0) {
            if (this.responses[idx].correlationId == correlationId) { this.responses.remove(at: idx) }
            idx--
        }
    }

    private func rememberExpiredLocked(correlationId: String): Unit {
        if (this.expiredCorrelations.contains(correlationId)) { return }
        if (this.expiredCorrelationOrder.size >= 128) {
            let oldest = this.expiredCorrelationOrder.remove(at: 0)
            this.expiredCorrelations.remove(oldest)
        }
        this.expiredCorrelationOrder.add(correlationId)
        this.expiredCorrelations.add(correlationId)
    }

    private func findResponseIndex(correlationId: String): Int64 {
        var idx: Int64 = 0
        while (idx < this.responses.size) {
            if (this.responses[idx].correlationId == correlationId) {
                return idx
            }
            idx++
        }
        -1
    }
}

public func servicePluginResponseQueueExpiryProofForTest(): (String, Int64, String, Int64, Int64) {
    let timeoutQueue = ServicePluginResponseQueue()
    for (index in 0..1000) {
        timeoutQueue.append(ServiceFrame(
            "response", "unsolicited-${index}", "gitcode-monitor", method: "emitCapabilityEvent",
            capabilityId: "gitcode.event.accepted", correlationId: "wrong-${index}", payload: "{}"
        ))
    }
    var timedOut = ServicePluginStdoutReadResult(false, status: "missing")
    for (index in 0..129) {
        let corr = "corr-timeout-${index}"
        let _ = timeoutQueue.registerCorrelation(corr)
        timedOut = timeoutQueue.readResponse(corr, "gitcode-monitor", "emitCapabilityEvent", "gitcode.event.accepted", 1)
    }
    var index: Int64 = 128
    while (index >= 0) {
        timeoutQueue.append(ServiceFrame(
            "response", "late-${index}", "gitcode-monitor", method: "emitCapabilityEvent",
            capabilityId: "gitcode.event.accepted", correlationId: "corr-timeout-${index}", payload: "{}"
        ))
        index--
    }
    let mismatchQueue = ServicePluginResponseQueue()
    let _ = mismatchQueue.registerCorrelation("corr-wrong")
    mismatchQueue.append(ServiceFrame(
        "response", "wrong", "wrong-service", method: "emitCapabilityEvent",
        capabilityId: "gitcode.event.accepted", correlationId: "corr-wrong", payload: "{}"
    ))
    let mismatched = mismatchQueue.readResponse("corr-wrong", "gitcode-monitor", "emitCapabilityEvent", "gitcode.event.accepted", 1)
    mismatchQueue.append(ServiceFrame(
        "response", "late-right", "gitcode-monitor", method: "emitCapabilityEvent",
        capabilityId: "gitcode.event.accepted", correlationId: "corr-wrong", payload: "{}"
    ))
    (timedOut.status, timeoutQueue.pendingCountForTest(), mismatched.status, mismatchQueue.pendingCountForTest(), timeoutQueue.activeCountForTest() + mismatchQueue.activeCountForTest())
}

private class ServicePluginProcessEnsureResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let process: ?ServicePluginStdioProcess
    public let queue: ?ServicePluginResponseQueue

    public init(
        ok: Bool,
        status: String,
        diagnostic!: String = "",
        process!: ?ServicePluginStdioProcess = None<ServicePluginStdioProcess>,
        queue!: ?ServicePluginResponseQueue = None<ServicePluginResponseQueue>
    ) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.process = process
        this.queue = queue
    }
}

private var servicePluginActiveProcesses = HashMap<String, ServicePluginStdioProcess>()
private var servicePluginResponseQueues = HashMap<String, ServicePluginResponseQueue>()
private var servicePluginEventPumps = HashMap<String, Future<Unit>>()
private var servicePluginStartClaims = HashMap<String, ServicePluginStartClaim>()
private var servicePluginCleanupPendingOwners = HashMap<String, ServicePluginCleanupPendingSlot>()
private var servicePluginBrokerOwnerSequence: Int64 = 0
private var servicePluginStartClaimSequence: Int64 = 0
private var servicePluginCleanupTokenSequence: Int64 = 0
private var servicePluginStartPhaseHookForTest: Option<(String, String) -> Unit> = None<(String, String) -> Unit>
private var servicePluginBeforeEventDispatchHookForTest: Option<(String) -> Unit> = None<(String) -> Unit>
private var servicePluginDispatchLaunchHookForTest: Option<(String) -> Unit> = None<(String) -> Unit>
private var servicePluginDispatchRegisterHookForTest: Option<(String) -> Unit> = None<(String) -> Unit>
private var servicePluginDispatchWorkerSettledHookForTest: Option<(String) -> Unit> = None<(String) -> Unit>
private var servicePluginEventAckWrittenHookForTest: Option<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit> = None<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit>
private var servicePluginBeforeCompletionAckHookForTest: Option<(String) -> Bool> = None<(String) -> Bool>
private var servicePluginDispatchDiagnosticHookForTest: Option<(String, String, ServicePluginDispatchSnapshot) -> Unit> = None<(String, String, ServicePluginDispatchSnapshot) -> Unit>
private var servicePluginBeforeSupervisorRegisterHookForTest: Option<(String) -> Unit> = None<(String) -> Unit>
private var servicePluginHostShuttingDown = false

public func setServicePluginStartPhaseHookForTest(hook: Option<(String, String) -> Unit>): Unit { servicePluginStartPhaseHookForTest = hook }
public func setServicePluginBeforeEventDispatchHookForTest(hook: Option<(String) -> Unit>): Unit { servicePluginBeforeEventDispatchHookForTest = hook }
public func setServicePluginDispatchLaunchHookForTest(hook: Option<(String) -> Unit>): Unit { servicePluginDispatchLaunchHookForTest = hook }
public func setServicePluginDispatchRegisterHookForTest(hook: Option<(String) -> Unit>): Unit { servicePluginDispatchRegisterHookForTest = hook }
public func setServicePluginDispatchWorkerSettledHookForTest(hook: Option<(String) -> Unit>): Unit { servicePluginDispatchWorkerSettledHookForTest = hook }
public func setServicePluginEventAckWrittenHookForTest(hook: Option<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit>): Unit { servicePluginEventAckWrittenHookForTest = hook }
public func setServicePluginBeforeCompletionAckHookForTest(hook: Option<(String) -> Bool>): Unit { servicePluginBeforeCompletionAckHookForTest = hook }
public func setServicePluginDispatchDiagnosticHookForTest(hook: Option<(String, String, ServicePluginDispatchSnapshot) -> Unit>): Unit { servicePluginDispatchDiagnosticHookForTest = hook }
public func setServicePluginBeforeSupervisorRegisterHookForTest(hook: Option<(String) -> Unit>): Unit { servicePluginBeforeSupervisorRegisterHookForTest = hook }

private func servicePluginRunStartPhaseHook(serviceId: String, phase: String): Unit { match (servicePluginStartPhaseHookForTest) { case Some(hook) => hook(serviceId, phase) case None => () } }
private let servicePluginProcessLock = Mutex()
private let servicePluginRuntimeRecordLock = Mutex()
private let servicePluginHostLogger = metisCreateSubsystemLogger("gateway/service-plugin/host")

private func servicePluginFlushDispatchDiagnostics(process: ServicePluginStdioProcess): Unit {
    let transitions = process.takeDispatchDiagnosticTransitions()
    for (state in transitions) {
        let snapshot = process.dispatchSnapshot()
        let meta = JsonObject()
        meta.put("serviceId", JsonString(process.serviceId))
        meta.put("state", JsonString(state))
        meta.put("active", JsonString("${snapshot.active}"))
        meta.put("queued", JsonString("${snapshot.queued}"))
        meta.put("highWater", JsonString("${snapshot.highWater}"))
        meta.put("queueFull", JsonString("${snapshot.queueFull}"))
        meta.put("fenced", JsonString("${snapshot.fenced}"))
        servicePluginHostLogger.info(MetisLogEvent.loggingRaw, "service_plugin.dispatch.state", meta: meta)
        match (servicePluginDispatchDiagnosticHookForTest) {
            case Some(hook) => hook(process.serviceId, state, snapshot)
            case None => ()
        }
    }
}

public func servicePluginCleanupPendingCountForTest(): Int64 { synchronized(servicePluginProcessLock) { Int64(servicePluginCleanupPendingOwners.size) } }
public func servicePluginSupervisorWorkerCountForTest(): Int64 { synchronized(servicePluginSupervisorLock) { Int64(servicePluginSupervisorWorkers.size) } }
public func servicePluginDispatchCountsForTest(serviceId: String): Option<(String, Int64, Int64, Int64)> {
    synchronized(servicePluginProcessLock) {
        match (servicePluginActiveProcesses.get(serviceId.trimAscii())) {
            case Some(process) => Some(process.dispatchCountsForTest())
            case None => None<(String, Int64, Int64, Int64)>
        }
    }
}
public func servicePluginDispatchSchedulerSnapshotForTest(serviceId: String): Option<ServicePluginDispatchSchedulerSnapshotForTest> {
    synchronized(servicePluginProcessLock) {
        match (servicePluginActiveProcesses.get(serviceId.trimAscii())) {
            case Some(process) => Some(process.dispatchSchedulerSnapshotForTest())
            case None => None<ServicePluginDispatchSchedulerSnapshotForTest>
        }
    }
}
public func servicePluginDispatchMemorySnapshot(serviceId: String): Option<ServicePluginDispatchMemorySnapshot> {
    let process = synchronized(servicePluginProcessLock) {
        servicePluginActiveProcesses.get(serviceId.trimAscii())
    }
    match (process) {
        case Some(value) => Some(value.memoryDiagnosticSnapshot())
        case None => None<ServicePluginDispatchMemorySnapshot>
    }
}
public func servicePluginResponseQueueCountsForTest(serviceId: String): Option<(Int64, Int64)> {
    synchronized(servicePluginProcessLock) {
        match (servicePluginResponseQueues.get(serviceId.trimAscii())) {
            case Some(queue) => Some((queue.activeCountForTest(), queue.pendingCountForTest()))
            case None => None<(Int64, Int64)>
        }
    }
}

private func servicePluginSafeDiagnosticText(text: String): String {
    redactServicePayload(text.trimAscii()).text
}

private func servicePluginSafePathDiagnostic(path: String): String {
    let trimmed = path.trimAscii()
    if (trimmed.isEmpty()) {
        return "absent"
    }
    servicePluginSafeDiagnosticText(trimmed)
}

private func servicePluginBinaryMtimeDiagnostic(command: String): String {
    let cmd = command.trimAscii()
    if (cmd.isEmpty() || !exists(Path(cmd))) {
        return "unavailable"
    }
    try {
        let darwin = executeWithOutput("stat", ["-f", "%m", cmd])
        if (darwin[0] == 0) {
            return String.fromUtf8(darwin[1]).trimAscii()
        }
    } catch (_: Exception) {
        ()
    }
    try {
        let linux = executeWithOutput("stat", ["-c", "%Y", cmd])
        if (linux[0] == 0) {
            return String.fromUtf8(linux[1]).trimAscii()
        }
    } catch (_: Exception) {
        ()
    }
    "unavailable"
}

private func servicePluginStartDiagnosticMeta(record: ServicePluginRuntimeRecord, pid: Int64, status: String, diagnostic!: String = ""): JsonObject {
    let configRef = record.registration.configRef
    let meta = JsonObject()
    meta.put("serviceId", JsonString(record.registration.manifest.pluginId))
    meta.put("status", JsonString(status.trimAscii()))
    meta.put("entryCommand", JsonString(servicePluginSafePathDiagnostic(record.registration.manifest.entryCommand)))
    meta.put("workingDirectory", JsonString(servicePluginSafePathDiagnostic(servicePluginEffectiveWorkingDirectory(configRef))))
    meta.put("pid", JsonString("${pid}"))
    meta.put("manifestPath", JsonString(servicePluginSafePathDiagnostic(configRef.manifestPath)))
    meta.put("configRef", JsonString(configRef.redacted()))
    meta.put("binaryMtime", JsonString(servicePluginBinaryMtimeDiagnostic(record.registration.manifest.entryCommand)))
    if (!diagnostic.trimAscii().isEmpty()) {
        meta.put("diagnostic", JsonString(servicePluginSafeDiagnosticText(diagnostic)))
    }
    meta
}

private func logServicePluginProcessStart(record: ServicePluginRuntimeRecord, pid: Int64): Unit {
    servicePluginHostLogger.info(
        MetisLogEvent.loggingRaw,
        "service_plugin.process.start",
        meta: servicePluginStartDiagnosticMeta(record, pid, "started")
    )
}

private func logServicePluginProcessStartFailed(record: ServicePluginRuntimeRecord, diagnostic: String): Unit {
    servicePluginHostLogger.warn(
        MetisLogEvent.loggingRaw,
        "service_plugin.process.start_failed",
        meta: servicePluginStartDiagnosticMeta(record, 0, "process_start_failed", diagnostic: diagnostic)
    )
}

private func servicePluginOwnerMatchesLocked(
    serviceId: String,
    ownerId: String,
    generation: Int64,
    claimToken!: Int64 = 0
): Bool {
    let sid = serviceId.trimAscii()
    match (servicePluginActiveProcesses.get(sid)) {
        case Some(current) =>
            if (current.ownerId != ownerId || current.generation != generation || (claimToken > 0 && current.claimToken != claimToken)) { return false }
        case None => return false
    }
    true
}

private func detachServicePluginOwnerLocked(
    serviceId: String,
    ownerId!: String = "",
    generation!: Int64 = 0,
    claimToken!: Int64 = 0
): ServicePluginDetachedOwner {
    let sid = serviceId.trimAscii()
    var process = None<ServicePluginStdioProcess>
    var queue = None<ServicePluginResponseQueue>
    var pump = None<Future<Unit>>
    match (servicePluginActiveProcesses.get(sid)) {
        case Some(current) =>
            if ((!ownerId.isEmpty() && current.ownerId != ownerId) ||
                (generation > 0 && current.generation != generation) ||
                (claimToken > 0 && current.claimToken != claimToken)) {
                return ServicePluginDetachedOwner()
            }
            process = Some(current)
            servicePluginActiveProcesses.remove(sid)
        case None => ()
    }
    match (servicePluginResponseQueues.get(sid)) {
        case Some(current) =>
            queue = Some(current)
            servicePluginResponseQueues.remove(sid)
        case None => ()
    }
    match (servicePluginEventPumps.get(sid)) {
        case Some(current) =>
            pump = Some(current)
            servicePluginEventPumps.remove(sid)
        case None => ()
    }
    ServicePluginDetachedOwner(process: process, queue: queue, pump: pump)
}

private func servicePluginHasCleanupPendingLocked(serviceId: String): Bool {
    let sid = serviceId.trimAscii()
    for ((_, slot) in servicePluginCleanupPendingOwners) {
        if (slot.serviceId == sid) { return true }
    }
    false
}

private func servicePluginFinalizeCleanupPending(
    serviceId: String,
    process: ServicePluginStdioProcess,
    timeoutMs!: Int64 = 1
): ServicePluginCleanupFinalizeResult {
    if (!process.dispatchesSettled()) {
        return ServicePluginCleanupFinalizeResult(
            false,
            "not_started",
            "dispatch_pending",
            "not_started",
            "not_checked",
            "not_checked",
            "dispatch_pending"
        )
    }
    let deadlineMs = servicePluginDeadlineNowMs() + max(1, timeoutMs)
    let candidate = synchronized(servicePluginProcessLock) {
        match (servicePluginCleanupPendingOwners.get(process.ownerId)) {
            case Some(slot) =>
                if (slot.serviceId == serviceId.trimAscii() && slot.generation == process.generation && slot.claimToken == process.claimToken) { Some(slot) } else { None<ServicePluginCleanupPendingSlot> }
            case None => None<ServicePluginCleanupPendingSlot>
        }
    }
    if (candidate.isNone()) {
        return ServicePluginCleanupFinalizeResult(
            false,
            "not_started",
            "not_started",
            "not_started",
            "not_checked",
            "not_checked",
            "cleanup_identity_missing"
        )
    }
    let expectedSlot = candidate.getOrThrow()
    let claim = expectedSlot.claimFinalize(deadlineMs)
    if (!claim[0]) {
        return match (claim[1]) {
            case Some(result) => result
            case None => ServicePluginCleanupFinalizeResult(
                false,
                expectedSlot.ingressStopStatus,
                expectedSlot.dispatchStatus,
                expectedSlot.ownerStopStatus,
                expectedSlot.leaseStatus,
                expectedSlot.portStatus,
                "cleanup_finalize_wait_timeout"
            )
        }
    }
    var result = ServicePluginCleanupFinalizeResult(
        false,
        expectedSlot.ingressStopStatus,
        expectedSlot.dispatchStatus,
        expectedSlot.ownerStopStatus,
        expectedSlot.leaseStatus,
        expectedSlot.portStatus,
        "cleanup_finalize_failed"
    )
    try {
        match (servicePluginCleanupFinalizeHookForTest) {
            case Some(hook) => hook(expectedSlot.serviceId, expectedSlot.cleanupToken)
            case None => ()
        }
        let remaining = servicePluginDeadlineRemaining(deadlineMs)
        let terminalReserve = min(100, max(0, remaining - 1))
        let stopped = process.stop(timeoutMs: max(1, remaining - terminalReserve))
        let cleanupRecord = synchronized(servicePluginProcessLock) { servicePluginRegistry.get(serviceId.trimAscii()) }
        let terminalState = match (cleanupRecord) {
            case Some(record) => servicePluginStopTerminalState(
                record,
                process.process.pid,
                ServicePluginProbeDeadline(deadlineMs)
            )
            case None => ServicePluginStopTerminalState(true, "service_missing_after_stop", "gone", "not_applicable", "not_applicable")
        }
        let finalized = synchronized(servicePluginProcessLock) {
            match (servicePluginCleanupPendingOwners.get(process.ownerId)) {
                case Some(slot) =>
                    let identityMatches = slot.serviceId == serviceId.trimAscii() && slot.generation == process.generation &&
                        slot.claimToken == process.claimToken && slot.cleanupToken == expectedSlot.cleanupToken
                    if (!identityMatches) {
                        false
                    } else {
                        slot.ownerStopStatus = stopped.status
                        slot.dispatchStatus = if (process.dispatchesSettled()) { "drained" } else { "dispatch_pending" }
                        slot.leaseStatus = terminalState.leaseStatus
                        slot.portStatus = terminalState.portStatus
                        slot.terminalDiagnostic = terminalState.diagnostic
                        let phaseMatches = stopped.ok && terminalState.ok && !servicePluginActiveProcesses.contains(slot.serviceId) &&
                            !servicePluginStartClaims.contains(slot.serviceId)
                        let recordMatches = match (servicePluginRegistry.get(slot.serviceId)) {
                            case Some(record) => record.status == "cleanup_pending" && (record.pid == process.process.pid || record.pid == 0)
                            case None => true
                        }
                        if (!phaseMatches || !recordMatches) {
                            false
                        } else {
                            servicePluginCleanupPendingOwners.remove(process.ownerId)
                            let recoveredStopTimeout = slot.finalStatus == "degraded" && slot.finalReason == "stop timeout"
                            match (servicePluginRegistry.get(slot.serviceId)) {
                                case Some(record) =>
                                    record.pid = 0
                                    record.status = if (recoveredStopTimeout) { "stopped" } else { slot.finalStatus }
                                    record.degradedReason = if (recoveredStopTimeout) { "" } else { slot.finalReason }
                                    record.stateFlushed = if (recoveredStopTimeout) { true } else { slot.stateFlushed }
                                    record.lastError = "${slot.diagnostic} cleanup_retry_stop_status=${stopped.status} cleanup_finalized"
                                case None => ()
                            }
                            true
                        }
                    }
                case None => false
            }
        }
        result = ServicePluginCleanupFinalizeResult(
            finalized,
            expectedSlot.ingressStopStatus,
            expectedSlot.dispatchStatus,
            stopped.status,
            terminalState.leaseStatus,
            terminalState.portStatus,
            terminalState.diagnostic
        )
    } finally {
        expectedSlot.finishFinalize(result)
    }
    result
}

private func servicePluginPublishCleanupPending(
    serviceId: String,
    detached: ServicePluginDetachedOwner,
    process: ServicePluginStdioProcess,
    stopStatus: String,
    diagnostic: String,
    finalStatus!: String = "stopped",
    finalReason!: String = "",
    stateFlushed!: Bool = true,
    ingressStopStatus!: String = "not_started",
    dispatchStatus!: String = "not_started",
    leaseStatus!: String = "not_checked",
    portStatus!: String = "not_checked"
): Unit {
    let sid = serviceId.trimAscii()
    let safeDiagnostic = servicePluginSafeDiagnosticText(diagnostic)
    synchronized(servicePluginProcessLock) {
        servicePluginCleanupTokenSequence++
        servicePluginCleanupPendingOwners[process.ownerId] = ServicePluginCleanupPendingSlot(
            sid,
            detached,
            process,
            stopStatus,
            safeDiagnostic,
            finalStatus,
            finalReason,
            stateFlushed,
            ingressStopStatus,
            dispatchStatus,
            leaseStatus,
            portStatus,
            servicePluginCleanupTokenSequence
        )
        match (servicePluginRegistry.get(sid)) {
            case Some(record) =>
                if (!servicePluginActiveProcesses.contains(sid)) {
                    record.status = "cleanup_pending"
                    record.degradedReason = "cleanup_pending"
                    record.stateFlushed = false
                    record.lastError = safeDiagnostic
                }
            case None => ()
        }
    }
    let _ = servicePluginFinalizeCleanupPending(sid, process)
}

private func servicePluginCleanupPendingForServiceLocked(serviceId: String): Option<ServicePluginCleanupPendingSlot> {
    let sid = serviceId.trimAscii()
    for ((_, slot) in servicePluginCleanupPendingOwners) {
        if (slot.serviceId == sid) { return Some(slot) }
    }
    None<ServicePluginCleanupPendingSlot>
}

private func servicePluginDrainDispatchForStop(process: ServicePluginStdioProcess, deadlineMs: Int64, stopReserveMs: Int64): String {
    servicePluginWriteFencedEventAcks(process.fenceDispatch(), process)
    let remaining = servicePluginDispatchRemaining(deadlineMs)
    let dispatchBudget = servicePluginDispatchBudget(remaining, stopReserveMs)
    let waitBudget = if (dispatchBudget > 1) { max(1, dispatchBudget / 2) } else { dispatchBudget }
    if (waitBudget > 0) {
        match (servicePluginBeforeDispatchWaitForTest) {
            case Some(hook) => hook(waitBudget)
            case None => ()
        }
    }
    if (waitBudget > 0 && process.waitDispatches(waitBudget)) { return "drained" }
    let cancelBudget = servicePluginDispatchBudget(servicePluginDispatchRemaining(deadlineMs), stopReserveMs)
    if (cancelBudget > 0 && process.cancelDispatches(cancelBudget)) { return "cancelled" }
    "dispatch_pending"
}

private func servicePluginDispatchRemaining(deadlineMs: Int64): Int64 {
    match (servicePluginDispatchRemainingForTest) {
        case Some(probe) => max(0, probe())
        case None => servicePluginDeadlineRemaining(deadlineMs)
    }
}

private func servicePluginDispatchBudget(remainingMs: Int64, stopReserveMs: Int64): Int64 {
    max(0, remainingMs - max(1, stopReserveMs))
}

public func servicePluginDispatchBudgetForTest(remainingMs: Int64, stopReserveMs: Int64): Int64 {
    servicePluginDispatchBudget(remainingMs, stopReserveMs)
}

private func servicePluginObserveIngressStop(
    serviceId: String,
    process: ServicePluginStdioProcess,
    deadlineMs: Int64
): Unit {
    let sid = serviceId.trimAscii()
    while (servicePluginDeadlineRemaining(deadlineMs) > 0) {
        let record = synchronized(servicePluginProcessLock) { servicePluginRegistry.get(sid) }
        let state = match (record) {
            case Some(record) => servicePluginStopTerminalState(
                record,
                process.process.pid,
                ServicePluginProbeDeadline(deadlineMs)
            )
            case None => return
        }
        if (state.ok || state.leaseStatus == "not_applicable") { return }
        sleep(Duration.millisecond * min(10, servicePluginDeadlineRemaining(deadlineMs)))
    }
}

private func cleanupDetachedServicePluginOwner(
    serviceId: String,
    detached: ServicePluginDetachedOwner,
    reason: String,
    diagnostic!: String = "",
    timeoutMs!: Int64 = 1000,
    joinPump!: Bool = true,
    stopProcess!: Bool = true
): Unit {
    let sid = serviceId.trimAscii()
    let normalizedReason = if (reason.trimAscii().isEmpty()) { "stale_active_process" } else { reason.trimAscii() }
    let safeDiagnostic = servicePluginSafeDiagnosticText(if (diagnostic.trimAscii().isEmpty()) { normalizedReason } else { diagnostic })
    let effectiveTimeoutMs = max(1, timeoutMs)
    let deadlineMs = servicePluginDeadlineNowMs() + effectiveTimeoutMs
    let stopReserveMs = if (stopProcess) { max(1, effectiveTimeoutMs / 2) } else { Int64(0) }
    var dispatchStatus = "not_started"
    var ingressStopStatus = "not_started"
    match (detached.process) {
        case Some(process) =>
            servicePluginWriteFencedEventAcks(process.fenceDispatch(), process)
            if (stopProcess) {
                let ingressBudget = max(0, servicePluginDeadlineRemaining(deadlineMs) - stopReserveMs)
                if (ingressBudget > 0) {
                    try {
                        process.writeLine(
                            encodeServiceFrame(ServiceFrame(
                                "request",
                                "stop-${process.ownerId}",
                                sid,
                                method: "stop",
                                correlationId: "stop-${process.ownerId}",
                                payload: "{}"
                            )).trimAscii(),
                            timeoutMs: ingressBudget
                        )
                        ingressStopStatus = "sent"
                    } catch (_: Exception) {
                        ingressStopStatus = "write_failed"
                    }
                    let observeBudget = min(500, max(0, servicePluginDeadlineRemaining(deadlineMs) - stopReserveMs) / 2)
                    if (observeBudget > 0) {
                        servicePluginObserveIngressStop(sid, process, servicePluginDeadlineNowMs() + observeBudget)
                    }
                }
                if (ingressBudget <= 0) { ingressStopStatus = "deadline_exhausted" }
            }
            dispatchStatus = servicePluginDrainDispatchForStop(process, deadlineMs, stopReserveMs)
        case None => ()
    }
    var stopStatus = ""
    var stoppedPid: Int64 = 0
    var stoppedPidGone = false
    var preForceTerminal = None<ServicePluginStopTerminalState>
    var terminalState = ServicePluginStopTerminalState(true, "not_applicable", "not_applicable", "not_applicable", "not_applicable")
    if (stopProcess) {
        match (detached.process) {
            case Some(process) =>
                stoppedPid = process.process.pid
                match (synchronized(servicePluginProcessLock) { servicePluginRegistry.get(sid) }) {
                    case Some(record) => preForceTerminal = Some(servicePluginStopTerminalState(
                        record,
                        stoppedPid,
                        servicePluginPreForceProbeDeadline(deadlineMs)
                    ))
                    case None => ()
                }
                let remaining = servicePluginDeadlineRemaining(deadlineMs)
                let terminalReserve = min(100, max(0, remaining - 1))
                let stopped = process.stop(timeoutMs: max(1, remaining - terminalReserve))
                stopStatus = stopped.status
            case None => ()
        }
    }
    if (stoppedPid > 0) {
        let cleanupRecord = synchronized(servicePluginProcessLock) { servicePluginRegistry.get(sid) }
        let postStopTerminal = match (cleanupRecord) {
            case Some(record) => servicePluginStopTerminalState(
                record,
                stoppedPid,
                ServicePluginProbeDeadline(deadlineMs)
            )
            case None => ServicePluginStopTerminalState(true, "service_missing_after_stop", "gone", "not_applicable", "not_applicable")
        }
        terminalState = servicePluginTerminalWithPreForceEvidence(postStopTerminal, preForceTerminal)
        stoppedPidGone = terminalState.pidStatus == "gone" || terminalState.pidStatus == "not_applicable"
    }
    let cleanupIncomplete = dispatchStatus == "dispatch_pending" ||
        (stopProcess && stoppedPid > 0 && (!stoppedPidGone || !terminalState.ok))
    if (stoppedPid > 0 && stoppedPidGone && terminalState.ok && !cleanupIncomplete) {
        synchronized(servicePluginProcessLock) {
            match (servicePluginRegistry.get(sid)) {
                case Some(record) => if (record.pid == stoppedPid && !servicePluginActiveProcesses.contains(sid)) { record.pid = 0 }
                case None => ()
            }
        }
    }
    match (detached.queue) {
        case Some(queue) => queue.close(status: normalizedReason, diagnostic: safeDiagnostic)
        case None => ()
    }
    if (cleanupIncomplete) {
        match (detached.process) {
            case Some(process) => servicePluginPublishCleanupPending(
                sid,
                detached,
                process,
                stopStatus,
                "${safeDiagnostic} dispatch_status=${dispatchStatus} ${terminalState.diagnostic} cleanup_pending",
                finalStatus: "degraded",
                finalReason: normalizedReason,
                stateFlushed: false,
                ingressStopStatus: ingressStopStatus,
                dispatchStatus: dispatchStatus,
                leaseStatus: terminalState.leaseStatus,
                portStatus: terminalState.portStatus
            )
            case None => ()
        }
    }
    if (joinPump) {
        match (detached.pump) {
            case Some(future) =>
                let remaining = servicePluginDeadlineRemaining(deadlineMs)
                if (remaining > 0) { try { future.get(Duration.millisecond * remaining) } catch (_: Exception) { () } }
            case None => ()
        }
    }
    if (detached.process.isSome() || detached.queue.isSome() || detached.pump.isSome()) {
        let meta = JsonObject()
        meta.put("serviceId", JsonString(sid))
        meta.put("reason", JsonString(normalizedReason))
        meta.put("hadActiveProcess", JsonString("${detached.process.isSome()}"))
        meta.put("hadResponseQueue", JsonString("${detached.queue.isSome()}"))
        meta.put("dispatchStatus", JsonString(dispatchStatus))
        if (!stopStatus.isEmpty()) {
            meta.put("stopStatus", JsonString(stopStatus))
        }
        meta.put("diagnostic", JsonString(safeDiagnostic))
        servicePluginHostLogger.warn(MetisLogEvent.loggingRaw, "service_plugin.active_process.cleanup", meta: meta)
    }
}

private func readExpectedServiceFrame(process: ServicePluginStdioProcess, policy: ServicePluginStdoutReadPolicy): ServicePluginStdoutReadResult {
    var noiseLineCount: Int64 = 0
    var emptyLineCount: Int64 = 0
    var noiseBytes: Int64 = 0
    let noiseSamples = ArrayList<String>()

    while (true) {
        let line = match (process.readStdoutLine(policy.timeoutMs)) {
            case Some(value) => value
            case None =>
                let terminal = process.terminalStatus()
                let status = if (terminal.isEmpty()) { "timeout" } else { terminal }
                return ServicePluginStdoutReadResult(false, status: status, diagnostic: servicePluginStdoutNoiseDiagnostic(status, noiseLineCount, noiseBytes, noiseSamples))
        }
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            emptyLineCount++
            let noise = servicePluginRecordStdoutNoise(line, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            if (emptyLineCount > 2 || servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, policy)) {
                return ServicePluginStdoutReadResult(false, status: "stdout_protocol_violation", diagnostic: servicePluginStdoutNoiseDiagnostic("stdout_protocol_violation", noiseLineCount, noiseBytes, noiseSamples), noiseLineCount: noiseLineCount, noiseHash: hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n")))
            }
            continue
        }

        if (!trimmed.startsWith("{")) {
            let noise = servicePluginRecordStdoutNoise(line, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, policy)) {
                return ServicePluginStdoutReadResult(false, status: "stdout_protocol_violation", diagnostic: servicePluginStdoutNoiseDiagnostic("stdout_protocol_violation", noiseLineCount, noiseBytes, noiseSamples), noiseLineCount: noiseLineCount, noiseHash: hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n")))
            }
            continue
        }

        let decoded = decodeServiceFrame(trimmed)
        if (!decoded.ok) {
            if (decoded.errorKind == "frame_too_large") {
                return ServicePluginStdoutReadResult(false, status: "frame_too_large", diagnostic: "frame_too_large ${hashRawPayload(trimmed)}", noiseLineCount: noiseLineCount, noiseHash: hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n")))
            }
            let noise = servicePluginRecordStdoutNoise(trimmed, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, policy)) {
                return ServicePluginStdoutReadResult(false, status: "frame_decode_failed", diagnostic: servicePluginStdoutNoiseDiagnostic("frame_decode_failed", noiseLineCount, noiseBytes, noiseSamples), noiseLineCount: noiseLineCount, noiseHash: hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n")))
            }
            continue
        }

        let validation = validateServicePluginResponseFrame(
            decoded.frame,
            policy.expectedServiceId,
            policy.expectedMethod,
            expectedCapabilityId: policy.expectedCapabilityId,
            expectedCorrelationId: policy.expectedCorrelationId
        )
        if (validation.ok) {
            let noiseHash = hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n"))
            return ServicePluginStdoutReadResult(
                true,
                frame: decoded.frame,
                status: if (noiseLineCount > 0) { "stdout_protocol_noise" } else { "ok" },
                diagnostic: if (noiseLineCount > 0) { servicePluginStdoutNoiseDiagnostic("stdout_protocol_noise", noiseLineCount, noiseBytes, noiseSamples) } else { "" },
                noiseLineCount: noiseLineCount,
                noiseHash: noiseHash
            )
        }

        if (decoded.frame.frameType == "event" || decoded.frame.frameType == "audit" || decoded.frame.frameType == "heartbeat") {
            let noise = servicePluginRecordStdoutNoise(trimmed, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, policy)) {
                return ServicePluginStdoutReadResult(false, status: "stdout_protocol_violation", diagnostic: servicePluginStdoutNoiseDiagnostic("stdout_protocol_violation", noiseLineCount, noiseBytes, noiseSamples), noiseLineCount: noiseLineCount, noiseHash: hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n")))
            }
            continue
        }

        return ServicePluginStdoutReadResult(false, frame: decoded.frame, status: validation.status, diagnostic: validation.diagnostic, noiseLineCount: noiseLineCount, noiseHash: hashRawPayload(String.join(noiseSamples.toArray(), delimiter: "\n")))
    }
    ServicePluginStdoutReadResult(false, status: "timeout", diagnostic: servicePluginStdoutNoiseDiagnostic("timeout", noiseLineCount, noiseBytes, noiseSamples))
}

private func servicePluginRecordStdoutNoise(line: String, count: Int64, bytes: Int64, samples: ArrayList<String>): (Int64, Int64) {
    if (samples.size < 8) {
        samples.add(line)
    }
    (count + 1, bytes + line.size)
}

private func servicePluginStdoutNoiseExceeded(count: Int64, bytes: Int64, policy: ServicePluginStdoutReadPolicy): Bool {
    count > policy.maxNoiseLines || bytes > policy.maxNoiseBytes
}

private func servicePluginStdoutNoiseDiagnostic(kind: String, count: Int64, bytes: Int64, samples: ArrayList<String>): String {
    let raw = String.join(samples.toArray(), delimiter: "\n")
    let redacted = redactServicePayload(raw).text
    let sample = if (redacted.isEmpty()) { "" } else { " sample=${redacted}" }
    "${kind} noiseLines=${count} noiseBytes=${bytes} noiseHash=${hashRawPayload(raw)}${sample}"
}

public func setServicePluginCapabilityInvokerForTest(
    invoker: Option<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult>
): Unit {
    servicePluginCapabilityInvokerForTest = invoker
}

public func setServicePluginSupervisorConfigForTest(config: ServicePluginSupervisorConfig): Unit {
    servicePluginSupervisorConfig = config
}

public func setServicePluginSupervisorAutoStartForTest(enabled: Bool): Unit {
    servicePluginSupervisorAutoStartForTest = enabled
}

public func setServicePluginHealthzProbeForTest(
    probe: Option<(String, Int64) -> ServicePluginHealthzProbeResult>
): Unit {
    servicePluginHealthzProbeForTest = probe
}

public func setServicePluginPortOwnerProbeForTest(
    probe: Option<(Int64, Int64) -> Bool>
): Unit {
    servicePluginPortOwnerProbeForTest = probe
}

public func setServicePluginPortReleaseCommandForTest(
    probe: Option<(Int64, Int64, Int64) -> (Int64, String, String)>
): Unit {
    servicePluginPortReleaseCommandForTest = probe
}

public func setServicePluginPidProbeCommandForTest(
    probe: Option<(Int64, Int64) -> (Int64, String, String)>
): Unit {
    servicePluginPidProbeCommandForTest = probe
}

public func setServicePluginMonotonicNowForTest(probe: Option<() -> Int64>): Unit {
    synchronized(servicePluginDeadlineClockLock) {
        servicePluginMonotonicNowForTest = probe
        servicePluginLastDeadlineNowMs = 0
    }
}

public func servicePluginPidProbeStatusForTest(pid: Int64, timeoutMs: Int64): String {
    servicePluginProbePid(
        pid,
        ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + max(1, timeoutMs))
    ).status
}

public func servicePluginPortProbeStatusForTest(port: Int64, pid: Int64, timeoutMs: Int64): String {
    servicePluginPortReleaseState(
        port,
        pid,
        ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + max(1, timeoutMs))
    ).status
}

public func servicePluginDeadlineRemainingForTest(timeoutMs: Int64): (Int64, Int64) {
    let deadline = ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + max(1, timeoutMs))
    (deadline.remaining(), deadline.remaining())
}

public func setServicePluginDispatchRemainingForTest(probe: Option<() -> Int64>): Unit {
    servicePluginDispatchRemainingForTest = probe
}

public func setServicePluginBeforeDispatchWaitForTest(probe: Option<(Int64) -> Unit>): Unit {
    servicePluginBeforeDispatchWaitForTest = probe
}

public func setServicePluginDispatchSettledHookForTest(probe: Option<() -> Unit>): Unit {
    servicePluginDispatchSettledHookForTest = probe
}

public func setServicePluginCleanupFinalizeHookForTest(probe: Option<(String, Int64) -> Unit>): Unit {
    servicePluginCleanupFinalizeHookForTest = probe
}

public func servicePluginCleanupPendingIdentityForTest(serviceId: String): Option<(String, Int64, Int64, Int64)> {
    synchronized(servicePluginProcessLock) {
        match (servicePluginCleanupPendingForServiceLocked(serviceId)) {
            case Some(slot) => Some((slot.ownerId, slot.generation, slot.claimToken, slot.cleanupToken))
            case None => None<(String, Int64, Int64, Int64)>
        }
    }
}

public func servicePluginActiveIdentityForTest(serviceId: String): Option<(String, Int64, Int64)> {
    synchronized(servicePluginProcessLock) {
        match (servicePluginActiveProcesses.get(serviceId.trimAscii())) {
            case Some(process) => Some((process.ownerId, process.generation, process.claimToken))
            case None => None<(String, Int64, Int64)>
        }
    }
}

public func closeServicePluginResponseQueueForTest(serviceId: String, status!: String = "test_closed"): Bool {
    synchronized(servicePluginProcessLock) {
        match (servicePluginResponseQueues.get(serviceId.trimAscii())) {
            case Some(queue) =>
                queue.close(status: status, diagnostic: status)
                true
            case None => false
        }
    }
}

public func dropServicePluginResponseQueueForTest(serviceId: String): Bool {
    synchronized(servicePluginProcessLock) {
        let sid = serviceId.trimAscii()
        if (!servicePluginResponseQueues.contains(sid)) {
            return false
        }
        servicePluginResponseQueues.remove(sid)
        true
    }
}

public func dropServicePluginActiveProcessForTest(serviceId: String, stopProcess!: Bool = true): Bool {
    let detached = synchronized(servicePluginProcessLock) {
        let sid = serviceId.trimAscii()
        match (servicePluginActiveProcesses.get(sid)) {
            case Some(process) => detachServicePluginOwnerLocked(sid, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
            case None => ServicePluginDetachedOwner()
        }
    }
    let found = detached.process.isSome()
    cleanupDetachedServicePluginOwner(
        serviceId,
        detached,
        "test_drop",
        stopProcess: stopProcess,
        joinPump: stopProcess
    )
    found
}

public func resetServicePluginHostForTest(): Unit {
    stopAllServicePluginSupervisors()
    stopAllActiveServicePluginProcesses()
    let pendingCleanup = synchronized(servicePluginProcessLock) {
        let rows = ArrayList<ServicePluginCleanupPendingSlot>()
        for ((_, slot) in servicePluginCleanupPendingOwners) { rows.add(slot) }
        rows
    }
    for (slot in pendingCleanup) {
        match (slot.detached.queue) {
            case Some(queue) => queue.close(status: "test_reset", diagnostic: "service plugin test reset")
            case None => ()
        }
        match (slot.detached.process) {
            case Some(process) =>
                servicePluginWriteFencedEventAcks(process.fenceDispatch(), process)
                let _ = process.stop(timeoutMs: 1000)
                process.stopReaders(100)
            case None => ()
        }
        match (slot.detached.pump) {
            case Some(pump) => try { let _ = pump.get(Duration.second) } catch (_: Exception) { () }
            case None => ()
        }
    }
    synchronized(servicePluginProcessLock) {
        servicePluginCleanupPendingOwners = HashMap<String, ServicePluginCleanupPendingSlot>()
    }
    servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
    serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()
    servicePluginCapabilityInvokerForTest = None<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult>
    servicePluginHealthzProbeForTest = None<(String, Int64) -> ServicePluginHealthzProbeResult>
    servicePluginPortOwnerProbeForTest = None<(Int64, Int64) -> Bool>
    servicePluginPortReleaseCommandForTest = None<(Int64, Int64, Int64) -> (Int64, String, String)>
    servicePluginPidProbeCommandForTest = None<(Int64, Int64) -> (Int64, String, String)>
    synchronized(servicePluginDeadlineClockLock) {
        servicePluginMonotonicNowForTest = None<() -> Int64>
        servicePluginLastDeadlineNowMs = 0
    }
    servicePluginDispatchRemainingForTest = None<() -> Int64>
    servicePluginBeforeDispatchWaitForTest = None<(Int64) -> Unit>
    servicePluginDispatchSettledHookForTest = None<() -> Unit>
    servicePluginCleanupFinalizeHookForTest = None<(String, Int64) -> Unit>
    servicePluginSupervisorAutoStartForTest = true
    servicePluginSupervisorConfig = ServicePluginSupervisorConfig()
    servicePluginStartPhaseHookForTest = None<(String, String) -> Unit>
    servicePluginBeforeEventDispatchHookForTest = None<(String) -> Unit>
    servicePluginDispatchLaunchHookForTest = None<(String) -> Unit>
    servicePluginDispatchRegisterHookForTest = None<(String) -> Unit>
    servicePluginDispatchWorkerSettledHookForTest = None<(String) -> Unit>
    servicePluginEventAckWrittenHookForTest = None<(String, String, String, ServicePluginDispatchSchedulerSnapshotForTest) -> Unit>
    servicePluginBeforeCompletionAckHookForTest = None<(String) -> Bool>
    servicePluginDispatchDiagnosticHookForTest = None<(String, String, ServicePluginDispatchSnapshot) -> Unit>
    servicePluginBeforeSupervisorRegisterHookForTest = None<(String) -> Unit>
    synchronized(servicePluginProcessLock) { servicePluginHostShuttingDown = false }
}

public func withServicePluginHostTestHome<T>(label: String, block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp").join("metis-service-plugin-${servicePluginPathSegment(label)}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        try {
            return block(home)
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
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
    match (servicePluginRegistry.get(resolution.serviceId)) {
        case Some(record) =>
            match (servicePluginCapabilityInvokerForTest) {
                case Some(invoker) =>
                    let result = invoker(record.registration, request)
                    record.lastInvokeAtMillis += 1
                    if (result.ok) {
                        record.status = "running"
                        record.degradedReason = ""
                        record.lastError = ""
                    } else {
                        record.status = "degraded"
                        record.degradedReason = result.status
                        record.lastError = result.diagnostic
                    }
                    return result
                case None => return servicePluginInvokeViaStdioProcess(record, request)
            }
        case None => CapabilityInvokeResult(false, "service_missing", serviceId: resolution.serviceId, capabilityId: request.capabilityId, diagnostic: "service plugin is not registered")
    }
}

public func invokeGitCodeWritebackApplyResult(pluginId: String, payload: String, timeoutMs: Int64): CapabilityInvokeResult {
    let expectedPluginId = pluginId.trimAscii()
    let capabilityId = "gitcode.writeback.apply_result"
    let caller = CapabilityCaller(callerId: "gateway-gitcode-writeback", isOperator: true)
    let resolution = resolveCapabilityRoute(capabilityId, caller)
    if (!resolution.ok) {
        return CapabilityInvokeResult(false, resolution.status, serviceId: resolution.serviceId, capabilityId: capabilityId, diagnostic: resolution.reason)
    }
    if (!expectedPluginId.isEmpty() && resolution.serviceId != expectedPluginId) {
        return CapabilityInvokeResult(false, "service_mismatch", serviceId: resolution.serviceId, capabilityId: capabilityId, diagnostic: "writeback capability is owned by another service plugin")
    }
    invokeRegisteredCapability(CapabilityInvokeRequest(capabilityId, payload: payload, caller: caller, timeoutMillis: timeoutMs))
}

private func servicePluginInvokeViaStdioProcess(record: ServicePluginRuntimeRecord, request: CapabilityInvokeRequest): CapabilityInvokeResult {
    let serviceId = record.registration.manifest.pluginId
    let ensured = ensureServicePluginStdioProcess(record)
    if (!ensured.ok) {
        return CapabilityInvokeResult(false, ensured.status, serviceId: serviceId, capabilityId: request.capabilityId, diagnostic: ensured.diagnostic)
    }
    let process = match (ensured.process) {
        case Some(value) => value
        case None => return CapabilityInvokeResult(false, "process_start_failed", serviceId: serviceId, capabilityId: request.capabilityId, diagnostic: "service plugin process missing after start")
    }
    let queue = match (ensured.queue) {
        case Some(value) => value
        case None => return CapabilityInvokeResult(false, "process_start_failed", serviceId: serviceId, capabilityId: request.capabilityId, diagnostic: "service plugin response queue missing after start")
    }
    try {
        let invokeSequence = process.nextInvokeSequence()
        let correlationId = "corr-${process.ownerId}-${process.generation}-${invokeSequence}-${request.capabilityId}"
        let invokeFrame = ServiceFrame(
            "request",
            "invoke-${process.generation}-${invokeSequence}",
            serviceId,
            method: "invokeCapability",
            capabilityId: request.capabilityId,
            correlationId: correlationId,
            payload: request.payload
        )
        if (!queue.registerCorrelation(correlationId)) {
            return CapabilityInvokeResult(false, "stdio_closed", serviceId: serviceId, capabilityId: request.capabilityId, diagnostic: "service plugin response correlation unavailable")
        }
        try { process.writeLine(encodeServiceFrame(invokeFrame).trimAscii()) } catch (e: Exception) {
            queue.cancelCorrelation(correlationId, status: "write_failed")
            throw e
        }
        let responseRead = queue.readResponse(
            correlationId,
            serviceId,
            "invokeCapability",
            request.capabilityId,
            if (request.timeoutMillis > 0) { request.timeoutMillis } else { 30000 }
        )
        if (!responseRead.ok) {
            record.status = "degraded"
            record.degradedReason = if (responseRead.status == "timeout") { "invoke_timeout" } else { responseRead.status }
            record.lastError = if (responseRead.status == "timeout") {
                servicePluginProcessError("service plugin invoke timeout", process)
            } else {
                redactServicePayload(responseRead.diagnostic).text
            }
            return CapabilityInvokeResult(false, record.degradedReason, serviceId: serviceId, capabilityId: request.capabilityId, diagnostic: record.lastError)
        }
        let payloadValidation = validateServicePluginPayloadObject(responseRead.frame.payload)
        if (!payloadValidation.ok) {
            record.status = "degraded"
            record.degradedReason = "payload_invalid"
            record.lastError = redactServicePayload(payloadValidation.diagnostic).text
            return CapabilityInvokeResult(false, "payload_invalid", serviceId: serviceId, capabilityId: request.capabilityId, payload: responseRead.frame.payload, diagnostic: record.lastError)
        }
        let payloadStatus = parseServicePluginPayloadStatus(responseRead.frame.payload)
        let invokeOk = payloadStatus.ok
        let resultStatus = if (payloadStatus.status.isEmpty()) { if (invokeOk) { "ok" } else { "invoke_failed" } } else { payloadStatus.status }
        record.status = if (invokeOk) { "running" } else { "degraded" }
        record.degradedReason = if (invokeOk) { "" } else { resultStatus }
        record.lastError = if (invokeOk) {
            responseRead.diagnostic
        } else if (payloadStatus.diagnostic.isEmpty()) {
            redactServicePayload(responseRead.frame.payload).text
        } else {
            redactServicePayload(payloadStatus.diagnostic).text
        }
        record.lastInvokeAtMillis += 1
        CapabilityInvokeResult(invokeOk, resultStatus, serviceId: serviceId, capabilityId: request.capabilityId, payload: responseRead.frame.payload, diagnostic: record.lastError)
    } catch (e: Exception) {
        record.status = "degraded"
        record.degradedReason = "invoke_exception"
        record.lastError = e.message
        CapabilityInvokeResult(false, "invoke_exception", serviceId: serviceId, capabilityId: request.capabilityId, diagnostic: e.message)
    }
}

private func servicePluginEffectiveWorkingDirectory(ref: ServicePluginConfigRef): String {
    if (!ref.workingDirectory.isEmpty()) {
        return ref.workingDirectory
    }
    if (!ref.manifestPath.isEmpty()) {
        return Path(ref.manifestPath).parent.toString()
    }
    ""
}

private func servicePluginArgsWithConfigRef(args: Array<String>, configRef: String): Array<String> {
    let ref = configRef.trimAscii()
    if (ref.isEmpty()) {
        return args
    }
    let out = ArrayList<String>()
    var index = 0
    var injected = false
    while (index < args.size) {
        if (args[index] == "--run-args" && index + 1 < args.size) {
            out.add(args[index])
            let runArgs = args[index + 1]
            out.add(if (runArgs.contains("--config")) { runArgs } else { "--config ${ref} ${runArgs}" })
            index += 2
            injected = true
        } else {
            out.add(args[index])
            index++
        }
    }
    if (!injected) {
        let withConfig = ArrayList<String>()
        withConfig.add("--config")
        withConfig.add(ref)
        for (arg in out) {
            withConfig.add(arg)
        }
        return withConfig.toArray()
    }
    out.toArray()
}

private func servicePluginProcessError(prefix: String, process: ServicePluginStdioProcess): String {
    let parts = ArrayList<String>()
    parts.add(prefix)
    let stdout = process.stdoutSummary()
    if (!stdout.isEmpty()) {
        parts.add("stdout=${stdout}")
    }
    let stderr = process.stderrSummary()
    if (!stderr.isEmpty()) {
        parts.add("stderr=${stderr}")
    }
    redactServicePayload(String.join(parts.toArray(), delimiter: " ")).text
}

private func servicePluginPathSegment(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) { return "service-plugin" }
    trimmed.replace("/", "_").replace("\\", "_").replace(":", "_")
}

private func servicePluginRuntimeLeaseDir(serviceId: String): Path {
    CliConfig.dotDir
        .join("service-plugin")
        .join("runtime")
        .join(servicePluginPathSegment(serviceId))
}

private func servicePluginLeasePath(record: ServicePluginRuntimeRecord): String {
    let instanceId = servicePluginPathSegment(record.instanceId)
    servicePluginRuntimeLeaseDir(record.registration.manifest.pluginId)
        .join("${instanceId}.lease.json")
        .toString()
}

private class ServicePluginLeaseSnapshot {
    public let path: String
    public let state: String
    public let sessionId: String
    public let pid: Int64
    public let parentPid: Int64
    public let bindHost: String
    public let port: Int64
    public let lastHeartbeatMs: Int64
    public let startedAtMs: Int64

    public init(
        path: String,
        state!: String = "",
        sessionId!: String = "",
        pid!: Int64 = 0,
        parentPid!: Int64 = 0,
        bindHost!: String = "",
        port!: Int64 = 0,
        lastHeartbeatMs!: Int64 = 0,
        startedAtMs!: Int64 = 0
    ) {
        this.path = path
        this.state = state.trimAscii()
        this.sessionId = sessionId.trimAscii()
        this.pid = pid
        this.parentPid = parentPid
        this.bindHost = bindHost.trimAscii()
        this.port = port
        this.lastHeartbeatMs = lastHeartbeatMs
        this.startedAtMs = startedAtMs
    }
}

private class ServicePluginLeaseStartBlock {
    public let status: String
    public let diagnostic: String

    public init(status: String, diagnostic: String) {
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

private func servicePluginReadLease(path: Path): ?ServicePluginLeaseSnapshot {
    if (!exists(path)) {
        return None<ServicePluginLeaseSnapshot>
    }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        let state = servicePluginLeaseString(root, "state", fallback: servicePluginLeaseString(root, "status"))
        Some(ServicePluginLeaseSnapshot(
            path.toString(),
            state: state,
            sessionId: servicePluginLeaseString(root, "sessionId"),
            pid: servicePluginLeaseInt(root, "pid"),
            parentPid: servicePluginLeaseInt(root, "parentPid"),
            bindHost: servicePluginLeaseString(root, "bindHost"),
            port: servicePluginLeaseInt(root, "port"),
            lastHeartbeatMs: servicePluginLeaseInt(root, "lastHeartbeatMs"),
            startedAtMs: servicePluginLeaseInt(root, "startedAtMs")
        ))
    } catch (_: Exception) {
        None<ServicePluginLeaseSnapshot>
    }
}

private func servicePluginReadRestartLease(record: ServicePluginRuntimeRecord, timeoutMs: Int64): ?ServicePluginLeaseSnapshot {
    let path = Path(servicePluginLeasePath(record))
    let boundedTimeoutMs = max(0, min(1000, timeoutMs))
    var waitedMs: Int64 = 0
    while (waitedMs <= boundedTimeoutMs) {
        match (servicePluginReadLease(path)) {
            case Some(lease) => return Some(lease)
            case None => ()
        }
        if (waitedMs >= boundedTimeoutMs) {
            break
        }
        let pollMs = min(10, boundedTimeoutMs - waitedMs)
        sleep(Duration.millisecond * pollMs)
        waitedMs += pollMs
    }
    None<ServicePluginLeaseSnapshot>
}

private func servicePluginLeaseString(root: JsonObject, key: String, fallback!: String = ""): String {
    match (root.get(key)) {
        case Some(value) => try { value.asString().getValue().trimAscii() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func servicePluginLeaseInt(root: JsonObject, key: String): Int64 {
    match (root.get(key)) {
        case Some(value) =>
            try { value.asInt().getValue() } catch (_: Exception) {
                try { Int64.parse(value.asString().getValue().trimAscii()) } catch (_inner: Exception) { 0 }
            }
        case None => 0
    }
}

private class ServicePluginProbeDeadline {
    public let deadlineMs: Int64

    public init(deadlineMs: Int64) {
        this.deadlineMs = deadlineMs
    }

    public func remaining(): Int64 {
        max(0, this.deadlineMs - servicePluginDeadlineNowMs())
    }
}

private class ServicePluginPidProbeState {
    public let conclusive: Bool
    public let alive: Bool
    public let status: String
    public let diagnostic: String

    public init(conclusive: Bool, alive: Bool, status: String, diagnostic!: String = "") {
        this.conclusive = conclusive
        this.alive = alive
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

private func servicePluginProbePid(
    pid: Int64,
    deadline: ServicePluginProbeDeadline,
    maxBudgetMs!: Int64 = 0
): ServicePluginPidProbeState {
    if (pid <= 0) { return ServicePluginPidProbeState(true, false, "not_applicable") }
    let remaining = deadline.remaining()
    if (remaining <= 0) { return ServicePluginPidProbeState(false, false, "pid_probe_timeout", diagnostic: "pid_probe_timeout") }
    let timeoutMs = if (maxBudgetMs > 0) { max(1, min(remaining, maxBudgetMs)) } else { remaining }
    try {
        let result = match (servicePluginPidProbeCommandForTest) {
            case Some(probe) => probe(pid, timeoutMs)
            case None => ShellUtils.executeWithDeadline("kill -0 ${pid}", timeoutMs)
        }
        let (exitCode, stdout, stderr) = result
        let stdoutText = stdout.trimAscii()
        let stderrText = stderr.trimAscii()
        if (exitCode == 0 && stderrText.isEmpty()) { return ServicePluginPidProbeState(true, true, "alive") }
        if (exitCode == 124) { return ServicePluginPidProbeState(false, false, "pid_probe_timeout", diagnostic: "pid_probe_timeout") }
        if (exitCode == SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE) {
            return ServicePluginPidProbeState(false, false, "invalid_response_encoding", diagnostic: "pid_probe_invalid_response_encoding")
        }
        let explicitGone = exitCode == 1 && stdoutText.isEmpty() &&
            (stderrText.contains("No such process") || stderrText.contains("no such process") || stderrText.contains("ESRCH"))
        if (explicitGone) { return ServicePluginPidProbeState(true, false, "gone") }
        let status = if (stderrText.contains("Operation not permitted") || stderrText.contains("EPERM")) {
            "pid_probe_permission_denied"
        } else {
            "pid_probe_unavailable"
        }
        ServicePluginPidProbeState(false, false, status, diagnostic: status)
    } catch (_: Exception) {
        ServicePluginPidProbeState(false, false, "pid_probe_unavailable", diagnostic: "pid_probe_unavailable")
    }
}

private class ServicePluginPortReleaseState {
    public let released: Bool
    public let conclusive: Bool
    public let status: String

    public init(released: Bool, status: String, conclusive!: Bool = true) {
        this.released = released
        this.conclusive = conclusive
        this.status = status.trimAscii()
    }
}

private func servicePluginPortReleaseState(port: Int64, pid: Int64, deadline: ServicePluginProbeDeadline): ServicePluginPortReleaseState {
    if (port <= 0) { return ServicePluginPortReleaseState(true, "not_applicable") }
    let timeoutMs = deadline.remaining()
    if (timeoutMs <= 0) { return ServicePluginPortReleaseState(false, "port_probe_timeout", conclusive: false) }
    match (servicePluginPortOwnerProbeForTest) {
        case Some(probe) =>
            if (probe(port, pid)) {
                return ServicePluginPortReleaseState(false, "port_release_timeout")
            }
            return ServicePluginPortReleaseState(true, "released")
        case None => ()
    }
    try {
        let result = match (servicePluginPortReleaseCommandForTest) {
            case Some(probe) => probe(port, pid, timeoutMs)
            case None => ShellUtils.executeWithDeadline(
                "lsof -nP -iTCP:${port} -sTCP:LISTEN -Fp",
                timeoutMs
            )
        }
        let (exitCode, stdout, stderr) = result
        let stderrText = stderr.trimAscii()
        if (exitCode == 124) { return ServicePluginPortReleaseState(false, "port_probe_timeout", conclusive: false) }
        if (exitCode == SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE) {
            return ServicePluginPortReleaseState(false, "invalid_response_encoding", conclusive: false)
        }
        if (exitCode == 1 && stderrText.isEmpty()) { return ServicePluginPortReleaseState(true, "released") }
        if (!stderrText.isEmpty()) { return ServicePluginPortReleaseState(false, "port_probe_unavailable", conclusive: false) }
        if (exitCode != 0) { return ServicePluginPortReleaseState(false, "port_probe_unavailable", conclusive: false) }
        for (line in stdout.split("\n")) {
            if (line.trimAscii().startsWith("p")) {
                return ServicePluginPortReleaseState(false, "port_release_timeout")
            }
        }
        ServicePluginPortReleaseState(false, "port_probe_invalid", conclusive: false)
    } catch (_: Exception) {
        ServicePluginPortReleaseState(false, "port_probe_unavailable", conclusive: false)
    }
}

private func servicePluginNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func servicePluginDeadlineNowMs(): Int64 {
    synchronized(servicePluginDeadlineClockLock) {
        let observed = match (servicePluginMonotonicNowForTest) {
            case Some(probe) => probe()
            case None => (MonoTime.now() - servicePluginMonotonicOrigin).toMilliseconds()
        }
        servicePluginLastDeadlineNowMs = max(servicePluginLastDeadlineNowMs, observed)
        servicePluginLastDeadlineNowMs
    }
}

private func servicePluginReadHttpBytes(response: HttpResponse): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(1024, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
        if (out.size > 1024) {
            break
        }
    }
    out.toArray()
}

private func servicePluginNativeHealthzProbe(url: String, timeoutMs: Int64): ServicePluginHealthzProbeResult {
    let startedAtMs = servicePluginNowMs()
    try {
        let builder = ClientBuilder()
        builder.readTimeout(Duration.millisecond * max(1, timeoutMs))
        let client = builder.build()
        try {
            let response = client.send(HttpRequestBuilder().url(url).get().build())
            let _ = servicePluginReadHttpBytes(response)
            let elapsedMs = max(0, servicePluginNowMs() - startedAtMs)
            let statusCode = Int64(response.status)
            let ok = statusCode >= 200 && statusCode < 300
            ServicePluginHealthzProbeResult(ok, statusCode: statusCode, durationMs: elapsedMs, diagnostic: "healthz_status=${statusCode}")
        } finally {
            client.close()
        }
    } catch (e: Exception) {
        let elapsedMs = max(0, servicePluginNowMs() - startedAtMs)
        let diagnostic = if (elapsedMs >= timeoutMs) { "healthz_timeout" } else { "healthz_error ${e.message}" }
        ServicePluginHealthzProbeResult(false, statusCode: 0, durationMs: elapsedMs, diagnostic: redactServicePayload(diagnostic).text)
    }
}

private func servicePluginHealthzProbe(url: String, timeoutMs: Int64): ServicePluginHealthzProbeResult {
    match (servicePluginHealthzProbeForTest) {
        case Some(probe) => probe(url, timeoutMs)
        case None => servicePluginNativeHealthzProbe(url, timeoutMs)
    }
}

private func servicePluginLeaseAgeMs(lease: ServicePluginLeaseSnapshot, nowMs: Int64): Int64 {
    if (lease.lastHeartbeatMs > 0) {
        return max(0, nowMs - lease.lastHeartbeatMs)
    }
    if (lease.startedAtMs > 0) {
        return max(0, nowMs - lease.startedAtMs)
    }
    -1
}

public func probeServicePluginHealth(serviceId: String, nowMs!: Int64 = servicePluginNowMs()): ServicePluginHealthProbeResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) => probeServicePluginHealth(record, nowMs: nowMs)
        case None => ServicePluginHealthProbeResult(diagnostic: "service_missing")
    }
}

private func probeServicePluginHealth(record: ServicePluginRuntimeRecord, nowMs!: Int64 = servicePluginNowMs()): ServicePluginHealthProbeResult {
    let serviceId = record.registration.manifest.pluginId
    if (record.status == "registered" || record.status == "stopped" || record.status == "disabled") {
        return ServicePluginHealthProbeResult(
            pidAlive: false,
            stdioAlive: false,
            healthzOk: true,
            diagnostic: "supervisor_skipped_status=${record.status}"
        )
    }

    var pidAlive = false
    var stdioAlive = false
    synchronized(servicePluginProcessLock) {
        match (servicePluginActiveProcesses.get(serviceId)) {
            case Some(process) =>
                pidAlive = process.process.isAlive()
                match (servicePluginResponseQueues.get(serviceId)) {
                    case Some(queue) => stdioAlive = pidAlive && !queue.isClosed()
                    case None => stdioAlive = false
                }
            case None =>
                pidAlive = false
                stdioAlive = false
        }
    }

    let leasePath = Path(servicePluginLeasePath(record))
    match (servicePluginReadLease(leasePath)) {
        case Some(lease) =>
            let leaseAgeMs = servicePluginLeaseAgeMs(lease, nowMs)
            if (!pidAlive) {
                return ServicePluginHealthProbeResult(
                    pidAlive: false,
                    stdioAlive: false,
                    leaseState: lease.state,
                    leaseAgeMs: leaseAgeMs,
                    healthzOk: false,
                    port: lease.port,
                    diagnostic: "process_exited leaseState=${lease.state} pid=${lease.pid} port=${lease.port}"
                )
            }
            if (lease.bindHost.isEmpty() || lease.port <= 0) {
                return ServicePluginHealthProbeResult(
                    pidAlive: pidAlive,
                    stdioAlive: stdioAlive,
                    leaseState: lease.state,
                    leaseAgeMs: leaseAgeMs,
                    healthzOk: true,
                    port: lease.port,
                    diagnostic: "listener_endpoint_missing leaseState=${lease.state} bindHost=${lease.bindHost} port=${lease.port}"
                )
            }
            let healthz = servicePluginHealthzProbe("http://${lease.bindHost}:${lease.port}/healthz", servicePluginSupervisorConfig.healthTimeoutMs)
            ServicePluginHealthProbeResult(
                pidAlive: pidAlive,
                stdioAlive: stdioAlive,
                leaseState: lease.state,
                leaseAgeMs: leaseAgeMs,
                healthzOk: healthz.ok,
                healthzDurationMs: healthz.durationMs,
                port: lease.port,
                diagnostic: "${healthz.diagnostic} leaseState=${lease.state} bindHost=${lease.bindHost} port=${lease.port}"
            )
        case None =>
            if (!pidAlive) {
                return ServicePluginHealthProbeResult(
                    pidAlive: false,
                    stdioAlive: false,
                    healthzOk: false,
                    diagnostic: "process_exited lease_missing"
                )
            }
            ServicePluginHealthProbeResult(
                pidAlive: pidAlive,
                stdioAlive: stdioAlive,
                healthzOk: true,
                diagnostic: "lease_missing"
            )
    }
}

public func classifyServicePluginHealth(
    probe: ServicePluginHealthProbeResult,
    previousFailures!: Int64,
    config!: ServicePluginSupervisorConfig = ServicePluginSupervisorConfig()
): ServicePluginHealthClassification {
    if (probe.diagnostic.contains("supervisor_skipped_status=")) {
        return ServicePluginHealthClassification("healthy", diagnostic: probe.diagnostic)
    }
    if (!probe.pidAlive) {
        return ServicePluginHealthClassification(
            "degraded",
            reason: "process_exited",
            failureCount: max(1, previousFailures + 1),
            shouldRecover: true,
            diagnostic: probe.diagnostic
        )
    }
    if (!probe.stdioAlive) {
        let failures = previousFailures + 1
        return ServicePluginHealthClassification(
            "degraded",
            reason: "stdio_closed",
            failureCount: failures,
            shouldRecover: failures >= config.failureThreshold,
            diagnostic: probe.diagnostic
        )
    }
    if (probe.diagnostic.contains("lease_missing") || probe.diagnostic.contains("listener_endpoint_missing")) {
        return ServicePluginHealthClassification("healthy", diagnostic: probe.diagnostic)
    }
    if (!probe.healthzOk) {
        let failures = previousFailures + 1
        let reason = if (probe.diagnostic.contains("healthz_timeout")) {
            "healthz_timeout"
        } else if (probe.diagnostic.contains("port_not_owned")) {
            "port_not_owned"
        } else {
            "healthz_unhealthy"
        }
        return ServicePluginHealthClassification(
            "degraded",
            reason: reason,
            failureCount: failures,
            shouldRecover: failures >= config.failureThreshold,
            diagnostic: probe.diagnostic
        )
    }
    ServicePluginHealthClassification("healthy", failureCount: 0, diagnostic: probe.diagnostic)
}

private func servicePluginSupervisorReason(reason: String): Bool {
    let normalized = reason.trimAscii()
    normalized == "process_exited" ||
        normalized == "stdio_closed" ||
        normalized == "healthz_timeout" ||
        normalized == "healthz_unhealthy" ||
        normalized == "port_not_owned"
}

private func servicePluginSupervisorProbeSummary(probe: ServicePluginHealthProbeResult, classification: ServicePluginHealthClassification): String {
    let diag = redactServicePayload(probe.diagnostic).text
    "status=${classification.status} reason=${classification.reason} pidAlive=${probe.pidAlive} stdioAlive=${probe.stdioAlive} leaseState=${probe.leaseState} leaseAgeMs=${probe.leaseAgeMs} healthzOk=${probe.healthzOk} healthzDurationMs=${probe.healthzDurationMs} port=${probe.port} failureCount=${classification.failureCount} diagnostic=${diag}"
}

private func servicePluginSupervisorRecordProbe(record: ServicePluginRuntimeRecord, probe: ServicePluginHealthProbeResult, classification: ServicePluginHealthClassification, nowMs: Int64): Unit {
    record.supervisorFailureCount = classification.failureCount
    record.supervisorLastProbeAtMs = nowMs
    record.supervisorLastProbe = servicePluginSupervisorProbeSummary(probe, classification)
    if (classification.status == "healthy") {
        record.supervisorLastDegradedReason = ""
        if (record.status == "degraded" && servicePluginSupervisorReason(record.degradedReason)) {
            record.status = "running"
            record.degradedReason = ""
            record.lastError = ""
        }
        return
    }
    record.status = "degraded"
    record.degradedReason = classification.reason
    record.supervisorLastDegradedReason = classification.reason
    record.lastError = redactServicePayload(if (classification.diagnostic.isEmpty()) { classification.reason } else { classification.diagnostic }).text
}

private func servicePluginSupervisorStopTimeoutMs(config: ServicePluginSupervisorConfig): Int64 {
    max(1000, min(5000, config.healthTimeoutMs * 10))
}

private func recoverServicePlugin(record: ServicePluginRuntimeRecord, reason: String, nowMs!: Int64 = servicePluginNowMs()): Bool {
    let serviceId = record.registration.manifest.pluginId
    let config = servicePluginSupervisorConfig
    let recoveryDeadline = ServicePluginProbeDeadline(
        servicePluginDeadlineNowMs() + servicePluginSupervisorStopTimeoutMs(config)
    )
    if (record.supervisorLastRestartAtMs > 0 && nowMs - record.supervisorLastRestartAtMs < config.restartCooldownMs) {
        record.lastError = serviceJoinStrings([record.lastError, "restart_cooldown reason=${reason}"], " ")
        return false
    }

    if (reason == "process_exited") {
        servicePluginStopSupervisorWorker(serviceId)
        let recoveryOwner = synchronized(servicePluginProcessLock) {
            match (servicePluginActiveProcesses.get(serviceId)) {
                case Some(process) =>
                    if (process.process.isAlive()) {
                        (ServicePluginDetachedOwner(), true)
                    } else {
                        (detachServicePluginOwnerLocked(
                            serviceId,
                            ownerId: process.ownerId,
                            generation: process.generation,
                            claimToken: process.claimToken
                        ), false)
                    }
                case None => (ServicePluginDetachedOwner(), false)
            }
        }
        if (recoveryOwner[1]) { return true }
        let detached = recoveryOwner[0]
        cleanupDetachedServicePluginOwner(
            serviceId,
            detached,
            "process_exited",
            diagnostic: "supervisor recovery process_exited"
        )
        record.pid = 0
        record.status = "stopped"
    } else {
        let previousPid = record.pid
        let stopped = stopServicePlugin(serviceId, reason: "supervisor_${reason}", timeoutMillis: servicePluginSupervisorStopTimeoutMs(config))
        if (!stopped.ok) {
            let lease = servicePluginReadLease(Path(servicePluginLeasePath(record)))
            let portState = match (stopped.portStatus) {
                case "released" => ServicePluginPortReleaseState(true, "released")
                case "not_applicable" => ServicePluginPortReleaseState(true, "not_applicable")
                case "port_release_timeout" => ServicePluginPortReleaseState(false, "port_release_timeout")
                case status => ServicePluginPortReleaseState(false, status, conclusive: false)
            }
            if (!portState.released) {
                match (lease) {
                    case Some(value) =>
                        record.lastError = "${stopped.diagnostic} ${portState.status} port=${value.port} pid=${value.pid} portOwnerAlive=${portState.conclusive && !portState.released}"
                    case None =>
                        record.lastError = "${stopped.diagnostic} ${portState.status} port=0 pid=0"
                }
                record.pid = previousPid
            } else {
                record.lastError = stopped.diagnostic
            }
            record.status = "degraded"
            record.degradedReason = reason
            return false
        }
    }

    match (servicePluginReadLease(Path(servicePluginLeasePath(record)))) {
        case Some(lease) =>
            let portState = servicePluginPortReleaseState(lease.port, lease.pid, recoveryDeadline)
            if (!portState.released) {
                record.status = "degraded"
                record.degradedReason = reason
                record.lastError = "${portState.status} port=${lease.port} pid=${lease.pid} portOwnerAlive=${portState.conclusive && !portState.released}"
                return false
            }
        case None => ()
    }

    let ensured = ensureServicePluginStdioProcess(record, startupTimeoutMs: max(1000, config.healthTimeoutMs * 10))
    if (!ensured.ok) {
        record.status = "degraded"
        record.degradedReason = if (record.degradedReason.isEmpty()) { reason } else { record.degradedReason }
        record.lastError = if (ensured.diagnostic.isEmpty()) { reason } else { ensured.diagnostic }
        return false
    }
    record.supervisorRestartCount++
    record.supervisorLastRestartAtMs = nowMs
    // The initialize frame and lease file travel over independent channels.
    // A child may flush initialize immediately before atomically publishing its
    // new lease, especially under full-suite scheduler pressure.
    match (servicePluginReadRestartLease(record, max(250, config.healthTimeoutMs * 10))) {
        case Some(lease) =>
            if (lease.bindHost.isEmpty() || lease.port <= 0) {
                record.status = "degraded"
                record.degradedReason = "restart_healthz_failed"
                record.supervisorLastDegradedReason = "restart_healthz_failed"
                record.lastError = "restart_healthz_failed reason=${reason} listener_endpoint_missing leaseState=${lease.state} bindHost=${lease.bindHost} port=${lease.port}"
                return false
            }
            let healthz = servicePluginHealthzProbe("http://${lease.bindHost}:${lease.port}/healthz", config.healthTimeoutMs)
            if (!healthz.ok) {
                record.status = "degraded"
                record.degradedReason = "restart_healthz_failed"
                record.supervisorLastDegradedReason = "restart_healthz_failed"
                record.lastError = "restart_healthz_failed reason=${reason} ${servicePluginSafeDiagnosticText(healthz.diagnostic)} leaseState=${lease.state} bindHost=${lease.bindHost} port=${lease.port}"
                return false
            }
            record.status = "running"
            record.degradedReason = ""
            record.supervisorLastDegradedReason = ""
            record.supervisorFailureCount = 0
            record.lastError = "recovery_success reason=${reason} healthz_status=${healthz.statusCode} port=${lease.port}"
            true
        case None =>
            record.status = "degraded"
            record.degradedReason = "restart_healthz_failed"
            record.supervisorLastDegradedReason = "restart_healthz_failed"
            record.lastError = "restart_healthz_failed reason=${reason} lease_missing"
            false
    }
}

private func servicePluginRunSupervisorTick(serviceId: String, nowMs: Int64, allowRecover!: Bool = true): ServicePluginSupervisorTickResult {
    let sid = serviceId.trimAscii()
    match (servicePluginRegistry.get(sid)) {
        case Some(record) =>
            if (!servicePluginSupervisorConfig.enabled) {
                let probe = ServicePluginHealthProbeResult(healthzOk: true, diagnostic: "supervisor_disabled")
                let classification = ServicePluginHealthClassification("healthy", diagnostic: "supervisor_disabled")
                servicePluginSupervisorRecordProbe(record, probe, classification, nowMs)
                return ServicePluginSupervisorTickResult(true, "disabled", probe: probe, classification: classification)
            }
            let probe = probeServicePluginHealth(record, nowMs: nowMs)
            let classification = classifyServicePluginHealth(probe, previousFailures: record.supervisorFailureCount, config: servicePluginSupervisorConfig)
            servicePluginSupervisorRecordProbe(record, probe, classification, nowMs)
            servicePluginFlushUnconfirmedForService(sid)
            var recovered = false
            if (allowRecover && classification.shouldRecover) {
                recovered = recoverServicePlugin(record, classification.reason, nowMs: nowMs)
            }
            ServicePluginSupervisorTickResult(true, classification.status, probe: probe, classification: classification, recovered: recovered, diagnostic: record.lastError)
        case None => ServicePluginSupervisorTickResult(false, "missing", diagnostic: "service plugin is not registered")
    }
}

public func runServicePluginSupervisorTickForTest(serviceId: String, nowMs!: Int64 = servicePluginNowMs()): ServicePluginSupervisorTickResult {
    // Manual supervisor tests own the probe sequence; stop the background worker
    // so fake healthz probes are not consumed by a concurrent tick.
    servicePluginSupervisorAutoStartForTest = false
    servicePluginStopSupervisorWorker(serviceId.trimAscii())
    servicePluginRunSupervisorTick(serviceId, nowMs, allowRecover: true)
}

private func logServicePluginSupervisorTick(serviceId: String, tick: ServicePluginSupervisorTickResult): Unit {
    let meta = JsonObject()
    meta.put("serviceId", JsonString(serviceId.trimAscii()))
    meta.put("status", JsonString(tick.status))
    meta.put("classification", JsonString(tick.classification.status))
    meta.put("reason", JsonString(tick.classification.reason))
    meta.put("recovered", JsonString("${tick.recovered}"))
    servicePluginHostLogger.info(MetisLogEvent.loggingRaw, "service_plugin.supervisor.tick", meta: meta)
}

private func servicePluginRunSupervisorWorkerTick(serviceId: String, nowMs: Int64): Unit {
    let sid = serviceId.trimAscii()
    try {
        let tick = servicePluginRunSupervisorTick(sid, nowMs, allowRecover: true)
        logServicePluginSupervisorTick(sid, tick)
    } catch (e: Exception) {
        let safeError = servicePluginSafeDiagnosticText(e.message)
        match (servicePluginRegistry.get(sid)) {
            case Some(record) =>
                record.status = "degraded"
                record.degradedReason = "supervisor_exception"
                record.supervisorLastDegradedReason = "supervisor_exception"
                record.lastError = safeError
            case None => ()
        }
        let meta = JsonObject()
        meta.put("serviceId", JsonString(sid))
        meta.put("error", JsonString(safeError))
        servicePluginHostLogger.error(MetisLogEvent.loggingRaw, "service_plugin.supervisor.exception", meta: meta)
    }
}

public func runServicePluginSupervisorWorkerTickForTest(serviceId: String, nowMs!: Int64 = servicePluginNowMs()): Unit {
    servicePluginRunSupervisorWorkerTick(serviceId, nowMs)
}

private func servicePluginReserveSupervisorLocked(serviceId: String): Option<ServicePluginSupervisorStopFlag> {
    if (!servicePluginSupervisorConfig.enabled) {
        return None<ServicePluginSupervisorStopFlag>
    }
    if (!servicePluginSupervisorAutoStartForTest) {
        return None<ServicePluginSupervisorStopFlag>
    }
    synchronized(servicePluginSupervisorLock) {
        match (servicePluginSupervisorWorkers.get(serviceId)) {
            case Some(existing) =>
                if (!existing.stopped()) {
                    return None<ServicePluginSupervisorStopFlag>
                }
            case None => ()
        }
        let flag = ServicePluginSupervisorStopFlag()
        servicePluginSupervisorWorkers[serviceId] = flag
        Some(flag)
    }
}

private func servicePluginSpawnSupervisorWorker(serviceId: String, flag: ServicePluginSupervisorStopFlag): Unit {
    spawn {
        while (!flag.stopped()) {
            sleep(Duration.millisecond * servicePluginSupervisorConfig.intervalMs)
            if (flag.stopped()) {
                return
            }
            servicePluginRunSupervisorWorkerTick(serviceId, servicePluginNowMs())
        }
    }
}

private func servicePluginStartSupervisorWorker(record: ServicePluginRuntimeRecord): Bool {
    let serviceId = record.registration.manifest.pluginId
    match (servicePluginBeforeSupervisorRegisterHookForTest) { case Some(hook) => hook(serviceId) case None => () }
    let reserved = synchronized(servicePluginProcessLock) {
        if (servicePluginHostShuttingDown || servicePluginHasCleanupPendingLocked(serviceId)) {
            None<ServicePluginSupervisorStopFlag>
        } else {
            servicePluginReserveSupervisorLocked(serviceId)
        }
    }
    match (reserved) {
        case Some(flag) =>
            servicePluginSpawnSupervisorWorker(serviceId, flag)
            true
        case None => !synchronized(servicePluginProcessLock) { servicePluginHostShuttingDown || servicePluginHasCleanupPendingLocked(serviceId) }
    }
}

private func servicePluginStopSupervisorWorker(serviceId: String): Unit {
    synchronized(servicePluginSupervisorLock) {
        match (servicePluginSupervisorWorkers.get(serviceId.trimAscii())) {
            case Some(flag) =>
                flag.stop()
                servicePluginSupervisorWorkers.remove(serviceId.trimAscii())
            case None => ()
        }
    }
}

private func stopAllServicePluginSupervisors(): Unit {
    synchronized(servicePluginSupervisorLock) {
        for ((_, flag) in servicePluginSupervisorWorkers) {
            flag.stop()
        }
        servicePluginSupervisorWorkers = HashMap<String, ServicePluginSupervisorStopFlag>()
    }
}

private func servicePluginLeaseStartDiagnostic(status: String, lease: ServicePluginLeaseSnapshot, pidAlive: Bool, portOwnerAlive: Bool): String {
    "${status} sessionId=${lease.sessionId} state=${lease.state} pid=${lease.pid} parentPid=${lease.parentPid} pidAlive=${pidAlive} port=${lease.port} portOwnerAlive=${portOwnerAlive}"
}

private func servicePluginBlockingLeaseBeforeStart(serviceId: String, deadlineMs: Int64): ?ServicePluginLeaseStartBlock {
    let dir = servicePluginRuntimeLeaseDir(serviceId)
    if (!exists(dir)) {
        return None<ServicePluginLeaseStartBlock>
    }
    let deadline = ServicePluginProbeDeadline(deadlineMs)
    try {
        for (entry in Directory.readFrom(dir)) {
            if (!entry.isRegular() || !entry.name.endsWith(".lease.json")) {
                continue
            }
            match (servicePluginReadLease(entry.path)) {
                case Some(lease) =>
                    let pidState = servicePluginProbePid(lease.pid, deadline)
                    if (!pidState.conclusive) {
                        let status = pidState.status
                        return Some(ServicePluginLeaseStartBlock(status, "${status} sessionId=${lease.sessionId} state=${lease.state} pid=${lease.pid}"))
                    }
                    let pidAlive = pidState.alive
                    if (lease.state == "running" && pidAlive) {
                        let status = "stale_lease_before_start"
                        return Some(ServicePluginLeaseStartBlock(status, servicePluginLeaseStartDiagnostic(status, lease, pidAlive, false)))
                    }
                    if (lease.state == "orphan_detected") {
                        if (pidAlive) {
                            let status = "orphan_lease_alive_before_start"
                            return Some(ServicePluginLeaseStartBlock(status, servicePluginLeaseStartDiagnostic(status, lease, pidAlive, false)))
                        }
                        let portState = servicePluginPortReleaseState(lease.port, lease.pid, deadline)
                        if (!portState.released) {
                            let status = if (portState.conclusive) { "orphan_port_owner_alive_before_start" } else { portState.status }
                            return Some(ServicePluginLeaseStartBlock(status, servicePluginLeaseStartDiagnostic(status, lease, pidAlive, true)))
                        }
                    }
                case None => ()
            }
        }
    } catch (_: Exception) {
        ()
    }
    None<ServicePluginLeaseStartBlock>
}

private class ServicePluginStopTerminalState {
    public let ok: Bool
    public let diagnostic: String
    public let pidStatus: String
    public let leaseStatus: String
    public let portStatus: String

    public init(ok: Bool, diagnostic: String, pidStatus: String, leaseStatus: String, portStatus: String) {
        this.ok = ok
        this.diagnostic = diagnostic.trimAscii()
        this.pidStatus = pidStatus.trimAscii()
        this.leaseStatus = leaseStatus.trimAscii()
        this.portStatus = portStatus.trimAscii()
    }
}

private func servicePluginStopTerminalState(
    record: ServicePluginRuntimeRecord,
    expectedPid: Int64,
    deadline: ServicePluginProbeDeadline
): ServicePluginStopTerminalState {
    if (deadline.remaining() <= 0) {
        return ServicePluginStopTerminalState(false, "terminal_probe_timeout", "pid_probe_timeout", "lease_probe_timeout", "port_probe_timeout")
    }
    let leasePath = Path(servicePluginLeasePath(record))
    var leaseStatus = "not_applicable"
    var leaseDiagnostic = "lease_missing_after_stop"
    var leaseAllowsTerminal = true
    var portPid: Int64 = 0
    var port: Int64 = 0
    var portEligible = false
    match (servicePluginReadLease(leasePath)) {
        case Some(lease) =>
            let expectedParentPid = Int64(getProcessId())
            if (lease.sessionId != record.instanceId || lease.pid != expectedPid || lease.parentPid != expectedParentPid) {
                leaseStatus = "identity_mismatch"
                leaseAllowsTerminal = false
                leaseDiagnostic = "lease_identity_mismatch_after_stop expectedSessionId=${record.instanceId} expectedPid=${expectedPid} expectedParentPid=${expectedParentPid} actualSessionId=${lease.sessionId} actualPid=${lease.pid} actualParentPid=${lease.parentPid}"
            } else {
                leaseStatus = if (lease.state == "stopped") { "stopped" } else { "not_stopped" }
                leaseAllowsTerminal = lease.state == "stopped"
                leaseDiagnostic = if (leaseAllowsTerminal) {
                    "lease_stopped state=stopped pid=${lease.pid} parentPid=${lease.parentPid} port=${lease.port}"
                } else {
                    "lease_not_stopped_after_stop state=${lease.state} pid=${lease.pid} parentPid=${lease.parentPid} port=${lease.port}"
                }
                portPid = lease.pid
                port = lease.port
                portEligible = true
            }
        case None =>
            if (exists(leasePath)) {
                leaseStatus = "invalid"
                leaseAllowsTerminal = false
                leaseDiagnostic = "lease_invalid_after_stop"
            }
    }
    let pidBudget = if (portEligible) { max(1, deadline.remaining() / 2) } else { deadline.remaining() }
    let pidState = servicePluginProbePid(expectedPid, deadline, maxBudgetMs: pidBudget)
    let portState = if (portEligible) {
        servicePluginPortReleaseState(port, portPid, deadline)
    } else if (leaseStatus == "not_applicable") {
        ServicePluginPortReleaseState(true, "not_applicable")
    } else {
        ServicePluginPortReleaseState(false, "not_checked", conclusive: false)
    }
    let diagnostic = if (leaseStatus == "not_stopped") {
        "${leaseDiagnostic} pidAlive=${pidState.alive} pidStatus=${pidState.status} portStatus=${portState.status}"
    } else if (leaseStatus == "identity_mismatch" || leaseStatus == "invalid") {
        "${leaseDiagnostic} pidStatus=${pidState.status}"
    } else if (!pidState.conclusive) {
        "${pidState.diagnostic} ${leaseDiagnostic} portStatus=${portState.status}"
    } else if (pidState.alive) {
        "pid_alive_after_stop pid=${expectedPid} ${leaseDiagnostic} portStatus=${portState.status}"
    } else if (!portState.released) {
        "${portState.status} pid=${portPid} port=${port} ${leaseDiagnostic}"
    } else {
        leaseDiagnostic
    }
    ServicePluginStopTerminalState(
        pidState.conclusive && !pidState.alive && leaseAllowsTerminal && portState.released,
        diagnostic,
        pidState.status,
        leaseStatus,
        portState.status
    )
}

private func servicePluginLeaseStopDiagnostic(record: ServicePluginRuntimeRecord): String {
    servicePluginStopTerminalState(
        record,
        record.pid,
        ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000)
    ).diagnostic
}

private func servicePluginLeaseStopped(record: ServicePluginRuntimeRecord, deadlineMs: Int64): Bool {
    if (record.pid <= 0) { return false }
    servicePluginStopTerminalState(record, record.pid, ServicePluginProbeDeadline(deadlineMs)).ok
}

private func servicePluginDeadlineRemaining(deadlineMs: Int64): Int64 {
    max(0, deadlineMs - servicePluginDeadlineNowMs())
}

private func servicePluginPreForceProbeDeadline(deadlineMs: Int64): ServicePluginProbeDeadline {
    let remaining = servicePluginDeadlineRemaining(deadlineMs)
    ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + min(25, remaining))
}

private func servicePluginTerminalWithPreForceEvidence(
    postStop: ServicePluginStopTerminalState,
    preForce: Option<ServicePluginStopTerminalState>
): ServicePluginStopTerminalState {
    let postUnavailable = postStop.pidStatus == "pid_probe_timeout" && postStop.leaseStatus == "lease_probe_timeout" &&
        postStop.portStatus == "port_probe_timeout"
    if (!postUnavailable) { return postStop }
    match (preForce) {
        case Some(observed) => if (!observed.ok) { observed } else { postStop }
        case None => postStop
    }
}

private func servicePluginProcessEnvironment(record: ServicePluginRuntimeRecord): HashMap<String, String> {
    let env = HashMap<String, String>()
    for ((key, value) in getVariables()) {
        env[key] = value
    }
    env["METIS_SERVICE_PLUGIN_ID"] = record.registration.manifest.pluginId
    env["METIS_SERVICE_PLUGIN_INSTANCE_ID"] = record.instanceId
    env["METIS_SERVICE_PLUGIN_SESSION_ID"] = record.instanceId
    env["METIS_SERVICE_PLUGIN_PARENT_PID"] = "${getProcessId()}"
    env["METIS_SERVICE_PLUGIN_LEASE_PATH"] = servicePluginLeasePath(record)
    env
}

private func stopAllActiveServicePluginProcesses(): Unit {
    let detached = ArrayList<(String, ServicePluginDetachedOwner)>()
    let pending = ArrayList<ServicePluginStartClaim>()
    synchronized(servicePluginProcessLock) {
        for ((serviceId, process) in servicePluginActiveProcesses) {
            detached.add((serviceId, ServicePluginDetachedOwner(
                process: Some(process),
                queue: servicePluginResponseQueues.get(serviceId),
                pump: servicePluginEventPumps.get(serviceId)
            )))
        }
        for ((serviceId, claim) in servicePluginStartClaims) {
            claim.cancel()
            pending.add(claim)
        }
        servicePluginActiveProcesses = HashMap<String, ServicePluginStdioProcess>()
        servicePluginResponseQueues = HashMap<String, ServicePluginResponseQueue>()
        servicePluginEventPumps = HashMap<String, Future<Unit>>()
        servicePluginStartClaims = HashMap<String, ServicePluginStartClaim>()
    }
    for ((serviceId, owner) in detached) {
        cleanupDetachedServicePluginOwner(serviceId, owner, "stopped", diagnostic: "service plugin host reset")
    }
    for (claim in pending) {
        let _ = claim.waitSettled(2000)
    }
}

public func shutdownServicePluginHost(reason!: String = "shutdown", timeoutMillis!: Int64 = 30000): ServicePluginHostShutdownResult {
    let deadlineMs = servicePluginDeadlineNowMs() + max(1, min(timeoutMillis, 30000))
    let activeIds = ArrayList<String>()
    let stopResults = HashMap<String, ServiceStopResult>()
    let cleanupFinalizeResults = HashMap<String, ServicePluginCleanupFinalizeResult>()
    let claims = ArrayList<(String, ServicePluginStartClaim)>()
    let supervisorFlags = ArrayList<ServicePluginSupervisorStopFlag>()
    let fencedDispatches = ArrayList<(ServicePluginStdioProcess, ArrayList<ServicePluginDispatchTask>)>()
    synchronized(servicePluginProcessLock) {
        servicePluginHostShuttingDown = true
        for ((serviceId, claim) in servicePluginStartClaims) {
            claim.cancel()
            claims.add((serviceId, claim))
            match (servicePluginRegistry.get(serviceId)) {
                case Some(record) => record.status = "stopping"
                case None => ()
            }
        }
        for ((serviceId, process) in servicePluginActiveProcesses) {
            fencedDispatches.add((process, process.fenceDispatch()))
            activeIds.add(serviceId)
        }
        synchronized(servicePluginSupervisorLock) {
            for ((_, flag) in servicePluginSupervisorWorkers) { supervisorFlags.add(flag) }
            servicePluginSupervisorWorkers = HashMap<String, ServicePluginSupervisorStopFlag>()
        }
        for ((serviceId, record) in servicePluginRegistry) {
            if (record.status == "registered" && !servicePluginStartClaims.contains(serviceId) && !servicePluginActiveProcesses.contains(serviceId)) {
                record.status = "stopped"
                record.pid = 0
                record.stateFlushed = true
            }
        }
    }
    for ((process, tasks) in fencedDispatches) { servicePluginWriteFencedEventAcks(tasks, process) }
    for (flag in supervisorFlags) { flag.stop() }
    for ((serviceId, _) in claims) { servicePluginRunStartPhaseHook(serviceId, "claim_cancelled") }
    for ((serviceId, claim) in claims) {
        let remaining = servicePluginDeadlineRemaining(deadlineMs)
        if (remaining > 0) { let _ = claim.waitSettled(remaining) }
        synchronized(servicePluginProcessLock) {
            if (!servicePluginStartClaims.contains(serviceId) && !servicePluginActiveProcesses.contains(serviceId)) {
                match (servicePluginRegistry.get(serviceId)) {
                    case Some(record) =>
                        record.pid = 0
                        record.status = "stopped"
                        record.stateFlushed = true
                    case None => ()
                }
            }
        }
    }
    for (serviceId in activeIds) {
        let remaining = servicePluginDeadlineRemaining(deadlineMs)
        if (remaining > 0) {
            stopResults[serviceId] = stopServicePlugin(serviceId, reason: reason, timeoutMillis: remaining)
        } else {
            stopResults[serviceId] = ServiceStopResult(false, serviceId, "cleanup_pending", diagnostic: "service plugin host shutdown deadline exhausted")
        }
    }
    let leftovers = ArrayList<(String, ServicePluginDetachedOwner)>()
    synchronized(servicePluginProcessLock) {
        let ids = ArrayList<String>()
        for ((serviceId, _) in servicePluginActiveProcesses) { ids.add(serviceId) }
        for (serviceId in ids) {
            let detached = detachServicePluginOwnerLocked(serviceId)
            if (detached.process.isSome() || detached.queue.isSome() || detached.pump.isSome()) {
                leftovers.add((serviceId, detached))
            }
        }
    }
    for ((serviceId, detached) in leftovers) {
        cleanupDetachedServicePluginOwner(
            serviceId,
            detached,
            "stopped",
            diagnostic: "service plugin host shutdown",
            timeoutMs: max(1, servicePluginDeadlineRemaining(deadlineMs))
        )
    }
    let pendingCleanup = synchronized(servicePluginProcessLock) {
        let rows = ArrayList<ServicePluginCleanupPendingSlot>()
        for ((_, slot) in servicePluginCleanupPendingOwners) { rows.add(slot) }
        rows
    }
    for (slot in pendingCleanup) {
        let remaining = servicePluginDeadlineRemaining(deadlineMs)
        if (remaining <= 0) { break }
        match (slot.detached.process) {
            case Some(process) =>
                let finalized = servicePluginFinalizeCleanupPending(slot.serviceId, process, timeoutMs: remaining)
                if (finalized.finalized) { cleanupFinalizeResults[slot.serviceId] = finalized }
            case None => ()
        }
    }
    synchronized(servicePluginProcessLock) {
        let results = ArrayList<ServiceStopResult>()
        var allStopped = true
        for ((serviceId, record) in servicePluginRegistry) {
            match (stopResults.get(serviceId)) {
                case Some(result) =>
                    let recovered = !result.ok && record.status == "stopped" && !servicePluginHasCleanupPendingLocked(serviceId)
                    if (recovered) {
                        let finalized = cleanupFinalizeResults.get(serviceId)
                        let ingressStatus = match (finalized) { case Some(value) => value.ingressStopStatus case None => result.ingressStopStatus }
                        let dispatchStatus = match (finalized) { case Some(value) => value.dispatchStatus case None => result.dispatchStatus }
                        let ownerStatus = match (finalized) { case Some(value) => value.ownerStopStatus case None => result.ownerStopStatus }
                        let leaseStatus = match (finalized) { case Some(value) => value.leaseStatus case None => result.leaseStatus }
                        let portStatus = match (finalized) { case Some(value) => value.portStatus case None => result.portStatus }
                        let terminalFields = (dispatchStatus == "drained" || dispatchStatus == "cancelled" || dispatchStatus == "not_applicable") &&
                            (ownerStatus == "graceful_exited" || ownerStatus == "terminated" || ownerStatus == "force_terminated" || ownerStatus == "already_stopped") &&
                            (leaseStatus == "stopped" || leaseStatus == "not_applicable") &&
                            (portStatus == "released" || portStatus == "not_applicable")
                        results.add(ServiceStopResult(
                            terminalFields,
                            serviceId,
                            if (terminalFields) { "stopped" } else { "cleanup_pending" },
                            stateFlushed: terminalFields && record.stateFlushed,
                            diagnostic: "${result.diagnostic} cleanup_finalized",
                            ingressStopStatus: ingressStatus,
                            dispatchStatus: dispatchStatus,
                            ownerStopStatus: ownerStatus,
                            leaseStatus: leaseStatus,
                            portStatus: portStatus
                        ))
                        if (!terminalFields) { allStopped = false }
                    } else {
                        results.add(result)
                        if (!result.ok) { allStopped = false }
                    }
                case None =>
                    let noResources = record.pid <= 0 && !servicePluginActiveProcesses.contains(serviceId) &&
                        !servicePluginStartClaims.contains(serviceId) && !servicePluginHasCleanupPendingLocked(serviceId)
                    if (noResources) {
                        results.add(ServiceStopResult(
                            true,
                            serviceId,
                            "not_applicable",
                            stateFlushed: record.stateFlushed,
                            diagnostic: record.lastError,
                            ingressStopStatus: "not_applicable",
                            dispatchStatus: "not_applicable",
                            ownerStopStatus: "not_applicable",
                            leaseStatus: "not_applicable",
                            portStatus: "not_applicable"
                        ))
                    } else {
                        results.add(ServiceStopResult(false, serviceId, "cleanup_pending", stateFlushed: false, diagnostic: record.lastError))
                        allStopped = false
                    }
            }
        }
        ServicePluginHostShutdownResult(allStopped, if (allStopped) { "stopped" } else { "cleanup_pending" }, results)
    }
}

private func servicePluginStartClaimMatchesLocked(serviceId: String, claim: ServicePluginStartClaim): Bool {
    match (servicePluginStartClaims.get(serviceId.trimAscii())) {
        case Some(current) => current.token == claim.token && current.ownerId == claim.ownerId && current.instanceId == claim.instanceId
        case None => false
    }
}

private func failServicePluginStartClaim(
    record: ServicePluginRuntimeRecord,
    claim: ServicePluginStartClaim,
    status: String,
    diagnostic: String,
    process!: Option<ServicePluginStdioProcess> = None<ServicePluginStdioProcess>
): ServicePluginProcessEnsureResult {
    let serviceId = record.registration.manifest.pluginId
    let safeDiagnostic = servicePluginSafeDiagnosticText(diagnostic)
    match (process) {
        case Some(value) => let _ = value.stop()
        case None => ()
    }
    synchronized(servicePluginProcessLock) {
        if (servicePluginStartClaimMatchesLocked(serviceId, claim)) {
            servicePluginStartClaims.remove(serviceId)
            if (record.instanceId == claim.instanceId && record.status != "stopping") {
                record.status = "degraded"
                record.degradedReason = status
                record.lastError = safeDiagnostic
                record.pid = 0
            }
        }
    }
    claim.settle(status, safeDiagnostic)
    ServicePluginProcessEnsureResult(false, status, diagnostic: safeDiagnostic)
}

private func ensureServicePluginStdioProcess(record: ServicePluginRuntimeRecord, startupTimeoutMs!: Int64 = 10000): ServicePluginProcessEnsureResult {
    let serviceId = record.registration.manifest.pluginId
    if (record.registration.manifest.entryCommand.isEmpty()) {
        record.status = "degraded"
        record.degradedReason = "missing_entry_command"
        record.lastError = record.degradedReason
        return ServicePluginProcessEnsureResult(false, "missing_entry_command", diagnostic: record.lastError)
    }
    let cwd = servicePluginEffectiveWorkingDirectory(record.registration.configRef)
    if (!cwd.isEmpty() && !exists(Path(cwd))) {
        record.status = "degraded"
        record.degradedReason = "cwd_missing"
        record.lastError = "service plugin working directory missing: ${redactServicePayload(cwd).text}"
        return ServicePluginProcessEnsureResult(false, "cwd_missing", diagnostic: record.lastError)
    }

    var stale = ServicePluginDetachedOwner()
    var early = None<ServicePluginProcessEnsureResult>
    var follower = None<ServicePluginStartClaim>
    var claim = ServicePluginStartClaim(0, "", "")
    synchronized(servicePluginProcessLock) {
        if (servicePluginHostShuttingDown) {
            early = Some(ServicePluginProcessEnsureResult(false, "stopping", diagnostic: "service plugin host is shutting down"))
        } else if (servicePluginHasCleanupPendingLocked(serviceId)) {
            early = Some(ServicePluginProcessEnsureResult(false, "cleanup_pending", diagnostic: "service plugin owner cleanup is pending"))
        } else if (record.status == "stopping") {
            early = Some(ServicePluginProcessEnsureResult(false, "stopping", diagnostic: "service plugin stop in progress"))
        } else if (servicePluginStartClaims.contains(serviceId)) {
            follower = servicePluginStartClaims.get(serviceId)
        } else if (servicePluginActiveProcesses.contains(serviceId) && servicePluginResponseQueues.contains(serviceId)) {
            let activeProcess = servicePluginActiveProcesses[serviceId]
            let activeQueue = servicePluginResponseQueues[serviceId]
            if (activeProcess.process.isAlive() && !activeQueue.isClosed()) {
                early = Some(ServicePluginProcessEnsureResult(true, "running", process: Some(activeProcess), queue: Some(activeQueue)))
            } else {
                stale = detachServicePluginOwnerLocked(serviceId, ownerId: activeProcess.ownerId, generation: activeProcess.generation, claimToken: activeProcess.claimToken)
            }
        } else if (servicePluginActiveProcesses.contains(serviceId) || servicePluginResponseQueues.contains(serviceId)) {
            stale = detachServicePluginOwnerLocked(serviceId)
        }
        if (early.isNone() && follower.isNone()) {
            record.instanceSeq++
            record.instanceId = "${serviceId}-${record.instanceSeq}"
            servicePluginStartClaimSequence++
            servicePluginBrokerOwnerSequence++
            let ownerId = "service-plugin:${serviceId}:${record.instanceId}:${servicePluginBrokerOwnerSequence}"
            claim = ServicePluginStartClaim(servicePluginStartClaimSequence, ownerId, record.instanceId)
            servicePluginStartClaims[serviceId] = claim
            record.status = "starting"
            record.degradedReason = ""
            record.lastError = ""
        }
    }
    match (early) {
        case Some(result) => return result
        case None => ()
    }
    match (follower) {
        case Some(existingClaim) =>
            servicePluginRunStartPhaseHook(serviceId, "follower_waiting")
            if (!existingClaim.waitSettled(max(1, startupTimeoutMs))) {
                return ServicePluginProcessEnsureResult(false, "initialize_timeout", diagnostic: "service plugin concurrent start wait timed out")
            }
            let outcome = existingClaim.outcome()
            if (outcome[0] == "published") {
                return synchronized(servicePluginProcessLock) {
                    match (servicePluginActiveProcesses.get(serviceId)) {
                        case Some(active) =>
                            match (servicePluginResponseQueues.get(serviceId)) {
                                case Some(activeQueue) => ServicePluginProcessEnsureResult(true, "running", process: Some(active), queue: Some(activeQueue))
                                case None => ServicePluginProcessEnsureResult(false, if (record.status == "stopping" || record.status == "stopped") { "stopping" } else { "stdio_closed" }, diagnostic: "published service plugin response queue missing")
                            }
                        case None => ServicePluginProcessEnsureResult(false, if (record.status == "stopping" || record.status == "stopped") { "stopping" } else { "stdio_closed" }, diagnostic: "published service plugin owner missing")
                    }
                }
            }
            return ServicePluginProcessEnsureResult(false, outcome[0], diagnostic: outcome[1])
        case None => ()
    }
    cleanupDetachedServicePluginOwner(serviceId, stale, "stdio_closed", diagnostic: "ensure stale active process")

    match (servicePluginBlockingLeaseBeforeStart(serviceId, servicePluginDeadlineNowMs() + max(1, startupTimeoutMs))) {
        case Some(block) => return failServicePluginStartClaim(record, claim, block.status, block.diagnostic)
        case None => ()
    }
    try { Directory.create(servicePluginRuntimeLeaseDir(serviceId), recursive: true) } catch (_: Exception) { () }
    let args = servicePluginArgsWithConfigRef(record.registration.manifest.entryArgs, record.registration.configRef.configPath)
    let ownerEnvironment = ArrayList<(String, String)>()
    for ((key, value) in servicePluginProcessEnvironment(record)) { ownerEnvironment.add((key, value)) }

    if (!claim.transition("launching")) { return failServicePluginStartClaim(record, claim, "stopping", "service plugin start cancelled") }
    servicePluginRunStartPhaseHook(serviceId, "before_start")
    if (claim.cancelled()) { return failServicePluginStartClaim(record, claim, "stopping", "service plugin start cancelled") }
    let started = try {
        gatewayStdioBroker().startOwner(ManagedStdioOwnerSpec(
            claim.ownerId,
            record.registration.manifest.entryCommand,
            args: args,
            workingDirectory: if (cwd.isEmpty()) { None<String> } else { Some(cwd) },
            environment: ownerEnvironment.toArray(),
            stdinMode: "line",
            outputMode: "line"
        ), timeoutMs: startupTimeoutMs)
    } catch (e: Exception) {
        logServicePluginProcessStartFailed(record, e.message)
        return failServicePluginStartClaim(record, claim, "process_start_failed", e.message)
    }
    if (!started.ok) {
        logServicePluginProcessStartFailed(record, started.status)
        return failServicePluginStartClaim(record, claim, "process_start_failed", "service plugin broker owner start failed: ${started.status}")
    }
    let process = ServicePluginStdioProcess(
        gatewayStdioBroker(),
        serviceId,
        claim.ownerId,
        started.generation,
        started.pid,
        claimToken: claim.token
    )
    if (claim.cancelled()) { return failServicePluginStartClaim(record, claim, "stopping", "service plugin start cancelled", process: Some(process)) }
    let attached = synchronized(servicePluginProcessLock) {
        if (servicePluginStartClaimMatchesLocked(serviceId, claim) && record.status != "stopping") {
            record.pid = started.pid
            true
        } else {
            false
        }
    }
    if (!attached) {
        return failServicePluginStartClaim(record, claim, "stopping", "service plugin start cancelled", process: Some(process))
    }
    logServicePluginProcessStart(record, started.pid)
    let _ = claim.transition("attached")
    servicePluginRunStartPhaseHook(serviceId, "after_attach")
    if (claim.cancelled()) { return failServicePluginStartClaim(record, claim, "stopping", "service plugin start cancelled", process: Some(process)) }

    let _ = claim.transition("initializing")
    let initRead = readExpectedServiceFrame(process, ServicePluginStdoutReadPolicy(startupTimeoutMs, serviceId, "initialize"))
    if (!initRead.ok) {
        let status = if (initRead.status == "timeout") { "initialize_timeout" } else { initRead.status }
        let diagnostic = if (initRead.status == "timeout") {
            servicePluginProcessError("service plugin initialize timeout", process)
        } else {
            initRead.diagnostic
        }
        return failServicePluginStartClaim(record, claim, status, diagnostic, process: Some(process))
    }
    let initPayloadValidation = validateServicePluginPayloadObject(initRead.frame.payload)
    if (!initPayloadValidation.ok) {
        return failServicePluginStartClaim(record, claim, "payload_invalid", initPayloadValidation.diagnostic, process: Some(process))
    }
    let initPayloadStatus = parseServicePluginPayloadStatus(initRead.frame.payload)
    if (!initPayloadStatus.parsed || !initPayloadStatus.okPresent || !initPayloadStatus.ok) {
        let diagnostic = if (!initPayloadStatus.diagnostic.isEmpty()) {
            initPayloadStatus.diagnostic
        } else if (!initPayloadStatus.status.isEmpty() && initPayloadStatus.status != "ok" && initPayloadStatus.status != "invalid_payload") {
            "initialize rejected: ${initPayloadStatus.status}"
        } else {
            "initialize payload missing boolean ok"
        }
        return failServicePluginStartClaim(record, claim, "initialize_failed", diagnostic, process: Some(process))
    }

    let queue = ServicePluginResponseQueue()
    servicePluginRunStartPhaseHook(serviceId, "before_publish")
    let gate = ServicePluginEventPumpGate()
    let pump = spawn {
        gate.waitOpen()
        servicePluginEventPump(record, process, queue)
    }
    let published = synchronized(servicePluginProcessLock) {
        if (servicePluginStartClaimMatchesLocked(serviceId, claim) && record.status != "stopping" && !claim.cancelled()) {
            servicePluginStartClaims.remove(serviceId)
            servicePluginActiveProcesses[serviceId] = process
            servicePluginResponseQueues[serviceId] = queue
            servicePluginEventPumps[serviceId] = pump
            record.status = "running"
            record.degradedReason = ""
            record.lastError = ""
            let _ = claim.transition("published")
            true
        } else {
            false
        }
    }
    gate.open()
    if (!published) {
        queue.close(status: "stopped", diagnostic: "service plugin start cancelled")
        let _ = process.stop()
        try { pump.get(Duration.second) } catch (_: Exception) { () }
        synchronized(servicePluginProcessLock) {
            if (servicePluginStartClaimMatchesLocked(serviceId, claim)) { servicePluginStartClaims.remove(serviceId) }
        }
        claim.settle("stopping", "service plugin start cancelled")
        return ServicePluginProcessEnsureResult(false, "stopping", diagnostic: "service plugin start cancelled")
    }
    claim.settle("published", "")
    if (!servicePluginStartSupervisorWorker(record)) {
        return ServicePluginProcessEnsureResult(false, "stopping", diagnostic: "service plugin host is shutting down")
    }
    servicePluginFlushUnconfirmedReceipts(record, process, queue)
    ServicePluginProcessEnsureResult(true, "running", process: Some(process), queue: Some(queue))
}

private func servicePluginEventPump(record: ServicePluginRuntimeRecord, process: ServicePluginStdioProcess, queue: ServicePluginResponseQueue): Unit {
    let serviceId = record.registration.manifest.pluginId
    var noiseLineCount: Int64 = 0
    var noiseBytes: Int64 = 0
    var idlePolls: Int64 = 0
    var exitDrainPolls: Int64 = 0
    let noiseSamples = ArrayList<String>()
    while (true) {
        let current = synchronized(servicePluginProcessLock) {
            servicePluginOwnerMatchesLocked(
                serviceId,
                process.ownerId,
                process.generation,
                claimToken: process.claimToken
            )
        }
        if (!current) {
            servicePluginDrainDetachedOwner(process)
            return
        }
        let readTimeoutMs: Int64 = if (exitDrainPolls > 0) { 50 } else { 1000 }
        let line = match (process.readStdoutLine(readTimeoutMs)) {
            case Some(value) => value
            case None =>
                if (process.process.isAlive()) {
                    idlePolls++
                    exitDrainPolls = 0
                } else if (!process.stdoutClosed() && exitDrainPolls < 20) {
                    exitDrainPolls++
                    continue
                } else {
                    idlePolls = 3600
                }
                if (idlePolls < 3600) {
                    continue
                }
                let terminal = process.terminalStatus()
                let degradedReason = if (terminal.isEmpty()) { "process_exited" } else { terminal }
                let diagnostic = servicePluginProcessError("service plugin process stdout closed", process)
                var detached = ServicePluginDetachedOwner()
                var stopping = false
                synchronized(servicePluginProcessLock) {
                    if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                        stopping = record.status == "stopping"
                        if (!stopping) {
                            record.status = "degraded"
                            record.degradedReason = degradedReason
                            record.lastError = diagnostic
                            detached = detachServicePluginOwnerLocked(serviceId, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
                        }
                    }
                }
                if (stopping) { return }
                cleanupDetachedServicePluginOwner(
                    serviceId,
                    detached,
                    degradedReason,
                    diagnostic: diagnostic,
                    joinPump: false
                )
                return
        }
        idlePolls = 0
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty() || !trimmed.startsWith("{")) {
            let noise = servicePluginRecordStdoutNoise(line, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, ServicePluginStdoutReadPolicy(1000, serviceId, "eventPump"))) {
                let diagnostic = servicePluginStdoutNoiseDiagnostic("stdout_protocol_violation", noiseLineCount, noiseBytes, noiseSamples)
                var detached = ServicePluginDetachedOwner()
                synchronized(servicePluginProcessLock) {
                    if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                        record.status = "degraded"
                        record.degradedReason = "stdout_protocol_violation"
                        record.lastError = diagnostic
                        detached = detachServicePluginOwnerLocked(serviceId, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
                    }
                }
                cleanupDetachedServicePluginOwner(serviceId, detached, "stdout_protocol_violation", diagnostic: diagnostic, joinPump: false)
                return
            }
            continue
        }
        let decoded = decodeServiceFrame(trimmed)
        if (!decoded.ok) {
            let noise = servicePluginRecordStdoutNoise(trimmed, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            let diagnostic = servicePluginStdoutNoiseDiagnostic(decoded.errorKind, noiseLineCount, noiseBytes, noiseSamples)
            if (decoded.errorKind == "frame_too_large") {
                var detached = ServicePluginDetachedOwner()
                synchronized(servicePluginProcessLock) {
                    if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                        record.status = "degraded"
                        record.degradedReason = "frame_too_large"
                        record.lastError = diagnostic
                        detached = detachServicePluginOwnerLocked(serviceId, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
                    }
                }
                cleanupDetachedServicePluginOwner(serviceId, detached, "frame_too_large", diagnostic: "frame_too_large ${hashRawPayload(trimmed)}", joinPump: false)
                return
            }
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, ServicePluginStdoutReadPolicy(1000, serviceId, "eventPump"))) {
                var detached = ServicePluginDetachedOwner()
                synchronized(servicePluginProcessLock) {
                    if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                        record.status = "degraded"
                        record.degradedReason = "frame_decode_failed"
                        record.lastError = diagnostic
                        detached = detachServicePluginOwnerLocked(serviceId, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
                    }
                }
                cleanupDetachedServicePluginOwner(serviceId, detached, "frame_decode_failed", diagnostic: diagnostic, joinPump: false)
                return
            }
            continue
        }
        let frame = decoded.frame
        if (frame.frameType == "response") {
            synchronized(servicePluginProcessLock) {
                if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                    queue.append(frame)
                }
            }
            continue
        }
        if (frame.frameType == "heartbeat" || frame.method == "heartbeat") {
            let currentHeartbeat = synchronized(servicePluginProcessLock) {
                servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)
            }
            if (currentHeartbeat) { let _ = handleServiceHeartbeat(frame) }
            continue
        }
        if (frame.frameType == "event") {
            let task = ServicePluginDispatchTask(record, frame)
            let hasAckIdentity = task.hasAckIdentity()
            if (hasAckIdentity && !task.ackable()) {
                synchronized(servicePluginRuntimeRecordLock) { record.lastError = "invalid_event_ack_identity" }
                continue
            }
            let handled = handleServiceCapabilityEvent(ServiceCapabilityEvent(frame.serviceId, frame.capabilityId, payload: frame.payload))
            if (!handled.ok) {
                synchronized(servicePluginRuntimeRecordLock) { record.lastError = redactServicePayload(handled.diagnostic).text }
                if (task.ackable()) { servicePluginWriteEventAck(task, "admission", "retry", process) }
                continue
            }
            let currentEvent = synchronized(servicePluginProcessLock) {
                if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                    process.trySubmitDispatch(task)
                } else { "cancelled" }
            }
            servicePluginFlushDispatchDiagnostics(process)
            match (currentEvent) {
                case "started" =>
                    synchronized(servicePluginRuntimeRecordLock) { servicePluginRetainEventFrameLocked(record, frame) }
                    if (servicePluginWriteEventAck(task, "admission", "accepted", process)) {
                        let confirmed = process.confirmAdmission(task)
                        servicePluginFlushDispatchDiagnostics(process)
                        if (confirmed == "started") {
                            servicePluginLaunchEventDispatchTask(task, process)
                        } else if (confirmed == "cancelled") {
                            let _ = servicePluginWriteEventAck(task, "admission", "cancelled", process)
                        }
                    } else {
                        let next = process.rollbackAdmittedTask(task)
                        servicePluginFlushDispatchDiagnostics(process)
                        match (next) { case Some(queued) => servicePluginLaunchEventDispatchTask(queued, process) case None => () }
                    }
                case "queued" =>
                    synchronized(servicePluginRuntimeRecordLock) { servicePluginRetainEventFrameLocked(record, frame) }
                    if (servicePluginWriteEventAck(task, "admission", "accepted", process)) {
                        let confirmed = process.confirmAdmission(task)
                        servicePluginFlushDispatchDiagnostics(process)
                        if (confirmed == "started") {
                            servicePluginLaunchEventDispatchTask(task, process)
                        } else if (confirmed == "cancelled") {
                            let _ = servicePluginWriteEventAck(task, "admission", "cancelled", process)
                        }
                    } else {
                        let _ = process.rollbackAdmittedTask(task)
                        servicePluginFlushDispatchDiagnostics(process)
                    }
                case "queue_full" =>
                    if (task.ackable()) {
                        let _ = servicePluginWriteEventAck(task, "admission", "queue_full", process)
                    } else {
                        servicePluginWriteFencedEventAcks(process.fenceDispatch(), process)
                        var detached = ServicePluginDetachedOwner()
                        synchronized(servicePluginProcessLock) {
                            if (servicePluginOwnerMatchesLocked(serviceId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                                synchronized(servicePluginRuntimeRecordLock) {
                                    record.status = "degraded"
                                    record.degradedReason = "dispatch_queue_full_unrecoverable"
                                    record.lastError = "dispatch_queue_full_unrecoverable"
                                }
                                detached = detachServicePluginOwnerLocked(serviceId, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
                            }
                        }
                        cleanupDetachedServicePluginOwner(serviceId, detached, "dispatch_queue_full_unrecoverable", diagnostic: "dispatch_queue_full_unrecoverable", joinPump: false)
                        return
                    }
                case _ => let _ = servicePluginWriteEventAck(task, "admission", "cancelled", process)
            }
            continue
        }
        if (frame.frameType == "audit") {
            continue
        }
    }
}

private func servicePluginDrainDetachedOwner(process: ServicePluginStdioProcess, timeoutMs!: Int64 = 1000): Unit {
    let deadlineMs = servicePluginDeadlineNowMs() + max(1, timeoutMs)
    let stopReserveMs = min(500, max(100, timeoutMs / 2))
    while (servicePluginDeadlineRemaining(deadlineMs) > stopReserveMs) {
        let remaining = servicePluginDeadlineRemaining(deadlineMs) - stopReserveMs
        let _ = process.readStdoutLine(min(50, max(1, remaining)))
        if (!process.terminalStatus().isEmpty()) { return }
    }
    let remaining = servicePluginDeadlineRemaining(deadlineMs)
    if (remaining > 0 && process.terminalStatus().isEmpty()) {
        let _ = process.stop(timeoutMs: remaining)
    }
}

private func servicePluginWriteEventAck(task: ServicePluginDispatchTask, phase: String, status: String, process: ServicePluginStdioProcess): Bool {
    if (!task.ackable()) { return true }
    let current = synchronized(servicePluginProcessLock) {
        servicePluginOwnerMatchesLocked(task.record.registration.manifest.pluginId, process.ownerId, process.generation, claimToken: process.claimToken)
    }
    if (!current) { return false }
    let ack = ServiceEventAck(METIS_SERVICE_PLUGIN_PROTOCOL_VERSION, task.deliveryId, task.eventId, task.attemptToken, phase, status)
    let frame = ServiceFrame(
        "response", "event-ack-${process.generation}-${task.admissionSequence}-${phase}",
        task.record.registration.manifest.pluginId, method: "emitCapabilityEvent",
        capabilityId: "gitcode.event.accepted", correlationId: task.attemptToken,
        payload: encodeServiceEventAckPayload(ack)
    )
    try {
        process.writeLine(encodeServiceFrame(frame).trimAscii())
        process.recordEventAckWritten(phase, status)
        match (servicePluginEventAckWrittenHookForTest) {
            case Some(hook) => hook(task.frame.frameId, phase, status, process.dispatchSchedulerSnapshotForTest())
            case None => ()
        }
        true
    } catch (_: Exception) { false }
}

private func servicePluginCompletionConfirmationPayloadValid(
    payload: String,
    receipt: ServicePluginWebhookReceipt
): Bool {
    try {
        let root = JsonValue.fromStr(payload).asObject()
        let ok = root.get("ok").getOrThrow().asBool().getValue()
        let status = root.get("status").getOrThrow().asString().getValue().trimAscii()
        let protocolVersion = root.get("protocolVersion").getOrThrow().asString().getValue().trimAscii()
        let deliveryId = root.get("deliveryId").getOrThrow().asString().getValue().trimAscii()
        let eventId = root.get("eventId").getOrThrow().asString().getValue().trimAscii()
        let attemptToken = root.get("attemptToken").getOrThrow().asString().getValue().trimAscii()
        ok && (status == "host_completed" || status == "already_completed") &&
            protocolVersion == METIS_SERVICE_PLUGIN_PROTOCOL_VERSION &&
            deliveryId == receipt.deliveryId && eventId == receipt.eventId && attemptToken == receipt.attemptToken
    } catch (_: Exception) { false }
}

private func servicePluginConfirmCompletedReceipt(
    record: ServicePluginRuntimeRecord,
    process: ServicePluginStdioProcess,
    queue: ServicePluginResponseQueue,
    receipt: ServicePluginWebhookReceipt,
    frameId: String,
    timeoutMs!: Int64 = 3000,
    requireDispatchAllowed!: Bool = false
): Bool {
    let allowed = match (servicePluginBeforeCompletionAckHookForTest) {
        case Some(hook) => hook(frameId)
        case None => true
    }
    if (!allowed) { return false }
    let current = synchronized(servicePluginProcessLock) {
        servicePluginOwnerMatchesLocked(record.registration.manifest.pluginId, process.ownerId, process.generation, claimToken: process.claimToken)
    }
    if (!current || (requireDispatchAllowed && !process.dispatchAllowed())) { return false }
    let sequence = process.nextInvokeSequence()
    let correlationId = "event-confirm-${process.ownerId}-${process.generation}-${sequence}"
    let ack = ServiceEventAck(
        METIS_SERVICE_PLUGIN_PROTOCOL_VERSION,
        receipt.deliveryId,
        receipt.eventId,
        receipt.attemptToken,
        "completion",
        "completed"
    )
    let request = ServiceFrame(
        "request",
        "event-confirm-${process.generation}-${sequence}",
        record.registration.manifest.pluginId,
        method: "emitCapabilityEvent",
        capabilityId: "gitcode.event.accepted",
        correlationId: correlationId,
        payload: encodeServiceEventAckPayload(ack)
    )
    if (!queue.registerCorrelation(correlationId)) { return false }
    if (requireDispatchAllowed && !process.dispatchAllowed()) {
        queue.cancelCorrelation(correlationId, status: "dispatch_fenced")
        return false
    }
    try {
        process.writeLine(encodeServiceFrame(request).trimAscii())
    } catch (_: Exception) {
        queue.cancelCorrelation(correlationId, status: "write_failed")
        return false
    }
    let response = queue.readResponse(
        correlationId,
        record.registration.manifest.pluginId,
        "emitCapabilityEvent",
        "gitcode.event.accepted",
        max(1, timeoutMs)
    )
    if (!response.ok || !servicePluginCompletionConfirmationPayloadValid(response.frame.payload, receipt)) { return false }
    let removed = servicePluginWebhookReceiptStore().confirmAndRemove(
        receipt.serviceId,
        receipt.deliveryId,
        receipt.eventId,
        receipt.attemptToken
    )
    if (removed.status != "confirmed") { return false }
    process.recordCompletionConfirmed()
    match (servicePluginEventAckWrittenHookForTest) {
        case Some(hook) => hook(frameId, "completion", "completed", process.dispatchSchedulerSnapshotForTest())
        case None => ()
    }
    true
}

private func servicePluginFlushUnconfirmedReceipts(
    record: ServicePluginRuntimeRecord,
    process: ServicePluginStdioProcess,
    queue: ServicePluginResponseQueue,
    limit!: Int64 = 4
): Int64 {
    let listed = servicePluginWebhookReceiptStore().listUnconfirmed(limit: limit)
    if (!listed.ok) { return 0 }
    var confirmed: Int64 = 0
    for (receipt in listed.receipts) {
        if (receipt.serviceId != record.registration.manifest.pluginId) { continue }
        if (servicePluginConfirmCompletedReceipt(record, process, queue, receipt, "outbox-${receipt.eventId}", timeoutMs: 500)) { confirmed++ }
    }
    confirmed
}

private func servicePluginFlushUnconfirmedForService(serviceId: String): Int64 {
    var record = None<ServicePluginRuntimeRecord>
    var process = None<ServicePluginStdioProcess>
    var queue = None<ServicePluginResponseQueue>
    synchronized(servicePluginProcessLock) {
        match (servicePluginRegistry.get(serviceId)) { case Some(value) => record = Some(value) case None => () }
        match (servicePluginActiveProcesses.get(serviceId)) { case Some(value) => process = Some(value) case None => () }
        match (servicePluginResponseQueues.get(serviceId)) { case Some(value) => queue = Some(value) case None => () }
    }
    if (record.isNone() || process.isNone() || queue.isNone()) { return 0 }
    servicePluginFlushUnconfirmedReceipts(record.getOrThrow(), process.getOrThrow(), queue.getOrThrow())
}

private func servicePluginCancelCompletionWaits(serviceId: String): Int64 {
    var queue = None<ServicePluginResponseQueue>
    synchronized(servicePluginProcessLock) {
        match (servicePluginResponseQueues.get(serviceId.trimAscii())) {
            case Some(value) => queue = Some(value)
            case None => ()
        }
    }
    match (queue) {
        case Some(value) => value.cancelCorrelationsWithPrefix("event-confirm-")
        case None => Int64(0)
    }
}

public func flushServicePluginUnconfirmedReceiptsForTest(serviceId: String): Int64 {
    servicePluginFlushUnconfirmedForService(serviceId.trimAscii())
}

private func servicePluginWriteFencedEventAcks(tasks: ArrayList<ServicePluginDispatchTask>, process: ServicePluginStdioProcess): Unit {
    servicePluginFlushDispatchDiagnostics(process)
    for (task in tasks) { let _ = servicePluginWriteEventAck(task, "admission", "cancelled", process) }
}

private func servicePluginLaunchEventDispatchTask(task: ServicePluginDispatchTask, process: ServicePluginStdioProcess): Unit {
    let gate = ServicePluginEventPumpGate()
    let token = process.nextDispatchFutureToken()
    var launched = None<Future<Unit>>
    try {
        match (servicePluginDispatchLaunchHookForTest) { case Some(hook) => hook(task.frame.frameId) case None => () }
        let future = spawn {
            if (!gate.waitOpen()) {
                gate.markWorkerSettled()
                match (servicePluginDispatchWorkerSettledHookForTest) { case Some(hook) => hook(task.frame.frameId) case None => () }
                return
            }
            var completed = false
            try {
            let hookGate = ServicePluginDispatchGuardHookGate()
            let dispatchAllowed = { =>
                let allowedBeforeHook = synchronized(servicePluginProcessLock) {
                    servicePluginOwnerMatchesLocked(task.record.registration.manifest.pluginId, process.ownerId, process.generation, claimToken: process.claimToken) && process.dispatchAllowed()
                }
                if (!allowedBeforeHook) { return false }
                if (hookGate.take()) {
                    match (servicePluginBeforeEventDispatchHookForTest) {
                        case Some(hook) => hook(task.record.registration.manifest.pluginId)
                        case None => ()
                    }
                }
                synchronized(servicePluginProcessLock) {
                    servicePluginOwnerMatchesLocked(task.record.registration.manifest.pluginId, process.ownerId, process.generation, claimToken: process.claimToken) && process.dispatchAllowed()
                }
            }
            let dispatch = dispatchServicePluginEvent(task.frame, dispatchAllowed: dispatchAllowed)
            synchronized(servicePluginProcessLock) {
                if (servicePluginOwnerMatchesLocked(
                    task.record.registration.manifest.pluginId,
                    process.ownerId,
                    process.generation,
                    claimToken: process.claimToken
                )) {
                    servicePluginRecordRuntimeDispatchLocked(task.record, task.frame, dispatch)
                    completed = dispatch.status != "dispatch_cancelled" && dispatch.status != "dispatch_retry"
                }
            }
            if (!completed) { let _ = servicePluginWriteEventAck(task, "admission", "retry", process) }
            } catch (_: Exception) {
                let _ = servicePluginWriteEventAck(task, "admission", "retry", process)
            } finally {
                if (completed && task.ackable()) {
                    let receipt = ServicePluginWebhookReceipt(
                        task.record.registration.manifest.pluginId,
                        task.deliveryId,
                        task.eventId,
                        task.attemptToken,
                        "completed_unconfirmed"
                    )
                    var queue = None<ServicePluginResponseQueue>
                    synchronized(servicePluginProcessLock) {
                        if (servicePluginOwnerMatchesLocked(task.record.registration.manifest.pluginId, process.ownerId, process.generation, claimToken: process.claimToken)) {
                            match (servicePluginResponseQueues.get(task.record.registration.manifest.pluginId)) {
                                case Some(value) => queue = Some(value)
                                case None => ()
                            }
                        }
                    }
                    match (queue) {
                        case Some(value) => let _ = servicePluginConfirmCompletedReceipt(task.record, process, value, receipt, task.frame.frameId, requireDispatchAllowed: true)
                        case None => ()
                    }
                }
                let next = process.finishDispatchFuture(token)
                servicePluginFlushDispatchDiagnostics(process)
                match (next) { case Some(queued) => servicePluginLaunchEventDispatchTask(queued, process) case None => () }
                let _ = servicePluginFinalizeCleanupPending(task.record.registration.manifest.pluginId, process, timeoutMs: 1000)
                gate.markWorkerSettled()
                match (servicePluginDispatchWorkerSettledHookForTest) { case Some(hook) => hook(task.frame.frameId) case None => () }
            }
        }
        launched = Some(future)
        match (servicePluginDispatchRegisterHookForTest) { case Some(hook) => hook(task.frame.frameId) case None => () }
        process.registerDispatchFuture(token, future)
        gate.open()
    } catch (_: Exception) {
        match (launched) {
            case Some(future) =>
                gate.cancel()
                gate.waitWorkerSettled()
                try { let _ = future.get(Duration.second) } catch (_: Exception) { () }
            case None => ()
        }
        let next = process.rollbackDispatchLaunch()
        servicePluginFlushDispatchDiagnostics(process)
        let _ = servicePluginWriteEventAck(task, "admission", "retry", process)
        match (next) { case Some(queued) => servicePluginLaunchEventDispatchTask(queued, process) case None => () }
    }
}

private func servicePluginRecordRuntimeDispatchLocked(record: ServicePluginRuntimeRecord, frame: ServiceFrame, dispatch: ServicePluginEventDispatchResult): Unit {
    synchronized(servicePluginRuntimeRecordLock) {
        servicePluginRecordRuntimeDispatch(record, frame, dispatch)
    }
}

private func servicePluginRecordRuntimeDispatch(record: ServicePluginRuntimeRecord, frame: ServiceFrame, dispatch: ServicePluginEventDispatchResult): Unit {
    if (frame.capabilityId == "gitcode.monitor.orphan_detected" || dispatch.status == "orphan_detected") {
        record.status = "degraded"
        record.degradedReason = "orphan_detected"
        record.lastError = servicePluginDispatchDiagnosticSummary(frame, dispatch)
        return
    }
    if (!dispatch.ok || dispatch.status == "no_subscribers" || dispatch.status == "generated_reply_degraded_delivered" || dispatch.status == "generated_reply_partially_delivered" || dispatch.status == "generated_reply_delivery_failed") {
        record.lastError = servicePluginDispatchDiagnosticSummary(frame, dispatch)
        return
    }
    record.lastError = ""
}

public func servicePluginRuntimeIsOrphanDrainingForDispatch(serviceId: String): Bool {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) => record.degradedReason == "orphan_detected"
        case None => false
    }
}

public func recordServicePluginRuntimeDispatchForTest(serviceId: String, frame: ServiceFrame, dispatch: ServicePluginEventDispatchResult): Unit {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            if (record.status == "registered") {
                record.status = "running"
            }
            servicePluginRecordRuntimeDispatchLocked(record, frame, dispatch)
        case None => ()
    }
}

public func startServicePlugin(serviceId: String, context!: ServiceStartContext = ServiceStartContext()): ServiceStartResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            let sid = serviceId.trimAscii()
            let cwd = servicePluginEffectiveWorkingDirectory(record.registration.configRef)
            let cwdMissing = !cwd.isEmpty() && !exists(Path(cwd))
            match (servicePluginBeforeSupervisorRegisterHookForTest) { case Some(hook) => hook(sid) case None => () }
            var supervisor = None<ServicePluginSupervisorStopFlag>
            let started = synchronized(servicePluginProcessLock) {
                if (servicePluginHostShuttingDown) {
                    ServiceStartResult(false, sid, "stopping", instanceId: record.instanceId, diagnostic: "service plugin host is shutting down")
                } else if (servicePluginHasCleanupPendingLocked(sid)) {
                    ServiceStartResult(false, sid, "cleanup_pending", instanceId: record.instanceId, diagnostic: "service plugin owner cleanup is pending")
                } else if (!record.registration.enabled) {
                    record.status = "disabled"
                    record.degradedReason = "plugin disabled"
                    ServiceStartResult(false, sid, "disabled", diagnostic: record.degradedReason)
                } else if (record.registration.manifest.entryCommand.isEmpty()) {
                    record.status = "degraded"
                    record.degradedReason = "missing entry command"
                    record.lastError = record.degradedReason
                    ServiceStartResult(false, sid, "degraded", diagnostic: record.degradedReason)
                } else if (cwdMissing) {
                    record.status = "degraded"
                    record.degradedReason = "cwd_missing"
                    record.lastError = "service plugin working directory missing"
                    ServiceStartResult(false, sid, "degraded", diagnostic: record.lastError)
                } else {
                    record.instanceSeq++
                    record.instanceId = "${sid}-${record.instanceSeq}"
                    record.status = "registered"
                    record.degradedReason = ""
                    record.lastError = ""
                    record.lastHeartbeatAtMillis = context.nowMillis
                    record.stateFlushed = false
                    supervisor = servicePluginReserveSupervisorLocked(sid)
                    ServiceStartResult(true, sid, record.status, instanceId: record.instanceId)
                }
            }
            if (!started.ok) { return started }
            match (supervisor) { case Some(flag) => servicePluginSpawnSupervisorWorker(sid, flag) case None => () }
            started
        case None => ServiceStartResult(false, serviceId.trimAscii(), "missing", diagnostic: "service plugin is not registered")
    }
}

public func ensureRegisteredServicePluginStarted(serviceId: String, startupTimeoutMs!: Int64 = 10000): ServiceStartResult {
    let sid = serviceId.trimAscii()
    match (servicePluginRegistry.get(sid)) {
        case Some(record) =>
            if (!record.registration.enabled) {
                record.status = "disabled"
                record.degradedReason = "plugin disabled"
                return ServiceStartResult(false, sid, "disabled", diagnostic: record.degradedReason)
            }
            let ensured = ensureServicePluginStdioProcess(record, startupTimeoutMs: startupTimeoutMs)
            ServiceStartResult(
                ensured.ok,
                sid,
                if (ensured.ok) { "running" } else if (!ensured.status.isEmpty()) { ensured.status } else { record.degradedReason },
                instanceId: record.instanceId,
                diagnostic: ensured.diagnostic
            )
        case None => ServiceStartResult(false, sid, "missing", diagnostic: "service plugin is not registered")
    }
}

public func stopServicePlugin(serviceId: String, reason!: String = "", timeoutMillis!: Int64 = 30000): ServiceStopResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            let sid = serviceId.trimAscii()
            servicePluginStopSupervisorWorker(sid)
            if (timeoutMillis <= 0) {
                record.status = "degraded"
                record.degradedReason = "stop timeout"
                return ServiceStopResult(false, sid, "degraded", diagnostic: record.degradedReason)
            }
            let effectiveTimeoutMillis = min(timeoutMillis, 30000)
            let pendingCleanup = synchronized(servicePluginProcessLock) { servicePluginCleanupPendingForServiceLocked(sid) }
            match (pendingCleanup) {
                case Some(slot) =>
                    match (slot.detached.process) {
                        case Some(process) =>
                            let finalized = servicePluginFinalizeCleanupPending(sid, process, timeoutMs: effectiveTimeoutMillis)
                            if (finalized.finalized) {
                                let published = synchronized(servicePluginProcessLock) {
                                    match (servicePluginRegistry.get(sid)) {
                                        case Some(current) =>
                                            if (!servicePluginActiveProcesses.contains(sid) && !servicePluginStartClaims.contains(sid) &&
                                                !servicePluginHasCleanupPendingLocked(sid) && current.pid == 0) {
                                                current.status = "stopped"
                                                current.degradedReason = reason.trimAscii()
                                                current.stateFlushed = true
                                                true
                                            } else { false }
                                        case None => false
                                    }
                                }
                                if (!published) {
                                    return ServiceStopResult(
                                        false,
                                        sid,
                                        "cleanup_pending",
                                        stateFlushed: false,
                                        diagnostic: "cleanup finalized but service identity changed",
                                        ingressStopStatus: finalized.ingressStopStatus,
                                        dispatchStatus: finalized.dispatchStatus,
                                        ownerStopStatus: finalized.ownerStopStatus,
                                        leaseStatus: finalized.leaseStatus,
                                        portStatus: finalized.portStatus
                                    )
                                }
                                return ServiceStopResult(
                                    true,
                                    sid,
                                    "stopped",
                                    stateFlushed: true,
                                    diagnostic: "${slot.diagnostic} cleanup_retry_stop_status=${finalized.ownerStopStatus} ${finalized.diagnostic} cleanup_finalized",
                                    ingressStopStatus: finalized.ingressStopStatus,
                                    dispatchStatus: finalized.dispatchStatus,
                                    ownerStopStatus: finalized.ownerStopStatus,
                                    leaseStatus: finalized.leaseStatus,
                                    portStatus: finalized.portStatus
                                )
                            }
                        case None => ()
                    }
                    return ServiceStopResult(
                        false,
                        sid,
                        "cleanup_pending",
                        stateFlushed: false,
                        diagnostic: "${slot.diagnostic} ${slot.terminalDiagnostic} cleanup_retry_pending",
                        ingressStopStatus: slot.ingressStopStatus,
                        dispatchStatus: slot.dispatchStatus,
                        ownerStopStatus: slot.ownerStopStatus,
                        leaseStatus: slot.leaseStatus,
                        portStatus: slot.portStatus
                    )
                case None => ()
            }
            let deadlineMs = servicePluginDeadlineNowMs() + effectiveTimeoutMillis
            let terminalDeadline = ServicePluginProbeDeadline(deadlineMs)
            let stopReserveMs = max(1, effectiveTimeoutMillis / 2)
            var selectedProcess = None<ServicePluginStdioProcess>
            var fencedTasks = ArrayList<ServicePluginDispatchTask>()
            var pendingClaim = None<ServicePluginStartClaim>
            var stopClaimed = false
            synchronized(servicePluginProcessLock) {
                if (servicePluginHasCleanupPendingLocked(sid)) {
                    ()
                } else if (record.status != "stopping") {
                    stopClaimed = true
                    record.status = "stopping"
                    match (servicePluginActiveProcesses.get(sid)) {
                        case Some(process) =>
                            fencedTasks = process.fenceDispatch()
                            selectedProcess = Some(process)
                        case None => ()
                    }
                    match (servicePluginStartClaims.get(sid)) {
                        case Some(claim) =>
                            claim.cancel()
                            pendingClaim = Some(claim)
                        case None => ()
                    }
                }
            }
            let _ = servicePluginCancelCompletionWaits(sid)
            match (selectedProcess) { case Some(process) => servicePluginWriteFencedEventAcks(fencedTasks, process) case None => () }
            if (!stopClaimed) {
                let status = synchronized(servicePluginProcessLock) { if (servicePluginHasCleanupPendingLocked(sid)) { "cleanup_pending" } else { "stopping" } }
                return ServiceStopResult(false, sid, status, diagnostic: if (status == "cleanup_pending") { "service plugin owner cleanup is pending" } else { "service plugin stop already in progress" })
            }
            match (pendingClaim) {
                case Some(_) => servicePluginRunStartPhaseHook(sid, "claim_cancelled")
                case None => ()
            }
            var stopStatus = "graceful_exited"
            var stopOk = true
            match (pendingClaim) {
                case Some(claim) =>
                    let claimBudget = max(0, servicePluginDeadlineRemaining(deadlineMs) - stopReserveMs)
                    if (claimBudget <= 0 || !claim.waitSettled(claimBudget)) {
                        stopStatus = "still_alive"
                        stopOk = false
                    }
                case None => ()
            }
            if (stopOk && selectedProcess.isNone()) {
                selectedProcess = synchronized(servicePluginProcessLock) {
                    match (servicePluginActiveProcesses.get(sid)) {
                        case Some(process) => Some(process)
                        case None => None<ServicePluginStdioProcess>
                    }
                }
                let _ = servicePluginCancelCompletionWaits(sid)
                match (selectedProcess) { case Some(process) => servicePluginWriteFencedEventAcks(process.fenceDispatch(), process) case None => () }
            }
            var dispatchStatus = "not_started"
            var ingressStopStatus = "not_started"
            var preForceTerminal = None<ServicePluginStopTerminalState>
            match (selectedProcess) {
                case Some(process) =>
                    let ingressBudget = max(0, servicePluginDeadlineRemaining(deadlineMs) - stopReserveMs)
                    if (ingressBudget > 0) {
                        try {
                            process.writeLine(
                                encodeServiceFrame(ServiceFrame("request", "stop-${record.instanceId}", sid, method: "stop", correlationId: "stop-${record.instanceId}", payload: "{}")).trimAscii(),
                                timeoutMs: ingressBudget
                            )
                            ingressStopStatus = "sent"
                        } catch (_: Exception) {
                            ingressStopStatus = "write_failed"
                        }
                    } else {
                        ingressStopStatus = "deadline_exhausted"
                    }
                    let observeBudget = min(500, max(0, servicePluginDeadlineRemaining(deadlineMs) - stopReserveMs) / 2)
                    if (ingressStopStatus == "sent" && observeBudget > 0) {
                        servicePluginObserveIngressStop(sid, process, servicePluginDeadlineNowMs() + observeBudget)
                    }
                    dispatchStatus = servicePluginDrainDispatchForStop(process, deadlineMs, stopReserveMs)
                    let forceReserveMs = max(1, stopReserveMs / 2)
                    var graceful = false
                    while (servicePluginDeadlineRemaining(deadlineMs) > forceReserveMs) {
                        let waitMs = min(50, servicePluginDeadlineRemaining(deadlineMs) - forceReserveMs)
                        let terminal = process.waitTerminal(max(1, waitMs))
                        if (terminal && servicePluginLeaseStopped(record, deadlineMs)) {
                            stopStatus = "graceful_exited"
                            graceful = true
                            break
                        }
                        if (terminal) { sleep(Duration.millisecond * min(10, max(1, waitMs))) }
                    }
                    preForceTerminal = Some(servicePluginStopTerminalState(
                        record,
                        process.process.pid,
                        servicePluginPreForceProbeDeadline(deadlineMs)
                    ))
                    let remaining = servicePluginDeadlineRemaining(deadlineMs)
                    let terminalReserve = min(100, max(0, remaining - 1))
                    let forced = process.stop(timeoutMs: if (graceful) { 1 } else { max(1, remaining - terminalReserve) })
                    stopOk = forced.ok
                    stopStatus = if (graceful && forced.ok) { "graceful_exited" } else { forced.status }
                case None => ()
            }
            let detached = synchronized(servicePluginProcessLock) {
                match (selectedProcess) {
                    case Some(process) => detachServicePluginOwnerLocked(sid, ownerId: process.ownerId, generation: process.generation, claimToken: process.claimToken)
                    case None =>
                        if (servicePluginActiveProcesses.contains(sid)) {
                            ServicePluginDetachedOwner()
                        } else {
                            detachServicePluginOwnerLocked(sid)
                        }
                }
            }
            match (detached.queue) {
                case Some(queue) => queue.close(status: "stopped", diagnostic: "service plugin stopped: ${reason.trimAscii()}")
                case None => ()
            }
            match (detached.process) {
                case Some(process) => process.stopReaders(min(100, max(1, servicePluginDeadlineRemaining(deadlineMs))))
                case None => ()
            }
            let expectedPid = match (selectedProcess) {
                case Some(process) => process.process.pid
                case None => Int64(0)
            }
            let postStopTerminal = if (expectedPid > 0) {
                servicePluginStopTerminalState(
                    record,
                    expectedPid,
                    terminalDeadline
                )
            } else {
                ServicePluginStopTerminalState(true, "lease_not_applicable", "not_applicable", "not_applicable", "not_applicable")
            }
            let terminalState = servicePluginTerminalWithPreForceEvidence(postStopTerminal, preForceTerminal)
            if (!stopOk && (terminalState.pidStatus == "gone" || terminalState.pidStatus == "not_applicable")) {
                stopOk = true
                stopStatus = "force_terminated"
            }
            let stopDiagnostic = "stop_status=${stopStatus} dispatch_status=${dispatchStatus}"
            if (!stopOk) {
                record.lastError = match (selectedProcess) {
                    case Some(process) => "${stopDiagnostic} ${servicePluginProcessError("service plugin stop forced", process)}"
                    case None => stopDiagnostic
                }
            } else {
                record.lastError = stopDiagnostic
            }
            let leaseDiagnostic = terminalState.diagnostic
            let cleanLease = terminalState.ok
            if (dispatchStatus == "dispatch_pending") {
                match (selectedProcess) {
                    case Some(process) =>
                        servicePluginPublishCleanupPending(
                            sid,
                            detached,
                            process,
                            stopStatus,
                            "${stopDiagnostic} ${leaseDiagnostic} cleanup_pending",
                            finalStatus: if (cleanLease && stopOk) { "stopped" } else { "degraded" },
                            finalReason: if (!cleanLease) { "lease_not_stopped_after_stop" } else if (!stopOk) { "stop timeout" } else { reason.trimAscii() },
                            stateFlushed: cleanLease && stopOk,
                            ingressStopStatus: ingressStopStatus,
                            dispatchStatus: dispatchStatus,
                            leaseStatus: terminalState.leaseStatus,
                            portStatus: terminalState.portStatus
                        )
                    case None => ()
                }
                return ServiceStopResult(
                    false,
                    sid,
                    "cleanup_pending",
                    stateFlushed: false,
                    diagnostic: "${stopDiagnostic} ${leaseDiagnostic} cleanup_pending",
                    ingressStopStatus: ingressStopStatus,
                    dispatchStatus: dispatchStatus,
                    ownerStopStatus: stopStatus,
                    leaseStatus: terminalState.leaseStatus,
                    portStatus: terminalState.portStatus
                )
            }
            match (detached.pump) {
                case Some(pump) =>
                    let remaining = servicePluginDeadlineRemaining(deadlineMs)
                    if (remaining > 0) { try { pump.get(Duration.millisecond * remaining) } catch (_: Exception) { () } }
                case None => ()
            }
            if (!cleanLease || !stopOk) {
                record.status = "degraded"
                record.degradedReason = if (!cleanLease) { "lease_not_stopped_after_stop" } else { "stop timeout" }
                record.stateFlushed = false
                if (!record.lastError.isEmpty()) {
                    record.lastError = "${record.lastError} ${leaseDiagnostic}"
                } else {
                    record.lastError = leaseDiagnostic
                }
                if (terminalState.pidStatus == "gone" || terminalState.pidStatus == "not_applicable") {
                    record.pid = 0
                }
                match (selectedProcess) {
                    case Some(process) => servicePluginPublishCleanupPending(
                        sid,
                        detached,
                        process,
                        stopStatus,
                        "${stopDiagnostic} ${leaseDiagnostic} cleanup_pending",
                        finalStatus: "stopped",
                        finalReason: if (!cleanLease) { terminalState.leaseStatus } else { "stop timeout" },
                        stateFlushed: false,
                        ingressStopStatus: ingressStopStatus,
                        dispatchStatus: dispatchStatus,
                        leaseStatus: terminalState.leaseStatus,
                        portStatus: terminalState.portStatus
                    )
                    case None => ()
                }
                return ServiceStopResult(
                    false,
                    sid,
                    if (selectedProcess.isSome()) { "cleanup_pending" } else { "degraded" },
                    stateFlushed: false,
                    diagnostic: record.lastError,
                    ingressStopStatus: ingressStopStatus,
                    dispatchStatus: dispatchStatus,
                    ownerStopStatus: stopStatus,
                    leaseStatus: terminalState.leaseStatus,
                    portStatus: terminalState.portStatus
                )
            }
            record.status = "stopped"
            record.degradedReason = reason.trimAscii()
            record.stateFlushed = true
            record.pid = 0
            let diagnostic = if (record.lastError.isEmpty()) { leaseDiagnostic } else { "${record.lastError} ${leaseDiagnostic}" }
            record.lastError = diagnostic
            ServiceStopResult(
                true,
                sid,
                "stopped",
                stateFlushed: true,
                diagnostic: diagnostic,
                ingressStopStatus: ingressStopStatus,
                dispatchStatus: dispatchStatus,
                ownerStopStatus: stopStatus,
                leaseStatus: terminalState.leaseStatus,
                portStatus: terminalState.portStatus
            )
        case None => ServiceStopResult(false, serviceId.trimAscii(), "missing", diagnostic: "service plugin is not registered")
    }
}

public func restartServicePlugin(serviceId: String, reason!: String = ""): ServiceRestartResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            let blocked = synchronized(servicePluginProcessLock) {
                if (servicePluginHostShuttingDown) { "stopping" }
                else if (servicePluginHasCleanupPendingLocked(serviceId)) { "cleanup_pending" }
                else { "" }
            }
            if (!blocked.isEmpty()) {
                return ServiceRestartResult(false, serviceId.trimAscii(), blocked, previousInstanceId: record.instanceId, diagnostic: if (blocked == "stopping") { "service plugin host is shutting down" } else { "service plugin owner cleanup is pending" })
            }
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
            if (record.status != "running" && record.status != "registered") {
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

public func markServicePluginDegraded(serviceId: String, reason: String, diagnostic!: String = ""): Unit {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            record.status = "degraded"
            record.degradedReason = reason.trimAscii()
            record.lastError = redactServicePayload(if (diagnostic.trimAscii().isEmpty()) { reason } else { diagnostic }).text
        case None => ()
    }
}

private func servicePluginRetainEventFrameLocked(record: ServicePluginRuntimeRecord, frame: ServiceFrame): Unit {
    if (Int64(record.eventFrames.size) >= SERVICE_PLUGIN_RETAINED_EVENT_FRAME_LIMIT) {
        record.eventFrames.remove(at: 0)
        record.eventFrameEvictions++
    }
    record.eventFrames.add(frame)
}

public func enqueueServiceEventFrameForTest(frame: ServiceFrame): Unit {
    match (servicePluginRegistry.get(frame.serviceId)) {
        case Some(record) => synchronized(servicePluginRuntimeRecordLock) { servicePluginRetainEventFrameLocked(record, frame) }
        case None => ()
    }
}

public func readServiceEventFrame(serviceId: String, timeoutMillis!: Int64 = 1000): ServiceEventReadResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            let retained = synchronized(servicePluginRuntimeRecordLock) {
                if (record.eventFrames.size == 0) {
                    None<ServiceFrame>
                } else {
                    let frame = record.eventFrames[0]
                    record.eventFrames.remove(at: 0)
                    Some(frame)
                }
            }
            let frame = match (retained) {
                case Some(value) => value
                case None => return ServiceEventReadResult(false, "timeout", diagnostic: "no service event frame available")
            }
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
    let redactedLastError = redactServicePayload(snapshot.lastError).text
    let redactedSupervisorProbe = redactServicePayload(snapshot.supervisorLastProbe).text
    let redactedSupervisorReason = redactServicePayload(snapshot.supervisorDegradedReason).text
    "serviceId=${snapshot.serviceId} status=${snapshot.status} enabled=${snapshot.enabled} capabilities=${serviceJoinStrings(snapshot.capabilityIds, ",")} config=${snapshot.configSummary} degradedReason=${redactedReason} lastError=${redactedLastError} supervisorLastProbe=${redactedSupervisorProbe} supervisorFailureCount=${snapshot.supervisorFailureCount} supervisorRestartCount=${snapshot.supervisorRestartCount} supervisorDegradedReason=${redactedSupervisorReason} dispatchActive=${snapshot.dispatch.active} dispatchQueued=${snapshot.dispatch.queued} dispatchHighWater=${snapshot.dispatch.highWater} dispatchQueueFull=${snapshot.dispatch.queueFull} admissionAccepted=${snapshot.dispatch.admissionAccepted} admissionRetried=${snapshot.dispatch.admissionRetried} completionAck=${snapshot.dispatch.completionAck} dispatchFenced=${snapshot.dispatch.fenced} retainedEventFrames=${snapshot.retainedEventFrames} eventFrameEvictions=${snapshot.eventFrameEvictions}"
}

private func serviceSnapshot(record: ServicePluginRuntimeRecord): ServicePluginSnapshot {
    let dispatch = synchronized(servicePluginProcessLock) {
        match (servicePluginActiveProcesses.get(record.registration.manifest.pluginId)) {
            case Some(process) => process.dispatchSnapshot()
            case None => ServicePluginDispatchSnapshot()
        }
    }
    let retained = synchronized(servicePluginRuntimeRecordLock) {
        (Int64(record.eventFrames.size), record.eventFrameEvictions)
    }
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
            instanceId: record.instanceId,
            pid: record.pid,
            lastError: record.lastError,
            supervisorLastProbe: record.supervisorLastProbe,
            supervisorFailureCount: record.supervisorFailureCount,
            supervisorRestartCount: record.supervisorRestartCount,
            supervisorDegradedReason: record.supervisorLastDegradedReason,
            dispatch: dispatch,
            retainedEventFrames: retained[0],
            eventFrameEvictions: retained[1]
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
