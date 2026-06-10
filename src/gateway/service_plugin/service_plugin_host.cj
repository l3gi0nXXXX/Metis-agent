package metis.gateway.service_plugin

import metis.core.metisSafeUtf8Prefix
import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import std.collection.{ArrayList, HashMap, HashSet}
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists, remove}
import std.io.*
import std.env.{getProcessId, getVariable, getVariables, setVariable}
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.json.{JsonObject, JsonValue}
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
        supervisorDegradedReason!: String = ""
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

private class ServicePluginStdioProcess {
    public let process: SubProcess
    private let writer: StringWriter<OutputStream>
    private let stdoutBuffer = ServicePluginLineBuffer()
    private let stderrBuffer = ServicePluginLineBuffer()

    public init(process: SubProcess) {
        this.process = process
        this.writer = StringWriter(process.stdInPipe)
        let stdoutReader = StringReader<InputStream>(process.stdOutPipe)
        let stderrReader = StringReader<InputStream>(process.stdErrPipe)
        spawn { this.readLines(stdoutReader, this.stdoutBuffer) }
        spawn { this.readLines(stderrReader, this.stderrBuffer) }
    }

    public func writeLine(line: String): Unit {
        this.writer.writeln(line)
        this.writer.flush()
    }

    public func readStdoutLine(timeoutMs: Int64): Option<String> {
        this.stdoutBuffer.readLine(timeoutMs)
    }

    public func stderrSummary(): String {
        redactServicePayload(this.stderrBuffer.summary()).text
    }

    public func stdoutSummary(): String {
        redactServicePayload(this.stdoutBuffer.summary()).text
    }

    public func stop(timeoutMs!: Int64 = 500): ServicePluginProcessStopResult {
        let effective = if (timeoutMs > 0) { timeoutMs } else { 500 }
        try {
            let _ = this.process.wait(timeout: Some(Duration.millisecond * effective))
            this.stdoutBuffer.close()
            this.stderrBuffer.close()
            return ServicePluginProcessStopResult(true, "graceful_exited")
        } catch (_waitBeforeTerminate: Exception) {
            ()
        }
        try { this.process.terminate(force: false) } catch (_: Exception) { () }
        try {
            let _ = this.process.wait(timeout: Some(Duration.millisecond * effective))
            this.stdoutBuffer.close()
            this.stderrBuffer.close()
            return ServicePluginProcessStopResult(true, "terminated")
        } catch (_waitAfterTerminate: Exception) {
            try { this.process.terminate(force: true) } catch (_inner: Exception) { () }
        }
        sleep(Duration.millisecond * 25)
        this.stdoutBuffer.close()
        this.stderrBuffer.close()
        if (this.process.isAlive()) {
            return ServicePluginProcessStopResult(false, "still_alive")
        }
        ServicePluginProcessStopResult(true, "force_terminated")
    }

    private func readLines(reader: StringReader<InputStream>, buffer: ServicePluginLineBuffer): Unit {
        while (true) {
            let line = try {
                reader.readln()
            } catch (e: Exception) {
                buffer.close(error: "read failed: ${e.message}")
                return
            }
            match (line) {
                case Some(value) =>
                    try {
                        buffer.appendLine(value)
                    } catch (e: Exception) {
                        buffer.close(error: "line buffer append failed: ${e.message}")
                        return
                    }
                case None =>
                    buffer.close()
                    return
            }
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
            let _ = this.condition.waitUntil({ => this.closed || this.findResponseIndex(corr) >= 0 }, timeout: Duration.millisecond * effective)
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
                    return ServicePluginStdoutReadResult(false, frame: frame, status: validation.status, diagnostic: validation.diagnostic)
                }
                return ServicePluginStdoutReadResult(true, frame: frame)
            }
            if (this.closed) {
                return ServicePluginStdoutReadResult(false, status: if (this.closeStatus.isEmpty()) { "process_exited" } else { this.closeStatus }, diagnostic: this.closeDiagnostic)
            }
            ServicePluginStdoutReadResult(false, status: "timeout", diagnostic: "timeout waiting for response correlationId=${corr}")
        }
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
private let servicePluginProcessLock = Mutex()
private let servicePluginRuntimeRecordLock = Mutex()

private func readExpectedServiceFrame(process: ServicePluginStdioProcess, policy: ServicePluginStdoutReadPolicy): ServicePluginStdoutReadResult {
    var noiseLineCount: Int64 = 0
    var emptyLineCount: Int64 = 0
    var noiseBytes: Int64 = 0
    let noiseSamples = ArrayList<String>()

    while (true) {
        let line = match (process.readStdoutLine(policy.timeoutMs)) {
            case Some(value) => value
            case None =>
                return ServicePluginStdoutReadResult(false, status: "timeout", diagnostic: servicePluginStdoutNoiseDiagnostic("timeout", noiseLineCount, noiseBytes, noiseSamples))
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

public func resetServicePluginHostForTest(): Unit {
    stopAllServicePluginSupervisors()
    stopAllActiveServicePluginProcesses()
    servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
    serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()
    servicePluginCapabilityInvokerForTest = None<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult>
    servicePluginHealthzProbeForTest = None<(String, Int64) -> ServicePluginHealthzProbeResult>
    servicePluginPortOwnerProbeForTest = None<(Int64, Int64) -> Bool>
    servicePluginSupervisorConfig = ServicePluginSupervisorConfig()
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
        let correlationId = "corr-${record.instanceId}-${request.capabilityId}"
        let invokeFrame = ServiceFrame(
            "request",
            "invoke-${record.instanceId}",
            serviceId,
            method: "invokeCapability",
            capabilityId: request.capabilityId,
            correlationId: correlationId,
            payload: request.payload
        )
        process.writeLine(encodeServiceFrame(invokeFrame).trimAscii())
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

private func servicePluginPidAlive(pid: Int64): Bool {
    if (pid <= 0) {
        return false
    }
    try {
        let (exitCode, _, _) = executeWithOutput("kill", ["-0", "${pid}"])
        exitCode == 0
    } catch (_: Exception) {
        false
    }
}

private func servicePluginPortOwnedByPid(port: Int64, pid: Int64): Bool {
    if (port <= 0 || pid <= 0) {
        return false
    }
    try {
        let (exitCode, stdout, _) = executeWithOutput("lsof", ["-nP", "-iTCP:${port}", "-sTCP:LISTEN", "-Fp"])
        if (exitCode != 0) {
            return false
        }
        for (line in String.fromUtf8(stdout).split("\n")) {
            if (line.trimAscii() == "p${pid}") {
                return true
            }
        }
        false
    } catch (_: Exception) {
        false
    }
}

private func servicePluginPortOwnerAlive(port: Int64, pid: Int64): Bool {
    match (servicePluginPortOwnerProbeForTest) {
        case Some(probe) => probe(port, pid)
        case None => servicePluginPortOwnedByPid(port, pid)
    }
}

private func servicePluginNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
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
    max(200, min(5000, config.healthTimeoutMs * 10))
}

private func recoverServicePlugin(record: ServicePluginRuntimeRecord, reason: String, nowMs!: Int64 = servicePluginNowMs()): Bool {
    let serviceId = record.registration.manifest.pluginId
    let config = servicePluginSupervisorConfig
    if (record.supervisorLastRestartAtMs > 0 && nowMs - record.supervisorLastRestartAtMs < config.restartCooldownMs) {
        record.lastError = serviceJoinStrings([record.lastError, "restart_cooldown reason=${reason}"], " ")
        return false
    }

    if (reason == "process_exited") {
        servicePluginStopSupervisorWorker(serviceId)
        synchronized(servicePluginProcessLock) {
            if (servicePluginActiveProcesses.contains(serviceId)) { servicePluginActiveProcesses.remove(serviceId) }
            if (servicePluginResponseQueues.contains(serviceId)) { servicePluginResponseQueues.remove(serviceId) }
        }
        record.pid = 0
        record.status = "stopped"
    } else {
        let previousPid = record.pid
        let stopped = stopServicePlugin(serviceId, reason: "supervisor_${reason}", timeoutMillis: servicePluginSupervisorStopTimeoutMs(config))
        if (!stopped.ok) {
            let lease = servicePluginReadLease(Path(servicePluginLeasePath(record)))
            let portOwnerAlive = match (lease) {
                case Some(value) => servicePluginPortOwnerAlive(value.port, value.pid)
                case None => false
            }
            if (portOwnerAlive) {
                match (lease) {
                    case Some(value) =>
                        record.lastError = "${stopped.diagnostic} port_release_timeout port=${value.port} pid=${value.pid} portOwnerAlive=true"
                    case None =>
                        record.lastError = "${stopped.diagnostic} port_release_timeout port=0 pid=0 portOwnerAlive=true"
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
            if (servicePluginPortOwnerAlive(lease.port, lease.pid)) {
                record.status = "degraded"
                record.degradedReason = reason
                record.lastError = "port_release_timeout port=${lease.port} pid=${lease.pid} portOwnerAlive=true"
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
    record.status = "degraded"
    record.degradedReason = reason
    record.supervisorLastDegradedReason = reason
    record.lastError = "supervisor_restarted reason=${reason}"
    true
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
            var recovered = false
            if (allowRecover && classification.shouldRecover) {
                recovered = recoverServicePlugin(record, classification.reason, nowMs: nowMs)
            }
            ServicePluginSupervisorTickResult(true, classification.status, probe: probe, classification: classification, recovered: recovered, diagnostic: record.lastError)
        case None => ServicePluginSupervisorTickResult(false, "missing", diagnostic: "service plugin is not registered")
    }
}

public func runServicePluginSupervisorTickForTest(serviceId: String, nowMs!: Int64 = servicePluginNowMs()): ServicePluginSupervisorTickResult {
    servicePluginRunSupervisorTick(serviceId, nowMs, allowRecover: true)
}

private func servicePluginStartSupervisorWorker(record: ServicePluginRuntimeRecord): Unit {
    if (!servicePluginSupervisorConfig.enabled) {
        return
    }
    let serviceId = record.registration.manifest.pluginId
    let flag = ServicePluginSupervisorStopFlag()
    synchronized(servicePluginSupervisorLock) {
        match (servicePluginSupervisorWorkers.get(serviceId)) {
            case Some(existing) =>
                if (!existing.stopped()) {
                    return
                }
            case None => ()
        }
        servicePluginSupervisorWorkers[serviceId] = flag
    }
    spawn {
        while (!flag.stopped()) {
            sleep(Duration.millisecond * servicePluginSupervisorConfig.intervalMs)
            if (flag.stopped()) {
                return
            }
            let _ = servicePluginRunSupervisorTick(serviceId, servicePluginNowMs(), allowRecover: true)
        }
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

private func servicePluginBlockingLeaseBeforeStart(serviceId: String): ?ServicePluginLeaseStartBlock {
    let dir = servicePluginRuntimeLeaseDir(serviceId)
    if (!exists(dir)) {
        return None<ServicePluginLeaseStartBlock>
    }
    try {
        for (entry in Directory.readFrom(dir)) {
            if (!entry.isRegular() || !entry.name.endsWith(".lease.json")) {
                continue
            }
            match (servicePluginReadLease(entry.path)) {
                case Some(lease) =>
                    let pidAlive = servicePluginPidAlive(lease.pid)
                    if (lease.state == "running" && pidAlive) {
                        let status = "stale_lease_before_start"
                        return Some(ServicePluginLeaseStartBlock(status, servicePluginLeaseStartDiagnostic(status, lease, pidAlive, false)))
                    }
                    if (lease.state == "orphan_detected") {
                        if (pidAlive) {
                            let status = "orphan_lease_alive_before_start"
                            return Some(ServicePluginLeaseStartBlock(status, servicePluginLeaseStartDiagnostic(status, lease, pidAlive, false)))
                        }
                        let portOwnerAlive = servicePluginPortOwnedByPid(lease.port, lease.pid)
                        if (portOwnerAlive) {
                            let status = "orphan_port_owner_alive_before_start"
                            return Some(ServicePluginLeaseStartBlock(status, servicePluginLeaseStartDiagnostic(status, lease, pidAlive, portOwnerAlive)))
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

private func servicePluginLeaseStopDiagnostic(record: ServicePluginRuntimeRecord): String {
    let leasePath = Path(servicePluginLeasePath(record))
    match (servicePluginReadLease(leasePath)) {
        case Some(lease) =>
            let pidAlive = servicePluginPidAlive(lease.pid)
            if (lease.state != "stopped" || pidAlive) {
                return "lease_not_stopped_after_stop state=${lease.state} pid=${lease.pid} parentPid=${lease.parentPid} pidAlive=${pidAlive} port=${lease.port}"
            }
            "lease_stopped state=stopped pid=${lease.pid} parentPid=${lease.parentPid}"
        case None => "lease_missing_after_stop"
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
    synchronized(servicePluginProcessLock) {
        for ((_, process) in servicePluginActiveProcesses) {
            process.stop()
        }
        for ((_, queue) in servicePluginResponseQueues) {
            queue.close(status: "stopped", diagnostic: "service plugin host reset")
        }
        servicePluginActiveProcesses = HashMap<String, ServicePluginStdioProcess>()
        servicePluginResponseQueues = HashMap<String, ServicePluginResponseQueue>()
    }
}

public func shutdownServicePluginHost(reason!: String = "shutdown", timeoutMillis!: Int64 = 30000): Unit {
    let ids = ArrayList<String>()
    synchronized(servicePluginProcessLock) {
        for ((serviceId, _) in servicePluginActiveProcesses) {
            ids.add(serviceId)
        }
    }
    for (serviceId in ids) {
        let _ = stopServicePlugin(serviceId, reason: reason, timeoutMillis: timeoutMillis)
    }
    stopAllServicePluginSupervisors()
}

private func ensureServicePluginStdioProcess(record: ServicePluginRuntimeRecord, startupTimeoutMs!: Int64 = 10000): ServicePluginProcessEnsureResult {
    let serviceId = record.registration.manifest.pluginId
    synchronized(servicePluginProcessLock) {
        if (servicePluginActiveProcesses.contains(serviceId) && servicePluginResponseQueues.contains(serviceId)) {
            return ServicePluginProcessEnsureResult(true, "running", process: Some(servicePluginActiveProcesses[serviceId]), queue: Some(servicePluginResponseQueues[serviceId]))
        }
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
        match (servicePluginBlockingLeaseBeforeStart(serviceId)) {
            case Some(block) =>
                record.status = "degraded"
                record.degradedReason = block.status
                record.lastError = block.diagnostic
                return ServicePluginProcessEnsureResult(false, block.status, diagnostic: record.lastError)
            case None => ()
        }
        record.instanceSeq++
        record.instanceId = "${serviceId}-${record.instanceSeq}"
        try { Directory.create(servicePluginRuntimeLeaseDir(serviceId), recursive: true) } catch (_: Exception) { () }
        let args = servicePluginArgsWithConfigRef(record.registration.manifest.entryArgs, record.registration.configRef.configPath)
        let process = try {
            let proc = launch(
                record.registration.manifest.entryCommand,
                args,
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe,
                workingDirectory: if (cwd.isEmpty()) { None<Path> } else { Some(Path(cwd)) },
                environment: Some(servicePluginProcessEnvironment(record))
            )
            record.pid = proc.pid
            ServicePluginStdioProcess(proc)
        } catch (e: Exception) {
            record.status = "degraded"
            record.degradedReason = "process_start_failed"
            record.lastError = redactServicePayload(e.message).text
            return ServicePluginProcessEnsureResult(false, "process_start_failed", diagnostic: record.lastError)
        }
        let initRead = readExpectedServiceFrame(process, ServicePluginStdoutReadPolicy(startupTimeoutMs, serviceId, "initialize"))
        if (!initRead.ok) {
            record.status = "degraded"
            record.degradedReason = if (initRead.status == "timeout") { "initialize_timeout" } else { initRead.status }
            record.lastError = if (initRead.status == "timeout") {
                servicePluginProcessError("service plugin initialize timeout", process)
            } else {
                initRead.diagnostic
            }
            process.stop()
            return ServicePluginProcessEnsureResult(false, record.degradedReason, diagnostic: record.lastError)
        }
        let initPayloadValidation = validateServicePluginPayloadObject(initRead.frame.payload)
        if (!initPayloadValidation.ok) {
            record.status = "degraded"
            record.degradedReason = "payload_invalid"
            record.lastError = redactServicePayload(initPayloadValidation.diagnostic).text
            process.stop()
            return ServicePluginProcessEnsureResult(false, "payload_invalid", diagnostic: record.lastError)
        }
        let initPayloadStatus = parseServicePluginPayloadStatus(initRead.frame.payload)
        if (!initPayloadStatus.parsed || !initPayloadStatus.okPresent || !initPayloadStatus.ok) {
            record.status = "degraded"
            record.degradedReason = "initialize_failed"
            record.lastError = if (!initPayloadStatus.diagnostic.isEmpty()) {
                redactServicePayload(initPayloadStatus.diagnostic).text
            } else if (!initPayloadStatus.status.isEmpty() && initPayloadStatus.status != "ok" && initPayloadStatus.status != "invalid_payload") {
                "initialize rejected: ${redactServicePayload(initPayloadStatus.status).text}"
            } else {
                "initialize payload missing boolean ok"
            }
            process.stop()
            return ServicePluginProcessEnsureResult(false, record.degradedReason, diagnostic: record.lastError)
        }

        let queue = ServicePluginResponseQueue()
        servicePluginActiveProcesses[serviceId] = process
        servicePluginResponseQueues[serviceId] = queue
        record.status = "running"
        record.degradedReason = ""
        record.lastError = ""
        spawn { servicePluginEventPump(record, process, queue) }
        servicePluginStartSupervisorWorker(record)
        ServicePluginProcessEnsureResult(true, "running", process: Some(process), queue: Some(queue))
    }
}

private func servicePluginEventPump(record: ServicePluginRuntimeRecord, process: ServicePluginStdioProcess, queue: ServicePluginResponseQueue): Unit {
    let serviceId = record.registration.manifest.pluginId
    var noiseLineCount: Int64 = 0
    var noiseBytes: Int64 = 0
    var idlePolls: Int64 = 0
    let noiseSamples = ArrayList<String>()
    while (true) {
        let line = match (process.readStdoutLine(1000)) {
            case Some(value) => value
            case None =>
                idlePolls++
                if (idlePolls < 3600) {
                    continue
                }
                record.status = "degraded"
                record.degradedReason = "process_exited"
                record.lastError = servicePluginProcessError("service plugin process stdout closed", process)
                queue.close(status: "process_exited", diagnostic: record.lastError)
                synchronized(servicePluginProcessLock) {
                    if (servicePluginActiveProcesses.contains(serviceId)) { servicePluginActiveProcesses.remove(serviceId) }
                    if (servicePluginResponseQueues.contains(serviceId)) { servicePluginResponseQueues.remove(serviceId) }
                }
                return
        }
        idlePolls = 0
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty() || !trimmed.startsWith("{")) {
            let noise = servicePluginRecordStdoutNoise(line, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, ServicePluginStdoutReadPolicy(1000, serviceId, "eventPump"))) {
                record.status = "degraded"
                record.degradedReason = "stdout_protocol_violation"
                record.lastError = servicePluginStdoutNoiseDiagnostic("stdout_protocol_violation", noiseLineCount, noiseBytes, noiseSamples)
                queue.close(status: "stdout_protocol_violation", diagnostic: record.lastError)
                process.stop()
                return
            }
            continue
        }
        let decoded = decodeServiceFrame(trimmed)
        if (!decoded.ok) {
            let noise = servicePluginRecordStdoutNoise(trimmed, noiseLineCount, noiseBytes, noiseSamples)
            noiseLineCount = noise[0]
            noiseBytes = noise[1]
            record.lastError = servicePluginStdoutNoiseDiagnostic(decoded.errorKind, noiseLineCount, noiseBytes, noiseSamples)
            if (decoded.errorKind == "frame_too_large") {
                record.status = "degraded"
                record.degradedReason = "frame_too_large"
                queue.close(status: "frame_too_large", diagnostic: "frame_too_large ${hashRawPayload(trimmed)}")
                process.stop()
                return
            }
            if (servicePluginStdoutNoiseExceeded(noiseLineCount, noiseBytes, ServicePluginStdoutReadPolicy(1000, serviceId, "eventPump"))) {
                record.status = "degraded"
                record.degradedReason = "frame_decode_failed"
                queue.close(status: "frame_decode_failed", diagnostic: record.lastError)
                process.stop()
                return
            }
            continue
        }
        let frame = decoded.frame
        if (frame.frameType == "response") {
            queue.append(frame)
            continue
        }
        if (frame.frameType == "heartbeat" || frame.method == "heartbeat") {
            let _ = handleServiceHeartbeat(frame)
            continue
        }
        if (frame.frameType == "event") {
            synchronized(servicePluginRuntimeRecordLock) {
                record.eventFrames.add(frame)
            }
            let handled = handleServiceCapabilityEvent(ServiceCapabilityEvent(frame.serviceId, frame.capabilityId, payload: frame.payload))
            if (handled.ok) {
                servicePluginScheduleEventDispatch(record, frame)
            } else {
                synchronized(servicePluginRuntimeRecordLock) {
                    record.lastError = redactServicePayload(handled.diagnostic).text
                }
            }
            continue
        }
        if (frame.frameType == "audit") {
            continue
        }
    }
}

private func servicePluginScheduleEventDispatch(record: ServicePluginRuntimeRecord, frame: ServiceFrame): Unit {
    spawn {
        let dispatch = dispatchServicePluginEvent(frame)
        servicePluginRecordRuntimeDispatchLocked(record, frame, dispatch)
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
            if (!record.registration.enabled) {
                record.status = "disabled"
                record.degradedReason = "plugin disabled"
                return ServiceStartResult(false, serviceId.trimAscii(), "disabled", diagnostic: record.degradedReason)
            }
            if (record.registration.manifest.entryCommand.isEmpty()) {
                record.status = "degraded"
                record.degradedReason = "missing entry command"
                record.lastError = record.degradedReason
                return ServiceStartResult(false, serviceId.trimAscii(), "degraded", diagnostic: record.degradedReason)
            }
            let cwd = servicePluginEffectiveWorkingDirectory(record.registration.configRef)
            if (!cwd.isEmpty() && !exists(Path(cwd))) {
                record.status = "degraded"
                record.degradedReason = "cwd_missing"
                record.lastError = "service plugin working directory missing"
                return ServiceStartResult(false, serviceId.trimAscii(), "degraded", diagnostic: record.lastError)
            }
            record.instanceSeq++
            record.instanceId = "${serviceId.trimAscii()}-${record.instanceSeq}"
            record.status = "registered"
            record.degradedReason = ""
            record.lastError = ""
            record.lastHeartbeatAtMillis = context.nowMillis
            record.stateFlushed = false
            servicePluginStartSupervisorWorker(record)
            ServiceStartResult(true, serviceId.trimAscii(), record.status, instanceId: record.instanceId)
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
                if (ensured.ok) { "running" } else { record.degradedReason },
                instanceId: record.instanceId,
                diagnostic: ensured.diagnostic
            )
        case None => ServiceStartResult(false, sid, "missing", diagnostic: "service plugin is not registered")
    }
}

public func stopServicePlugin(serviceId: String, reason!: String = "", timeoutMillis!: Int64 = 30000): ServiceStopResult {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            servicePluginStopSupervisorWorker(serviceId.trimAscii())
            if (timeoutMillis <= 0) {
                record.status = "degraded"
                record.degradedReason = "stop timeout"
                return ServiceStopResult(false, serviceId.trimAscii(), "degraded", diagnostic: record.degradedReason)
            }
            synchronized(servicePluginProcessLock) {
                match (servicePluginActiveProcesses.get(serviceId.trimAscii())) {
                    case Some(process) =>
                        try {
                            process.writeLine(encodeServiceFrame(ServiceFrame("request", "stop-${record.instanceId}", serviceId.trimAscii(), method: "stop", correlationId: "stop-${record.instanceId}", payload: "{}")).trimAscii())
                        } catch (_: Exception) {
                            ()
                        }
                        let stop = process.stop(timeoutMs: min(timeoutMillis, 30000))
                        if (stop.status != "still_alive") {
                            servicePluginActiveProcesses.remove(serviceId.trimAscii())
                        }
                        let stopDiagnostic = "stop_status=${stop.status}"
                        if (!stop.ok) {
                            record.lastError = if (record.lastError.isEmpty()) {
                                "${stopDiagnostic} ${servicePluginProcessError("service plugin stop forced", process)}"
                            } else {
                                "${record.lastError} ${stopDiagnostic}"
                            }
                        } else if (record.lastError.isEmpty()) {
                            record.lastError = stopDiagnostic
                        }
                    case None => ()
                }
                match (servicePluginResponseQueues.get(serviceId.trimAscii())) {
                    case Some(queue) =>
                        queue.close(status: "stopped", diagnostic: "service plugin stopped: ${reason.trimAscii()}")
                        servicePluginResponseQueues.remove(serviceId.trimAscii())
                    case None => ()
                }
            }
            let leaseDiagnostic = servicePluginLeaseStopDiagnostic(record)
            let cleanLease = !leaseDiagnostic.startsWith("lease_not_stopped_after_stop")
            if (!cleanLease) {
                record.status = "degraded"
                record.degradedReason = "lease_not_stopped_after_stop"
                record.stateFlushed = false
                if (!record.lastError.isEmpty()) {
                    record.lastError = "${record.lastError} ${leaseDiagnostic}"
                } else {
                    record.lastError = leaseDiagnostic
                }
                if (!servicePluginPidAlive(record.pid)) {
                    record.pid = 0
                }
                return ServiceStopResult(false, serviceId.trimAscii(), "degraded", stateFlushed: false, diagnostic: record.lastError)
            }
            record.status = "stopped"
            record.degradedReason = reason.trimAscii()
            record.stateFlushed = true
            record.pid = 0
            let diagnostic = if (record.lastError.isEmpty()) { leaseDiagnostic } else { "${record.lastError} ${leaseDiagnostic}" }
            record.lastError = diagnostic
            ServiceStopResult(true, serviceId.trimAscii(), "stopped", stateFlushed: true, diagnostic: diagnostic)
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
    let redactedLastError = redactServicePayload(snapshot.lastError).text
    let redactedSupervisorProbe = redactServicePayload(snapshot.supervisorLastProbe).text
    let redactedSupervisorReason = redactServicePayload(snapshot.supervisorDegradedReason).text
    "serviceId=${snapshot.serviceId} status=${snapshot.status} enabled=${snapshot.enabled} capabilities=${serviceJoinStrings(snapshot.capabilityIds, ",")} config=${snapshot.configSummary} degradedReason=${redactedReason} lastError=${redactedLastError} supervisorLastProbe=${redactedSupervisorProbe} supervisorFailureCount=${snapshot.supervisorFailureCount} supervisorRestartCount=${snapshot.supervisorRestartCount} supervisorDegradedReason=${redactedSupervisorReason}"
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
            instanceId: record.instanceId,
            pid: record.pid,
            lastError: record.lastError,
            supervisorLastProbe: record.supervisorLastProbe,
            supervisorFailureCount: record.supervisorFailureCount,
            supervisorRestartCount: record.supervisorRestartCount,
            supervisorDegradedReason: record.supervisorLastDegradedReason
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
