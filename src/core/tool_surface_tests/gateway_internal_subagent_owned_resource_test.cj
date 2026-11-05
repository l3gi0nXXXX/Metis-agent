package metis.core.tool_surface_tests

import metis.core.tools.GatewaySessionsToolset
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.process.*
import magic.config.Config
import std.collection.{ArrayList, HashMap, Map}
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, copy, exists, remove, rename}
import std.posix.chmod
import std.process.ProcessRedirect
import std.runtime.{getThreadCount, getBlockingThreadCount, getMaxHeapSize}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import stdx.encoding.json.*

// proc_pidinfo already belongs to this package's existing ACP resource test.
@When[os == "macOS"]
foreign { func getpgid(pid: Int32): Int32; func kill(pid: Int32, signal: Int32): Int32; func __error(): CPointer<Int32> }

private func internalCheck(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("internal_subagent_contract_failed") }
}
private func internalText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("internal_subagent_fixture_invalid_encoding") }
}
private func internalObject(path: Path): JsonObject {
    try { JsonValue.fromStr(internalText(path)).asObject() }
    catch (_: Exception) { throw Exception("internal_subagent_fixture_invalid_json") }
}
private func internalResponse(raw: String): JsonObject {
    try { JsonValue.fromStr(raw).asObject() }
    catch (_: Exception) { throw Exception("internal_subagent_response_invalid_json") }
}
private func internalPublish(path: Path, bytes: Array<Byte>): Unit {
    let pending = path.parent.join(path.fileName + ".pending")
    File.writeTo(pending, bytes); rename(pending, to: path)
}
private func internalSha(path: Path): String {
    let digest = SHA256(); let buffer = Array<Byte>(8192, repeat: 0)
    try (file = File(path, OpenMode.Read)) {
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            digest.write(buffer[0..count])
        }
    }
    let result = StringBuilder()
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    for (value in digest.finish()) { result.append(digits[Int64(value >> 4)]); result.append(digits[Int64(value & 15)]) }
    result.toString()
}
private func internalRestore(key: String, previous: Option<String>): Unit {
    match (previous) { case Some(value) => setVariable(key, value) case None => removeVariable(key) }
}
private func internalEnvironment(): HashMap<String, String> {
    let environment = HashMap<String, String>(getVariables())
    for (key in environment.keys().toArray()) {
        let upper = key.toAsciiUpper()
        if (key.startsWith("METIS_") || upper.contains("PROXY") || upper.contains("TOKEN") ||
            upper.contains("API_KEY") || upper.endsWith("_ACCESS_KEY_ID") || upper.contains("SECRET") ||
            upper.contains("PASSWORD") || upper.contains("CREDENTIAL") || key == "BASH_ENV" || key == "ENV" ||
            key == "NODE_OPTIONS" || key == "SSH_AUTH_SOCK" || key == "SSH_AGENT_PID" || key == "MAGIC_LOG_FILE") { environment.remove(key) }
    }
    environment
}
@When[os == "macOS"]
private func internalFd(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("internal_subagent_fd_unknown") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}
@When[os == "macOS"]
private func internalGroupGone(pid: Int64): Bool {
    unsafe { kill(-Int32(pid), 0) == -1 && __error().read() == 3 }
}
@When[os == "macOS"]
private func internalStable(fd: Int64, tasks: Int64, blocking: Int64): Bool {
    let deadline = MonoTime.now() + Duration.second * 2
    while (true) {
        if (internalFd() == fd && getThreadCount() <= tasks && getBlockingThreadCount() <= blocking) { return true }
        if (MonoTime.now() >= deadline) { return false }
        sleep(Duration.millisecond * 2)
    }
    throw Exception("internal_subagent_unreachable")
}

@When[os == "macOS"]
private class InternalSubagentChild {
    let home: Path
    let nonce: String
    let bound: Bool
    let scenario: String
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let toolset = GatewaySessionsToolset()
    let driverSha = internalSha(Path(getCommand()))
    let heldBirths = ArrayList<ProcessBirthIdentity>()
    var calls: Int64 = 0
    var formalRounds: Int64 = 0
    var fd: Int64 = 0
    var tasks: Int64 = 0
    var blocking: Int64 = 0
    var passed = false
    var activeCase = "setup"
    var stage = "setup"
    var launchPending = false
    init() {
        home = canonicalize(Path(getVariable("METIS_INTERNAL_SUBAGENT_HOME").getOrThrow()))
        nonce = getVariable("METIS_INTERNAL_SUBAGENT_NONCE").getOrThrow()
        bound = getVariable("METIS_INTERNAL_SUBAGENT_CONTEXT").getOrThrow() == "bound"
        scenario = getVariable("METIS_INTERNAL_SUBAGENT_SCENARIO").getOrThrow()
        internalCheck(home.toString().startsWith("/private/tmp/") && internalText(home.join("owner")) == nonce)
        internalCheck(getMaxHeapSize() == 67108864 && oldDirectory.isNone() && oldParent.isNone())
        internalCheck(getVariable("PATH") == Some(home.join("bin").toString()))
        internalCheck(internalSha(home.join("bin/cjpm")) == internalText(home.parent.join("actor.sha")))
        CliConfig.workspaceDirOverride = home.toString(); CliConfig.invalidatePathCache()
        CliConfig.language = "zh"; CliConfig.model = "openai:fixture"
        MetisConfigManager.invalidate(); CliSettingManager.invalidate()
        Config.logFile = home.join("magic.log").toString()
        internalPublish(home.join("driver-identity"), parent.toArray())
        if (bound) { internalCheck(managedRecoveryInitialize(home.join("inventory"), parent, nonce)) }
        var settings = CliSettingManager.readGatewaySettings()
        settings.subagents.requireAgentId = false; settings.subagents.allowAgents = ["*"]
        let _ = MetisConfigManager.setGatewaySettings(settings)
        CliSettingManager.invalidate()
        setVariable("METIS_INTERNAL_SUBAGENT_PROMPT_ROOT", CliConfig.dotDir.join("gateway-subagent-prompts").toString())
    }
    func sourceTerminal(deadline!: MonoTime = MonoTime.now() + Duration.second * 2): Bool {
        if (!bound) { return true }
        let result = managedRecoveryProbeRecords(home.join("inventory"), parent, nonce, deadline)
        return result.ok && result.terminal
    }
    func settled(deadline!: MonoTime = MonoTime.now() + Duration.second * 5): Bool {
        while (toolset.debugManagedSubagentOwnerCountsForTest() != (0, 0) && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 2)
        }
        return toolset.debugManagedSubagentOwnerCountsForTest() == (0, 0)
    }
    func checkpoint(): Unit {
        stage = "resource_checkpoint"
        internalCheck(settled() && sourceTerminal())
        internalCheck(internalStable(fd, tasks, blocking))
    }
    func run(name: String, actorMode: String, cancel!: String = "", failed!: Bool = false): Unit {
        activeCase = name; stage = "prepare"
        let directory = home.join("cases/" + name); Directory.create(directory)
        let task = "owned task 中文😀\nsecond line 'quoted' `literal` $(literal) " + name
        File.writeTo(directory.join("owner"), nonce.toArray())
        File.writeTo(directory.join("task.bin"), task.toArray())
        File.writeTo(directory.join("mode"), actorMode.toArray())
        setVariable("METIS_INTERNAL_SUBAGENT_CASE", directory.toString())
        launchPending = true
        let raw = toolset.sessionsSpawnForCommand(task, Some("owned-internal"), Some("subagent"), Some("explorer"),
            None, None, None, Some(home.toString()), Some<Int64>(30), None, None, None, Some("keep"), None, None)
        launchPending = false
        File.writeTo(directory.join("spawn-response.json"), raw.toArray())
        let response = internalResponse(raw)
        stage = "spawn_response"
        internalCheck(response.get("liveRunStarted").getOrThrow().asBool().getValue())
        internalCheck(response.get("runtime").getOrThrow().asString().getValue() == "subagent" &&
            response.get("agentId").getOrThrow().asString().getValue() == "explorer")
        let session = response.get("sessionKey").getOrThrow().asString().getValue()
        if (!failed) {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!exists(directory.join("receipt.json")) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
            internalCheck(exists(directory.join("receipt.json")))
            stage = "actor_receipt"
            let receipt = internalObject(directory.join("receipt.json"))
            internalCheck(receipt.get("nonce").getOrThrow().asString().getValue() == nonce)
            internalCheck(receipt.get("heapBytes").getOrThrow().asInt().getValue() == 67108864)
            let pid = receipt.get("pid").getOrThrow().asInt().getValue()
            let pgid = receipt.get("pgid").getOrThrow().asInt().getValue()
            internalCheck(pid > 1 && pgid > 1)
            internalCheck(if (bound) { pgid == pid } else { pgid == Int64(unsafe { getpgid(0) }) })
            internalCheck(canonicalize(Path(receipt.get("command").getOrThrow().asString().getValue())) == canonicalize(home.join("bin/cjpm")))
            internalCheck(receipt.get("commandResolution").getOrThrow().asString().getValue() == "unique_owned_PATH" &&
                receipt.get("commandSha").getOrThrow().asString().getValue() == internalText(home.parent.join("actor.sha")))
            let args = receipt.get("args").getOrThrow().asArray().getItems()
            internalCheck(args.size == 6 && args[0].asString().getValue() == "run" &&
                args[1].asString().getValue() == "--skip-build" && args[2].asString().getValue() == "--name" &&
                args[3].asString().getValue() == "metis" && args[4].asString().getValue() == "--run-args")
            let prompt = Path(receipt.get("promptPath").getOrThrow().asString().getValue())
            internalCheck(args[5].asString().getValue() == "--internal-subagent explorer --prompt-file ${prompt.toString()} --output-format plain --language zh --model openai:fixture")
            let expected = "Subagent role: explorer. Focus on exploring the codebase and reporting findings.\nProject path: ${home.toString()}\nSession key: ${session}\n\nTask:\n${task}"
            internalCheck(File.readFrom(directory.join("observed-prompt.bin")) == expected.toArray())
            internalCheck(internalSha(directory.join("observed-prompt.bin")) == receipt.get("promptSha").getOrThrow().asString().getValue())
            internalCheck(internalSha(directory.join("actor.stdout.bin")) == receipt.get("stdoutSha").getOrThrow().asString().getValue())
            internalCheck(internalSha(directory.join("actor.stderr.bin")) == receipt.get("stderrSha").getOrThrow().asString().getValue())
            internalCheck(receipt.get("recoveryDirectory").getOrThrow().asString().getValue() == if (bound) { home.join("inventory").toString() } else { "" })
            internalCheck(receipt.get("recoveryParent").getOrThrow().asString().getValue() == if (bound) { parent } else { "" })
            if (!cancel.isEmpty()) {
                let birth = observeProcessBirthIdentity(pid).getOrThrow(); heldBirths.add(birth)
                internalCheck(toolset.debugManagedSubagentOwnerCountsForTest() == (1, 1))
                File.writeTo(directory.join("observed-live-birth"), birth.serialize().toArray())
                let result = toolset.subagents.invoke(HashMap<String, JsonValue>([
                    ("action", JsonString("kill")), ("target", JsonString(if (cancel == "all") { "all" } else { session }))]))
                internalCheck(!result.isError)
                File.writeTo(directory.join("kill-response.json"), result.content.toArray())
                stage = "kill_response"
                let killed = internalResponse(result.content)
                internalCheck(killed.get("ok").getOrThrow().asBool().getValue())
                if (cancel == "all") {
                    var found = false
                    for (item in killed.get("sessions").getOrThrow().asArray().getItems()) {
                        let row = item.asObject()
                        if (row.get("sessionKey").getOrThrow().asString().getValue() == session) {
                            internalCheck(row.get("hadLiveProcess").getOrThrow().asBool().getValue() &&
                                row.get("hadLiveFuture").getOrThrow().asBool().getValue())
                            found = true
                        }
                    }
                    internalCheck(found && killed.get("killed").getOrThrow().asInt().getValue() >= 1)
                } else {
                    internalCheck(killed.get("cancelRequested").getOrThrow().asBool().getValue() &&
                        killed.get("hadLiveProcess").getOrThrow().asBool().getValue() && killed.get("hadLiveFuture").getOrThrow().asBool().getValue())
                }
                internalCheck(settled() && observeProcessBirthIdentity(pid).isNone())
            } else {
                internalCheck(settled() && exists(directory.join("writers-joined")))
                internalCheck(internalText(directory.join("writers-joined")) == nonce)
            }
        } else {
            internalCheck(settled() && !exists(directory.join("receipt.json")))
        }
        stage = "settled"
        if (cancel.isEmpty()) {
            let rawStatus = toolset.subagents.invoke(HashMap<String, JsonValue>([
                ("action", JsonString("status")), ("target", JsonString(session))]))
            internalCheck(!rawStatus.isError)
            File.writeTo(directory.join("status-response.json"), rawStatus.content.toArray())
            let status = internalResponse(rawStatus.content)
            internalCheck(status.get("state").getOrThrow().asString().getValue() == if (failed) { "failed" } else { "succeeded" })
            internalCheck(!status.get("hasLiveFuture").getOrThrow().asBool().getValue() &&
                !status.get("hasLiveProcess").getOrThrow().asBool().getValue())
            if (!failed) {
                let summary = status.get("run").getOrThrow().asObject().get("resultSummary").getOrThrow().asString().getValue()
                internalCheck(summary.toArray() == internalText(directory.join("actor.stdout.bin")).trimAscii().toArray())
            }
        }
        stage = "source_terminal"
        let sourceProof = JsonObject(); sourceProof.put("context", JsonString(if (bound) { "bound" } else { "absent" }))
        sourceProof.put("terminal", JsonBool(sourceTerminal()))
        if (bound) {
            let observation = managedRecoveryProbeRecords(home.join("inventory"), parent, nonce, MonoTime.now() + Duration.second * 2)
            sourceProof.put("ok", JsonBool(observation.ok)); sourceProof.put("status", JsonString(observation.status))
            internalCheck(observation.ok && observation.terminal)
            let snapshot = directory.join("source"); Directory.create(snapshot)
            for (entry in Directory.readFrom(home.join("inventory"))) {
                if (FileInfo(entry.path).isRegular() && !FileInfo(entry.path).isSymbolicLink()) {
                    copy(entry.path, to: snapshot.join(entry.name))
                }
            }
        }
        internalPublish(directory.join("source-proof.json"), sourceProof.toJsonString().toArray())
        internalCheck(sourceTerminal())
        calls++
    }
    func execute(): Unit {
        run("warm-0", "normal"); run("warm-1", "normal")
        fd = internalFd(); tasks = getThreadCount(); blocking = getBlockingThreadCount()
        internalCheck(settled() && sourceTerminal())
        if (scenario == "fast") {
            for (index in 0..32) { run("formal-${index}", "normal"); checkpoint(); formalRounds++ }
            run("large", "large"); checkpoint()
            internalCheck(formalRounds == 32 && calls == 35)
        } else {
            internalCheck(scenario == "cancel")
            run("kill-one", "hold", cancel: "one"); checkpoint()
            run("kill-all", "hold", cancel: "all"); checkpoint()
            let executable = home.join("bin/cjpm")
            internalCheck(chmod(executable.toString(), 0o000) == 0)
            try { run("invalid", "normal", failed: true); checkpoint() }
            finally { internalCheck(chmod(executable.toString(), 0o700) == 0) }
            rename(executable, to: home.join("saved-cjpm"))
            try { run("missing", "normal", failed: true); checkpoint() }
            finally { rename(home.join("saved-cjpm"), to: executable) }
            internalCheck(calls == 6 && heldBirths.size == 2)
        }
        passed = true
    }
    func finish(): Unit {
        var saved = false
        var formal = false
        var failure = None<Exception>
        try {
            let finalFd = internalFd()
            let finalTasks = getThreadCount(); let finalBlocking = getBlockingThreadCount()
            let ownersZero = toolset.debugManagedSubagentOwnerCountsForTest() == (0, 0)
            let sourceOk = sourceTerminal()
            formal = passed && !launchPending && ownersZero && sourceOk && finalFd == fd && finalTasks <= tasks && finalBlocking <= blocking
            let proof = JsonObject()
            proof.put("formalOk", JsonBool(formal)); proof.put("recordedBeforeFallback", JsonBool(true))
            proof.put("writerPid", JsonInt(getProcessId())); proof.put("heapBytes", JsonInt(getMaxHeapSize()))
            proof.put("driverSha", JsonString(driverSha)); proof.put("launchPending", JsonBool(launchPending))
            proof.put("calls", JsonInt(calls)); proof.put("formalRounds", JsonInt(formalRounds))
            proof.put("activeCase", JsonString(activeCase)); proof.put("stage", JsonString(stage))
            proof.put("warmFd", JsonInt(fd)); proof.put("finalFd", JsonInt(finalFd))
            proof.put("warmCjTasks", JsonInt(tasks)); proof.put("finalCjTasks", JsonInt(finalTasks))
            proof.put("warmBlocking", JsonInt(blocking)); proof.put("finalBlocking", JsonInt(finalBlocking))
            proof.put("ownerCountsZero", JsonBool(ownersZero)); proof.put("strictSourceApplicable", JsonBool(bound))
            proof.put("strictSourceTerminal", JsonBool(sourceOk))
            internalPublish(home.join("formal-before-fallback.json"), proof.toJsonString().toArray()); saved = true
            if (passed) { internalCheck(formal) }
        } catch (error: Exception) { failure = Some(error) }
        finally {
            let deadline = MonoTime.now() + Duration.second * 3
            var terminal = !launchPending
            try { let _ = toolset.subagents.invoke(HashMap<String, JsonValue>([("action", JsonString("kill")), ("target", JsonString("all"))])) }
            catch (_: Exception) { terminal = false }
            try {
                if (bound) { terminal = managedRecoveryStopOwnedChildren((home.join("inventory").toString(), parent), deadline) && terminal }
            } catch (_: Exception) { terminal = false }
            try { terminal = settled(deadline: deadline) && sourceTerminal(deadline: deadline) && terminal }
            catch (_: Exception) { terminal = false }
            for (birth in heldBirths) {
                try { terminal = observeProcessBirthIdentity(birth.pid).isNone() && terminal }
                catch (_: Exception) { terminal = false }
            }
            terminal = MonoTime.now() <= deadline && terminal
            try {
                if (terminal) { internalRestore("METIS_PROCESS_RECOVERY_DIRECTORY", oldDirectory); internalRestore("METIS_PROCESS_RECOVERY_PARENT", oldParent) }
                let result = JsonObject(); result.put("formalOk", JsonBool(formal && saved && failure.isNone()))
                result.put("terminal", JsonBool(terminal)); result.put("recordedBeforeFallback", JsonBool(saved))
                result.put("calls", JsonInt(calls)); result.put("formalRounds", JsonInt(formalRounds))
                result.put("writerPid", JsonInt(getProcessId())); result.put("heapBytes", JsonInt(getMaxHeapSize()))
                result.put("driverSha", JsonString(driverSha))
                internalPublish(home.join("result.json"), result.toJsonString().toArray())
            } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
        }
        if (let Some(error) <- failure) { throw error }
    }
}

@When[os == "macOS"]
private class InternalReturnedChild {
    let child: ManagedOwnedChild
    let birth: ProcessBirthIdentity
    var code: Int64 = -1
    var reaped = false
    init(value: ManagedOwnedChild) {
        child = value
        birth = observeProcessBirthIdentity(child.pid).getOrThrow()
        internalCheck(Int64(unsafe { getpgid(Int32(child.pid)) }) == child.pid)
    }
    func wait(seconds: Int64): Unit {
        code = child.wait(timeout: Some(Duration.second * seconds)); reaped = true
        child.closeStreams()
        internalCheck(child.wait() == code && child.streamsAreClosed() && !child.isAlive())
    }
    func terminal(): Bool {
        try { return reaped && !child.isAlive() && child.streamsAreClosed() &&
            observeProcessBirthIdentity(birth.pid).isNone() && internalGroupGone(child.pid) }
        catch (_: Exception) { return false }
    }
}

@When[os == "macOS"]
private func internalParent(): Unit {
    internalCheck(getMaxHeapSize() == 67108864)
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let root = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let realNode = canonicalize(Path(managedStdioResolveNodeCommand()))
    let sdk = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
    let stdx = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow())).join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
    let actorSource = root.join("test/fixtures/service_plugin/stdio_protocol/internal_subagent_process_fixture.cj")
    let binary = home.join("actor")
    let handles = ArrayList<ManagedOwnedChild>()
    let owners = ArrayList<InternalReturnedChild>()
    let baselineFd = internalFd(); let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
    var passed = false
    var saved = false
    var failure = None<Exception>
    var launchPending = false
    try {
        File.writeTo(home.join("owner"), nonce.toArray())
        println("R-SUBAGENT fixture=${home.fileName};nonce=${nonce};status=started")
        let sourceHashes = JsonObject(); sourceHashes.put("actor", JsonString(internalSha(actorSource)))
        sourceHashes.put("driver", JsonString(internalSha(Path(getCommand()))))
        sourceHashes.put("caller", JsonString(internalSha(root.join("src/core/tools/gateway_sessions_toolset.cj"))))
        sourceHashes.put("broker", JsonString(internalSha(root.join("scripts/metis-stdio-broker.mjs"))))
        File.writeTo(home.join("source-hashes.json"), sourceHashes.toJsonString().toArray())
        let environment = internalEnvironment()
        environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString(); environment["METIS_HOME"] = home.toString()
        environment["XDG_CONFIG_HOME"] = home.join("xdg").toString(); environment["CURL_HOME"] = home.toString()
        try (input = File(home.join("compiler.stdin"), OpenMode.ReadWrite), output = File(home.join("compiler.stdout"), OpenMode.Write),
            error = File(home.join("compiler.stderr"), OpenMode.Write)) {
            launchPending = true
            let compiler = launchManagedRawChild(sdk.join("bin/cjc").toString(), [actorSource.toString(), "--import-path", stdx.toString(),
                "-L", stdx.toString(), "-lstdx.encoding.json", "-lstdx.crypto.digest", "--link-options",
                "-rpath ${sdk.join("runtime/lib/darwin_aarch64_llvm").toString()} -rpath ${stdx.toString()} -rpath /opt/homebrew/opt/openssl@3/lib",
                "-o", binary.toString()], environment: Some<Map<String, String>>(environment), workingDirectory: Some(home),
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error), newGeneration: true)
            handles.add(compiler); launchPending = false
            let owner = InternalReturnedChild(compiler); owners.add(owner)
            owner.wait(60); internalCheck(owner.code == 0 && owner.terminal() && exists(binary))
        }
        let actorSha = internalSha(binary)
        File.writeTo(home.join("actor.sha"), actorSha.toArray())
        sourceHashes.put("actorBinary", JsonString(actorSha))
        File.writeTo(home.join("source-hashes.json"), sourceHashes.toJsonString().toArray())
        for (mode in ["absent", "bound"]) {
            for (scenario in ["fast", "cancel"]) {
                let directory = home.join("${mode}-${scenario}"); Directory.create(directory)
                Directory.create(directory.join("bin")); Directory.create(directory.join("cases"))
                copy(binary, to: directory.join("bin/cjpm")); internalCheck(chmod(directory.join("bin/cjpm").toString(), 0o700) == 0)
                File.writeTo(directory.join("owner"), nonce.toArray())
                File.writeTo(directory.join("cjpm.toml"), "[package]\nname=\"ownedfixture\"\nversion=\"0.0.0\"\n".toArray())
                File.writeTo(directory.join("metis.json"), "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"openai:fixture\"}}}}".toArray())
                let values = internalEnvironment()
                values["HOME"] = directory.toString(); values["TMPDIR"] = directory.toString(); values["METIS_HOME"] = directory.toString()
                values["XDG_CONFIG_HOME"] = directory.join("xdg").toString(); values["CURL_HOME"] = directory.toString()
                values["PATH"] = directory.join("bin").toString()
                values["METIS_INTERNAL_SUBAGENT_HOME"] = directory.toString(); values["METIS_INTERNAL_SUBAGENT_NONCE"] = nonce
                values["METIS_INTERNAL_SUBAGENT_CONTEXT"] = mode; values["METIS_INTERNAL_SUBAGENT_SCENARIO"] = scenario
                values["METIS_CJPM_ROOT"] = directory.toString()
                values["METIS_STDIO_BROKER_NODE_COMMAND"] = realNode.toString()
                values["METIS_STDIO_BROKER_SCRIPT"] = root.join("scripts/metis-stdio-broker.mjs").toString()
                var driverPid: Int64 = 0
                try (input = File(directory.join("stdin"), OpenMode.ReadWrite), output = File(directory.join("stdout"), OpenMode.Write),
                    error = File(directory.join("stderr"), OpenMode.Write)) {
                    launchPending = true
                    let child = launchManagedRawChild(canonicalize(Path(getCommand())).toString(), ["--filter=GatewayInternalSubagentOwnedResourceTest.internalSubagentActualManagedOwnership",
                        "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], workingDirectory: Some(directory),
                        environment: Some<Map<String, String>>(values), stdIn: ProcessRedirect.FromFile(input),
                        stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error), newGeneration: true)
                    handles.add(child); launchPending = false; driverPid = child.pid
                    let owner = InternalReturnedChild(child); owners.add(owner)
                    File.writeTo(directory.join("observed-driver-birth"), owner.birth.serialize().toArray())
                    owner.wait(60); internalCheck(owner.code == 0 && owner.terminal())
                }
                let result = internalObject(directory.join("result.json"))
                internalCheck(result.get("writerPid").getOrThrow().asInt().getValue() == driverPid &&
                    result.get("heapBytes").getOrThrow().asInt().getValue() == 67108864 &&
                    result.get("driverSha").getOrThrow().asString().getValue() == sourceHashes.get("driver").getOrThrow().asString().getValue())
                internalCheck(result.get("formalOk").getOrThrow().asBool().getValue() && result.get("terminal").getOrThrow().asBool().getValue() &&
                    result.get("recordedBeforeFallback").getOrThrow().asBool().getValue())
                internalCheck(result.get("calls").getOrThrow().asInt().getValue() == if (scenario == "fast") { 35 } else { 6 })
                internalCheck(result.get("formalRounds").getOrThrow().asInt().getValue() == if (scenario == "fast") { 32 } else { 0 })
                let formal = internalObject(directory.join("formal-before-fallback.json"))
                println("R-SUBAGENT context=${mode};scenario=${scenario}" +
                    ";calls=${result.get("calls").getOrThrow().asInt().getValue()};formalRounds=${result.get("formalRounds").getOrThrow().asInt().getValue()}" +
                    ";warmFd=${formal.get("warmFd").getOrThrow().asInt().getValue()};finalFd=${formal.get("finalFd").getOrThrow().asInt().getValue()}" +
                    ";warmCjTasks=${formal.get("warmCjTasks").getOrThrow().asInt().getValue()};finalCjTasks=${formal.get("finalCjTasks").getOrThrow().asInt().getValue()}" +
                    ";warmBlocking=${formal.get("warmBlocking").getOrThrow().asInt().getValue()};finalBlocking=${formal.get("finalBlocking").getOrThrow().asInt().getValue()}" +
                    ";strictSource=${formal.get("strictSourceTerminal").getOrThrow().asBool().getValue()}")
            }
        }
        internalCheck(internalStable(baselineFd, baselineTasks, baselineBlocking))
        passed = true
    } catch (error: Exception) { failure = Some(error) }
    finally {
        try {
            let finalFd = internalFd(); let finalTasks = getThreadCount(); let finalBlocking = getBlockingThreadCount()
            let formal = passed && !launchPending && finalFd == baselineFd && finalTasks <= baselineTasks && finalBlocking <= baselineBlocking
            let proof = JsonObject(); proof.put("formalOk", JsonBool(formal)); proof.put("recordedBeforeFallback", JsonBool(true))
            proof.put("launchPending", JsonBool(launchPending))
            let receipts = JsonArray()
            for (owner in owners) {
                let item = JsonObject(); item.put("pid", JsonInt(owner.child.pid)); item.put("birth", JsonString(owner.birth.serialize()))
                item.put("actualCode", JsonInt(owner.code)); item.put("reaped", JsonBool(owner.reaped)); item.put("terminal", JsonBool(owner.terminal()))
                receipts.add(item)
            }
            proof.put("returnedChildren", receipts)
            proof.put("returnedHandleCount", JsonInt(handles.size)); proof.put("birthBoundCount", JsonInt(owners.size))
            proof.put("warmFd", JsonInt(baselineFd)); proof.put("finalFd", JsonInt(finalFd))
            proof.put("warmCjTasks", JsonInt(baselineTasks)); proof.put("finalCjTasks", JsonInt(finalTasks))
            proof.put("warmBlocking", JsonInt(baselineBlocking)); proof.put("finalBlocking", JsonInt(finalBlocking))
            internalPublish(home.join("parent-formal-before-fallback.json"), proof.toJsonString().toArray()); saved = true
            if (passed) { internalCheck(formal) }
        } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
        finally {
            let deadline = MonoTime.now() + Duration.second * 3
            var terminal = !launchPending
            for (handle in handles) {
                var code: Int64 = -1
                var reaped = false
                try {
                    if (handle.isAlive()) { handle.terminate() }
                    let now = MonoTime.now()
                    let left = if (now < deadline) { deadline - now } else { Duration.Zero }
                    code = handle.wait(timeout: Some(left)); reaped = true
                } catch (error: Exception) {
                    terminal = false
                    if (failure.isNone()) { failure = Some(error) }
                } finally {
                    try { handle.closeStreams() }
                    catch (error: Exception) { terminal = false; if (failure.isNone()) { failure = Some(error) } }
                }
                try {
                    terminal = reaped && code >= 0 && code <= 255 && handle.streamsAreClosed() && !handle.isAlive() &&
                        observeProcessBirthIdentity(handle.pid).isNone() && internalGroupGone(handle.pid) && terminal
                } catch (error: Exception) {
                    terminal = false
                    if (failure.isNone()) { failure = Some(error) }
                }
            }
            for (mode in ["absent", "bound"]) {
                for (scenario in ["fast", "cancel"]) {
                    let directory = home.join("${mode}-${scenario}")
                    if (mode == "bound" && exists(directory.join("inventory"))) {
                        try {
                            let identity = internalText(directory.join("driver-identity"))
                            let source = managedRecoveryProbeRecords(directory.join("inventory"), identity, nonce, deadline)
                            terminal = source.ok && source.terminal && terminal
                        } catch (_: Exception) { terminal = false }
                    }
                }
            }
            // Record physical cleanup against its shared deadline before the separate resource window.
            terminal = MonoTime.now() <= deadline && terminal
            try { terminal = internalStable(baselineFd, baselineTasks, baselineBlocking) && terminal }
            catch (_: Exception) { terminal = false }
            if ((!passed || !saved || !terminal) && failure.isNone()) {
                failure = Some(Exception("internal_subagent_final_cleanup_incomplete"))
            }
            try {
                if (passed && failure.isNone() && saved && terminal) { remove(home, recursive: true) }
                else { println("R-SUBAGENT fixture=${home.fileName};nonce=${nonce};status=evidence_retained;terminal=${terminal}") }
            } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
        }
    }
    if (let Some(error) <- failure) { throw error }
}

@When[os == "macOS"]
@Test
public class GatewayInternalSubagentOwnedResourceTest {
    @TestCase
    public func internalSubagentActualManagedOwnership(): Unit {
        if (getVariable("METIS_INTERNAL_SUBAGENT_HOME").isNone()) { internalParent(); return }
        let fixture = InternalSubagentChild()
        var failure = None<Exception>
        try { fixture.execute() } catch (error: Exception) { failure = Some(error) }
        finally {
            try { fixture.finish() } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
        }
        if (let Some(error) <- failure) { throw error }
    }
}
