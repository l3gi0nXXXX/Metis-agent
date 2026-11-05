package metis.core.surface_tests

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
import std.fs.Directory
import std.fs.File
import std.fs.FileInfo
import std.fs.Path
import std.fs.OpenMode
import std.fs.canonicalize
import std.fs.exists
import std.fs.copy
import std.fs.remove
import std.io.InputStream
import std.posix.chmod
import std.process.ProcessRedirect
import std.time.DateTime
import std.time.MonoTime
import std.unittest.testmacro.*
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

import metis.core.*

import std.unittest.*

private class FakeGatewaySystemProxyReader <: GatewaySystemProxyReader {
    private let value: String

    public init(value: String) {
        this.value = value
    }

    public func readSystemProxy(): String {
        value
    }
}

@Test
public class GatewaySystemProxyResolverTest {
    @TestCase
    public func parseScutilPrefersHttpsProxy(): Unit {
        let raw =
            "HTTPEnable : 1\n" +
            "HTTPProxy : 127.0.0.1\n" +
            "HTTPPort : 7890\n" +
            "HTTPSEnable : 1\n" +
            "HTTPSProxy : 127.0.0.1\n" +
            "HTTPSPort : 7897\n"

        @Expect(parseGatewayScutilProxy(raw), "http://127.0.0.1:7897")
    }

    @TestCase
    public func parseScutilFallsBackToHttpProxy(): Unit {
        let raw =
            "HTTPSEnable : 0\n" +
            "HTTPSProxy : 127.0.0.1\n" +
            "HTTPSPort : 7897\n" +
            "HTTPEnable : 1\n" +
            "HTTPProxy : 127.0.0.1\n" +
            "HTTPPort : 7890\n"

        @Expect(parseGatewayScutilProxy(raw), "http://127.0.0.1:7890")
    }

    @TestCase
    public func parseScutilFallsBackToSocksWhenOnlySocksExists(): Unit {
        let raw =
            "HTTPSEnable : 0\n" +
            "HTTPEnable : 0\n" +
            "SOCKSEnable : 1\n" +
            "SOCKSProxy : 127.0.0.1\n" +
            "SOCKSPort : 1086\n"

        @Expect(parseGatewayScutilProxy(raw), "socks5://127.0.0.1:1086")
    }

    @TestCase
    public func resolveSystemProxyTrimsFakeReaderValue(): Unit {
        let reader = FakeGatewaySystemProxyReader("  http://127.0.0.1:7897  ")

        @Expect(resolveGatewaySystemProxy(systemProxyReader: reader), "http://127.0.0.1:7897")
    }
}


// Scratch private-helper template. Instantiate once per package, not per test.
// Required imports are listed in manifest; no production/public test framework.
@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}


@When[os == "macOS"]
private func systemProxyThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func systemProxyThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), systemProxyThinCount(6))
}

@When[os == "macOS"]
private func systemProxyThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func systemProxyThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func systemProxyThinRead(stream: InputStream): Array<Byte> {
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
private func systemProxyThinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class SystemProxyThinCase {
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
    var missingRounds: Int64 = 0
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
                let receipt = JsonValue.fromStr(systemProxyThinText(entry.path)).asObject()
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
        while (MonoTime.now() < deadline && (!sourceTerminal() || systemProxyThinCount(1) > fd || !systemProxyThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(systemProxyThinCount(1) == fd); check(systemProxyThinThreadsWithin(threadBaseline))
        let currentThreads = systemProxyThinThreadSnapshot()
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
private func systemProxyThinCompileActor(home: Path,
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
    let compileDeadline = MonoTime.now() + Duration.second * 60
    try {
        output = Some(spawn { systemProxyThinRead(compiler.stdOutPipe) }); error = Some(spawn { systemProxyThinRead(compiler.stdErrPipe) })
        let waitRemaining = compileDeadline - MonoTime.now()
        if (waitRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let code = compiler.wait(timeout: Some(waitRemaining)); reaped = true
        let outputRemaining = compileDeadline - MonoTime.now()
        if (outputRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = output.getOrThrow().get(outputRemaining)
        let errorRemaining = compileDeadline - MonoTime.now()
        if (errorRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = error.getOrThrow().get(errorRemaining)
        if (MonoTime.now() > compileDeadline) { throw Exception("thin_actor_compile_timeout") }
        if (code != 0 || !exists(binary) || !FileInfo(binary).isRegular()) { throw Exception("thin_actor_compile_failed") }
    } catch (failure: Exception) { original = Some(failure) }
    finally {
        let cleanupDeadline = MonoTime.now() + Duration.second * 3
        try { if (compiler.isAlive()) { compiler.terminate(force: true) } }
        catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        try {
            let remaining = cleanupDeadline - MonoTime.now()
            if (remaining <= Duration.Zero) { throw Exception("thin_actor_compile_pending") }
            let _ = compiler.wait(timeout: Some(remaining)); reaped = true
        }
        catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        finally {
            try { compiler.closeStreams() }
            catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let outputJoined = output.map({ worker => systemProxyThinJoin(worker, cleanupDeadline) }) ?? true
                let errorJoined = error.map({ worker => systemProxyThinJoin(worker, cleanupDeadline) }) ?? true
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
private enum SystemProxyThinProxySelection { Https | Http | Socks | Empty | Exit7 | Malformed | Invalid | Long }

@When[os == "macOS"]
private func systemProxyThinProxySelections(): Array<SystemProxyThinProxySelection> {
    [SystemProxyThinProxySelection.Https, SystemProxyThinProxySelection.Http, SystemProxyThinProxySelection.Socks, SystemProxyThinProxySelection.Empty,
        SystemProxyThinProxySelection.Exit7, SystemProxyThinProxySelection.Malformed, SystemProxyThinProxySelection.Invalid, SystemProxyThinProxySelection.Long]
}

@When[os == "macOS"]
private func systemProxyThinProxyKey(value: SystemProxyThinProxySelection): String {
    match (value) {
        case Https => "https" case Http => "http" case Socks => "socks" case Empty => "empty"
        case Exit7 => "exit7" case Malformed => "malformed" case Invalid => "invalid" case Long => "long"
    }
}

@When[os == "macOS"]
private func systemProxyThinProxySelect(raw: Option<String>): SystemProxyThinProxySelection {
    match (raw) {
        case Some(value) => match (value) {
            case "https" => SystemProxyThinProxySelection.Https case "http" => SystemProxyThinProxySelection.Http case "socks" => SystemProxyThinProxySelection.Socks
            case "empty" => SystemProxyThinProxySelection.Empty case "exit7" => SystemProxyThinProxySelection.Exit7 case "malformed" => SystemProxyThinProxySelection.Malformed
            case "invalid" => SystemProxyThinProxySelection.Invalid case "long" => SystemProxyThinProxySelection.Long
            case _ => throw Exception("thin_proxy_selector_invalid")
        }
        case None => throw Exception("thin_proxy_selector_invalid")
    }
}

@When[os == "macOS"]
private func systemProxyThinRun(filter: String, action: (SystemProxyThinCase) -> Unit, stdin!: Array<Byte> = []): Unit {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || systemProxyThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let selected = systemProxyThinProxySelect(getVariable("METIS_THIN_PROXY_CASE"))
        let fixture = SystemProxyThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        fixture.selectedCase = systemProxyThinProxyKey(selected)
        try { action(fixture) }
        finally {
            let terminal = fixture.terminal()
            File.writeTo(home.join("formal-before-fallback.json"),
                ("{\"formal\":${fixture.completed && !fixture.failed},\"terminal\":${terminal},\"recorded\":true," +
                    "\"case\":\"${fixture.selectedCase}\",\"nonce\":\"${nonce}\",\"bound\":${fixture.bound}," +
                    "\"warmRounds\":${fixture.warmRounds},\"formalRounds\":${fixture.formalRounds},\"missingRounds\":${fixture.missingRounds}}").toArray())
            if (terminal) { fixture.restore() }
            else { eprintln("thin_child_cleanup_pending_evidence_retained") }
        }
        return
    }
    synchronized(MetisProcessEnvironmentLock) {
        let outer = Directory.createTemp("/private/tmp")
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(outer.join("owned.marker"), nonce.toArray())
        println("R-WRAP fixture=${outer.fileName};nonce=${nonce};kind=${filter}")
        var formal = false
        var compilerReady = false
        let aggregateDeadline = MonoTime.now() + Duration.second * 1103
        var aggregateFormal: Int64 = 0
        var aggregateWarm: Int64 = 0
        var aggregateMissing: Int64 = 0
        let completedCases = HashMap<String, Int64>()
        try {
            let artifact = systemProxyThinCompileActor(outer); compilerReady = artifact[1]
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
                try { let _ = systemProxyThinProxySelect(raw) }
                catch (failure: Exception) { if (failure.message == "thin_proxy_selector_invalid") { selectorRejections += 1 } }
            }
            if (selectorRejections != 2) { throw Exception("thin_proxy_selector_validation_failed") }
            let selections = systemProxyThinProxySelections()
            if (selections.size != 8) { throw Exception("thin_proxy_matrix_incomplete") }
            for (mode in ["absent", "bound"]) {
              for (selected in selections) {
                let caseName = systemProxyThinProxyKey(selected)
                let scheduleKey = mode + "-" + caseName
                if (completedCases.contains(scheduleKey) || MonoTime.now() >= aggregateDeadline) { throw Exception("thin_proxy_schedule_invalid") }
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
                environment["METIS_THIN_PROXY_CASE"] = caseName
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
                    if (remaining <= Duration.Zero) { throw Exception("thin_proxy_aggregate_deadline") }
                    let code = child.getOrThrow().wait(timeout: Some(min(Duration.second * 60, remaining))); reaped = true
                    child.getOrThrow().closeStreams()
                    let proof = JsonValue.fromStr(systemProxyThinText(home.join("formal-before-fallback.json"))).asObject()
                    let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                    terminal = source.ok && source.terminal
                    childFormal = code == 0 && terminal && proof.get("formal").getOrThrow().asBool().getValue() &&
                        proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue() &&
                        proof.get("case").getOrThrow().asString().getValue() == caseName &&
                        proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                        proof.get("bound").getOrThrow().asBool().getValue() == (mode == "bound") &&
                        proof.get("warmRounds").getOrThrow().asInt().getValue() == 2 &&
                        proof.get("formalRounds").getOrThrow().asInt().getValue() == 32 &&
                        proof.get("missingRounds").getOrThrow().asInt().getValue() == (if (caseName == "https") { 1 } else { 0 })
                    if (childFormal) {
                        completedCases[scheduleKey] = proof.get("formalRounds").getOrThrow().asInt().getValue()
                        aggregateFormal += proof.get("formalRounds").getOrThrow().asInt().getValue()
                        aggregateWarm += proof.get("warmRounds").getOrThrow().asInt().getValue()
                        aggregateMissing += proof.get("missingRounds").getOrThrow().asInt().getValue()
                    }
                    allCases = allCases && childFormal
                    @Expect(childFormal, true)
                    if (!childFormal) { throw Exception("thin_proxy_child_formal_failed") }
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
                    if (completedCases.get(mode + "-" + systemProxyThinProxyKey(selected)) != Some<Int64>(32)) { throw Exception("thin_proxy_matrix_incomplete") }
                }
            }
            if (completedCases.size != 16 || aggregateFormal != 512 || aggregateWarm != 32 || aggregateMissing != 2 ||
                MonoTime.now() > aggregateDeadline) { throw Exception("thin_proxy_matrix_incomplete") }
            File.writeTo(outer.join("aggregate-formal.json"),
                ("{\"children\":${completedCases.size},\"formalRounds\":${aggregateFormal},\"warmRounds\":${aggregateWarm}," +
                    "\"missingRounds\":${aggregateMissing},\"selectorRejections\":${selectorRejections},\"parentScheduleSeconds\":1103}").toArray())

            println("R-WRAP-PROXY-AGG children=${completedCases.size};formalRounds=${aggregateFormal};warmRounds=${aggregateWarm};missingRounds=${aggregateMissing};selectorRejections=${selectorRejections}")
            formal = allCases
        } finally {
            if (formal && compilerReady) { remove(outer, recursive: true) }
            else { eprintln("thin_interface_failure_evidence_retained") }
        }
    }
}

// Add this private helper once to each concrete-reader package. The reader
// callback is the concrete public OS reader, never a fake parser/runner.
@When[os == "macOS"]
private func systemProxyThinProxyMatrix(fixture: SystemProxyThinCase, read: () -> String): Unit {
    let https = "<dictionary> {\n HTTPEnable : 1\n HTTPProxy : 127.0.0.1\n HTTPPort : 8080\n HTTPSEnable : 1\n HTTPSProxy : 127.0.0.1\n HTTPSPort : 7897\n}\n"
    let http = "<dictionary> {\n HTTPEnable : 1\n HTTPProxy : 127.0.0.1\n HTTPPort : 8080\n}\n"
    let socks = "<dictionary> {\n SOCKSEnable : 1\n SOCKSProxy : 127.0.0.1\n SOCKSPort : 1080\n}\n"
    let cases: Array<(String, Array<Byte>, Int64, String)> = [
        ("https", https.toArray(), 0, "http://127.0.0.1:7897"),
        ("http", http.toArray(), 0, "http://127.0.0.1:8080"),
        ("socks", socks.toArray(), 0, "socks5://127.0.0.1:1080"),
        ("empty", [], 0, ""), ("exit7", https.toArray(), 7, ""),
        ("malformed", "{malformed-中文😀".toArray(), 0, ""),
        ("invalid", [255u8, 254u8, 128u8, 0u8], 0, ""),
        ("long", (String(Array<Rune>(32768, repeat: r'中')) + "😀\n" + https).toArray(), 0, "http://127.0.0.1:7897")]
    let selected = systemProxyThinProxySelect(getVariable("METIS_THIN_PROXY_CASE"))
    let caseName = systemProxyThinProxyKey(selected)
    fixture.check(fixture.selectedCase == caseName)
    for (round in 0..2) {
        fixture.begin("warm-${round}", ["scutil"])
        fixture.route("scutil", "main", https.toArray(), [], 0)
        fixture.check(read() == "http://127.0.0.1:7897"); fixture.warmRounds += 1
    }
    let fd = systemProxyThinCount(1); let threadBaseline = systemProxyThinThreadSnapshot()
    var completed: Int64 = 0
    for (item in cases) {
        if (item[0] != caseName) { continue }
        for (round in 0..32) {
            fixture.begin(item[0] + "-${round}", ["scutil"])
            fixture.route("scutil", "main", item[1], "私有错误中文😀".toArray(), item[2])
            fixture.check(read() == item[3])
            let receipts = fixture.receipts(); fixture.check(receipts.size == 1)
            if (receipts.size == 1) {
                let args = receipts[0].get("args").getOrThrow().asArray().getItems()
                fixture.check(args.size == 1 && args[0].asString().getValue() == "--proxy")
                fixture.check(receipts[0].get("commandName").getOrThrow().asString().getValue() == "scutil")
            }
            fixture.stable(fd, threadBaseline); completed += 1; fixture.formalRounds += 1
        }
    }
    // Actual missing executable, rather than a fake capture exception.
    if (caseName == "https") {
        fixture.begin("missing", [])
        fixture.check(read().isEmpty()); fixture.check(fixture.receipts().isEmpty()); fixture.stable(fd, threadBaseline)
        fixture.missingRounds += 1
    }
    fixture.check(completed == 32 && fixture.formalRounds == 32 && fixture.warmRounds == 2 &&
        fixture.missingRounds == (if (caseName == "https") { 1 } else { 0 }))
    println("R-WRAP-PROXY case=${caseName};actualRounds=${completed};bound=${fixture.bound};fd=${systemProxyThinCount(1)};sourceTerminal=${fixture.terminal()};formal=${!fixture.failed}")
    fixture.finish()
}


@When[os == "macOS"]
@Test
public class ThinGatewayProxyResourceTest {
    @TestCase
    public func rWrapProxyGatewayConcreteReaderPreservesRawOutputAndCloses(): Unit {
        systemProxyThinRun("ThinGatewayProxyResourceTest.rWrapProxyGatewayConcreteReaderPreservesRawOutputAndCloses", { fixture =>
            let reader = GatewayScutilSystemProxyReader()
            systemProxyThinProxyMatrix(fixture, { => reader.readSystemProxy() })
        })
    }
}
