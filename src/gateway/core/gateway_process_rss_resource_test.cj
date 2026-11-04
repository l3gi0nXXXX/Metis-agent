package metis.gateway.core

import metis.core.config.cliModelProviderCatalogDescriptors
import metis.process.*
import std.collection.{ArrayList, HashMap, HashSet, Map}
import std.env.{getCommand, getProcessId, getVariable, getVariables, removeVariable, setVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, copy, exists, remove, rename}
import std.io.InputStream
import std.posix.chmod
import std.process.ProcessRedirect
import std.runtime.{getMaxHeapSize, getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import stdx.encoding.json.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
    func getpgid(pid: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}

private func rssResourceRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("rss_interface_contract_failed") }
}

private func rssResourceText(bytes: Array<Byte>): String {
    try { String.fromUtf8(bytes) }
    catch (_: Exception) { throw Exception("rss_fixture_invalid_encoding") }
}

private func rssResourceSha(bytes: Array<Byte>): String {
    let digest = SHA256(); digest.write(bytes)
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    let result = StringBuilder()
    for (byte in digest.finish()) {
        result.append(digits[Int64(byte >> 4)]); result.append(digits[Int64(byte & 0x0f)])
    }
    result.toString()
}

private func rssResourceFileSha(path: Path): String {
    let digest = SHA256(); let buffer = Array<Byte>(8192, repeat: 0)
    try (input = File(path, OpenMode.Read)) {
        while (true) {
            let count = input.read(buffer)
            if (count == 0) { break }
            digest.write(buffer[..count])
        }
    }
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    let result = StringBuilder()
    for (byte in digest.finish()) {
        result.append(digits[Int64(byte >> 4)]); result.append(digits[Int64(byte & 0x0f)])
    }
    result.toString()
}

private func rssResourceEnvironment(): HashMap<String, String> {
    let aliases = HashSet<String>()
    for (descriptor in cliModelProviderCatalogDescriptors()) {
        aliases.add(descriptor.apiKeyEnv.toAsciiUpper())
        for (name in descriptor.apiKeyEnvAliases) { aliases.add(name.toAsciiUpper()) }
    }
    let result = HashMap<String, String>(getVariables())
    for (name in result.keys().toArray()) {
        let upper = name.toAsciiUpper()
        if (name.startsWith("METIS_PROCESS_RECOVERY_") || name.startsWith("METIS_RSS_RESOURCE_") ||
            name.startsWith("METIS_THIN_ACTOR_") || upper.contains("PROXY") || upper.endsWith("_TOKEN") ||
            upper.endsWith("_API_KEY") || upper.contains("SECRET") || upper.contains("PASSWORD") ||
            upper.contains("CREDENTIAL") || upper.endsWith("_ACCESS_KEY_ID") || aliases.contains(upper)) {
            result.remove(name)
        }
    }
    result
}

@When[os == "macOS"]
private func rssResourceCount(flavor: Int32): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("rss_resource_observation_failed") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

@When[os == "macOS"]
private func rssResourceGroupGone(pid: Int64): Bool {
    if (pid <= 1 || pid > 2147483647) { return false }
    unsafe { kill(-Int32(pid), 0) } != 0 && unsafe { __error().read() } == 3
}

@When[os == "macOS"]
private func rssResourceInventoryTerminal(home: Path, mode: String, nonce: String, writer: ProcessBirthIdentity, deadline: MonoTime): Bool {
    let directory = home.join("inventory")
    if (mode == "absent") { return !exists(directory) }
    try {
        if (!exists(directory) || FileInfo(directory).isSymbolicLink()) { return false }
        let header = directory.join("inventory")
        if (!exists(header) || FileInfo(header).isSymbolicLink()) { return false }
        let fields = managedRecoveryParseFields(rssResourceText(File.readFrom(header))).getOrThrow()
        let parent = fields.get("parent").getOrThrow()
        let identity = parseProcessInstanceIdentity(parent).getOrThrow()
        // Public Darwin ProcessInstanceIdentity stores the observed start pair in value8/value9.
        if (identity.pid != writer.pid || identity.value8 != writer.seconds || identity.value9 != writer.microseconds ||
            fields.get("binding") != Some(nonce)) { return false }
        let proof = managedRecoveryProbeRecords(directory, parent, nonce, deadline)
        proof.ok && proof.terminal
    } catch (_: Exception) { false }
}

private func rssResourceDrain(input: InputStream): Array<Byte> {
    let result = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = input.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { if (result.size < 65536) { result.add(buffer[index]) } }
    }
    result.toArray()
}

private func rssResourceWait(milliseconds: Int64, predicate: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.millisecond * milliseconds
    while (MonoTime.now() < deadline) {
        if (predicate()) { return true }
        sleep(Duration.millisecond * 5)
    }
    predicate()
}

private func rssResourceExpected(mode: String): (Array<Byte>, Array<Byte>, Int64) {
    match (mode) {
        case "mtime" => ("1234567890\n".toArray(), [], 0)
        case "empty_stdout" => ([], [], 0)
        case "malformed" => ("{invalid-中文😀\n".toArray(), [], 0)
        case "unicode_stdout" =>
            (("\u{1b}[31m中文😀" + String(Array<Rune>(32768, repeat: r'中')) + "\u{1b}[0m\n").toArray(), [], 0)
        case "invalid_stdout" => ([255u8, 254u8, 128u8, 0u8, 10u8], [], 0)
        case "invalid_stderr" => ([], [255u8, 254u8, 128u8, 0u8, 10u8], 7)
        case "exit_127" => ([], "业务退出😀\n".toArray(), 127)
        case "unicode_stderr" => ([], "\u{1b}[31m构建失败😀\u{1b}[0m\n".toArray(), 7)
        case _ => throw Exception("rss_fixture_case_invalid")
    }
}

@When[os == "macOS"]
private class RssResourceChild {
    let home: Path
    let nonce: String
    let mode: String
    let bound: Bool
    let writer: ProcessBirthIdentity
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let counts = HashMap<String, Int64>()
    var warmFd: Int64 = 0
    var warmTasks: Int64 = 0
    var warmBlocking: Int64 = 0
    var receipts: Int64 = 0
    var warmCalls: Int64 = 0
    var formalCalls: Int64 = 0
    var missingCalls: Int64 = 0
    var passed = false

    init() {
        home = canonicalize(Path(getVariable("METIS_RSS_RESOURCE_HOME").getOrThrow()))
        nonce = getVariable("METIS_RSS_RESOURCE_NONCE").getOrThrow()
        mode = getVariable("METIS_RSS_RESOURCE_MODE").getOrThrow()
        bound = mode == "bound"
        rssResourceRequire(home.toString().startsWith("/private/tmp/") && !nonce.isEmpty())
        rssResourceRequire(rssResourceText(File.readFrom(home.join("owner"))) == "rss-resource-v1\n" + nonce)
        rssResourceRequire(oldDirectory.isNone() && oldParent.isNone())
        rssResourceRequire(getMaxHeapSize() == 67108864)
        let release = home.join("expected-writer")
        rssResourceRequire(rssResourceWait(5000, { => exists(release) }))
        let expected = JsonValue.fromStr(rssResourceText(File.readFrom(release))).asObject()
        rssResourceRequire(expected.getFields().size == 4 && expected.get("nonce").getOrThrow().asString().getValue() == nonce &&
            expected.get("mode").getOrThrow().asString().getValue() == mode &&
            expected.get("pid").getOrThrow().asInt().getValue() == getProcessId())
        writer = parseProcessBirthIdentity(expected.get("birth").getOrThrow().asString().getValue()).getOrThrow()
        rssResourceRequire(writer.pid == getProcessId() && writerMatches())
        let actor = canonicalize(Path(getVariable("METIS_RSS_RESOURCE_ACTOR").getOrThrow()))
        rssResourceRequire(actor == canonicalize(home.parent.join("actor")))
        rssResourceRequire(rssResourceText(File.readFrom(home.parent.join("actor.binding"))) == nonce + "\n" + rssResourceFileSha(actor))
        copy(actor, to: home.join("bin/ps"))
        rssResourceRequire(unsafe { chmod(home.join("bin/ps").toString(), 0o700) } == 0)
        if (bound) { rssResourceRequire(managedRecoveryInitialize(home.join("inventory"), parent, nonce)) }
    }

    func writerMatches(): Bool {
        observeProcessBirthIdentity(getProcessId())?.serialize() == Some(writer.serialize()) &&
            unsafe { getpgid(Int32(getProcessId())) } == Int32(getProcessId())
    }

    func sourceTerminal(until!: MonoTime = MonoTime.now() + Duration.second * 2): Bool {
        if (!bound) { return !exists(home.join("inventory")) }
        let result = managedRecoveryProbeRecords(home.join("inventory"), parent, nonce, until)
        result.ok && result.terminal
    }

    func checkpoint(): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        var settled = false
        while (MonoTime.now() < deadline) {
            if (sourceTerminal(until: deadline) && rssResourceCount(1) == warmFd &&
                getThreadCount() <= warmTasks && getBlockingThreadCount() <= warmBlocking) { settled = true; break }
            if (MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        }
        let proof = JsonObject(); proof.put("settled", JsonBool(settled)); proof.put("fd", JsonInt(rssResourceCount(1)))
        proof.put("warmFd", JsonInt(warmFd)); proof.put("tasks", JsonInt(getThreadCount()))
        proof.put("warmTasks", JsonInt(warmTasks)); proof.put("blocking", JsonInt(getBlockingThreadCount()))
        proof.put("warmBlocking", JsonInt(warmBlocking)); proof.put("osThreads", JsonInt(rssResourceCount(6)))
        proof.put("formalCalls", JsonInt(formalCalls)); proof.put("receipts", JsonInt(receipts))
        File.writeTo(home.join("resource-checkpoint.json"), proof.toJsonString().toArray())
        rssResourceRequire(settled && writerMatches())
    }

    func call(caseName: String, directoryName: String, missing!: Bool = false): Unit {
        let directory = home.join("cases/" + directoryName); Directory.create(directory)
        File.writeTo(directory.join("binding"), nonce.toArray())
        File.writeTo(directory.join("actor-mode"), caseName.toArray())
        if (!missing) {
            let (output, error, code) = rssResourceExpected(caseName)
            // These are expected fixture emissions, not captured RSS raw output.
            File.writeTo(directory.join("expected.stdout.bin"), output)
            File.writeTo(directory.join("expected.stderr.bin"), error)
            File.writeTo(directory.join("expected.exit"), code.toString().toArray())
        }
        setVariable("METIS_THIN_ACTOR_DIRECTORY", directory.toString())
        setVariable("METIS_THIN_ACTOR_NONCE", nonce)
        setVariable("METIS_THIN_ACTOR_CASE", caseName)
        rssResourceRequire(writerMatches())
        let value = gatewayProcessResidentSetKb()
        rssResourceRequire(writerMatches())
        let expected = if (!missing && caseName == "mtime") { 1234567890 } else { -1 }
        let observed = JsonObject(); observed.put("actualRssKb", JsonInt(value)); observed.put("expectedRssKb", JsonInt(expected))
        observed.put("writerPid", JsonInt(getProcessId())); observed.put("writerBirth", JsonString(writer.serialize()))
        observed.put("case", JsonString(caseName)); observed.put("missing", JsonBool(missing))
        File.writeTo(directory.join("observed.json"), observed.toJsonString().toArray())
        rssResourceRequire(value == expected)
        var found: Int64 = 0
        for (entry in Directory.readFrom(directory)) {
            if (!entry.name.startsWith("receipt-") || !entry.name.endsWith(".json")) { continue }
            let receipt = JsonValue.fromStr(rssResourceText(File.readFrom(entry.path))).asObject()
            let pid = receipt.get("pid").getOrThrow().asInt().getValue()
            rssResourceRequire(pid > 1 && receipt.get("nonce").getOrThrow().asString().getValue() == nonce)
            let invocation = receipt.get("command").getOrThrow().asString().getValue()
            rssResourceRequire(receipt.get("commandName").getOrThrow().asString().getValue() == "ps" &&
                (invocation == "ps" || invocation == home.join("bin/ps").toString()) &&
                getVariable("PATH") == Some(home.join("bin").toString()))
            let invokedPath = if (Path(invocation).isAbsolute()) { Path(invocation) } else { home.join("bin").join(invocation) }
            rssResourceRequire(canonicalize(invokedPath) == canonicalize(home.join("bin/ps")))
            rssResourceRequire(receipt.get("cwd").getOrThrow().asString().getValue() == home.toString())
            let arguments = ArrayList<String>()
            for (argument in receipt.get("args").getOrThrow().asArray().getItems()) { arguments.add(argument.asString().getValue()) }
            rssResourceRequire(arguments.toArray() == ["-o", "rss=", "-p", getProcessId().toString()])
            rssResourceRequire(entry.name == "receipt-" + pid.toString() + ".json")
            found += 1
        }
        rssResourceRequire(found == if (missing) { 0 } else { 1 })
        receipts += found
    }

    func finish(): Unit {
        var before = false
        var proofSaved = false
        var terminal = false
        try {
            try {
                before = sourceTerminal()
                let proof = JsonObject(); proof.put("formal", JsonBool(passed)); proof.put("recordedBeforeFallback", JsonBool(true))
                proof.put("mode", JsonString(mode)); proof.put("sourceTerminal", JsonBool(before))
                proof.put("warmCalls", JsonInt(warmCalls)); proof.put("formalCalls", JsonInt(formalCalls))
                proof.put("missingCalls", JsonInt(missingCalls)); proof.put("receipts", JsonInt(receipts))
                proof.put("writerPid", JsonInt(getProcessId())); proof.put("writerBirth", JsonString(writer.serialize()))
                proof.put("heapBytes", JsonInt(getMaxHeapSize())); proof.put("fd", JsonInt(rssResourceCount(1)))
                proof.put("warmFd", JsonInt(warmFd)); proof.put("tasks", JsonInt(getThreadCount()))
                proof.put("blocking", JsonInt(getBlockingThreadCount())); proof.put("osThreads", JsonInt(rssResourceCount(6)))
                let perCase = JsonObject(); for ((name, count) in counts) { perCase.put(name, JsonInt(count)) }; proof.put("perCase", perCase)
                File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray())
                proofSaved = true
            } catch (_: Exception) {
                @Expect(false, true)
                try { eprintln("rss_child_formal_proof_failed") } catch (_: Exception) { () }
            }
        } finally {
            let deadline = MonoTime.now() + Duration.second * 3
            try {
                terminal = before
                if (bound) {
                    terminal = managedRecoveryStopOwnedChildren((home.join("inventory").toString(), parent), deadline) && sourceTerminal(until: deadline) &&
                        MonoTime.now() <= deadline
                }
                if (terminal) {
                    try {
                        match (oldDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value) case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
                    } catch (_: Exception) { terminal = false; @Expect(false, true) }
                    try {
                        match (oldParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value) case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
                    } catch (_: Exception) { terminal = false; @Expect(false, true) }
                }
                if (bound) { terminal = terminal && MonoTime.now() <= deadline }
            } catch (_: Exception) {
                terminal = false
                @Expect(false, true)
                try { eprintln("rss_child_cleanup_pending") } catch (_: Exception) { () }
            }
            @Expect(terminal, true)
            try {
                let result = JsonObject(); result.put("formal", JsonBool(passed && before && proofSaved)); result.put("terminal", JsonBool(terminal))
                result.put("recordedBeforeFallback", JsonBool(true)); result.put("formalCalls", JsonInt(formalCalls)); result.put("receipts", JsonInt(receipts))
                result.put("warmCalls", JsonInt(warmCalls)); result.put("missingCalls", JsonInt(missingCalls))
                File.writeTo(home.join("result.json"), result.toJsonString().toArray())
            } catch (_: Exception) {
                @Expect(false, true)
                try { eprintln("rss_child_cleanup_proof_failed") } catch (_: Exception) { () }
            }
        }
    }
}

@When[os == "macOS"]
private func rssResourceChild(): Unit {
    let fixture = RssResourceChild()
    try {
        for (round in 0..2) { fixture.call("mtime", "warm-" + round.toString()); fixture.warmCalls += 1 }
        rssResourceRequire(fixture.sourceTerminal())
        fixture.warmFd = rssResourceCount(1); fixture.warmTasks = getThreadCount(); fixture.warmBlocking = getBlockingThreadCount()
        for (name in ["mtime", "empty_stdout", "malformed", "unicode_stdout", "invalid_stdout", "invalid_stderr", "exit_127", "unicode_stderr"]) {
            fixture.counts[name] = 0
            for (round in 0..32) {
                fixture.call(name, name + "-" + round.toString())
                fixture.formalCalls += 1; fixture.counts[name] += 1
                fixture.checkpoint()
            }
            rssResourceRequire(fixture.counts[name] == 32)
        }
        remove(fixture.home.join("bin/ps"))
        fixture.call("mtime", "missing-ps", missing: true); fixture.missingCalls += 1
        fixture.checkpoint()
        rssResourceRequire(fixture.formalCalls == 256 && fixture.warmCalls == 2 && fixture.missingCalls == 1 && fixture.receipts == 258)
        fixture.passed = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
private func rssResourceParent(): Unit {
    rssResourceRequire(getMaxHeapSize() == 67108864)
    let context = managedRecoveryContext(); rssResourceRequire(context[0].isEmpty() && context[1].isEmpty())
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
    let actor = home.join("actor")
    let handles = ArrayList<ManagedOwnedChild>()
    let births = HashMap<Int64, ProcessBirthIdentity>()
    let childSources = HashMap<Int64, (Path, String)>()
    let drains = ArrayList<Future<Array<Byte>>>()
    let baselineFd = rssResourceCount(1); let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
    var formal = false
    var formalSaved = false
    var compilerJoined = false
    var pendingLaunch = false
    try {
        println("R-WRAP-RSS fixture=" + home.fileName + ";nonce=" + nonce)
        File.writeTo(home.join("owner"), ("rss-resource-v1\n" + nonce).toArray())
        let source = project.join("test/fixtures/service_plugin/stdio_protocol/thin_process_output_fixture.cj")
        copy(source, to: home.join("actor-source.cj"))
        rssResourceRequire(File.readFrom(source) == File.readFrom(home.join("actor-source.cj")))
        let sdk = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
        @When[arch == "aarch64"]
        let platform = "darwin_aarch64_llvm"
        @When[arch == "x86_64"]
        let platform = "darwin_x86_64_llvm"
        @When[arch == "aarch64"]
        let distribution = "cangjie-stdx-mac-aarch64-1.0.0.1"
        @When[arch == "x86_64"]
        let distribution = "cangjie-stdx-mac-x86_64-1.0.0.1"
        let stdx = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow())).join("libs/" + distribution + "/" + platform + "/dynamic/stdx")
        let runtime = sdk.join("runtime/lib/" + platform)
        let inputs = JsonObject(); inputs.put("actorSource", JsonString(rssResourceSha(File.readFrom(source))))
        inputs.put("rssSource", JsonString(rssResourceSha(File.readFrom(project.join("src/gateway/core/gateway_process_memory.cj")))))
        inputs.put("sdkCjc", JsonString(rssResourceFileSha(sdk.join("bin/cjc"))))
        File.writeTo(home.join("source-sha256.json"), inputs.toJsonString().toArray())
        pendingLaunch = true
        let compiler = launchManagedRawChild(sdk.join("bin/cjc").toString(), [home.join("actor-source.cj").toString(),
            "--import-path", stdx.toString(), "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options",
            "-rpath " + stdx.toString() + " -rpath " + runtime.toString(), "-o", actor.toString()],
            workingDirectory: Some(home), environment: Some<Map<String, String>>(rssResourceEnvironment()),
            stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe, newGeneration: true)
        handles.add(compiler); pendingLaunch = false
        let compilerBirth = observeProcessBirthIdentity(compiler.pid).getOrThrow()
        births[compiler.pid] = compilerBirth
        let output = spawn { rssResourceDrain(compiler.stdOutPipe) }; drains.add(output)
        let error = spawn { rssResourceDrain(compiler.stdErrPipe) }; drains.add(error)
        let code = compiler.wait(timeout: Some(Duration.second * 60))
        let stdout = output.get(Duration.second * 3); let stderr = error.get(Duration.second * 3)
        compilerJoined = true
        File.writeTo(home.join("compiler.stdout.bin"), stdout); File.writeTo(home.join("compiler.stderr.bin"), stderr)
        let encoding = try { let _ = String.fromUtf8(stdout); let _ = String.fromUtf8(stderr); "valid_utf8" }
            catch (_: Exception) { "invalid_response_encoding" }
        File.writeTo(home.join("compiler-encoding-status"), encoding.toArray())
        compiler.closeStreams()
        let compilerCached = compiler.wait()
        let compilerClosed = compiler.streamsAreClosed()
        let compilerGroupGone = rssResourceGroupGone(compiler.pid)
        let compilerGone = probeProcessBirthIdentity(compilerBirth, MonoTime.now() + Duration.second * 2)
        let compilerProof = JsonObject(); compilerProof.put("code", JsonInt(code)); compilerProof.put("cachedCode", JsonInt(compilerCached))
        compilerProof.put("streamsClosed", JsonBool(compilerClosed)); compilerProof.put("groupGone", JsonBool(compilerGroupGone))
        compilerProof.put("birthGone", JsonBool(compilerGone.conclusive && !compilerGone.alive)); compilerProof.put("readersJoined", JsonBool(compilerJoined))
        compilerProof.put("recordedBeforeFallback", JsonBool(true))
        File.writeTo(home.join("compiler-formal-before-fallback.json"), compilerProof.toJsonString().toArray())
        rssResourceRequire(code == 0 && compilerCached == 0 && compilerClosed && !compiler.isAlive() &&
            compilerGroupGone && compilerGone.conclusive && !compilerGone.alive && exists(actor))
        File.writeTo(home.join("actor.binding"), (nonce + "\n" + rssResourceFileSha(actor)).toArray())
        for (mode in ["absent", "bound"]) {
            let directory = home.join(mode); Directory.create(directory)
            Directory.create(directory.join("bin")); Directory.create(directory.join("cases"))
            File.writeTo(directory.join("owner"), ("rss-resource-v1\n" + nonce).toArray())
            File.writeTo(directory.join("metis.json"), "{\"gateway\":{\"enabled\":false}}".toArray())
            let environment = rssResourceEnvironment()
            environment["HOME"] = directory.toString(); environment["TMPDIR"] = directory.toString()
            environment["METIS_HOME"] = directory.toString(); environment["XDG_CONFIG_HOME"] = directory.join("xdg").toString()
            environment["CURL_HOME"] = directory.toString(); environment["METIS_CJPM_ROOT"] = directory.toString()
            environment["METIS_LOG_FILE"] = directory.join("test.log").toString()
            environment["PATH"] = directory.join("bin").toString()
            environment["METIS_RSS_RESOURCE_CHILD"] = "1"; environment["METIS_RSS_RESOURCE_HOME"] = directory.toString()
            environment["METIS_RSS_RESOURCE_NONCE"] = nonce; environment["METIS_RSS_RESOURCE_MODE"] = mode
            environment["METIS_RSS_RESOURCE_ACTOR"] = actor.toString()
            environment["METIS_STDIO_BROKER_SCRIPT"] = project.join("scripts/metis-stdio-broker.mjs").toString()
            let node = getVariable("METIS_STDIO_BROKER_NODE_COMMAND").getOrDefault({ => managedStdioResolveNodeCommand() })
            rssResourceRequire(Path(node).isAbsolute() && exists(Path(node)))
            environment["METIS_STDIO_BROKER_NODE_COMMAND"] = node
            try (input = File(directory.join("stdin"), OpenMode.ReadWrite), stdout = File(directory.join("stdout"), OpenMode.Write),
                stderr = File(directory.join("stderr"), OpenMode.Write)) {
                pendingLaunch = true
                let child = launchManagedRawChild(getCommand(), ["--filter=ThinGatewayRssResourceTest.rWrapRssActualPsPreservesResultCategoriesAndCloses",
                    "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], workingDirectory: Some(directory),
                    environment: Some<Map<String, String>>(environment), stdIn: ProcessRedirect.FromFile(input),
                    stdOut: ProcessRedirect.FromFile(stdout), stdErr: ProcessRedirect.FromFile(stderr), newGeneration: true)
                handles.add(child); pendingLaunch = false; childSources[child.pid] = (directory, mode)
                let birth = observeProcessBirthIdentity(child.pid).getOrThrow(); births[child.pid] = birth
                rssResourceRequire(birth.pid == child.pid && child.isAlive() && unsafe { getpgid(Int32(child.pid)) } == Int32(child.pid))
                let expected = JsonObject(); expected.put("nonce", JsonString(nonce)); expected.put("mode", JsonString(mode))
                expected.put("pid", JsonInt(child.pid)); expected.put("birth", JsonString(birth.serialize()))
                File.writeTo(directory.join("expected-writer.tmp"), expected.toJsonString().toArray())
                rssResourceRequire(observeProcessBirthIdentity(child.pid)?.serialize() == Some(birth.serialize()) && child.isAlive())
                rename(directory.join("expected-writer.tmp"), to: directory.join("expected-writer"))
                let childCode = child.wait(timeout: Some(Duration.second * 60))
                child.closeStreams()
                let cached = child.wait(); let closed = child.streamsAreClosed(); let groupGone = rssResourceGroupGone(child.pid)
                let deadline = MonoTime.now() + Duration.second * 2
                let gone = probeProcessBirthIdentity(birth, deadline)
                let sourceTerminal = rssResourceInventoryTerminal(directory, mode, nonce, birth, deadline)
                let driverProof = JsonObject(); driverProof.put("code", JsonInt(childCode)); driverProof.put("cachedCode", JsonInt(cached))
                driverProof.put("streamsClosed", JsonBool(closed)); driverProof.put("groupGone", JsonBool(groupGone))
                driverProof.put("birthGone", JsonBool(gone.conclusive && !gone.alive)); driverProof.put("sourceTerminal", JsonBool(sourceTerminal))
                driverProof.put("writerPid", JsonInt(child.pid)); driverProof.put("writerBirth", JsonString(birth.serialize()))
                driverProof.put("recordedBeforeFallback", JsonBool(true))
                File.writeTo(directory.join("parent-driver-formal-before-fallback.json"), driverProof.toJsonString().toArray())
                rssResourceRequire(childCode == 0 && cached == 0 && closed && !child.isAlive() && groupGone &&
                    gone.conclusive && !gone.alive && sourceTerminal)
            }
            let result = JsonValue.fromStr(rssResourceText(File.readFrom(directory.join("result.json")))).asObject()
            rssResourceRequire(result.get("formal").getOrThrow().asBool().getValue() && result.get("terminal").getOrThrow().asBool().getValue() &&
                result.get("recordedBeforeFallback").getOrThrow().asBool().getValue())
            rssResourceRequire(result.get("formalCalls").getOrThrow().asInt().getValue() == 256 && result.get("receipts").getOrThrow().asInt().getValue() == 258 &&
                result.get("warmCalls").getOrThrow().asInt().getValue() == 2 && result.get("missingCalls").getOrThrow().asInt().getValue() == 1)
            rssResourceRequire(rssResourceWait(2000, { => rssResourceCount(1) == baselineFd &&
                getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking }))
        }
        formal = true
    } finally {
        try {
            try {
                let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("recordedBeforeFallback", JsonBool(true))
                proof.put("compilerJoined", JsonBool(compilerJoined)); proof.put("fd", JsonInt(rssResourceCount(1)))
                proof.put("baselineFd", JsonInt(baselineFd)); proof.put("tasks", JsonInt(getThreadCount())); proof.put("blocking", JsonInt(getBlockingThreadCount()))
                File.writeTo(home.join("parent-formal-before-fallback.json"), proof.toJsonString().toArray()); formalSaved = true
            } catch (_: Exception) {
                @Expect(false, true)
                try { eprintln("rss_parent_formal_proof_failed") } catch (_: Exception) { () }
            }
        } finally {
            let deadline = MonoTime.now() + Duration.second * 3
            var terminal = !pendingLaunch
            for (handle in handles) {
                var waited = false
                var status: Int64 = -1
                try { if (handle.isAlive()) { handle.terminate(force: true) } }
                catch (_: Exception) { terminal = false }
                try {
                    let remaining = deadline - MonoTime.now()
                    if (remaining > Duration.Zero) { status = handle.wait(timeout: Some(remaining)); waited = true }
                    else { terminal = false }
                } catch (_: Exception) { terminal = false }
                finally {
                    try { handle.closeStreams() } catch (_: Exception) { terminal = false }
                }
                try {
                    terminal = terminal && waited && status >= 0 && status <= 255 && handle.wait() == status && handle.streamsAreClosed() &&
                        !handle.isAlive() && rssResourceGroupGone(handle.pid)
                    match (births.get(handle.pid)) {
                        case Some(birth) =>
                            let gone = probeProcessBirthIdentity(birth, deadline)
                            terminal = terminal && gone.conclusive && !gone.alive
                            if (let Some(source) <- childSources.get(handle.pid)) {
                                terminal = terminal && rssResourceInventoryTerminal(source[0], source[1], nonce, birth, deadline)
                            }
                        case None => terminal = false
                    }
                } catch (_: Exception) { terminal = false }
            }
            var readersJoined = true
            for (worker in drains) {
                try {
                    let remaining = deadline - MonoTime.now()
                    if (remaining <= Duration.Zero) { readersJoined = false; continue }
                    let _ = worker.get(remaining)
                } catch (_: Exception) { readersJoined = false }
            }
            terminal = terminal && readersJoined && MonoTime.now() <= deadline
            @Expect(terminal, true)
            try {
                let cleanup = JsonObject(); cleanup.put("formal", JsonBool(formal && formalSaved)); cleanup.put("terminal", JsonBool(terminal))
                cleanup.put("readersJoined", JsonBool(readersJoined)); cleanup.put("retained", JsonBool(!(formal && formalSaved && terminal)))
                File.writeTo(home.join("cleanup.json"), cleanup.toJsonString().toArray())
                if (formal && formalSaved && terminal) { remove(home, recursive: true) }
            } catch (_: Exception) {
                @Expect(false, true)
                try { eprintln("rss_parent_cleanup_proof_failed") } catch (_: Exception) { () }
            }
        }
    }
}

@When[os == "macOS"]
@Test
public class ThinGatewayRssResourceTest {
    @TestCase
    public func rWrapRssActualPsPreservesResultCategoriesAndCloses(): Unit {
        if (getVariable("METIS_RSS_RESOURCE_CHILD") == Some("1")) { rssResourceChild(); return }
        rssResourceParent()
    }
}
