package metis.core.tools.cj_utils

import metis.process.*
import magic.config.Config
import std.sort.sort
import metis.core.config.CliConfig
import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, OpenMode, Path, canonicalize, copy, exists, remove}
import std.io.InputStream
import std.posix.chmod
import std.process.{ProcessException, ProcessRedirect, executeWithOutput}
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

@When[os == "macOS"]
foreign { func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32 }

private func thinCheck(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("thin_interface_contract_failed") }
}
private func thinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}
private func thinRead(input: InputStream): Array<Byte> {
    let output = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = input.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { if (output.size < 65536) { output.add(buffer[index]) } }
    }
    output.toArray()
}
private func thinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}
@When[os == "macOS"]
private func thinCount(flavor: Int32): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("thin_resource_observation_failed") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}
private func thinEnvironment(): HashMap<String, String> {
    let values = HashMap<String, String>(getVariables())
    for (key in values.keys().toArray()) {
        let upper = key.toAsciiUpper()
        if (key.startsWith("METIS_PROCESS_RECOVERY_") || upper.contains("PROXY") || upper.endsWith("_TOKEN") ||
            upper.endsWith("_API_KEY") || upper.contains("SECRET") || upper.endsWith("_ACCESS_KEY_ID") ||
            upper.contains("PASSWORD") || upper.contains("CREDENTIAL")) { values.remove(key) }
    }
    values
}
@When[os == "macOS"]
private class ThinChild {
    let home: Path
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let binding: String
    let bound: Bool
    let mode: String
    let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    var fd: Int64 = 0
    var threads: Int64 = 0
    var cjTasks: Int64 = 0
    var cjBlocking: Int64 = 0
    var passed = false
    var current = Path("")
    var calls: Int64 = 0
    init() {
        home = canonicalize(Path(getVariable("METIS_THIN_TEST_HOME").getOrThrow()))
        binding = getVariable("METIS_THIN_TEST_NONCE").getOrThrow()
        mode = getVariable("METIS_THIN_TEST_MODE").getOrThrow()
        bound = mode == "bound"
        thinCheck(home.toString().startsWith("/private/tmp/") && !binding.isEmpty())
        thinCheck(thinText(home.join("owner")) == binding)
        thinCheck(oldDirectory.isNone() && oldParent.isNone())
        let actor = canonicalize(Path(getVariable("METIS_THIN_TEST_ACTOR").getOrThrow()))
        thinCheck(actor.isAbsolute() && actor == canonicalize(home.parent.join("actor")))
        thinCheck(thinText(actor.parent.join("actor.binding")) == binding + "\n" + actor.toString())
        CliConfig.workspaceDirOverride = home.toString(); CliConfig.invalidatePathCache()
        Config.logFile = home.join("magic.log").toString(); File.writeTo(home.join("magic.log"), [])
        if (bound) { thinCheck(managedRecoveryInitialize(home.join("inventory"), parent, binding)) }
        for (command in ["cjc", "cjpm", "git", "diff", "which", "rg", "grep"]) {
            copy(Path(getVariable("METIS_THIN_TEST_ACTOR").getOrThrow()), to: home.join("bin/" + command))
            chmod(home.join("bin/" + command).toString(), 0o700)
        }
    }
    func begin(name: String): Unit {
        current = home.join("cases/" + name); Directory.create(current, recursive: true)
        Directory.create(current.join("responses"))
        File.writeTo(current.join("binding"), binding.toArray())
        setVariable("METIS_THIN_ACTOR_DIRECTORY", current.toString())
        setVariable("METIS_THIN_ACTOR_NONCE", binding)
        setVariable("METIS_THIN_ACTOR_CASE", "raw_routes")
    }
    func route(command: String, output: Array<Byte>, code: Int64, error!: Array<Byte> = [], phase!: String = "main"): Unit {
        let prefix = current.join("responses/${command}.${phase}").toString()
        File.writeTo(Path(prefix + ".stdout.bin"), output)
        File.writeTo(Path(prefix + ".stderr.bin"), error)
        File.writeTo(Path(prefix + ".exit.txt"), code.toString().toArray())
    }
    func receipts(): Array<JsonObject> {
        let values = ArrayList<JsonObject>()
        for (entry in Directory.readFrom(current)) {
            if (!entry.name.startsWith("receipt-") || !entry.name.endsWith(".json")) { continue }
            let value = JsonValue.fromStr(thinText(entry.path)).asObject()
            thinCheck(value.get("nonce").getOrThrow().asString().getValue() == binding)
            thinCheck(value.get("pid").getOrThrow().asInt().getValue() > 1)
            values.add(value)
        }
        values.toArray()
    }
    func one(command: String, phase!: String = "main"): JsonObject {
        let values = ArrayList<JsonObject>()
        for (value in receipts()) {
            if (value.get("commandName").getOrThrow().asString().getValue() == command &&
                value.get("phase").getOrThrow().asString().getValue() == phase) { values.add(value) }
        }
        thinCheck(values.size == 1)
        values[0]
    }
    func args(receipt: JsonObject): Array<String> {
        let result = ArrayList<String>()
        for (value in receipt.get("args").getOrThrow().asArray().getItems()) { result.add(value.asString().getValue()) }
        result.toArray()
    }
    func sourceTerminal(): Bool {
        if (!bound) { return true }
        let proof = managedRecoveryProbeRecords(home.join("inventory"), parent, binding, MonoTime.now() + Duration.second * 2)
        proof.ok && proof.terminal
    }
    func warm(): Unit {
        if (mode != "sdk") {
            let before = thinCount(1)
            let output = managedRecoveryExecuteWithOutput("/usr/bin/true", [])
            thinCheck(output[0] == 0 && sourceTerminal() && thinCount(1) == before)
        }
        fd = thinCount(1); threads = thinCount(6)
        cjTasks = getThreadCount(); cjBlocking = getBlockingThreadCount()
        println("R-WRAP warm mode=${mode};warmFd=${fd};warmThreads=${threads};warmCjTasks=${cjTasks};warmCjBlocking=${cjBlocking}")
    }
    func checkpoint(): Unit {
        if (mode != "sdk") {
            thinCheck(sourceTerminal())
            let currentFd = thinCount(1)
            thinCheck(currentFd == fd)
            let currentThreads = thinCount(6)
            let currentCjTasks = getThreadCount(); let currentCjBlocking = getBlockingThreadCount()
            println("R-WRAP checkpoint mode=${mode};calls=${calls};warmFd=${fd};currentFd=${currentFd};warmThreads=${threads};currentThreads=${currentThreads};warmCjTasks=${cjTasks};currentCjTasks=${currentCjTasks};warmCjBlocking=${cjBlocking};currentCjBlocking=${currentCjBlocking}")
            thinCheck(currentCjTasks <= cjTasks && currentCjBlocking <= cjBlocking)
        }
        calls += 1
    }
    func finish(): Unit {
        var saved = false
        var before = false
        var terminal = false
        try {
            before = sourceTerminal()
            let proof = JsonObject()
            proof.put("formalOk", JsonBool(passed && before)); proof.put("recordedBeforeFallback", JsonBool(true))
            proof.put("calls", JsonInt(calls)); proof.put("mode", JsonString(mode))
            let finalFd = try { thinCount(1) } catch (_: Exception) { -1 }
            proof.put("warmFd", JsonInt(fd)); proof.put("finalFd", JsonInt(finalFd))
            let finalThreads = try { thinCount(6) } catch (_: Exception) { -1 }
            proof.put("warmThreads", JsonInt(threads)); proof.put("finalThreads", JsonInt(finalThreads))
            proof.put("warmCjTasks", JsonInt(cjTasks)); proof.put("finalCjTasks", JsonInt(getThreadCount()))
            proof.put("warmCjBlocking", JsonInt(cjBlocking)); proof.put("finalCjBlocking", JsonInt(getBlockingThreadCount()))
            File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray()); saved = true
        } catch (_: Exception) {
            @Expect(false, true)
        } finally {
            let deadline = MonoTime.now() + Duration.second * 3
            try {
                terminal = true
                if (bound) {
                    let stopped = managedRecoveryStopOwnedChildren((home.join("inventory").toString(), parent), deadline)
                    let source = managedRecoveryProbeRecords(home.join("inventory"), parent, binding, deadline)
                    terminal = stopped && source.ok && source.terminal
                }
                terminal = terminal && MonoTime.now() <= deadline
            } catch (_: Exception) { terminal = false }
            if (terminal) {
                try {
                    match (oldDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value) case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
                try {
                    match (oldParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value) case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
            }
            terminal = terminal && MonoTime.now() <= deadline
            @Expect(saved && before && terminal, true)
            try {
                let result = JsonObject(); result.put("formalOk", JsonBool(passed && before && saved))
                result.put("terminal", JsonBool(terminal)); result.put("recordedBeforeFallback", JsonBool(saved))
                File.writeTo(home.join("result.json"), result.toJsonString().toArray())
            } catch (_: Exception) { @Expect(false, true) }
        }
    }
}

@When[os == "macOS"]
private func thinParent(testName: String, kind: String, scenarios: Array<String>, sdk!: Bool = false): Unit {
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let root = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let binary = home.join("actor")
    let handles = ArrayList<ManagedOwnedChild>()
    var compilerJoined = true
    var passed = false
    var formalSaved = false
    var parentFailure = None<Exception>
    var pendingLaunch = false
    try {
        File.writeTo(home.join("owner"), nonce.toArray())
        println("R-WRAP fixture=${home.fileName};nonce=${nonce};kind=${kind}")
        let stdx = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow())).join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
        let sdkRoot = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
        pendingLaunch = true
        let compiler = launchManagedRawChild(sdkRoot.join("bin/cjc").toString(),
            [root.join("test/fixtures/service_plugin/stdio_protocol/thin_process_output_fixture.cj").toString(),
                "--import-path", stdx.toString(), "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options",
                "-rpath ${stdx.toString()}", "-o", binary.toString()], workingDirectory: Some(root),
            environment: Some<Map<String, String>>(thinEnvironment()), stdIn: ProcessRedirect.Discard,
            stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe, newGeneration: true)
        handles.add(compiler); pendingLaunch = false
        let stdout = spawn { thinRead(compiler.stdOutPipe) }; let stderr = spawn { thinRead(compiler.stdErrPipe) }
        var original = None<Exception>
        var compilerCode: Int64 = -1
        try {
            compilerCode = compiler.wait(timeout: Some(Duration.second * 60))
            let outputBytes = stdout.get(Duration.second * 3); let errorBytes = stderr.get(Duration.second * 3)
            File.writeTo(home.join("compiler.stdout.bin"), outputBytes); File.writeTo(home.join("compiler.stderr.bin"), errorBytes)
            let encoding = try { let _ = String.fromUtf8(outputBytes); let _ = String.fromUtf8(errorBytes); "valid_utf8" }
                catch (_: Exception) { "invalid_response_encoding" }
            File.writeTo(home.join("compiler-encoding-status"), encoding.toArray())
            thinCheck(compilerCode == 0 && exists(binary))
        } catch (failure: Exception) { original = Some(failure) }
        finally {
            try {
                let compilerProof = JsonObject()
                compilerProof.put("recordedBeforeFallback", JsonBool(true)); compilerProof.put("code", JsonInt(compilerCode))
                compilerProof.put("formalOk", JsonBool(original.isNone() && compilerCode == 0))
                File.writeTo(home.join("compiler-formal-before-fallback.json"), compilerProof.toJsonString().toArray())
            } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let deadline = MonoTime.now() + Duration.second * 3
                try { if (compiler.isAlive()) { compiler.terminate() } }
                catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
                try {
                    let remaining = deadline - MonoTime.now()
                    if (remaining <= Duration.Zero) { throw Exception("thin_compiler_cleanup_pending") }
                    let _ = compiler.wait(timeout: Some(remaining))
                }
                catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
                finally {
                    try { compiler.closeStreams() }
                    catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
                    finally {
                        let outputJoined = thinJoin(stdout, deadline); let errorJoined = thinJoin(stderr, deadline)
                        compilerJoined = outputJoined && errorJoined && MonoTime.now() <= deadline
                    }
                }
            }
        }
        if (let Some(failure) <- original) { throw failure }
        thinCheck(compilerJoined && !compiler.isAlive() && compiler.streamsAreClosed())
        File.writeTo(home.join("actor.binding"), (nonce + "\n" + binary.toString()).toArray())
        let modes = if (sdk) { ["sdk", "absent", "bound"] } else { ["absent", "bound"] }
        for (mode in modes) {
            for (scenario in scenarios) {
                let directory = home.join(mode + "-" + scenario); Directory.create(directory)
                for (name in ["bin", "cases"]) { Directory.create(directory.join(name)) }
                File.writeTo(directory.join("owner"), nonce.toArray())
                File.writeTo(directory.join("cjpm.toml"), "[package]\nname=\"fixture\"\nversion=\"0.0.0\"\n".toArray())
                File.writeTo(directory.join("metis.json"), "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"openai:fixture\"}}}}".toArray())
                let environment = thinEnvironment()
                environment["METIS_THIN_TEST_HOME"] = directory.toString(); environment["METIS_THIN_TEST_NONCE"] = nonce
                environment["METIS_THIN_TEST_ACTOR"] = binary.toString(); environment["METIS_THIN_TEST_MODE"] = mode
                environment["METIS_THIN_TEST_KIND"] = kind; environment["METIS_THIN_TEST_SCENARIO"] = scenario
                environment["METIS_CJPM_ROOT"] = directory.toString()
                environment["METIS_HOME"] = directory.toString(); environment["METIS_LOG_FILE"] = directory.join("test.log").toString()
                environment["XDG_CONFIG_HOME"] = directory.join("xdg").toString(); environment["CURL_HOME"] = directory.toString()
                environment["PATH"] = directory.join("bin").toString() + ":/usr/bin:/bin"
                environment["METIS_STDIO_BROKER_SCRIPT"] = root.join("scripts/metis-stdio-broker.mjs").toString()
                let realNode = getVariable("METIS_STDIO_BROKER_NODE_COMMAND").getOrDefault({ => managedStdioResolveNodeCommand() })
                thinCheck(Path(realNode).isAbsolute() && exists(Path(realNode)))
                environment["METIS_STDIO_BROKER_NODE_COMMAND"] = realNode
                try (input = File(directory.join("stdin"), OpenMode.ReadWrite), output = File(directory.join("stdout"), OpenMode.Write),
                    error = File(directory.join("stderr"), OpenMode.Write)) {
                    pendingLaunch = true
                    let child = launchManagedRawChild(getCommand(), ["--filter=${testName}", "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"],
                        workingDirectory: Some(directory), environment: Some<Map<String, String>>(environment), stdIn: ProcessRedirect.FromFile(input),
                        stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error), newGeneration: true)
                    handles.add(child); pendingLaunch = false
                    thinCheck(child.wait(timeout: Some(Duration.second * 60)) == 0)
                    child.closeStreams(); thinCheck(child.wait() == 0 && child.streamsAreClosed() && !child.isAlive())
                }
                let result = JsonValue.fromStr(thinText(directory.join("result.json"))).asObject()
                thinCheck(result.get("formalOk").getOrThrow().asBool().getValue() && result.get("terminal").getOrThrow().asBool().getValue() &&
                    result.get("recordedBeforeFallback").getOrThrow().asBool().getValue())
            }
        }
        passed = true
    } catch (failure: Exception) { parentFailure = Some(failure) }
    finally {
        try {
            let proof = JsonObject(); proof.put("formalOk", JsonBool(passed)); proof.put("recordedBeforeFallback", JsonBool(true))
            File.writeTo(home.join("parent-formal.json"), proof.toJsonString().toArray()); formalSaved = true
        } catch (failure: Exception) { if (parentFailure.isNone()) { parentFailure = Some(failure) } }
        finally {
            let deadline = MonoTime.now() + Duration.second * 3
            var terminal = compilerJoined && !pendingLaunch
            for (handle in handles) {
                try { if (handle.isAlive()) { handle.terminate() } }
                catch (failure: Exception) { terminal = false; if (parentFailure.isNone()) { parentFailure = Some(failure) } }
                try {
                    let remaining = deadline - MonoTime.now()
                    if (remaining <= Duration.Zero) { throw Exception("thin_parent_cleanup_pending") }
                    let _ = handle.wait(timeout: Some(remaining))
                }
                catch (failure: Exception) { terminal = false; if (parentFailure.isNone()) { parentFailure = Some(failure) } }
                finally {
                    try { handle.closeStreams() }
                    catch (failure: Exception) { terminal = false; if (parentFailure.isNone()) { parentFailure = Some(failure) } }
                }
                try { terminal = terminal && handle.streamsAreClosed() && !handle.isAlive() }
                catch (failure: Exception) { terminal = false; if (parentFailure.isNone()) { parentFailure = Some(failure) } }
            }
            terminal = terminal && MonoTime.now() <= deadline
            if (!terminal && parentFailure.isNone()) { parentFailure = Some(Exception("thin_parent_cleanup_pending")) }
            if (passed && formalSaved && terminal && parentFailure.isNone()) { remove(home, recursive: true) }
            else { try { println("R-WRAP owned_evidence_retained terminal=${terminal}") } catch (_: Exception) { () } }
        }
    }
    if (let Some(failure) <- parentFailure) { throw failure }
}

@When[os == "macOS"]
private func cjOutcome(fixture: ThinChild, command: String, arguments: Array<String>, cwd: Path): String {
    try {
        let result = if (fixture.mode == "sdk") { executeWithOutput(command, arguments, workingDirectory: Some(cwd)) }
            else { managedRecoveryExecuteWithOutput(command, arguments, workingDirectory: Some(cwd)) }
        "exit:${result[0]}"
    } catch (_: ProcessException) { "process_exception" }
    catch (_: IllegalArgumentException) { "illegal_argument" }
    catch (_: Exception) { "other_exception" }
}
@When[os == "macOS"]
private func cjTypeChild(): Unit {
    let fixture = ThinChild()
    let observed = JsonArray()
    var compatible = true
    try {
        fixture.warm()
        let denied = fixture.home.join("denied")
        copy(Path(getVariable("METIS_THIN_TEST_ACTOR").getOrThrow()), to: denied); chmod(denied.toString(), 0o000)
        for (kind in ["missing", "eacces", "cwd", "nul", "seven", "business127"]) {
            let rounds: Int64 = if (kind == "missing" || kind == "cwd") { 32 } else { 1 }
            for (round in 0..rounds) {
                fixture.begin("type-${kind}-${round}")
                fixture.route("cjc", [], if (kind == "business127") { 127 } else { 7 })
                let command = if (kind == "missing") { fixture.home.join("missing-command").toString() }
                    else if (kind == "eacces") { denied.toString() } else { fixture.home.join("bin/cjc").toString() }
                let arguments = if (kind == "nul") { ["\u{0}"] } else { ["--synthetic", "中文😀"] }
                let cwd = if (kind == "cwd") { fixture.home.join("missing-directory") } else { fixture.home }
                let expected = match (kind) {
                    case "missing" | "eacces" => "process_exception"
                    case "cwd" | "nul" => "illegal_argument"
                    case "business127" => "exit:127"
                    case _ => "exit:7"
                }
                let actual = cjOutcome(fixture, command, arguments, cwd)
                let row = JsonObject(); row.put("kind", JsonString(kind)); row.put("round", JsonInt(round))
                row.put("actual", JsonString(actual)); row.put("expected", JsonString(expected)); observed.add(row)
                compatible = compatible && actual == expected
                fixture.checkpoint()
            }
        }
        thinCheck(fixture.calls == 68)
        thinCheck(compatible)
        fixture.passed = true
    } finally {
        File.writeTo(fixture.home.join("typed-outcomes.json"), observed.toJsonString().toArray())
        fixture.finish()
    }
}

@When[os == "macOS"]
private func cjOutputChild(): Unit {
    let fixture = ThinChild()
    try {
        fixture.warm()
        let text = "中文😀" + String(Array<Rune>(32768, repeat: r'中')) + "\n"
        let ansi = "\u{1b}[31m" + text + "\u{1b}[0m"
        let args = ["--fixture-only", "参数中文😀", "space value"]
        for (command in ["cjc", "cjpm"]) {
            for (round in 0..32) {
                fixture.begin("${command}-${round}")
                let success = round % 2 == 0
                fixture.route(command, if (success) { ansi.toArray() } else { [] }, if (success) { 0 } else { 7 },
                    error: if (success) { [] } else { "\u{1b}[31m构建失败😀\u{1b}[0m\n".toArray() })
                let result = if (command == "cjc") { cjcRun(args, fixture.home) } else { cjpmRun(args, fixture.home) }
                thinCheck(result == if (success) { text } else { "构建失败😀\n" })
                let receipt = fixture.one(command)
                thinCheck(fixture.args(receipt) == args)
                thinCheck(receipt.get("cwd").getOrThrow().asString().getValue() == fixture.home.toString())
                thinCheck(fixture.receipts().size == 1)
                fixture.checkpoint()
            }
            for (kind in ["empty", "malformed", "invalid_stdout", "invalid_stderr", "missing", "eacces", "cwd"]) {
                fixture.begin("${command}-${kind}")
                let binary = fixture.home.join("bin/" + command)
                if (kind == "missing") { remove(binary) }
                if (kind == "eacces") { chmod(binary.toString(), 0o000) }
                fixture.route(command, if (kind == "invalid_stdout") { [0xffu8, 0xfeu8, 0x80u8, 0u8] } else if (kind == "malformed") { "{invalid-中文😀\n".toArray() } else { [] },
                    if (kind == "invalid_stderr") { 7 } else { 0 },
                    error: if (kind == "invalid_stderr") { [0xffu8, 0xfeu8, 0x80u8, 0u8] } else { [] })
                let cwd = if (kind == "cwd") { fixture.home.join("missing-directory") } else { fixture.home }
                let result = if (command == "cjc") { cjcRun([], cwd) } else { cjpmRun([], cwd) }
                if (kind == "missing") { copy(Path(getVariable("METIS_THIN_TEST_ACTOR").getOrThrow()), to: binary); chmod(binary.toString(), 0o700) }
                if (kind == "eacces") { chmod(binary.toString(), 0o700) }
                if (kind == "empty") { thinCheck(result == "Execute '${command} ' successfully.") }
                else if (kind == "malformed") { thinCheck(result == "{invalid-中文😀\n") }
                else if (kind == "missing" || kind == "eacces") { thinCheck(result.startsWith("Process execution error:") && !result.startsWith("Unknown error occurred:")) }
                else { thinCheck(result.startsWith("Unknown error occurred:")) }
                if (kind == "invalid_stdout" || kind == "invalid_stderr") {
                    thinCheck(!result.contains(fixture.home.toString()))
                }
                if (kind == "empty" || kind == "malformed" || kind == "invalid_stdout" || kind == "invalid_stderr") {
                    let receipt = fixture.one(command); thinCheck(fixture.args(receipt).isEmpty())
                    thinCheck(receipt.get("cwd").getOrThrow().asString().getValue() == fixture.home.toString())
                } else { thinCheck(fixture.receipts().isEmpty()) }
                fixture.checkpoint()
            }
        }
        thinCheck(fixture.calls == 78)
        fixture.passed = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
@Test
public class CjcCjpmRunResourceTest {
    @TestCase
    public func wrapperTypeCompatibilityMatrix(): Unit {
        if (getVariable("METIS_THIN_TEST_KIND") == Some("type")) { cjTypeChild(); return }
        thinParent("CjcCjpmRunResourceTest.wrapperTypeCompatibilityMatrix", "type", ["matrix"], sdk: true)
    }
    @TestCase
    public func wrapperCjcCjpmOutputContracts(): Unit {
        if (getVariable("METIS_THIN_TEST_KIND") == Some("cj")) { cjOutputChild(); return }
        thinParent("CjcCjpmRunResourceTest.wrapperCjcCjpmOutputContracts", "cj", ["outputs"])
    }
}
