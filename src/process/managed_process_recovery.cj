package metis.process

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, exists}
import std.posix.chmod
import std.sort.*
import std.time.{DateTime, MonoTime}

// A bounded evidence reader is not a new business-process concurrency admission policy.
let managedRecoveryLimit: Int64 = 4096

public class ManagedProcessRecoveryReadResult {
    public let ok: Bool
    public let terminal: Bool
    public let status: String
    public let original: String
    public let count: Int64
    public init(ok: Bool, terminal: Bool, status: String, original!: String = "", count!: Int64 = 0) {
        this.ok = ok; this.terminal = terminal; this.status = status; this.original = original; this.count = count
    }
}

public func managedRecoverySafeKey(value: String): Bool {
    if (value.isEmpty() || value.size > 256) { return false }
    for (rune in value.runes()) {
        if (!((rune >= r'0' && rune <= r'9') || (rune >= r'a' && rune <= r'z') ||
            (rune >= r'A' && rune <= r'Z') || rune == r'-' || rune == r'_')) { return false }
    }
    true
}

public func managedRecoveryDirectorySafe(path: Path): Bool {
    try {
        var current = path
        var depth: Int64 = 0
        while (depth < 128) {
            if (exists(current) && FileInfo(current).isSymbolicLink()) { return false }
            let parent = current.parent
            if (parent == current) { return true }
            current = parent; depth += 1
        }
        false
    } catch (_: Exception) { false }
}

public func managedRecoveryReadText(path: Path): ?String {
    try {
        if (!managedRecoveryDirectorySafe(path.parent)) { return None }
        let info = FileInfo(path)
        if (info.isSymbolicLink() || !info.isRegular() || info.size > 16384) { return None }
        let bytes = Array<UInt8>(16385, repeat: 0)
        var used: Int64 = 0
        try (file = File(path, OpenMode.Read)) {
            while (used < bytes.size) {
                let count = file.read(bytes[used..])
                if (count == 0) { break }
                used += count
            }
        }
        if (used > 16384) { return None }
        Some(String.fromUtf8(bytes[..used]))
    } catch (_: Exception) { None }
}

public func managedRecoveryParseFields(text: String): ?HashMap<String, String> {
    if (text.size > 16384 || text.contains("\r") || text.contains("\u{0}")) { return None }
    let fields = HashMap<String, String>()
    let lines = text.split("\n")
    if (lines.isEmpty() || lines[0] != "managed-recovery-v1") { return None }
    for (index in 1..lines.size) {
        if (lines[index].isEmpty()) { continue }
        let parts = lines[index].split(":")
        if (parts.size < 2 || !managedRecoverySafeKey(parts[0]) || fields.contains(parts[0])) { return None }
        fields[parts[0]] = String.join(parts[1..], delimiter: ":")
    }
    Some(fields)
}

private func managedRecoveryRecordValid(record: HashMap<String, String>): Bool {
    if (record.size != 6) { return false }
    for (key in ["key", "phase", "parent", "pid", "pgid", "birth"]) { if (!record.contains(key)) { return false } }
    try {
        let pid = Int64.parse(record["pid"]); let pgid = Int64.parse(record["pgid"])
        if (pid.toString() != record["pid"] || pgid.toString() != record["pgid"]) { return false }
        if (["intent", "not_spawned"].contains(record["phase"])) { return pid == 0 && pgid == 0 && record["birth"].isEmpty() }
        if (pid <= 1 || pid > 2147483647 || (pgid != 0 && pgid != pid)) { return false }
        if (record["phase"] == "birth") {
            let birth = parseProcessBirthIdentity(record["birth"])
            birth.isSome() && birth.getOrThrow().pid == pid
        } else { record["birth"].isEmpty() }
    } catch (_: Exception) { false }
}

public func managedRecoveryPublishFact(directory: Path, key: String, phase: String, parent: String,
    pid!: Int64 = 0, pgid!: Int64 = 0, birth!: String = ""): Bool {
    if (!managedRecoverySafeKey(key) || !["intent", "spawned", "birth", "terminal", "not_spawned"].contains(phase) ||
        parent.contains("\n") || parent.contains("\r")) { return false }
    let text = "managed-recovery-v1\nkey:${key}\nphase:${phase}\nparent:${parent}\npid:${pid}\npgid:${pgid}\nbirth:${birth}\n"
    let path = directory.join("${key}.${phase}")
    if (!managedRecoveryDirectorySafe(directory)) { return false }
    let published = publishExclusiveUtf8File(path, text)
    if (!published.ok && managedRecoveryReadText(path).getOrDefault({ => "" }) != text) { return false }
    try { chmod(path.toString(), UInt32(0o600)); syncFileDirectory(directory) } catch (_: Exception) { false }
}

/** Validated native private-channel outcome; exit status alone never constructs this value. */
public class ManagedRecoveryExecError {
    public let phase: String
    public let error: Int64
    public let originalText: String
    public init(phase: String, error: Int64, originalText: String) {
        this.phase = phase; this.error = error; this.originalText = originalText
    }
}

/** Only a genuinely absent directory entry is optional; unreadable/replaced metadata stays pending. */
private func managedRecoveryOptionalExecText(directory: Path, name: String): ?String {
    if (!managedRecoveryDirectorySafe(directory)) { throw Exception("process_recovery_exec_error_pending") }
    var scanned: Int64 = 0
    for (entry in Directory.readFrom(directory)) {
        scanned += 1
        if (scanned > 16384) { throw Exception("process_recovery_exec_error_pending") }
        if (entry.name != name) { continue }
        if (entry.isSymbolicLink() || !entry.isRegular()) { throw Exception("process_recovery_exec_error_pending") }
        let text = managedRecoveryReadText(entry.path).getOrThrow()
        if (text.size > 8192) { throw Exception("process_recovery_exec_error_pending") }
        return Some(text)
    }
    None
}

/** The independent inventory binding is not encoded in ProcessInstanceIdentity. */
public func managedRecoveryBinding(context: (String, String)): String {
    try {
        if (context[0].isEmpty() || parseProcessInstanceIdentity(context[1]).isNone()) {
            throw Exception("process_recovery_exec_error_pending")
        }
        let text = managedRecoveryReadText(Path(context[0]).join("inventory")).getOrThrow()
        let fields = managedRecoveryParseFields(text).getOrThrow()
        let binding = fields["binding"]
        if (context[0].isEmpty() || parseProcessInstanceIdentity(context[1]).isNone() || fields.size != 3 ||
            binding.isEmpty() || binding.size > 4096 || binding.contains("\n") || binding.contains("\r") || binding.contains("\u{0}") ||
            text != "managed-recovery-v1\nparent:${context[1]}\nbinding:${binding}\ncoverage:broker-v1\n") {
            throw Exception("process_recovery_exec_error_pending")
        }
        binding
    } catch (_: Exception) { throw Exception("process_recovery_exec_error_pending") }
}

private func managedRecoveryExecOriginal(directory: Path, parent: String, key: String,
    pid: Int64, pgid: Int64, birth: String): Bool {
    let identity = parseProcessBirthIdentity(birth).getOrThrow()
    if (identity.pid != pid || identity.serialize() != birth || pid <= 1 || pid > 2147483647 ||
        exists(directory.join("${key}.not_spawned"))) { return false }
    for (phase in ["intent", "spawned", "birth"]) {
        let expectedPid = if (phase == "intent") { 0 } else { pid }
        let expectedPgid = if (phase == "intent") { 0 } else { pgid }
        let expectedBirth = if (phase == "birth") { birth } else { "" }
        let expected = "managed-recovery-v1\nkey:${key}\nphase:${phase}\nparent:${parent}\npid:${expectedPid}\npgid:${expectedPgid}\nbirth:${expectedBirth}\n"
        if (managedRecoveryReadText(directory.join("${key}.${phase}")).getOrThrow() != expected) { return false }
    }
    true
}

private func managedRecoveryReadExecErrorFields(directory: Path, parent: String, binding: String,
    ownerKey: String): ?HashMap<String, String> {
    if (!managedRecoverySafeKey(ownerKey) || managedRecoveryBinding((directory.toString(), parent)) != binding) {
        throw Exception("process_recovery_exec_error_pending")
    }
    let text = match (managedRecoveryOptionalExecText(directory, "${ownerKey}.exec_error")) {
        case Some(value) => value
        case None => return None
    }
    let lines = text.split("\n")
    let names = ["key", "parent", "binding", "helper_key", "helper_pid", "helper_birth",
        "owner_pid", "owner_pgid", "owner_birth", "phase", "errno"]
    if (lines.size != 13 || lines[0] != "managed-exec-error-v1" || !lines[12].isEmpty() ||
        text.contains("\r") || text.contains("\u{0}")) { throw Exception("process_recovery_exec_error_pending") }
    let fields = HashMap<String, String>()
    for (index in 0..names.size) {
        let prefix = names[index] + ":"
        if (!lines[index + 1].startsWith(prefix)) { throw Exception("process_recovery_exec_error_pending") }
        fields[names[index]] = lines[index + 1].removePrefix(prefix)
    }
    let helper = fields["helper_key"]
    let owner = ownerKey.split("-o-")
    if (!managedRecoverySafeKey(helper) || owner.size != 2 || owner[0] != helper || fields["key"] != ownerKey ||
        fields["parent"] != parent || fields["binding"] != binding) { throw Exception("process_recovery_exec_error_pending") }
    let sequence = Int64.parse(owner[1])
    let helperPid = Int64.parse(fields["helper_pid"])
    let ownerPid = Int64.parse(fields["owner_pid"])
    let ownerPgid = Int64.parse(fields["owner_pgid"])
    let error = Int64.parse(fields["errno"])
    if (sequence <= 0 || sequence > 9007199254740991 || sequence.toString() != owner[1] ||
        helperPid.toString() != fields["helper_pid"] || ownerPid.toString() != fields["owner_pid"] ||
        ownerPgid.toString() != fields["owner_pgid"] || ownerPgid != ownerPid ||
        error < 0 || error > 2147483647 || error.toString() != fields["errno"] ||
        !["exec", "spawn", "setup", "protocol", "channel"].contains(fields["phase"]) ||
        (["exec", "spawn"].contains(fields["phase"]) && error == 0) ||
        !managedRecoveryExecOriginal(directory, parent, helper, helperPid, 0, fields["helper_birth"])) {
        throw Exception("process_recovery_exec_error_pending")
    }
    if (fields["phase"] == "spawn") {
        // Node v24.14.1's exposed Darwin POSIX set; unknown runtime codes stay unknown.
        let known = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
            16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
            30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43,
            45, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 60, 61,
            62, 63, 65, 66, 69, 70, 77, 78, 84, 89, 90, 91, 92, 94,
            95, 96, 97, 98, 99, 100, 101, 102 ]
        if (!known.contains(error) || ownerPid != 0 || ownerPgid != 0 || !fields["owner_birth"].isEmpty()) {
            throw Exception("process_recovery_exec_error_pending")
        }
        let intent = "managed-recovery-v1\nkey:${ownerKey}\nphase:intent\nparent:${parent}\npid:0\npgid:0\nbirth:\n"
        if (managedRecoveryReadText(directory.join("${ownerKey}.intent")).getOrThrow() != intent ||
            managedRecoveryReadText(directory.join("${ownerKey}.not_spawned")).getOrThrow() != intent.replace("phase:intent\n", "phase:not_spawned\n")) {
            throw Exception("process_recovery_exec_error_pending")
        }
        for (entry in Directory.readFrom(directory)) {
            if (["${ownerKey}.spawned", "${ownerKey}.birth", "${ownerKey}.terminal"].contains(entry.name)) {
                throw Exception("process_recovery_exec_error_pending")
            }
        }
    } else if (!managedRecoveryExecOriginal(directory, parent, ownerKey, ownerPid, ownerPgid, fields["owner_birth"])) {
        throw Exception("process_recovery_exec_error_pending")
    }
    fields["original_text"] = text
    Some(fields)
}

/** Only an absent file returns None; invalid/unreadable facts stay pending, valid unknown phases return Some. */
public func managedRecoveryReadExecError(directory: Path, parent: String, binding: String,
    ownerKey: String): ?ManagedRecoveryExecError {
    try {
        match (managedRecoveryReadExecErrorFields(directory, parent, binding, ownerKey)) {
            case Some(fields) => Some(ManagedRecoveryExecError(fields["phase"], Int64.parse(fields["errno"]), fields["original_text"]))
            case None => None
        }
    } catch (_: Exception) { throw Exception("process_recovery_exec_error_pending") }
}

/** Validate all retained optional outcomes before root checkpointing or any source deletion. */
func managedRecoveryRootExecErrorNames(directory: Path, parent: String, binding: String,
    root: String): Array<String> {
    let names = ArrayList<String>()
    var scanned: Int64 = 0
    for (entry in Directory.readFrom(directory)) {
        scanned += 1
        if (scanned > 16384 || entry.isSymbolicLink()) { throw Exception("process_recovery_exec_error_pending") }
        if (!entry.name.endsWith(".exec_error")) { continue }
        let owner = entry.name.removeSuffix(".exec_error")
        if (!managedRecoverySafeKey(owner)) { throw Exception("process_recovery_exec_error_pending") }
        if (owner.split("-o-")[0] != root) { continue }
        let fields = managedRecoveryReadExecErrorFields(directory, parent, binding, owner).getOrThrow()
        if (fields["helper_key"] != root) { throw Exception("process_recovery_exec_error_pending") }
        let terminalKeys = if (fields["phase"] == "spawn") { [root] } else { [root, owner] }
        for (key in terminalKeys) {
            let spawned = managedRecoveryReadText(directory.join("${key}.spawned")).getOrThrow()
            if (managedRecoveryReadText(directory.join("${key}.terminal")).getOrThrow() !=
                spawned.replace("phase:spawned\n", "phase:terminal\n")) { throw Exception("process_recovery_exec_error_pending") }
        }
        let deadline = MonoTime.now() + Duration.millisecond * 100
        let births = if (fields["phase"] == "spawn") { [fields["helper_birth"]] } else { [fields["helper_birth"], fields["owner_birth"]] }
        for (birth in births) {
            let observed = probeProcessBirthIdentity(parseProcessBirthIdentity(birth).getOrThrow(), deadline)
            if (!observed.conclusive || observed.alive) { throw Exception("process_recovery_exec_error_pending") }
        }
        if (fields["phase"] != "spawn" && !managedRecoveryGroupGone(Int64.parse(fields["owner_pgid"]))) {
            throw Exception("process_recovery_exec_error_pending")
        }
        names.add(entry.name)
    }
    names.toArray()
}

/** Establishes the root ownership contract before the first external resource is usable. */
public func managedRecoveryInitialize(directory: Path, parent: String, binding: String): Bool {
    if (parseProcessInstanceIdentity(parent).isNone() || binding.isEmpty() || binding.size > 4096 ||
        binding.contains("\n") || binding.contains("\r") || binding.contains("\u{0}") ||
        !managedRecoveryDirectorySafe(directory)) { return false }
    try {
        if (!exists(directory)) { Directory.create(directory, recursive: true) }
        chmod(directory.toString(), UInt32(0o700))
        let text = "managed-recovery-v1\nparent:${parent}\nbinding:${binding}\ncoverage:broker-v1\n"
        let published = publishExclusiveUtf8File(directory.join("inventory"), text)
        if (!published.ok && managedRecoveryReadText(directory.join("inventory")).getOrDefault({ => "" }) != text) { return false }
        chmod(directory.join("inventory").toString(), UInt32(0o600))
        if (!syncFileDirectory(directory)) { return false }
        setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", directory.toString())
        setVariable("METIS_PROCESS_RECOVERY_PARENT", parent)
        true
    } catch (_: Exception) { false }
}

public func managedRecoveryContext(): (String, String) {
    (getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").getOrDefault({ => "" }),
        getVariable("METIS_PROCESS_RECOVERY_PARENT").getOrDefault({ => "" }))
}

public func managedRecoveryNextBrokerKey(generation: Int64): String {
    let context = managedRecoveryContext()
    if (!context[0].isEmpty()) { return managedRecoveryAllocateRoot(context) }
    let process = currentProcessInstanceIdentity()
    let pid = match (process) { case Some(value) => value.pid case None => 0 }
    "b-${pid}-${generation}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
}

public func managedRecoveryNativeIntent(context!: (String, String) = managedRecoveryContext()): String {
    if (context[0].isEmpty()) { return "" }
    managedRecoveryAllocateRoot(context)
}

public func managedRecoveryCommitObservedSpawn(directory: Path, key: String, parent: String): Bool {
    let text = managedRecoveryReadText(directory.join("${key}.spawned"))
    let fields = match (text) { case Some(value) => managedRecoveryParseFields(value) case None => return false }
    let record = match (fields) { case Some(value) => value case None => return false }
    try {
        if (record["key"] != key || record["parent"] != parent || record["phase"] != "spawned") { return false }
        let pid = Int64.parse(record["pid"])
        let pgid = Int64.parse(record["pgid"])
        let birth = observeProcessBirthIdentity(pid)
        birth.isSome() && managedRecoveryPublishFact(directory, key, "birth", parent, pid: pid, pgid: pgid, birth: birth.getOrThrow().serialize())
    } catch (_: Exception) { false }
}

public func managedRecoveryNativeSpawned(key: String, pid: Int64, pgid: Int64,
    context!: (String, String) = managedRecoveryContext()): Bool {
    if (key.isEmpty()) { return true }
    managedRecoveryPublishFact(Path(context[0]), key, "spawned", context[1], pid: pid, pgid: pgid) &&
        managedRecoveryCommitObservedSpawn(Path(context[0]), key, context[1])
}

public func managedRecoveryNativeTerminal(key: String, pid: Int64, pgid: Int64, spawned: Bool, treeGone: Bool,
    context!: (String, String) = managedRecoveryContext()): Unit {
    if (key.isEmpty() || !treeGone) { return }
    let _ = managedRecoveryPublishFact(Path(context[0]), key, if (spawned) { "terminal" } else { "not_spawned" }, context[1], pid: pid, pgid: pgid)
    let _ = managedRecoveryRetireRoot(context, key, pid)
}

/** Called only after wait returned for this owned helper; terminal source still must be present. */
public func managedRecoveryRetireObservedHelper(key: String, context: (String, String),
    expectedBinding!: ?String = None, expectedExecText!: ?String = None): Bool {
    if (key.isEmpty()) { return true }
    let text = managedRecoveryReadText(Path(context[0]).join("${key}.spawned"))
    let fields = match (text) { case Some(value) => managedRecoveryParseFields(value) case None => return false }
    try {
        let record = fields.getOrThrow()
        if (record["key"] != key || record["parent"] != context[1]) { return false }
        managedRecoveryRetireRoot(context, key, Int64.parse(record["pid"]), expectedBinding: expectedBinding,
            expectedExecText: expectedExecText)
    } catch (_: Exception) { false }
}

/** The independent helper and its gated child publish before the host commits their births. */
public func managedRecoveryCommitAttachedLaunch(directory: Path, key: String, parent: String,
    timeoutMs!: Int64 = 3000): Bool {
    let deadline = MonoTime.now() + Duration.millisecond * max(1, timeoutMs)
    let binding = managedRecoveryBinding((directory.toString(), parent))
    var helperCommitted = false
    while (MonoTime.now() < deadline) {
        if (managedRecoveryBinding((directory.toString(), parent)) != binding) { return false }
        if (!helperCommitted) { helperCommitted = managedRecoveryCommitObservedSpawn(directory, key, parent) }
        if (helperCommitted && managedRecoveryCommitObservedSpawn(directory, "${key}-o-1", parent)) { return true }
        if (helperCommitted && exists(directory.join("${key}.terminal"))) {
            // Node publishes helper terminal only after its optional outcome is complete and durable.
            let outcome = managedRecoveryReadExecError(directory, parent, binding, "${key}-o-1")
            return outcome.isSome() && outcome.getOrThrow().phase == "spawn"
        }
        if (exists(directory.join("${key}.terminal"))) { return false }
        sleep(Duration.millisecond * 10)
    }
    false
}

/** Caller holds a real unreaped direct-child handle; never used by historical recovery. */
@When[os == "macOS"]
public func managedRecoveryRequestOwnedHelperStop(pid: Int64): Unit {
    if (pid > 1 && pid <= 2147483647) { let _ = unsafe { kill(Int32(pid), Int32(15)) } }
}

@When[os != "macOS"]
public func managedRecoveryRequestOwnedHelperStop(_pid: Int64): Unit { () }

@When[os == "macOS"]
foreign { func kill(pid: Int32, signal: Int32): Int32 }

@When[os == "macOS"]
private func managedRecoveryGroupGone(pgid: Int64): Bool {
    if (pgid <= 1 || pgid > 2147483647) { return false }
    let result = unsafe { kill(-Int32(pgid), Int32(0)) }
    result != 0 && unsafe { __error().read() } == 3
}

@When[os != "macOS"]
private func managedRecoveryGroupGone(_pgid: Int64): Bool { false }

public class ManagedRecoveryClosedCheckpoint {
    public let broker: String
    public let ranges: Array<(Int64, Int64)>
    public let issued: Int64
    public init(broker: String, ranges: Array<(Int64, Int64)>, issued!: Int64 = 0) { this.broker = broker; this.ranges = ranges; this.issued = issued }
    public func covers(key: String): Bool {
        let parts = key.split("-o-")
        if (parts.isEmpty()) { return false }
        let sequenceText = if (this.broker == "roots") {
            let root = parts[0].split("-")
            if (root.size != 2 || root[0] != "r") { return false }
            root[1]
        } else {
            if (parts.size != 2 || parts[0] != this.broker) { return false }
            parts[1]
        }
        let sequence = try { Int64.parse(sequenceText) } catch (_: Exception) { return false }
        if (sequence.toString() != sequenceText) { return false }
        for ((low, high) in this.ranges) { if (low <= sequence && sequence <= high) { return true } }
        false
    }
}

public func managedRecoveryParseClosedCheckpoint(text: String, name: String, parent: String): ?ManagedRecoveryClosedCheckpoint {
    let fields = match (managedRecoveryParseFields(text)) { case Some(value) => value case None => return None }
    try {
        if (fields.size != 4 || fields["parent"] != parent || !managedRecoverySafeKey(fields["broker"]) || name != "${fields["broker"]}.closed") { return None }
        let issued = Int64.parse(fields["issued"])
        if (issued <= 0 || issued > 9007199254740991 || issued.toString() != fields["issued"]) { return None }
        let ranges = ArrayList<(Int64, Int64)>()
        var previous: Int64 = 0
        for (part in fields["ranges"].split(",")) {
            let bounds = part.split("-")
            if (bounds.size != 2 || ranges.size >= 257) { return None }
            let low = Int64.parse(bounds[0]); let high = Int64.parse(bounds[1])
            if (low <= previous || high < low || high > issued || low.toString() != bounds[0] || high.toString() != bounds[1]) { return None }
            ranges.add((low, high)); previous = high
        }
        if (ranges.isEmpty()) { return None }
        Some(ManagedRecoveryClosedCheckpoint(fields["broker"], ranges.toArray(), issued: issued))
    } catch (_: Exception) { None }
}

/** Strict source facts plus fresh probes; an unresolved intent is never terminal. */
public func managedRecoveryProbeRecords(directory: Path, parent: String, binding: String,
    deadline: MonoTime): ManagedProcessRecoveryReadResult {
    let fail = { status: String => ManagedProcessRecoveryReadResult(false, false, status) }
    if (!exists(directory)) { return fail("legacy_inventory_missing") }
    if (!managedRecoveryDirectorySafe(directory)) { return fail("unsafe_path") }
    let header = managedRecoveryReadText(directory.join("inventory"))
    let inventory = match (header) { case Some(value) => value case None => return fail("inventory_invalid") }
    if (inventory.isEmpty()) { return fail("inventory_changing") }
    let fields = match (managedRecoveryParseFields(inventory)) { case Some(value) => value case None => return fail("inventory_invalid") }
    if (fields.size != 3 || fields.get("parent").getOrDefault({ => "" }) != parent ||
        fields.get("binding").getOrDefault({ => "" }) != binding || fields.get("coverage").getOrDefault({ => "" }) != "broker-v1") {
        return fail("inventory_identity_mismatch")
    }
    if (exists(directory.join(".issued")) && managedRecoveryReadIssued(directory, parent) < 0) { return fail("inventory_invalid") }
    let facts = HashMap<String, HashMap<String, String>>()
    let originals = ArrayList<String>()
    let checkpoints = ArrayList<ManagedRecoveryClosedCheckpoint>()
    var rootCheckpoint = None<ManagedRecoveryClosedCheckpoint>
    var count: Int64 = 0
    try {
        var rawCount: Int64 = 0
        // Checkpoints precede the live budget: covered crash residuals and late births are not live owners.
        for (entry in Directory.readFrom(directory)) {
            rawCount += 1
            if (rawCount > 16384) { return fail("evidence_limit_exceeded") }
            if (MonoTime.now() >= deadline) { return fail("deadline_exceeded") }
            if (entry.isSymbolicLink()) { return fail("unsafe_path") }
            if (!entry.name.endsWith(".closed")) { continue }
            let text = match (managedRecoveryReadText(entry.path)) { case Some(value) => value case None => return fail("checkpoint_invalid") }
            let checkpoint = match (managedRecoveryParseClosedCheckpoint(text, entry.name, parent)) { case Some(value) => value case None => return fail("checkpoint_invalid") }
            checkpoints.add(checkpoint)
            if (checkpoint.broker == "roots") {
                if (rootCheckpoint.isSome() || checkpoint.issued > managedRecoveryReadIssued(directory, parent)) { return fail("checkpoint_invalid") }
                rootCheckpoint = Some(checkpoint)
            }
        }
        let activeCheckpoints = ArrayList<ManagedRecoveryClosedCheckpoint>()
        for (checkpoint in checkpoints) {
            if (checkpoint.broker != "roots" && rootCheckpoint.isSome() && rootCheckpoint.getOrThrow().covers(checkpoint.broker)) { continue }
            activeCheckpoints.add(checkpoint)
            let text = managedRecoveryReadText(directory.join("${checkpoint.broker}.closed")).getOrDefault({ => "" })
            originals.add("${checkpoint.broker}.closed:" + text)
        }
        for (entry in Directory.readFrom(directory)) {
            if (MonoTime.now() >= deadline) { return fail("deadline_exceeded") }
            if (entry.name == "inventory") { continue }
            if (entry.name == ".resource-claim" || entry.name == ".issued" || entry.name.startsWith(".issued.tmp-")) { continue }
            if (entry.name.endsWith(".closed")) { continue }
            if (entry.name.contains(".closed.tmp-")) { continue }
            if (entry.name == "ready") {
                let ready = managedRecoveryReadText(entry.path).getOrDefault({ => "" })
                if (ready != "managed-recovery-ready-v1\nparent:${parent}\nbinding:${binding}\n") { return fail("inventory_invalid") }
                continue
            }
            if (entry.name.endsWith(".exec_error")) {
                let key = entry.name.removeSuffix(".exec_error")
                let error = try { managedRecoveryReadExecErrorFields(directory, parent, binding, key).getOrThrow() }
                    catch (_: Exception) { return fail("resource_exec_error_pending") }
                let oldParent = parseProcessInstanceIdentity(parent).getOrThrow()
                let parentProbe = probeProcessInstance(oldParent, deadline)
                if (!parentProbe.conclusive || parentProbe.alive) { return fail("resource_exec_error_pending") }
                let births = if (error["phase"] == "spawn") { [error["helper_birth"]] } else { [error["helper_birth"], error["owner_birth"]] }
                for (birth in births) {
                    let observed = probeProcessBirthIdentity(parseProcessBirthIdentity(birth).getOrThrow(), deadline)
                    if (!observed.conclusive || observed.alive) { return fail("resource_exec_error_pending") }
                }
                if (error["phase"] != "spawn" && !managedRecoveryGroupGone(Int64.parse(error["owner_pgid"]))) {
                    return fail("resource_group_active_or_unknown")
                }
                count += 1
                if (count > managedRecoveryLimit) { return fail("evidence_limit_exceeded") }
                originals.add(entry.name + ":" + error["original_text"])
                // Covered crash residuals still need their original birth witnesses in the archive.
                for (sourceKey in [error["helper_key"], key]) {
                    let phases = if (sourceKey == key && error["phase"] == "spawn") {
                        ["intent", "not_spawned"]
                    } else { ["intent", "spawned", "birth", "terminal"] }
                    for (sourcePhase in phases) {
                        let sourceName = "${sourceKey}.${sourcePhase}"
                        let source = managedRecoveryReadText(directory.join(sourceName)).getOrThrow()
                        if (sourcePhase == "terminal" && source !=
                            managedRecoveryReadText(directory.join("${sourceKey}.spawned")).getOrThrow().replace("phase:spawned\n", "phase:terminal\n")) {
                            return fail("resource_exec_error_pending")
                        }
                        originals.add(sourceName + ":" + source)
                    }
                }
                continue
            }
            let nameParts = entry.name.split(".")
            if (nameParts.size != 2 || !managedRecoverySafeKey(nameParts[0]) ||
                !["intent", "spawned", "birth", "terminal", "not_spawned"].contains(nameParts[1])) { return fail("inventory_invalid") }
            let text = match (managedRecoveryReadText(entry.path)) { case Some(value) => value case None => return fail("inventory_invalid") }
            if (text.isEmpty()) { return fail("inventory_changing") }
            let record = match (managedRecoveryParseFields(text)) { case Some(value) => value case None => return fail("inventory_invalid") }
            let key = record.get("key").getOrDefault({ => "" })
            let phase = record.get("phase").getOrDefault({ => "" })
            if (!managedRecoveryRecordValid(record) || !managedRecoverySafeKey(key) || !["intent", "spawned", "birth", "terminal", "not_spawned"].contains(phase) ||
                entry.name != "${key}.${phase}" || record.get("parent").getOrDefault({ => "" }) != parent) { return fail("inventory_invalid") }
            var covered = false
            for (checkpoint in activeCheckpoints) { if (checkpoint.covers(key)) { covered = true } }
            if (covered) {
                // A forged/stale checkpoint cannot hide a contradictory still-live recorded birth.
                if (phase == "birth") {
                    let identity = match (parseProcessBirthIdentity(record["birth"])) { case Some(value) => value case None => return fail("inventory_invalid") }
                    let checked = probeProcessBirthIdentity(identity, deadline)
                    if (!checked.conclusive || checked.alive) { return fail("checkpoint_resource_not_terminal") }
                }
                continue
            }
            count += 1
            if (count > managedRecoveryLimit) { return fail("evidence_limit_exceeded") }
            facts[entry.name] = record
            originals.add(entry.name + ":" + text)
        }
        var resources: Int64 = 0
        for (checkpoint in activeCheckpoints) {
            if (checkpoint.broker == "roots") { continue }
            if (!facts.contains("${checkpoint.broker}.intent") || !facts.contains("${checkpoint.broker}.spawned")) { return fail("checkpoint_owner_missing") }
        }
        for ((name, intent) in facts) {
            if (!name.endsWith(".intent")) { continue }
            resources += 1
            let key = intent["key"]
            let spawned = match (facts.get("${key}.spawned")) {
                case Some(value) =>
                    if (facts.contains("${key}.not_spawned")) { return fail("inventory_invalid") }
                    value
                case None =>
                    match (facts.get("${key}.not_spawned")) {
                        case Some(value) =>
                            if (value["pid"] != "0" || value["pgid"] != "0" || facts.contains("${key}.birth") || facts.contains("${key}.terminal")) { return fail("inventory_invalid") }
                            continue
                        case None => return fail("resource_intent_incomplete")
                    }
            }
            let pid = try { Int64.parse(spawned["pid"]) } catch (_: Exception) { return fail("inventory_invalid") }
            let pgid = try { Int64.parse(spawned["pgid"]) } catch (_: Exception) { return fail("inventory_invalid") }
            if (pid <= 1 || (pgid != 0 && pgid != pid)) { return fail("inventory_invalid") }
            match (facts.get("${key}.terminal")) {
                case Some(terminal) =>
                    if (terminal["pid"] != spawned["pid"] || terminal["pgid"] != spawned["pgid"]) { return fail("inventory_identity_mismatch") }
                    if (pgid == 0) {
                        // Independent source proof says no child group can be created again.
                        // With no birth observation, only numeric absence is useful; presence stays unknown.
                        let probe = match (facts.get("${key}.birth")) {
                            case Some(birth) =>
                                let identity = match (parseProcessBirthIdentity(birth["birth"])) { case Some(value) => value case None => return fail("inventory_invalid") }
                                if (identity.pid != pid) { return fail("inventory_identity_mismatch") }
                                probeProcessBirthIdentity(identity, deadline)
                            case None => probeProcessPidPresence(pid, deadline)
                        }
                        if (!probe.conclusive || probe.alive) { return fail(if (probe.alive) { "resource_alive" } else { probe.status }) }
                    }
                case None =>
                    let birth = match (facts.get("${key}.birth")) { case Some(value) => value case None => return fail("resource_identity_unknown") }
                    let identity = match (parseProcessBirthIdentity(birth["birth"])) { case Some(value) => value case None => return fail("inventory_invalid") }
                    if (identity.pid != pid) { return fail("inventory_identity_mismatch") }
                    let probe = probeProcessBirthIdentity(identity, deadline)
                    if (!probe.conclusive) { return fail(probe.status) }
                    if (probe.alive) { return ManagedProcessRecoveryReadResult(true, false, "resource_alive") }
                    if (pgid > 1 && !managedRecoveryGroupGone(pgid)) { return fail("resource_group_active_or_unknown") }
            }
        }
        // Every phase must have an intent; extra commit/terminal facts cannot widen coverage.
        for ((_, fact) in facts) { if (!facts.contains("${fact["key"]}.intent")) { return fail("resource_intent_missing") } }
        let ordered = originals.toArray()
        sort(ordered)
        ManagedProcessRecoveryReadResult(true, true, "terminal", original: inventory + String.join(ordered, delimiter: "\n"), count: resources)
    } catch (_: Exception) { fail("inventory_read_failed") }
}
