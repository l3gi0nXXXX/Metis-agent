package metis.gateway.service_plugin

import metis.core.config.CliConfig
import std.collection.{ArrayList, HashSet}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists}
import std.time.MonoTime
import stdx.encoding.json.{JsonObject, JsonValue}

/** A read-only snapshot. Paths are local handles, never diagnostic output. */
public class ServicePluginHistoricalLeaseEvidence {
    let path: Path
    let original: String
    public let pluginId: String
    public let sessionId: String
    public let state: String
    public let pid: Int64
    public let parentPid: Int64
    public let startedAtMs: Int64
    public let port: Int64
    public init(path: Path, original: String, pluginId: String, sessionId: String, state: String,
        pid: Int64, parentPid: Int64, startedAtMs: Int64, port: Int64) {
        this.path = path
        this.original = original
        this.pluginId = pluginId
        this.sessionId = sessionId
        this.state = state
        this.pid = pid
        this.parentPid = parentPid
        this.startedAtMs = startedAtMs
        this.port = port
    }
}

public class ServicePluginHistoricalLeaseReadResult {
    public let status: String
    public let evidence: ?ServicePluginHistoricalLeaseEvidence
    public init(status: String, evidence!: ?ServicePluginHistoricalLeaseEvidence = None) {
        this.status = status
        this.evidence = evidence
    }
}

public class ServicePluginHistoricalRecoveryResult {
    public let conclusive: Bool
    public let terminal: Bool
    public let status: String
    public let matchedCount: Int64
    public let evidence: Array<ServicePluginHistoricalLeaseEvidence>
    public let parentPid: Int64
    public let parentStartedAtMs: Int64
    public init(conclusive: Bool, terminal: Bool, status: String,
        evidence!: Array<ServicePluginHistoricalLeaseEvidence> = [], parentPid!: Int64 = 0, parentStartedAtMs!: Int64 = 0) {
        this.conclusive = conclusive
        this.terminal = terminal
        this.status = status
        this.evidence = evidence
        this.matchedCount = evidence.size
        this.parentPid = parentPid
        this.parentStartedAtMs = parentStartedAtMs
    }
}

// JsonObject parsing alone may overwrite duplicate fields. Check decoded top-level keys first.
func servicePluginHistoricalUniqueJsonKeys(text: String): Bool {
    let keys = HashSet<String>()
    var depth: Int64 = 0
    var quoted = false
    var escaped = false
    var keyExpected = false
    var token = ""
    for (rune in text.runes()) {
        if (quoted) {
            token += String([rune])
            if (escaped) { escaped = false; continue }
            if (rune == r'\\') { escaped = true; continue }
            if (rune == r'"') {
                quoted = false
                if (depth == 1 && keyExpected) {
                    let key = try { JsonValue.fromStr(token).asString().getValue() } catch (_: Exception) { return false }
                    if (keys.contains(key)) { return false }
                    keys.add(key)
                    keyExpected = false
                }
            }
            continue
        }
        if (rune == r'"') { quoted = true; token = "\""; continue }
        if (rune == r'{' || rune == r'[') { depth += 1; if (depth == 1) { keyExpected = true } }
        if (rune == r'}' || rune == r']') { depth -= 1 }
        if (rune == r',' && depth == 1) { keyExpected = true }
    }
    !quoted && depth == 0
}

/** Reject links at every level; /tmp's platform alias is permitted by comparing canonical parents. */
func servicePluginHistoricalSafePath(path: Path): Bool {
    try {
        let root = CliConfig.dotDir
        if (FileInfo(root).isSymbolicLink() || !FileInfo(root).isDirectory()) { return false }
        let base = canonicalize(root)
        var current = path
        while (current != root) {
            let info = FileInfo(current)
            if (info.isSymbolicLink()) { return false }
            let resolved = canonicalize(current).toString()
            if (!resolved.startsWith(base.toString() + "/")) { return false }
            if (current == current.parent) { return false }
            current = current.parent
        }
        true
    } catch (_: Exception) { false }
}

public func servicePluginReadHistoricalLeaseStrict(path: Path): ServicePluginHistoricalLeaseReadResult {
    if (!exists(path)) { return ServicePluginHistoricalLeaseReadResult("missing") }
    if (!servicePluginHistoricalSafePath(path)) { return ServicePluginHistoricalLeaseReadResult("unsafe_path") }
    let text = try {
        let info = FileInfo(path)
        if (!info.isRegular()) { return ServicePluginHistoricalLeaseReadResult("unsafe_path") }
        if (info.size > 65536) { return ServicePluginHistoricalLeaseReadResult("evidence_limit_exceeded") }
        let bytes = Array<UInt8>(65537, repeat: 0)
        var used: Int64 = 0
        try (file = File(path, OpenMode.Read)) {
            while (used < bytes.size) {
                let count = file.read(bytes[used..])
                if (count == 0) { break }
                used += count
            }
        }
        if (used > 65536) { return ServicePluginHistoricalLeaseReadResult("evidence_limit_exceeded") }
        try { String.fromUtf8(bytes[..used]) } catch (_: Exception) { return ServicePluginHistoricalLeaseReadResult("invalid_response_encoding") }
    } catch (_: Exception) { return ServicePluginHistoricalLeaseReadResult("read_failed") }
    if (!servicePluginHistoricalUniqueJsonKeys(text)) { return ServicePluginHistoricalLeaseReadResult("malformed_json") }
    try {
        let root = JsonValue.fromStr(text).asObject()
        let plugin = root.get("pluginId").getOrThrow().asString().getValue()
        let session = root.get("sessionId").getOrThrow().asString().getValue()
        let state = root.get("state").getOrThrow().asString().getValue()
        if (let Some(status) <- root.get("status")) {
            if (status.asString().getValue() != state) { return ServicePluginHistoricalLeaseReadResult("identity_mismatch") }
        }
        let pid = root.get("pid").getOrThrow().asInt().getValue()
        let parent = root.get("parentPid").getOrThrow().asInt().getValue()
        let started = root.get("startedAtMs").getOrThrow().asInt().getValue()
        let port = root.get("port").getOrThrow().asInt().getValue()
        if (plugin.isEmpty() || session.isEmpty() || plugin == "." || plugin == ".." ||
            session == "." || session == ".." || servicePluginPathSegment(plugin) != plugin ||
            servicePluginPathSegment(session) != session || path.fileName != "${session}.lease.json" ||
            path.parent.fileName != plugin || pid <= 0 || parent <= 0 || started <= 0 || port < 0 || port > 65535) {
            return ServicePluginHistoricalLeaseReadResult("identity_mismatch")
        }
        ServicePluginHistoricalLeaseReadResult("ok", evidence: Some(ServicePluginHistoricalLeaseEvidence(
            path, text, plugin, session, state, pid, parent, started, port)))
    } catch (_: Exception) { ServicePluginHistoricalLeaseReadResult("malformed_json") }
}

public func servicePluginHistoricalLeaseMatchesParent(lease: ServicePluginHistoricalLeaseEvidence,
    parentPid: Int64, parentStartedAtMs: Int64): Bool {
    lease.parentPid == parentPid && lease.startedAtMs >= parentStartedAtMs
}

public func probeServicePluginHistoricalResources(parentPid: Int64, parentStartedAtMs: Int64,
    deadline: MonoTime, allowStaleActiveLease!: Bool = false): ServicePluginHistoricalRecoveryResult {
    let evidence = ArrayList<ServicePluginHistoricalLeaseEvidence>()
    let fail = { status: String => ServicePluginHistoricalRecoveryResult(false, false, status,
        evidence: evidence.toArray(), parentPid: parentPid, parentStartedAtMs: parentStartedAtMs) }
    if (parentPid <= 0 || parentStartedAtMs <= 0) { return fail("identity_mismatch") }
    if (deadline <= MonoTime.now()) { return fail("probe_timeout") }
    let base = CliConfig.dotDir.join("service-plugin").join("runtime")
    if (!exists(base)) { return fail("lease_evidence_missing") }
    if (!servicePluginHistoricalSafePath(base)) { return fail("unsafe_path") }
    let hostDeadline = ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + max(0, (deadline - MonoTime.now()).toMilliseconds()))
    var count: Int64 = 0
    try {
        for (directory in Directory.readFrom(base)) {
            count += 1
            if (count > 4096) { return fail("evidence_limit_exceeded") }
            if (!directory.isDirectory() || directory.isSymbolicLink() || !servicePluginHistoricalSafePath(directory.path)) {
                return fail("unsafe_path")
            }
            for (entry in Directory.readFrom(directory.path)) {
                count += 1
                if (count > 4096) { return fail("evidence_limit_exceeded") }
                if (hostDeadline.remaining() <= 0) { return fail("probe_timeout") }
                if (!entry.name.endsWith(".lease.json")) {
                    if (entry.name.endsWith(".log")) { continue }
                    if (entry.name.contains("lease")) { return fail("unsafe_lease_candidate") }
                    continue
                }
                let read = servicePluginReadHistoricalLeaseStrict(entry.path)
                let lease = match (read.evidence) { case Some(value) => value case None => return fail(read.status) }
                if (lease.parentPid != parentPid) { continue }
                if (!servicePluginHistoricalLeaseMatchesParent(lease, parentPid, parentStartedAtMs)) { return fail("identity_mismatch") }
                evidence.add(lease)
                if (lease.state != "stopped" && !["running", "starting", "stopping"].contains(lease.state)) { return fail("lease_state_unknown") }
                if (lease.state != "stopped" && !allowStaleActiveLease) { return ServicePluginHistoricalRecoveryResult(true, false, "lease_active", evidence: evidence.toArray(), parentPid: parentPid, parentStartedAtMs: parentStartedAtMs) }
                let pid = servicePluginProbePid(lease.pid, hostDeadline)
                if (!pid.conclusive) { return fail(pid.status) }
                if (pid.alive) { return ServicePluginHistoricalRecoveryResult(true, false, "pid_alive", evidence: evidence.toArray(), parentPid: parentPid, parentStartedAtMs: parentStartedAtMs) }
                let port = servicePluginPortReleaseState(lease.port, lease.pid, hostDeadline)
                if (!port.conclusive) { return fail(port.status) }
                if (!port.released) { return ServicePluginHistoricalRecoveryResult(true, false, "port_active", evidence: evidence.toArray(), parentPid: parentPid, parentStartedAtMs: parentStartedAtMs) }
            }
        }
        if (evidence.isEmpty()) { return fail("lease_evidence_missing") }
        ServicePluginHistoricalRecoveryResult(true, true, "terminal", evidence: evidence.toArray(), parentPid: parentPid, parentStartedAtMs: parentStartedAtMs)
    } catch (_: Exception) { fail("scan_failed") }
}

public func revalidateServicePluginHistoricalEvidence(evidence: ServicePluginHistoricalRecoveryResult,
    deadline: MonoTime, allowStaleActiveLease!: Bool = false): ServicePluginHistoricalRecoveryResult {
    let current = probeServicePluginHistoricalResources(evidence.parentPid, evidence.parentStartedAtMs, deadline,
        allowStaleActiveLease: allowStaleActiveLease)
    if (!current.terminal) { return current }
    if (current.matchedCount != evidence.matchedCount) { return ServicePluginHistoricalRecoveryResult(false, false, "identity_changed") }
    for (previous in evidence.evidence) {
        var found = false
        for (next in current.evidence) {
            if (previous.path == next.path && previous.original == next.original) { found = true }
        }
        if (!found) { return ServicePluginHistoricalRecoveryResult(false, false, "identity_changed") }
    }
    current
}
