package metis

import std.runtime.{getThreadCount, getBlockingThreadCount, getMaxHeapSize}

import metis.core.config.cliModelProviderCatalogDescriptors

import std.collection.HashMap
import std.collection.Map
import std.env.getVariables
import std.env.getProcessId
import std.env.getCommand
import std.env.removeVariable
import std.fs.FileInfo
import std.fs.OpenMode
import std.fs.canonicalize
import std.fs.copy
import std.io.InputStream
import std.posix.chmod
import std.process.ProcessRedirect
import stdx.encoding.json.*
import metis.process.ManagedOwnedChild
import metis.process.{managedRecoveryParseFields, parseProcessInstanceIdentity, probeProcessInstance,
    parseProcessBirthIdentity, observeProcessBirthIdentity}
import metis.process.currentProcessInstanceIdentity
import metis.process.launchManagedRawChild
import metis.process.managedRecoveryInitialize
import metis.process.managedRecoveryLaunchOwned
import metis.process.managedRecoveryExecuteWithOutput
import metis.process.managedRecoveryProbeRecords
import metis.process.managedRecoveryStopOwnedChildren
import std.net.SocketTimeoutException
import std.sync.AtomicBool

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.process.{ManagedStdioBrokerClient, ManagedStdioOperationResult, managedStdioBroker, resetManagedStdioBrokerForTest, shutdownManagedStdioBroker}
import std.collection.ArrayList
import std.core.Duration
import std.convert.Parsable
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove, rename}
import std.net.{IPSocketAddress, TcpServerSocket}
import std.process.executeWithOutput
import std.sync.AtomicInt64
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

@Test
public class CliProgramLifecycleTest {
    @TestCase
    public func hrS3B1AllReturnAndThrowPathsCloseOnlyOwnedBroker(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            let closes = AtomicInt64(0)
            for (code in [0, 2, 7]) {
                let returned = cliRunWithBrokerCleanup({ => code }, { => closes.fetchAdd(1); shutdownManagedStdioBroker() })
                @Expect(returned, code)
            }
            @Expect(closes.load(), 3)
            var thrown = false
            try {
                let _ = cliRunWithBrokerCleanup({ => throw Exception("primary-exception") }, { => closes.fetchAdd(1); shutdownManagedStdioBroker() })
            } catch (error: Exception) { thrown = error.message == "primary-exception" }
            @Expect(thrown, true)
            @Expect(closes.load(), 4)
            @Expect(shutdownManagedStdioBroker().generation, 0)
            let broker = managedStdioBroker()
            let ready = broker.ensureBrokerRunning(timeoutMs: 2000)
            @Expect(ready.ok, true)
            @Expect(cliRunWithBrokerCleanup({ => 0 }, { => shutdownManagedStdioBroker() }), 0)
            @Expect(broker.snapshot().running, false)
            @Expect(broker.snapshot().generation, ready.generation)
            @Expect(cliRunWithBrokerCleanup({ => 0 }, { => shutdownManagedStdioBroker() }), 0)
            @Expect(broker.snapshot().generation, ready.generation)
            @Expect(broker.snapshot().readerCount, 0)
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
        }
    }

    @TestCase
    public func hrS3N1CleanupFailurePreservesPrimaryFailure(): Unit {
        @Expect(cliRunWithBrokerCleanup({ => 0 }, { => ManagedStdioOperationResult(false, "broker_close_write_failed") }), 1)
        @Expect(cliRunWithBrokerCleanup({ => 7 }, { => ManagedStdioOperationResult(false, "broker_close_write_failed") }), 7)
        @Expect(cliRunWithBrokerCleanup({ => 8 }, { => throw Exception("cleanup-error") }), 8)
        var primary = false
        try {
            let _ = cliRunWithBrokerCleanup({ => throw Exception("primary-exception") }, { => throw Exception("cleanup-error") })
        } catch (error: Exception) { primary = error.message == "primary-exception" }
        @Expect(primary, true)
    }

    @TestCase
    public func hrS3P2ThirtyTwoShortLivedCommandsLeaveNoBroker(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let binary = Path(getVariable("METIS_TEST_BIN").getOrDefault({ => CliConfig.cwd.join("target/release/bin/metis").toString() }))
            @Expect(exists(binary), true)
            if (!exists(binary)) { return }
            let home = Path("/tmp/metis-hr-cli-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let previous = getVariable("METIS_HOME")
            let previousMode = getVariable("METIS_STDIO_BROKER_TEST_MODE")
            let previousDiagnostics = getVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER")
            Directory.create(home, recursive: true)
            setVariable("METIS_STDIO_BROKER_TEST_MODE", "1")
            try {
                var observed: Int64 = 0
                for (index in 0..32) {
                    let round = home.join("${index}")
                    let diag = round.join("diagnostics")
                    Directory.create(diag, recursive: true)
                    setVariable("METIS_HOME", round.toString())
                    setVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER", diag.toString())
                    CliConfig.invalidatePathCache()
                    MetisConfigManager.invalidate()
                    CliSettingManager.invalidate()
                    var settings = CliSettingManager.readGatewaySettings()
                    try (socket = TcpServerSocket(bindAt: 0u16)) {
                        socket.bind()
                        settings.port = Int64((socket.localAddress as IPSocketAddress)?.port ?? 0u16)
                    }
                    settings.enabled = true
                    settings.servicePlugins = []
                    let _ = MetisConfigManager.setGatewaySettings(settings)
                    var roundObserved: Int64 = 0
                    for (command in ["stop", "status", "restart"]) {
                        if (command == "restart") { File.writeTo(round.join("metis.json"), "{".toArray()) }
                        let result = executeWithOutput(binary.toString(), ["gateway", command])
                        let stderr = try { String.fromUtf8(result[2]) } catch (_: Exception) { "invalid_response_encoding" }
                        @Expect(stderr.contains("protocol writer failed"), false)
                        @Expect(stderr == "invalid_response_encoding", false)
                        @Expect(result[0], if (command == "restart") { 1 } else { 0 })
                        if (exists(diag)) {
                            for (entry in Directory.readFrom(diag)) {
                                if (!entry.name.endsWith(".json")) { continue }
                                let row = JsonValue.fromStr(String.fromUtf8(File.readFrom(entry.path))).asObject()
                                if (let Some(value) <- row.get("brokerPid")) {
                                    observed += 1
                                    roundObserved += 1
                                    @Expect(row.get("writerFailureKind").getOrThrow().asString().getValue(), "")
                                    @Expect(row.get("closeAckCallbackSeen").getOrThrow().asBool().getValue(), true)
                                    let pid = value.asInt().getValue()
                                    @Expect(executeWithOutput("/bin/kill", ["-0", "${pid}"])[0] != 0, true)
                                }
                            }
                        }
                    }
                    @Expect(roundObserved > 0, true)
                }
                @Expect(observed > 0, true)
            } finally {
                setVariable("METIS_HOME", previous.getOrDefault({ => "" }))
                setVariable("METIS_STDIO_BROKER_TEST_MODE", previousMode.getOrDefault({ => "" }))
                setVariable("METIS_STDIO_BROKER_DIAGNOSTIC_MARKER", previousDiagnostics.getOrDefault({ => "" }))
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                remove(home, recursive: true)
                @Expect(exists(home), false)
            }
        }
    }
    @TestCase
    public func hrS3ActualWriterFailurePreservesPrimaryOutcome(): Unit {
        for (mode in ["success", "failed", "exception"]) {
            let broker = ManagedStdioBrokerClient(brokerTestMode: true)
            let results = ArrayList<ManagedStdioOperationResult>()
            try {
                let ready = broker.ensureBrokerRunning(timeoutMs: 2000)
                @Expect(ready.ok, true)
                @Expect(broker.debugDropBrokerWriterForCloseTest(), true)
                var threw = false
                var code: Int64 = -1
                try {
                    code = cliRunWithBrokerCleanup({ =>
                        if (mode == "exception") { throw Exception("synthetic-primary") }
                        if (mode == "failed") { 7 } else { 0 }
                    }, { =>
                        let result = broker.close(timeoutMs: 2000)
                        results.add(result)
                        result
                    })
                } catch (error: Exception) { threw = error.message == "synthetic-primary" }
                @Expect(threw, mode == "exception")
                if (mode != "exception") { @Expect(code, if (mode == "failed") { 7 } else { 1 }) }
                @Expect(results.size, 1)
                @Expect(results[0].ok, false)
                @Expect(results[0].status, "broker_close_write_failed")
                @Expect(results[0].externalTerminal, false)
                let deadline = MonoTime.now() + Duration.second * 3
                while (MonoTime.now() < deadline && (broker.snapshot().readerCount != 0 || broker.snapshot().dispatcherCount != 0)) {
                    sleep(Duration.millisecond)
                }
                @Expect(broker.snapshot().generation, ready.generation)
                @Expect(broker.snapshot().running, false)
                @Expect(broker.snapshot().ownerCount, 0)
                @Expect(broker.snapshot().readerCount, 0)
                @Expect(broker.snapshot().dispatcherCount, 0)
            } finally {
                broker.debugKillBrokerForTest()
                let _ = broker.close(timeoutMs: 3000)
            }
        }
    }

    @TestCase
    public func hrS3RealCliMainFastAndUsagePathsDoNotCreateBroker(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let previous = getVariable("METIS_HOME")
            let home = Path("/tmp/metis-hr-cli-entry-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            Directory.create(home, recursive: true)
            setVariable("METIS_HOME", home.toString())
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            try {
                @Expect(cliMain(["--help"]), 0)
                @Expect(shutdownManagedStdioBroker().generation, 0)
                @Expect(cliMain(["gateway", "synthetic-invalid-subcommand"]), 1)
                @Expect(shutdownManagedStdioBroker().generation, 0)
            } finally {
                let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                setVariable("METIS_HOME", previous.getOrDefault({ => "" }))
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                remove(home, recursive: true)
            }
        }
    }

}


// Scratch private-helper template. Instantiate once per package, not per test.
// Required imports are listed in manifest; no production/public test framework.
@When[os == "macOS"]
foreign {
    func getpgid(pid: Int32): Int32
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}

@When[os == "macOS"]
private func interactiveThinPidGone(pid: Int64): Bool {
    if (pid <= 1 || pid > Int64(Int32.Max)) { return false }
    // Read-only signal0; never authorize cleanup from this numeric observation.
    let result = unsafe { kill(Int32(pid), 0) }
    result != 0 && unsafe { __error().read() } == 3
}

@When[os == "macOS"]
private func interactiveThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func interactiveThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), interactiveThinCount(6))
}

@When[os == "macOS"]
private func interactiveThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func interactiveThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func interactiveThinRead(stream: InputStream): Array<Byte> {
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
private func interactiveThinJoin(worker: Future<Array<Byte>>): Bool {
    try { let _ = worker.get(Duration.second * 3); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class InteractiveThinCase {
    let home: Path
    let actor: Path
    let journal: Path
    let parent: String
    let nonce: String
    let bound: Bool
    var failed = false
    var completed = false
    var auxiliaryJoined = true
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
                let receipt = JsonValue.fromStr(interactiveThinText(entry.path)).asObject()
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
        while (MonoTime.now() < deadline && (!sourceTerminal() || interactiveThinCount(1) > fd || !interactiveThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        let currentSource = sourceTerminal()
        let currentFd = interactiveThinCount(1)
        let currentThreads = interactiveThinThreadSnapshot()
        let fdOk = currentFd == fd
        let cjTasksOk = currentThreads[0] <= threadBaseline[0]
        let cjBlockingOk = currentThreads[1] <= threadBaseline[1]
        check(currentSource); check(fdOk); check(cjTasksOk && cjBlockingOk)
        println("R-THREADS warmFd=${fd};finalFd=${currentFd};sourceOk=${currentSource};fdOk=${fdOk};cjTasksOk=${cjTasksOk};cjBlockingOk=${cjBlockingOk};warmCjTasks=${threadBaseline[0]};finalCjTasks=${currentThreads[0]};warmCjBlocking=${threadBaseline[1]};finalCjBlocking=${currentThreads[1]};warmOsThreads=${threadBaseline[2]};finalOsThreads=${currentThreads[2]}")
    }
    func finish(): Unit { completed = !failed }
    func restore(): Unit {
        for ((key, prior) in priorEnvironment) {
            match (prior) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
        }
    }
}

@When[os == "macOS"]
private func interactiveThinCompileActor(home: Path,
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
    try {
        output = Some(spawn { interactiveThinRead(compiler.stdOutPipe) }); error = Some(spawn { interactiveThinRead(compiler.stdErrPipe) })
        let code = compiler.wait(timeout: Some(Duration.second * 60)); reaped = true
        let _ = output.getOrThrow().get(); let _ = error.getOrThrow().get()
        if (code != 0 || !exists(binary) || !FileInfo(binary).isRegular()) { throw Exception("thin_actor_compile_failed") }
    } catch (failure: Exception) { original = Some(failure) }
    finally {
        try {
            if (compiler.isAlive()) { compiler.terminate(force: true) }
            let _ = compiler.wait(timeout: Some(Duration.second * 3)); reaped = true
        } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        compiler.closeStreams()
        let outputJoined = output.map({ worker => interactiveThinJoin(worker) }) ?? true
        let errorJoined = error.map({ worker => interactiveThinJoin(worker) }) ?? true
        joined = outputJoined && errorJoined
        File.writeTo(home.join("compiler-proof"), "joined:${joined}\nreaped:${reaped}\n".toArray())
    }
    if (let Some(failure) <- original) { throw failure }
    if (!joined || !reaped || !compiler.streamsAreClosed()) { throw Exception("thin_actor_compile_pending") }
    (binary, true)
}

@When[os == "macOS"]
private func interactiveThinFeederSource(home: Path, directory: Path, parent: String, binding: String,
    nonce: String, ordinal: Int64, owned: ManagedOwnedChild): Bool {
    let markerText = interactiveThinText(home.join("stdin-ready-${ordinal}"))
    let marker = managedRecoveryParseFields(markerText).getOrThrow()
    if (marker.get("nonce") != Some(nonce) || marker.get("ordinal") != Some(ordinal.toString())) { return false }
    let identity = parseProcessInstanceIdentity(marker.get("identity").getOrThrow()).getOrThrow()
    if (marker.get("pid") != Some(identity.pid.toString())) { return false }
    let first = probeProcessInstance(identity, MonoTime.now() + Duration.second)
    if (!first.conclusive || !first.alive || !owned.isAlive()) { return false }
    let group = Int64(unsafe { getpgid(Int32(identity.pid)) })
    if (group <= 1) { return false }
    let headerText = interactiveThinText(directory.join("inventory"))
    let header = managedRecoveryParseFields(headerText).getOrThrow()
    if (header.get("parent") != Some(parent) || header.get("binding") != Some(binding)) { return false }
    File.writeTo(home.join("stdin-${ordinal}-driver-header.proof"), headerText.toArray())
    File.writeTo(home.join("stdin-${ordinal}-driver-marker.proof"), markerText.toArray())
    for (entry in Directory.readFrom(directory)) {
        if (!entry.name.endsWith("-o-1.spawned") || !entry.isRegular() || entry.isSymbolicLink()) { continue }
        let ownerText = interactiveThinText(entry.path)
        let owner = managedRecoveryParseFields(ownerText).getOrThrow()
        if (owner.get("parent") != Some(parent) || owner.get("pid") != Some(group.toString()) ||
            owner.get("pgid") != Some(group.toString())) { continue }
        let key = owner.get("key").getOrThrow()
        if (entry.name != key + ".spawned") { return false }
        let rootKey = key.removeSuffix("-o-1")
        let helperText = interactiveThinText(directory.join(rootKey + ".spawned"))
        let helper = managedRecoveryParseFields(helperText).getOrThrow()
        if (helper.size != 6 || helper.get("parent") != Some(parent) || helper.get("key") != Some(rootKey) ||
            helper.get("phase") != Some("spawned") || helper.get("pid") != Some(owned.pid.toString()) ||
            helper.get("pgid") != Some("0") || helper.get("birth") != Some("")) { continue }
        let helperBirthText = interactiveThinText(directory.join(rootKey + ".birth"))
        let helperBirth = managedRecoveryParseFields(helperBirthText).getOrThrow()
        if (helperBirth.size != 6 || helperBirth.get("parent") != Some(parent) || helperBirth.get("key") != Some(rootKey) ||
            helperBirth.get("phase") != Some("birth") || helperBirth.get("pid") != Some(owned.pid.toString()) ||
            helperBirth.get("pgid") != Some("0")) { return false }
        let helperRecorded = parseProcessBirthIdentity(helperBirth.get("birth").getOrThrow()).getOrThrow()
        let helperObserved = observeProcessBirthIdentity(owned.pid)
        if (helperRecorded.pid != owned.pid || helperBirth.get("birth") != Some(helperRecorded.serialize()) ||
            helperObserved.isNone() || helperObserved.getOrThrow().serialize() != helperRecorded.serialize()) { return false }
        let birthText = interactiveThinText(directory.join(key + ".birth"))
        let birth = managedRecoveryParseFields(birthText).getOrThrow()
        if (birth.get("parent") != Some(parent) || birth.get("key") != Some(key)) { return false }
        let recorded = parseProcessBirthIdentity(birth.get("birth").getOrThrow()).getOrThrow()
        let observed = observeProcessBirthIdentity(group)
        if (observed.isNone() || observed.getOrThrow().serialize() != recorded.serialize()) { return false }
        File.writeTo(home.join("stdin-${ordinal}-driver-owner.proof"), ownerText.toArray())
        File.writeTo(home.join("stdin-${ordinal}-driver-owner-birth.proof"), birthText.toArray())
        File.writeTo(home.join("stdin-${ordinal}-driver-helper.proof"), helperText.toArray())
        File.writeTo(home.join("stdin-${ordinal}-driver-helper-birth.proof"), helperBirthText.toArray())
        let second = probeProcessInstance(identity, MonoTime.now() + Duration.second)
        let helperSecond = observeProcessBirthIdentity(owned.pid)
        return second.conclusive && second.alive && owned.isAlive() && helperSecond.isSome() &&
            helperSecond.getOrThrow().serialize() == helperRecorded.serialize() &&
            Int64(unsafe { getpgid(Int32(identity.pid)) }) == group
    }
    false
}


@When[os == "macOS"]
private func interactiveThinFeedMemory(home: Path, directory: Path, parent: String, binding: String,
    nonce: String, owned: ManagedOwnedChild, stopped: AtomicBool, settled: AtomicBool): Bool {
    let deadline = MonoTime.now() + Duration.second * 60
    try {
        for (ordinal in 0..32) {
            let ready = home.join("stdin-ready-${ordinal}")
            while (!exists(ready) && !stopped.load() && MonoTime.now() < deadline && owned.isAlive()) {
                sleep(Duration.millisecond * 5)
            }
            if (stopped.load() || !exists(ready) || MonoTime.now() >= deadline ||
                !interactiveThinFeederSource(home, directory, parent, binding, nonce, ordinal, owned)) { return false }
            // One command per actual ready round. Do not close stdin: EOF is
            // readable to RawInputUtils and would turn Enter into multiline.
            if (!owned.isAlive()) { return false }
            // Home clears command completion without changing the buffer. A
            // plain Enter would only accept the /memory status suggestion.
            let input = "/memory\u{1}\n".toArray()
            File.writeTo(home.join("stdin-${ordinal}-input.bin"), input)
            owned.stdInPipe.write(input)
            if (!owned.isAlive()) { return false }
        }
        true
    } catch (_: Exception) { false }
    finally { settled.store(true) }
}

@When[os == "macOS"]
private func interactiveThinRun(filter: String, action: (InteractiveThinCase) -> Unit, stdin!: Array<Byte> = [], keepOpenMemory!: Bool = false): Bool {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || interactiveThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let fixture = InteractiveThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        try { action(fixture) }
        finally {
            let terminal = fixture.terminal()
            File.writeTo(home.join("formal-before-fallback.json"),
                ("{\"formal\":${fixture.completed && !fixture.failed},\"terminal\":${terminal},\"recorded\":true}").toArray())
            if (terminal) { fixture.restore() }
            else { eprintln("thin_child_cleanup_pending_evidence_retained") }
        }
        return fixture.completed && !fixture.failed && fixture.terminal()
    }
    synchronized(MetisProcessEnvironmentLock) {
        let outer = Directory.createTemp("/private/tmp")
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(outer.join("owned.marker"), nonce.toArray())
        println("R-WRAP fixture=${outer.fileName};nonce=${nonce};kind=${filter}")
        var formal = false
        var compilerReady = false
        try {
            let artifact = interactiveThinCompileActor(outer); compilerReady = artifact[1]
            let (_, nodeBytes, _) = managedRecoveryExecuteWithOutput("which", ["node"])
            let node = try { String.fromUtf8(nodeBytes).trimAscii() }
                catch (_: Exception) { throw Exception("thin_node_resolution_failed") }
            if (node.isEmpty() || !Path(node).isAbsolute() || !FileInfo(node).isRegular()) {
                throw Exception("thin_node_resolution_failed")
            }
            var allCases = true
            for (mode in ["absent", "bound"]) {
                let home = outer.join(mode); Directory.create(home)
                File.writeTo(home.join("metis.json"), "{}".toArray())
                File.writeTo(home.join("stdin"), stdin)
                let environment = HashMap(getVariables())
                environment.remove("cjHeapSize")
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
                environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = ""; environment["METIS_PROCESS_RECOVERY_PARENT"] = ""
                environment["METIS_STDIO_BROKER_NODE_COMMAND"] = node
                environment["METIS_STDIO_BROKER_SCRIPT"] = canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString()
                let driver = outer.join(mode + "-driver-inventory")
                let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
                let binding = "thin-driver-" + mode + nonce
                let prior = ArrayList<(String, Option<String>)>()
                for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT",
                    "METIS_STDIO_BROKER_NODE_COMMAND"]) { prior.add((key, getVariable(key))) }
                var child = None<ManagedOwnedChild>; var reaped = false; var terminal = false; var childFormal = false
                var feeder = None<Future<Bool>>
                let feederSettled = AtomicBool(false); let stopFeeder = AtomicBool(false)
                var feederJoined = !keepOpenMemory
                try {
                    setVariable("METIS_STDIO_BROKER_SCRIPT", environment["METIS_STDIO_BROKER_SCRIPT"])
                    setVariable("METIS_STDIO_BROKER_NODE_COMMAND", node)
                    if (!managedRecoveryInitialize(driver, parent, binding)) { throw Exception("thin_driver_inventory_failed") }
                    try (input = File(home.join("stdin"), OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
                        child = Some(managedRecoveryLaunchOwned(getCommand(), ["--filter=" + filter, "--parallel=1",
                            "--no-progress", "--no-color", "--no-capture-output"], environment: Some<Map<String, String>>(environment),
                            stdIn: if (keepOpenMemory) { ProcessRedirect.Pipe } else { ProcessRedirect.FromFile(input) },
                            stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
                    }
                    if (keepOpenMemory) {
                        let owned = child.getOrThrow()
                        feeder = Some(spawn { interactiveThinFeedMemory(home, driver, parent, binding, nonce,
                            owned, stopFeeder, feederSettled) })
                    }
                    let code = child.getOrThrow().wait(timeout: Some(Duration.second * 60)); reaped = true
                    if (let Some(worker) <- feeder) {
                        feederJoined = try { worker.get(Duration.second * 3) && feederSettled.load() }
                            catch (_: Exception) { false }
                    }
                    let heap = JsonValue.fromStr(interactiveThinText(home.join("heap-baseline.json"))).asObject()
                    println("R-INTERACTIVE-HEAP-PARENT envAbsent=${heap.get("envAbsent").getOrThrow().asBool().getValue()};childMaxHeapBytes=${heap.get("maxHeapBytes").getOrThrow().asInt().getValue()};parentMaxHeapBytes=${getMaxHeapSize()}")
                    child.getOrThrow().closeStreams()
                    let proof = JsonValue.fromStr(interactiveThinText(home.join("formal-before-fallback.json"))).asObject()
                    let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                    terminal = source.ok && source.terminal
                    childFormal = code == 0 && terminal && feederJoined && proof.get("formal").getOrThrow().asBool().getValue() &&
                        proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue()
                    allCases = allCases && childFormal
                    @Expect(childFormal, true)
                    if (!childFormal) { throw Exception("interactive_file_input_child_failed") }
                } finally {
                    File.writeTo(home.join("parent-formal-before-fallback"),
                        "formal:${childFormal}\nreaped:${reaped}\nterminal:${terminal}\nfeederJoined:${feederJoined}\n".toArray())
                    if (let Some(handle) <- child) {
                        try {
                            if (handle.isAlive()) { handle.terminate(force: true) }
                            let _ = handle.wait(timeout: Some(Duration.second * 3)); reaped = true
                        } catch (_: Exception) { () }
                        handle.closeStreams()
                    }
                    stopFeeder.store(true)
                    if (let Some(worker) <- feeder) {
                        // A cancelled/exceptional Future is not a join receipt.
                        feederJoined = try { let _ = worker.get(Duration.second * 3); feederSettled.load() }
                            catch (_: Exception) { false }
                    }
                    let stopped = managedRecoveryStopOwnedChildren((driver.toString(), parent), MonoTime.now() + Duration.second * 3)
                    let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                    terminal = stopped && source.ok && source.terminal && reaped && feederJoined
                    if (terminal) {
                        for ((key, value) in prior) {
                            match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                        }
                    } else { allCases = false; eprintln("thin_driver_cleanup_pending_evidence_retained") }
                }
            }
            formal = allCases
        } finally {
            if (formal && compilerReady) { remove(outer, recursive: true) }
            else { eprintln("thin_interface_failure_evidence_retained") }
        }
        formal
    }
}

@When[os == "macOS"]
private func interactiveThinInteractivePeer(listener: TcpServerSocket, stopped: AtomicBool): Unit {
    while (!stopped.load()) {
        try (peer = listener.accept(timeout: Some(Duration.millisecond * 25))) {
            peer.readTimeout = Some(Duration.second)
            let bytes = Array<Byte>(8192, repeat: 0)
            let count = peer.read(bytes)
            if (count > 0) {
                let _ = try { String.fromUtf8(bytes[..count]) }
                    catch (_: Exception) { throw Exception("thin_peer_invalid_encoding") }
                // Only the isolated notice watcher can contact this owned port.
                // A prompt HTTP rejection keeps it bounded without serving a
                // real model/Gateway or adding a production transport hook.
                peer.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toArray())
            }
        } catch (_: SocketTimeoutException) { () }
        catch (error: Exception) { if (!stopped.load()) { throw error } }
    }
}

@When[os == "macOS"]
private func interactiveThinInteractiveBody(fixture: InteractiveThinCase, throwing: Bool, probe: Bool, expectedFileEof!: Bool = false): Unit {
    let heapAbsent = getVariable("cjHeapSize").isNone()
    let maxHeap = getMaxHeapSize()
    let heapProof = JsonObject()
    heapProof.put("envAbsent", JsonBool(heapAbsent)); heapProof.put("maxHeapBytes", JsonInt(maxHeap))
    File.writeTo(fixture.home.join("heap-baseline.json"), heapProof.toString().toArray())
    println("R-INTERACTIVE-HEAP envAbsent=${heapAbsent};maxHeapBytes=${maxHeap}")
    fixture.check(heapAbsent)
    let workspace = fixture.home.join("workspace"); Directory.create(workspace)
    let receipt = fixture.home.join("mcp.receipt")
    var mcp = None<Path>
    if (!probe) {
        let artifact = interactiveThinCompileActor(fixture.home, sourceFile: "mcp_lifecycle_fixture.cj", outputName: "owned-mcp-actor")
        fixture.check(artifact[1]); mcp = Some(artifact[0])
    }
    let coldFd = interactiveThinCount(1); let coldThreadBaseline = interactiveThinThreadSnapshot()
    let listener = TcpServerSocket(bindAt: 0u16)
    let stop = AtomicBool(false)
    var peer = None<Future<Unit>>
    var joined = false
    var bodyCompleted = false
    var original = None<Exception>
    fixture.auxiliaryJoined = false
    try {
        listener.bind()
        let port = Int64((listener.localAddress as IPSocketAddress)?.port ?? 0u16)
        fixture.check(port > 0)
        peer = Some(spawn { interactiveThinInteractivePeer(listener, stop) })
        let config = JsonObject(); let gateway = JsonObject()
        gateway.put("enabled", JsonBool(true)); gateway.put("port", JsonInt(port))
        let auth = JsonObject(); auth.put("mode", JsonString("token")); auth.put("token", JsonString("fixture-only-token"))
        gateway.put("auth", auth); gateway.put("servicePlugins", JsonArray()); config.put("gateway", gateway)
        let agents = JsonObject(); let defaults = JsonObject(); let model = JsonObject()
        model.put("primary", JsonString("openai:fixture")); defaults.put("model", model)
        defaults.put("workspace", JsonString(workspace.toString())); agents.put("defaults", defaults); config.put("agents", agents)
        let models = JsonObject(); let providers = JsonObject(); let provider = JsonObject()
        provider.put("apiKey", JsonString("fixture-only-key")); provider.put("baseURL", JsonString("http://127.0.0.1:${port}/v1"))
        providers.put("openai", provider); models.put("providers", providers); config.put("models", models)
        if (let Some(binary) <- mcp) {
            let servers = JsonObject(); let server = JsonObject()
            server.put("command", JsonString(binary.toString()))
            server.put("args", JsonArray([JsonString("normal"), JsonString(receipt.toString()), JsonString(fixture.nonce)]))
            server.put("env", JsonObject()); servers.put("owned", server); config.put("mcpServers", servers)
        }
        File.writeTo(fixture.home.join("metis.json"), config.toString().toArray())
        CliConfig.workspaceDirOverride = workspace.toString(); CliConfig.language = "general"; CliConfig.internalSubagent = "explorer"
        CliConfig.invalidatePathCache(); CliSettingManager.invalidate(); MetisConfigManager.invalidate()
        let invalid = [255u8, 254u8, 128u8, 0u8]
        var expectedFailure = ""
        try { let _ = String.fromUtf8(invalid) } catch (error: Exception) { expectedFailure = error.message }
        if (throwing) { File.writeTo(workspace.join("MEMORY.md"), invalid) }
        let fd = interactiveThinCount(1); let threadBaseline = interactiveThinThreadSnapshot()
        var completed: Int64 = 0
        let rounds: Int64 = if (probe) { 1 } else { 32 }
        for (ordinal in 0..rounds) {
            if (exists(receipt)) { remove(receipt) }
            if (throwing) {
                // Publish only a closed complete record. The parent feeds one
                // line for this round and leaves the pipe open until exit.
                let identity = currentProcessInstanceIdentity().getOrThrow()
                let pending = fixture.home.join("stdin-ready-${ordinal}.pending")
                File.writeTo(pending, ("managed-recovery-v1\nnonce:${fixture.nonce}\nordinal:${ordinal}\npid:${identity.pid}\nidentity:${identity.serialize()}\n").toArray())
                rename(pending, to: fixture.home.join("stdin-ready-${ordinal}"), overwrite: false)
            }
            var code: Int64 = -1; var failure = ""
            var caughtException = false; var knownEofLengthMismatch = false
            try { code = runCliProgram(["interactive", "--language", "general"]) }
            catch (error: Exception) {
                failure = error.message; caughtException = true
                knownEofLengthMismatch = failure == "Read bytes(0) != Expected bytes(1)"
            }
            let failureCategory = if (failure.isEmpty()) { "none" }
                else if (throwing && failure == expectedFailure) { "expected_input_encoding" }
                else if (knownEofLengthMismatch) { "known_input_eof_length_mismatch" }
                else { "unexpected_exception" }
            println("R-INTERACTIVE-RETURN code=${code};failureCategory=${failureCategory};caughtException=${caughtException};knownEofLengthMismatch=${knownEofLengthMismatch};probe=${probe};throwing=${throwing};bound=${fixture.bound}")
            if (expectedFileEof) {
                fixture.check(caughtException && knownEofLengthMismatch && code == -1)
            } else {
                fixture.check(failure == if (throwing) { expectedFailure } else { "" })
                if (!throwing) { fixture.check(code == 0) }
            }
            if (!probe) {
                fixture.check(exists(receipt))
                if (exists(receipt)) {
                    let row = JsonValue.fromStr(interactiveThinText(receipt)).asObject()
                    fixture.check(row.get("nonce").getOrThrow().asString().getValue() == fixture.nonce)
                    fixture.check(row.get("phase").getOrThrow().asString().getValue() == "tools")
                    let pid = row.get("pid").getOrThrow().asInt().getValue()
                    let deadline = MonoTime.now() + Duration.second * 2
                    while (MonoTime.now() < deadline && !interactiveThinPidGone(pid)) { sleep(Duration.millisecond * 10) }
                    fixture.check(interactiveThinPidGone(pid))
                }
            }
            fixture.stable(fd, threadBaseline); completed += 1
        }
        fixture.check(completed == rounds)
        println("R-WRAP-INTERACTIVE actualRounds=${completed};probe=${probe};throwing=${throwing};bound=${fixture.bound};contextTerminalBeforePeerClose=${fixture.sourceTerminal()};formal=${!fixture.failed}")
        bodyCompleted = true
    } catch (failure: Exception) { original = Some(failure) }
    finally {
        stop.store(true)
        try { listener.close() } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        joined = match (peer) {
            case Some(worker) =>
                try { worker.get(Duration.second * 3); true }
                catch (_: TimeoutException) { false }
                catch (failure: Exception) { if (original.isNone()) { original = Some(failure) }; true }
            case None => true
        }
        fixture.auxiliaryJoined = joined
        fixture.check(joined)
        try { if (joined) { fixture.stable(coldFd, coldThreadBaseline) } }
        catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        // Cleanup completion cannot turn a failed input probe into a PASS.
        if (joined && bodyCompleted && original.isNone()) { fixture.finish() }
    }
    if (let Some(failure) <- original) { throw failure }
}

// The EOF negative is separate from legal CtrlD exit. Formal selections each
// prove their own legal-input precondition without relying on case ordering.

@When[os == "macOS"]
@Test
public class ThinInteractiveEntryResourceTest {
    // This deliberately reaches regular-file EOF and verifies cleanup of the
    // exact input error. It is not evidence that exit-newline is normal input.
    @TestCase
    public func rWrapInteractivePrivateFileEofIsFixedDiagnostic(): Unit {
        let passed = interactiveThinRun("ThinInteractiveEntryResourceTest.rWrapInteractivePrivateFileEofIsFixedDiagnostic", { fixture =>
            interactiveThinInteractiveBody(fixture, false, true, expectedFileEof: true)
        }, stdin: "exit\n".toArray())
        if (!passed) { throw Exception("interactive_file_stdin_probe_failed") }
    }

    // Independent input probe. It preserves the historical exit-newline failure
    // and does not substitute for either formal lifecycle case.
    @TestCase
    public func rWrapInteractivePrivateFileCtrlDProbe(): Unit {
        let passed = interactiveThinRun("ThinInteractiveEntryResourceTest.rWrapInteractivePrivateFileCtrlDProbe", { fixture =>
            interactiveThinInteractiveBody(fixture, false, true)
        }, stdin: [4u8])
        if (!passed) { throw Exception("interactive_ctrl_d_probe_failed") }
    }

    @TestCase
    public func rWrapInteractiveEntryClosesActualMcpOnReturn(): Unit {
        // A standalone selection of this formal case proves its own input
        // precondition. No testcase ordering or persisted marker is trusted.
        if (getVariable("METIS_THIN_OUTER").isNone()) { rWrapInteractivePrivateFileCtrlDProbe() }
        let passed = interactiveThinRun("ThinInteractiveEntryResourceTest.rWrapInteractiveEntryClosesActualMcpOnReturn", { fixture =>
            interactiveThinInteractiveBody(fixture, false, false)
        }, stdin: Array<Byte>(32, repeat: 4u8))
        if (!passed) { throw Exception("interactive_file_stdin_formal_failed") }
    }

    @TestCase
    public func rWrapInteractiveEntryClosesActualMcpOnThrow(): Unit {
        if (getVariable("METIS_THIN_OUTER").isNone()) { rWrapInteractivePrivateFileCtrlDProbe() }
        let passed = interactiveThinRun("ThinInteractiveEntryResourceTest.rWrapInteractiveEntryClosesActualMcpOnThrow", { fixture =>
            interactiveThinInteractiveBody(fixture, true, false)
        }, keepOpenMemory: true)
        if (!passed) { throw Exception("interactive_file_stdin_formal_failed") }
    }
}
