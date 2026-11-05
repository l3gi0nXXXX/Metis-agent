package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, removeVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists}
import std.process.{ProcessRedirect, executeWithOutput}
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.sort.sort
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*
import stdx.crypto.digest.SHA256

private let cfEnvironmentKey = "__CF_USER_TEXT_ENCODING"
private let cfWitnessKey = "METIS_STDIO_ATTACHED_CF_ENV_V1"

private func cfEnvironmentRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("cf_environment_contract_failed") }
}

private func cfEnvironmentText(bytes: Array<Byte>): String {
    try { String.fromUtf8(bytes) }
    catch (_: Exception) { throw Exception("cf_environment_invalid_encoding") }
}

private func cfEnvironmentNul(): String { cfEnvironmentText([0u8]) }

private func cfEnvironmentOriginal(index: Int64): ?String {
    match (index) {
        case 0 => None<String>
        case 1 => Some("")
        case 2 => Some("0x0:'合成中文😀':\"引号\"\n下一行")
        case 3 => Some("0x0:0:0")
        case _ => throw Exception("cf_environment_case_invalid")
    }
}

private func cfEnvironmentMarker(index: Int64): ?String {
    match (index) {
        case 0 => None<String>
        case 1 => Some("")
        case 2 => Some("用户见证'\"中文😀\n下一行")
        case _ => throw Exception("cf_environment_case_invalid")
    }
}

private func cfEnvironmentSet(values: HashMap<String, String>, key: String, value: ?String): Unit {
    match (value) {
        case Some(text) => values[key] = text
        case None => values.remove(key); ()
    }
}

private func cfEnvironmentRecordInput(home: Path, values: HashMap<String, String>): Unit {
    let proof = JsonObject()
    for ((key, value) in values) { proof.put(key, JsonString(value)) }
    File.writeTo(home.join("input-environment.json"), proof.toJsonString().toArray())
}

private func cfEnvironmentParse(bytes: Array<Byte>): HashMap<String, String> {
    let text = cfEnvironmentText(bytes)
    let records = text.split(cfEnvironmentNul())
    cfEnvironmentRequire(records.size > 1 && records[records.size - 1].isEmpty())
    let result = HashMap<String, String>()
    for (record in records[..records.size - 1]) {
        let parts = record.split("=")
        cfEnvironmentRequire(parts.size >= 2 && !result.contains(parts[0]))
        result[parts[0]] = String.join(parts[1..], delimiter: "=")
    }
    result
}

private func cfEnvironmentCanonical(values: HashMap<String, String>): Array<Byte> {
    let keys = values.keys().toArray(); sort(keys)
    let result = ArrayList<Byte>()
    for (key in keys) { result.add(all: (key + "=" + values[key] + cfEnvironmentNul()).toArray()) }
    result.toArray()
}

private func cfEnvironmentSha(bytes: Array<Byte>): String {
    let sha = SHA256(); sha.write(bytes)
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    let result = StringBuilder()
    for (byte in sha.finish()) { result.append(digits[Int64(byte >> 4)]); result.append(digits[Int64(byte & 0x0f)]) }
    result.toString()
}

@When[os == "macOS"]
private func cfEnvironmentGroupGone(pid: Int64): Bool {
    if (pid <= 1 || pid > 2147483647) { return false }
    unsafe { kill(-Int32(pid), Int32(0)) } != 0 && unsafe { __error().read() } == 3
}

private class CfEnvironmentOutcome {
    var returned: ?ManagedOwnedChild = None
    var result: ?(Int64, Array<Byte>, Array<Byte>) = None
    var category = "not_completed"
}

@When[os == "macOS"]
private class CfEnvironmentChild {
    let home: Path
    let mode: String
    let kind: String
    let parent: String
    let binding: String
    let inventory: Path
    let bound: Bool
    let state = CfEnvironmentOutcome()
    let workers = ArrayList<Future<Bool>>()
    let baselineFd: Int64
    let baselineTasks: Int64
    let baselineBlocking: Int64
    var passed = false
    var sourceTerminalBeforeFallback = false
    var workerJoined = false
    var issuedDelta: Int64 = 0
    var actualKeys: Int64 = 0

    init() {
        home = canonicalize(Path(getVariable("METIS_CF_ENV_HOME").getOrThrow()))
        mode = getVariable("METIS_CF_ENV_MODE").getOrThrow()
        kind = getVariable("METIS_CF_ENV_KIND").getOrThrow()
        let nonce = getVariable("METIS_CF_ENV_NONCE").getOrThrow()
        cfEnvironmentRequire(home.toString().startsWith("/private/tmp/") &&
            cfEnvironmentText(File.readFrom(home.join("owner"))) == "cf-environment-v1\n" + nonce)
        cfEnvironmentRequire(["sdk", "absent", "bound"].contains(mode))
        cfEnvironmentRequire(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").isNone() && getVariable("METIS_PROCESS_RECOVERY_PARENT").isNone())
        parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        binding = "cf-环境中文😀-" + nonce
        inventory = home.join("inventory")
        bound = mode == "bound"
        if (bound) { cfEnvironmentRequire(managedRecoveryInitialize(inventory, parent, binding)) }
        baselineFd = ownedTestFdCount(); baselineTasks = getThreadCount(); baselineBlocking = getBlockingThreadCount()
    }

    func capture(values: HashMap<String, String>): (Int64, Array<Byte>, Array<Byte>) {
        if (mode == "sdk") {
            executeWithOutput("/usr/bin/env", ["-0"], environment: Some<Map<String, String>>(values), workingDirectory: Some(home))
        } else {
            managedRecoveryExecuteWithOutput("/usr/bin/env", ["-0"], environment: Some<Map<String, String>>(values), workingDirectory: Some(home))
        }
    }

    func sourceTerminal(): Bool {
        if (!bound) { return true }
        let proof = managedRecoveryProbeRecords(inventory, parent, binding, MonoTime.now() + Duration.second * 5)
        proof.ok && proof.terminal
    }

    func checkpoint(): Unit {
        if (mode != "sdk") {
            cfEnvironmentRequire(ownedTestFdCount() == baselineFd)
            cfEnvironmentRequire(getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking)
        }
        sourceTerminalBeforeFallback = sourceTerminal()
        cfEnvironmentRequire(workerJoined && sourceTerminalBeforeFallback)
    }

    func saveResult(): Unit {
        if (let Some(value) <- state.result) {
            File.writeTo(home.join("business.stdout.bin"), value[1]); File.writeTo(home.join("business.stderr.bin"), value[2])
            File.writeTo(home.join("business-code"), value[0].toString().toArray())
        }
    }

    func finish(): Unit {
        if (workerJoined) { saveResult() }
        let proof = JsonObject(); proof.put("formal", JsonBool(passed)); proof.put("mode", JsonString(mode)); proof.put("kind", JsonString(kind))
        proof.put("category", JsonString(if (workerJoined) { state.category } else { "operation_pending" })); proof.put("workerJoined", JsonBool(workerJoined))
        proof.put("sourceTerminalBeforeFallback", JsonBool(sourceTerminalBeforeFallback)); proof.put("issuedDelta", JsonInt(issuedDelta))
        proof.put("actualKeys", JsonInt(actualKeys)); proof.put("baselineFd", JsonInt(baselineFd)); proof.put("formalFd", JsonInt(ownedTestFdCount()))
        proof.put("baselineTasks", JsonInt(baselineTasks)); proof.put("formalTasks", JsonInt(getThreadCount()))
        proof.put("baselineBlocking", JsonInt(baselineBlocking)); proof.put("formalBlocking", JsonInt(getBlockingThreadCount()))
        proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("retained", JsonBool(true))
        File.writeTo(home.join("child-formal-before-fallback.json"), proof.toJsonString().toArray())
        var terminal = true
        if (bound) { terminal = managedRecoveryStopOwnedChildren((inventory.toString(), parent), MonoTime.now() + Duration.second * 5) }
        var allWorkersJoined = true
        for (worker in workers) {
            try { let _ = worker.get(Duration.second * 5) }
            catch (_: TimeoutException) { allWorkersJoined = false }
            catch (_: Exception) { () }
        }
        terminal = terminal && allWorkersJoined
        if (allWorkersJoined) {
        if (let Some(child) <- state.returned) {
            try {
                if (child.isAlive()) { child.terminate() }
                let code = child.wait(timeout: Some(Duration.second * 5)); child.closeStreams()
                terminal = terminal && code >= 0 && code <= 255 && !child.isAlive() && child.streamsAreClosed()
            } catch (_: Exception) { terminal = false }
        }
        }
        terminal = terminal && sourceTerminal()
        File.writeTo(home.join("child-cleanup.json"), ("{\"terminal\":${terminal},\"retained\":true}").toArray())
        if (terminal && bound) { removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY"); removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
    }
}

@When[os == "macOS"]
private func cfEnvironmentPositive(child: CfEnvironmentChild, cfIndex: Int64, markerIndex: Int64): Unit {
    let original = cfEnvironmentOriginal(cfIndex); let marker = cfEnvironmentMarker(markerIndex)
    let inheritedCf = getVariable(cfEnvironmentKey); let inheritedMarker = getVariable(cfWitnessKey)
    let inherited = JsonObject(); inherited.put("cfPresent", JsonBool(inheritedCf.isSome())); inherited.put("cf", JsonString(inheritedCf ?? ""))
    inherited.put("markerPresent", JsonBool(inheritedMarker.isSome())); inherited.put("marker", JsonString(inheritedMarker ?? ""))
    File.writeTo(child.home.join("inherited-environment.json"), inherited.toJsonString().toArray())
    cfEnvironmentRequire(inheritedCf == original && inheritedMarker == marker)
    let values = HashMap<String, String>()
    values[""] = "合成中文😀"; values["EMPTY"] = ""; values["PATH"] = "/usr/bin:/bin"
    cfEnvironmentSet(values, cfEnvironmentKey, original); cfEnvironmentSet(values, cfWitnessKey, marker)
    cfEnvironmentRecordInput(child.home, values)
    let expected = HashMap<String, String>(values)
    let issued = if (child.bound) { managedRecoveryReadIssued(child.inventory, child.parent) } else { 0 }
    if (child.bound) {
        expected["METIS_PROCESS_RECOVERY_DIRECTORY"] = child.inventory.toString()
        expected["METIS_PROCESS_RECOVERY_PARENT"] = child.parent
        expected["METIS_PROCESS_RECOVERY_BROKER_KEY"] = "r-${issued + 1}"
        expected["METIS_PROCESS_RECOVERY_OWNER_PID"] = getProcessId().toString()
        expected["METIS_PROCESS_RECOVERY_OWNER_BIRTH"] = observeProcessBirthIdentity(getProcessId()).getOrThrow().serialize()
    }
    let worker = spawn { => child.state.result = Some(child.capture(values)); child.state.category = "success"; true }
    child.workers.add(worker)
    cfEnvironmentRequire(worker.get(Duration.second * 5)); child.workerJoined = true
    child.saveResult()
    let result = child.state.result.getOrThrow()
    cfEnvironmentRequire(result[0] == 0 && result[2].isEmpty())
    let actual = cfEnvironmentParse(result[1]); child.actualKeys = actual.size
    cfEnvironmentRequire(actual.size == expected.size)
    for ((key, value) in expected) { cfEnvironmentRequire(actual.contains(key) && actual[key] == value) }
    cfEnvironmentRequire(!actual.contains("MISSING") && actual["EMPTY"].isEmpty())
    let projected = HashMap<String, String>()
    for ((key, _) in values) { projected[key] = actual[key] }
    let canonical = cfEnvironmentCanonical(projected)
    cfEnvironmentRequire(canonical == cfEnvironmentCanonical(values))
    File.writeTo(child.home.join("business-projection.bin"), canonical)
    if (child.bound) {
        child.issuedDelta = managedRecoveryReadIssued(child.inventory, child.parent) - issued
        cfEnvironmentRequire(child.issuedDelta == 1)
    }
    child.checkpoint(); child.passed = true
}

@When[os == "macOS"]
private func cfEnvironmentNegative(child: CfEnvironmentChild, kind: String): Unit {
    let values = HashMap<String, String>()
    values[""] = "合成中文😀"; values["EMPTY"] = ""; values["PATH"] = "/usr/bin:/bin"
    let key = if (kind.contains("marker")) { cfWitnessKey } else { cfEnvironmentKey }
    values[key] = "非法中文😀" + cfEnvironmentNul() + "尾部"
    cfEnvironmentRecordInput(child.home, values)
    let marker = child.home.join("business-executed")
    let worker = spawn { =>
        try {
            if (kind.startsWith("raw")) {
                child.state.returned = Some(managedRecoveryLaunchOwned("/usr/bin/touch", [marker.toString()], workingDirectory: Some(child.home),
                    environment: Some<Map<String, String>>(values), stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe))
                child.state.category = "unexpected_child"
            } else {
                if (child.mode == "sdk") {
                    child.state.result = Some(executeWithOutput("/usr/bin/touch", [marker.toString()], workingDirectory: Some(child.home), environment: Some<Map<String, String>>(values)))
                } else {
                    child.state.result = Some(managedRecoveryExecuteWithOutput("/usr/bin/touch", [marker.toString()], workingDirectory: Some(child.home), environment: Some<Map<String, String>>(values)))
                }
                child.state.category = "unexpected_success"
            }
        } catch (_: IllegalArgumentException) { child.state.category = "illegal_argument" }
        catch (_: Exception) { child.state.category = "unexpected_exception" }
        child.state.category == "illegal_argument"
    }
    child.workers.add(worker)
    let typed = worker.get(Duration.second * 5); child.workerJoined = true
    child.saveResult()
    cfEnvironmentRequire(typed && child.state.returned.isNone() && !exists(marker))
    if (child.bound) { cfEnvironmentRequire(managedRecoveryReadIssued(child.inventory, child.parent) == 0) }
    child.checkpoint(); child.passed = true
}

@When[os == "macOS"]
private func cfEnvironmentChild(kind: String, cfIndex: Int64, markerIndex: Int64): Unit {
    let child = CfEnvironmentChild()
    try {
        if (kind == "positive") { cfEnvironmentPositive(child, cfIndex, markerIndex) }
        else { cfEnvironmentNegative(child, kind) }
    } finally { child.finish() }
}

@When[os == "macOS"]
private class CfEnvironmentDriver {
    let home = Directory.createTemp("/private/tmp")
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT") ?? "."))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let children = ArrayList<ManagedOwnedChild>()
    let initialFd = ownedTestFdCount()
    let initialTasks = getThreadCount()
    let initialBlocking = getBlockingThreadCount()
    var passed = false
    var completed: Int64 = 0

    init() {
        File.writeTo(home.join("owner"), ("cf-environment-suite-v1\n" + nonce).toArray())
        println("R-NG-CF-ENV fixture=${home.fileName};nonce=${nonce}")
        let inputs = home.join("source-inputs"); Directory.create(inputs)
        let hashes = JsonObject()
        for (name in ["managed_owned_child.cj", "managed_process_recovery.cj", "managed_process_recovery_roots.cj", "managed_exec_gate_environment_test.cj"]) {
            let path = project.join("src/process").join(name)
            cfEnvironmentRequire(FileInfo(path).isRegular() && !FileInfo(path).isSymbolicLink())
            let bytes = File.readFrom(path); File.writeTo(inputs.join(name), bytes)
            hashes.put(name, JsonString(cfEnvironmentSha(bytes)))
        }
        let broker = File.readFrom(project.join("scripts/metis-stdio-broker.mjs"))
        File.writeTo(inputs.join("metis-stdio-broker.mjs"), broker); hashes.put("metis-stdio-broker.mjs", JsonString(cfEnvironmentSha(broker)))
        for (relative in ["src/process/managed_exec_gate.c", "build.cj", "target/native/metis-exec-gate-v1"]) {
            let path = project.join(relative)
            cfEnvironmentRequire(FileInfo(path).isRegular() && !FileInfo(path).isSymbolicLink())
            let bytes = File.readFrom(path); File.writeTo(inputs.join(path.fileName), bytes)
            hashes.put(relative, JsonString(cfEnvironmentSha(bytes)))
        }
        let asset = FileInfo(project.join("target/native/metis-exec-gate-v1"))
        cfEnvironmentRequire(asset.lastModificationTime >= FileInfo(project.join("build.cj")).lastModificationTime &&
            asset.lastModificationTime >= FileInfo(project.join("src/process/managed_exec_gate.c")).lastModificationTime)
        File.writeTo(home.join("source-sha256.json"), hashes.toJsonString().toArray())
    }

    func run(mode: String, kind: String, cfIndex: Int64, markerIndex: Int64, method: String): Path {
        let directory = home.join("${mode}-${kind}-${cfIndex}-${markerIndex}"); Directory.create(directory)
        File.writeTo(directory.join("owner"), ("cf-environment-v1\n" + nonce).toArray())
        let env = HashMap<String, String>()
        for ((key, value) in getVariables()) {
            if (["PATH", "HOME", "TMPDIR", "LANG", "CANGJIE_HOME", "MAGIC_PATH", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "cjHeapSize"].contains(key)) { env[key] = value }
        }
        env["METIS_CF_ENV_HOME"] = directory.toString(); env["METIS_CF_ENV_MODE"] = mode
        env["METIS_CF_ENV_KIND"] = kind; env["METIS_CF_ENV_NONCE"] = nonce
        env["METIS_CF_ENV_CF_INDEX"] = cfIndex.toString(); env["METIS_CF_ENV_MARKER_INDEX"] = markerIndex.toString()
        env["HOME"] = directory.toString(); env["TMPDIR"] = directory.toString()
        env["METIS_HOME"] = directory.toString(); env["METIS_CJPM_ROOT"] = project.toString()
        env["METIS_STDIO_BROKER_NODE_COMMAND"] = managedStdioResolveNodeCommand()
        cfEnvironmentSet(env, cfEnvironmentKey, cfEnvironmentOriginal(cfIndex)); cfEnvironmentSet(env, cfWitnessKey, cfEnvironmentMarker(markerIndex))
        let stdin = directory.join("stdin"); File.writeTo(stdin, [])
        try (input = File(stdin, OpenMode.Read), output = File(directory.join("stdout"), OpenMode.Write), error = File(directory.join("stderr"), OpenMode.Write)) {
            let launched = launchManagedRawChild(getCommand(), ["--filter=ManagedExecGateEnvironmentTest.${method}",
                "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], newGeneration: true,
                workingDirectory: Some(project), environment: Some<Map<String, String>>(env),
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            children.add(launched)
            cfEnvironmentRequire(unsafe { getpgid(Int32(launched.pid)) } == Int32(launched.pid))
            let code = launched.wait(timeout: Some(Duration.second * 60))
            launched.closeStreams()
            cfEnvironmentRequire(code == 0 && launched.wait() == 0 && !launched.isAlive() && launched.streamsAreClosed() && cfEnvironmentGroupGone(launched.pid))
            cfEnvironmentRequire(!input.isClosed() && !output.isClosed() && !error.isClosed())
        }
        cfEnvironmentRequire(ownedTestFdCount() == initialFd && getThreadCount() <= initialTasks && getBlockingThreadCount() <= initialBlocking)
        let proof = JsonValue.fromStr(cfEnvironmentText(File.readFrom(directory.join("child-formal-before-fallback.json")))).asObject()
        let cleanup = JsonValue.fromStr(cfEnvironmentText(File.readFrom(directory.join("child-cleanup.json")))).asObject()
        cfEnvironmentRequire(proof.get("formal").getOrThrow().asBool().getValue() && proof.get("workerJoined").getOrThrow().asBool().getValue() &&
            proof.get("sourceTerminalBeforeFallback").getOrThrow().asBool().getValue() && proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue() &&
            cleanup.get("terminal").getOrThrow().asBool().getValue())
        completed += 1
        println("R-NG-CF-ENV mode=${mode};kind=${kind};case=${cfIndex * 3 + markerIndex};completed=${completed}")
        directory
    }

    func finish(): Unit {
        var terminalBefore = true
        for (child in children) { terminalBefore = terminalBefore && !child.isAlive() && child.streamsAreClosed() && cfEnvironmentGroupGone(child.pid) }
        File.writeTo(home.join("formal-before-fallback.json"),
            ("{\"formal\":${passed},\"completed\":${completed},\"terminalBeforeFallback\":${terminalBefore},\"recordedBeforeFallback\":true,\"retained\":true}").toArray())
        var terminal = true
        for (child in children) {
            try {
                if (child.isAlive()) { child.terminate() }
                let code = child.wait(timeout: Some(Duration.second * 5)); child.closeStreams()
                terminal = terminal && code >= 0 && code <= 255 && !child.isAlive() && child.streamsAreClosed() && cfEnvironmentGroupGone(child.pid)
            } catch (_: Exception) { terminal = false }
        }
        File.writeTo(home.join("cleanup.json"), ("{\"terminal\":${terminal},\"retained\":true}").toArray())
        cfEnvironmentRequire(terminal)
    }
}

@When[os == "macOS"]
@Test
public class ManagedExecGateEnvironmentTest {
    @TestCase
    public func cfEnvP1TwelveOriginalStatesAcrossThreeModes(): Unit {
        if (let Some(kind) <- getVariable("METIS_CF_ENV_KIND")) {
            let cf = Int64.parse(getVariable("METIS_CF_ENV_CF_INDEX").getOrThrow())
            let marker = Int64.parse(getVariable("METIS_CF_ENV_MARKER_INDEX").getOrThrow())
            cfEnvironmentChild(kind, cf, marker); return
        }
        let originalCf = getVariable(cfEnvironmentKey); let originalMarker = getVariable(cfWitnessKey)
        let driver = CfEnvironmentDriver()
        try {
            for (cf in 0..4) {
                for (marker in 0..3) {
                    let sdk = driver.run("sdk", "positive", cf, marker, "cfEnvP1TwelveOriginalStatesAcrossThreeModes")
                    let absent = driver.run("absent", "positive", cf, marker, "cfEnvP1TwelveOriginalStatesAcrossThreeModes")
                    let bound = driver.run("bound", "positive", cf, marker, "cfEnvP1TwelveOriginalStatesAcrossThreeModes")
                    let expected = File.readFrom(sdk.join("business-projection.bin"))
                    cfEnvironmentRequire(File.readFrom(absent.join("business-projection.bin")) == expected && File.readFrom(bound.join("business-projection.bin")) == expected)
                }
            }
            cfEnvironmentRequire(driver.completed == 36 && getVariable(cfEnvironmentKey) == originalCf && getVariable(cfWitnessKey) == originalMarker)
            driver.passed = true
        } finally { driver.finish() }
    }

    @TestCase
    public func cfEnvN1OriginalNulNeverEscapesValidation(): Unit {
        if (let Some(kind) <- getVariable("METIS_CF_ENV_KIND")) { cfEnvironmentChild(kind, 0, 0); return }
        let originalCf = getVariable(cfEnvironmentKey); let originalMarker = getVariable(cfWitnessKey)
        let driver = CfEnvironmentDriver()
        try {
            for (mode in ["sdk", "absent", "bound"]) {
                for (kind in ["capture_cf_nul", "capture_marker_nul"]) { driver.run(mode, kind, 0, 0, "cfEnvN1OriginalNulNeverEscapesValidation") }
            }
            for (kind in ["raw_cf_nul", "raw_marker_nul"]) { driver.run("bound", kind, 0, 0, "cfEnvN1OriginalNulNeverEscapesValidation") }
            cfEnvironmentRequire(driver.completed == 8 && getVariable(cfEnvironmentKey) == originalCf && getVariable(cfWitnessKey) == originalMarker)
            driver.passed = true
        } finally { driver.finish() }
    }
}
