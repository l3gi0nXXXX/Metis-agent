package metis.gateway.service_plugin

import std.collection.{ArrayList, HashMap, HashSet}
import std.fs.{Path, exists}
import std.io.*
import std.process.*
import std.sync.*
import std.time.*

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
        lastError!: String = ""
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
    public var pid: Int64
    public var lastError: String
    public var lastInvokeAtMillis: Int64
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
        this.eventFrames = ArrayList<ServiceFrame>()
    }
}

private var servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
private var serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()
private var servicePluginCapabilityInvokerForTest: Option<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult> =
    None<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult>

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
            let stored = if (line.size > 65537) { line[..65537] + "...[TRUNCATED]" } else { line }
            let clipped = if (line.size > 4096) { line[..4096] + "...[TRUNCATED]" } else { line }
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

    public func stop(): Unit {
        try { this.process.terminate(force: false) } catch (_: Exception) { () }
        try { let _ = this.process.wait(timeout: Some(Duration.millisecond * 500)) } catch (_: Exception) { try { this.process.terminate(force: true) } catch (_inner: Exception) { () } }
        this.stdoutBuffer.close()
        this.stderrBuffer.close()
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
                case Some(value) => buffer.appendLine(value)
                case None =>
                    buffer.close()
                    return
            }
        }
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
            let _ = this.condition.waitUntil({ => this.closed || !this.responses.isEmpty() }, timeout: Duration.millisecond * effective)
            if (!this.responses.isEmpty()) {
                let frame = this.responses[0]
                this.responses.remove(at: 0)
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

public func resetServicePluginHostForTest(): Unit {
    stopAllActiveServicePluginProcesses()
    servicePluginRegistry = HashMap<String, ServicePluginRuntimeRecord>()
    serviceCapabilityRoutes = HashMap<String, (String, ServiceCapabilityRecord)>()
    servicePluginCapabilityInvokerForTest = None<(ServicePluginRegistration, CapabilityInvokeRequest) -> CapabilityInvokeResult>
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
        record.instanceSeq++
        record.instanceId = "${serviceId}-${record.instanceSeq}"
        let args = servicePluginArgsWithConfigRef(record.registration.manifest.entryArgs, record.registration.configRef.configPath)
        let process = try {
            let proc = launch(
                record.registration.manifest.entryCommand,
                args,
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe,
                workingDirectory: if (cwd.isEmpty()) { None<Path> } else { Some(Path(cwd)) }
            )
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
            record.eventFrames.add(frame)
            let handled = handleServiceCapabilityEvent(ServiceCapabilityEvent(frame.serviceId, frame.capabilityId, payload: frame.payload))
            if (handled.ok) {
                let dispatch = dispatchServicePluginEvent(frame)
                servicePluginRecordRuntimeDispatch(record, frame, dispatch)
            } else {
                record.lastError = redactServicePayload(handled.diagnostic).text
            }
            continue
        }
        if (frame.frameType == "audit") {
            continue
        }
    }
}

private func servicePluginRecordRuntimeDispatch(record: ServicePluginRuntimeRecord, frame: ServiceFrame, dispatch: ServicePluginEventDispatchResult): Unit {
    if (!dispatch.ok || dispatch.status == "no_subscribers" || dispatch.status == "generated_reply_partially_delivered" || dispatch.status == "generated_reply_delivery_failed") {
        record.lastError = servicePluginDispatchDiagnosticSummary(frame, dispatch)
        return
    }
    record.lastError = ""
}

public func recordServicePluginRuntimeDispatchForTest(serviceId: String, frame: ServiceFrame, dispatch: ServicePluginEventDispatchResult): Unit {
    match (servicePluginRegistry.get(serviceId.trimAscii())) {
        case Some(record) =>
            if (record.status == "registered") {
                record.status = "running"
            }
            servicePluginRecordRuntimeDispatch(record, frame, dispatch)
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
                        process.stop()
                        servicePluginActiveProcesses.remove(serviceId.trimAscii())
                    case None => ()
                }
                match (servicePluginResponseQueues.get(serviceId.trimAscii())) {
                    case Some(queue) =>
                        queue.close(status: "stopped", diagnostic: "service plugin stopped: ${reason.trimAscii()}")
                        servicePluginResponseQueues.remove(serviceId.trimAscii())
                    case None => ()
                }
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
    "serviceId=${snapshot.serviceId} status=${snapshot.status} enabled=${snapshot.enabled} capabilities=${serviceJoinStrings(snapshot.capabilityIds, ",")} config=${snapshot.configSummary} degradedReason=${redactedReason} lastError=${redactedLastError}"
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
            lastError: record.lastError
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
