package metis.core.model

import std.runtime.{getThreadCount, getBlockingThreadCount}

import metis.core.config.cliModelProviderCatalogDescriptors

import std.collection.ArrayList
import std.collection.HashMap
import std.collection.Map
import std.convert.Parsable
import std.core.Duration
import std.env.getVariable
import std.env.getVariables
import std.env.getProcessId
import std.env.getCommand
import std.env.setVariable
import std.env.removeVariable
import std.fs.FileInfo
import std.fs.OpenMode
import std.fs.canonicalize
import std.fs.copy
import std.io.InputStream
import std.posix.chmod
import std.process.ProcessRedirect
import std.time.MonoTime
import stdx.encoding.json.*
import metis.core.config.MetisProcessEnvironmentLock
import metis.process.ManagedOwnedChild
import metis.process.currentProcessInstanceIdentity
import metis.process.launchManagedRawChild
import metis.process.managedRecoveryInitialize
import metis.process.managedRecoveryLaunchOwned
import metis.process.managedRecoveryExecuteWithOutput
import metis.process.managedRecoveryProbeRecords
import metis.process.managedRecoveryStopOwnedChildren

import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

@Test
public class CodexRuntimeSwitchTest {
    private func tempRoot(label: String): Path {
        let root = Path("/tmp/metis-m4-runtime-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        root
    }

    private func fakeCodex(version: String): String {
        let path = this.tempRoot("codex").join("codex")
        File.writeTo(path, "#!/bin/sh\nprintf 'codex-cli ${version}\\n'\n".toArray())
        let (_exitCode, _stdout, _stderr) = executeWithOutput("chmod", ["+x", path.toString()])
        path.toString()
    }

    @TestCase
    public func runtimeParseAndConfigKeysAreFixed(): Unit {
        @Expect(CODEX_RUNTIME_CONFIG_DEFAULT_KEY, "agents.defaults.model.openaiRuntime")
        @Expect(CODEX_RUNTIME_CONFIG_AGENT_KEY, "agents.list[].model.openaiRuntime")
        @Expect(parseCodexRuntimeSwitchArgs("on").desiredRuntime.getOrThrow(), CODEX_RUNTIME_APP_SERVER)
        @Expect(parseCodexRuntimeSwitchArgs("codex").desiredRuntime.getOrThrow(), CODEX_RUNTIME_APP_SERVER)
        @Expect(parseCodexRuntimeSwitchArgs("off").desiredRuntime.getOrThrow(), CODEX_RUNTIME_AUTO)
        @Expect(parseCodexRuntimeSwitchArgs("status").desiredRuntime.isNone(), true)
        @Expect(parseCodexRuntimeSwitchArgs("").desiredRuntime.isNone(), true)
        @Expect(parseCodexRuntimeSwitchArgs("bogus").errors.isEmpty(), false)
        @Expect(normalizeCodexRuntimeValue("openai").isNone(), true)
    }

    @TestCase
    public func configMigrationMovesLegacyKeysAndFallsBackInvalidEnums(): Unit {
        let root = JsonObject()
        let agents = JsonObject()
        let defaults = JsonObject()
        let defaultModel = JsonObject()
        defaultModel.put("openai_runtime", JsonString(CODEX_RUNTIME_APP_SERVER))
        defaults.put("model", defaultModel)
        agents.put("defaults", defaults)

        let list = JsonArray([])
        let agent = JsonObject()
        let agentModel = JsonObject()
        agentModel.put("openaiRuntime", JsonString("bad-runtime"))
        agent.put("model", agentModel)
        list.add(agent)
        agents.put("list", list)
        root.put("agents", agents)

        let result = codexRuntimeMigrateConfig(root)
        @Expect(result.changed, true)
        @Expect(codexRuntimeReadDefaultRuntime(root), CODEX_RUNTIME_APP_SERVER)
        @Expect(agentModel.get("openaiRuntime").getOrThrow().asString().getValue(), CODEX_RUNTIME_AUTO)
        @Expect(result.errors.isEmpty(), false)
        @Expect(result.migratedPaths.contains("agents.defaults.model.openaiRuntime"), true)
        @Expect(result.migratedPaths.contains("agents.list[0].model.openaiRuntime"), true)
    }

    @TestCase
    public func migrationIgnoresUnknownProviderFieldsWithoutFatalError(): Unit {
        let root = JsonObject()
        let agents = JsonObject()
        let defaults = JsonObject()
        let model = JsonObject()
        model.put("provider", JsonString("future-provider"))
        defaults.put("model", model)
        agents.put("defaults", defaults)
        root.put("agents", agents)

        let result = codexRuntimeMigrateConfig(root)
        @Expect(result.changed, false)
        @Expect(result.errors.isEmpty(), true)
        @Expect(result.warnings.isEmpty(), false)
        @Expect(codexRuntimeReadDefaultRuntime(root), CODEX_RUNTIME_AUTO)
    }

    @TestCase
    public func binaryCheckUsesFakeExecutableAndVersionFloor(): Unit {
        @Expect(parseCodexAppServerVersion("codex-cli 0.130.0").getOrThrow(), "0.130.0")
        @Expect(compareCodexSemver("0.130.0"), 1)
        @Expect(compareCodexSemver("0.125.0"), 0)
        @Expect(compareCodexSemver("0.124.9"), -1)

        let good = checkCodexAppServerBinary(command: this.fakeCodex("0.130.0"))
        @Expect(good.ok, true)
        @Expect(good.version, "0.130.0")

        let old = checkCodexAppServerBinary(command: this.fakeCodex("0.124.9"))
        @Expect(old.ok, false)
        @Expect(old.status, "too-old")
    }

    @TestCase
    public func switchBlocksMissingBinaryAndRendersHumanOutput(): Unit {
        let missing = CodexAppServerBinaryCheck(false, status: "not-found", message: "Codex CLI was not found.")
        let result = applyCodexRuntimeSwitch("auto", Some(CODEX_RUNTIME_APP_SERVER), binaryCheck: missing)
        @Expect(result.success, false)
        @Expect(result.mutated, false)
        @Expect(result.newValue, CODEX_RUNTIME_AUTO)

        let human = renderCodexRuntimeSwitchResult(result)
        @Expect(human.contains("\"ok\""), false)
        @Expect(human.contains("\"result\""), false)
        @Expect(human.contains("\"sessions\""), false)
    }

    @TestCase
    public func switchEnablesDisablesAndKeepsMigrationDiagnosticsNonFatal(): Unit {
        let migration = CodexRuntimeConfigMigrationResult(
            true,
            runtime: CODEX_RUNTIME_AUTO,
            errors: ["Invalid legacy value fell back to auto."],
            migratedPaths: ["agents.defaults.model.openaiRuntime"]
        )
        let enabled = applyCodexRuntimeSwitch(
            "auto",
            Some(CODEX_RUNTIME_APP_SERVER),
            binaryCheck: CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0"),
            migration: Some(migration)
        )
        @Expect(enabled.success, true)
        @Expect(enabled.mutated, true)
        @Expect(enabled.requiresCacheInvalidation, true)
        @Expect(enabled.diagnostics.isEmpty(), false)

        let disabled = applyCodexRuntimeSwitch(
            CODEX_RUNTIME_APP_SERVER,
            Some(CODEX_RUNTIME_AUTO),
            binaryCheck: CodexAppServerBinaryCheck(false, status: "not-found", message: "missing")
        )
        @Expect(disabled.success, true)
        @Expect(disabled.newValue, CODEX_RUNTIME_AUTO)
        @Expect(disabled.mutated, true)
    }
}


@When[os == "macOS"]
private enum CodexThinCaseSelection { Input0 | Input1 | Input2 | Input3 | Input4 | Input5 | Input6 }

@When[os == "macOS"]
private func codexThinSelections(): Array<CodexThinCaseSelection> { [CodexThinCaseSelection.Input0, CodexThinCaseSelection.Input1, CodexThinCaseSelection.Input2, CodexThinCaseSelection.Input3, CodexThinCaseSelection.Input4, CodexThinCaseSelection.Input5, CodexThinCaseSelection.Input6] }

@When[os == "macOS"]
private func codexThinKey(selected: CodexThinCaseSelection): String {
    match (selected) {
        case CodexThinCaseSelection.Input0 => "good"
        case CodexThinCaseSelection.Input1 => "old"
        case CodexThinCaseSelection.Input2 => "malformed"
        case CodexThinCaseSelection.Input3 => "invalid"
        case CodexThinCaseSelection.Input4 => "nonzero"
        case CodexThinCaseSelection.Input5 => "invalid_error"
        case CodexThinCaseSelection.Input6 => "long"
    }
}

@When[os == "macOS"]
private func codexThinSelect(raw: Option<String>): CodexThinCaseSelection {
    match (raw) {
        case Some(value) => match (value) {
            case "good" => CodexThinCaseSelection.Input0
            case "old" => CodexThinCaseSelection.Input1
            case "malformed" => CodexThinCaseSelection.Input2
            case "invalid" => CodexThinCaseSelection.Input3
            case "nonzero" => CodexThinCaseSelection.Input4
            case "invalid_error" => CodexThinCaseSelection.Input5
            case "long" => CodexThinCaseSelection.Input6
            case _ => throw Exception("thin_input_selector_invalid")
        }
        case None => throw Exception("thin_input_selector_invalid")
    }
}

// Scratch private-helper template. Instantiate once per package, not per test.
// Required imports are listed in manifest; no production/public test framework.
@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}


@When[os == "macOS"]
private func codexThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func codexThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), codexThinCount(6))
}

@When[os == "macOS"]
private func codexThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func codexThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func codexThinRead(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        for (index in 0..count) { bytes.add(buffer[index]) }
        if (bytes.size > 65536) { throw Exception("thin_diagnostic_oversize") }
    }
    bytes.toArray()
}

@When[os == "macOS"]
private func codexThinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class CodexThinCase {
    let home: Path
    let actor: Path
    let journal: Path
    let parent: String
    let nonce: String
    let bound: Bool
    var failed = false
    var completed = false
    var auxiliaryJoined = true
    var selectedCase = ""
    var warmRounds: Int64 = 0
    var formalRounds: Int64 = 0
    var negativeRounds: Int64 = 0
    var roundDirectory = None<Path>
    let priorEnvironment = ArrayList<(String, Option<String>)>()
    init(home: Path, actor: Path, nonce: String, bound: Bool) {
        this.home = home; this.actor = actor; this.nonce = nonce; this.bound = bound
        this.journal = home.join("inventory")
        this.parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
            "METIS_THIN_ACTOR_DIRECTORY", "METIS_THIN_ACTOR_NONCE", "METIS_THIN_ACTOR_CASE", "METIS_CJPM_ROOT", "PATH"]) {
            priorEnvironment.add((key, getVariable(key)))
        }
        if (bound) { check(managedRecoveryInitialize(journal, parent, nonce)) }
        else { removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY"); removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
    }
    func check(value: Bool): Unit { failed = failed || !value; @Expect(value, true) }
    func begin(name: String, commands: Array<String>): Unit {
        let path = home.join(name); Directory.create(path); Directory.create(path.join("bin")); Directory.create(path.join("responses"))
        File.writeTo(path.join("binding"), nonce.toArray())
        for (command in commands) {
            copy(actor, to: path.join("bin").join(command))
            check(chmod(path.join("bin").join(command).toString(), 0o700u32) == 0)
        }
        roundDirectory = Some(path)
        setVariable("METIS_THIN_ACTOR_DIRECTORY", path.toString())
        setVariable("METIS_THIN_ACTOR_NONCE", nonce)
        setVariable("METIS_THIN_ACTOR_CASE", "raw_routes")
        // Only this controlled selfchild changes PATH; parent env is unchanged.
        setVariable("PATH", path.join("bin").toString())
    }
    func route(command: String, phase: String, stdout: Array<Byte>, stderr: Array<Byte>, code: Int64): Unit {
        let directory = roundDirectory.getOrThrow().join("responses")
        let prefix = command + "." + phase
        File.writeTo(directory.join(prefix + ".stdout.bin"), stdout)
        File.writeTo(directory.join(prefix + ".stderr.bin"), stderr)
        File.writeTo(directory.join(prefix + ".exit.txt"), code.toString().toArray())
    }
    func receipts(): Array<JsonObject> {
        let results = ArrayList<JsonObject>()
        for (entry in Directory.readFrom(roundDirectory.getOrThrow())) {
            if (entry.name.startsWith("receipt-") && entry.name.endsWith(".json")) {
                check(entry.isRegular() && !entry.isSymbolicLink())
                let receipt = JsonValue.fromStr(codexThinText(entry.path)).asObject()
                check(receipt.get("nonce").getOrThrow().asString().getValue() == nonce)
                check(receipt.get("pid").getOrThrow().asInt().getValue() > 1)
                results.add(receipt)
            }
        }
        results.toArray()
    }
    func sourceTerminal(): Bool {
        if (!bound) { return true }
        let source = managedRecoveryProbeRecords(journal, parent, nonce, MonoTime.now() + Duration.second * 2)
        source.ok && source.terminal
    }
    func terminal(): Bool { auxiliaryJoined && sourceTerminal() }
    func stable(fd: Int64, threadBaseline: (Int64, Int64, Int64)): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        while (MonoTime.now() < deadline && (!sourceTerminal() || codexThinCount(1) > fd || !codexThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(codexThinCount(1) == fd); check(codexThinThreadsWithin(threadBaseline))
        let currentThreads = codexThinThreadSnapshot()
        println("R-THREADS warmCjTasks=${threadBaseline[0]};finalCjTasks=${currentThreads[0]};warmCjBlocking=${threadBaseline[1]};finalCjBlocking=${currentThreads[1]};warmOsThreads=${threadBaseline[2]};finalOsThreads=${currentThreads[2]}")
    }
    func finish(): Unit { completed = !failed }
    func restore(): Unit {
        for ((key, prior) in priorEnvironment) {
            match (prior) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
        }
    }
}

@When[os == "macOS"]
private func codexThinCompileActor(home: Path,
    sourceFile!: String = "thin_process_output_fixture.cj", outputName!: String = "owned-thin-actor"): (Path, Bool) {
    if (!["thin_process_output_fixture.cj", "mcp_lifecycle_fixture.cj"].contains(sourceFile) ||
        !["owned-thin-actor", "owned-mcp-actor"].contains(outputName)) { throw Exception("thin_actor_source_invalid") }
    let source = canonicalize(Path("test/fixtures/service_plugin/stdio_protocol").join(sourceFile))
    let sdk = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
    let compilerPath = sdk.join("bin/cjc")
    let magic = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow()))
    let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
    let binary = home.join(outputName)
    let compiler = launchManagedRawChild(compilerPath.toString(), [source.toString(), "--import-path", stdx.toString(),
        "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options", "-rpath ${stdx.toString()}", "-o", binary.toString()],
        newGeneration: true, stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    var output = None<Future<Array<Byte>>>; var error = None<Future<Array<Byte>>>
    var original = None<Exception>; var joined = false; var reaped = false
    let operationDeadline = MonoTime.now() + Duration.second * 60
    try {
        output = Some(spawn { codexThinRead(compiler.stdOutPipe) }); error = Some(spawn { codexThinRead(compiler.stdErrPipe) })
        let code = compiler.wait(timeout: Some(max(Duration.Zero, operationDeadline - MonoTime.now()))); reaped = true
        let outputRemaining = operationDeadline - MonoTime.now()
        if (outputRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = output.getOrThrow().get(outputRemaining)
        let errorRemaining = operationDeadline - MonoTime.now()
        if (errorRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = error.getOrThrow().get(errorRemaining)
        if (code != 0 || !exists(binary) || !FileInfo(binary).isRegular()) { throw Exception("thin_actor_compile_failed") }
    } catch (failure: Exception) { original = Some(failure) }
    finally {
        let cleanupDeadline = MonoTime.now() + Duration.second * 3
        try {
            if (compiler.isAlive()) { compiler.terminate(force: true) }
            let _ = compiler.wait(timeout: Some(max(Duration.Zero, cleanupDeadline - MonoTime.now()))); reaped = true
        } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        finally {
            try { compiler.closeStreams() }
            catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let outputJoined = output.map({ worker => codexThinJoin(worker, cleanupDeadline) }) ?? true
                let errorJoined = error.map({ worker => codexThinJoin(worker, cleanupDeadline) }) ?? true
                joined = outputJoined && errorJoined && MonoTime.now() <= cleanupDeadline
                try { File.writeTo(home.join("compiler-proof"), "joined:${joined}\nreaped:${reaped}\n".toArray()) }
                catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            }
        }
    }
    if (let Some(failure) <- original) { throw failure }
    if (!joined || !reaped || !compiler.streamsAreClosed()) { throw Exception("thin_actor_compile_pending") }
    (binary, true)
}

@When[os == "macOS"]
private func codexThinRun(filter: String, action: (CodexThinCase) -> Unit, stdin!: Array<Byte> = []): Unit {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || codexThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let selected = codexThinSelect(getVariable("METIS_THIN_INPUT_CASE"))
        let fixture = CodexThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        fixture.selectedCase = codexThinKey(selected)
        var original = None<Exception>
        try { action(fixture) }
        catch (failure: Exception) { original = Some(failure) }
        finally {
            try {
                let terminal = fixture.terminal()
                let childFormal = fixture.completed && !fixture.failed && original.isNone() && terminal
                File.writeTo(home.join("formal-before-fallback.json"),
                    ("{\"formal\":${childFormal},\"terminal\":${terminal},\"recorded\":true," +
                        "\"case\":\"${fixture.selectedCase}\",\"nonce\":\"${nonce}\",\"bound\":${fixture.bound}," +
                        "\"warmRounds\":${fixture.warmRounds},\"formalRounds\":${fixture.formalRounds},\"negativeRounds\":${fixture.negativeRounds}}").toArray())
                if (!childFormal && original.isNone()) { original = Some(Exception("thin_input_child_formal_failed")) }
            } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let cleanupDeadline = MonoTime.now() + Duration.second * 3
                try {
                    var terminal = fixture.auxiliaryJoined
                    if (fixture.bound) {
                        let stopped = managedRecoveryStopOwnedChildren((fixture.journal.toString(), fixture.parent), cleanupDeadline)
                        let source = managedRecoveryProbeRecords(fixture.journal, fixture.parent, fixture.nonce, cleanupDeadline)
                        terminal = terminal && stopped && source.ok && source.terminal
                    }
                    terminal = terminal && MonoTime.now() <= cleanupDeadline
                    if (terminal) { fixture.restore() }
                    else if (original.isNone()) { original = Some(Exception("thin_child_cleanup_pending_evidence_retained")) }
                } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            }
        }
        if (let Some(failure) <- original) { throw failure }
        return
    }
    synchronized(MetisProcessEnvironmentLock) {
        let outer = Directory.createTemp("/private/tmp")
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(outer.join("owned.marker"), nonce.toArray())
        println("R-WRAP fixture=${outer.fileName};nonce=${nonce};kind=${filter}")
        var formal = false
        var compilerReady = false
        let aggregateDeadline = MonoTime.now() + Duration.second * 973
        var aggregateFormal: Int64 = 0
        var aggregateWarm: Int64 = 0
        var aggregateNegative: Int64 = 0
        let completedCases = HashMap<String, Int64>()
        try {
            let artifact = codexThinCompileActor(outer); compilerReady = artifact[1]
            let (_, nodeBytes, _) = managedRecoveryExecuteWithOutput("which", ["node"])
            let node = try { String.fromUtf8(nodeBytes).trimAscii() }
                catch (_: Exception) { throw Exception("thin_node_resolution_failed") }
            if (node.isEmpty() || !Path(node).isAbsolute() || !FileInfo(node).isRegular()) {
                throw Exception("thin_node_resolution_failed")
            }
            var allCases = true
            var selectorRejections: Int64 = 0
            let invalidSelections: Array<Option<String>> = [None, Some("unknown")]
            for (raw in invalidSelections) {
                try { let _ = codexThinSelect(raw) }
                catch (failure: Exception) { if (failure.message == "thin_input_selector_invalid") { selectorRejections += 1 } }
            }
            if (selectorRejections != 2) { throw Exception("thin_input_selector_validation_failed") }
            let selections = codexThinSelections()
            if (selections.size != 7) { throw Exception("thin_input_matrix_incomplete") }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    let caseName = codexThinKey(selected)
                    let scheduleKey = mode + "-" + caseName
                    if (completedCases.contains(scheduleKey) || MonoTime.now() >= aggregateDeadline) { throw Exception("thin_input_schedule_invalid") }
                    let home = outer.join(scheduleKey); Directory.create(home)
                    File.writeTo(home.join("metis.json"), "{}".toArray())
                    File.writeTo(home.join("stdin"), stdin)
                    let environment = HashMap(getVariables())
                    let providerAliases = ArrayList<String>()
                    for (descriptor in cliModelProviderCatalogDescriptors()) {
                        for (alias in descriptor.apiKeyEnvAliases) { providerAliases.add(alias.toAsciiUpper()) }
                    }
                    for (name in environment.keys().toArray()) {
                        let upper = name.toAsciiUpper()
                        if (upper.contains("PROXY") || upper.endsWith("_TOKEN") || upper.endsWith("_API_KEY") ||
                            upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") ||
                            upper.endsWith("_ACCESS_KEY_ID") || providerAliases.contains(upper)) { environment.remove(name) }
                    }
                    environment["METIS_HOME"] = home.toString()
                    environment["CURL_HOME"] = home.toString(); environment["XDG_CONFIG_HOME"] = home.toString()
                    environment["METIS_LOG_FILE"] = home.join("child.log").toString()
                    environment["METIS_THIN_OUTER"] = outer.toString(); environment["METIS_THIN_OUTER_NONCE"] = nonce
                    environment["METIS_THIN_ACTOR_BINARY"] = artifact[0].toString()
                    environment["METIS_THIN_TEST_HOME"] = home.toString()
                    environment["METIS_THIN_BOUND"] = (mode == "bound").toString()
                    environment["METIS_THIN_INPUT_CASE"] = caseName
                    environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = ""; environment["METIS_PROCESS_RECOVERY_PARENT"] = ""
                    environment["METIS_STDIO_BROKER_NODE_COMMAND"] = node
                    environment["METIS_STDIO_BROKER_SCRIPT"] = canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString()
                    let driver = outer.join(scheduleKey + "-driver-inventory")
                    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
                    let binding = "thin-driver-" + scheduleKey + nonce
                    let prior = ArrayList<(String, Option<String>)>()
                    for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT",
                        "METIS_STDIO_BROKER_NODE_COMMAND"]) { prior.add((key, getVariable(key))) }
                    var child = None<ManagedOwnedChild>; var reaped = false; var terminal = false; var childFormal = false
                    var launchPending = false
                    var bodyFailure = None<Exception>
                    try {
                        setVariable("METIS_STDIO_BROKER_SCRIPT", environment["METIS_STDIO_BROKER_SCRIPT"])
                        setVariable("METIS_STDIO_BROKER_NODE_COMMAND", node)
                        if (!managedRecoveryInitialize(driver, parent, binding)) { throw Exception("thin_driver_inventory_failed") }
                        try (input = File(home.join("stdin"), OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
                            launchPending = true
                            child = Some(managedRecoveryLaunchOwned(getCommand(), ["--filter=" + filter, "--parallel=1",
                                "--no-progress", "--no-color", "--no-capture-output"], environment: Some<Map<String, String>>(environment),
                                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
                            launchPending = false
                        }
                        let remaining = aggregateDeadline - MonoTime.now()
                        if (remaining <= Duration.Zero) { throw Exception("thin_input_aggregate_deadline") }
                        let code = child.getOrThrow().wait(timeout: Some(min(Duration.second * 60, remaining))); reaped = true
                        child.getOrThrow().closeStreams()
                        let proof = JsonValue.fromStr(codexThinText(home.join("formal-before-fallback.json"))).asObject()
                        let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                        terminal = source.ok && source.terminal
                        childFormal = code == 0 && terminal && proof.get("formal").getOrThrow().asBool().getValue() &&
                            proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue() &&
                            proof.get("case").getOrThrow().asString().getValue() == caseName &&
                            proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                            proof.get("bound").getOrThrow().asBool().getValue() == (mode == "bound") &&
                            proof.get("warmRounds").getOrThrow().asInt().getValue() == 2 &&
                            proof.get("formalRounds").getOrThrow().asInt().getValue() == 32 &&
                            proof.get("negativeRounds").getOrThrow().asInt().getValue() == (if (caseName == "good") { 2 } else { 0 })
                        if (childFormal) {
                            completedCases[scheduleKey] = proof.get("formalRounds").getOrThrow().asInt().getValue()
                            aggregateFormal += proof.get("formalRounds").getOrThrow().asInt().getValue()
                            aggregateWarm += proof.get("warmRounds").getOrThrow().asInt().getValue()
                            aggregateNegative += proof.get("negativeRounds").getOrThrow().asInt().getValue()
                        }
                        allCases = allCases && childFormal
                        @Expect(childFormal, true)
                        if (!childFormal) { throw Exception("thin_input_child_formal_failed") }
                    } catch (failure: Exception) { bodyFailure = Some(failure) }
                    finally {
                        try {
                            File.writeTo(home.join("parent-formal-before-fallback"),
                                "formal:${childFormal}\nreaped:${reaped}\nterminal:${terminal}\ncase:${caseName}\n".toArray())
                        } catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                        finally {
                            let cleanupDeadline = MonoTime.now() + Duration.second * 3
                            if (let Some(handle) <- child) {
                                try {
                                    if (handle.isAlive()) { handle.terminate(force: true) }
                                    let left = max(Duration.Zero, cleanupDeadline - MonoTime.now())
                                    let _ = handle.wait(timeout: Some(left)); reaped = true
                                } catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                                finally {
                                    try { handle.closeStreams() }
                                    catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                                }
                            }
                            try {
                                let stopped = managedRecoveryStopOwnedChildren((driver.toString(), parent), cleanupDeadline)
                                let source = managedRecoveryProbeRecords(driver, parent, binding, cleanupDeadline)
                                terminal = !launchPending && stopped && source.ok && source.terminal && reaped &&
                                    child.isSome() && child.getOrThrow().streamsAreClosed() && MonoTime.now() <= cleanupDeadline
                                if (terminal) {
                                    for ((key, value) in prior) {
                                        match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                                    }
                                } else {
                                    allCases = false
                                    if (bodyFailure.isNone()) { bodyFailure = Some(Exception("thin_driver_cleanup_pending")) }
                                }
                            } catch (failure: Exception) { allCases = false; if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                        }
                    }
                    if (let Some(failure) <- bodyFailure) { throw failure }
                }
            }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    if (completedCases.get(mode + "-" + codexThinKey(selected)) != Some<Int64>(32)) { throw Exception("thin_input_matrix_incomplete") }
                }
            }
            if (completedCases.size != 14 || aggregateFormal != 448 || aggregateWarm != 28 || aggregateNegative != 4 ||
                MonoTime.now() > aggregateDeadline) { throw Exception("thin_input_matrix_incomplete") }
            File.writeTo(outer.join("aggregate-formal.json"),
                ("{\"children\":${completedCases.size},\"formalRounds\":${aggregateFormal},\"warmRounds\":${aggregateWarm}," +
                    "\"negativeRounds\":${aggregateNegative},\"selectorRejections\":${selectorRejections},\"parentScheduleSeconds\":973}").toArray())

            formal = allCases
        } finally {
            if (formal && compilerReady) { remove(outer, recursive: true) }
            else { eprintln("thin_interface_failure_evidence_retained") }
        }
    }
}

@When[os == "macOS"]
@Test
public class ThinCodexBinaryResourceTest {
    @TestCase
    public func rWrapCodexActualBinaryPreservesResultCategories(): Unit {
        codexThinRun("ThinCodexBinaryResourceTest.rWrapCodexActualBinaryPreservesResultCategories", { fixture =>
            for (warm in 0..2) {
                fixture.begin("warm-${warm}", ["codex"])
                fixture.route("codex", "version", "codex-cli 0.130.0\n".toArray(), [], 0)
                fixture.check(checkCodexAppServerBinary(command: fixture.roundDirectory.getOrThrow().join("bin/codex").toString()).status == "ok")
                fixture.warmRounds += 1
            }
            let fd = codexThinCount(1); let threadBaseline = codexThinThreadSnapshot()
            let cases: Array<(String, Array<Byte>, Array<Byte>, Int64, String)> = [
                ("good", "codex-cli 0.130.0\n".toArray(), [], 0, "ok"),
                ("old", "codex-cli 0.124.9\n".toArray(), [], 0, "too-old"),
                ("malformed", "codex-cli 中文😀\n".toArray(), [], 0, "unparseable-version"),
                ("invalid", [255u8, 254u8, 128u8, 0u8], [], 0, "unparseable-version"),
                ("nonzero", [], "工具错误中文😀".toArray(), 7, "nonzero-exit"),
                ("invalid_error", [], [255u8, 254u8, 128u8, 0u8], 7, "nonzero-exit"),
                ("long", (String(Array<Rune>(32768, repeat: r'中')) + "😀 codex-cli 0.130.0\n").toArray(), [], 0, "ok")]
            var completed: Int64 = 0
            for (item in cases) {
                if (item[0] != fixture.selectedCase) { continue }
                for (round in 0..32) {
                    fixture.begin(item[0] + "-${round}", ["codex"])
                    fixture.route("codex", "version", item[1], item[2], item[3])
                    let result = checkCodexAppServerBinary(command: fixture.roundDirectory.getOrThrow().join("bin/codex").toString())
                    fixture.check(result.status == item[4])
                    if (item[4] == "ok") { fixture.check(result.version == "0.130.0") }
                    let receipts = fixture.receipts(); fixture.check(receipts.size == 1)
                    if (receipts.size == 1) {
                        let args = receipts[0].get("args").getOrThrow().asArray().getItems()
                        fixture.check(args.size == 1 && args[0].asString().getValue() == "--version")
                    }
                    fixture.stable(fd, threadBaseline); completed += 1; fixture.formalRounds += 1
                }
            }
            if (fixture.selectedCase == "good") {
                for (kind in ["missing", "eacces"]) {
                    fixture.begin(kind, if (kind == "eacces") { ["codex"] } else { [] })
                    let command = fixture.roundDirectory.getOrThrow().join("bin/codex")
                    if (kind == "eacces") { fixture.check(chmod(command.toString(), 0o600u32) == 0) }
                    fixture.check(checkCodexAppServerBinary(command: command.toString()).status == "not-found")
                    fixture.check(fixture.receipts().isEmpty()); fixture.stable(fd, threadBaseline)
                    fixture.negativeRounds += 1
                }
            }
            fixture.check(completed == 32 && fixture.formalRounds == 32 && fixture.warmRounds == 2 &&
                fixture.negativeRounds == (if (fixture.selectedCase == "good") { 2 } else { 0 }))
            println("R-WRAP-CODEX case=${fixture.selectedCase};actualRounds=${completed};bound=${fixture.bound};sourceTerminal=${fixture.terminal()};formal=${!fixture.failed}")
            fixture.finish()
        })
    }
}
