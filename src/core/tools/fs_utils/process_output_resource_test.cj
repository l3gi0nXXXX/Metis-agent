package metis.core.tools.fs_utils

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
        @When[arch == "aarch64"]
        let runtime = sdkRoot.join("runtime/lib/darwin_aarch64_llvm")
        @When[arch == "x86_64"]
        let runtime = sdkRoot.join("runtime/lib/darwin_x86_64_llvm")
        pendingLaunch = true
        let compiler = launchManagedRawChild(sdkRoot.join("bin/cjc").toString(),
            [root.join("test/fixtures/service_plugin/stdio_protocol/thin_process_output_fixture.cj").toString(),
                "--import-path", stdx.toString(), "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options",
                "-rpath ${stdx.toString()} -rpath ${runtime.toString()}", "-o", binary.toString()], workingDirectory: Some(root),
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

private func fsDirectories(home: Path): Array<String> {
    let names = ArrayList<String>()
    for (entry in Directory.readFrom(home)) { if (entry.isDirectory()) { names.add(entry.name) } }
    let result = names.toArray(); sort(result); result
}
@When[os == "macOS"]
private func fsBlacklistChild(): Unit {
    let fixture = ThinChild()
    try {
        thinCheck(workspaceIsGitRepo.isNone())
        Directory.create(fixture.home.join(".git"))
        fixture.warm()
        for (kind in ["ignored", "not_ignored", "throw"]) {
            for (round in 0..32) {
                fixture.begin("blacklist-${kind}-${round}")
                let path = fixture.home.join("candidate-${kind}-${round}-中文😀.cj")
                File.writeTo(path, "中文😀".toArray())
                let ignoredBytes = if (round % 4 == 0) { [0xffu8, 0xfeu8, 0x80u8, 0u8] }
                    else if (round % 4 == 1) { ("中文😀" + String(Array<Rune>(32768, repeat: r'中'))).toArray() }
                    else if (round % 4 == 2) { "{invalid-中文😀".toArray() } else { "中文😀".toArray() }
                fixture.route("git", ignoredBytes, if (kind == "ignored") { 0 } else { 1 })
                let command = fixture.home.join("bin/git")
                if (kind == "throw") { remove(command) }
                var first = false; var cached = false
                if (kind == "throw") {
                    let priorPath = getVariable("PATH")
                    try {
                        setVariable("PATH", fixture.home.join("bin").toString())
                        first = ignored(path); cached = ignored(path)
                    } finally {
                        match (priorPath) { case Some(value) => setVariable("PATH", value) case None => removeVariable("PATH") }
                    }
                } else { first = ignored(path); cached = ignored(path) }
                if (kind == "throw") {
                    copy(Path(getVariable("METIS_THIN_TEST_ACTOR").getOrThrow()), to: command); chmod(command.toString(), 0o700)
                    thinCheck(!ignored(path))
                }
                thinCheck(first == (kind == "ignored") && cached == first)
                for (name in IGNORED_DIR) { thinCheck(ignored(fixture.home.join(name))) }
                thinCheck(!ignored(fixture.home.join(".gitignore")))
                if (kind == "throw") { thinCheck(fixture.receipts().isEmpty()) }
                else {
                    thinCheck(fixture.receipts().size == 1)
                    let receipt = fixture.one("git")
                    thinCheck(fixture.args(receipt) == ["-C", fixture.home.toString(), "check-ignore", "--no-index", "-q", path.fileName])
                    thinCheck(receipt.get("cwd").getOrThrow().asString().getValue() == fixture.home.toString())
                }
                fixture.checkpoint()
            }
        }
        thinCheck(fixture.calls == 96); fixture.passed = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
private func fsDiffPayload(fixture: ThinChild, command: String, old: String, fresh: String): JsonObject {
    let receipt = fixture.one(command)
    let args = fixture.args(receipt)
    let offset: Int64 = if (command == "git") { 3 } else { 1 }
    thinCheck(args.size == offset + 2)
    if (command == "git") { thinCheck(args[0] == "diff" && args[1] == "--no-index" && args[2] == "--color=never") }
    else { thinCheck(args[0] == "-u") }
    thinCheck(Path(args[offset]).fileName == "old_content" && Path(args[offset + 1]).fileName == "new_content")
    thinCheck(Path(args[offset]).parent == Path(args[offset + 1]).parent)
    thinCheck(!exists(Path(args[offset]).parent))
    thinCheck(receipt.get("payloadRecorded").getOrThrow().asBool().getValue())
    let pid = receipt.get("pid").getOrThrow().asInt().getValue()
    thinCheck(File.readFrom(fixture.current.join("payload-${pid}-0.bin")) == old.toArray())
    thinCheck(File.readFrom(fixture.current.join("payload-${pid}-1.bin")) == fresh.toArray())
    receipt
}
@When[os == "macOS"]
private func fsDiffChild(): Unit {
    let fixture = ThinChild()
    try {
        fixture.warm()
        let scenario = getVariable("METIS_THIN_TEST_SCENARIO").getOrThrow()
        let old = "旧中文😀\n"; let fresh = "新中文😀\n"
        for (round in 0..32) {
            fixture.begin("diff-${scenario}-${round}")
            let directories = fsDirectories(fixture.home)
            let payload = "diff --git a/owned b/owned\nindex 111..222\n--- a/owned\n+++ b/owned\n@@ -1 +1 @@\n-旧中文😀\n+新中文😀\n"
            let filtered = "@@ -1 +1 @@\n-旧中文😀\n+新中文😀\n"
            let fallback = "Old content:\n" + old + "\nNew content:\n" + fresh
            var expected = filtered
            if (scenario == "same") { fixture.route("git", [], 0); expected = "" }
            else if (scenario == "changed") { fixture.route("git", payload.toArray(), 1) }
            else if (scenario == "fallback") { fixture.route("git", [], 2); fixture.route("diff", payload.toArray(), 1) }
            else if (scenario == "both_failed") { fixture.route("git", [], 2); fixture.route("diff", [], 2); expected = fallback }
            else if (scenario == "invalid") { fixture.route("git", [0xffu8, 0xfeu8, 0x80u8, 0u8], 1); expected = fallback }
            else if (scenario == "malformed") { fixture.route("git", "{invalid-中文😀\n".toArray(), 1); expected = "{invalid-中文😀\n" }
            else if (scenario == "long") {
                expected = "@@ -1 +1 @@\n+" + String(Array<Rune>(32768, repeat: r'中')) + "😀\n"
                fixture.route("git", ("--- a/owned\n+++ b/owned\n" + expected).toArray(), 1)
            } else { throw Exception("thin_diff_scenario_invalid") }
            thinCheck(diff(old, fresh) == expected)
            thinCheck(fsDirectories(fixture.home) == directories)
            let git = fsDiffPayload(fixture, "git", old, fresh)
            if (scenario == "fallback" || scenario == "both_failed") {
                thinCheck(fixture.receipts().size == 2)
                let system = fsDiffPayload(fixture, "diff", old, fresh)
                thinCheck(git.get("recordedAtNs").getOrThrow().asInt().getValue() <= system.get("recordedAtNs").getOrThrow().asInt().getValue())
            } else { thinCheck(fixture.receipts().size == 1) }
            fixture.checkpoint()
        }
        thinCheck(fixture.calls == 32); fixture.passed = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
private func fsGrepChild(): Unit {
    let fixture = ThinChild()
    try {
        File.writeTo(fixture.home.join("matches.cj"), "匹配中文😀\n".toArray())
        Directory.create(fixture.home.join("node_modules"))
        fixture.warm()
        let scenario = getVariable("METIS_THIN_TEST_SCENARIO").getOrThrow()
        for (round in 0..32) {
            fixture.begin("grep-${scenario}-${round}")
            let traditional = scenario.startsWith("traditional")
            let whichInvalid = scenario == "traditional_invalid_which"
            let versionFailed = scenario == "traditional_version_failed"
            fixture.route("which", if (whichInvalid) { [0xffu8, 0xfeu8, 0x80u8, 0u8] } else {
                (fixture.home.join("bin/rg").toString() + "\n").toArray()
            }, if (scenario == "traditional") { 1 } else { 0 })
            fixture.route("rg", "ripgrep fixture\n".toArray(), if (versionFailed) { 7 } else { 0 }, phase: "version")
            let command = if (traditional) { "grep" } else { "rg" }
            var raw = "./matches.cj:1:匹配中文😀"
            var expected = fixture.home.join("matches.cj").toString() + ":1:匹配中文😀"
            var code: Int64 = 0
            var error = ""
            if (scenario == "rg_limit") {
                let rows = ArrayList<String>(); let results = ArrayList<String>()
                rows.add("./node_modules:1:应被过滤😀")
                for (index in 1..105) {
                    rows.add("./matches.cj:${index}:匹配中文😀")
                    if (index < 100) { results.add(fixture.home.join("matches.cj").toString() + ":${index}:匹配中文😀") }
                }
                raw = String.join(rows.toArray(), delimiter: "\n")
                expected = String.join(results.toArray(), delimiter: "\n") + "\n\n[Truncated: showing 100 of 105 matches. 5 more results not shown. Use more specific pattern or include filter.]"
            } else if (scenario == "rg_long") {
                let value = String(Array<Rune>(32768, repeat: r'中')) + "😀"
                raw = "./matches.cj:1:" + value; expected = fixture.home.join("matches.cj").toString() + ":1:" + value
            } else if (scenario == "rg_malformed") {
                raw = "{invalid-中文😀"; expected = raw
            } else if (scenario == "rg_invalid") {
                expected = "invalid_response_encoding"
            } else if (scenario == "rg_error") {
                code = 7; error = "搜索失败😀\n"; expected = error
            }
            fixture.route(command, if (scenario == "rg_invalid") { [0xffu8, 0xfeu8, 0x80u8, 0u8] } else { raw.toArray() }, code, error: error.toArray())
            let actualOutput = grep("匹配", Some(fixture.home.toString()), Some("*.cj"))
            if (actualOutput != expected) { File.writeTo(fixture.current.join("grep.actual.utf8"), actualOutput.toArray()) }
            thinCheck(actualOutput == expected)
            let which = fixture.one("which"); thinCheck(fixture.args(which) == ["rg"])
            let actual = fixture.one(command)
            let args = fixture.args(actual)
            thinCheck(actual.get("cwd").getOrThrow().asString().getValue() == fixture.home.toString())
            thinCheck(args.contains("匹配"))
            if (traditional) {
                thinCheck(args.contains("-r") && args.contains("-n") && args.contains("-H") && args.contains("-E"))
                thinCheck(args.contains("--include=*.cj") && args[args.size - 1] == ".")
                for (name in IGNORED_DIR) { thinCheck(args.contains("--exclude-dir=" + name)) }
            } else {
                thinCheck(args[0] == "--line-number" && args[1] == "--with-filename" && args[2] == "--no-heading")
                thinCheck(args.contains("--glob=*.cj") && args[args.size - 1] == fixture.home.toString())
                for (name in IGNORED_DIR) { thinCheck(args.contains("--glob=!**/" + name + "/**")) }
            }
            let versionExpected = !traditional || versionFailed
            if (versionExpected) { thinCheck(fixture.args(fixture.one("rg", phase: "version")) == ["--version"]) }
            thinCheck(fixture.receipts().size == if (versionExpected) { 3 } else { 2 })
            thinCheck(which.get("recordedAtNs").getOrThrow().asInt().getValue() <= actual.get("recordedAtNs").getOrThrow().asInt().getValue())
            fixture.checkpoint()
        }
        thinCheck(fixture.calls == 32); fixture.passed = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
@Test
public class ProcessOutputResourceTest {
    @TestCase
    public func wrapperBlacklistCacheAndExitContracts(): Unit {
        if (getVariable("METIS_THIN_TEST_KIND") == Some("blacklist")) { fsBlacklistChild(); return }
        thinParent("ProcessOutputResourceTest.wrapperBlacklistCacheAndExitContracts", "blacklist", ["cache"])
    }
    @TestCase
    public func wrapperDiffOutputAndCleanupContracts(): Unit {
        if (getVariable("METIS_THIN_TEST_KIND") == Some("diff")) { fsDiffChild(); return }
        thinParent("ProcessOutputResourceTest.wrapperDiffOutputAndCleanupContracts", "diff", ["same", "changed", "fallback", "both_failed", "invalid", "malformed", "long"])
    }
    @TestCase
    public func wrapperGrepSelectionLimitAndOutputContracts(): Unit {
        if (getVariable("METIS_THIN_TEST_KIND") == Some("grep")) { fsGrepChild(); return }
        thinParent("ProcessOutputResourceTest.wrapperGrepSelectionLimitAndOutputContracts", "grep",
            ["rg", "traditional", "traditional_invalid_which", "traditional_version_failed", "rg_limit", "rg_long", "rg_malformed", "rg_invalid", "rg_error"])
    }
}
