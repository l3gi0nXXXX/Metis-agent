package metis.gateway.runtime

import metis.core.config.CliConfig
import metis.gateway.logging.{MetisLogEvent, metisCreateSubsystemLogger}
import metis.gateway.service_plugin.{ServicePluginHistoricalRecoveryResult, probeServicePluginHistoricalResources, revalidateServicePluginHistoricalEvidence}
import metis.process.{probeProcessInstance, publishExclusiveUtf8File}
import std.collection.{HashSet}
import std.convert.Parsable
import std.core.Duration
import std.fs.{Directory, File, FileInfo, OpenMode, Path, exists, remove}
import std.posix.chmod
import std.sync.Mutex
import std.time.{DateTime, MonoTime}
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

private let gatewayRecoveryCommitMutex = Mutex()
private let gatewayRecoveryLogger = metisCreateSubsystemLogger("gateway/recovery")

public class GatewayHistoricalCompletionParseResult {
    public let ok: Bool
    public let status: String
    public let original: String
    public let identity: ?GatewayServeIdentity
    public let completion: GatewayServeCompletionResult
    public init(ok: Bool, status: String, original!: String = "", identity!: ?GatewayServeIdentity = None,
        completion!: GatewayServeCompletionResult = GatewayServeCompletionResult(false)) {
        this.ok = ok
        this.status = status
        this.original = original
        this.identity = identity
        this.completion = completion
    }
}

public class GatewayHistoricalResourceState {
    public let terminal: Bool
    public let status: String
    public init(terminal: Bool, status: String) { this.terminal = terminal; this.status = status }
}

public class GatewayHistoricalRecoveryEvidence {
    public let parsed: GatewayHistoricalCompletionParseResult
    public let status: String
    public let parentStatus: String
    public let rawPortStatus: String
    public let brokerBasis: String
    public let durationMs: Int64
    public let host: ?ServicePluginHistoricalRecoveryResult
    public init(parsed: GatewayHistoricalCompletionParseResult, status: String,
        host!: ?ServicePluginHistoricalRecoveryResult = None, parentStatus!: String = "not_checked",
        rawPortStatus!: String = "not_checked", brokerBasis!: String = "unknown", durationMs!: Int64 = 0) {
        this.parsed = parsed
        this.status = status
        this.host = host
        this.parentStatus = parentStatus
        this.rawPortStatus = rawPortStatus
        this.brokerBasis = brokerBasis
        this.durationMs = durationMs
    }
}

public func gatewayParseHistoricalCompletionStrict(text: String): GatewayHistoricalCompletionParseResult {
    let fail = { status: String => GatewayHistoricalCompletionParseResult(false, status, original: text) }
    if (text.size > 65536) { return fail("evidence_limit_exceeded") }
    let lines = text.split("\n")
    if (lines.isEmpty() || lines[0] != "gateway-serve-active-v4") { return fail("identity_unsupported") }
    let keys = HashSet<String>()
    for (index in 1..lines.size) {
        let line = lines[index]
        if (line.isEmpty()) { continue }
        let parts = line.split(":")
        if (parts.size < 2 || parts[0].isEmpty()) { return fail("malformed") }
        let key = parts[0]
        if (key != key.trimAscii()) { return fail("malformed") }
        if (keys.contains(key)) { return fail("malformed") }
        keys.add(key)
    }
    for (key in ["pid", "startedAtMs", "nonce", "processIdentity", "status", "fullTerminal", "servicePluginPendingCount",
        "inboundStatus", "compatStatus", "sidecarStatus", "servicePluginIngressStatus", "servicePluginDispatchStatus",
        "servicePluginOwnerStatus", "servicePluginLeaseStatus", "servicePluginPortStatus", "channelsStatus",
        "brokerStatus", "httpStatus", "canvasStatus", "gatewayServerStatus"]) {
        if (!keys.contains(key)) { return fail("malformed") }
    }
    let known = ["pid", "startedAtMs", "nonce", "processIdentity", "gracefulShutdownTimeoutMs", "status", "fullTerminal",
        "inboundStatus", "compatStatus", "sidecarStatus", "servicePluginIngressStatus", "servicePluginDispatchStatus",
        "servicePluginOwnerStatus", "servicePluginLeaseStatus", "servicePluginPortStatus", "servicePluginPendingCount",
        "channelsStatus", "brokerStatus", "httpStatus", "canvasStatus", "gatewayServerStatus",
        "recoveryEvidenceVersion", "brokerExternalTerminal", "brokerTerminalBasis"]
    for (key in keys) { if (!known.contains(key)) { return fail("malformed") } }
    let fullTerminal = gatewayServePayloadField(text, "fullTerminal")
    if (fullTerminal != "0" && fullTerminal != "1") { return fail("malformed") }
    let nonce = gatewayServePayloadField(text, "nonce")
    if (nonce.size > 4096) { return fail("evidence_limit_exceeded") }
    if (text.contains("\u{0}") || text.contains("\r")) { return fail("malformed") }
    let identity = match (gatewayParseServeIdentity(text)) { case Some(value) => value case None => return fail("malformed") }
    let process = match (identity.processIdentity) { case Some(value) => value case None => return fail("identity_unsupported") }
    if (process.pid != identity.pid) { return fail("identity_mismatch") }
    let completion = gatewayParseServeCompletion(text, identity)
    if (!completion.found) { return fail(completion.status) }
    let version = gatewayServePayloadField(text, "recoveryEvidenceVersion")
    if (!version.isEmpty() && version != "1") { return fail("evidence_version_unsupported") }
    if (version == "1") {
        let terminal = gatewayServePayloadField(text, "brokerExternalTerminal")
        let basis = gatewayServePayloadField(text, "brokerTerminalBasis")
        if ((terminal != "0" && terminal != "1") ||
            !["closed_ack_exit_observed", "not_applicable", "unknown"].contains(basis) ||
            (terminal == "1" && basis == "unknown") || (terminal == "0" && basis != "unknown")) { return fail("malformed") }
    } else if (keys.contains("brokerExternalTerminal") || keys.contains("brokerTerminalBasis")) { return fail("malformed") }
    GatewayHistoricalCompletionParseResult(true, "ok", original: text, identity: Some(identity), completion: completion)
}

public func gatewayHistoricalBrokerResourceState(parsed: GatewayHistoricalCompletionParseResult): GatewayHistoricalResourceState {
    let status = parsed.completion.brokerStatus
    if (["stopped", "not_applicable"].contains(status)) { return GatewayHistoricalResourceState(true, "terminal") }
    // v4's nonzero result was produced only after the same-generation, zero-owner ACK and wait returned.
    // Explicit facts never turn an operation failure into success.
    if (status == "broker_close_exit_nonzero") {
        let version = gatewayServePayloadField(parsed.original, "recoveryEvidenceVersion")
        if (version.isEmpty() || (version == "1" &&
            gatewayServePayloadField(parsed.original, "brokerExternalTerminal") == "1" &&
            gatewayServePayloadField(parsed.original, "brokerTerminalBasis") == "closed_ack_exit_observed")) {
            return GatewayHistoricalResourceState(true, "terminal")
        }
    }
    GatewayHistoricalResourceState(false, "broker_evidence_unknown")
}

private func gatewayHistoricalSurfaceTerminal(completion: GatewayServeCompletionResult): Bool {
    ["stopped", "not_applicable"].contains(completion.inboundStatus) &&
        ["stopped", "not_applicable"].contains(completion.compatStatus) &&
        ["stopped", "already_stopped", "disabled", "not_applicable"].contains(completion.sidecarStatus) &&
        ["sent", "stopped", "not_applicable", "terminal"].contains(completion.servicePluginIngressStatus) &&
        ["cleanup_pending", "drained", "cancelled", "stopped", "not_applicable", "terminal"].contains(completion.servicePluginDispatchStatus) &&
        ["stopped", "already_stopped", "graceful_exited", "terminated", "force_terminated", "not_applicable", "terminal"].contains(completion.servicePluginOwnerStatus) &&
        ["stopped", "not_applicable"].contains(completion.channelsStatus) &&
        ["stopped", "already_stopped", "not_applicable"].contains(completion.httpStatus) &&
        ["stopped", "already_stopped", "not_applicable"].contains(completion.canvasStatus) &&
        ["stopped", "already_stopped", "not_applicable"].contains(completion.gatewayServerStatus)
}

private func gatewayHistoricalCompletionRead(): GatewayHistoricalCompletionParseResult {
    let path = gatewayServeCompletionPath()
    if (!exists(path)) { return GatewayHistoricalCompletionParseResult(false, "missing") }
    try {
        let info = FileInfo(path)
        if (FileInfo(CliConfig.dotDir).isSymbolicLink() || info.isSymbolicLink() || !info.isRegular()) { return GatewayHistoricalCompletionParseResult(false, "unsafe_path") }
        if (info.size > 65536) { return GatewayHistoricalCompletionParseResult(false, "evidence_limit_exceeded") }
        let bytes = Array<UInt8>(65537, repeat: 0)
        var used: Int64 = 0
        try (file = File(path, OpenMode.Read)) {
            while (used < bytes.size) {
                let count = file.read(bytes[used..])
                if (count == 0) { break }
                used += count
            }
        }
        if (used > 65536) { return GatewayHistoricalCompletionParseResult(false, "evidence_limit_exceeded") }
        let text = try { String.fromUtf8(bytes[..used]) } catch (_: Exception) { return GatewayHistoricalCompletionParseResult(false, "invalid_response_encoding") }
        gatewayParseHistoricalCompletionStrict(text)
    } catch (_: Exception) { GatewayHistoricalCompletionParseResult(false, "read_failed") }
}

private func gatewayRecoveryLog(event: String, evidence: GatewayHistoricalRecoveryEvidence): Unit {
    try {
        let meta = JsonObject()
        meta.put("phase", JsonString("historical_recovery"))
        meta.put("historicalStatus", JsonString(evidence.parsed.completion.status))
        meta.put("resourceStatus", JsonString(if (evidence.status == "recoverable") { "terminal" } else if (["identity_alive", "pid_alive", "lease_active", "port_active"].contains(evidence.status)) { "active" } else { "unknown" }))
        meta.put("reason", JsonString(evidence.status))
        meta.put("durationMs", JsonInt(evidence.durationMs))
        meta.put("count", JsonInt(match (evidence.host) { case Some(value) => value.matchedCount case None => 0 }))
        match (evidence.parsed.identity) {
            case Some(value) =>
                meta.put("oldPid", JsonInt(value.pid))
                meta.put("identityHash", JsonString(value.processIdentity.getOrThrow().serialize().hashCode().toString()))
            case None => ()
        }
        gatewayRecoveryLogger.infoFileOnly(event, "historical gateway recovery checked", meta: meta)
    } catch (_: Exception) { () }
}

public func gatewayCollectHistoricalRecoveryEvidence(deadline: MonoTime): GatewayHistoricalRecoveryEvidence {
    let started = MonoTime.now()
    let parsed = gatewayHistoricalCompletionRead()
    var parentStatus = "not_checked"
    var rawPortStatus = "not_checked"
    let brokerBasis = if (gatewayServePayloadField(parsed.original, "recoveryEvidenceVersion").isEmpty()) {
        "legacy_v4_${parsed.completion.brokerStatus}"
    } else { gatewayServePayloadField(parsed.original, "brokerTerminalBasis") }
    let fail = { status: String, parent: String, rawPort: String => GatewayHistoricalRecoveryEvidence(parsed, status, parentStatus: parent,
        rawPortStatus: rawPort, brokerBasis: brokerBasis, durationMs: (MonoTime.now() - started).toMilliseconds()) }
    if (!parsed.ok) { return fail(parsed.status, parentStatus, rawPortStatus) }
    let completion = parsed.completion
    if (completion.status != "cleanup_pending" || !gatewayHistoricalSurfaceTerminal(completion) ||
        !gatewayHistoricalBrokerResourceState(parsed).terminal) { return fail("resources_not_terminal", parentStatus, rawPortStatus) }
    let identity = parsed.identity.getOrThrow()
    let probe = probeProcessInstance(identity.processIdentity.getOrThrow(), deadline)
    parentStatus = probe.status
    if (!probe.conclusive) { return fail(probe.status, parentStatus, rawPortStatus) }
    if (probe.alive) { return fail("identity_alive", parentStatus, rawPortStatus) }
    let leaseTerminal = ["stopped", "not_applicable", "terminal"].contains(completion.servicePluginLeaseStatus) &&
        ["released", "not_applicable", "terminal"].contains(completion.servicePluginPortStatus)
    if (!leaseTerminal &&
        (!["stopped", "not_applicable", "terminal", "cleanup_pending"].contains(completion.servicePluginLeaseStatus) ||
        !["released", "not_applicable", "terminal", "cleanup_pending"].contains(completion.servicePluginPortStatus))) {
        return fail("resources_not_terminal", parentStatus, rawPortStatus)
    }
    if (leaseTerminal) {
        let port = gatewayServePortReleasedUntil(gatewayConfiguredServePort(), deadline)
        rawPortStatus = port.portStatus
        if (!port.ok) { return fail(port.portStatus, parentStatus, rawPortStatus) }
        return fail("recoverable", parentStatus, rawPortStatus)
    }
    let host = probeServicePluginHistoricalResources(identity.pid, identity.startedAtMs, deadline)
    if (host.terminal && host.conclusive) {
        let port = gatewayServePortReleasedUntil(gatewayConfiguredServePort(), deadline)
        rawPortStatus = port.portStatus
        if (!port.ok) {
            return GatewayHistoricalRecoveryEvidence(parsed, port.portStatus, host: Some(host), parentStatus: parentStatus,
                rawPortStatus: rawPortStatus, brokerBasis: brokerBasis, durationMs: (MonoTime.now() - started).toMilliseconds())
        }
    }
    // Keep the established wrapper status for absent evidence, with the precise reason retained in host.status.
    GatewayHistoricalRecoveryEvidence(parsed,
        if (host.terminal && host.conclusive) { "recoverable" } else if (host.status == "lease_evidence_missing") { "resources_not_terminal" } else { host.status }, host: Some(host), parentStatus: parentStatus, rawPortStatus: rawPortStatus,
        brokerBasis: brokerBasis, durationMs: (MonoTime.now() - started).toMilliseconds())
}

public func gatewayEvaluateHistoricalRecoveryEvidence(evidence: GatewayHistoricalRecoveryEvidence): GatewayServeCompletionReconcileResult {
    let ok = evidence.status == "recoverable"
    gatewayRecoveryLog(if (ok) { MetisLogEvent.gatewayRecoveryChecked } else { MetisLogEvent.gatewayRecoveryBlocked }, evidence)
    GatewayServeCompletionReconcileResult(ok, evidence.status)
}

public func gatewayArchiveHistoricalServeCompletion(evidence: GatewayHistoricalRecoveryEvidence): GatewayServeCompletionReconcileResult {
    if (evidence.status != "recoverable" || !evidence.parsed.ok) { return GatewayServeCompletionReconcileResult(false, evidence.status) }
    if (!gatewayOwnsCurrentServeLock()) { return GatewayServeCompletionReconcileResult(false, "lock_not_owned") }
    try {
        if (FileInfo(CliConfig.dotDir).isSymbolicLink()) { return GatewayServeCompletionReconcileResult(false, "archive_write_failed") }
        let dir = CliConfig.dotDir.join("gateway-serve.recovery-history")
        if (exists(dir) && (FileInfo(dir).isSymbolicLink() || !FileInfo(dir).isDirectory())) { return GatewayServeCompletionReconcileResult(false, "archive_write_failed") }
        if (!exists(dir)) { Directory.create(dir, recursive: true) }
        chmod(dir.toString(), UInt32(0o700))
        let identity = evidence.parsed.identity.getOrThrow()
        let sequence = DateTime.now().toUnixTimeStamp().toNanoseconds()
        let base = dir.join("${identity.pid}-${identity.startedAtMs}-${sequence}")
        let original = Path(base.toString() + ".completion")
        let saved = publishExclusiveUtf8File(original, evidence.parsed.original)
        if (!saved.ok) { return GatewayServeCompletionReconcileResult(false, "archive_write_failed") }
        chmod(original.toString(), UInt32(0o600))
        let summary = Path(base.toString() + ".evidence")
        var detail = "recovery-evidence-v1\noldPid:${identity.pid}\n" +
            "identityHash:${identity.processIdentity.getOrThrow().serialize().hashCode()}\n" +
            "historicalStatus:${evidence.parsed.completion.status}\nresourceStatus:terminal\nreason:recoverable\n" +
            "parentProbe:${evidence.parentStatus}\nrawPortProbe:${evidence.rawPortStatus}\nbrokerBasis:${evidence.brokerBasis}\n"
        match (evidence.host) {
            case Some(host) =>
                detail += "leaseCount:${host.matchedCount}\n"
                for (lease in host.evidence) {
                    // Numeric identity and fixed terminal state only: no paths, argv, or business payload.
                    detail += "lease:${lease.pid}:${lease.parentPid}:${lease.startedAtMs}:${lease.port}:stopped\n"
                }
            case None => detail += "leaseCount:0\n"
        }
        if (detail.size > 1048576) { return GatewayServeCompletionReconcileResult(false, "evidence_limit_exceeded") }
        let written = publishExclusiveUtf8File(summary, detail)
        if (!written.ok) { return GatewayServeCompletionReconcileResult(false, "archive_write_failed") }
        chmod(summary.toString(), UInt32(0o600))
        GatewayServeCompletionReconcileResult(true, "archived")
    } catch (_: Exception) { GatewayServeCompletionReconcileResult(false, "archive_write_failed") }
}

public func gatewayCommitHistoricalRecovery(evidence: GatewayHistoricalRecoveryEvidence, deadline: MonoTime,
    afterArchive!: () -> Unit = { => }): GatewayServeCompletionReconcileResult {
    synchronized(gatewayRecoveryCommitMutex) {
        if (!gatewayOwnsCurrentServeLock()) { return GatewayServeCompletionReconcileResult(false, "lock_not_owned") }
        let current = gatewayCollectHistoricalRecoveryEvidence(deadline)
        let checked = gatewayEvaluateHistoricalRecoveryEvidence(current)
        if (!checked.ok) { return checked }
        if (current.parsed.original != evidence.parsed.original) { return GatewayServeCompletionReconcileResult(false, "identity_changed") }
        match (evidence.host) {
            case Some(host) =>
                let revalidated = revalidateServicePluginHistoricalEvidence(host, deadline)
                if (!revalidated.terminal) { return GatewayServeCompletionReconcileResult(false, revalidated.status) }
            case None => ()
        }
        let archived = gatewayArchiveHistoricalServeCompletion(current)
        if (!archived.ok) { return archived }
        try { afterArchive() } catch (_: Exception) { return GatewayServeCompletionReconcileResult(false, "recovery_revalidation_failed") }
        // Archive first, then reobserve. A concurrent replacement is never removed using a preview result.
        let finalEvidence = gatewayCollectHistoricalRecoveryEvidence(deadline)
        if (!gatewayOwnsCurrentServeLock()) { return GatewayServeCompletionReconcileResult(false, "lock_not_owned") }
        if (!finalEvidence.parsed.ok) { return gatewayEvaluateHistoricalRecoveryEvidence(finalEvidence) }
        if (finalEvidence.parsed.original != current.parsed.original) { return GatewayServeCompletionReconcileResult(false, "identity_changed") }
        let finalChecked = gatewayEvaluateHistoricalRecoveryEvidence(finalEvidence)
        if (!finalChecked.ok) { return finalChecked }
        match (current.host) {
            case Some(host) =>
                let revalidated = revalidateServicePluginHistoricalEvidence(host, deadline)
                if (!revalidated.terminal) { return GatewayServeCompletionReconcileResult(false, revalidated.status) }
            case None => ()
        }
        try {
            if (gatewayReadLockText(gatewayServeCompletionPath()).getOrDefault({ => "" }) != current.parsed.original) {
                return GatewayServeCompletionReconcileResult(false, "identity_changed")
            }
            if (!gatewayOwnsCurrentServeLock()) { return GatewayServeCompletionReconcileResult(false, "lock_not_owned") }
            remove(gatewayServeCompletionPath())
            gatewayRecoveryLog(MetisLogEvent.gatewayRecoveryReconciled, finalEvidence)
            GatewayServeCompletionReconcileResult(true, "reconciled")
        } catch (_: Exception) { GatewayServeCompletionReconcileResult(false, "remove_failed") }
    }
}
