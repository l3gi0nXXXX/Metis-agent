package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager}
import metis.gateway.core.GatewayStopResult
import metis.process.{ProcessInstanceIdentity, currentProcessInstanceIdentity, parseProcessInstanceIdentity, probeProcessInstance, processInstanceKillSignal, processInstanceTermSignal, publishExclusiveUtf8File, signalProcessInstance}
import metis.utils.{InfoUtils, SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, ShellTimeoutException, ShellUtils}

import std.collection.{ArrayList, HashSet}
import std.convert.Parsable
import std.env.{atExit, getVariable}
import std.fs.{Path, File, FileInfo, exists, remove, rename}
import std.posix.chmod
import std.sync.*
import std.time.{DateTime, MonoTime}
import std.core.Duration
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

private let LOCK_FILE: String = "gateway-serve.lock"
private let COMPLETION_FILE: String = "gateway-serve.stop-complete"
private let STOP_REQUEST_FILE: String = "gateway-serve.stop-request"
public let GATEWAY_SERVE_GRACEFUL_SHUTDOWN_TIMEOUT_MS: Int64 = 60000
private let GATEWAY_SERVE_STOP_REQUEST_GRACE_MS: Int64 = 55000
private let GATEWAY_SERVE_TERM_RESERVE_MS: Int64 = 3000
private let GATEWAY_SERVE_FORCE_KILL_RESERVE_MS: Int64 = 2000

/** Derive the server budget from the original request; never restart the CLI's 55s window. */
public func gatewayShutdownWorkRemainingMs(requestedAtMs: Int64, wallNowMs: Int64,
    windowMs!: Int64 = 55000, completionReserveMs!: Int64 = 1000): Int64 {
    let elapsed = if (wallNowMs > requestedAtMs) { wallNowMs - requestedAtMs } else { 0 }
    max(0, max(0, windowMs - completionReserveMs) - min(max(0, windowMs), elapsed))
}

public func gatewayServeShutdownDeadline(identity: Option<GatewayServeIdentity>): MonoTime {
    var remaining: Int64 = 54000
    match (identity) {
        case Some(expected) =>
            match (gatewayReadLockText(gatewayServeStopRequestPath())) {
                case Some(text) =>
                    match (gatewayParseServeStopRequestIdentity(text)) {
                        case Some(requested) =>
                            if (requested.matches(expected)) {
                                remaining = try {
                                    gatewayShutdownWorkRemainingMs(Int64.parse(gatewayServePayloadField(text, "requestedAtMs")),
                                        DateTime.now().toUnixTimeStamp().toMilliseconds())
                                } catch (_: Exception) { 0 }
                            }
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    MonoTime.now() + Duration.millisecond * remaining
}

/** Retained only for actual serve shutdown phases; a timed out closure still owns its resources. */
class GatewayShutdownPhase {
    let name: String
    private let lock = Mutex()
    private var condition: Condition
    private var settled = false
    private var result = GatewaySurfaceStopResult(false, "cleanup_pending")
    private let ownerWork: () -> GatewaySurfaceStopResult
    private var future: Option<Future<Unit>> = None<Future<Unit>>

    init(name: String, work: () -> GatewaySurfaceStopResult) {
        this.name = name
        this.ownerWork = work
        synchronized(this.lock) { this.condition = this.lock.condition() }
        this.future = Some(spawn {
            try {
                let value = this.ownerWork()
                synchronized(this.lock) { this.result = value }
            } catch (_: Exception) {
                synchronized(this.lock) { this.result = GatewaySurfaceStopResult(false, "stop_failed") }
            } finally {
                synchronized(this.lock) { this.settled = true; this.condition.notifyAll() }
            }
        })
    }

    func awaitUntil(deadline: MonoTime): GatewaySurfaceStopResult {
        synchronized(this.lock) {
            while (!this.settled) {
                let remaining = (deadline - MonoTime.now()).toMilliseconds()
                if (remaining <= 0) { return GatewaySurfaceStopResult(false, "cleanup_pending") }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            this.result
        }
    }

    func terminalObserved(): Bool {
        synchronized(this.lock) { this.settled && (this.result.ok || this.name == "state") }
    }
}

/** One serve invocation owns one collection, so late work cannot be mistaken for a new generation. */
class GatewayServeShutdownOwners {
    private let lock = Mutex()
    private var phases = ArrayList<GatewayShutdownPhase>()

    func run(name: String, deadline: MonoTime, work: () -> GatewaySurfaceStopResult): GatewaySurfaceStopResult {
        let phase = GatewayShutdownPhase(name, work)
        synchronized(this.lock) { this.phases.add(phase) }
        phase.awaitUntil(deadline)
    }

    func result(name: String, fallback: GatewaySurfaceStopResult): GatewaySurfaceStopResult {
        let current = synchronized(this.lock) { this.phases.toArray() }
        for (phase in current) { if (phase.name == name) { return phase.awaitUntil(MonoTime.now()) } }
        fallback
    }

    func reap(): Int64 {
        synchronized(this.lock) {
            let pending = ArrayList<GatewayShutdownPhase>()
            for (phase in this.phases) { if (!phase.terminalObserved()) { pending.add(phase) } }
            this.phases = pending
            Int64(pending.size)
        }
    }
}

private let gatewayPendingShutdownOwnersLock = Mutex()
private var gatewayPendingShutdownOwners = ArrayList<GatewayServeShutdownOwners>()

func gatewayHasPendingShutdownOwners(): Bool {
    synchronized(gatewayPendingShutdownOwnersLock) {
        let pending = ArrayList<GatewayServeShutdownOwners>()
        for (previous in gatewayPendingShutdownOwners) { if (previous.reap() > 0) { pending.add(previous) } }
        gatewayPendingShutdownOwners = pending
        !pending.isEmpty()
    }
}

func gatewayRetainPendingShutdownOwners(owners: GatewayServeShutdownOwners): Unit {
    synchronized(gatewayPendingShutdownOwnersLock) {
        let pending = ArrayList<GatewayServeShutdownOwners>()
        for (previous in gatewayPendingShutdownOwners) { if (previous.reap() > 0) { pending.add(previous) } }
        if (owners.reap() > 0) { pending.add(owners) }
        gatewayPendingShutdownOwners = pending
    }
}

/** 无 pid 字段的旧版锁文件：仍用 mtime 判断；有 pid 时以进程是否存在为准。 */
private let LEGACY_LOCK_TTL: Duration = Duration.minute * 3
private let GATEWAY_STOP_TERM_WAIT_TOTAL: Duration = Duration.millisecond * 900
private let GATEWAY_STOP_TERM_WAIT_STEP: Duration = Duration.millisecond * 50
private let GATEWAY_STOP_KILL_WAIT_TOTAL: Duration = Duration.millisecond * 500
private let GATEWAY_STOP_KILL_WAIT_STEP: Duration = Duration.millisecond * 50
private let gatewayServeMonotonicOrigin = MonoTime.now()
private let gatewayServeIdentityLock = Mutex()
private let gatewayServePortProbeLock = Mutex()
private var gatewayServePortProbeForTest: Option<(Int64, Int64) -> (Int64, String, String)> =
    None<(Int64, Int64) -> (Int64, String, String)>

/** Test-only synchronous probe seam. None preserves the production ShellUtils path. */
public func setGatewayServePortProbeForTest(
    probe: Option<(Int64, Int64) -> (Int64, String, String)>
): Unit {
    synchronized(gatewayServePortProbeLock) { gatewayServePortProbeForTest = probe }
}

public class GatewayServeIdentity {
    public let pid: Int64
    public let startedAtMs: Int64
    public let nonce: String
    public let processIdentity: Option<ProcessInstanceIdentity>

    public init(pid: Int64, startedAtMs: Int64, nonce: String, processIdentity!: Option<ProcessInstanceIdentity> = None<ProcessInstanceIdentity>) {
        this.pid = pid
        this.startedAtMs = startedAtMs
        this.nonce = nonce.trimAscii()
        this.processIdentity = processIdentity
    }

    public func matches(other: GatewayServeIdentity): Bool {
        if (this.pid != other.pid || this.startedAtMs != other.startedAtMs || this.nonce != other.nonce) { return false }
        match ((this.processIdentity, other.processIdentity)) {
            case (Some(left), Some(right)) => left.matches(right)
            case (None, None) => true
            case _ => false
        }
    }
}

public class GatewayServePidProbeResult {
    public let conclusive: Bool
    public let alive: Bool
    public let status: String

    public init(conclusive: Bool, alive: Bool, status: String) {
        this.conclusive = conclusive
        this.alive = alive
        this.status = status.trimAscii()
    }
}

public class GatewayServeListenerDiscoveryResult {
    public let conclusive: Bool
    public let pids: Array<Int64>
    public let status: String

    public init(conclusive: Bool, pids: Array<Int64>, status: String) {
        this.conclusive = conclusive
        this.pids = pids
        this.status = status.trimAscii()
    }
}

public class GatewaySurfaceStopResult {
    public let ok: Bool
    public let status: String
    public let portStatus: String

    public init(ok: Bool, status: String, portStatus!: String = "not_applicable") {
        this.ok = ok
        this.status = status.trimAscii()
        this.portStatus = portStatus.trimAscii()
    }
}

public class GatewayServeCompletionResult {
    public let found: Bool
    public let status: String
    public let fullTerminal: Bool
    public let shutdownPhase: String
    public let inboundStatus: String
    public let compatStatus: String
    public let sidecarStatus: String
    public let servicePluginIngressStatus: String
    public let servicePluginDispatchStatus: String
    public let servicePluginOwnerStatus: String
    public let servicePluginLeaseStatus: String
    public let servicePluginPortStatus: String
    public let servicePluginPendingCount: Int64
    public let channelsStatus: String
    public let brokerStatus: String
    public let httpStatus: String
    public let canvasStatus: String
    public let gatewayServerStatus: String

    public init(found: Bool, status!: String = "missing", fullTerminal!: Bool = false, shutdownPhase!: String = "unknown",
        inboundStatus!: String = "not_checked", compatStatus!: String = "not_checked", sidecarStatus!: String = "not_checked",
        servicePluginIngressStatus!: String = "not_checked", servicePluginDispatchStatus!: String = "not_checked",
        servicePluginOwnerStatus!: String = "not_checked", servicePluginLeaseStatus!: String = "not_checked",
        servicePluginPortStatus!: String = "not_checked", servicePluginPendingCount!: Int64 = 0,
        channelsStatus!: String = "not_checked", brokerStatus!: String = "not_checked",
        httpStatus!: String = "not_checked", canvasStatus!: String = "not_checked",
        gatewayServerStatus!: String = "not_checked") {
        this.found = found
        this.status = status.trimAscii()
        this.fullTerminal = fullTerminal
        this.shutdownPhase = shutdownPhase
        this.inboundStatus = inboundStatus.trimAscii()
        this.compatStatus = compatStatus.trimAscii()
        this.sidecarStatus = sidecarStatus.trimAscii()
        this.servicePluginIngressStatus = servicePluginIngressStatus.trimAscii()
        this.servicePluginDispatchStatus = servicePluginDispatchStatus.trimAscii()
        this.servicePluginOwnerStatus = servicePluginOwnerStatus.trimAscii()
        this.servicePluginLeaseStatus = servicePluginLeaseStatus.trimAscii()
        this.servicePluginPortStatus = servicePluginPortStatus.trimAscii()
        this.servicePluginPendingCount = max(0, servicePluginPendingCount)
        this.channelsStatus = channelsStatus.trimAscii()
        this.brokerStatus = brokerStatus.trimAscii()
        this.httpStatus = httpStatus.trimAscii()
        this.canvasStatus = canvasStatus.trimAscii()
        this.gatewayServerStatus = gatewayServerStatus.trimAscii()
    }
}

public class GatewayServeCompletionReconcileResult {
    public let ok: Bool
    public let status: String

    public init(ok: Bool, status: String) {
        this.ok = ok
        this.status = status.trimAscii()
    }
}

public class GatewayServeTerminationResult {
    public let ok: Bool
    public let status: String
    public let termSent: Bool
    public let killSent: Bool
    public let pidStatus: String
    public let shutdownPhase: String

    public init(ok: Bool, status: String, termSent!: Bool = false, killSent!: Bool = false, pidStatus!: String = "not_checked", shutdownPhase!: String = "unknown") {
        this.ok = ok
        this.status = status.trimAscii()
        this.termSent = termSent
        this.killSent = killSent
        this.pidStatus = pidStatus.trimAscii()
        this.shutdownPhase = shutdownPhase
    }
}

private var gatewayActiveServeIdentity: Option<GatewayServeIdentity> = None<GatewayServeIdentity>

@When[os == "Windows"]
foreign {
    func GetCurrentProcessId(): UInt32
}

@When[os != "Windows"]
foreign {
    func getpid(): Int32
}

@When[os == "Windows"]
private func gatewayCurrentProcessId(): Int64 {
    Int64(unsafe { GetCurrentProcessId() })
}

@When[os != "Windows"]
private func gatewayCurrentProcessId(): Int64 {
    Int64(unsafe { getpid() })
}

/**
 * 常驻网关进程持有的锁路径（`~/.metis/gateway-serve.lock`）。
 */
public func gatewayServeLockPath(): Path {
    CliConfig.dotDir.join(LOCK_FILE)
}

public func gatewayConfiguredServePort(): Int64 {
    try {
        let user = CliSettingManager.readGatewaySettings()
        if (user.port > 0) {
            return user.port
        }
    } catch (_: Exception) {
        ()
    }
    18788
}

func gatewayServePayloadField(text: String, key: String): String {
    for (line in text.split("\n")) {
        let t = line.trimAscii()
        let parts = t.split(":")
        if (parts.size >= 2 && parts[0].trimAscii() == key) {
            let rest = ArrayList<String>()
            for (index in 1..parts.size) { rest.add(parts[index]) }
            return String.join(rest.toArray(), delimiter: ":").trimAscii()
        }
    }
    ""
}

private func gatewayParseLockPid(text: String): Option<Int64> {
    let raw = gatewayServePayloadField(text, "pid")
    if (raw.isEmpty()) { return None<Int64> }
    try { Some(Int64.parse(raw)) } catch (_: Exception) { None<Int64> }
}

public func gatewayParseServeIdentity(text: String): Option<GatewayServeIdentity> {
    let pidText = gatewayServePayloadField(text, "pid")
    let startedText = gatewayServePayloadField(text, "startedAtMs")
    let nonce = gatewayServePayloadField(text, "nonce")
    if (pidText.isEmpty() || startedText.isEmpty() || nonce.isEmpty()) { return None<GatewayServeIdentity> }
    try {
        let pid = Int64.parse(pidText)
        let startedAtMs = Int64.parse(startedText)
        if (pid <= 0 || startedAtMs <= 0) { return None<GatewayServeIdentity> }
        let instance = parseProcessInstanceIdentity(gatewayServePayloadField(text, "processIdentity"))
        Some(GatewayServeIdentity(pid, startedAtMs, nonce, processIdentity: instance))
    } catch (_: Exception) {
        None<GatewayServeIdentity>
    }
}

public func gatewayParsePidListText(text: String): Array<Int64> {
    let result = ArrayList<Int64>()
    let seen = HashSet<Int64>()
    for (line in text.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            continue
        }
        try {
            let pid = Int64.parse(trimmed)
            if (pid > 0 && !seen.contains(pid)) {
                seen.add(pid)
                result.add(pid)
            }
        } catch (_: Exception) {
            ()
        }
    }
    result.toArray()
}

public func gatewayLooksLikeServeCommand(command: String): Bool {
    let normalized = command.trimAscii().toAsciiLower()
    if (normalized.isEmpty()) {
        return false
    }
    let looksLikeBinary =
        normalized.contains("metis") ||
        normalized.contains("magic-cli") ||
        normalized.contains("cjpm")
    let looksLikeServe = normalized.contains("gateway") && normalized.contains("serve")
    return looksLikeBinary && looksLikeServe
}

private func gatewayReadProcessCommand(pid: Int64, timeoutMs: Int64): Option<String> {
    if (pid <= 0) {
        return None
    }
    if (InfoUtils.os == "windows") {
        return None
    }
    let (ec, out, _) = ShellUtils.execute(
        ["ps", "-o", "command=", "-p", "${pid}"],
        withWrap: false,
        timeout: Some(Duration.millisecond * max(1, timeoutMs))
    )
    if (ec != 0) {
        return None
    }
    let trimmed = out.trimAscii()
    if (trimmed.isEmpty()) {
        return None
    }
    Some(trimmed)
}

public func gatewayFindVerifiedListenerPidsOnPortDetailed(port!: Int64 = gatewayConfiguredServePort(), timeoutMs!: Int64 = 800): GatewayServeListenerDiscoveryResult {
    gatewayFindVerifiedListenerPidsOnPortUntil(
        MonoTime.now() + Duration.millisecond * max(1, timeoutMs),
        port: port
    )
}

public func gatewayFindVerifiedListenerPidsOnPortUntil(deadline: MonoTime, port!: Int64 = gatewayConfiguredServePort()): GatewayServeListenerDiscoveryResult {
    if (port <= 0 || InfoUtils.os == "windows") {
        return GatewayServeListenerDiscoveryResult(false, [], "listener_discovery_unsupported")
    }
    let initialRemaining = (deadline - MonoTime.now()).toMilliseconds()
    if (initialRemaining <= 0) { return GatewayServeListenerDiscoveryResult(false, [], "listener_discovery_timeout") }
    let execution = try {
        ShellUtils.execute(
            ["lsof", "-nP", "-iTCP:${port}", "-sTCP:LISTEN", "-t"],
            withWrap: false,
            timeout: Some(Duration.millisecond * initialRemaining)
        )
    } catch (_: ShellTimeoutException) {
        return GatewayServeListenerDiscoveryResult(false, [], "listener_discovery_timeout")
    } catch (_: Exception) {
        return GatewayServeListenerDiscoveryResult(false, [], "listener_discovery_failed")
    }
    let (ec, out, _) = execution
    if (ec != 0) {
        return if (ec == 1) {
            GatewayServeListenerDiscoveryResult(true, [], "no_listener")
        } else if (ec == 124) {
            GatewayServeListenerDiscoveryResult(false, [], "listener_discovery_timeout")
        } else if (ec == SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE) {
            GatewayServeListenerDiscoveryResult(false, [], "invalid_response_encoding")
        } else {
            GatewayServeListenerDiscoveryResult(false, [], "listener_discovery_failed")
        }
    }
    let result = ArrayList<Int64>()
    for (pid in gatewayParsePidListText(out)) {
        let remaining = (deadline - MonoTime.now()).toMilliseconds()
        if (remaining <= 0) { return GatewayServeListenerDiscoveryResult(false, result.toArray(), "listener_discovery_timeout") }
        try {
            match (gatewayReadProcessCommand(pid, remaining)) {
                case Some(command) =>
                    if (gatewayLooksLikeServeCommand(command)) {
                        result.add(pid)
                    }
                case None => return GatewayServeListenerDiscoveryResult(false, result.toArray(), "listener_identity_unavailable")
            }
        } catch (_: ShellTimeoutException) {
            return GatewayServeListenerDiscoveryResult(false, result.toArray(), "listener_discovery_timeout")
        } catch (_: Exception) {
            return GatewayServeListenerDiscoveryResult(false, result.toArray(), "listener_discovery_failed")
        }
    }
    GatewayServeListenerDiscoveryResult(true, result.toArray(), if (result.isEmpty()) { "no_listener" } else { "listeners_verified" })
}

public func gatewayFindVerifiedListenerPidsOnPort(port!: Int64 = gatewayConfiguredServePort(), timeoutMs!: Int64 = 800): Array<Int64> {
    gatewayFindVerifiedListenerPidsOnPortDetailed(port: port, timeoutMs: timeoutMs).pids
}

public func gatewayResolveStopTargetPids(
    listenerPids: Array<Int64>,
    lockPid!: Option<Int64> = None
): Array<Int64> {
    if (listenerPids.size > 0) {
        return listenerPids
    }
    match (lockPid) {
        case Some(pid) => if (pid > 0) { [pid] } else { [] }
        case None => []
    }
}

/** 判断指定 PID 是否仍在运行（供 CLI stop / 锁校验共用）。 */
public func gatewayServePidProbe(pid: Int64, timeoutMs: Int64): GatewayServePidProbeResult {
    if (pid <= 0) {
        return GatewayServePidProbeResult(true, false, "gone")
    }
    if (InfoUtils.os == "windows") {
        try {
            let (ec, out, _) = ShellUtils.execute(["tasklist", "/FI", "PID eq ${pid}", "/NH"], withWrap: false, timeout: Some(Duration.millisecond * max(1, timeoutMs)))
            if (ec == 0 && out.contains("${pid}")) { return GatewayServePidProbeResult(true, true, "alive") }
            return GatewayServePidProbeResult(false, false, "pid_probe_unavailable")
        } catch (_: Exception) {
            return GatewayServePidProbeResult(false, false, "pid_probe_unavailable")
        }
    }
    let (exitCode, stdout, stderr) = ShellUtils.executeWithDeadline("kill -0 ${pid}", max(1, timeoutMs))
    let stdoutText = stdout.trimAscii()
    let stderrText = stderr.trimAscii()
    if (exitCode == 0 && stderrText.isEmpty()) { return GatewayServePidProbeResult(true, true, "alive") }
    if (exitCode == 124) { return GatewayServePidProbeResult(false, false, "pid_probe_timeout") }
    if (exitCode == SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE) { return GatewayServePidProbeResult(false, false, "invalid_response_encoding") }
    let explicitGone = exitCode == 1 && stdoutText.isEmpty() &&
        (stderrText.contains("No such process") || stderrText.contains("no such process") || stderrText.contains("ESRCH"))
    if (explicitGone) { return GatewayServePidProbeResult(true, false, "gone") }
    if (stderrText.contains("Operation not permitted") || stderrText.contains("EPERM")) {
        return GatewayServePidProbeResult(false, false, "pid_probe_permission_denied")
    }
    GatewayServePidProbeResult(false, false, "pid_probe_unavailable")
}

public func gatewayServePidIsAlive(pid: Int64): Bool {
    let probe = gatewayServePidProbe(pid, 500)
    probe.conclusive && probe.alive
}

private func gatewayWriteServeLockPayload(identity: GatewayServeIdentity): String {
    let instance = match (identity.processIdentity) {
        case Some(value) => value.serialize()
        case None => ""
    }
    "gateway-serve-active-v4\npid:${identity.pid}\nstartedAtMs:${identity.startedAtMs}\nnonce:${identity.nonce}\nprocessIdentity:${instance}\ngracefulShutdownTimeoutMs:${GATEWAY_SERVE_GRACEFUL_SHUTDOWN_TIMEOUT_MS}\n"
}

private func gatewayAtomicWrite(path: Path, text: String): Bool {
    let tmp = Path("${path.toString()}.tmp-${gatewayCurrentProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try {
        File.writeTo(tmp, text.toArray())
        rename(tmp, to: path, overwrite: true)
        true
    } catch (_: Exception) {
        try { if (exists(tmp)) { remove(tmp) } } catch (_: Exception) { () }
        false
    }
}

private func gatewayShutdownPhaseSequence(phase: String): Int64 {
    if (phase == "stop_request_observed") { return 1 }
    if (phase == "canvas_done") { return 2 }
    if (phase == "http_close_enter") { return 3 }
    if (phase == "http_close_returned") { return 4 }
    if (phase == "http_probe_done") { return 5 }
    if (phase == "gateway_stop_enter") { return 6 }
    if (phase == "owners_enter") { return 7 }
    if (phase == "owners_done") { return 8 }
    if (phase == "channels_enter") { return 9 }
    if (phase == "channels_done") { return 10 }
    if (phase == "broker_enter") { return 11 }
    if (phase == "broker_done") { return 12 }
    if (phase == "gateway_stop_returned") { return 13 }
    if (phase == "completion_written") { return 14 }
    0
}

/** Test-only shutdown ordering proof. Empty or partial environment is a zero-behaviour no-op. */
public func gatewayPublishShutdownPhaseForTest(identity: GatewayServeIdentity, phase: String): Bool {
    let markerBase = getVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_MARKER").getOrDefault { "" }.trimAscii()
    let testNonce = getVariable("METIS_TEST_GATEWAY_SHUTDOWN_PHASE_NONCE").getOrDefault { "" }.trimAscii()
    let sequence = gatewayShutdownPhaseSequence(phase.trimAscii())
    if (markerBase.isEmpty() || testNonce.isEmpty() || sequence <= 0) { return false }
    let processIdentity = match (identity.processIdentity) {
        case Some(value) => value.serialize()
        case None => return false
    }
    if (sequence > 1) {
        let previous = Path("${markerBase}.${sequence - 1}.json")
        let previousMatches = try {
            let value = JsonValue.fromStr(String.fromUtf8(File.readFrom(previous))).asObject()
            value.get("schema").getOrThrow().asString().getValue() == "metis.gateway.shutdownPhase.v1" &&
                value.get("sequence").getOrThrow().asInt().getValue() == sequence - 1 &&
                value.get("pid").getOrThrow().asInt().getValue() == identity.pid &&
                value.get("startedAtMs").getOrThrow().asInt().getValue() == identity.startedAtMs &&
                value.get("nonce").getOrThrow().asString().getValue() == identity.nonce &&
                value.get("processIdentity").getOrThrow().asString().getValue() == processIdentity &&
                value.get("testNonce").getOrThrow().asString().getValue() == testNonce
        } catch (_: Exception) {
            false
        }
        if (!previousMatches) { return false }
    }
    let marker = Path("${markerBase}.${sequence}.json")
    let temporary = Path("${marker.toString()}.tmp-${gatewayCurrentProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try {
        let root = JsonObject()
        root.put("schema", JsonString("metis.gateway.shutdownPhase.v1"))
        root.put("phase", JsonString(phase.trimAscii()))
        root.put("sequence", JsonInt(sequence))
        root.put("pid", JsonInt(identity.pid))
        root.put("startedAtMs", JsonInt(identity.startedAtMs))
        root.put("nonce", JsonString(identity.nonce))
        root.put("processIdentity", JsonString(processIdentity))
        root.put("testNonce", JsonString(testNonce))
        root.put("observedMonotonicMs", JsonInt(gatewayServeNowMonotonicMs()))
        File.writeTo(temporary, root.toJsonString().toArray())
        chmod(temporary.toString(), UInt32(0o600))
        rename(temporary, to: marker, overwrite: true)
        chmod(marker.toString(), UInt32(0o600))
        true
    } catch (_: Exception) {
        try { if (exists(temporary)) { remove(temporary) } } catch (_: Exception) { () }
        false
    }
}

func gatewayReadLockText(p: Path): Option<String> {
    try {
        Some(String.fromUtf8(File.readFrom(p)))
    } catch (_: Exception) {
        None
    }
}

func gatewayReadServeIdentity(): Option<GatewayServeIdentity> {
    match (gatewayReadLockText(gatewayServeLockPath())) {
        case Some(text) => gatewayParseServeIdentity(text)
        case None => None<GatewayServeIdentity>
    }
}

public func gatewayCurrentServeIdentity(): Option<GatewayServeIdentity> {
    let active = synchronized(gatewayServeIdentityLock) { gatewayActiveServeIdentity }
    match (active) {
        case Some(identity) => Some(identity)
        case None => gatewayReadServeIdentity()
    }
}

func gatewayServeCompletionPath(): Path { CliConfig.dotDir.join(COMPLETION_FILE) }

private func gatewayServeStopRequestPath(): Path { CliConfig.dotDir.join(STOP_REQUEST_FILE) }

public func gatewayParseServeStopRequestIdentity(text: String): Option<GatewayServeIdentity> {
    let identity = gatewayParseServeIdentity(text)
    if (identity.isNone()) { return None<GatewayServeIdentity> }
    if (identity.getOrThrow().processIdentity.isNone()) { return None<GatewayServeIdentity> }
    try {
        if (Int64.parse(gatewayServePayloadField(text, "requestedAtMs")) <= 0) {
            return None<GatewayServeIdentity>
        }
    } catch (_: Exception) {
        return None<GatewayServeIdentity>
    }
    identity
}

private func gatewayWriteServeStopRequest(identity: GatewayServeIdentity): Bool {
    match (gatewayReadServeIdentity()) {
        case Some(current) => if (!current.matches(identity)) { return false }
        case None => return false
    }
    if (!gatewayAtomicWrite(
        gatewayServeStopRequestPath(),
        gatewayWriteServeLockPayload(identity) +
            "requestedAtMs:${DateTime.now().toUnixTimeStamp().toMilliseconds()}\n"
    )) { return false }
    match (gatewayReadServeIdentity()) {
        case Some(current) =>
            if (current.matches(identity)) { return true }
        case None => ()
    }
    let _ = gatewayRemoveServeStopRequest(identity)
    false
}

public func gatewayServeStopRequested(identity: GatewayServeIdentity): Bool {
    let path = gatewayServeStopRequestPath()
    if (!exists(path)) { return false }
    match (gatewayReadLockText(path)) {
        case Some(text) =>
            match (gatewayParseServeStopRequestIdentity(text)) {
                case Some(requested) =>
                    let matched = requested.matches(identity)
                    if (matched) { let _ = gatewayPublishShutdownPhaseForTest(identity, "stop_request_observed") }
                    matched
                case None => false
            }
        case None => false
    }
}

private func gatewayRemoveServeStopRequest(expected: GatewayServeIdentity): Bool {
    let path = gatewayServeStopRequestPath()
    try {
        if (!exists(path)) { return true }
        match (gatewayReadLockText(path)) {
            case Some(text) =>
                match (gatewayParseServeStopRequestIdentity(text)) {
                    case Some(requested) => if (!requested.matches(expected)) { return false }
                    case None => return false
                }
            case None => return false
        }
        remove(path)
        true
    } catch (_: Exception) {
        false
    }
}

func gatewayShutdownCompletionFactsTerminal(text: String): Bool {
    for (key in ["channelPendingCount", "shutdownPendingCount"]) {
        if (!text.contains("\n${key}:")) { continue }
        let count = try { Int64.parse(gatewayServePayloadField(text, key)) } catch (_: Exception) { -1 }
        if (count != 0) { return false }
    }
    for (key in ["cronStatus", "memoryStatus"]) {
        if (!text.contains("\n${key}:")) { continue }
        let status = gatewayServePayloadField(text, key)
        if (status != "stopped" && status != "not_applicable" &&
            !(key == "memoryStatus" && status == "already_stopped")) { return false }
    }
    true
}

func gatewayParseServeCompletion(text: String, identity: GatewayServeIdentity): GatewayServeCompletionResult {
    match (gatewayParseServeIdentity(text)) {
        case Some(found) =>
            if (!found.matches(identity)) { return GatewayServeCompletionResult(false, status: "identity_mismatch") }
            let status = gatewayServePayloadField(text, "status")
            if (status == "graceful" || status == "cleanup_pending") {
                let pending = try { Int64.parse(gatewayServePayloadField(text, "servicePluginPendingCount")) } catch (_: Exception) { -1 }
                if (pending < 0) { return GatewayServeCompletionResult(false, status: "malformed") }
                for (key in ["channelPendingCount", "shutdownPendingCount"]) {
                    let raw = gatewayServePayloadField(text, key)
                    if (!text.contains("\n${key}:")) { continue }
                    let count = try { Int64.parse(raw) } catch (_: Exception) { -1 }
                    if (count < 0) { return GatewayServeCompletionResult(false, status: "malformed") }
                }
                let fullTerminal = gatewayServePayloadField(text, "fullTerminal") == "1" && pending == 0 && gatewayShutdownCompletionFactsTerminal(text)
                return GatewayServeCompletionResult(
                    true,
                    status: status,
                    fullTerminal: fullTerminal,
                    shutdownPhase: gatewayServePayloadField(text, "shutdownPhase"),
                    inboundStatus: gatewayServePayloadField(text, "inboundStatus"),
                    compatStatus: gatewayServePayloadField(text, "compatStatus"),
                    sidecarStatus: gatewayServePayloadField(text, "sidecarStatus"),
                    servicePluginIngressStatus: gatewayServePayloadField(text, "servicePluginIngressStatus"),
                    servicePluginDispatchStatus: gatewayServePayloadField(text, "servicePluginDispatchStatus"),
                    servicePluginOwnerStatus: gatewayServePayloadField(text, "servicePluginOwnerStatus"),
                    servicePluginLeaseStatus: gatewayServePayloadField(text, "servicePluginLeaseStatus"),
                    servicePluginPortStatus: gatewayServePayloadField(text, "servicePluginPortStatus"),
                    servicePluginPendingCount: pending,
                    channelsStatus: gatewayServePayloadField(text, "channelsStatus"),
                    brokerStatus: gatewayServePayloadField(text, "brokerStatus"),
                    httpStatus: gatewayServePayloadField(text, "httpStatus"),
                    canvasStatus: gatewayServePayloadField(text, "canvasStatus"),
                    gatewayServerStatus: gatewayServePayloadField(text, "gatewayServerStatus")
                )
            }
            GatewayServeCompletionResult(false, status: "malformed")
        case None => GatewayServeCompletionResult(false, status: "malformed")
    }
}

private func gatewayReadServeCompletion(identity: GatewayServeIdentity): GatewayServeCompletionResult {
    let path = gatewayServeCompletionPath()
    if (!exists(path)) { return GatewayServeCompletionResult(false) }
    match (gatewayReadLockText(path)) {
        case Some(text) => gatewayParseServeCompletion(text, identity)
        case None => GatewayServeCompletionResult(false, status: "invalid_response_encoding")
    }
}

/**
 * 仅清理 identity-bound、原进程已确定死亡且所有外部资源均终止的历史 completion。
 * durable pending 业务状态不在此文件中，不会被删除。
 */
func gatewayOwnsCurrentServeLock(): Bool {
    synchronized(gatewayServeIdentityLock) {
        let safe = try {
            let root = FileInfo(CliConfig.dotDir)
            let lockInfo = FileInfo(gatewayServeLockPath())
            root.isDirectory() && !root.isSymbolicLink() && lockInfo.isRegular() && !lockInfo.isSymbolicLink()
        } catch (_: Exception) { false }
        if (!safe) { return false }
        match ((gatewayActiveServeIdentity, gatewayReadServeIdentity())) {
            case (Some(expected), Some(current)) => expected.matches(current)
            case _ => false
        }
    }
}

private func gatewayEvaluateHistoricalServeCompletion(removeMarker: Bool): GatewayServeCompletionReconcileResult {
    if (removeMarker && !gatewayOwnsCurrentServeLock()) { return GatewayServeCompletionReconcileResult(false, "lock_not_owned") }
    let deadline = MonoTime.now() + Duration.second * 5
    let evidence = gatewayCollectHistoricalRecoveryEvidence(deadline)
    if (removeMarker) { gatewayCommitHistoricalRecovery(evidence, deadline) }
    else { gatewayEvaluateHistoricalRecoveryEvidence(evidence) }
}

public func gatewayHistoricalServeCompletionRecoveryStatus(): GatewayServeCompletionReconcileResult {
    gatewayEvaluateHistoricalServeCompletion(false)
}

public func gatewayReconcileHistoricalServeCompletion(): GatewayServeCompletionReconcileResult {
    gatewayEvaluateHistoricalServeCompletion(true)
}

public func gatewayPendingServeCompletionStatus(): String {
    let path = gatewayServeCompletionPath()
    if (!exists(path)) {
        let requestPath = gatewayServeStopRequestPath()
        if (!exists(requestPath)) { return "missing" }
        return match (gatewayReadLockText(requestPath)) {
            case Some(text) => if (gatewayParseServeStopRequestIdentity(text).isSome()) { "cleanup_pending" } else { "malformed" }
            case None => "invalid_response_encoding"
        }
    }
    match (gatewayReadLockText(path)) {
        case Some(text) =>
            let status = gatewayServePayloadField(text, "status")
            if (status == "cleanup_pending") { "cleanup_pending" } else if (status == "graceful") { "graceful" } else { "malformed" }
        case None => "invalid_response_encoding"
    }
}

public func gatewayWriteServeCompletionMarker(identity: GatewayServeIdentity, status: String): Bool {
    let normalized = if (status.trimAscii() == "stopped" || status.trimAscii() == "graceful") { "graceful" } else { "cleanup_pending" }
    try {
        gatewayAtomicWrite(gatewayServeCompletionPath(), gatewayWriteServeLockPayload(identity) + "status:${normalized}\nfullTerminal:0\nservicePluginPendingCount:0\n")
    } catch (_: Exception) {
        false
    }
}

public func gatewayWriteServeCompletionMarker(identity: GatewayServeIdentity, result: GatewayStopResult,
    httpStatus!: String = "not_applicable", canvasStatus!: String = "not_applicable",
    gatewayServerStatus!: String = "not_applicable", shutdownPhase!: String = "complete",
    shutdownPendingCount!: Int64 = 0, cronStatus!: String = "not_applicable", memoryStatus!: String = "not_applicable"): Bool {
    let surfacesOk = (httpStatus == "stopped" || httpStatus == "already_stopped" || httpStatus == "not_applicable") &&
        (canvasStatus == "stopped" || canvasStatus == "already_stopped" || canvasStatus == "not_applicable") &&
        (gatewayServerStatus == "stopped" || gatewayServerStatus == "already_stopped" || gatewayServerStatus == "not_applicable")
    let normalized = if (result.ok && result.servicePluginPendingCount == 0 && result.channelPendingCount == 0 &&
        shutdownPendingCount == 0 && (cronStatus == "stopped" || cronStatus == "not_applicable") &&
        (memoryStatus == "stopped" || memoryStatus == "already_stopped" || memoryStatus == "not_applicable") && surfacesOk) { "graceful" } else { "cleanup_pending" }
    let payload = gatewayWriteServeLockPayload(identity) +
        "status:${normalized}\n" +
        "fullTerminal:${if (normalized == "graceful") { 1 } else { 0 }}\n" +
        "inboundStatus:${result.inboundStatus}\n" +
        "compatStatus:${result.compatStatus}\n" +
        "sidecarStatus:${result.sidecarStatus}\n" +
        "servicePluginIngressStatus:${result.servicePluginIngressStatus}\n" +
        "servicePluginDispatchStatus:${result.servicePluginDispatchStatus}\n" +
        "servicePluginOwnerStatus:${result.servicePluginOwnerStatus}\n" +
        "servicePluginLeaseStatus:${result.servicePluginLeaseStatus}\n" +
        "servicePluginPortStatus:${result.servicePluginPortStatus}\n" +
        "servicePluginPendingCount:${result.servicePluginPendingCount}\n" +
        "channelsStatus:${result.channelsStatus}\n" +
        "channelPendingCount:${result.channelPendingCount}\n" +
        "shutdownPhase:${shutdownPhase}\n" +
        "shutdownPendingCount:${max(0, shutdownPendingCount)}\n" +
        "cronStatus:${cronStatus}\n" +
        "memoryStatus:${memoryStatus}\n" +
        "brokerStatus:${result.brokerStatus}\n" +
        "recoveryEvidenceVersion:1\n" +
        "brokerExternalTerminal:${if (result.brokerExternalTerminal) { 1 } else { 0 }}\n" +
        "brokerTerminalBasis:${result.brokerTerminalBasis}\n" +
        "httpStatus:${httpStatus}\n" +
        "canvasStatus:${canvasStatus}\n" +
        "gatewayServerStatus:${gatewayServerStatus}\n"
    gatewayAtomicWrite(gatewayServeCompletionPath(), payload)
}

public func gatewayServePortReleasedUntil(port: Int64, deadline: MonoTime): GatewaySurfaceStopResult {
    if (port <= 0) { return GatewaySurfaceStopResult(true, "not_applicable") }
    let localDeadline = MonoTime.now() + Duration.second * 2
    let effectiveDeadline = if (deadline < localDeadline) { deadline } else { localDeadline }
    while (MonoTime.now() < effectiveDeadline) {
        let remaining = (effectiveDeadline - MonoTime.now()).toMilliseconds()
        let probeBudget = min(Int64(500), max(Int64(1), remaining))
        let testProbe = synchronized(gatewayServePortProbeLock) { gatewayServePortProbeForTest }
        let result = try {
            match (testProbe) {
                case Some(probe) => probe(port, probeBudget)
                case None => ShellUtils.execute(
                    ["lsof", "-nP", "-iTCP:${port}", "-sTCP:LISTEN", "-t"],
                    withWrap: false,
                    timeout: Some(Duration.millisecond * probeBudget)
                )
            }
        } catch (_: ShellTimeoutException) {
            return GatewaySurfaceStopResult(false, "cleanup_pending", portStatus: "port_probe_timeout")
        } catch (_: Exception) {
            return GatewaySurfaceStopResult(false, "cleanup_pending", portStatus: "port_probe_failed")
        }
        let (exitCode, stdout, stderr) = result
        if (exitCode == 1) {
            if (stdout.trimAscii().isEmpty() && stderr.trimAscii().isEmpty()) {
                return GatewaySurfaceStopResult(true, "stopped", portStatus: "released")
            }
            return GatewaySurfaceStopResult(false, "cleanup_pending", portStatus: "port_probe_failed")
        }
        if (exitCode != 0) {
            let status = if (exitCode == 124) { "port_probe_timeout" }
                else if (exitCode == SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE) { "invalid_response_encoding" }
                else { "port_probe_failed" }
            return GatewaySurfaceStopResult(false, "cleanup_pending", portStatus: status)
        }
        sleep(Duration.millisecond * min(20, max(1, remaining)))
    }
    GatewaySurfaceStopResult(false, "cleanup_pending", portStatus: "port_release_timeout")
}

/**
 * 锁文件存在且对应进程仍在运行（或旧版锁未过期）时返回 true。
 * 若锁内 PID 已退出，会删除陈旧锁文件并返回 false。
 */
public func gatewayAnotherServeInstanceSeemsRunning(): Bool {
    let listeners = gatewayFindVerifiedListenerPidsOnPortDetailed()
    if (listeners.pids.size > 0) {
        return true
    }
    if (!listeners.conclusive) {
        return true
    }
    let p = gatewayServeLockPath()
    if (!exists(p)) {
        return false
    }
    try {
        if (let Some(text) <- gatewayReadLockText(p)) {
            if (let Some(pid) <- gatewayParseLockPid(text)) {
                let probe = match (gatewayParseServeIdentity(text)) {
                    case Some(identity) =>
                        match (identity.processIdentity) {
                            case Some(instance) =>
                                let checked = probeProcessInstance(instance, MonoTime.now() + Duration.millisecond * 500)
                                GatewayServePidProbeResult(checked.conclusive, checked.alive, checked.status)
                            case None => GatewayServePidProbeResult(false, false, "identity_unsupported")
                        }
                    case None => gatewayServePidProbe(pid, 500)
                }
                if (!probe.conclusive || probe.alive) { return true }
                match (gatewayParseServeIdentity(text)) {
                    case Some(identity) => let _ = gatewayRemoveServeLockFile(expected: Some(identity))
                    case None => let _ = gatewayRemoveServeLockFile()
                }
                return false
            }
            let m = FileInfo(p).lastModificationTime
            if ((DateTime.now() - m) < LEGACY_LOCK_TTL) {
                return true
            }
            let _ = gatewayRemoveServeLockFile()
            return false
        }
        return true
    } catch (_e: Exception) {
        true
    }
}

/**
 * 刷新锁文件（保持当前进程 PID），避免长驻进程仅因 mtime 被误判。
 */
public func gatewayRefreshServeLockMtime(): Unit {
    // v4 liveness is process-instance-bound; rewriting the lock creates a stale-writer
    // race that can overwrite a replacement. Keep this compatibility hook read-only.
    let active = synchronized(gatewayServeIdentityLock) { gatewayActiveServeIdentity }
    match ((active, gatewayReadServeIdentity())) {
        case (Some(expected), Some(current)) => let _ = current.matches(expected)
        case _ => ()
    }
}

private func gatewayRemoveServeLockFile(expected!: Option<GatewayServeIdentity> = None<GatewayServeIdentity>): Bool {
    let p = gatewayServeLockPath()
    try {
        if (!exists(p)) { return true }
        match (expected) {
            case Some(identity) =>
                match (gatewayReadServeIdentity()) {
                    case Some(current) => if (!current.matches(identity)) { return false }
                    case None => return false
                }
            case None => ()
        }
        remove(p)
        true
    } catch (_e: Exception) {
        false
    }
}

/** 供 `runGatewayService` 在 `finally` 中调用（Ctrl+C 未必走 atExit）。 */
public func gatewayReleaseServeLockQuiet(): Unit {
    let active = synchronized(gatewayServeIdentityLock) { gatewayActiveServeIdentity }
    match (active) {
        case Some(identity) =>
            let _ = gatewayRemoveServeLockFile(expected: Some(identity))
            let _ = gatewayRemoveServeStopRequest(identity)
            synchronized(gatewayServeIdentityLock) {
                match (gatewayActiveServeIdentity) {
                    case Some(current) => if (current.matches(identity)) { gatewayActiveServeIdentity = None<GatewayServeIdentity> }
                    case None => ()
                }
            }
        case None => ()
    }
}

public func gatewayReleaseServeLockForIdentity(identity: GatewayServeIdentity): Bool {
    let removed = gatewayRemoveServeLockFile(expected: Some(identity))
    if (removed) {
        let _ = gatewayRemoveServeStopRequest(identity)
        synchronized(gatewayServeIdentityLock) {
            match (gatewayActiveServeIdentity) {
                case Some(active) => if (active.matches(identity)) { gatewayActiveServeIdentity = None<GatewayServeIdentity> }
                case None => ()
            }
        }
    }
    removed
}

public func gatewayReleaseLegacyServeLockQuiet(): Bool {
    if (gatewayReadServeIdentity().isSome()) { return false }
    gatewayRemoveServeLockFile()
}

/** 读取锁文件中的网关进程 PID（不删除锁、不校验进程是否存活）。 */
public func gatewayPeekServeLockPid(): Option<Int64> {
    let p = gatewayServeLockPath()
    if (!exists(p)) {
        return None
    }
    if (let Some(text) <- gatewayReadLockText(p)) {
        return gatewayParseLockPid(text)
    }
    None
}

/** 当前进程 PID（用于避免在 serve 进程内对自己执行 stop）。 */
public func gatewayCliOwnProcessId(): Int64 {
    gatewayCurrentProcessId()
}

/**
 * 尝试结束锁文件对应的网关进程：先温和终止，必要时强制。
 * 成功后删除锁文件；返回是否已不再存活。
 */
public func gatewayTerminateServeProcessWithPolicy(
    identity: GatewayServeIdentity,
    nowMs: () -> Int64,
    waitMs: (Int64) -> Unit,
    probePid: (Int64, Int64) -> GatewayServePidProbeResult,
    readIdentity: () -> Option<GatewayServeIdentity>,
    readCompletion: (GatewayServeIdentity) -> GatewayServeCompletionResult,
    requestStop: (GatewayServeIdentity) -> Bool,
    sendSignal: (GatewayServeIdentity, String, Int64) -> Bool,
    totalTimeoutMs!: Int64 = 1400,
    requestGraceMs!: Int64 = 900,
    termReserveMs!: Int64 = 300,
    killReserveMs!: Int64 = 200
): GatewayServeTerminationResult {
    let startedAt = nowMs()
    let deadline = startedAt + max(1, totalTimeoutMs)
    let killBudget = max(1, min(killReserveMs, totalTimeoutMs - 1))
    let termBudget = max(1, min(termReserveMs, totalTimeoutMs - killBudget))
    let requestDeadline = min(
        deadline - termBudget - killBudget,
        startedAt + max(1, requestGraceMs)
    )
    let termDeadline = deadline - killBudget
    match (readIdentity()) {
        case Some(current) => if (!current.matches(identity)) { return GatewayServeTerminationResult(false, "stale_identity") }
        case None => return GatewayServeTerminationResult(false, "stale_identity")
    }
    let initialProbe = probePid(identity.pid, max(1, min(100, deadline - nowMs())))
    if (!initialProbe.conclusive) { return GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: initialProbe.status) }
    if (!initialProbe.alive) {
        let completion = readCompletion(identity)
        return if (completion.found && completion.status == "graceful" && completion.fullTerminal) {
            GatewayServeTerminationResult(true, "graceful", pidStatus: initialProbe.status)
        } else {
            GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: initialProbe.status, shutdownPhase: completion.shutdownPhase)
        }
    }
    if (!requestStop(identity)) {
        return GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: "request_write_failed")
    }
    while (true) {
        let completion = readCompletion(identity)
        let remaining = max(1, min(100, deadline - nowMs()))
        let probe = probePid(identity.pid, remaining)
        if (completion.found && completion.status == "cleanup_pending") {
            return GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: probe.status, shutdownPhase: completion.shutdownPhase)
        }
        if (completion.found && completion.status == "graceful" && completion.fullTerminal && probe.conclusive && !probe.alive) {
            return GatewayServeTerminationResult(true, "graceful", pidStatus: probe.status)
        }
        if (probe.conclusive && !probe.alive) {
            return GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: probe.status, shutdownPhase: completion.shutdownPhase)
        }
        if (nowMs() >= requestDeadline) { break }
        waitMs(max(1, min(50, requestDeadline - nowMs())))
    }
    match (readIdentity()) {
        case Some(current) => if (!current.matches(identity)) {
            return GatewayServeTerminationResult(false, "stale_identity")
        }
        case None => return GatewayServeTerminationResult(false, "cleanup_pending")
    }
    let termSent = sendSignal(identity, "TERM", max(1, termDeadline - nowMs()))
    if (!termSent) { return GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: "signal_failed") }
    while (true) {
        let completion = readCompletion(identity)
        let remaining = max(1, min(100, deadline - nowMs()))
        let probe = probePid(identity.pid, remaining)
        if (completion.found && completion.status == "cleanup_pending") {
            return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, pidStatus: probe.status, shutdownPhase: completion.shutdownPhase)
        }
        if (completion.found && completion.status == "graceful" && completion.fullTerminal && probe.conclusive && !probe.alive) {
            return GatewayServeTerminationResult(true, "graceful", termSent: true, pidStatus: probe.status)
        }
        if (probe.conclusive && !probe.alive) {
            return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, pidStatus: probe.status, shutdownPhase: completion.shutdownPhase)
        }
        if (nowMs() >= termDeadline) { break }
        waitMs(max(1, min(50, termDeadline - nowMs())))
    }
    match (readIdentity()) {
        case Some(current) => if (!current.matches(identity)) {
            return GatewayServeTerminationResult(false, "stale_identity", termSent: true)
        }
        case None => return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true)
    }
    let beforeKill = probePid(identity.pid, max(1, min(100, deadline - nowMs())))
    if (!beforeKill.conclusive || !beforeKill.alive) {
        return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, pidStatus: beforeKill.status)
    }
    let killRemaining = deadline - nowMs()
    if (killRemaining <= 0) {
        return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, pidStatus: beforeKill.status)
    }
    let completionBeforeKill = readCompletion(identity)
    let fullTerminalBeforeKill = completionBeforeKill.found && completionBeforeKill.status == "graceful" && completionBeforeKill.fullTerminal
    let killSent = sendSignal(identity, "KILL", killRemaining)
    if (!killSent) { return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, pidStatus: "signal_failed") }
    while (nowMs() <= deadline) {
        match (readIdentity()) {
            case Some(current) => if (!current.matches(identity)) {
                return GatewayServeTerminationResult(false, "stale_identity", termSent: true, killSent: true)
            }
            case None => ()
        }
        let probe = probePid(identity.pid, max(1, min(100, deadline - nowMs())))
        if (probe.conclusive && !probe.alive) {
            return if (fullTerminalBeforeKill) {
                GatewayServeTerminationResult(true, "force_terminated", termSent: true, killSent: true, pidStatus: probe.status)
            } else {
                GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, killSent: true, pidStatus: probe.status)
            }
        }
        if (!probe.conclusive && nowMs() >= deadline) {
            return GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, killSent: true, pidStatus: probe.status)
        }
        if (nowMs() >= deadline) { break }
        waitMs(max(1, min(50, deadline - nowMs())))
    }
    GatewayServeTerminationResult(false, "cleanup_pending", termSent: true, killSent: true, pidStatus: "alive")
}

private func gatewayServeNowMonotonicMs(): Int64 {
    (MonoTime.now() - gatewayServeMonotonicOrigin).toMilliseconds()
}

private func gatewaySendServeSignal(identity: GatewayServeIdentity, signal: String, timeoutMs: Int64): Bool {
    match (identity.processIdentity) {
        case Some(instance) =>
            let deadline = MonoTime.now() + Duration.millisecond * max(1, timeoutMs)
            signalProcessInstance(
                instance,
                if (signal == "KILL") { processInstanceKillSignal() } else { processInstanceTermSignal() },
                deadline
            ).ok
        case None => false
    }
}

public func gatewayTryTerminateServeProcess(pid: Int64): GatewayServeTerminationResult {
    gatewayTryTerminateServeProcessUntil(
        pid,
        MonoTime.now() + Duration.millisecond * GATEWAY_SERVE_GRACEFUL_SHUTDOWN_TIMEOUT_MS
    )
}

public func gatewayTryTerminateServeProcessUntil(pid: Int64, deadline: MonoTime): GatewayServeTerminationResult {
    let identity = match (gatewayReadServeIdentity()) {
        case Some(value) => value
        case None => return GatewayServeTerminationResult(false, "stale_identity")
    }
    if (identity.pid != pid) { return GatewayServeTerminationResult(false, "stale_identity") }
    let remaining = (deadline - MonoTime.now()).toMilliseconds()
    if (remaining <= 0) { return GatewayServeTerminationResult(false, "cleanup_pending", pidStatus: "deadline_exceeded") }
    let result = gatewayTerminateServeProcessWithPolicy(
        identity,
        { => gatewayServeNowMonotonicMs() },
        { millis => sleep(Duration.millisecond * millis) },
        { _targetPid, timeoutMs =>
            match (identity.processIdentity) {
                case Some(instance) =>
                    let probe = probeProcessInstance(instance, MonoTime.now() + Duration.millisecond * max(1, timeoutMs))
                    GatewayServePidProbeResult(probe.conclusive, probe.alive, probe.status)
                case None => GatewayServePidProbeResult(false, false, "identity_unsupported")
            }
        },
        { => gatewayReadServeIdentity() },
        { expected => gatewayReadServeCompletion(expected) },
        { expected => gatewayWriteServeStopRequest(expected) },
        { expected, signal, timeoutMs => gatewaySendServeSignal(expected, signal, timeoutMs) },
        totalTimeoutMs: remaining,
        requestGraceMs: min(GATEWAY_SERVE_STOP_REQUEST_GRACE_MS, remaining),
        termReserveMs: min(GATEWAY_SERVE_TERM_RESERVE_MS, remaining),
        killReserveMs: min(GATEWAY_SERVE_FORCE_KILL_RESERVE_MS, remaining)
    )
    if (result.ok && result.status == "force_terminated") {
        let _ = gatewayRemoveServeLockFile(expected: Some(identity))
        let _ = gatewayRemoveServeStopRequest(identity)
    }
    result
}

/**
 * 在 `gateway serve` 进程内获取独占锁；失败表示已有实例在跑。
 * 成功时注册 `atExit` 清理锁文件（Ctrl+C 不一定触发 atExit，故 `runGatewayService` 另用 try/finally）。
 */
public func gatewayAcquireServeLockForRunningProcess(): Bool {
    let completionPath = gatewayServeCompletionPath()
    if (exists(completionPath)) {
        match (gatewayReadLockText(completionPath)) {
            case Some(text) =>
                let status = gatewayServePayloadField(text, "status")
                if (status != "cleanup_pending" && status != "graceful") {
                    return false
                }
            case None => return false
        }
    }
    let requestPath = gatewayServeStopRequestPath()
    if (exists(requestPath)) {
        let staleRequest = match (gatewayReadLockText(requestPath)) {
            case Some(text) =>
                match (gatewayParseServeStopRequestIdentity(text)) {
                    case Some(requested) =>
                        match (requested.processIdentity) {
                            case Some(instance) =>
                                let probe = probeProcessInstance(instance, MonoTime.now() + Duration.millisecond * 500)
                                probe.conclusive && !probe.alive && gatewayRemoveServeStopRequest(requested)
                            case None => false
                        }
                    case None => false
                }
            case None => false
        }
        if (!staleRequest) { return false }
    }
    if (gatewayAnotherServeInstanceSeemsRunning()) {
        return false
    }
    let p = gatewayServeLockPath()
    try {
        let pid = gatewayCurrentProcessId()
        let startedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let processIdentity = currentProcessInstanceIdentity()
        let identity = GatewayServeIdentity(pid, startedAtMs, "${pid}-${startedAtMs}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}", processIdentity: processIdentity)
        let published = publishExclusiveUtf8File(p, gatewayWriteServeLockPayload(identity))
        if (!published.ok) { return false }
        synchronized(gatewayServeIdentityLock) { gatewayActiveServeIdentity = Some(identity) }
        if (exists(completionPath)) {
            match (gatewayReadLockText(completionPath)) {
                case Some(text) =>
                    let status = gatewayServePayloadField(text, "status")
                    if (status == "cleanup_pending") {
                        if (!gatewayReconcileHistoricalServeCompletion().ok) {
                            gatewayReleaseServeLockQuiet()
                            return false
                        }
                    } else if (status != "graceful") {
                        gatewayReleaseServeLockQuiet()
                        return false
                    }
                case None =>
                    gatewayReleaseServeLockQuiet()
                    return false
            }
        }
        atExit({ =>
            let _ = gatewayRemoveServeLockFile(expected: Some(identity))
            let _ = gatewayRemoveServeStopRequest(identity)
        })
        return true
    } catch (_e: Exception) {
        false
    }
}
