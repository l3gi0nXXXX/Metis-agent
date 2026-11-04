package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, removeVariable, setVariable}
import std.fs.{Directory, File, OpenMode, Path, canonicalize, exists, remove}
import std.io.SeekPosition
import std.posix.chmod
import std.process.{ProcessException, ProcessRedirect, executeWithOutput}
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func gateCompatCheck(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("native_gate_compat_contract_failed") }
}

private func gateCompatText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("native_gate_compat_invalid_encoding") }
}

private func gateCompatResult(home: Path, index: Int64, result: (Int64, Array<Byte>, Array<Byte>)): Unit {
    File.writeTo(home.join("round-${index}.stdout.bin"), result[1])
    File.writeTo(home.join("round-${index}.stderr.bin"), result[2])
    let proof = JsonObject(); proof.put("ordinal", JsonInt(index)); proof.put("actualCode", JsonInt(result[0]))
    File.writeTo(home.join("round-${index}.result.json"), proof.toJsonString().toArray())
}

private func gateCompatInput(): Array<Byte> {
    let bytes = ArrayList<Byte>(); bytes.add(all: "继承中文😀".toArray())
    bytes.add(all: [0u8, 0xffu8, 0xfeu8, 0x80u8]); bytes.toArray()
}

private func gateCompatFields(text: String): HashMap<String, String> {
    let result = HashMap<String, String>()
    let lines = text.split("\n")
    gateCompatCheck(lines.size == 13 && lines[0] == "managed-exec-error-v1")
    for (index in 1..12) {
        let parts = lines[index].split(":")
        gateCompatCheck(parts.size >= 2 && !result.contains(parts[0]))
        result[parts[0]] = String.join(parts[1..], delimiter: ":")
    }
    result
}

@When[os == "macOS"]
private class GateCompatChild {
    let home: Path
    let mode: String
    let parent: String
    let binding: String
    let inventory: Path
    let handles = ArrayList<ManagedOwnedChild>()
    let workers = ArrayList<Future<Bool>>()
    var bound = false
    var passed = false
    var completed: Int64 = 0
    var preflights: Int64 = 0
    var heldLaunches: Int64 = 0
    var legitimateLaunches: Int64 = 0
    var rejected: Int64 = 0
    var validUnknown: Int64 = 0
    var totalHelpers: Int64 = 0
    var formalIssuedDelta: Int64 = 0
    var environmentExpectedKeys: Int64 = 0
    var environmentIssuedDelta: Int64 = 0
    var warmFd: Int64 = 0
    var warmTasks: Int64 = 0
    var warmBlocking: Int64 = 0

    init() {
        home = canonicalize(Path(getVariable("METIS_GATE_COMPAT_HOME").getOrThrow()))
        mode = getVariable("METIS_GATE_COMPAT_MODE").getOrThrow()
        gateCompatCheck(["sdk", "absent", "bound"].contains(mode))
        let nonce = getVariable("METIS_GATE_COMPAT_NONCE").getOrThrow()
        gateCompatCheck(home.toString().startsWith("/private/tmp/") && !nonce.isEmpty() &&
            gateCompatText(home.join("owner")) == "native-gate-compat-v1\n" + nonce)
        gateCompatCheck(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").isNone() &&
            getVariable("METIS_PROCESS_RECOVERY_PARENT").isNone())
        parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        binding = "generation-中文😀-" + nonce
        inventory = home.join("inventory")
        if (mode == "bound") {
            gateCompatCheck(managedRecoveryInitialize(inventory, parent, binding))
            gateCompatCheck(managedRecoveryBinding((inventory.toString(), parent)) == binding)
            bound = true
        }
    }

    func baseline(): Unit {
        warmFd = ownedTestFdCount(); warmTasks = getThreadCount(); warmBlocking = getBlockingThreadCount()
    }

    func checkpoint(active!: Bool = false): Unit {
        gateCompatCheck(ownedTestFdCount() == warmFd)
        gateCompatCheck(getThreadCount() <= warmTasks && getBlockingThreadCount() <= warmBlocking)
        if (bound) {
            let source = managedRecoveryProbeRecords(inventory, parent, binding, MonoTime.now() + Duration.second * 2)
            gateCompatCheck(source.ok && source.terminal == !active)
        }
    }

    func capture(command: String, args: Array<String>, environment: HashMap<String, String>): (Int64, Array<Byte>, Array<Byte>) {
        if (mode == "sdk") {
            executeWithOutput(command, args, workingDirectory: Some(home), environment: Some<Map<String, String>>(environment))
        } else {
            managedRecoveryExecuteWithOutput(command, args, workingDirectory: Some(home), environment: Some<Map<String, String>>(environment))
        }
    }

    func finish(): Unit {
        let proof = JsonObject()
        proof.put("formal", JsonBool(passed)); proof.put("completed", JsonInt(completed)); proof.put("mode", JsonString(mode))
        proof.put("preflights", JsonInt(preflights)); proof.put("heldLaunches", JsonInt(heldLaunches))
        proof.put("legitimateLaunches", JsonInt(legitimateLaunches)); proof.put("rejectedMutants", JsonInt(rejected))
        proof.put("totalHelpers", JsonInt(totalHelpers)); proof.put("formalIssuedDelta", JsonInt(formalIssuedDelta))
        proof.put("environmentExpectedKeys", JsonInt(environmentExpectedKeys))
        proof.put("environmentIssuedDelta", JsonInt(environmentIssuedDelta))
        proof.put("validUnknownMutants", JsonInt(validUnknown)); proof.put("recordedBeforeFallback", JsonBool(true))
        proof.put("warmFd", JsonInt(warmFd)); proof.put("formalFd", JsonInt(ownedTestFdCount()))
        proof.put("warmTasks", JsonInt(warmTasks)); proof.put("formalTasks", JsonInt(getThreadCount()))
        proof.put("warmBlocking", JsonInt(warmBlocking)); proof.put("formalBlocking", JsonInt(getBlockingThreadCount()))
        File.writeTo(home.join("child-formal-before-fallback.json"), proof.toJsonString().toArray())
        var terminal = true
        for (child in handles) {
            try {
                if (child.isAlive()) { child.terminate() }
                let code = child.wait(timeout: Some(Duration.second * 5)); child.closeStreams()
                terminal = terminal && code >= 0 && code <= 255 && !child.isAlive() && child.streamsAreClosed()
            } catch (_: Exception) { terminal = false }
        }
        if (bound) {
            terminal = managedRecoveryStopOwnedChildren((inventory.toString(), parent), MonoTime.now() + Duration.second * 5) && terminal
            let source = managedRecoveryProbeRecords(inventory, parent, binding, MonoTime.now() + Duration.second * 2)
            terminal = terminal && source.ok && source.terminal
        }
        for (worker in workers) {
            try { let _ = worker.get(Duration.second * 5) }
            catch (_: TimeoutException) { terminal = false }
            catch (_: Exception) { () }
        }
        let finalProof = JsonObject(); finalProof.put("terminal", JsonBool(terminal))
        finalProof.put("formal", JsonBool(passed)); finalProof.put("retained", JsonBool(true))
        File.writeTo(home.join("child-cleanup.json"), finalProof.toJsonString().toArray())
        if (terminal) { removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY"); removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
    }
}

@When[os == "macOS"]
private func gateCompatStdin(fixture: GateCompatChild): Unit {
    let input = gateCompatInput()
    let expectedError = ArrayList<Byte>(); expectedError.add(all: "错误😀".toArray()); expectedError.add(all: [0u8, 0xfeu8])
    let stdout = ArrayList<Byte>(); let stderr = ArrayList<Byte>()
    let originalGroup = Int64(unsafe { getpgid(Int32(getProcessId())) })
    for (index in 0..33) {
        let groupFile = fixture.home.join("group-${index}")
        let pidFile = fixture.home.join("pid-${index}")
        let environment = HashMap<String, String>()
        environment["PATH"] = "/usr/bin:/bin"; environment["LANG"] = "C"; environment["SYNTHETIC"] = "合成中文😀-${index}"
        let script = "[ \"$PATH\" = '/usr/bin:/bin' ] && [ \"$SYNTHETIC\" = \"$3\" ] && [ \"$PWD\" = \"$4\" ] || exit 63; /bin/ps -o pgid= -p $$ > \"$1\"; printf '%s' \"$$\" > \"$2\"; dd bs=${input.size} count=1 2>/dev/null; printf '错误😀\\000\\376' >&2; exit 7"
        let result = fixture.capture("/bin/sh", ["-c", script, "fixture", groupFile.toString(), pidFile.toString(), environment["SYNTHETIC"], fixture.home.toString()], environment)
        gateCompatResult(fixture.home, index, result)
        gateCompatCheck(result[0] == 7 && result[1] == input && result[2] == expectedError.toArray())
        let pid = Int64.parse(gateCompatText(pidFile)); let group = Int64.parse(gateCompatText(groupFile).trimAscii())
        gateCompatCheck(pid > 1 && group == if (fixture.bound) { pid } else { originalGroup })
        gateCompatCheck(unsafe { getpgid(Int32(pid)) } == -1)
        if (index == 0) { fixture.baseline(); continue }
        stdout.add(all: result[1]); stderr.add(all: result[2]); fixture.completed += 1
        if (fixture.mode != "sdk") { fixture.checkpoint() }
    }
    gateCompatCheck(fixture.completed == 32)
    File.writeTo(fixture.home.join("captured.stdout.bin"), stdout.toArray())
    File.writeTo(fixture.home.join("captured.stderr.bin"), stderr.toArray())
}

@When[os == "macOS"]
private func gateCompatEnvironment(fixture: GateCompatChild): Unit {
    let transcript = ArrayList<Byte>()
    for (index in 0..33) {
        let environment = HashMap<String, String>()
        environment[""] = "合成中文😀"; environment["EMPTY"] = ""; environment["PATH"] = "/usr/bin:/bin"
        let expected = ArrayList<Byte>()
        for ((key, value) in environment) { expected.add(all: (key + "=" + value + "\n").toArray()) }
        let issued = if (fixture.bound) { managedRecoveryReadIssued(fixture.inventory, fixture.parent) } else { 0 }
        let expectedFields = HashMap<String, String>(environment)
        if (fixture.bound) {
            expectedFields["METIS_PROCESS_RECOVERY_DIRECTORY"] = fixture.inventory.toString()
            expectedFields["METIS_PROCESS_RECOVERY_PARENT"] = fixture.parent
            expectedFields["METIS_PROCESS_RECOVERY_BROKER_KEY"] = "r-${issued + 1}"
            expectedFields["METIS_PROCESS_RECOVERY_OWNER_PID"] = getProcessId().toString()
            expectedFields["METIS_PROCESS_RECOVERY_OWNER_BIRTH"] = observeProcessBirthIdentity(getProcessId()).getOrThrow().serialize()
        }
        let result = fixture.capture("/usr/bin/env", [], environment)
        gateCompatResult(fixture.home, index, result)
        gateCompatCheck(result[0] == 0 && result[2].isEmpty())
        if (!fixture.bound) { gateCompatCheck(result[1] == expected.toArray()) }
        let text = try { String.fromUtf8(result[1]) }
            catch (_: Exception) { throw Exception("native_gate_compat_invalid_encoding") }
        let lines = text.split("\n")
        gateCompatCheck(lines.size == expectedFields.size + 1 && lines[lines.size - 1].isEmpty())
        let actualFields = HashMap<String, String>()
        for (line in lines[..lines.size - 1]) {
            let parts = line.split("=")
            gateCompatCheck(parts.size >= 2 && !actualFields.contains(parts[0]))
            actualFields[parts[0]] = String.join(parts[1..], delimiter: "=")
        }
        gateCompatCheck(actualFields.size == expectedFields.size)
        for ((key, value) in expectedFields) {
            gateCompatCheck(actualFields.contains(key) && actualFields[key] == value)
        }
        gateCompatCheck(!actualFields.contains("MISSING") && actualFields.contains("EMPTY") && actualFields["EMPTY"].isEmpty())
        fixture.environmentExpectedKeys = expectedFields.size
        if (fixture.bound) {
            gateCompatCheck(managedRecoveryReadIssued(fixture.inventory, fixture.parent) == issued + 1)
            fixture.environmentIssuedDelta += 1
        }
        if (index == 0) { fixture.baseline(); continue }
        for (key in ["", "EMPTY", "PATH"]) { transcript.add(all: (key + "=" + actualFields[key] + "\n").toArray()) }
        fixture.completed += 1
        if (fixture.mode != "sdk") { fixture.checkpoint() }
    }
    gateCompatCheck(fixture.completed == 32)
    File.writeTo(fixture.home.join("captured.stdout.bin"), transcript.toArray())
    File.writeTo(fixture.home.join("captured.stderr.bin"), [])
}

private func gateCompatClone(source: Path, destination: Path): Unit {
    Directory.create(destination)
    for (entry in Directory.readFrom(source)) {
        gateCompatCheck(!entry.isSymbolicLink() && entry.isRegular())
        File.writeTo(destination.join(entry.name), File.readFrom(entry.path))
    }
}

private func gateCompatSnapshot(directory: Path): HashMap<String, Array<Byte>> {
    let result = HashMap<String, Array<Byte>>()
    for (entry in Directory.readFrom(directory)) { result[entry.name] = File.readFrom(entry.path) }
    result
}

private func gateCompatUnchanged(directory: Path, expected: HashMap<String, Array<Byte>>): Bool {
    if (Directory.readFrom(directory).size != expected.size) { return false }
    for ((name, bytes) in expected) { if (!exists(directory.join(name)) || File.readFrom(directory.join(name)) != bytes) { return false } }
    true
}

@When[os == "macOS"]
private func gateCompatPreflight(fixture: GateCompatChild): (ManagedOwnedChild, String, String) {
    let issued = managedRecoveryReadIssued(fixture.inventory, fixture.parent)
    let child = managedRecoveryLaunchOwned(fixture.home.join("truly-missing").toString(), [],
        stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
    fixture.handles.add(child); fixture.preflights += 1
    let key = "r-${issued + 1}"; let owner = key + "-o-1"
    gateCompatCheck(managedRecoveryReadIssued(fixture.inventory, fixture.parent) == issued + 1)
    let deadline = MonoTime.now() + Duration.second * 5
    while (child.isAlive() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
    gateCompatCheck(!child.isAlive())
    let text = gateCompatText(fixture.inventory.join(owner + ".exec_error"))
    let error = managedRecoveryReadExecError(fixture.inventory, fixture.parent, fixture.binding, owner).getOrThrow()
    gateCompatCheck(error.phase == "exec" && error.error == 2)
    let fields = gateCompatFields(text)
    gateCompatCheck(fields["helper_pid"] == child.pid.toString())
    gateCompatCheck(parseProcessBirthIdentity(fields["helper_birth"]).getOrThrow().pid == child.pid)
    gateCompatCheck(parseProcessBirthIdentity(fields["owner_birth"]).getOrThrow().pid == Int64.parse(fields["owner_pid"]))
    File.writeTo(fixture.home.join("preflight-original.exec_error"), text.toArray())
    (child, key, text)
}

@When[os == "macOS"]
private func gateCompatFacts(fixture: GateCompatChild): Unit {
    let (child, key, text) = gateCompatPreflight(fixture)
    let fields = gateCompatFields(text); let owner = key + "-o-1"
    let root = fixture.home.join("snapshots"); Directory.create(root)
    let labels = ["binding", "parent", "helper-key", "helper-birth", "owner-birth", "binary", "duplicate", "errno", "errno-zero", "oversize", "replacement", "spawn-contradiction", "spawn-errno"]
    var formal = false
    try {
        for (label in labels) {
            File.writeTo(fixture.home.join("fact-current-step"), label.toArray())
            let copy = root.join(label); gateCompatClone(fixture.inventory, copy)
            var bytes = text.toArray()
            if (label == "binding") { bytes = text.replace("binding:" + fixture.binding, "binding:other-generation中文😀").toArray() }
            if (label == "parent") { bytes = text.replace("parent:" + fixture.parent, "parent:wrong-parent").toArray() }
            if (label == "helper-key") { bytes = text.replace("helper_key:" + key, "helper_key:wrong-key").toArray() }
            if (label == "helper-birth") { bytes = text.replace("helper_birth:" + fields["helper_birth"], "helper_birth:" + fields["owner_birth"]).toArray() }
            if (label == "owner-birth") { bytes = text.replace("owner_birth:" + fields["owner_birth"], "owner_birth:" + fields["helper_birth"]).toArray() }
            if (label == "binary") { bytes = [0xffu8, 0xfeu8] }
            if (label == "duplicate") { bytes = text.replace("key:" + owner + "\n", "key:" + owner + "\nkey:" + owner + "\n").toArray() }
            if (label == "errno") { bytes = text.replace("errno:2\n", "errno:02\n").toArray() }
            if (label == "errno-zero") { bytes = text.replace("errno:2\n", "errno:0\n").toArray() }
            if (label == "oversize") { bytes = Array<Byte>(8193, repeat: 65) }
            if (label == "spawn-contradiction") { bytes = text.replace("phase:exec\n", "phase:spawn\n").toArray() }
            if (label == "spawn-errno") { bytes = text.replace("phase:exec\n", "phase:spawn\n").replace("errno:2\n", "errno:15\n").toArray() }
            File.writeTo(copy.join(owner + ".exec_error"), bytes)
            if (label == "replacement") {
                let header = gateCompatText(copy.join("inventory"))
                File.writeTo(copy.join("inventory"), header.replace("binding:" + fixture.binding, "binding:replacement中文😀").toArray())
            }
            let before = gateCompatSnapshot(copy)
            var pending = false
            try { let _ = managedRecoveryReadExecError(copy, fixture.parent, fixture.binding, owner) }
            catch (error: Exception) { pending = error.message == "process_recovery_exec_error_pending" }
            gateCompatCheck(pending)
            gateCompatCheck(!managedRecoveryRetireRoot((copy.toString(), fixture.parent), key, child.pid, expectedBinding: Some(fixture.binding), expectedExecText: Some(text)))
            gateCompatCheck(gateCompatUnchanged(copy, before)); fixture.rejected += 1
        }
        for (phase in ["setup", "protocol", "channel"]) {
            File.writeTo(fixture.home.join("fact-current-step"), phase.toArray())
            let copy = root.join(phase); gateCompatClone(fixture.inventory, copy)
            let variant = text.replace("phase:exec\n", "phase:${phase}\n").replace("errno:2\n", "errno:0\n")
            File.writeTo(copy.join(owner + ".exec_error"), variant.toArray())
            let observed = managedRecoveryReadExecError(copy, fixture.parent, fixture.binding, owner).getOrThrow()
            gateCompatCheck(observed.phase == phase && observed.error == 0 && observed.phase != "exec")
            gateCompatCheck(managedRecoveryRetireRoot((copy.toString(), fixture.parent), key, child.pid,
                expectedBinding: Some(fixture.binding), expectedExecText: Some(observed.originalText)))
            gateCompatCheck(!exists(copy.join(owner + ".exec_error")) && managedRecoveryReadRootCheckpoint(copy, fixture.parent).getOrThrow().covers(key))
            fixture.validUnknown += 1
        }
        for (label in ["valid-A-to-B", "absent-to-present", "present-to-absent"]) {
            File.writeTo(fixture.home.join("fact-current-step"), label.toArray())
            let copy = root.join(label); gateCompatClone(fixture.inventory, copy)
            let path = copy.join(owner + ".exec_error")
            var cached = text
            if (label == "absent-to-present") {
                remove(path)
                gateCompatCheck(managedRecoveryReadExecError(copy, fixture.parent, fixture.binding, owner).isNone())
                cached = ""
                File.writeTo(path, text.toArray())
            } else {
                let observed = managedRecoveryReadExecError(copy, fixture.parent, fixture.binding, owner).getOrThrow()
                cached = observed.originalText
                gateCompatCheck(cached == text)
                if (label == "present-to-absent") { remove(path) }
                else {
                    let variant = text.replace("errno:2\n", "errno:13\n")
                    File.writeTo(path, variant.toArray())
                    gateCompatCheck(managedRecoveryReadExecError(copy, fixture.parent, fixture.binding, owner).getOrThrow().originalText == variant)
                }
            }
            let before = gateCompatSnapshot(copy)
            gateCompatCheck(!managedRecoveryRetireRoot((copy.toString(), fixture.parent), key, child.pid,
                expectedBinding: Some(fixture.binding), expectedExecText: Some(cached)))
            gateCompatCheck(gateCompatUnchanged(copy, before)); fixture.rejected += 1
        }
        gateCompatCheck(fixture.rejected == labels.size + 3 && fixture.validUnknown == 3)
        gateCompatCheck(gateCompatText(fixture.inventory.join(owner + ".exec_error")) == text)
        formal = true
    } finally {
        let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("recordedBeforeFallback", JsonBool(true))
        proof.put("invalidRejected", JsonInt(fixture.rejected)); proof.put("validUnknown", JsonInt(fixture.validUnknown))
        File.writeTo(fixture.home.join("mutants-formal-before-authoritative-cleanup.json"), proof.toJsonString().toArray())
    }
    gateCompatCheck(child.wait(timeout: Some(Duration.second * 5)) == 125 && child.wait() == 125)
    child.closeStreams(); gateCompatCheck(child.streamsAreClosed())
    fixture.completed = labels.size + 6
    fixture.baseline(); fixture.checkpoint()
}

@When[os == "macOS"]
private func gateCompatCapacity(fixture: GateCompatChild): Unit {
    let initialIssued = managedRecoveryReadIssued(fixture.inventory, fixture.parent)
    let (preflight, _, _) = gateCompatPreflight(fixture)
    gateCompatCheck(preflight.wait(timeout: Some(Duration.second * 5)) == 125 && preflight.wait() == 125)
    preflight.closeStreams(); gateCompatCheck(preflight.streamsAreClosed())
    let coldFd = ownedTestFdCount(); let coldTasks = getThreadCount(); let coldBlocking = getBlockingThreadCount()
    let held = managedRecoveryLaunchOwned("/bin/sleep", ["300"], stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
    fixture.handles.add(held); fixture.heldLaunches += 1
    fixture.baseline()
    let issued = managedRecoveryReadIssued(fixture.inventory, fixture.parent)
    for (index in 1..=1000) {
        let worker = spawn {
            var typed = false
            try {
                let returned = managedRecoveryExecuteWithOutput(fixture.home.join("truly-missing").toString(), [])
                gateCompatResult(fixture.home, index, returned)
            } catch (_: ProcessException) { typed = true }
            catch (_: Exception) {
                File.writeTo(fixture.home.join("capacity-first-failure"), ("ordinal:${index}\ncategory:other_exception\n").toArray())
                throw Exception("native_gate_capacity_wrong_category")
            }
            if (!typed) { File.writeTo(fixture.home.join("capacity-first-failure"), ("ordinal:${index}\ncategory:returned\n").toArray()) }
            typed
        }
        fixture.workers.add(worker)
        gateCompatCheck(worker.get(Duration.second * 5) && held.isAlive())
        fixture.completed += 1; fixture.checkpoint(active: true)
        gateCompatCheck(managedRecoveryReadIssued(fixture.inventory, fixture.parent) == issued + index)
        var live: Int64 = 0
        for (entry in Directory.readFrom(fixture.inventory)) {
            if (!["inventory", ".issued", ".resource-claim", "roots.closed"].contains(entry.name)) { live += 1 }
        }
        gateCompatCheck(live <= 4096)
        let checkpoint = managedRecoveryReadRootCheckpoint(fixture.inventory, fixture.parent).getOrThrow()
        gateCompatCheck(checkpoint.ranges.size <= 257)
        gateCompatCheck(gateCompatText(fixture.inventory.join("roots.closed")).size <= 16384)
        if (index % 100 == 0) { println("R-NG-C1 completed=${index};formalTarget=1000;activeGap=1") }
    }
    fixture.formalIssuedDelta = managedRecoveryReadIssued(fixture.inventory, fixture.parent) - issued
    gateCompatCheck(fixture.completed == 1000 && fixture.formalIssuedDelta == 1000)
    let code = managedRecoveryExecuteWithOutput("/bin/sh", ["-c", "exit 126"])
    gateCompatCheck(code[0] == 126 && code[1].isEmpty() && code[2].isEmpty())
    fixture.legitimateLaunches += 1; fixture.checkpoint(active: true)
    gateCompatCheck(fixture.preflights == 1 && fixture.heldLaunches == 1 && fixture.legitimateLaunches == 1)
    fixture.totalHelpers = managedRecoveryReadIssued(fixture.inventory, fixture.parent) - initialIssued
    gateCompatCheck(fixture.totalHelpers == 1003)
    held.terminate(); gateCompatCheck(held.wait(timeout: Some(Duration.second * 5)) >= 0)
    let heldCode = held.wait(); gateCompatCheck(heldCode >= 0 && heldCode <= 255)
    held.closeStreams(); gateCompatCheck(held.streamsAreClosed())
    let final = managedRecoveryProbeRecords(fixture.inventory, fixture.parent, fixture.binding, MonoTime.now() + Duration.second * 2)
    gateCompatCheck(final.ok && final.terminal)
    gateCompatCheck(ownedTestFdCount() == coldFd && getThreadCount() <= coldTasks && getBlockingThreadCount() <= coldBlocking)
}

@When[os == "macOS"]
private func gateCompatBusiness125(fixture: GateCompatChild): Unit {
    fixture.baseline()
    let environment = HashMap<String, String>(); environment["PATH"] = "/usr/bin:/bin"
    let result = fixture.capture("/bin/sh", ["-c", "printf '业务125😀\\000\\377'; printf '错误125😀\\376' >&2; exit 125"], environment)
    let expected = ArrayList<Byte>(); expected.add(all: "业务125😀".toArray()); expected.add(all: [0u8, 0xffu8])
    let error = ArrayList<Byte>(); error.add(all: "错误125😀".toArray()); error.add(0xfeu8)
    gateCompatResult(fixture.home, 0, result)
    gateCompatCheck(result[0] == 125 && result[1] == expected.toArray() && result[2] == error.toArray())
    File.writeTo(fixture.home.join("captured.stdout.bin"), result[1]); File.writeTo(fixture.home.join("captured.stderr.bin"), result[2])
    fixture.completed = 1; fixture.legitimateLaunches = 1
    if (fixture.mode != "sdk") { fixture.checkpoint() }
}

@When[os == "macOS"]
private func gateCompatEmpty(fixture: GateCompatChild): Unit {
    fixture.baseline()
    for (invalidCwd in [false, true]) {
        var actual = "returned"
        let cwd = if (invalidCwd) { fixture.home.join("missing-directory") } else { fixture.home }
        try {
            if (fixture.mode == "sdk") { let _ = executeWithOutput("", [], workingDirectory: Some(cwd)) }
            else { let _ = managedRecoveryExecuteWithOutput("", [], workingDirectory: Some(cwd)) }
        } catch (_: ProcessException) { actual = "process_exception" }
        catch (_: IllegalArgumentException) { actual = "illegal_argument" }
        catch (_: Exception) { actual = "other_exception" }
        let expected = if (invalidCwd) { "illegal_argument" } else { "process_exception" }
        let proof = JsonObject(); proof.put("invalidCwd", JsonBool(invalidCwd)); proof.put("category", JsonString(actual))
        File.writeTo(fixture.home.join("empty-${fixture.completed}.json"), proof.toJsonString().toArray())
        gateCompatCheck(actual == expected)
        fixture.completed += 1
        if (fixture.mode != "sdk") { fixture.checkpoint() }
    }
    if (fixture.bound) { gateCompatCheck(managedRecoveryReadIssued(fixture.inventory, fixture.parent) == 0) }
}

@When[os == "macOS"]
private func gateCompatUnknown(fixture: GateCompatChild): Unit {
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
    let dev = fixture.home.join("private-dev")
    Directory.create(dev.join("scripts"), recursive: true)
    Directory.create(dev.join("src/process"), recursive: true)
    Directory.create(dev.join("target/native"), recursive: true)
    for (name in ["scripts/metis-stdio-broker.mjs", "src/process/managed_exec_gate.c", "build.cj"]) {
        let bytes = File.readFrom(project.join(name))
        File.writeTo(dev.join(name), bytes)
        gateCompatCheck(File.readFrom(dev.join(name)) == bytes)
    }
    let asset = dev.join("target/native/metis-exec-gate-v1")
    let actor = "#!/bin/sh\n" +
        "case \"$METIS_GATE_COMPAT_HOME\" in /private/tmp/*) ;; *) exit 125 ;; esac\n" +
        "case \"$METIS_PROCESS_RECOVERY_DIRECTORY\" in /private/tmp/*) ;; *) exit 125 ;; esac\n" +
        "journal=$METIS_PROCESS_RECOVERY_DIRECTORY\nkey=$METIS_PROCESS_RECOVERY_BROKER_KEY\n" +
        "while [ ! -f \"$journal/$key-o-1.birth\" ]; do /bin/sleep 0.01; done\n" +
        "/bin/cat \"$journal/$key.birth\" > \"$METIS_GATE_COMPAT_HOME/unknown-helper.birth\" || exit 125\n" +
        "/bin/cat \"$journal/$key-o-1.birth\" > \"$METIS_GATE_COMPAT_HOME/unknown-owner.birth\" || exit 125\n" +
        "printf 'METIS-EXEC-GATE:9:00000000000000000000000000000000\\n' >&3\n/bin/sleep 300\n"
    File.writeTo(asset, actor.toArray()); chmod(asset.toString(), UInt32(0o755))
    let oldScript = getVariable("METIS_STDIO_BROKER_SCRIPT")
    setVariable("METIS_STDIO_BROKER_SCRIPT", dev.join("scripts/metis-stdio-broker.mjs").toString())
    var stopped = false
    try {
        fixture.baseline()
        let marker = fixture.home.join("unexpected-business-marker")
        let issued = managedRecoveryReadIssued(fixture.inventory, fixture.parent)
        let worker = spawn {
            var category = "returned"
            try { let _ = managedRecoveryExecuteWithOutput("/usr/bin/touch", [marker.toString()]) }
            catch (_: ProcessException) { category = "process_exception" }
            catch (error: Exception) {
                category = if (error.message == "owned_process_exec_outcome_unknown") { "ordinary_unknown" } else { "other_exception" }
            }
            let proof = JsonObject(); proof.put("category", JsonString(category))
            File.writeTo(fixture.home.join("unknown-category.json"), proof.toJsonString().toArray())
            category == "ordinary_unknown"
        }
        fixture.workers.add(worker)
        gateCompatCheck(worker.get(Duration.second * 5) && !exists(marker))
        let key = "r-${issued + 1}"
        for (name in ["unknown-helper.birth", "unknown-owner.birth"]) {
            let text = gateCompatText(fixture.home.join(name))
            let fields = managedRecoveryParseFields(text).getOrThrow()
            let expectedKey = if (name == "unknown-helper.birth") { key } else { key + "-o-1" }
            gateCompatCheck(fields.size == 6 && fields["phase"] == "birth" && fields["parent"] == fixture.parent && fields["key"] == expectedKey)
            let birth = parseProcessBirthIdentity(fields["birth"]).getOrThrow()
            gateCompatCheck(birth.pid == Int64.parse(fields["pid"]) &&
                Int64.parse(fields["pgid"]) == if (name == "unknown-helper.birth") { 0 } else { birth.pid })
            let observed = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second * 2)
            gateCompatCheck(observed.conclusive && !observed.alive)
        }
        gateCompatCheck(managedRecoveryReadIssued(fixture.inventory, fixture.parent) == issued + 1)
        gateCompatCheck(managedRecoveryReadRootCheckpoint(fixture.inventory, fixture.parent).getOrThrow().covers(key))
        fixture.checkpoint()
        stopped = managedRecoveryStopOwnedChildren((fixture.inventory.toString(), fixture.parent), MonoTime.now() + Duration.second * 5)
        gateCompatCheck(stopped)
        let source = managedRecoveryProbeRecords(fixture.inventory, fixture.parent, fixture.binding, MonoTime.now() + Duration.second * 2)
        gateCompatCheck(source.ok && source.terminal)
        fixture.completed = 1
    } finally {
        // Only the isolated selfchild map changed; keep its override if cleanup remains unknown.
        if (stopped) {
            match (oldScript) { case Some(value) => setVariable("METIS_STDIO_BROKER_SCRIPT", value) case None => removeVariable("METIS_STDIO_BROKER_SCRIPT") }
        }
    }
}

@When[os == "macOS"]
private func gateCompatChild(kind: String): Unit {
    let fixture = GateCompatChild()
    try {
        if (kind == "stdin") { gateCompatStdin(fixture) }
        else if (kind == "environment") { gateCompatEnvironment(fixture) }
        else if (kind == "facts") { gateCompatFacts(fixture) }
        else if (kind == "capacity") { gateCompatCapacity(fixture) }
        else if (kind == "business125") { gateCompatBusiness125(fixture) }
        else if (kind == "empty") { gateCompatEmpty(fixture) }
        else if (kind == "unknown") { gateCompatUnknown(fixture) }
        else { throw Exception("native_gate_compat_kind_invalid") }
        fixture.passed = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
private func gateCompatParent(kind: String, method: String): Unit {
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let originalDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let originalParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let originalEmpty = getVariable("EMPTY"); let originalMissing = getVariable("MISSING")
    let children = ArrayList<ManagedOwnedChild>()
    var passed = false
    let result = JsonObject(); result.put("formal", JsonBool(false))
    println("R-NG-COMPAT fixture=${home.fileName};nonce=${nonce};kind=${kind}")
    try {
        let modes = if (kind == "stdin" || kind == "environment" || kind == "business125" || kind == "empty") { ["sdk", "absent", "bound"] } else { ["bound"] }
        for (mode in modes) {
            let directory = home.join(mode); Directory.create(directory)
            File.writeTo(directory.join("owner"), ("native-gate-compat-v1\n" + nonce).toArray())
            let inputBytes = ArrayList<Byte>()
            for (_ in 0..33) { inputBytes.add(all: gateCompatInput()) }
            File.writeTo(directory.join("input.bin"), inputBytes.toArray())
            let environment = HashMap<String, String>()
            for ((key, value) in getVariables()) {
                if (["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "CANGJIE_HOME", "CANGJIE_PATH", "CANGJIE_STDX_PATH",
                    "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "cjHeapSize"].contains(key)) { environment[key] = value }
            }
            environment["METIS_GATE_COMPAT_HOME"] = directory.toString(); environment["METIS_GATE_COMPAT_MODE"] = mode
            environment["METIS_GATE_COMPAT_NONCE"] = nonce; environment["METIS_GATE_COMPAT_KIND"] = kind
            environment["METIS_HOME"] = directory.toString()
            environment["METIS_CJPM_ROOT"] = canonicalize(Path(getVariable("METIS_CJPM_ROOT") ?? ".")).toString()
            environment["METIS_STDIO_BROKER_NODE_COMMAND"] = managedStdioResolveNodeCommand()
            try (input = File(directory.join("input.bin"), OpenMode.ReadWrite), output = File(directory.join("stdout"), OpenMode.Write),
                error = File(directory.join("stderr"), OpenMode.Write)) {
                let child = launchManagedRawChild(getCommand(), ["--filter=ManagedExecGateCompatTest.${method}", "--parallel=1",
                    "--no-progress", "--no-color", "--no-capture-output"], environment: Some<Map<String, String>>(environment),
                    workingDirectory: Some(directory), newGeneration: true, stdIn: ProcessRedirect.FromFile(input),
                    stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
                children.add(child)
                gateCompatCheck(child.wait(timeout: Some(Duration.second * (if (kind == "capacity") { 300 } else { 60 }))) == 0)
                gateCompatCheck(child.wait() == 0); child.closeStreams()
                gateCompatCheck(!child.isAlive() && child.streamsAreClosed() && !input.isClosed() && !output.isClosed() && !error.isClosed())
                input.seek(SeekPosition.Begin(0))
                let read = Array<Byte>(inputBytes.size, repeat: 0)
                gateCompatCheck(input.read(read) == inputBytes.size && read == inputBytes.toArray())
                input.seek(SeekPosition.End(0)); input.write("caller仍拥有😀".toArray()); input.flush()
            }
            let proof = JsonValue.fromStr(gateCompatText(directory.join("child-formal-before-fallback.json"))).asObject()
            gateCompatCheck(proof.get("formal").getOrThrow().asBool().getValue() && proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue())
            gateCompatCheck(proof.get("completed").getOrThrow().asInt().getValue() == if (kind == "capacity") { 1000 } else if (kind == "facts") { 19 } else if (kind == "business125") { 1 } else if (kind == "empty") { 2 } else if (kind == "unknown") { 1 } else { 32 })
            let cleanup = JsonValue.fromStr(gateCompatText(directory.join("child-cleanup.json"))).asObject()
            gateCompatCheck(cleanup.get("terminal").getOrThrow().asBool().getValue())
        }
        if (kind == "stdin" || kind == "environment" || kind == "business125") {
            for (stream in ["captured.stdout.bin", "captured.stderr.bin"]) {
                let sdk = File.readFrom(home.join("sdk").join(stream))
                gateCompatCheck(File.readFrom(home.join("absent").join(stream)) == sdk && File.readFrom(home.join("bound").join(stream)) == sdk)
            }
        }
        gateCompatCheck(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY") == originalDirectory && getVariable("METIS_PROCESS_RECOVERY_PARENT") == originalParent)
        gateCompatCheck(getVariable("EMPTY") == originalEmpty && getVariable("MISSING") == originalMissing)
        passed = true
    } finally {
        result.put("formal", JsonBool(passed)); result.put("recordedBeforeFallback", JsonBool(true))
        File.writeTo(home.join("parent-formal-before-fallback.json"), result.toJsonString().toArray())
        var terminal = true
        for (child in children) {
            try {
                if (child.isAlive()) { child.terminate() }
                let code = child.wait(timeout: Some(Duration.second * (if (kind == "capacity" || kind == "facts" || kind == "unknown") { 5 } else { 3 })))
                child.closeStreams(); terminal = terminal && code >= 0 && code <= 255 && !child.isAlive() && child.streamsAreClosed()
            } catch (_: Exception) { terminal = false }
        }
        var resourcesTerminal = terminal
        for (entry in Directory.readFrom(home)) {
            if (!entry.isDirectory() || entry.name != "bound") { continue }
            let inventory = entry.path.join("inventory")
            try {
                let header = managedRecoveryParseFields(gateCompatText(inventory.join("inventory"))).getOrThrow()
                let source = managedRecoveryProbeRecords(inventory, header["parent"], header["binding"], MonoTime.now() + Duration.second * 2)
                resourcesTerminal = resourcesTerminal && source.ok && source.terminal
            } catch (_: Exception) { resourcesTerminal = false }
        }
        let cleanup = JsonObject(); cleanup.put("driverTerminal", JsonBool(terminal))
        cleanup.put("resourcesTerminal", JsonBool(resourcesTerminal)); cleanup.put("formal", JsonBool(passed))
        File.writeTo(home.join("parent-cleanup.json"), cleanup.toJsonString().toArray())
        println("R-NG-COMPAT retained;formal=${passed};driverTerminal=${terminal};resourcesTerminal=${resourcesTerminal}")
    }
}

@When[os == "macOS"]
@Test
public class ManagedExecGateCompatTest {
    @TestCase
    public func nativeGateStdinP1ThreeModesThirtyTwoRawCaptures(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("stdin")) { gateCompatChild("stdin"); return }
        gateCompatParent("stdin", "nativeGateStdinP1ThreeModesThirtyTwoRawCaptures")
    }

    @TestCase
    public func nativeGateEnvP1EmptyAndMissingKeysPreserveRawEnvironment(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("environment")) { gateCompatChild("environment"); return }
        gateCompatParent("environment", "nativeGateEnvP1EmptyAndMissingKeysPreserveRawEnvironment")
    }

    @TestCase
    public func nativeGateExec125ThreeModesPreserveGenuineBusinessResult(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("business125")) { gateCompatChild("business125"); return }
        gateCompatParent("business125", "nativeGateExec125ThreeModesPreserveGenuineBusinessResult")
    }

    @TestCase
    public func nativeGateEmptyP1ThreeModesKeepValidationPriority(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("empty")) { gateCompatChild("empty"); return }
        gateCompatParent("empty", "nativeGateEmptyP1ThreeModesKeepValidationPriority")
    }

    @TestCase
    public func nativeGateUnknownP1PublicCaptureRetiresRealVersionFailure(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("unknown")) { gateCompatChild("unknown"); return }
        gateCompatParent("unknown", "nativeGateUnknownP1PublicCaptureRetiresRealVersionFailure")
    }

    @TestCase
    public func nativeGateFactN1ActualBirthBoundSnapshotsStayStrict(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("facts")) { gateCompatChild("facts"); return }
        gateCompatParent("facts", "nativeGateFactN1ActualBirthBoundSnapshotsStayStrict")
    }

    @TestCase
    public func nativeGateFactC1ThousandCapturesKeepActualActiveGap(): Unit {
        if (getVariable("METIS_GATE_COMPAT_KIND") == Some("capacity")) { gateCompatChild("capacity"); return }
        gateCompatParent("capacity", "nativeGateFactC1ThousandCapturesKeepActualActiveGap")
    }
}
