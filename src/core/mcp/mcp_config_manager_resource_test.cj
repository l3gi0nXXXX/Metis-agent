package metis.core.mcp

import std.runtime.{getThreadCount, getBlockingThreadCount}

import std.convert.Parsable
import magic.config.Config
import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock,
    cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.process.{ManagedMagicRecoveryLaunchScope, managedRecoveryInitialize, managedRecoveryContext,
    managedRecoveryProbeRecords, managedRecoveryParseFields, currentProcessInstanceIdentity,
    ProcessBirthIdentity, parseProcessBirthIdentity, probeProcessBirthIdentity, observeProcessBirthIdentity}
import std.collection.{ArrayList, HashMap, HashSet}
import std.env.{getVariable, getVariables, getProcessId, getCommand, setVariable, removeVariable}
import std.fs.{Directory, File, FileInfo, Path, OpenMode, canonicalize, exists, remove}
import std.io.{InputStream, OutputStream}
import std.net.{TcpServerSocket, IPSocketAddress}
import metis.process.launchManagedRawChild
import std.process.ProcessRedirect
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}

@When[os == "macOS"]
private func ifaceThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), ifaceCount(6))
}

@When[os == "macOS"]
private func ifaceThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func ifaceCount(flavor: Int32): Int64 {
    var values = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout values, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("interface_observation_failed") }
    Int64(count) / 8
}
@When[os != "macOS"]
private func ifaceCount(_flavor: Int32): Int64 { throw Exception("interface_platform_unsupported") }

private func ifaceText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { throw Exception("interface_fixture_invalid_encoding") }
}

private func ifaceReadAll(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { bytes.add(buffer[index]) }
        if (bytes.size > 65536) { throw Exception("interface_compiler_diagnostic_oversize") }
    }
    bytes.toArray()
}

private func ifaceUnusedModelEndpoint(): String {
    var port: Int64 = 0
    try (server = TcpServerSocket(bindAt: 0u16)) {
        server.bind()
        port = Int64((server.localAddress as IPSocketAddress)?.port ?? 0u16)
    }
    if (port <= 0) { throw Exception("interface_loopback_port_missing") }
    "http://127.0.0.1:${port}/v1"
}

private func ifaceCompilerJoined(worker: Future<Array<Byte>>): Bool {
    try { let _ = worker.get(Duration.second * 3); true }
    catch (_: TimeoutException) { false }
    // Future.get rethrows a completed worker's exception. That worker is joined;
    // its original error is preserved separately by compilePeer.
    catch (_: Exception) { true }
}

private class IfacePreviousProvider <: ProcessLaunchProvider {
    var calls: Int64 = 0
    public func launch(_command: String, _args: Array<String>, _env: Array<(String, String)>, _redirectErr: Bool): ProcessHandle {
        calls += 1
        throw Exception("interface_previous_provider")
    }
}

private class IfaceHandle <: ProcessHandle {
    let inner: ProcessHandle
    var release = true
    var closes: Int64 = 0
    init(inner: ProcessHandle) { this.inner = inner }
    public prop pid: Int64 { get() { inner.pid } }
    public prop stdInPipe: OutputStream { get() { inner.stdInPipe } }
    public prop stdOutPipe: InputStream { get() { inner.stdOutPipe } }
    public prop stdErrPipe: InputStream { get() { inner.stdErrPipe } }
    public func isAlive(): Bool { inner.isAlive() }
    public func isClosed(): Bool { inner.isClosed() }
    public func wait(timeout!: ?Duration): Int64 { inner.wait(timeout: timeout) }
    public func terminate(force!: Bool): Unit { inner.terminate(force: force) }
    public func close(): Unit {
        closes += 1
        // Explicit interface fault injection. This is not an OS timeout claim.
        if (!release) { throw Exception("interface_close_pending") }
        inner.close()
    }
}

private class IfaceProvider <: ProcessLaunchProvider {
    let inner: ProcessLaunchProvider
    let directory: Path
    let handles = ArrayList<IfaceHandle>()
    let births = ArrayList<ProcessBirthIdentity>()
    let groups = HashSet<Int64>()
    var calls: Int64 = 0
    var failAt: Int64 = 0
    var holdClose = false
    init(inner: ProcessLaunchProvider, directory: Path) { this.inner = inner; this.directory = directory }
    public func launch(command: String, args: Array<String>, env: Array<(String, String)>, redirectErr: Bool): ProcessHandle {
        calls += 1
        let copied = args.clone()
        if (calls == failAt) { copied[0] = "invalid_utf8" }
        let handle = IfaceHandle(inner.launch(command, copied, env, redirectErr))
        handle.release = !holdClose
        handles.add(handle)
        for (entry in Directory.readFrom(directory)) {
            if (!entry.name.endsWith(".birth") || !entry.isRegular() || entry.isSymbolicLink()) { continue }
            let fields = managedRecoveryParseFields(ifaceText(entry.path)).getOrThrow()
            if (let Some(birth) <- parseProcessBirthIdentity(fields.get("birth").getOrThrow())) { births.add(birth) }
            let text = fields.get("pgid").getOrDefault({ => "0" })
            let group = Int64.parse(text)
            if (group > 1) { groups.add(group) }
        }
        handle
    }
    func releaseAll(): Unit { for (handle in handles) { handle.release = true } }
    @When[os == "macOS"]
    func gone(): Bool {
        for (handle in handles) {
            if (!handle.isClosed() || handle.isAlive()) { return false }
            let _ = handle.wait(timeout: Some(Duration.second * 3))
        }
        for (birth in births) {
            let value = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
            if (!value.conclusive || value.alive) { return false }
        }
        for (group in groups) {
            if (unsafe { kill(Int32(-group), 0) } == 0 || unsafe { __error().read() } != 3) { return false }
        }
        true
    }
    @When[os != "macOS"]
    func gone(): Bool { false }
}

private class IfaceFixture {
    let home: Path
    let journal: Path
    let binary: Path
    let parent: String
    let binding = "interface-中文😀"
    let previous = IfacePreviousProvider()
    let modelBaseUrl = ifaceUnusedModelEndpoint()
    var scope = None<ManagedMagicRecoveryLaunchScope>
    var provider = None<IfaceProvider>
    var failed = false
    var completed = false
    var compilerWorkersJoined = true
    var compilerTerminal = true
    var servers = JsonObject()
    let receiptBirths = ArrayList<ProcessBirthIdentity>()
    let receiptGroups = HashSet<Int64>()
    init(home: Path) {
        this.home = home
        this.journal = home.join("inventory")
        this.binary = home.join("owned-mcp")
        this.parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    }
    func check(ok: Bool): Unit { if (!ok) { failed = true }; @Expect(ok, true) }
    func complete(): Unit { completed = !failed }
    func compilePeer(): Unit {
        let magic = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow()))
        let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
        let compilerPath = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()).join("bin/cjc"))
        let compiler = launchManagedRawChild(compilerPath.toString(), [canonicalize(Path("test/fixtures/service_plugin/stdio_protocol/mcp_lifecycle_fixture.cj")).toString(),
            "--import-path", stdx.toString(), "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options",
            "-rpath ${stdx.toString()}", "-o", binary.toString()],
            stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe, newGeneration: true)
        let output = spawn { ifaceReadAll(compiler.stdOutPipe) }
        let error = spawn { ifaceReadAll(compiler.stdErrPipe) }
        var original = None<Exception>
        try {
            let _ = output.get(); let _ = error.get()
            if (compiler.wait() != 0 || !exists(binary)) { throw Exception("interface_fixture_compile_failed") }
        } catch (failure: Exception) { original = Some(failure) }
        finally {
            // Closing the actual returned compiler releases both borrowed pipe
            // reads before joining either reader, including diagnostic failures.
            try {
                if (compiler.isAlive()) { compiler.terminate(force: true) }
                let _ = compiler.wait(timeout: Some(Duration.second * 3))
            } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally { compiler.closeStreams() }
            let outputJoined = ifaceCompilerJoined(output)
            let errorJoined = ifaceCompilerJoined(error)
            compilerWorkersJoined = compilerWorkersJoined && outputJoined && errorJoined
            compilerTerminal = compilerTerminal && compiler.streamsAreClosed() && !compiler.isAlive()
        }
        if (let Some(failure) <- original) { throw failure }
        if (!compilerWorkersJoined || !compilerTerminal) { throw Exception("interface_compiler_cleanup_pending") }
    }
    func configure(): Unit {
        let root = JsonObject(); root.put("mcpServers", servers)
        let agents = JsonObject(); let defaults = JsonObject(); let model = JsonObject()
        model.put("primary", JsonString("openai:fixture")); defaults.put("model", model)
        defaults.put("workspace", JsonString(home.join("workspace").toString())); agents.put("defaults", defaults); root.put("agents", agents)
        let models = JsonObject(); let providers = JsonObject(); let openai = JsonObject()
        openai.put("apiKey", JsonString("fixture-only-key")); openai.put("baseURL", JsonString(modelBaseUrl))
        providers.put("openai", openai); models.put("providers", providers); root.put("models", models)
        File.writeTo(home.join("metis.json"), root.toString().toArray())
        CliSettingManager.invalidate(); MetisConfigManager.invalidate()
    }
    func add(name: String, mode: String): Unit {
        let params = JsonObject(); params.put("command", JsonString(binary.toString()))
        params.put("args", JsonArray([JsonString(mode), JsonString(home.join("${name}.receipt").toString()), JsonString(binding)]))
        params.put("env", JsonObject()); servers.put(name, params); configure()
    }
    func beginScope(): Unit {
        check(managedRecoveryInitialize(journal, parent, binding))
        scope = Some(ManagedMagicRecoveryLaunchScope(managedRecoveryContext()))
        installProxy()
    }
    func installProxy(): Unit {
        let real = setProcessLaunchProvider(None).getOrThrow()
        let proxy = IfaceProvider(real, journal)
        provider = Some(proxy)
        let _ = setProcessLaunchProvider(Some<ProcessLaunchProvider>(proxy))
    }
    func restoreManagedProvider(): Unit {
        let _ = setProcessLaunchProvider(Some(provider.getOrThrow().inner))
    }
    func sourceTerminal(): Bool {
        if (!compilerWorkersJoined || !compilerTerminal) { return false }
        if (!exists(journal)) { return provider.isNone() && receiptsGone() }
        let result = managedRecoveryProbeRecords(journal, parent, binding, MonoTime.now() + Duration.second * 3)
        result.ok && result.terminal && (provider.map({ value => value.gone() }) ?? true) && receiptsGone()
    }
    @When[os == "macOS"]
    func receiptsGone(): Bool {
        for (birth in receiptBirths) {
            let probe = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
            if (!probe.conclusive || probe.alive) { return false }
        }
        for (group in receiptGroups) {
            if (unsafe { kill(Int32(-group), 0) } == 0 || unsafe { __error().read() } != 3) { return false }
        }
        true
    }
    @When[os != "macOS"]
    func receiptsGone(): Bool { false }
    func stable(fd: Int64, threadBaseline: (Int64, Int64, Int64)): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        while (MonoTime.now() < deadline && (!sourceTerminal() || ifaceCount(1) > fd || !ifaceThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(ifaceCount(1) <= fd); check(ifaceThreadsWithin(threadBaseline))
        let currentThreads = ifaceThreadSnapshot()
        println("R-THREADS warmCjTasks=${threadBaseline[0]};finalCjTasks=${currentThreads[0]};warmCjBlocking=${threadBaseline[1]};finalCjBlocking=${currentThreads[1]};warmOsThreads=${threadBaseline[2]};finalOsThreads=${currentThreads[2]}")
    }
    func phase(name: String): Bool {
        let receipt = JsonValue.fromStr(ifaceText(home.join("${name}.receipt"))).asObject()
        receipt.get("nonce").getOrThrow().asString().getValue() == binding &&
            receipt.get("phase").getOrThrow().asString().getValue() == "tools"
    }
    func captureReceipt(name: String): Unit {
        let receipt = JsonValue.fromStr(ifaceText(home.join("${name}.receipt"))).asObject()
        let pid = receipt.get("pid").getOrThrow().asInt().getValue()
        if (let Some(birth) <- observeProcessBirthIdentity(pid)) { receiptBirths.add(birth) }
        for (fact in receipt.get("birthFacts").getOrThrow().asArray().getItems()) {
            let fields = managedRecoveryParseFields(fact.asString().getValue()).getOrThrow()
            check(fields.get("parent") == Some(parent))
            if (let Some(birth) <- parseProcessBirthIdentity(fields.get("birth").getOrThrow())) {
                receiptBirths.add(birth)
            } else { check(false) }
            let group = Int64.parse(fields.get("pgid").getOrThrow())
            if (group > 1) { receiptGroups.add(group) }
        }
    }
}

private func withIfaceFixture(action: (IfaceFixture) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let outer = getVariable("METIS_APP_INTERFACE_OUTER")
        let base = outer.getOrDefault({ => "/private/tmp" })
        let canonicalBase = canonicalize(Path(base)).toString()
        if (canonicalBase != "/private/tmp" && !canonicalBase.startsWith("/private/tmp/")) { throw Exception("interface_home_not_owned") }
        if (outer.isSome() && ifaceText(Path(base).join("owned.marker")) != getVariable("METIS_APP_INTERFACE_NONCE").getOrThrow()) {
            throw Exception("interface_outer_binding_missing")
        }
        let home = Directory.createTemp(base)
        let priorEnvironment = ArrayList<(String, Option<String>)>()
        let environmentKeys = ArrayList<String>(["METIS_HOME", "METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT"])
        environmentKeys.add(all: cliProviderApiKeyEnvAliases("openai"))
        environmentKeys.add(all: cliProviderBaseUrlEnvAliases("openai"))
        for (key in environmentKeys) {
            priorEnvironment.add((key, getVariable(key)))
        }
        let oldWorkspace = CliConfig.workspaceDirOverride
        let oldLanguage = CliConfig.language
        let oldInternal = CliConfig.internalSubagent
        let oldCommands = CliConfig.commandDirs
        let oldLog = Config.logFile
        let oldProvider = setProcessLaunchProvider(None)
        setVariable("METIS_HOME", home.toString())
        removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY"); removeVariable("METIS_PROCESS_RECOVERY_PARENT")
        setVariable("METIS_STDIO_BROKER_SCRIPT", canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString())
        CliConfig.workspaceDirOverride = home.join("workspace").toString(); CliConfig.invalidatePathCache()
        CliSettingManager.invalidate(); MetisConfigManager.invalidate(); Config.logFile = home.join("test.log").toString()
        for (name in ["workspace", "agents", "commands"]) { Directory.create(home.join(name)) }
        let fixture = IfaceFixture(home)
        try {
            fixture.compilePeer()
            let _ = setProcessLaunchProvider(Some<ProcessLaunchProvider>(fixture.previous))
            action(fixture)
        } finally {
            File.writeTo(home.join("formal-before-fallback.json"),
                ("{\"formalOk\":${fixture.completed && !fixture.failed},\"recordedBeforeFallback\":true}").toArray())
            if (let Some(provider) <- fixture.provider) {
                provider.releaseAll()
                for (handle in provider.handles) { try { handle.inner.close() } catch (_: Exception) { () } }
            }
            var terminal = fixture.sourceTerminal()
            if (let Some(scope) <- fixture.scope) { terminal = scope.restoreAfterTerminal(MonoTime.now() + Duration.second * 5) && terminal }
            if (let Some(path) <- outer) {
                let result = JsonObject()
                result.put("formalOk", JsonBool(fixture.completed && !fixture.failed))
                result.put("terminalAfterFallback", JsonBool(terminal))
                result.put("formalRecordedBeforeFallback", JsonBool(true))
                result.put("retainedOnFailure", JsonBool(!fixture.completed || fixture.failed || !terminal))
                File.writeTo(Path(path).join("child-resource-result.json"), result.toString().toArray())
            }
            if (terminal) {
                let _ = setProcessLaunchProvider(oldProvider)
                for ((key, value) in priorEnvironment) {
                    match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                }
                CliConfig.workspaceDirOverride = oldWorkspace
                CliConfig.language = oldLanguage; CliConfig.internalSubagent = oldInternal; CliConfig.commandDirs = oldCommands
                CliConfig.invalidatePathCache()
                CliSettingManager.invalidate(); MetisConfigManager.invalidate(); Config.logFile = oldLog
                if (fixture.completed && !fixture.failed) { remove(home, recursive: true) }
                else { eprintln("interface_formal_failed_evidence_retained") }
            } else { eprintln("interface_cleanup_pending_evidence_retained") }
        }
    }
}

@When[os == "macOS"]
@Test
public class MCPConfigManagerResourceTest {
    @TestCase
    public func rMgrP1RealLoadEchoAndCloseThirtyTwo(): Unit {
        withIfaceFixture({ fixture =>
            fixture.add("normal", "normal"); fixture.beginScope()
            for (_ in 0..2) { let warm = MCPConfigManager(); let _ = warm.loadMCPServers(); fixture.check(warm.close()) }
            let fd = ifaceCount(1); let threadBaseline = ifaceThreadSnapshot()
            for (round in 0..32) {
                let manager = MCPConfigManager()
                try {
                    let tools = manager.loadMCPServers()
                    fixture.check(tools.size == 1 && tools[0].name == "owned_echo")
                    let text = if (round == 31) { String(Array<Rune>(32768, repeat: r'中')) + "😀" } else { "中文😀-${round}" }
                    let args = HashMap<String, JsonValue>(); args["text"] = JsonString(text)
                    let response = tools[0].invoke(args)
                    fixture.check(!response.isError && response.content == text + "\n")
                    fixture.check(fixture.phase("normal"))
                    fixture.check(manager.close()); fixture.check(manager.close()); fixture.stable(fd, threadBaseline)
                } finally { fixture.check(manager.close()) }
            }
            println("R-MGR-P1 actualRounds=32;unicodeLong=true;actualReaped=${fixture.sourceTerminal()};formal=${!fixture.failed}")
            fixture.complete()
        })
    }

    @TestCase
    public func rMgrN1ToolsFailureAfterInitializeClosesThirtyTwoEach(): Unit {
        withIfaceFixture({ fixture =>
            fixture.add("negative", "normal"); fixture.beginScope()
            let warm = MCPConfigManager(); let _ = warm.loadMCPServers(); fixture.check(warm.close())
            let fd = ifaceCount(1); let threadBaseline = ifaceThreadSnapshot()
            for ((mode, expected) in [("invalid_utf8", "invalid_response_encoding"), ("malformed_json", "malformed_json"), ("early_eof", "mcp_early_eof")]) {
                fixture.add("negative", mode)
                for (_ in 0..32) {
                    let manager = MCPConfigManager()
                    var original = ""
                    try { let _ = manager.loadMCPServers() } catch (error: Exception) { original = error.message }
                    fixture.check(original == expected && !original.contains("syntheticsecret"))
                    fixture.check(fixture.phase("negative")); fixture.check(manager.close()); fixture.stable(fd, threadBaseline)
                }
                println("R-MGR-N1 mode=${mode};rounds=32;expectedCategory=${expected};actualReaped=${fixture.sourceTerminal()};formal=${!fixture.failed}")
            }
            fixture.complete()
        })
    }

    @TestCase
    public func rMgrB1PartialLoadClosesBothActualClients(): Unit {
        withIfaceFixture({ fixture =>
            fixture.add("first", "normal"); fixture.beginScope()
            let warm = MCPConfigManager(); let _ = warm.loadMCPServers(); fixture.check(warm.close())
            for (name in ["second", "third"]) { fixture.add(name, "normal") }
            let before = fixture.provider.getOrThrow().calls
            fixture.provider.getOrThrow().failAt = before + 2
            let fd = ifaceCount(1); let threadBaseline = ifaceThreadSnapshot()
            let manager = MCPConfigManager()
            var original = ""
            try { let _ = manager.loadMCPServers() } catch (error: Exception) { original = error.message }
            fixture.check(original == "invalid_response_encoding")
            let proxy = fixture.provider.getOrThrow()
            fixture.check(proxy.calls - before == 2 && proxy.handles.size == before + 2)
            for (handle in proxy.handles) { fixture.check(handle.closes == 1 && handle.isClosed()) }
            fixture.check(manager.close()); fixture.stable(fd, threadBaseline)
            var actualClosed: Int64 = 0
            for (index in before..proxy.handles.size) { if (proxy.handles[index].isClosed()) { actualClosed += 1 } }
            println("R-MGR-B1 configured=3;actualLaunches=${proxy.calls - before};actualClosed=${actualClosed};sourceTerminal=${fixture.sourceTerminal()};formal=${!fixture.failed}")
            fixture.complete()
        })
    }

    @TestCase
    public func rMgrN2PendingConsumerIsRetainedUntilRelease(): Unit {
        withIfaceFixture({ fixture =>
            fixture.add("pending", "normal"); fixture.beginScope()
            let warm = MCPConfigManager(); let _ = warm.loadMCPServers(); fixture.check(warm.close())
            let fd = ifaceCount(1); let threadBaseline = ifaceThreadSnapshot()
            fixture.add("pending", "invalid_utf8")
            let proxy = fixture.provider.getOrThrow(); proxy.holdClose = true
            let manager = MCPConfigManager()
            var original = ""
            try { let _ = manager.loadMCPServers() } catch (error: Exception) { original = error.message }
            fixture.check(original == "invalid_response_encoding" && fixture.phase("pending"))
            let handle = proxy.handles[proxy.handles.size - 1]
            fixture.check(handle.closes == 1 && handle.isAlive())
            let pending = manager.close()
            fixture.check(!pending && handle.closes == 2)
            proxy.releaseAll()
            let closed = manager.close()
            fixture.check(closed && handle.closes == 3)
            let emptyClosed = manager.close()
            fixture.check(emptyClosed && handle.closes == 3)
            fixture.stable(fd, threadBaseline)
            println("R-MGR-N2 interfaceFaultInjection=true;originalCategoryPreserved=${original == "invalid_response_encoding"};retryClosed=${closed};emptyClosed=${emptyClosed};actualReaped=${fixture.sourceTerminal()};formal=${!fixture.failed}")
            fixture.complete()
        })
    }
}
