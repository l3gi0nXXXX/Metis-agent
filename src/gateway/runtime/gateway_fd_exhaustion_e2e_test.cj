package metis.gateway.runtime

import magic.jsonable.*
import metis.core.{metisRedactSensitiveText, metisSafeUtf8Prefix}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, cliModelProviderCatalogDescriptors, cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.gateway.channels.telegram.TelegramAdapter
import metis.gateway.core.{resetGatewayChannelRuntimeObservationForTest, setGatewayChannelRuntimeWriterForTest}
import metis.gateway.process.gatewayStdioBrokerSnapshot
import metis.process.{ManagedOwnedChild, launchManagedRawChild, ProcessFdSnapshot, captureCurrentProcessFdSnapshot, managedRecoveryProbeRecords,
    probeProcessInstance, processInstanceKillSignal, processInstanceTermSignal, signalProcessInstance}
import std.collection.{ArrayList, HashMap, HashSet}
import std.convert.Parsable
import std.core.Duration
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable}
import std.fs.{Directory, File, FileInfo, FSException, OpenMode, Path, canonicalize, exists, remove}
import std.net.{IPSocketAddress, TcpServerSocket}
import std.process.{ProcessRedirect, executeWithOutput, findProcess}
import std.sync.Mutex
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}
import stdx.net.http.ClientBuilder

private let fdE2EFormalNonce = "metis-fd-formal-10000-20261102"

@When[os == "macOS"]
foreign {
    func getrlimit(resource: Int32, limit: CPointer<UInt64>): Int32
    func setrlimit(resource: Int32, limit: CPointer<UInt64>): Int32
    func fopen(path: CString, mode: CString): CPointer<Unit>
    func fclose(stream: CPointer<Unit>): Int32
    func sysctl(name: CPointer<Int32>, nameCount: UInt32, buffer: CPointer<UInt8>,
        size: CPointer<UIntNative>, replacement: CPointer<Unit>, replacementSize: UIntNative): Int32
}

private func fdE2EKernelArgumentsError(status: String, stage: String): Exception {
    try { println("FD_E2E_KERNEL_ARGUMENTS stage=${stage}") } catch (_: Exception) { () }
    Exception(status)
}

private func fdE2EParseKernelEnvironment(bytes: Array<Byte>, used: Int64): HashMap<String, String> {
    if (used < 5 || used > bytes.size || bytes.size > 1048576) {
        throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "header")
    }
    let argc = Int64(bytes[0]) | (Int64(bytes[1]) << 8) | (Int64(bytes[2]) << 16) | (Int64(bytes[3]) << 24)
    if (argc <= 0 || argc > 4096) { throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "argc") }
    var cursor: Int64 = 4
    while (cursor < used && bytes[cursor] != 0) { cursor += 1 }
    if (cursor == used) { throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "exec_path") }
    while (cursor < used && bytes[cursor] == 0) { cursor += 1 }
    for (_ in 0..argc) {
        let start = cursor
        while (cursor < used && bytes[cursor] != 0) { cursor += 1 }
        if (cursor == used) { throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "argv") }
        try { let _ = String.fromUtf8(bytes[start..cursor]) }
        catch (_: Exception) { throw fdE2EKernelArgumentsError("fixture_process_encoding_invalid", "argv_encoding") }
        cursor += 1
    }
    // Darwin may omit the environment and return exactly the complete argv region.
    if (cursor == used) { throw fdE2EKernelArgumentsError("fixture_process_arguments_unavailable", "env_absent") }
    let result = HashMap<String, String>()
    while (cursor < used && bytes[cursor] != 0) {
        let start = cursor
        while (cursor < used && bytes[cursor] != 0) { cursor += 1 }
        if (cursor == used) { throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "env_entry") }
        let entry = try { String.fromUtf8(bytes[start..cursor]) }
            catch (_: Exception) { throw fdE2EKernelArgumentsError("fixture_process_encoding_invalid", "env_encoding") }
        for (key in ["METIS_HOME", "METIS_FD_E2E_CHILD_NONCE", "METIS_FD_E2E_CHILD_MODE"]) {
            if (entry.startsWith(key + "=")) {
                if (result.contains(key)) { throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "env_duplicate") }
                result[key] = entry.removePrefix(key + "=")
            }
        }
        cursor += 1
    }
    if (cursor >= used) { throw fdE2EKernelArgumentsError("fixture_process_arguments_invalid", "env_tail") }
    result
}

@When[os == "macOS"]
private func fdE2EProcessEnvironment(pid: Int64, expectedBirth: (UInt64, UInt64)): HashMap<String, String> {
    if (pid <= 1 || pid > Int64(Int32.Max)) { throw Exception("fixture_process_arguments_invalid") }
    let before = fdE2ERequiredBirth(pid)
    if (before[0] != expectedBirth[0] || before[1] != expectedBirth[1]) { throw Exception("fixture_process_identity_changed") }
    var mib: VArray<Int32, $3> = [1, 49, Int32(pid)]
    let buffer = unsafe { LibC.malloc<Byte>(count: 1048576) }
    if (buffer.isNull()) { throw Exception("fixture_process_arguments_unavailable") }
    try {
        var size: UIntNative = 1048576
        if (unsafe { sysctl(inout mib, 3, buffer, inout size, CPointer<Unit>(), 0) } != 0 ||
            size > 1048576) { throw Exception("fixture_process_arguments_unavailable") }
        let after = fdE2ERequiredBirth(pid)
        if (after[0] != expectedBirth[0] || after[1] != expectedBirth[1]) { throw Exception("fixture_process_identity_changed") }
        let bytes = Array<Byte>(Int64(size), repeat: 0)
        for (index in 0..bytes.size) { bytes[index] = unsafe { buffer.read(index) } }
        fdE2EParseKernelEnvironment(bytes, bytes.size)
    } finally { unsafe { LibC.free(buffer) } }
}

private func fdE2EFormalEnabled(): Bool {
    getVariable("METIS_FD_FORMAL_LONG") == Some("1") &&
        getVariable("METIS_FD_FORMAL_NONCE") == Some(fdE2EFormalNonce)
}

private func fdE2ERead(path: Path): JsonObject {
    try { JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject() }
    catch (_: Exception) { JsonObject() }
}

private func fdE2EReadText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }
}

private func fdE2EInt(root: JsonObject, key: String): Int64 {
    try { Int64.parse(root.get(key).getOrThrow().toJsonString()) } catch (_: Exception) { 0 }
}

private func fdE2EString(root: JsonObject, key: String): String {
    try { root.get(key).getOrThrow().asString().getValue() } catch (_: Exception) { "" }
}

private func fdE2EBool(root: JsonObject, key: String): Bool {
    try { root.get(key).getOrThrow().asBool().getValue() } catch (_: Exception) { false }
}

private func fdE2EWriteProof(home: Path, name: String, root: JsonObject): Unit {
    File.writeTo(home.join(name), root.toJsonString().toArray())
}

private func fdE2EFileSha256(path: String): String {
    let result = executeWithOutput("/usr/bin/shasum", ["-a", "256", path])
    if (result[0] != 0) { throw Exception("fixture_binary_hash_failed") }
    let text = try { String.fromUtf8(result[1]) } catch (_: Exception) { throw Exception("fixture_hash_encoding_failed") }
    let value = text.trimAscii().split(" ")[0]
    if (value.size != 64) { throw Exception("fixture_binary_hash_invalid") }
    value
}

private func fdE2EBinarySha256(): String { fdE2EFileSha256(getCommand()) }

private func fdE2EPutSnapshot(root: JsonObject, prefix: String, value: ProcessFdSnapshot): Unit {
    root.put("${prefix}FdStatus", JsonString(value.status))
    root.put("${prefix}FdCount", value.fdCount.toJsonValue())
    root.put("${prefix}FdLimit", value.fdLimit.toJsonValue())
    root.put("${prefix}VnodeCount", value.vnodeCount.toJsonValue())
    root.put("${prefix}SocketCount", value.socketCount.toJsonValue())
    root.put("${prefix}PipeCount", value.pipeCount.toJsonValue())
    root.put("${prefix}OtherCount", value.otherCount.toJsonValue())
}

private func fdE2EChildPids(rootPid: Int64): Array<Int64> {
    if (rootPid <= 1) { return [] }
    let scan = executeWithOutput("/bin/ps", ["-axo", "pid=,ppid="])
    if (scan[0] != 0) { throw Exception("fixture_process_scan_failed") }
    let text = try { String.fromUtf8(scan[1]) } catch (_: Exception) { throw Exception("fixture_process_scan_encoding_failed") }
    let records = ArrayList<(Int64, Int64)>()
    for (line in text.split("\n")) {
        let fields = ArrayList<String>()
        for (field in line.trimAscii().replace("\t", " ").split(" ")) {
            if (!field.isEmpty()) { fields.add(field) }
        }
        if (fields.size == 2) { records.add((Int64.parse(fields[0]), Int64.parse(fields[1]))) }
        if (records.size > 8192) { throw Exception("fixture_process_scan_limit") }
    }
    let found = ArrayList<Int64>()
    found.add(rootPid)
    var cursor: Int64 = 0
    while (cursor < found.size) {
        let parent = found[cursor]
        for ((pid, ppid) in records) {
            if (ppid == parent && pid != rootPid && !found.contains(pid)) { found.add(pid) }
        }
        cursor += 1
        if (found.size > 128) { throw Exception("fixture_child_tree_limit") }
    }
    found.toArray()
}

private func fdE2EWait(timeoutMs: Int64, predicate: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.millisecond * timeoutMs
    while (MonoTime.now() < deadline) {
        if (predicate()) { return MonoTime.now() <= deadline }
        sleep(Duration.millisecond * 20)
    }
    false
}

private func fdE2EPort(): Int64 {
    var port: Int64 = 0
    try (socket = TcpServerSocket(bindAt: 0u16)) {
        socket.bind()
        let value = Int64((socket.localAddress as IPSocketAddress)?.port ?? 0u16)
        if (value == 18788 || value == 18080) { throw Exception("fixture_reserved_port") }
        port = value
    }
    port
}

private func fdE2EPortClosed(port: Int64): Bool {
    if (port <= 0) { return true }
    let result = executeWithOutput("/usr/sbin/lsof", ["-nP", "-iTCP:${port}", "-sTCP:LISTEN"])
    result[0] == 1
}

@When[os == "macOS"]
private func fdE2EPidGone(pid: Int64): Bool {
    if (pid <= 1) { return true }
    if (pid > Int64(Int32.Max)) { return false }
    unsafe { __error().write(Int32(0)) }
    let result = unsafe { kill(Int32(pid), Int32(0)) }
    // Only ESRCH proves absence. EPERM and unknown probe failures cannot authorize cleanup.
    result != 0 && unsafe { __error().read() } == 3
}

private func fdE2ESourceInventoryTerminal(home: Path, identity: Option<GatewayServeIdentity>,
    pid: Int64, birth: (UInt64, UInt64)): Bool {
    try {
        let owner = identity.getOrThrow()
        let full = owner.processIdentity.getOrThrow()
        if (pid <= 1 || owner.pid != pid || full.pid != pid || full.value8 != birth[0] || full.value9 != birth[1] ||
            owner.nonce.isEmpty()) { return false }
        let directory = home.join("gateway-resource-inventory").join("${owner.pid}-${owner.startedAtMs}")
        let result = managedRecoveryProbeRecords(directory, full.serialize(), owner.nonce,
            MonoTime.now() + Duration.second * 2)
        result.ok && result.terminal
    } catch (_: Exception) { false }
}

@When[os == "macOS"]
private class FdE2EOwnedDescendants {
    private let rootPid: Int64
    private let rootBirth: (UInt64, UInt64)
    private let home: Path
    private let nonce: String
    private let mode: String
    private let records = ArrayList<(Int64, (UInt64, UInt64))>()
    private let pendingPresence = HashSet<Int64>()
    private var valid = true

    public init(child: ManagedOwnedChild, home: Path, nonce: String, mode: String) {
        if (!child.isAlive() || !fdE2EValidateChild(home, nonce, mode)) { throw Exception("fixture_descendant_root_unbound") }
        this.rootPid = child.pid
        let birth = fdE2EBirth(child.pid).getOrThrow()
        this.rootBirth = (birth[0], birth[1])
        this.home = home; this.nonce = nonce; this.mode = mode
    }

    public func capture(child: ManagedOwnedChild): Bool {
        if (!this.valid) { return false }
        let captured = try {
            let gone = ArrayList<Int64>()
            for (pid in this.pendingPresence) { if (fdE2EPidGone(pid)) { gone.add(pid) } }
            for (pid in gone) { this.pendingPresence.remove(pid) }
            if (child.pid != this.rootPid) { throw Exception("fixture_descendant_root_not_live") }
            if (!child.isAlive()) {
                return fdE2EPidGone(this.rootPid) && this.inventoryTerminal() && this.terminal()
            }
            let root = match (fdE2EBirth(this.rootPid)) {
                case Some(value) => value
                case None => return fdE2EPidGone(this.rootPid) && this.inventoryTerminal() && this.terminal()
            }
            if (root[0] != this.rootBirth[0] || root[1] != this.rootBirth[1] ||
                !fdE2EValidateChild(this.home, this.nonce, this.mode)) { throw Exception("fixture_descendant_root_changed") }
            for (pid in fdE2EChildPids(this.rootPid)) {
                if (pid == this.rootPid || fdE2EPidGone(pid)) { continue }
                try {
                    let birth = fdE2ERequiredBirth(pid)
                    let environment = fdE2EProcessEnvironment(pid, (birth[0], birth[1]))
                    if (environment.get("METIS_HOME") != Some(this.home.toString()) ||
                        environment.get("METIS_FD_E2E_CHILD_NONCE") != Some(this.nonce) ||
                        environment.get("METIS_FD_E2E_CHILD_MODE") != Some(this.mode)) {
                        throw Exception("fixture_descendant_scope_unbound")
                    }
                    let verified = fdE2ERequiredBirth(pid)
                    if (birth[0] != verified[0] || birth[1] != verified[1]) { throw Exception("fixture_descendant_birth_changed") }
                    var known = false
                    for ((oldPid, oldBirth) in this.records) {
                        if (oldPid == pid && oldBirth[0] == birth[0] && oldBirth[1] == birth[1]) { known = true }
                    }
                    if (!known) {
                        if (this.records.size >= 256) { throw Exception("fixture_descendant_inventory_bound") }
                        this.records.add((pid, (birth[0], birth[1])))
                    }
                } catch (error: Exception) {
                    if (!fdE2EPidGone(pid)) {
                        if (["fixture_process_birth_unavailable", "fixture_process_arguments_unavailable"].contains(error.message)) {
                            if (this.pendingPresence.size >= 256 && !this.pendingPresence.contains(pid)) {
                                throw Exception("fixture_descendant_inventory_bound")
                            }
                            this.pendingPresence.add(pid)
                            println("FD_E2E_CAPTURE_PENDING status=${error.message}")
                        } else { throw error }
                    }
                }
            }
            true
        } catch (error: Exception) {
            let known = ["fixture_descendant_root_not_live", "fixture_descendant_root_changed", "fixture_descendant_scope_unbound",
                "fixture_descendant_birth_changed", "fixture_descendant_inventory_bound", "fixture_process_identity_changed",
                "fixture_process_arguments_invalid", "fixture_process_arguments_unavailable", "fixture_process_encoding_invalid"]
            let status = if (known.contains(error.message)) { error.message } else { "fixture_descendant_probe_failed" }
            println("FD_E2E_CAPTURE status=${status}")
            false
        }
        if (!captured) { this.valid = false }
        captured
    }

    public func terminal(): Bool {
        if (!this.valid) { return false }
        for (pid in this.pendingPresence) { if (!fdE2EPidGone(pid)) { return false } }
        for ((pid, birth) in this.records) {
            if (fdE2EPidGone(pid)) { continue }
            match (fdE2EBirth(pid)) {
                case Some(current) => if (current[0] == birth[0] && current[1] == birth[1]) { return false }
                case None => return false
            }
        }
        true
    }

    public func count(): Int64 { this.records.size }

    public func captureValid(): Bool { this.valid }

    public func inventoryTerminal(): Bool {
        for (name in ["gateway-serve.lock", "gateway-serve.stop-complete"]) {
            let identity = gatewayParseServeIdentity(fdE2EReadText(this.home.join(name)))
            if (fdE2ESourceInventoryTerminal(this.home, identity, this.rootPid, this.rootBirth)) { return true }
        }
        false
    }
}

@When[os == "macOS"]
private func fdE2EWaitOwnedExit(child: ManagedOwnedChild, descendants: FdE2EOwnedDescendants, seconds: Int64): Int64 {
    let deadline = MonoTime.now() + Duration.second * seconds
    var nextCapture = MonoTime.now()
    while (!fdE2EPidGone(child.pid) && MonoTime.now() < deadline) {
        if (MonoTime.now() >= nextCapture) {
            // Join an exited owned handle before the final inventory/native terminal assertions.
            if (!descendants.capture(child) && !descendants.captureValid()) { throw Exception("fixture_descendant_capture_failed") }
            nextCapture = MonoTime.now() + Duration.second
        }
        sleep(Duration.millisecond * 50)
    }
    if (!fdE2EPidGone(child.pid)) { throw Exception("fixture_child_exit_deadline") }
    child.wait(timeout: Some(Duration.second * 5))
}

private func fdE2EValidateChild(home: Path, nonce: String, mode: String): Bool {
    if ((mode != "short" && mode != "long" && mode != "joint" && mode != "positive32") || nonce.isEmpty() || nonce.size > 128 ||
        home.parent.toString() != "/private/tmp" || !home.fileName.startsWith("metis-fd-e2e-")) { return false }
    try {
        if (canonicalize(home.parent).toString() != "/private/tmp" ||
            !FileInfo(home).isDirectory() || FileInfo(home).isSymbolicLink() ||
            FileInfo(home.join("control.json")).isSymbolicLink()) { return false }
        let control = fdE2ERead(home.join("control.json"))
        fdE2EString(control, "nonce") == nonce && fdE2EString(control, "mode") == mode &&
            fdE2EInt(control, "parentPid") > 1
    } catch (_: Exception) { false }
}

private class FdE2EOwnedBroker {
    public let pid: Int64
    public let parentPid: Int64
    public let birth: (UInt64, UInt64)
    public let parentBirth: (UInt64, UInt64)
    public let home: Path
    public let nonce: String
    public let mode: String
    public let script: String

    public init(pid: Int64, parentPid: Int64, birth: (UInt64, UInt64), parentBirth: (UInt64, UInt64),
        home: Path, nonce: String, mode: String, script: String) {
        this.pid = pid
        this.parentPid = parentPid
        this.birth = birth
        this.parentBirth = parentBirth
        this.home = home
        this.nonce = nonce
        this.mode = mode
        this.script = script
    }
}

@When[os == "macOS"]
private func fdE2EBirth(pid: Int64): Option<(UInt64, UInt64, Int64)> {
    if (pid <= 1 || pid > Int64(Int32.Max)) { return None<(UInt64, UInt64, Int64)> }
    // Reuse this test package's proc_pidinfo declaration from the existing resource test.
    // Darwin proc_bsdinfo is 136 bytes; ppid is UInt32 at byte 16, start at 120/128.
    var info: VArray<UInt64, $17> = VArray<UInt64, $17>(repeat: 0)
    let size = unsafe { proc_pidinfo(Int32(pid), Int32(3), UInt64(0), inout info, Int32(136)) }
    if (size != 136) { return None<(UInt64, UInt64, Int64)> }
    Some((info[15], info[16], Int64(info[2] & UInt64(0xffffffff))))
}

@When[os == "macOS"]
private func fdE2ERequiredBirth(pid: Int64): (UInt64, UInt64, Int64) {
    match (fdE2EBirth(pid)) {
        case Some(value) => value
        case None => throw Exception("fixture_process_birth_unavailable")
    }
}

private func fdE2EBrokerBinding(owned: FdE2EOwnedBroker): Bool {
    try {
        if (!fdE2EValidateChild(owned.home, owned.nonce, owned.mode) ||
            owned.script != CliConfig.cwd.join("scripts").join("metis-stdio-broker.mjs").toString()) { return false }
        let control = fdE2ERead(owned.home.join("control.json"))
        if (fdE2EInt(control, "parentPid") != Int64(getProcessId())) { return false }
        let process = findProcess(owned.pid)
        if (!process.arguments.contains(owned.script)) { return false }
        let environment = fdE2EProcessEnvironment(owned.pid, owned.birth)
        environment.get("METIS_HOME") == Some(owned.home.toString()) &&
            environment.get("METIS_FD_E2E_CHILD_NONCE") == Some(owned.nonce) &&
            environment.get("METIS_FD_E2E_CHILD_MODE") == Some(owned.mode)
    } catch (_: Exception) { false }
}

@When[os == "macOS"]
private func fdE2ECaptureBroker(child: ManagedOwnedChild, home: Path, nonce: String, mode: String): Option<FdE2EOwnedBroker> {
    try {
        if (!child.isAlive()) { return None<FdE2EOwnedBroker> }
        let pid = fdE2EInt(fdE2ERead(home.join("progress.json")), "brokerPid")
        if (!fdE2EChildPids(child.pid).contains(pid)) { return None<FdE2EOwnedBroker> }
        let parentBirth = fdE2EBirth(child.pid).getOrThrow()
        let birth = fdE2EBirth(pid).getOrThrow()
        if (birth[2] != child.pid) { return None<FdE2EOwnedBroker> }
        let owned = FdE2EOwnedBroker(pid, child.pid, (birth[0], birth[1]), (parentBirth[0], parentBirth[1]),
            home, nonce, mode, CliConfig.cwd.join("scripts").join("metis-stdio-broker.mjs").toString())
        if (!fdE2EBrokerBinding(owned) || !child.isAlive()) { return None<FdE2EOwnedBroker> }
        Some(owned)
    } catch (_: Exception) { None<FdE2EOwnedBroker> }
}

@When[os == "macOS"]
private func fdE2EBrokerMatches(owned: FdE2EOwnedBroker): Bool {
    try {
        let birth = fdE2EBirth(owned.pid).getOrThrow()
        if (birth[0] != owned.birth[0] || birth[1] != owned.birth[1] || !fdE2EBrokerBinding(owned)) { return false }
        // Original ownership was established while the child was alive. A live parent must
        // still have its captured birth; an orphan must retain the inherited nonce binding.
        if (!fdE2EPidGone(owned.parentPid)) {
            let parentBirth = fdE2EBirth(owned.parentPid).getOrThrow()
            if (parentBirth[0] != owned.parentBirth[0] || parentBirth[1] != owned.parentBirth[1] || birth[2] != owned.parentPid) { return false }
        } else if (birth[2] != 1) { return false }
        true
    } catch (_: Exception) { false }
}

@When[os == "macOS"]
private func fdE2EFallbackBroker(owned: FdE2EOwnedBroker): Bool {
    if (fdE2EPidGone(owned.pid)) { return true }
    if (!fdE2EBrokerMatches(owned)) { return false }
    let _ = unsafe { kill(Int32(owned.pid), Int32(15)) }
    if (fdE2EWait(2000, { => fdE2EPidGone(owned.pid) })) { return true }
    if (!fdE2EBrokerMatches(owned)) { return false }
    let _ = unsafe { kill(Int32(owned.pid), Int32(9)) }
    fdE2EWait(5000, { => fdE2EPidGone(owned.pid) })
}

private func fdE2EEventCount(home: Path, kind: String, chatId!: String = ""): Int64 {
    let path = home.join("events.jsonl")
    if (!exists(path)) { return 0 }
    let text = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { return 0 }
    var count: Int64 = 0
    for (line in text.split("\n")) {
        try {
            let row = JsonValue.fromStr(line).asObject()
            if (fdE2EString(row, "kind") == kind && (chatId.isEmpty() || fdE2EString(row, "chatId") == chatId)) { count += 1 }
        } catch (_: Exception) { () }
    }
    count
}

private func fdE2EHeartbeatCount(): Int64 {
    let root = fdE2ERead(Path(gatewayNodeRegistryPath()))
    try {
        let items = root.get("nodes").getOrThrow().asObject().get("items").getOrThrow().asArray()
        if (items.size() == 0) { return 0 }
        fdE2EInt(items[0].asObject(), "heartbeatCount")
    } catch (_: Exception) { 0 }
}

/** All descriptors and the lowered limit exist only inside the explicitly selected test child. */
@When[os == "macOS"]
private func fdE2EExhaustWrite(path: Path, bytes: Array<Byte>): ProcessFdSnapshot {
    var original: VArray<UInt64, $2> = [0, 0]
    if (unsafe { getrlimit(Int32(8), inout original) } != 0) { throw Exception("fixture_limit_read_failed") }
    var limited: VArray<UInt64, $2> = [min(original[0], UInt64(128)), original[1]]
    let streams = ArrayList<CPointer<Unit>>()
    let nullPath = unsafe { LibC.mallocCString("/dev/null") }
    let mode = unsafe { LibC.mallocCString("r") }
    var changed = false
    var verified = false
    var pressure = ProcessFdSnapshot("unknown")
    try {
        if (unsafe { setrlimit(Int32(8), inout limited) } != 0) { throw Exception("fixture_limit_set_failed") }
        changed = true
        for (_ in 0..256) {
            let stream = unsafe { fopen(nullPath, mode) }
            if (stream.isNull()) { break }
            streams.add(stream)
        }
        pressure = captureCurrentProcessFdSnapshot()
        try { File.writeTo(path, bytes) }
        catch (e: Exception) { verified = e.message.contains("Too many open files") }
    } finally {
        for (stream in streams) { let _ = unsafe { fclose(stream) } }
        let restored = if (changed) { unsafe { setrlimit(Int32(8), inout original) } } else { Int32(0) }
        unsafe { LibC.free(nullPath); LibC.free(mode) }
        if (restored != 0) { throw Exception("fixture_limit_restore_failed") }
    }
    if (!verified || pressure.status != "ok") { throw Exception("fixture_native_emfile_not_verified") }
    pressure
}

private class FdE2EObservationProbe {
    private let lock = Mutex()
    private let measurementLock = Mutex()
    private let path: Path
    private var lastPull: Int64 = 0
    private var lastMonitor: Int64 = 0
    private var rounds: Int64 = 0
    private var faults: Int64 = 0
    private var pressureSnapshot = ProcessFdSnapshot("unknown")

    public init(home: Path) { this.path = home.join("gateway-channel-runtime-state.json") }

    @When[os == "macOS"]
    public func persist(path: Path, bytes: Array<Byte>): Unit {
        synchronized(this.measurementLock) { this.persistMeasured(path, bytes) }
    }

    @When[os == "macOS"]
    private func persistMeasured(path: Path, bytes: Array<Byte>): Unit {
        if (path.toString() != this.path.toString()) { throw Exception("fixture_writer_path_mismatch") }
        let root = try { JsonValue.fromStr(String.fromUtf8(bytes)).asObject() }
            catch (_: Exception) { throw Exception("fixture_writer_invalid_encoding") }
        let monitorTick = synchronized(this.lock) {
            var monitorTick = false
            let accounts = (root.get("accounts") ?? JsonArray([])).asArray()
            if (accounts.size() > 0) {
                let row = accounts[0].asObject()
                let pull = fdE2EInt(row, "lastPullAtMs")
                let monitor = fdE2EInt(row, "lastMonitorAtMs")
                if (this.lastPull == 0) { this.lastPull = pull }
                else if (pull > this.lastPull) { this.lastPull = pull; this.rounds += 1 }
                if (this.lastMonitor == 0) { this.lastMonitor = monitor }
                else if (monitor > this.lastMonitor) {
                    this.lastMonitor = monitor
                    monitorTick = true
                }
            }
            monitorTick
        }
        let inject = synchronized(this.lock) {
            monitorTick && (this.rounds == 2 || this.rounds == 52 || this.rounds == 102 ||
                this.rounds > 0 && this.rounds % 1000 == 0)
        }
        if (inject) {
            let pressure = fdE2EExhaustWrite(path, bytes)
            synchronized(this.lock) {
                this.faults += 1
                this.pressureSnapshot = pressure
            }
            throw FSException("fixture_native_emfile_verified")
        }
        File.writeTo(path, bytes)
    }

    @When[os == "macOS"]
    public func sampleQuietFd(): ProcessFdSnapshot {
        // Never acquire Gateway/state/log locks here: the writer enters this mutex from state I/O.
        synchronized(this.measurementLock) { captureCurrentProcessFdSnapshot() }
    }

    public func snapshot(): JsonObject {
        synchronized(this.lock) {
            let root = JsonObject()
            root.put("pollRounds", this.rounds.toJsonValue())
            root.put("nativeEmfileCount", this.faults.toJsonValue())
            fdE2EPutSnapshot(root, "pressure", this.pressureSnapshot)
            root
        }
    }
}

private func fdE2EConfigureOwnedGateway(home: Path, gatewayPort: Int64, dependencyPort: Int64): Unit {
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    Directory.create(home.join("workspace"))
    Directory.create(home.join("curl"))
    Directory.create(home.join("zsh"))
    File.writeTo(home.join("curl").join(".curlrc"), [])
    File.writeTo(home.join("curl").join("curlrc"), [])
    CliConfig.workspaceDirOverride = home.join("workspace").toString()
    let _ = MetisConfigManager.setWorkspace(CliConfig.workspaceDirOverride)
    var settings = CliSettingManager.readGatewaySettings()
    settings.enabled = true
    settings.port = gatewayPort
    settings.bind = "loopback"
    settings.customBindHost = ""
    settings.http.endpoints.chatCompletions.enabled = true
    settings.cronEnabled = false
    settings.controlUi.enabled = false
    settings.feishu.enabled = false
    settings.qq.enabled = false
    settings.servicePlugins = []
    settings.logging.file = home.join("gateway.log").toString()
    settings.logging.level = "info"
    settings.logging.consoleLevel = "off"
    settings.auth.mode = "none"
    var telegram = settings.telegram
    telegram.enabled = true
    telegram.botToken = "123456:FAKE-S5"
    telegram.dmPolicy = "open"
    telegram.allowFrom = ["*"]
    telegram.commandsNative = "off"
    telegram.apiRoot = "http://127.0.0.1:${dependencyPort}"
    telegram.timeoutSeconds = 1
    var network = telegram.network
    network.dangerouslyAllowPrivateNetwork = true
    telegram.network = network
    settings.telegram = telegram
    settings.channelModels["telegram"] = "openai:gpt-5.4"
    let _ = MetisConfigManager.setGatewaySettings(settings)
    let _ = MetisConfigManager.setPrimaryModelRef("openai:gpt-5.4")
    let _ = MetisConfigManager.setProviderApiKey("openai", "fake-fd-model-key")
    let _ = MetisConfigManager.setProviderBaseUrl("openai", "http://127.0.0.1:${dependencyPort}/v1")
    for (key in cliProviderApiKeyEnvAliases("openai")) { setVariable(key, "fake-fd-model-key") }
    for (key in cliProviderBaseUrlEnvAliases("openai")) { setVariable(key, "http://127.0.0.1:${dependencyPort}/v1") }
    CliSettingManager.invalidate()
}

private func fdE2ERequestStop(home: Path): Bool {
    let lock = home.join("gateway-serve.lock")
    let payload = try { String.fromUtf8(File.readFrom(lock)) } catch (_: Exception) { return false }
    match (gatewayParseServeIdentity(payload)) {
        case Some(identity) => if (identity.pid != Int64(getProcessId())) { return false }
        case None => return false
    }
    File.writeTo(home.join("gateway-serve.stop-request"),
        (payload + "requestedAtMs:${DateTime.now().toUnixTimeStamp().toMilliseconds()}\n").toArray())
    true
}

@When[os == "macOS"]
private func fdE2ERunChild(home: Path, mode: String): Unit {
    let control = fdE2ERead(home.join("control.json"))
    let port = fdE2EInt(control, "gatewayPort")
    fdE2EConfigureOwnedGateway(home, port, fdE2EInt(control, "dependencyPort"))
    let result = JsonObject()
    result.put("ok", false.toJsonValue())
    result.put("nonce", JsonString(fdE2EString(control, "nonce")))
    result.put("mode", JsonString(fdE2EString(control, "mode")))
    result.put("binarySha256", JsonString(fdE2EBinarySha256()))
    let serving = spawn { runGatewayCli(["run"]) }
    var requestedStop = false
    try {
        if (!fdE2EWait(30000, { => fdE2EBool(gatewayRuntimeSnapshot(), "running") })) { throw Exception("fixture_ready_failed") }
        let gateway = gatewayActiveService().getOrThrow()
        let adapter = (gateway.getAdapter("telegram").getOrThrow() as TelegramAdapter).getOrThrow()
        adapter.simulateIncomingText("fd-warm", "user:9001", "9001", "warm \u{4e2d}\u{6587}\u{1f600}")
        if (!fdE2EWait(20000, { => fdE2EEventCount(home, "telegram_send", chatId: "9001") == 1 })) {
            throw Exception("fixture_warm_business_failed")
        }
        if (!fdE2EWait(20000, { => fdE2EHeartbeatCount() >= 2 })) { throw Exception("fixture_warm_heartbeat_failed") }
        if (!gateway.awaitInboundIdleForTest()) { throw Exception("fixture_warm_not_idle") }
        let baseline = captureCurrentProcessFdSnapshot()
        if (baseline.status != "ok") { throw Exception("fixture_fd_probe_unavailable") }
        let warmHeartbeats = fdE2EHeartbeatCount()
        result.put("brokerPid", fdE2EInt(gatewayStdioBrokerSnapshot(), "brokerPid").toJsonValue())
        let probe = FdE2EObservationProbe(home)
        if (mode != "positive32") {
            setGatewayChannelRuntimeWriterForTest(Some({ path, bytes => probe.persist(path, bytes) }))
        }
        let target: Int64 = if (mode == "long") { 10000 } else { 120 }
        let measurementStarted = MonoTime.now()
        let deadline = MonoTime.now() + Duration.second * if (mode == "long") { 3000 } else { 180 }
        var sent = false
        var maxActive: Int64 = 0
        var idlePeak = baseline.fdCount
        var lastProgress: Int64 = -1
        if (mode == "positive32") {
            let samples = JsonArray()
            let progress = JsonObject()
            progress.put("brokerPid", fdE2EInt(gatewayStdioBrokerSnapshot(), "brokerPid").toJsonValue())
            fdE2EWriteProof(home, "progress.json", progress)
            if (!fdE2EWait(10000, { => fdE2EString(fdE2ERead(home.join("parent-captured.json")), "nonce") ==
                fdE2EString(control, "nonce") })) { throw Exception("fixture_parent_capture_not_confirmed") }
            for (round in 1..=32) {
                if (MonoTime.now() >= deadline) { throw Exception("fixture_positive_deadline") }
                adapter.simulateIncomingText("fd-positive-${round}", "user:9003", "9003", "positive ${round} 中文😀")
                if (!fdE2EWait(20000, { =>
                    fdE2EEventCount(home, "telegram_send", chatId: "9003") == round &&
                    fdE2EEventCount(home, "model_response") == round + 1
                })) { throw Exception("fixture_positive_business_failed") }
                if (!gateway.awaitInboundIdleForTest(timeoutMs: 10000)) { throw Exception("fixture_positive_not_idle") }
                let operational = gateway.operationalSnapshot()
                if (fdE2EInt(operational, "inboundActiveCount") != 0 ||
                    fdE2EInt(operational, "inboundQueueDepth") != 0) { throw Exception("fixture_positive_worker_not_quiescent") }
                let current = captureCurrentProcessFdSnapshot()
                if (current.status != "ok" || current.fdLimit != baseline.fdLimit ||
                    current.fdCount > baseline.fdCount + 2) { throw Exception("fixture_positive_fd_growth") }
                idlePeak = max(idlePeak, current.fdCount)
                let sample = JsonObject()
                sample.put("round", round.toJsonValue())
                sample.put("actualModelResponses", fdE2EEventCount(home, "model_response").toJsonValue())
                sample.put("actualTelegramSends", fdE2EEventCount(home, "telegram_send", chatId: "9003").toJsonValue())
                sample.put("active", fdE2EInt(operational, "inboundActiveCount").toJsonValue())
                sample.put("queued", fdE2EInt(operational, "inboundQueueDepth").toJsonValue())
                fdE2EPutSnapshot(sample, "idle", current)
                samples.add(sample)
                result.put("positiveRounds", round.toJsonValue())
                progress.put("positiveRounds", round.toJsonValue())
                fdE2EWriteProof(home, "progress.json", progress)
                if (MonoTime.now() >= deadline) { throw Exception("fixture_positive_deadline") }
            }
            result.put("positiveSamples", samples)
            result.put("warmBusinessSends", fdE2EEventCount(home, "telegram_send", chatId: "9001").toJsonValue())
        } else {
            var attemptedQuietBuckets: Int64 = 0
            var nonquiescentBuckets: Int64 = 0
            var validQuietSamples: Int64 = 0
            var quietPeak = baseline.fdCount
            result.put("quietStatus", JsonString("not_sampled"))
            result.put("attemptedQuietBuckets", Int64(0).toJsonValue())
            result.put("nonquiescentBuckets", Int64(0).toJsonValue())
            result.put("validQuietSamples", Int64(0).toJsonValue())
            result.put("quietPeakFdCount", quietPeak.toJsonValue())
            if (baseline.fdLimit <= 0) { throw Exception("fixture_fd_probe_unavailable") }
            while ((fdE2EInt(probe.snapshot(), "pollRounds") < target ||
                (MonoTime.now() - measurementStarted).toMilliseconds() < target * 200) && MonoTime.now() < deadline) {
                let snapshot = probe.snapshot()
                let rounds = fdE2EInt(snapshot, "pollRounds")
                if (!sent && fdE2EInt(snapshot, "nativeEmfileCount") > 0) {
                    adapter.simulateIncomingText("fd-business", "user:9002", "9002", "business \u{4e2d}\u{6587}\u{1f600}")
                    sent = true
                }
                let operational = gateway.operationalSnapshot()
                maxActive = max(maxActive, fdE2EInt(operational, "inboundActiveCount"))
                if (maxActive > 8 || fdE2EInt(operational, "inboundQueueDepth") > 128) { throw Exception("fixture_worker_bound_exceeded") }
                if (rounds / 50 != lastProgress) {
                    lastProgress = rounds / 50
                    attemptedQuietBuckets += 1
                    result.put("attemptedQuietBuckets", attemptedQuietBuckets.toJsonValue())
                    if (fdE2EInt(operational, "inboundActiveCount") == 0 && fdE2EInt(operational, "inboundQueueDepth") == 0) {
                        let current = probe.sampleQuietFd()
                        result.put("quietStatus", JsonString(current.status))
                        result.put("quietFdLimit", current.fdLimit.toJsonValue())
                        if (current.status != "ok" || current.fdLimit != baseline.fdLimit) { throw Exception("fixture_quiet_fd_probe_failed") }
                        fdE2EPutSnapshot(result, "quietLast", current)
                        if (current.fdCount > baseline.fdCount + 2) { throw Exception("fixture_quiet_fd_growth") }
                        validQuietSamples += 1
                        quietPeak = max(quietPeak, current.fdCount)
                        idlePeak = max(idlePeak, current.fdCount)
                        fdE2EPutSnapshot(snapshot, "quiet", current)
                        snapshot.put("sampleFdStatus", JsonString("ok"))
                        snapshot.put("sampleFdCount", current.fdCount.toJsonValue())
                    } else {
                        nonquiescentBuckets += 1
                        snapshot.put("sampleFdStatus", JsonString("non_quiescent"))
                    }
                    result.put("nonquiescentBuckets", nonquiescentBuckets.toJsonValue())
                    result.put("validQuietSamples", validQuietSamples.toJsonValue())
                    result.put("quietPeakFdCount", quietPeak.toJsonValue())
                    snapshot.put("attemptedQuietBuckets", attemptedQuietBuckets.toJsonValue())
                    snapshot.put("nonquiescentBuckets", nonquiescentBuckets.toJsonValue())
                    snapshot.put("validQuietSamples", validQuietSamples.toJsonValue())
                    snapshot.put("quietPeakFdCount", quietPeak.toJsonValue())
                    snapshot.put("warmFdCount", baseline.fdCount.toJsonValue())
                    snapshot.put("heartbeatCount", fdE2EHeartbeatCount().toJsonValue())
                    snapshot.put("brokerPid", fdE2EInt(gatewayStdioBrokerSnapshot(), "brokerPid").toJsonValue())
                    fdE2EWriteProof(home, "progress.json", snapshot)
                }
                sleep(Duration.millisecond * 20)
            }
            if (fdE2EInt(probe.snapshot(), "pollRounds") < target) { throw Exception("fixture_poll_target_not_reached") }
            if (validQuietSamples <= 0 || attemptedQuietBuckets != nonquiescentBuckets + validQuietSamples ||
                quietPeak > baseline.fdCount + 2) { throw Exception("fixture_quiet_samples_incomplete") }
        }
        setGatewayChannelRuntimeWriterForTest(None<(Path, Array<Byte>) -> Unit>)
        if (!gateway.awaitInboundIdleForTest(timeoutMs: 10000)) { throw Exception("fixture_final_not_idle") }
        let finalSnapshot = if (mode == "positive32") { captureCurrentProcessFdSnapshot() } else { probe.sampleQuietFd() }
        if (mode != "positive32") {
            result.put("quietFinalStatus", JsonString(finalSnapshot.status))
            result.put("quietFinalLimit", finalSnapshot.fdLimit.toJsonValue())
            if (finalSnapshot.status != "ok" || finalSnapshot.fdLimit != baseline.fdLimit) { throw Exception("fixture_quiet_fd_probe_failed") }
            fdE2EPutSnapshot(result, "quietFinal", finalSnapshot)
            if (finalSnapshot.fdCount > baseline.fdCount + 2) { throw Exception("fixture_quiet_fd_growth") }
            result.put("quietFinalCount", finalSnapshot.fdCount.toJsonValue())
            result.put("quietPeakFdCount", max(fdE2EInt(result, "quietPeakFdCount"), finalSnapshot.fdCount).toJsonValue())
        }
        let proof = probe.snapshot()
        for ((key, value) in proof.getFields()) { result.put(key, value) }
        result.put("mode", JsonString(mode))
        result.put("measurementMs", (MonoTime.now() - measurementStarted).toMilliseconds().toJsonValue())
        fdE2EPutSnapshot(result, "warm", baseline)
        result.put("samplePeakFdCount", idlePeak.toJsonValue())
        fdE2EPutSnapshot(result, "final", finalSnapshot)
        result.put("fdLimit", finalSnapshot.fdLimit.toJsonValue())
        result.put("heartbeatDelta", (fdE2EHeartbeatCount() - warmHeartbeats).toJsonValue())
        if (mode != "positive32") { result.put("maxInboundActive", maxActive.toJsonValue()) }
        else {
            result.put("quiescentActive", Int64(0).toJsonValue())
            result.put("quiescentQueued", Int64(0).toJsonValue())
        }
        result.put("modelResponses", fdE2EEventCount(home, "model_response").toJsonValue())
        result.put("businessSends", fdE2EEventCount(home, "telegram_send",
            chatId: if (mode == "positive32") { "9003" } else { "9002" }).toJsonValue())
        result.put("brokerPid", fdE2EInt(gatewayStdioBrokerSnapshot(), "brokerPid").toJsonValue())
        let builder = ClientBuilder()
        builder.readTimeout(Duration.second * 2)
        let client = builder.build()
        try { result.put("readyStatus", Int64(client.get("http://127.0.0.1:${port}/readyz").status).toJsonValue()) }
        finally { client.close() }
        let logs = fdE2EReadText(home.join("gateway.log"))
        result.put("degraded", logs.contains("channel.runtime.persistence.degraded").toJsonValue())
        result.put("recovered", logs.contains("channel.runtime.persistence.recovered").toJsonValue())
        let observationOk = if (mode == "positive32") {
            fdE2EInt(result, "positiveRounds") == 32 && fdE2EInt(result, "warmBusinessSends") == 1 &&
                fdE2EInt(result, "businessSends") == 32 && fdE2EInt(result, "modelResponses") == 33 &&
                fdE2EInt(result, "readyStatus") == 200 && finalSnapshot.status == "ok" &&
                finalSnapshot.fdLimit == baseline.fdLimit && finalSnapshot.fdCount <= baseline.fdCount + 2
        } else {
            fdE2EInt(result, "businessSends") == 1 && fdE2EInt(result, "modelResponses") == 2 &&
                fdE2EInt(result, "heartbeatDelta") >= 2 && fdE2EInt(result, "nativeEmfileCount") >= 1 &&
                fdE2EInt(result, "validQuietSamples") > 0 && fdE2EInt(result, "quietPeakFdCount") <= baseline.fdCount + 2 &&
                fdE2EString(result, "quietFinalStatus") == "ok" && fdE2EInt(result, "quietFinalLimit") == baseline.fdLimit &&
                fdE2EInt(result, "readyStatus") == 200 && fdE2EBool(result, "degraded") && fdE2EBool(result, "recovered") &&
                finalSnapshot.status == "ok" && finalSnapshot.fdLimit == baseline.fdLimit && finalSnapshot.fdCount <= baseline.fdCount + 2
        }
        result.put("observationOk", observationOk.toJsonValue())
        if (mode == "joint") {
            result.put("ok", observationOk.toJsonValue())
            fdE2EWriteProof(home, "joint-ready.json", result)
            @Expect(observationOk, true)
            let hardExitDeadline = MonoTime.now() + Duration.second * 120
            while (MonoTime.now() < hardExitDeadline && fdE2EBool(gatewayRuntimeSnapshot(), "running")) {
                sleep(Duration.millisecond * 50)
            }
            throw Exception("fixture_joint_hard_exit_not_received")
        }
        requestedStop = fdE2ERequestStop(home)
        result.put("normalStopRequested", requestedStop.toJsonValue())
        result.put("serveExit", serving.get(Duration.second * 40).toJsonValue())
        let completion = try { String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))) }
            catch (_: Exception) { "" }
        result.put("fullTerminal", completion.contains("fullTerminal:1").toJsonValue())
        let ok = requestedStop && fdE2EInt(result, "serveExit") == 0 && fdE2EBool(result, "fullTerminal") &&
            observationOk
        result.put("ok", ok.toJsonValue())
        @Expect(ok, true)
    } catch (e: Exception) {
        result.put("ok", false.toJsonValue())
        result.put("failureStatus", JsonString(if (e.message.startsWith("fixture_") && e.message.size <= 128) {
            e.message
        } else { "fixture_unexpected_exception" }))
        throw e
    } finally {
        try { fdE2EWriteProof(home, "formal-result.json", result) }
        catch (_: Exception) { println("FD_E2E_FORMAL_PROOF_WRITE_FAILED") }
        resetGatewayChannelRuntimeObservationForTest()
        if (!requestedStop) {
            try { let _ = fdE2ERequestStop(home) } catch (_: Exception) { () }
        }
        try { let _ = serving.get(Duration.second * 40) } catch (_: Exception) { () }
    }
}

private func fdE2EFixtureEnvironment(home: Path): HashMap<String, String> {
    let environment = HashMap(getVariables())
    for (descriptor in cliModelProviderCatalogDescriptors()) {
        for (key in descriptor.apiKeyEnvAliases) { environment.remove(key) }
        for (key in descriptor.baseUrlEnvAliases) { environment.remove(key) }
    }
    for ((key, _) in getVariables()) {
        let upper = key.toAsciiUpper()
        if (upper.contains("API_KEY") || upper.endsWith("_TOKEN") || upper.endsWith("_SECRET") ||
            upper.endsWith("_PASSWORD") || upper.endsWith("_CREDENTIALS")) { environment.remove(key) }
    }
    environment["METIS_HOME"] = home.toString()
    environment["METIS_CJPM_ROOT"] = CliConfig.cwd.toString()
    environment["NO_PROXY"] = "127.0.0.1,localhost"
    environment["no_proxy"] = "127.0.0.1,localhost"
    environment["CURL_HOME"] = home.join("curl").toString()
    environment["XDG_CONFIG_HOME"] = home.join("curl").toString()
    environment["ZDOTDIR"] = home.join("zsh").toString()
    for (key in ["METIS_LOG_FILE", "METIS_LOG_LEVEL", "METIS_CONSOLE_LEVEL", "METIS_STDIO_BROKER_SCRIPT",
        "METIS_STDIO_BROKER_NODE_COMMAND", "METIS_STDIO_BROKER_TEST_MODE", "METIS_GATEWAY_CLI_MODE",
        "METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_MODE", "METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_NONCE", "METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_POLLS",
        "METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
        "TELEGRAM_BOT_TOKEN", "METIS_TELEGRAM_BOT_TOKEN"]) { environment.remove(key) }
    environment
}

private func fdE2ELaunchChild(home: Path, mode: String, caseName: String, nonce: String): ManagedOwnedChild {
    let environment = fdE2EFixtureEnvironment(home)
    environment["METIS_FD_E2E_CHILD_HOME"] = home.toString()
    environment["METIS_FD_E2E_CHILD_NONCE"] = nonce
    environment["METIS_FD_E2E_CHILD_MODE"] = mode
    environment["cjHeapSize"] = "2GB"
    var child = None<ManagedOwnedChild>
    try (output = File(home.join("child.stdout"), OpenMode.Write), error = File(home.join("child.stderr"), OpenMode.Write)) {
        child = Some(launchManagedRawChild(getCommand(), ["--filter=GatewayFdExhaustionE2ETest.${caseName}", "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], environment: environment,
            stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
    }
    child.getOrThrow()
}

private func fdE2EStopProcess(process: Option<ManagedOwnedChild>): Bool {
    match (process) {
        case None => true
        case Some(child) =>
            try {
                if (child.isAlive()) { try { child.terminate(force: true) } catch (_: Exception) { () } }
                let _ = child.wait(timeout: Some(Duration.second * 5))
                child.closeStreams()
                !child.isAlive() && child.streamsAreClosed()
            } catch (_: Exception) { false }
    }
}

private func fdE2EPrintFailure(home: Path): Unit {
    let files = ArrayList<Path>()
    files.add(home.join("child.stdout")); files.add(home.join("child.stderr"))
    try {
        for (entry in Directory.readFrom(home)) {
            if (files.size >= 8) { break }
            if (entry.name.startsWith("joint-") && (entry.name.endsWith(".stdout") || entry.name.endsWith(".stderr"))) { files.add(entry.path) }
        }
    } catch (_: Exception) { () }
    for (path in files) {
        var redacted = metisRedactSensitiveText(fdE2EReadText(path)).replace(home.toString(), "<fixture-home>")
            .replace(CliConfig.cwd.toString(), "<project>")
        for (key in ["CANGJIE_HOME", "MAGIC_PATH"]) {
            let value = getVariable(key) ?? ""
            if (!value.isEmpty()) { redacted = redacted.replace(value, "<dependency>") }
        }
        println("FD_E2E_FAILURE " + metisSafeUtf8Prefix(redacted, 2000, marker: "...[truncated]"))
    }
}

private func fdE2ERequireFreshSources(root: Path, binaryTime: DateTime): Int64 {
    let directories = ArrayList<Path>([root])
    var cursor: Int64 = 0
    var count: Int64 = 0
    while (cursor < directories.size) {
        let directory = directories[cursor]
        let info = FileInfo(directory)
        if (!info.isDirectory() || info.isSymbolicLink()) { throw Exception("fixture_source_root_invalid") }
        for (entry in Directory.readFrom(directory)) {
            let entryInfo = FileInfo(entry.path)
            if (entryInfo.isSymbolicLink()) { throw Exception("fixture_source_symlink_rejected") }
            if (entryInfo.isDirectory()) {
                if (directories.size >= 4096) { throw Exception("fixture_source_directory_bound") }
                directories.add(entry.path)
            } else if (entry.name.endsWith(".cj") && !entry.name.endsWith("_test.cj")) {
                if (!entryInfo.isRegular() || binaryTime < entryInfo.lastModificationTime) { throw Exception("fixture_real_binary_stale") }
                count += 1
                if (count > 32768) { throw Exception("fixture_source_file_bound") }
            }
        }
        cursor += 1
    }
    if (count == 0) { throw Exception("fixture_source_root_empty") }
    count
}

@When[os == "macOS"]
private class FdE2EJointLifecycle {
    private let home: Path
    private let binary: Path
    private let commands = ArrayList<ManagedOwnedChild>()
    private let outputFiles = HashMap<Int64, (Path, Path)>()
    private let proof = JsonObject()
    private var binaryHash = ""
    private var oldIdentity = None<GatewayServeIdentity>
    private var newIdentity = None<GatewayServeIdentity>
    private var restartIssued = false

    public init(home: Path) {
        this.home = home
        this.binary = CliConfig.cwd.join("target").join("release").join("bin").join("metis")
    }

    // The class is file-private. This records an attempt, never an invented process identity.
    public func markRestartIssued(): Unit { this.restartIssued = true }

    public func inventoryTerminalForCleanup(): Bool {
        if (this.oldIdentity.isNone() || (this.restartIssued && this.newIdentity.isNone())) { return false }
        if (!this.terminal(this.oldIdentity.getOrThrow())) { return false }
        match (this.newIdentity) { case Some(value) => this.terminal(value) case None => !this.restartIssued }
    }

    public func requireFreshBinary(): Unit {
        if (!exists(this.binary) || !FileInfo(this.binary).isRegular() || FileInfo(this.binary).isSymbolicLink()) {
            throw Exception("fixture_real_binary_missing")
        }
        let binaryTime = FileInfo(this.binary).lastModificationTime
        let metisSources = fdE2ERequireFreshSources(CliConfig.cwd.join("src"), binaryTime)
        let magicRoot = getVariable("MAGIC_PATH") ?? ""
        if (magicRoot.isEmpty()) { throw Exception("fixture_magic_source_root_missing") }
        let magicSources = fdE2ERequireFreshSources(Path(magicRoot).join("src"), binaryTime)
        let brokerScript = CliConfig.cwd.join("scripts").join("metis-stdio-broker.mjs")
        if (!exists(brokerScript) || !FileInfo(brokerScript).isRegular() || FileInfo(brokerScript).isSymbolicLink() ||
            binaryTime < FileInfo(brokerScript).lastModificationTime) { throw Exception("fixture_broker_script_stale") }
        this.proof.put("governingMetisSources", metisSources.toJsonValue())
        this.proof.put("governingMagicSources", magicSources.toJsonValue())
        this.binaryHash = fdE2EFileSha256(this.binary.toString())
    }

    private func identity(): Option<GatewayServeIdentity> {
        gatewayParseServeIdentity(fdE2EReadText(this.home.join("gateway-serve.lock")))
    }

    private func inventory(identity: GatewayServeIdentity): Path {
        this.home.join("gateway-resource-inventory").join("${identity.pid}-${identity.startedAtMs}")
    }

    private func terminal(identity: GatewayServeIdentity): Bool {
        match (identity.processIdentity) {
            case Some(full) =>
                let parent = probeProcessInstance(full, MonoTime.now() + Duration.second)
                let resources = managedRecoveryProbeRecords(this.inventory(identity), full.serialize(), identity.nonce,
                    MonoTime.now() + Duration.second)
                parent.conclusive && !parent.alive && resources.ok && resources.terminal
            case None => false
        }
    }

    private func replacementBound(identity: GatewayServeIdentity): Bool {
        try {
            let control = fdE2ERead(this.home.join("control.json"))
            let nonce = fdE2EString(control, "nonce")
            if (!fdE2EValidateChild(this.home, nonce, "joint") || fdE2EInt(control, "parentPid") != Int64(getProcessId())) { return false }
            let full = identity.processIdentity.getOrThrow()
            let probe = probeProcessInstance(full, MonoTime.now() + Duration.second)
            if (!probe.conclusive || !probe.alive) { return false }
            let process = findProcess(identity.pid)
            let arguments = process.arguments
            let serveArgs = (arguments.contains("gateway") && (arguments.contains("run") || arguments.contains("serve"))) ||
                arguments.contains("gateway run") || arguments.contains("gateway serve")
            if (canonicalize(Path(process.command)) != canonicalize(this.binary) ||
                !serveArgs) { return false }
            let environment = fdE2EProcessEnvironment(identity.pid, (full.value8, full.value9))
            environment.get("METIS_HOME") == Some(this.home.toString()) &&
                environment.get("METIS_FD_E2E_CHILD_NONCE") == Some(nonce) &&
                environment.get("METIS_FD_E2E_CHILD_MODE") == Some("joint")
        } catch (_: Exception) { false }
    }

    private func launchCli(args: Array<String>, name: String): ManagedOwnedChild {
        let control = fdE2ERead(this.home.join("control.json"))
        let environment = fdE2EFixtureEnvironment(this.home)
        environment["cjHeapSize"] = "2GB"
        environment["METIS_FD_E2E_CHILD_NONCE"] = fdE2EString(control, "nonce")
        environment["METIS_FD_E2E_CHILD_MODE"] = "joint"
        for (key in cliProviderApiKeyEnvAliases("openai")) { environment[key] = "fake-fd-model-key" }
        let dependencyPort = fdE2EInt(control, "dependencyPort")
        for (key in cliProviderBaseUrlEnvAliases("openai")) { environment[key] = "http://127.0.0.1:${dependencyPort}/v1" }
        let outputPath = this.home.join("joint-${name}-${this.commands.size}.stdout")
        let errorPath = this.home.join("joint-${name}-${this.commands.size}.stderr")
        var child = None<ManagedOwnedChild>
        try (output = File(outputPath, OpenMode.Write), error = File(errorPath, OpenMode.Write)) {
            let process = launchManagedRawChild(this.binary.toString(), args, workingDirectory: Some(CliConfig.cwd), environment: environment,
                stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            this.commands.add(process)
            this.outputFiles[process.pid] = (outputPath, errorPath)
            child = Some(process)
        }
        child.getOrThrow()
    }

    private func output(process: ManagedOwnedChild): String {
        let paths = this.outputFiles[process.pid]
        fdE2EReadText(paths[0]) + fdE2EReadText(paths[1])
    }

    private func captureReady(previousNonce: String): Bool {
        match (this.identity()) {
            case Some(value) =>
                if (value.nonce == previousNonce || !this.replacementBound(value)) { return false }
                this.newIdentity = Some(value)
                let expected = "managed-recovery-ready-v1\nparent:${value.processIdentity.getOrThrow().serialize()}\nbinding:${value.nonce}\n"
                fdE2EReadText(this.inventory(value).join("ready")) == expected
            case None => false
        }
    }

    private func observeFirstReady(old: GatewayServeIdentity, broker: FdE2EOwnedBroker,
        descendants: FdE2EOwnedDescendants, port: Int64): Bool {
        if (fdE2EBool(this.proof, "firstNewReadyObserved")) {
            return fdE2EBool(this.proof, "oldTerminalAtFirstNewReadyObservation")
        }
        if (!this.captureReady(old.nonce) || this.readyStatus(port) != 200) { return false }
        let terminal = this.terminal(old) && descendants.terminal() && fdE2EPidGone(broker.pid)
        this.proof.put("firstNewReadyObserved", true.toJsonValue())
        this.proof.put("oldTerminalAtFirstNewReadyObservation", terminal.toJsonValue())
        if (!terminal) { throw Exception("fixture_new_ready_before_observed_old_terminal") }
        true
    }

    private func readyStatus(port: Int64): Int64 {
        let builder = ClientBuilder()
        builder.readTimeout(Duration.second * 2)
        let client = builder.build()
        try { Int64(client.get("http://127.0.0.1:${port}/readyz").status) }
        catch (_: Exception) { 0 }
        finally { client.close() }
    }

    public func run(child: ManagedOwnedChild, broker: FdE2EOwnedBroker, descendants: FdE2EOwnedDescendants, port: Int64): Bool {
        this.requireFreshBinary()
        this.proof.put("status", JsonString("waiting_fd_observation"))
        if (!fdE2EWait(180000, { => exists(this.home.join("joint-ready.json")) || !child.isAlive() })) {
            throw Exception("fixture_joint_observation_timeout")
        }
        let fdProof = fdE2ERead(this.home.join("joint-ready.json"))
        let control = fdE2ERead(this.home.join("control.json"))
        if (!fdE2EBool(fdProof, "ok") || fdE2EInt(fdProof, "pollRounds") < 120 ||
            fdE2EString(fdProof, "nonce") != fdE2EString(control, "nonce") ||
            fdE2EString(fdProof, "mode") != "joint" ||
            fdE2EString(fdProof, "binarySha256") != fdE2EBinarySha256()) { throw Exception("fixture_joint_fd_proof_failed") }
        this.proof.put("nonce", JsonString(fdE2EString(control, "nonce")))
        this.proof.put("mode", JsonString(fdE2EString(control, "mode")))
        this.proof.put("fdObservationOk", fdE2EBool(fdProof, "observationOk").toJsonValue())
        this.proof.put("pollRounds", fdE2EInt(fdProof, "pollRounds").toJsonValue())
        this.proof.put("nativeEmfileCount", fdE2EInt(fdProof, "nativeEmfileCount").toJsonValue())
        let old = this.identity().getOrThrow()
        this.oldIdentity = Some(old)
        let current = probeProcessInstance(old.processIdentity.getOrThrow(), MonoTime.now() + Duration.second)
        let birth = fdE2EBirth(child.pid).getOrThrow()
        if (child.pid != old.pid || !child.isAlive() || !current.conclusive || !current.alive ||
            birth[0] != broker.parentBirth[0] || birth[1] != broker.parentBirth[1]) {
            throw Exception("fixture_joint_old_identity_changed")
        }
        if (!descendants.capture(child)) { throw Exception("fixture_joint_descendant_capture_failed") }
        this.proof.put("capturedOldDescendants", descendants.count().toJsonValue())
        child.terminate(force: true)
        let oldExit = child.wait(timeout: Some(Duration.second * 5))
        this.proof.put("oldExit", oldExit.toJsonValue())
        if (child.isAlive() || oldExit == 0 || exists(this.home.join("gateway-serve.stop-complete"))) {
            throw Exception("fixture_joint_hard_exit_failed")
        }
        this.proof.put("status", JsonString("actual_cli_restart"))
        // No fallback, broker signal, stop request or resource pre-clean occurs here.
        this.markRestartIssued()
        let restart = this.launchCli(["gateway", "restart"], "restart")
        let restartDeadline = MonoTime.now() + Duration.second * 90
        while (restart.isAlive() && MonoTime.now() < restartDeadline) {
            let _ = this.observeFirstReady(old, broker, descendants, port)
            sleep(Duration.millisecond * 20)
        }
        if (restart.isAlive()) { throw Exception("fixture_joint_restart_deadline") }
        let restartExit = restart.wait(timeout: Some(Duration.second * 5))
        this.proof.put("restartExit", restartExit.toJsonValue())
        let restartOutput = this.output(restart)
        let launchMessage = "[网关] 已请求在后台启动网关，正在等待就绪；日志: " + this.home.join("gateway-background.log").toString()
        let launchCount = restartOutput.split(launchMessage).size - 1
        let ready = restartExit == 0 && fdE2EWait(30000, { => this.observeFirstReady(old, broker, descendants, port) })
        let replacement = this.newIdentity.getOrThrow()
        let oldTerminalAtReady = fdE2EBool(this.proof, "oldTerminalAtFirstNewReadyObservation")
        var generations: Int64 = 0
        for (entry in Directory.readFrom(this.home.join("gateway-resource-inventory"))) {
            if (entry.isDirectory()) { generations += 1 }
        }
        var archivedMissing = false
        let history = this.home.join("gateway-serve.recovery-history")
        if (exists(history)) {
            for (entry in Directory.readFrom(history)) {
                if (entry.name.endsWith(".crash-evidence") && fdE2EReadText(entry.path).contains("completion:missing")) { archivedMissing = true }
            }
        }
        let readyStatus = this.readyStatus(port)
        this.proof.put("status", JsonString("actual_cli_stop"))
        let stop = this.launchCli(["gateway", "stop"], "stop")
        let stopExit = stop.wait(timeout: Some(Duration.second * 65))
        let terminal = fdE2EWait(5000, { => this.terminal(old) && descendants.terminal() && this.terminal(replacement) && fdE2EPortClosed(port) })
        let fullTerminal = fdE2EReadText(this.home.join("gateway-serve.stop-complete")).contains("fullTerminal:1")
        let forbidden = restartOutput.contains("\u{4e3b}\u{8fdb}\u{7a0b}\u{5df2}\u{9000}\u{51fa}\u{4f46}\u{5b50}\u{8fdb}\u{7a0b}\u{6e05}\u{7406}\u{672a}\u{5b8c}\u{6210}")
        let proof = this.proof
        proof.put("fdObservationOk", fdE2EBool(fdProof, "observationOk").toJsonValue())
        proof.put("pollRounds", fdE2EInt(fdProof, "pollRounds").toJsonValue())
        proof.put("nativeEmfileCount", fdE2EInt(fdProof, "nativeEmfileCount").toJsonValue())
        proof.put("restartExit", restartExit.toJsonValue())
        proof.put("launchCount", launchCount.toJsonValue())
        proof.put("newNonce", (replacement.nonce != old.nonce && replacement.pid != old.pid).toJsonValue())
        proof.put("oldTerminalAtFirstNewReadyObservation", oldTerminalAtReady.toJsonValue())
        proof.put("readyStatus", readyStatus.toJsonValue())
        proof.put("generations", generations.toJsonValue())
        proof.put("archivedMissingCompletion", archivedMissing.toJsonValue())
        proof.put("stopExit", stopExit.toJsonValue())
        proof.put("fullTerminal", fullTerminal.toJsonValue())
        proof.put("terminalBeforeFallback", terminal.toJsonValue())
        proof.put("unitBinarySha256", JsonString(fdE2EBinarySha256()))
        proof.put("realBinarySha256", JsonString(this.binaryHash))
        let ok = ready && launchCount == 1 && replacement.nonce != old.nonce && replacement.pid != old.pid &&
            oldTerminalAtReady && readyStatus == 200 && generations == 2 && archivedMissing && !forbidden &&
            stopExit == 0 && terminal && fullTerminal && fdE2EFileSha256(this.binary.toString()) == this.binaryHash
        proof.put("ok", ok.toJsonValue())
        proof.put("status", JsonString(if (ok) { "passed" } else { "formal_failed" }))
        fdE2EWriteProof(this.home, "joint-formal-result.json", proof)
        let pollRounds = fdE2EInt(fdProof, "pollRounds")
        println("E2E_R03_FORMAL ok=${ok} polls=${pollRounds} oldTerminal=${oldTerminalAtReady} " +
            "launchCount=${launchCount} ready=${readyStatus} stop=${stopExit} terminal=${terminal}")
        ok
    }

    public func recordBeforeFallback(formalOk: Bool): Unit {
        let control = fdE2ERead(this.home.join("control.json"))
        this.proof.put("nonce", JsonString(fdE2EString(control, "nonce")))
        this.proof.put("mode", JsonString(fdE2EString(control, "mode")))
        this.proof.put("formalOkBeforeFallback", formalOk.toJsonValue())
        if (!formalOk) { this.proof.put("ok", false.toJsonValue()) }
        if (!this.binaryHash.isEmpty()) { this.proof.put("realBinarySha256", JsonString(this.binaryHash)) }
        match (this.oldIdentity) { case Some(value) => this.proof.put("oldPid", value.pid.toJsonValue()) case None => () }
        match (this.newIdentity) { case Some(value) => this.proof.put("newPid", value.pid.toJsonValue()) case None => () }
        fdE2EWriteProof(this.home, "joint-formal-result.json", this.proof)
    }

    public func cleanupAfterFormalFailure(): Bool {
        var commandsStopped = true
        var resourcesTerminal = false
        try {
            try {
                match (this.identity()) {
                    case Some(value) => if (this.oldIdentity.isSome() && value.nonce != this.oldIdentity.getOrThrow().nonce && this.replacementBound(value)) {
                        this.newIdentity = Some(value)
                    }
                    case None => ()
                }
            } catch (_: Exception) { () }
            for (command in this.commands) { if (!fdE2EStopProcess(Some(command))) { commandsStopped = false } }
            if (this.newIdentity.isSome()) {
                try {
                    let stop = this.launchCli(["gateway", "stop"], "fallback-stop")
                    let _ = stop.wait(timeout: Some(Duration.second * 65))
                } catch (_: Exception) { () }
                // A failed stop/diagnostic never bypasses the already identity-bound fallback.
                try {
                    let value = this.newIdentity.getOrThrow()
                    if (!this.terminal(value) && this.replacementBound(value)) {
                        let _ = signalProcessInstance(value.processIdentity.getOrThrow(), processInstanceTermSignal(), MonoTime.now() + Duration.second)
                        if (!fdE2EWait(3000, { => this.terminal(value) }) && this.replacementBound(value)) {
                            let _ = signalProcessInstance(value.processIdentity.getOrThrow(), processInstanceKillSignal(), MonoTime.now() + Duration.second)
                        }
                    }
                } catch (_: Exception) { () }
            }
        } finally {
            // Includes a returned fallback-stop handle even if its wait/diagnostic failed.
            for (command in this.commands) { if (!fdE2EStopProcess(Some(command))) { commandsStopped = false } }
            resourcesTerminal = try {
                match (this.newIdentity) {
                    case Some(value) => fdE2EWait(5000, { => this.terminal(value) })
                    case None => !this.restartIssued
                }
            } catch (_: Exception) { false }
        }
        commandsStopped && resourcesTerminal
    }

}

@When[os == "macOS"]
private func fdE2EParent(mode: String, caseName: String): Unit {
    let before = captureCurrentProcessFdSnapshot()
    let home = canonicalize(Path("/tmp")).join("metis-fd-e2e-${getProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    if (exists(home)) { throw Exception("fixture_home_already_exists") }
    Directory.create(home)
    var dependency = None<ManagedOwnedChild>
    var child = None<ManagedOwnedChild>
    var dependencyLaunchPending = false
    var childLaunchPending = false
    var gatewayPort: Int64 = 0
    var dependencyPort: Int64 = 0
    var formalOk = false
    var brokerPid: Int64 = 0
    var ownedBroker = None<FdE2EOwnedBroker>
    var ownedDescendants = None<FdE2EOwnedDescendants>
    let joint = FdE2EJointLifecycle(home)
    try {
        if (mode == "joint") { joint.requireFreshBinary() }
        let ready = home.join("dependency-ready.json")
        dependencyLaunchPending = true
        dependency = Some(launchManagedRawChild("/usr/bin/env", ["node", CliConfig.cwd.join("scripts").join("metis-s5-loopback-dependencies.mjs").toString(),
            ready.toString(), home.join("events.jsonl").toString(), "fd-e2e-synthetic-reply"],
            environment: fdE2EFixtureEnvironment(home),
            stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard))
        dependencyLaunchPending = false
        if (!fdE2EWait(10000, { => exists(ready) })) { throw Exception("fixture_dependency_not_ready") }
        dependencyPort = fdE2EInt(fdE2ERead(ready), "port")
        gatewayPort = fdE2EPort()
        if (dependencyPort <= 0 || gatewayPort <= 0 || dependencyPort == gatewayPort) { throw Exception("fixture_ports_invalid") }
        let nonce = "${getProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        let control = JsonObject()
        control.put("nonce", JsonString(nonce))
        control.put("mode", JsonString(mode))
        control.put("parentPid", Int64(getProcessId()).toJsonValue())
        control.put("binarySha256", JsonString(fdE2EBinarySha256()))
        control.put("gatewayPort", gatewayPort.toJsonValue())
        control.put("dependencyPort", dependencyPort.toJsonValue())
        fdE2EWriteProof(home, "control.json", control)
        childLaunchPending = true
        child = Some(fdE2ELaunchChild(home, mode, caseName, nonce))
        childLaunchPending = false
        let launched = child.getOrThrow()
        let descendants = FdE2EOwnedDescendants(launched, home, nonce, mode)
        ownedDescendants = Some(descendants)
        println("FD_E2E_STARTED mode=${mode} childPid=${launched.pid}")
        let _ = fdE2EWait(45000, { => exists(home.join("progress.json")) || !launched.isAlive() })
        ownedBroker = fdE2ECaptureBroker(launched, home, nonce, mode)
        if (!descendants.capture(launched) || ownedBroker.isNone()) { throw Exception("fixture_owned_ready_capture_failed") }
        let captured = JsonObject()
        captured.put("nonce", JsonString(nonce))
        fdE2EWriteProof(home, "parent-captured.json", captured)
        if (mode == "joint") {
            formalOk = joint.run(launched, ownedBroker.getOrThrow(), descendants, gatewayPort)
            if (!formalOk) { fdE2EPrintFailure(home) }
            @Expect(formalOk, true)
            return
        }
        let deadline = if (mode == "long") { 3100 } else if (mode == "positive32") { 420 } else { 240 }
        let code = fdE2EWaitOwnedExit(launched, descendants, deadline)
        let proof = fdE2ERead(home.join("formal-result.json"))
        brokerPid = fdE2EInt(proof, "brokerPid")
        formalOk = ownedBroker.isSome() && brokerPid > 1 && brokerPid == ownedBroker.getOrThrow().pid &&
            code == 0 && fdE2EBool(proof, "ok") &&
            fdE2EString(proof, "nonce") == nonce && fdE2EString(proof, "mode") == mode && descendants.terminal() &&
            fdE2EPidGone(ownedBroker.getOrThrow().pid) && fdE2EPortClosed(gatewayPort) &&
            fdE2EString(proof, "binarySha256") == fdE2EString(control, "binarySha256")
        @Expect(code, 0)
        @Expect(fdE2EBool(proof, "ok"), true)
        @Expect(formalOk, true)
        let rounds = fdE2EInt(proof, "pollRounds")
        let positive = fdE2EInt(proof, "positiveRounds")
        let emfile = fdE2EInt(proof, "nativeEmfileCount")
        let warm = fdE2EInt(proof, "warmFdCount")
        let finalCount = fdE2EInt(proof, "finalFdCount")
        let limit = fdE2EInt(proof, "fdLimit")
        let failureStatus = fdE2EString(proof, "failureStatus")
        let measurementMs = fdE2EInt(proof, "measurementMs")
        println("FD_E2E_FORMAL mode=${mode} ok=${formalOk} pollRounds=${rounds} " +
            "positiveRounds=${positive} nativeEmfileCount=${emfile} warmFd=${warm} finalFd=${finalCount} fdLimit=${limit} " +
            "measurementMs=${measurementMs} status=${failureStatus}")
        if (!formalOk) {
            let business = fdE2EInt(proof, "businessSends")
            let model = fdE2EInt(proof, "modelResponses")
            let heartbeats = fdE2EInt(proof, "heartbeatDelta")
            let degraded = fdE2EBool(proof, "degraded")
            let recovered = fdE2EBool(proof, "recovered")
            let ready = fdE2EInt(proof, "readyStatus")
            let terminal = fdE2EBool(proof, "fullTerminal")
            println("FD_E2E_CHECKS business=${business} model=${model} heartbeats=${heartbeats} degraded=${degraded} " +
                "recovered=${recovered} ready=${ready} fullTerminal=${terminal}")
            fdE2EPrintFailure(home)
        }
    } catch (e: Exception) {
        formalOk = false
        try { fdE2EPrintFailure(home) } catch (_: Exception) { () }
        throw e
    } finally {
        let descendantsAtCleanup = ownedDescendants
        let noChild = child.isNone() && !childLaunchPending
        var outcomeWritten = false
        var jointStopped = false
        var childStopped = false
        var brokerStopped = false
        var dependencyStopped = false
        try {
            try {
                let outcome = JsonObject()
                outcome.put("formalOkBeforeFallback", formalOk.toJsonValue())
                let control = fdE2ERead(home.join("control.json"))
                outcome.put("nonce", JsonString(fdE2EString(control, "nonce")))
                outcome.put("mode", JsonString(fdE2EString(control, "mode")))
                outcome.put("childLaunchPending", childLaunchPending.toJsonValue())
                outcome.put("dependencyLaunchPending", dependencyLaunchPending.toJsonValue())
                outcome.put("capturedDescendants", descendantsAtCleanup.map({ value => value.count() }).getOrDefault({ => 0 }).toJsonValue())
                outcome.put("descendantsTerminalBeforeFallback", descendantsAtCleanup.map({ value => value.terminal() }).getOrDefault({ => noChild }).toJsonValue())
                if (mode == "joint") { joint.recordBeforeFallback(formalOk) }
                fdE2EWriteProof(home, "formal-before-fallback.json", outcome)
                outcomeWritten = true
            } catch (_: Exception) { @Expect(false, true) }
        } finally {
            // Diagnostic failure cannot suppress cleanup of a known, independently bound owner.
            try {
                jointStopped = if (mode == "joint" && !formalOk) {
                    try { joint.cleanupAfterFormalFailure() } catch (_: Exception) { false }
                } else { true }
            } finally {
                try { childStopped = fdE2EStopProcess(child) }
                finally {
                    try {
                        brokerStopped = if (!formalOk) {
                            match (ownedBroker) {
                                case Some(owned) => try { fdE2EFallbackBroker(owned) } catch (_: Exception) { false }
                                case None => true
                            }
                        } else { true }
                    } finally { dependencyStopped = fdE2EStopProcess(dependency) }
                }
            }
        }
        var settled = false
        var limitUnchanged = false
        try {
            let recordedBroker = max(fdE2EInt(fdE2ERead(home.join("formal-result.json")), "brokerPid"),
                fdE2EInt(fdE2ERead(home.join("progress.json")), "brokerPid"))
            let expectedBrokerPid = max(brokerPid, recordedBroker)
            let descendantsGone = fdE2EWait(5000, { =>
                descendantsAtCleanup.map({ value => value.terminal() }).getOrDefault({ => noChild })
            })
            let inventoryTerminal = if (noChild) { true } else if (mode == "joint") { joint.inventoryTerminalForCleanup() }
                else { descendantsAtCleanup.map({ value => value.inventoryTerminal() }).getOrDefault({ => false }) }
            // PID0/None/empty census and a launch without a returned handle are not terminal proof.
            let brokerGone = if (expectedBrokerPid > 1) { fdE2EWait(5000, { => fdE2EPidGone(expectedBrokerPid) }) }
                else { noChild || inventoryTerminal }
            settled = !dependencyLaunchPending && !childLaunchPending && outcomeWritten && inventoryTerminal && descendantsGone &&
                jointStopped && childStopped && brokerStopped && dependencyStopped && brokerGone &&
                fdE2EPortClosed(gatewayPort) && fdE2EPortClosed(dependencyPort)
            @Expect(settled, true)
            limitUnchanged = captureCurrentProcessFdSnapshot().fdLimit == before.fdLimit
            @Expect(limitUnchanged, true)
        } catch (_: Exception) { @Expect(false, true) }
        let deletionAllowed = settled && formalOk && limitUnchanged
        if (deletionAllowed) { remove(home, recursive: true) }
        else { println("FD_E2E_EVIDENCE_RETAINED formalOk=${formalOk} cleanupTerminal=${settled}") }
        @Expect(exists(home), !deletionAllowed)
    }

}

@When[os == "macOS"]
private func fdE2EDispatch(mode: String, caseName: String): Unit {
    match (getVariable("METIS_FD_E2E_CHILD_HOME")) {
        case Some(value) =>
            let home = Path(value)
            let nonce = getVariable("METIS_FD_E2E_CHILD_NONCE") ?? ""
            if (getVariable("METIS_HOME") != Some(value) || getVariable("METIS_FD_E2E_CHILD_MODE") != Some(mode) ||
                !fdE2EValidateChild(home, nonce, mode)) { throw Exception("fixture_child_identity_rejected") }
            fdE2ERunChild(home, mode)
        case None => fdE2EParent(mode, caseName)
    }
}

@When[os == "macOS"]
@Test
public class GatewayFdExhaustionE2ETest {
    @TestCase
    public func fdE2EU1RejectsUnownedChildBeforeMutation(): Unit {
        @Expect(fdE2EValidateChild(Path("/tmp/metis-fd-e2e-does-not-exist"), "", "short"), false)
        @Expect(fdE2EValidateChild(Path("/tmp/metis-fd-e2e-does-not-exist"), "wrong", "long"), false)
        @Expect(fdE2EValidateChild(Path("/tmp/not-owned"), "wrong", "invalid"), false)
        @Expect(fdE2EValidateChild(Path("/"), "wrong", "short"), false)
        let originalHome = getVariable("HOME")
        let environment = fdE2EFixtureEnvironment(Path("/tmp/metis-fd-e2e-not-created"))
        for (descriptor in cliModelProviderCatalogDescriptors()) {
            for (key in descriptor.apiKeyEnvAliases) { @Expect(environment.contains(key), false) }
        }
        @Expect(environment.get("HOME") == originalHome, true)
        @Expect(getVariable("HOME") == originalHome, true)
        var longNonce = ""
        for (_ in 0..512) { longNonce += "中文😀" }
        let prefix = ArrayList<Byte>([1, 0, 0, 0])
        prefix.add(all: "/fixture\u{0}\u{0}METIS_HOME=argument-decoy\u{0}".toArray())
        let argvOnlyUnavailable = try { let _ = fdE2EParseKernelEnvironment(prefix.toArray(), prefix.size); false }
            catch (error: Exception) { error.message == "fixture_process_arguments_unavailable" }
        @Expect(argvOnlyUnavailable, true)
        let valid = ArrayList<Byte>(prefix.toArray())
        valid.add(all: ("METIS_HOME=/private/tmp/中文😀\u{0}" +
            "METIS_FD_E2E_CHILD_NONCE=${longNonce}\u{0}METIS_FD_E2E_CHILD_MODE=short\u{0}" +
            "OTHER_SECRET=not-retained\u{0}\u{0}").toArray())
        let parsed = fdE2EParseKernelEnvironment(valid.toArray(), valid.size)
        @Expect(parsed.size, 3)
        @Expect(parsed["METIS_HOME"], "/private/tmp/中文😀")
        @Expect(parsed["METIS_FD_E2E_CHILD_NONCE"], longNonce)
        @Expect(parsed["METIS_FD_E2E_CHILD_MODE"], "short")
        @Expect(parsed.contains("OTHER_SECRET"), false)
        let duplicate = ArrayList<Byte>(prefix.toArray())
        duplicate.add(all: "METIS_HOME=one\u{0}METIS_HOME=two\u{0}\u{0}".toArray())
        let binary = ArrayList<Byte>(prefix.toArray())
        binary.add(all: "METIS_HOME=".toArray())
        binary.add(all: [0xff, 0, 0])
        let validBytes = valid.toArray()
        let truncatedInvalid = try { let _ = fdE2EParseKernelEnvironment(validBytes, validBytes.size - 1); false }
            catch (error: Exception) { error.message == "fixture_process_arguments_invalid" }
        @Expect(truncatedInvalid, true)
        let malformed: Array<Array<Byte>> = [[], [1, 0, 0, 0], [0, 0, 0, 0, 0],
            [1, 16, 0, 0, 0], duplicate.toArray(), binary.toArray(), validBytes[..validBytes.size - 1]]
        for (bytes in malformed) {
            let rejected = try { let _ = fdE2EParseKernelEnvironment(bytes, bytes.size); false }
                catch (_: Exception) { true }
            @Expect(rejected, true)
        }
        let oversized = try { let _ = fdE2EParseKernelEnvironment(validBytes, validBytes.size + 1); false }
            catch (_: Exception) { true }
        @Expect(oversized, true)
    }

    @TestCase
    public func fdE2EU2FallbackRejectsUnboundIdentity(): Unit {
        let before = captureCurrentProcessFdSnapshot()
        let pid = Int64(getProcessId())
        let invalid = FdE2EOwnedBroker(pid, pid, (0, 0), (0, 0),
            Path("/tmp/metis-fd-e2e-does-not-exist"), "wrong", "short", "wrong-script")
        @Expect(fdE2EBrokerMatches(invalid), false)
        @Expect(fdE2EFallbackBroker(invalid), false)
        let environmentRejected = try { let _ = fdE2EProcessEnvironment(pid, (0, 0)); false }
            catch (_: Exception) { true }
        @Expect(environmentRejected, true)
        @Expect(fdE2EPidGone(pid), false)
        @Expect(captureCurrentProcessFdSnapshot().fdLimit, before.fdLimit)
        // N4/N5 cleanup-decision unit coverage; actual CLI composition is the R03 gate.
        @Expect(fdE2ESourceInventoryTerminal(Path("/tmp/metis-fd-e2e-does-not-exist"), None<GatewayServeIdentity>, pid, (0, 0)), false)
        let home = canonicalize(Path("/tmp")).join("metis-fd-e2e-cleanup-unit-${pid}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(home)
        var unitPassed = false
        try {
            File.writeTo(home.join("cleanup-unit.input"), "owned-no-generation".toArray())
            let unknown = FdE2EJointLifecycle(home)
            unknown.markRestartIssued()
            let cleanupTerminal = unknown.cleanupAfterFormalFailure()
            let inventoryTerminal = unknown.inventoryTerminalForCleanup()
            @Expect(cleanupTerminal, false)
            @Expect(inventoryTerminal, false)
            @Expect(fdE2EReadText(home.join("cleanup-unit.input")), "owned-no-generation")
            unitPassed = !cleanupTerminal && !inventoryTerminal && fdE2EReadText(home.join("cleanup-unit.input")) == "owned-no-generation"
        } finally {
            let proof = JsonObject()
            proof.put("unitDecisionPassed", unitPassed.toJsonValue())
            proof.put("recordedBeforeFallback", true.toJsonValue())
            fdE2EWriteProof(home, "formal-before-fallback.json", proof)
            if (unitPassed) { remove(home, recursive: true) }
            else { println("FD_E2E_CLEANUP_UNIT_EVIDENCE_RETAINED") }
        }
    }

    @TestCase
    public func fdE2EN1RejectedChildRecordsFailureBeforeCleanup(): Unit {
        let before = captureCurrentProcessFdSnapshot()
        let home = canonicalize(Path("/tmp")).join("metis-fd-e2e-reject-${getProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(home)
        var child = None<ManagedOwnedChild>
        var launchPending = false
        var exitCode = None<Int64>
        var expectedRejection = false
        var proofWritten = false
        try {
            let control = JsonObject()
            control.put("nonce", JsonString("expected-fixture-nonce"))
            control.put("mode", JsonString("short"))
            control.put("parentPid", Int64(getProcessId()).toJsonValue())
            fdE2EWriteProof(home, "control.json", control)
            launchPending = true
            child = Some(fdE2ELaunchChild(home, "short", "fdE2E01RealServeRecoversNativeEmfileAndStops", "wrong-fixture-nonce"))
            launchPending = false
            let code = child.getOrThrow().wait(timeout: Some(Duration.second * 10))
            exitCode = Some(code)
            @Expect(code != 0, true)
            @Expect(exists(home.join("gateway-serve.lock")), false)
            @Expect(exists(home.join("metis.json")), false)
            expectedRejection = code != 0 && !exists(home.join("gateway-serve.lock")) && !exists(home.join("metis.json"))
        } finally {
            var stopped = false
            try {
                try {
                    let outcome = JsonObject()
                    outcome.put("formalOkBeforeFallback", false.toJsonValue())
                    let control = fdE2ERead(home.join("control.json"))
                    outcome.put("nonce", JsonString(fdE2EString(control, "nonce")))
                    outcome.put("mode", JsonString(fdE2EString(control, "mode")))
                    outcome.put("expectedRejection", expectedRejection.toJsonValue())
                    outcome.put("launchPending", launchPending.toJsonValue())
                    outcome.put("childExitObserved", exitCode.isSome().toJsonValue())
                    match (exitCode) { case Some(code) => outcome.put("childExit", code.toJsonValue()) case None => () }
                    fdE2EWriteProof(home, "formal-before-fallback.json", outcome)
                    proofWritten = true
                    @Expect(fdE2EBool(fdE2ERead(home.join("formal-before-fallback.json")), "formalOkBeforeFallback"), false)
                } catch (_: Exception) { @Expect(false, true) }
            } finally { stopped = fdE2EStopProcess(child) }
            @Expect(stopped && !launchPending, true)
            let limitUnchanged = captureCurrentProcessFdSnapshot().fdLimit == before.fdLimit
            @Expect(limitUnchanged, true)
            let deletionAllowed = expectedRejection && proofWritten && stopped && !launchPending && limitUnchanged
            if (deletionAllowed) { remove(home, recursive: true) }
            else { println("FD_E2E_REJECTION_EVIDENCE_RETAINED") }
            @Expect(exists(home), !deletionAllowed)
        }
    }

    @TestCase
    public func fdE2E01RealServeRecoversNativeEmfileAndStops(): Unit {
        fdE2EDispatch("short", "fdE2E01RealServeRecoversNativeEmfileAndStops")
    }

    @TestCase
    public func fdS0P1ModelAndTelegramThirtyTwoSuccessesReturnClassifiedFds(): Unit {
        fdE2EDispatch("positive32", "fdS0P1ModelAndTelegramThirtyTwoSuccessesReturnClassifiedFds")
    }

    @TestCase
    public func fdE2ER03FdFailureThenHardExitActualCliRestart(): Unit {
        fdE2EDispatch("joint", "fdE2ER03FdFailureThenHardExitActualCliRestart")
    }

    @Configure[skip: !fdE2EFormalEnabled()]
    @TestCase
    public func fdE2E02TenThousandRealServePolls(): Unit {
        fdE2EDispatch("long", "fdE2E02TenThousandRealServePolls")
    }
}
