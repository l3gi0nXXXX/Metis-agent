package metis.process

import std.collection.{ArrayList, HashSet}
import std.convert.Parsable
import std.fs.{Directory, FileInfo, Path, exists, remove, rename}
import std.time.{DateTime, MonoTime}

func managedRecoveryAtomicMetadata(path: Path, text: String): Bool {
    let temporary = Path("${path.toString()}.tmp-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try {
        if (!managedRecoveryDirectorySafe(path.parent) || (exists(path) && FileInfo(path).isSymbolicLink())) { return false }
        if (!publishExclusiveUtf8File(temporary, text).ok) { return false }
        rename(temporary, to: path, overwrite: true)
        syncFileDirectory(path.parent)
    } catch (_: Exception) { false }
    finally { try { if (exists(temporary)) { remove(temporary) } } catch (_: Exception) { () } }
}

func managedRecoveryReadIssued(directory: Path, parent: String): Int64 {
    let path = directory.join(".issued")
    if (!exists(path)) { return 0 }
    let text = match (managedRecoveryReadText(path)) { case Some(value) => value case None => return -1 }
    let fields = match (managedRecoveryParseFields(text)) { case Some(value) => value case None => return -1 }
    try {
        let issued = Int64.parse(fields["issued"])
        if (fields.size != 2 || fields["parent"] != parent || issued <= 0 || issued > 9007199254740991 || issued.toString() != fields["issued"]) { return -1 }
        issued
    } catch (_: Exception) { -1 }
}

func managedRecoveryReadRootCheckpoint(directory: Path, parent: String): ?ManagedRecoveryClosedCheckpoint {
    let path = directory.join("roots.closed")
    if (!exists(path)) { return Some(ManagedRecoveryClosedCheckpoint("roots", [])) }
    match (managedRecoveryReadText(path)) {
        case Some(text) => managedRecoveryParseClosedCheckpoint(text, "roots.closed", parent)
        case None => None
    }
}

private func managedRecoveryRootSequence(key: String): Int64 {
    let parts = key.split("-")
    if (parts.size != 2 || parts[0] != "r") { return -1 }
    try {
        let value = Int64.parse(parts[1])
        if (value <= 0 || value > 9007199254740991 || value.toString() != parts[1]) { -1 } else { value }
    } catch (_: Exception) { -1 }
}

private func managedRecoveryMergeRoot(checkpoint: ManagedRecoveryClosedCheckpoint, sequence: Int64): Array<(Int64, Int64)> {
    let result = ArrayList<(Int64, Int64)>()
    var low = sequence; var high = sequence; var inserted = false
    for ((start, end) in checkpoint.ranges) {
        if (end + 1 < low) { result.add((start, end)) }
        else if (high + 1 < start) {
            if (!inserted) { result.add((low, high)); inserted = true }
            result.add((start, end))
        } else { low = min(low, start); high = max(high, end) }
    }
    if (!inserted) { result.add((low, high)) }
    result.toArray()
}

private func managedRecoveryRootBirthValid(directory: Path, parent: String, key: String, pid: Int64): Bool {
    let path = directory.join("${key}.birth")
    if (!exists(path)) { return true }
    let text = match (managedRecoveryReadText(path)) { case Some(value) => value case None => return false }
    let fields = match (managedRecoveryParseFields(text)) { case Some(value) => value case None => return false }
    try {
        let identity = parseProcessBirthIdentity(fields["birth"]).getOrThrow()
        identity.pid == pid && text == "managed-recovery-v1\nkey:${key}\nphase:birth\nparent:${parent}\npid:${pid}\npgid:0\nbirth:${identity.serialize()}\n"
    } catch (_: Exception) { false }
}

private func managedRecoveryRootSourceClosed(directory: Path, parent: String, key: String): Bool {
    let intent = "managed-recovery-v1\nkey:${key}\nphase:intent\nparent:${parent}\npid:0\npgid:0\nbirth:\n"
    if (managedRecoveryReadText(directory.join("${key}.intent")).getOrDefault({ => "" }) != intent) { return false }
    let noSpawn = directory.join("${key}.not_spawned")
    if (exists(noSpawn)) {
        return managedRecoveryReadText(noSpawn).getOrDefault({ => "" }) == intent.replace("phase:intent\n", "phase:not_spawned\n") &&
            !exists(directory.join("${key}.spawned")) && !exists(directory.join("${key}.birth")) && !exists(directory.join("${key}.terminal"))
    }
    let text = match (managedRecoveryReadText(directory.join("${key}.terminal"))) { case Some(value) => value case None => return false }
    let fields = match (managedRecoveryParseFields(text)) { case Some(value) => value case None => return false }
    try {
        let pid = Int64.parse(fields["pid"])
        let canonical = "managed-recovery-v1\nkey:${key}\nphase:terminal\nparent:${parent}\npid:${pid}\npgid:0\nbirth:\n"
        if (pid <= 1 || pid > 2147483647 || text != canonical || !managedRecoveryRootBirthValid(directory, parent, key, pid) ||
            managedRecoveryReadText(directory.join("${key}.spawned")).getOrDefault({ => "" }) != canonical.replace("phase:terminal\n", "phase:spawned\n")) { return false }
        let observed = probeProcessPidPresence(pid, MonoTime.now() + Duration.millisecond * 100)
        observed.conclusive && !observed.alive
    } catch (_: Exception) { false }
}

private func managedRecoveryRootHasExecError(directory: Path, key: String): Bool {
    var scanned: Int64 = 0
    for (entry in Directory.readFrom(directory)) {
        scanned += 1
        if (scanned > 16384 || entry.isSymbolicLink()) { throw Exception("process_recovery_exec_error_pending") }
        if (entry.name.endsWith(".exec_error")) {
            let owner = entry.name.removeSuffix(".exec_error")
            if (!managedRecoverySafeKey(owner)) { throw Exception("process_recovery_exec_error_pending") }
            if (owner.split("-o-")[0] == key) { return true }
        }
    }
    false
}

private func managedRecoveryExecSnapshotMatches(directory: Path, parent: String, binding: String,
    root: String, expected: ?String): Bool {
    if (expected.isNone()) { return true }
    let current = managedRecoveryReadExecError(directory, parent, binding, "${root}-o-1")
    let text = match (current) { case Some(value) => value.originalText case None => "" }
    text == expected.getOrThrow()
}

/** Revisit retained terminal sources after range overflow or an interrupted host callback. No signal is sent. */
private func managedRecoveryCompactRoots(directory: Path, parent: String, issued: Int64,
    checkpoint: ManagedRecoveryClosedCheckpoint, provenSequence!: Int64 = 0): ?ManagedRecoveryClosedCheckpoint {
    var merged = checkpoint
    var changed = false
    if (provenSequence > 0 && !merged.covers("r-${provenSequence}")) {
        merged = ManagedRecoveryClosedCheckpoint("roots", managedRecoveryMergeRoot(merged, provenSequence))
        changed = true
    }
    let errorRoots = HashSet<String>()
    var scanned: Int64 = 0
    for (entry in Directory.readFrom(directory)) {
        scanned += 1
        if (scanned > 16384 || entry.isSymbolicLink()) { return None }
        if (entry.name.endsWith(".exec_error")) {
            let owner = entry.name.removeSuffix(".exec_error")
            if (!managedRecoverySafeKey(owner)) { return None }
            errorRoots.add(owner.split("-o-")[0])
        }
    }
    scanned = 0
    for (entry in Directory.readFrom(directory)) {
        scanned += 1
        if (scanned > 16384 || entry.isSymbolicLink()) { return None }
        if (!entry.name.endsWith(".intent")) { continue }
        let key = entry.name.removeSuffix(".intent")
        let sequence = managedRecoveryRootSequence(key)
        if (sequence < 1 || sequence > issued || merged.covers(key)) { continue }
        // Another caller's active compaction cannot consume a live caller's error outcome.
        if (errorRoots.contains(key)) { continue }
        if (!managedRecoveryRootSourceClosed(directory, parent, key)) { continue }
        merged = ManagedRecoveryClosedCheckpoint("roots", managedRecoveryMergeRoot(merged, sequence))
        changed = true
    }
    if (!changed || merged.ranges.size > 257) { return Some(checkpoint) }
    let parts = ArrayList<String>()
    for ((low, high) in merged.ranges) { parts.add("${low}-${high}") }
    let text = "managed-recovery-v1\nparent:${parent}\nbroker:roots\nissued:${issued}\nranges:${String.join(parts.toArray(), delimiter: ",")}\n"
    if (text.size > 16384) { return Some(checkpoint) }
    if (!managedRecoveryAtomicMetadata(directory.join("roots.closed"), text)) { return None }
    Some(ManagedRecoveryClosedCheckpoint("roots", merged.ranges, issued: issued))
}

func managedRecoveryRemoveRetiredRoots(directory: Path, checkpoint: ManagedRecoveryClosedCheckpoint,
    parent: String, expectedBinding!: ?String = None, expectedExecText!: ?String = None,
    expectedRoot!: String = ""): Bool {
    try {
        let binding = managedRecoveryBinding((directory.toString(), parent))
        if (expectedBinding.isSome() && expectedBinding.getOrThrow() != binding) { return false }
        if (expectedExecText.isSome() && (expectedRoot.isEmpty() ||
            !managedRecoveryExecSnapshotMatches(directory, parent, binding, expectedRoot, expectedExecText))) { return false }
        let sources = ArrayList<Path>()
        let errors = ArrayList<Path>()
        var scanned: Int64 = 0
        for (entry in Directory.readFrom(directory)) {
            scanned += 1
            if (scanned > 16384) { return false }
            let segments = entry.name.split(".")
            let key = segments[0]
            if (!checkpoint.covers(key)) { continue }
            if (entry.isSymbolicLink()) { return false }
            if (segments.size < 2 || !["intent", "spawned", "birth", "terminal", "not_spawned", "closed", "exec_error"].contains(segments[1])) { return false }
            if (segments[1] == "exec_error") {
                if (segments.size != 2) { return false }
                let root = key.split("-o-")[0]
                if (expectedBinding.isNone() || expectedExecText.isNone() || root != expectedRoot) { return false }
                let validated = managedRecoveryRootExecErrorNames(directory, parent, binding, root)
                if (!validated.contains(entry.name)) { return false }
                errors.add(entry.path)
            } else { sources.add(entry.path) }
        }
        // A durable checkpoint already exists. Delete optional errors before their birth witnesses.
        // A crash before this phase leaves all original bindings available for strict retry.
        if (managedRecoveryBinding((directory.toString(), parent)) != binding ||
            !managedRecoveryExecSnapshotMatches(directory, parent, binding, expectedRoot, expectedExecText)) { return false }
        for (path in errors) { remove(path) }
        if (!errors.isEmpty() && !syncFileDirectory(directory)) { return false }
        for (path in sources) { remove(path) }
        true
    } catch (_: Exception) { false }
}

/** Global root sequence is shared by all inherited neutral helpers, under one stable OS claim. */
public func managedRecoveryAllocateRoot(context: (String, String)): String {
    let directory = Path(context[0])
    let claim = acquireProcessFileClaim(directory.join(".resource-claim"), MonoTime.now() + Duration.second * 3)
    if (!claim.ok) { throw Exception("process_recovery_claim_failed") }
    try {
        let issued = managedRecoveryReadIssued(directory, context[1])
        let priorCheckpoint = match (managedRecoveryReadRootCheckpoint(directory, context[1])) {
            case Some(value) => value
            case None => throw Exception("process_recovery_checkpoint_invalid")
        }
        if (issued < 0 || priorCheckpoint.issued > issued || issued >= 9007199254740991) { throw Exception("process_recovery_sequence_invalid") }
        let checkpoint = match (managedRecoveryCompactRoots(directory, context[1], issued, priorCheckpoint)) {
            case Some(value) => value
            case None => throw Exception("process_recovery_checkpoint_write_failed")
        }
        if (!managedRecoveryRemoveRetiredRoots(directory, checkpoint, context[1])) { throw Exception("process_recovery_cleanup_failed") }
        var liveEvidence: Int64 = 0
        for (entry in Directory.readFrom(directory)) {
            if (entry.isSymbolicLink()) { throw Exception("process_recovery_unsafe_path") }
            if (["inventory", "ready", ".issued", ".resource-claim", "roots.closed"].contains(entry.name)) { continue }
            if (entry.name.contains(".tmp-")) { continue }
            liveEvidence += 1
            if (liveEvidence >= managedRecoveryLimit) { throw Exception("process_recovery_evidence_pressure") }
        }
        let sequence = issued + 1
        if (!managedRecoveryAtomicMetadata(directory.join(".issued"), "managed-recovery-v1\nparent:${context[1]}\nissued:${sequence}\n")) {
            throw Exception("process_recovery_sequence_write_failed")
        }
        let key = "r-${sequence}"
        if (!managedRecoveryPublishFact(directory, key, "intent", context[1])) { throw Exception("process_recovery_intent_write_failed") }
        key
    } finally { claim.release() }
}

/** Caller observed the actual direct-child reap; independent helper terminal proves its groups gone. */
public func managedRecoveryRetireRoot(context: (String, String), key: String, expectedPid: Int64,
    expectedBinding!: ?String = None, expectedExecText!: ?String = None): Bool {
    let sequence = managedRecoveryRootSequence(key)
    if (sequence < 1 || expectedPid == 1 || expectedPid < 0) { return false }
    let directory = Path(context[0])
    let claim = acquireProcessFileClaim(directory.join(".resource-claim"), MonoTime.now() + Duration.second * 3)
    if (!claim.ok) { return false }
    try {
        let issued = managedRecoveryReadIssued(directory, context[1])
        let checkpoint = match (managedRecoveryReadRootCheckpoint(directory, context[1])) { case Some(value) => value case None => return false }
        if (issued < sequence || checkpoint.issued > issued) { return false }
        let binding = managedRecoveryBinding(context)
        if (expectedBinding.isSome() && expectedBinding.getOrThrow() != binding) { return false }
        if (!managedRecoveryExecSnapshotMatches(directory, context[1], binding, key, expectedExecText)) { return false }
        if (managedRecoveryRootHasExecError(directory, key)) {
            // Only this root's own wait may cache and acknowledge an attached outcome.
            if (expectedBinding.isNone() || expectedExecText.isNone()) { return false }
            let _ = managedRecoveryRootExecErrorNames(directory, context[1], binding, key)
        }
        if (checkpoint.covers(key)) {
            return managedRecoveryRemoveRetiredRoots(directory, checkpoint, context[1], expectedBinding: expectedBinding,
                expectedExecText: expectedExecText, expectedRoot: key)
        }
        let expectedIntent = "managed-recovery-v1\nkey:${key}\nphase:intent\nparent:${context[1]}\npid:0\npgid:0\nbirth:\n"
        if (managedRecoveryReadText(directory.join("${key}.intent")).getOrDefault({ => "" }) != expectedIntent) { return false }
        if (expectedPid == 0) {
            let text = match (managedRecoveryReadText(directory.join("${key}.not_spawned"))) { case Some(value) => value case None => return false }
            if (text != expectedIntent.replace("phase:intent\n", "phase:not_spawned\n") || exists(directory.join("${key}.spawned")) ||
                exists(directory.join("${key}.birth")) || exists(directory.join("${key}.terminal"))) { return false }
        } else {
            let terminalText = match (managedRecoveryReadText(directory.join("${key}.terminal"))) { case Some(value) => value case None => return false }
            let spawnedText = match (managedRecoveryReadText(directory.join("${key}.spawned"))) { case Some(value) => value case None => return false }
            let expected = "managed-recovery-v1\nkey:${key}\nphase:terminal\nparent:${context[1]}\npid:${expectedPid}\npgid:0\nbirth:\n"
            if (terminalText != expected || spawnedText != expected.replace("phase:terminal\n", "phase:spawned\n") ||
                !managedRecoveryRootBirthValid(directory, context[1], key, expectedPid) ||
                exists(directory.join("${key}.not_spawned"))) { return false }
        }
        let merged = match (managedRecoveryCompactRoots(directory, context[1], issued, checkpoint, provenSequence: sequence)) {
            case Some(value) => value
            case None => return false
        }
        if (!merged.covers(key)) { return false }
        managedRecoveryRemoveRetiredRoots(directory, merged, context[1], expectedBinding: expectedBinding,
            expectedExecText: expectedExecText, expectedRoot: key)
    } catch (_: Exception) { false }
    finally { claim.release() }
}
