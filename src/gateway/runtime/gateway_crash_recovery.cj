package metis.gateway.runtime

import metis.core.config.CliConfig
import metis.gateway.logging.{MetisLogEvent, metisCreateSubsystemLogger}
import metis.gateway.service_plugin.{probeServicePluginHistoricalResources}
import metis.process.{ProcessFileClaim, acquireProcessFileClaim, managedRecoveryInitialize, managedRecoveryProbeRecords,
    managedRecoveryReadText, managedRecoveryDirectorySafe, managedRecoverySafeKey, probeProcessInstance, publishExclusiveUtf8File,
    syncFileDirectory, shutdownManagedStdioBroker}
import std.collection.{ArrayList, HashSet}
import std.convert.Parsable
import std.fs.{Directory, FileInfo, Path, exists, remove}
import std.posix.chmod
import std.sync.Mutex
import std.time.{DateTime, MonoTime}
import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

private let gatewayCrashRecoveryLogger = metisCreateSubsystemLogger("gateway/recovery")

private func gatewayCrashRecoveryLog(event: String, status: String, evidence: GatewayCrashRecoveryEvidence, startedAt: MonoTime): Unit {
    try {
        let known = ["recoverable", "recovered_after_crash", "legacy_inventory_missing", "lock_invalid", "completion_present",
            "resource_alive", "resource_group_active_or_unknown", "resource_identity_unknown", "resource_intent_incomplete",
            "inventory_invalid", "inventory_identity_mismatch", "inventory_read_failed", "checkpoint_invalid", "checkpoint_owner_missing",
            "checkpoint_resource_not_terminal", "resource_intent_missing", "evidence_limit_exceeded", "unsafe_path",
            "identity_alive", "identity_changed", "pid_alive", "port_active", "lease_active", "deadline_exceeded", "probe_failed",
            "permission_denied", "claim_busy", "claim_open_failed", "archive_write_failed", "recovery_commit_failed",
            "stop_request_invalid", "stop_request_identity_mismatch", "stop_request_retirement_failed",
            "completion_invalid", "completion_identity_mismatch", "completion_retirement_failed"]
        let reason = if (known.contains(status)) { status } else { "resources_unknown" }
        let meta = JsonObject()
        meta.put("phase", JsonString("crash_recovery"))
        meta.put("evidenceKind", JsonString("owned_process_inventory_v1"))
        meta.put("status", JsonString(reason))
        meta.put("durationMs", JsonInt(max(0, (MonoTime.now() - startedAt).toMilliseconds())))
        let completionInvalid = reason == "completion_invalid" || reason == "completion_identity_mismatch"
        meta.put("kind", JsonString(if (completionInvalid || reason == "completion_present") { "unknown" } else { evidence.kind }))
        meta.put("historicalStatus", JsonString(if (completionInvalid) { "unknown" } else if (reason == "completion_present") { "graceful" } else if (evidence.originalCompletion.isSome()) { "cleanup_pending" } else { "missing" }))
        meta.put("resourceStatus", JsonString(if (["recoverable", "recovered_after_crash"].contains(reason)) { "terminal" } else { "unknown" }))
        meta.put("reason", JsonString(reason))
        match (evidence.identity) {
            case Some(value) =>
                meta.put("oldPid", JsonInt(value.pid))
                match (value.processIdentity) {
                    case Some(identity) => meta.put("identityHash", JsonString(identity.serialize().hashCode().toString()))
                    case None => ()
                }
            case None => ()
        }
        gatewayCrashRecoveryLogger.infoFileOnly(event, "gateway crash recovery evidence checked", meta: meta)
    } catch (_: Exception) { () }
}

private func gatewayCrashRecoveryResult(ok: Bool, status: String, evidence: GatewayCrashRecoveryEvidence, startedAt: MonoTime): GatewayServeCompletionReconcileResult {
    gatewayCrashRecoveryLog(if (ok) { MetisLogEvent.gatewayRecoveryReconciled } else { MetisLogEvent.gatewayRecoveryBlocked }, status, evidence, startedAt)
    GatewayServeCompletionReconcileResult(ok, status)
}

private let gatewayServeClaimState = Mutex()
private var gatewayServeClaimThread: Int64 = -1
private var gatewayServeClaimPath: String = ""

@When[os == "macOS"]
public func gatewayCrashRecoveryPlatformSupported(): Bool { true }
@When[os != "macOS"]
public func gatewayCrashRecoveryPlatformSupported(): Bool { false }

public class GatewayServeMutationClaim {
    public let ok: Bool
    public let status: String
    private let handle: ?ProcessFileClaim
    public init(ok: Bool, status: String, handle!: ?ProcessFileClaim = None) {
        this.ok = ok; this.status = status; this.handle = handle
    }
    public func release(): Unit {
        match (this.handle) {
            case Some(value) =>
                synchronized(gatewayServeClaimState) { gatewayServeClaimThread = -1; gatewayServeClaimPath = "" }
                value.release()
            case None => ()
        }
    }
}

/** Only mutation scopes reenter, on the same thread and same home; never unlink the claim. */
public func gatewayAcquireServeMutationClaim(deadline: MonoTime): GatewayServeMutationClaim {
    if (!gatewayCrashRecoveryPlatformSupported()) { return GatewayServeMutationClaim(true, "legacy_platform") }
    let path = CliConfig.dotDir.join("gateway-serve.mutation-claim")
    let nested = synchronized(gatewayServeClaimState) {
        gatewayServeClaimThread == Thread.currentThread.id && gatewayServeClaimPath == path.toString()
    }
    if (nested) { return GatewayServeMutationClaim(true, "claimed") }
    let handle = acquireProcessFileClaim(path, deadline)
    if (!handle.ok) { return GatewayServeMutationClaim(false, handle.status) }
    synchronized(gatewayServeClaimState) {
        gatewayServeClaimThread = Thread.currentThread.id; gatewayServeClaimPath = path.toString()
    }
    GatewayServeMutationClaim(true, "claimed", handle: Some(handle))
}

public func gatewayRecoveryInventoryPath(identity: GatewayServeIdentity): Path {
    CliConfig.dotDir.join("gateway-resource-inventory").join("${identity.pid}-${identity.startedAtMs}")
}

public func gatewayInitializeRecoveryInventory(identity: GatewayServeIdentity): Bool {
    if (!gatewayCrashRecoveryPlatformSupported()) { return true }
    // Discovery may have created a pre-serve broker. Its owners must finish before changing ownership context.
    if (!shutdownManagedStdioBroker(timeoutMs: 2000).ok) { return false }
    match (identity.processIdentity) {
        case Some(value) => managedRecoveryInitialize(gatewayRecoveryInventoryPath(identity), value.serialize(), identity.nonce)
        case None => false
    }
}

public func gatewayPublishServeReady(identity: GatewayServeIdentity): Bool {
    if (gatewayCrashRecoveryPlatformSupported() && identity.processIdentity.isNone()) { return false }
    let text = gatewayServeReadyPayload(identity)
    let path = gatewayRecoveryInventoryPath(identity).join("ready")
    if (!managedRecoveryDirectorySafe(path.parent)) { return false }
    try { if (!exists(path.parent)) { Directory.create(path.parent, recursive: true) } } catch (_: Exception) { return false }
    let result = publishExclusiveUtf8File(path, text)
    result.ok || managedRecoveryReadText(path).getOrDefault({ => "" }) == text
}

private func gatewayServeReadyPayload(identity: GatewayServeIdentity): String {
    if (gatewayCrashRecoveryPlatformSupported()) {
        "managed-recovery-ready-v1\nparent:${identity.processIdentity.getOrThrow().serialize()}\nbinding:${identity.nonce}\n"
    } else {
        "gateway-serve-ready-v1\npid:${identity.pid}\nbinding:${identity.nonce}\n"
    }
}

/** Ready is bound to the new OS instance and nonce, not a successful shell launcher exit. */
public func gatewayAwaitRestartReady(deadline: MonoTime, previousNonce!: String = ""): Bool {
    while (MonoTime.now() < deadline) {
        match (gatewayReadServeIdentity()) {
            case Some(identity) =>
                if (identity.nonce != previousNonce && (!gatewayCrashRecoveryPlatformSupported() || identity.processIdentity.isSome())) {
                    let alive = if (gatewayCrashRecoveryPlatformSupported()) {
                        let probe = probeProcessInstance(identity.processIdentity.getOrThrow(), deadline)
                        probe.conclusive && probe.alive
                    } else { gatewayServePidIsAlive(identity.pid) }
                    if (alive && managedRecoveryReadText(gatewayRecoveryInventoryPath(identity).join("ready")).getOrDefault({ => "" }) == gatewayServeReadyPayload(identity)) {
                        return true
                    }
                }
            case None => ()
        }
        sleep(Duration.millisecond * 25)
    }
    false
}

public class GatewayCrashRecoveryEvidence {
    public let status: String
    public let originalLock: String
    public let inventory: String
    public let originalStopRequest: String
    public let originalCompletion: ?String
    public let kind: String
    public let observationStarted: MonoTime
    public let identity: ?GatewayServeIdentity
    public init(status: String, originalLock!: String = "", inventory!: String = "", identity!: ?GatewayServeIdentity = None,
        originalStopRequest!: String = "", originalCompletion!: ?String = None, observationStarted!: MonoTime = MonoTime.now()) {
        this.status = status; this.originalLock = originalLock; this.inventory = inventory; this.identity = identity
        this.originalStopRequest = originalStopRequest
        this.originalCompletion = originalCompletion
        this.kind = if (originalCompletion.isSome()) { "interrupted_shutdown" } else { "missing_completion" }
        this.observationStarted = observationStarted
    }
}

func gatewayCrashStopRequestStrict(text: String, expected: GatewayServeIdentity): Bool {
    let lockLines = ArrayList<String>()
    var requestedAt = ""
    var seenRequestedAt = false
    for (line in text.split("\n")) {
        if (line.startsWith("requestedAtMs:")) {
            if (seenRequestedAt) { return false }
            seenRequestedAt = true
            requestedAt = line.removePrefix("requestedAtMs:")
        } else { lockLines.add(line) }
    }
    let identity = gatewayParseCrashLockStrict(String.join(lockLines.toArray(), delimiter: "\n"))
    if (identity.isNone() || !identity.getOrThrow().matches(expected)) { return false }
    try { let time = Int64.parse(requestedAt); time > 0 && time.toString() == requestedAt } catch (_: Exception) { false }
}

public func gatewayParseCrashLockStrict(text: String): ?GatewayServeIdentity {
    if (text.size > 8192 || text.contains("\r") || text.contains("\u{0}")) { return None }
    let lines = text.split("\n")
    if (lines.isEmpty() || lines[0] != "gateway-serve-active-v4") { return None }
    let keys = HashSet<String>()
    for (index in 1..lines.size) {
        if (lines[index].isEmpty()) { continue }
        let parts = lines[index].split(":")
        if (parts.size < 2 || !["pid", "startedAtMs", "nonce", "processIdentity", "gracefulShutdownTimeoutMs"].contains(parts[0]) ||
            keys.contains(parts[0])) { return None }
        keys.add(parts[0])
    }
    if (keys.size != 5) { return None }
    let identity = match (gatewayParseServeIdentity(text)) { case Some(value) => value case None => return None }
    if (identity.nonce.isEmpty() || identity.nonce.size > 4096 || identity.processIdentity.isNone() || identity.processIdentity.getOrThrow().pid != identity.pid) { return None }
    Some(identity)
}

private func gatewayCrashPendingCompletionStatus(text: String, expected: GatewayServeIdentity): String {
    if (text.size > 8192 || text.contains("\r") || text.contains("\u{0}")) { return "completion_invalid" }
    let lines = text.split("\n")
    if (lines.isEmpty() || lines[0] != "gateway-serve-active-v4") { return "completion_invalid" }
    let identityKeys = ["pid", "startedAtMs", "nonce", "processIdentity", "gracefulShutdownTimeoutMs"]
    let allowed = ["status", "fullTerminal", "inboundStatus", "compatStatus", "sidecarStatus", "servicePluginIngressStatus",
        "servicePluginDispatchStatus", "servicePluginOwnerStatus", "servicePluginLeaseStatus", "servicePluginPortStatus",
        "servicePluginPendingCount", "channelsStatus", "channelPendingCount", "shutdownPhase", "shutdownPendingCount",
        "cronStatus", "memoryStatus", "brokerStatus", "recoveryEvidenceVersion", "brokerExternalTerminal", "brokerTerminalBasis",
        "httpStatus", "canvasStatus", "gatewayServerStatus"]
    let keys = HashSet<String>()
    let identityLines = ArrayList<String>([lines[0]])
    for (index in 1..lines.size) {
        let line = lines[index]
        if (line.isEmpty()) { continue }
        let fields = line.split(":")
        if (fields.size < 2 || keys.contains(fields[0]) || (!identityKeys.contains(fields[0]) && !allowed.contains(fields[0]))) {
            return "completion_invalid"
        }
        keys.add(fields[0])
        if (identityKeys.contains(fields[0])) { identityLines.add(line) }
    }
    let bound = gatewayParseCrashLockStrict(String.join(identityLines.toArray(), delimiter: "\n"))
    if (bound.isNone()) { return "completion_invalid" }
    if (!bound.getOrThrow().matches(expected)) { return "completion_identity_mismatch" }
    let completion = gatewayParseServeCompletion(text, expected)
    if (!completion.found) { return "completion_invalid" }
    if (completion.status != "cleanup_pending") { return "completion_present" }
    if (gatewayServePayloadField(text, "fullTerminal") != "0") { return "completion_invalid" }
    for (key in ["servicePluginPendingCount", "channelPendingCount", "shutdownPendingCount"]) {
        if (!keys.contains(key)) { if (key == "servicePluginPendingCount") { return "completion_invalid" }; continue }
        let value = gatewayServePayloadField(text, key)
        let valid = try { let count = Int64.parse(value); count >= 0 && count.toString() == value } catch (_: Exception) { false }
        if (!valid) { return "completion_invalid" }
    }
    if (keys.contains("brokerExternalTerminal") && !["0", "1"].contains(gatewayServePayloadField(text, "brokerExternalTerminal"))) {
        return "completion_invalid"
    }
    if (keys.contains("recoveryEvidenceVersion") && gatewayServePayloadField(text, "recoveryEvidenceVersion") != "1") {
        return "completion_invalid"
    }
    "recoverable"
}

private func gatewayCrashCompletionMatches(original: ?String): Bool {
    match (original) {
        case Some(text) => exists(gatewayServeCompletionPath()) && managedRecoveryReadText(gatewayServeCompletionPath()) == Some(text)
        case None => !exists(gatewayServeCompletionPath())
    }
}

public func gatewayCollectCrashRecoveryEvidence(deadline: MonoTime): GatewayCrashRecoveryEvidence {
    let startedAt = MonoTime.now()
    if (!gatewayCrashRecoveryPlatformSupported()) { return GatewayCrashRecoveryEvidence("resources_unknown", observationStarted: startedAt) }
    let lock = managedRecoveryReadText(gatewayServeLockPath())
    let original = match (lock) { case Some(value) => value case None => return GatewayCrashRecoveryEvidence("lock_invalid", observationStarted: startedAt) }
    let identity = match (gatewayParseCrashLockStrict(original)) { case Some(value) => value case None => return GatewayCrashRecoveryEvidence("lock_invalid", observationStarted: startedAt) }
    let completionExists = exists(gatewayServeCompletionPath())
    let completion = if (completionExists) { managedRecoveryReadText(gatewayServeCompletionPath()) } else { None<String> }
    let fail = { status: String => GatewayCrashRecoveryEvidence(status, originalLock: original, identity: Some(identity),
        originalCompletion: completion, observationStarted: startedAt) }
    if (completionExists) {
        let text = match (completion) { case Some(value) => value case None => return fail("completion_invalid") }
        let status = gatewayCrashPendingCompletionStatus(text, identity)
        if (status != "recoverable") { return fail(status) }
    }
    let requestPath = CliConfig.dotDir.join("gateway-serve.stop-request")
    var originalRequest = ""
    if (exists(requestPath)) {
        originalRequest = match (managedRecoveryReadText(requestPath)) { case Some(value) => value case None => return fail("stop_request_invalid") }
        if (!gatewayCrashStopRequestStrict(originalRequest, identity)) { return fail("stop_request_identity_mismatch") }
    }
    let parent = probeProcessInstance(identity.processIdentity.getOrThrow(), deadline)
    if (!parent.conclusive) { return fail(parent.status) }
    if (parent.alive) { return fail("identity_alive") }
    let resources = managedRecoveryProbeRecords(gatewayRecoveryInventoryPath(identity), identity.processIdentity.getOrThrow().serialize(), identity.nonce, deadline)
    if (!resources.ok || !resources.terminal) { return fail(resources.status) }
    let leases = CliConfig.dotDir.join("service-plugin").join("runtime")
    if (exists(leases)) {
        let host = probeServicePluginHistoricalResources(identity.pid, identity.startedAtMs, deadline, allowStaleActiveLease: true)
        if (!host.terminal && host.status != "lease_evidence_missing") { return fail(host.status) }
    }
    let port = gatewayServePortReleasedUntil(gatewayConfiguredServePort(), deadline)
    if (!port.ok) { return fail(port.portStatus) }
    GatewayCrashRecoveryEvidence("recoverable", originalLock: original, inventory: resources.original, identity: Some(identity),
        originalStopRequest: originalRequest, originalCompletion: completion, observationStarted: startedAt)
}

/** Crash facts are archived as crash facts; no synthetic graceful completion is ever published. */
public func gatewayCommitCrashRecovery(evidence: GatewayCrashRecoveryEvidence, deadline: MonoTime,
    afterArchive!: () -> Unit = { => }): GatewayServeCompletionReconcileResult {
    let startedAt = MonoTime.now()
    if (evidence.status != "recoverable") { return gatewayCrashRecoveryResult(false, evidence.status, evidence, startedAt) }
    let claim = gatewayAcquireServeMutationClaim(deadline)
    if (!claim.ok) { return gatewayCrashRecoveryResult(false, claim.status, evidence, startedAt) }
    try {
        let current = gatewayCollectCrashRecoveryEvidence(deadline)
        if (current.status != "recoverable") { return gatewayCrashRecoveryResult(false, current.status, current, startedAt) }
        gatewayCrashRecoveryLog(MetisLogEvent.gatewayRecoveryChecked, current.status, current, current.observationStarted)
        if (current.originalLock != evidence.originalLock || current.inventory != evidence.inventory || current.originalStopRequest != evidence.originalStopRequest || current.originalCompletion != evidence.originalCompletion) {
            return gatewayCrashRecoveryResult(false, "identity_changed", current, startedAt)
        }
        let identity = current.identity.getOrThrow()
        let directory = CliConfig.dotDir.join("gateway-serve.recovery-history")
        if (exists(directory) && (FileInfo(directory).isSymbolicLink() || !FileInfo(directory).isDirectory())) {
            return gatewayCrashRecoveryResult(false, "archive_write_failed", current, startedAt)
        }
        if (!exists(directory)) { Directory.create(directory, recursive: true) }
        chmod(directory.toString(), UInt32(0o700))
        let base = "${identity.pid}-${identity.startedAtMs}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        let oldLock = directory.join("${base}.crash-lock")
        let facts = directory.join("${base}.crash-evidence")
        if (!publishExclusiveUtf8File(oldLock, current.originalLock).ok ||
            !publishExclusiveUtf8File(facts, "crash-recovery-v1\nstatus:resources_verified_before_retirement\nkind:${current.kind}\ncompletion:${if (current.originalCompletion.isSome()) { "cleanup_pending" } else { "missing" }}\n" + current.inventory).ok) {
            return gatewayCrashRecoveryResult(false, "archive_write_failed", current, startedAt)
        }
        if (!current.originalStopRequest.isEmpty() && !publishExclusiveUtf8File(directory.join("${base}.crash-stop-request"), current.originalStopRequest).ok) {
            return gatewayCrashRecoveryResult(false, "archive_write_failed", current, startedAt)
        }
        if (let Some(completion) <- current.originalCompletion) {
            if (!publishExclusiveUtf8File(directory.join("${base}.interrupted-completion"), completion).ok) {
                return gatewayCrashRecoveryResult(false, "archive_write_failed", current, startedAt)
            }
        }
        chmod(oldLock.toString(), UInt32(0o600)); chmod(facts.toString(), UInt32(0o600))
        if (!syncFileDirectory(directory)) { return gatewayCrashRecoveryResult(false, "archive_write_failed", current, startedAt) }
        afterArchive()
        let finalEvidence = gatewayCollectCrashRecoveryEvidence(deadline)
        if (finalEvidence.status != "recoverable" || finalEvidence.originalLock != current.originalLock || finalEvidence.inventory != current.inventory ||
            finalEvidence.originalStopRequest != current.originalStopRequest || finalEvidence.originalCompletion != current.originalCompletion) {
            return gatewayCrashRecoveryResult(false, if (finalEvidence.status != "recoverable") { finalEvidence.status } else { "identity_changed" }, finalEvidence, startedAt)
        }
        // All new-version publishers/removers hold this same OS claim. Do not retire a replacement.
        if (managedRecoveryReadText(gatewayServeLockPath()).getOrDefault({ => "" }) != current.originalLock) {
            return gatewayCrashRecoveryResult(false, "identity_changed", current, startedAt)
        }
        let requestPath = CliConfig.dotDir.join("gateway-serve.stop-request")
        if (!current.originalStopRequest.isEmpty()) {
            if (managedRecoveryReadText(requestPath).getOrDefault({ => "" }) != current.originalStopRequest) {
                return gatewayCrashRecoveryResult(false, "stop_request_identity_mismatch", current, startedAt)
            }
            try { remove(requestPath) } catch (_: Exception) { return gatewayCrashRecoveryResult(false, "stop_request_retirement_failed", current, startedAt) }
        } else if (exists(requestPath)) { return gatewayCrashRecoveryResult(false, "stop_request_identity_mismatch", current, startedAt) }
        if (!gatewayCrashCompletionMatches(current.originalCompletion)) {
            return gatewayCrashRecoveryResult(false, "identity_changed", current, startedAt)
        }
        if (current.originalCompletion.isSome()) {
            try { remove(gatewayServeCompletionPath()) } catch (_: Exception) {
                return gatewayCrashRecoveryResult(false, "completion_retirement_failed", current, startedAt)
            }
        }
        remove(gatewayServeLockPath())
        gatewayCrashRecoveryResult(true, "recovered_after_crash", current, startedAt)
    } catch (_: Exception) { gatewayCrashRecoveryResult(false, "recovery_commit_failed", evidence, startedAt) }
    finally { claim.release() }
}

public func gatewayReconcileCrashRecovery(deadline: MonoTime): GatewayServeCompletionReconcileResult {
    gatewayCommitCrashRecovery(gatewayCollectCrashRecoveryEvidence(deadline), deadline)
}
