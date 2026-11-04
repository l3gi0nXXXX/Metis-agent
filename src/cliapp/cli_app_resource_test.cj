package metis.cliapp

import std.runtime.{getThreadCount, getBlockingThreadCount, getMaxHeapSize, getUsedHeapSize, getAllocatedHeapSize, getGCCount}

import metis.core.config.cliModelProviderCatalogDescriptors

import std.convert.Parsable
import metis.core.mcp.MCPConfigManager
import metis.process.{ManagedOwnedChild, managedRecoveryLaunchOwned, managedRecoveryStopOwnedChildren}
import std.collection.Map
import magic.mcp.StdioMCPClient
import magic.config.Config
import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock,
    cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.process.{ManagedMagicRecoveryLaunchScope, managedRecoveryInitialize, managedRecoveryContext,
    managedRecoveryProbeRecords, managedRecoveryParseFields, currentProcessInstanceIdentity,
    ProcessBirthIdentity, parseProcessBirthIdentity, probeProcessBirthIdentity, observeProcessBirthIdentity,
    parseProcessInstanceIdentity, probeProcessInstance}
import std.collection.{ArrayList, HashMap, HashSet}
import std.env.{getVariable, getVariables, getProcessId, getCommand, setVariable, removeVariable}
import std.fs.{Directory, File, FileInfo, Path, OpenMode, canonicalize, exists, remove, rename}
import std.io.{InputStream, OutputStream}
import std.net.{TcpServerSocket, IPSocketAddress, SocketTimeoutException}
import std.sync.{AtomicBool, AtomicInt64}
import magic.utils.http.{HttpProcessLaunchProvider, HttpProcessLaunchSpec, setHttpProcessLaunchProvider}
import metis.process.launchManagedRawChild
import std.process.{ProcessRedirect, ProcessException}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func getpgid(pid: Int32): Int32
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
    var auxiliaryConsumersSettled = true
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
        if (!compilerWorkersJoined || !compilerTerminal || !auxiliaryConsumersSettled) { return false }
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

private func appPreviousProviderRestored(fixture: IfaceFixture): Bool {
    let current = setProcessLaunchProvider(None)
    let _ = setProcessLaunchProvider(current)
    var exact = false
    try { let _ = current.getOrThrow().launch("owned-unused", [], [], false) }
    catch (error: Exception) { exact = error.message == "interface_previous_provider" }
    exact && fixture.previous.calls == 1
}

private func appRecordStandaloneHeap(fixture: IfaceFixture): Unit {
    let absent = getVariable("cjHeapSize").isNone()
    let maxHeap = getMaxHeapSize()
    let proof = JsonObject()
    proof.put("envAbsent", JsonBool(absent)); proof.put("maxHeapBytes", JsonInt(maxHeap))
    let bytes = proof.toString().toArray()
    File.writeTo(fixture.home.join("heap-baseline.json"), bytes)
    File.writeTo(Path(getVariable("METIS_APP_INTERFACE_OUTER").getOrThrow()).join("child-heap-baseline.json"), bytes)
    println("R-APP-HEAP envAbsent=${absent};maxHeapBytes=${maxHeap}")
    fixture.check(absent)
}

private func appResourceChild(kind: String, mode: String): Unit {
    withIfaceFixture({ fixture =>
        appRecordStandaloneHeap(fixture)
        CliConfig.internalSubagent = "explorer"
        CliConfig.language = "general"
        CliConfig.commandDirs = ArrayList<Path>([fixture.home.join("commands")])
        for (key in cliProviderApiKeyEnvAliases("openai")) { setVariable(key, "fixture-only-key") }
        for (key in cliProviderBaseUrlEnvAliases("openai")) { setVariable(key, fixture.modelBaseUrl) }
        if (kind != "pending") { fixture.add("app", if (kind == "tools_failure") { "invalid_utf8" } else { "normal" }) }
        else { fixture.configure() }
        if (mode == "bound") { fixture.check(managedRecoveryInitialize(fixture.journal, fixture.parent, fixture.binding)) }
        else { let _ = setProcessLaunchProvider(None) }
        // Compiler reader workers have already joined. The same two-second
        // resource observation applies to actual ctor/close and ctor failure.
        let warmFd = ifaceCount(1); let warmThreadBaseline = ifaceThreadSnapshot()
        // Actual construction only; no prompt/model request or interactive loop.
        var app = None<CliApp>
        if (kind == "late_failure") {
            let broken = fixture.home.join("agents").join("broken")
            Directory.create(broken); Directory.create(broken.join("AGENT.md"))
            var original = ""
            try { app = Some(CliApp()) } catch (error: Exception) { original = error.message }
            fixture.captureReceipt("app")
            fixture.check(app.isNone() && !original.isEmpty() && original != "owned_process_cleanup_pending")
            fixture.check(fixture.phase("app")); fixture.check(fixture.receiptBirths.size >= 2)
            fixture.check(fixture.sourceTerminal()); fixture.check(appPreviousProviderRestored(fixture))
            fixture.stable(warmFd, warmThreadBaseline)
            println("R-APP-N2 actualClientBeforeFailure=${fixture.phase("app")};actualCtorFailed=${app.isNone()};sourceTerminal=${fixture.sourceTerminal()};warmFd=${warmFd};finalFd=${ifaceCount(1)};warmOsThreads=${warmThreadBaseline[2]};finalOsThreads=${ifaceCount(6)};formal=${!fixture.failed}")
            fixture.complete()
            return
        }
        let instance = CliApp()
        app = Some(instance)
        try {
            if (kind == "pending") {
                fixture.installProxy()
                let proxy = fixture.provider.getOrThrow(); proxy.holdClose = true
                fixture.check(instance.mcpManager.addStdioServer("app", fixture.binary.toString(),
                    ["normal", fixture.home.join("app.receipt").toString(), fixture.binding], []))
                let loaded = instance.mcpManager.loadMCPServers()
                fixture.check(loaded.size == 1 && fixture.phase("app")); fixture.captureReceipt("app")
                fixture.restoreManagedProvider()
                let firstClose = instance.close()
                fixture.check(!firstClose)
                fixture.check(fixture.previous.calls == 0)
                let previousBeforeAdmission = fixture.previous.calls
                var fenced = false
                var fenceIsProcessException = false
                var fenceCategory = "unrecognized"
                var unexpectedClient = None<StdioMCPClient>
                try { unexpectedClient = Some(StdioMCPClient("/bin/true", [])) }
                catch (error: Exception) {
                    fenceIsProcessException = error is ProcessException
                    if (error.message == "process_launch_provider_failed") { fenceCategory = "process_launch_provider_failed" }
                    else if (error.message == "process_recovery_generation_closing") { fenceCategory = "process_recovery_generation_closing" }
                    fenced = error is ProcessException && error.message == "process_launch_provider_failed"
                } finally { if (let Some(client) <- unexpectedClient) { client.close() } }
                let previousAfterAdmission = fixture.previous.calls
                let launchesAfterAdmission = proxy.calls
                fixture.check(fenced && fixture.previous.calls == 0)
                proxy.releaseAll()
                let retryClose = instance.close()
                fixture.check(retryClose); fixture.check(fixture.sourceTerminal())
                fixture.check(appPreviousProviderRestored(fixture))
                fixture.stable(warmFd, warmThreadBaseline)
                println("R-APP-N3 interfaceFaultInjection=true;firstClose=${firstClose};retryClose=${retryClose};fenced=${fenced};fenceIsProcessException=${fenceIsProcessException};fenceCategory=${fenceCategory};previousBeforeAdmission=${previousBeforeAdmission};previousAfterAdmission=${previousAfterAdmission};actualLaunches=${launchesAfterAdmission};sourceTerminal=${fixture.sourceTerminal()};warmFd=${warmFd};finalFd=${ifaceCount(1)};warmOsThreads=${warmThreadBaseline[2]};finalOsThreads=${ifaceCount(6)};formal=${!fixture.failed}")
            } else {
                fixture.captureReceipt("app"); fixture.check(fixture.phase("app"))
                if (kind == "normal") {
                    fixture.check(instance.agent.toolManager.findTool("owned_echo").isSome())
                } else {
                    fixture.check(instance.agent.toolManager.findTool("owned_echo").isNone())
                }
                fixture.check(instance.close()); fixture.check(instance.close())
                fixture.check(fixture.sourceTerminal())
                if (mode == "bound") { fixture.check(appPreviousProviderRestored(fixture)) }
                else {
                    let current = setProcessLaunchProvider(None)
                    fixture.check(current.isNone())
                }
                fixture.stable(warmFd, warmThreadBaseline)
                println("R-APP mode=${mode};kind=${kind};sourceTerminal=${fixture.sourceTerminal()};warmFd=${warmFd};finalFd=${ifaceCount(1)};warmOsThreads=${warmThreadBaseline[2]};finalOsThreads=${ifaceCount(6)};formal=${!fixture.failed}")
            }
            fixture.complete()
        } finally {
            if (let Some(proxy) <- fixture.provider) { proxy.releaseAll() }
            fixture.check(instance.close())
        }
    })
}


@When[os == "macOS"]
private class NoticeHttpReceiptProvider <: HttpProcessLaunchProvider {
    let starts = AtomicInt64(0)
    let reaped = AtomicInt64(0)
    public func prepare(command: String, args: Array<String>): HttpProcessLaunchSpec {
        HttpProcessLaunchSpec(command, args, environment: HashMap<String, String>(),
            onSpawned: { _pid => starts.fetchAdd(1); true },
            requestStop: { pid, _force => unsafe { kill(Int32(pid), 15) }; () },
            onTerminal: { _pid, spawned, terminal => if (spawned && terminal) { reaped.fetchAdd(1) } })
    }
}

@When[os == "macOS"]
private class NoticeProbePeer {
    let listener = TcpServerSocket(bindAt: 0u16)
    let requests = AtomicInt64(0)
    let release = AtomicBool(false)
    let stopped = AtomicBool(false)
    let settled = AtomicBool(false)
    let started = AtomicBool(false)
    let hold: Bool
    init(hold: Bool) { this.hold = hold; listener.bind() }
    prop port: Int64 { get() { Int64((listener.localAddress as IPSocketAddress)?.port ?? 0u16) } }
    func run(): Unit {
        started.store(true)
        try {
            while (!stopped.load()) {
                try (peer = listener.accept(timeout: Some(Duration.millisecond * 25))) {
                    peer.readTimeout = Some(Duration.second)
                    let buffer = Array<Byte>(8192, repeat: 0)
                    let headers = ArrayList<Byte>(); var complete = false
                    while (!complete && headers.size < 65536) {
                        let count = peer.read(buffer)
                        if (count == 0) { throw Exception("notice_fixture_request_eof") }
                        for (index in 0..count) {
                            headers.add(buffer[index]); let size = headers.size
                            if (size >= 4 && headers[size - 4] == 13 && headers[size - 3] == 10 &&
                                headers[size - 2] == 13 && headers[size - 1] == 10) { complete = true; break }
                        }
                    }
                    if (!complete) { throw Exception("notice_fixture_request_oversize") }
                    let ordinal = requests.fetchAdd(1)
                    if (ordinal == 0) {
                        let outer = Path(getVariable("METIS_APP_INTERFACE_OUTER").getOrThrow())
                        let nonce = getVariable("METIS_APP_INTERFACE_NONCE").getOrThrow()
                        let identity = currentProcessInstanceIdentity().getOrThrow()
                        let pending = outer.join("notice-first-request.pending")
                        File.writeTo(pending, "managed-recovery-v1\nnonce:${nonce}\npid:${getProcessId()}\nidentity:${identity.serialize()}\n".toArray())
                        // Closed contents are published atomically after the driver
                        // has already committed helper/owner native births.
                        rename(pending, to: outer.join("notice-first-request"), overwrite: false)
                    }
                    while (hold && !release.load() && !stopped.load()) { sleep(Duration.millisecond * 5) }
                    if (!stopped.load()) {
                        peer.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toArray())
                    }
                } catch (_: SocketTimeoutException) { () }
                catch (error: Exception) { if (!stopped.load()) { throw error } }
            }
        } finally { settled.store(true) }
    }
    func stop(): Unit {
        stopped.store(true); release.store(true)
        try { listener.close() } catch (_: Exception) { () }
    }
}

@When[os == "macOS"]
private func appWatcherResourceChild(kind: String, mode: String): Unit {
    withIfaceFixture({ fixture =>
        appRecordStandaloneHeap(fixture)
        CliConfig.internalSubagent = "explorer"; CliConfig.language = "general"
        CliConfig.commandDirs = ArrayList<Path>([fixture.home.join("commands")])
        fixture.configure()
        if (mode == "bound") { fixture.check(managedRecoveryInitialize(fixture.journal, fixture.parent, fixture.binding)) }
        else { let _ = setProcessLaunchProvider(None) }
        let coldFd = ifaceCount(1); let coldThreads = ifaceThreadSnapshot()
        let peer = NoticeProbePeer(kind == "watcher_pending")
        let config = JsonValue.fromStr(ifaceText(fixture.home.join("metis.json"))).asObject()
        let gateway = JsonObject(); gateway.put("enabled", JsonBool(true)); gateway.put("port", JsonInt(peer.port))
        let auth = JsonObject(); auth.put("mode", JsonString("token")); auth.put("token", JsonString("fixture-only-token"))
        gateway.put("auth", auth); gateway.put("servicePlugins", JsonArray()); config.put("gateway", gateway)
        File.writeTo(fixture.home.join("metis.json"), config.toString().toArray())
        CliSettingManager.invalidate(); MetisConfigManager.invalidate()
        Directory.create(fixture.home.join("requests"))
        let oldRequests = Config.modelRequestDir; Config.modelRequestDir = fixture.home.join("requests").toString()
        let http = NoticeHttpReceiptProvider()
        let priorHttp = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(http))
        fixture.auxiliaryConsumersSettled = false
        let worker = spawn { peer.run() }
        var watcher = None<CliSubagentNoticeWatcher>; var app = None<CliApp>
        var workerJoined = false; var ownerJoined = false; var formalActive = false
        try {
            let readyDeadline = MonoTime.now() + Duration.second * 2
            while (MonoTime.now() < readyDeadline && (!peer.started.load() ||
                getThreadCount() != coldThreads[0] + 1 || getBlockingThreadCount() != coldThreads[1] + 1)) {
                sleep(Duration.millisecond * 1)
            }
            fixture.check(peer.started.load() && getThreadCount() == coldThreads[0] + 1 &&
                getBlockingThreadCount() == coldThreads[1] + 1)
            let activeFd = ifaceCount(1); let activeThreads = ifaceThreadSnapshot()
            @Expect(Config.enableHttpRetry, true)
            fixture.check(!Config.saveModelRequest)
            if (kind == "watcher_pending") {
                let instance = CliApp(); app = Some(instance)
                // Parent's owned pipe feeder waits for the real request marker.
                instance.startInteractive()
                let afterInteractiveStarts = http.starts.load(); let afterInteractiveReaped = http.reaped.load()
                fixture.check(afterInteractiveStarts == 1 && afterInteractiveReaped == 0 && !peer.release.load())
                let firstClose = instance.close()
                var fenced = false
                try {
                    let client = StdioMCPClient("/bin/true", [])
                    client.close()
                } catch (error: Exception) {
                    fenced = error is ProcessException && error.message == "process_launch_provider_failed"
                }
                fixture.check(!firstClose); fixture.check(fenced && fixture.previous.calls == 0)
                peer.release.store(true)
                let retryClose = instance.close(); ownerJoined = retryClose
                fixture.check(retryClose); fixture.check(appPreviousProviderRestored(fixture))
                let startsBefore = http.starts.load(); let requestsBefore = peer.requests.load()
                let previousCalls = fixture.previous.calls
                let issued = fixture.journal.join(".issued")
                let issuedBefore = if (exists(issued)) { Some(ifaceText(issued)) } else { None<String> }
                var closingRejected = false
                try { instance.startInteractive() }
                catch (error: Exception) { closingRejected = error.message == "cli_notice_watcher_closing" }
                let issuedAfter = if (exists(issued)) { Some(ifaceText(issued)) } else { None<String> }
                fixture.check(closingRejected)
                fixture.check(http.starts.load() == startsBefore && peer.requests.load() == requestsBefore &&
                    fixture.previous.calls == previousCalls && issuedBefore == issuedAfter)
                println("R-WATCHER-CLOSING fixedClosing=${closingRejected};requestsUnchanged=${peer.requests.load() == requestsBefore};startsUnchanged=${http.starts.load() == startsBefore};issuedUnchanged=${issuedBefore == issuedAfter}")

                println("R-WATCHER-PENDING afterInteractiveStarts=${afterInteractiveStarts};afterInteractiveReaped=${afterInteractiveReaped};firstClose=${firstClose};fenced=${fenced};retryClose=${retryClose};actualStarts=${http.starts.load()};actualReaped=${http.reaped.load()}")
            } else {
                let notice = CliSubagentNoticeWatcher("main"); watcher = Some(notice)
                notice.start()
                let deadline = MonoTime.now() + Duration.second * 2
                while (http.reaped.load() < 1 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                fixture.check(http.reaped.load() == 1)
                let joined = notice.stop()
                fixture.check(joined)
                let settledDeadline = MonoTime.now() + Duration.second * 2
                while (MonoTime.now() < settledDeadline && (ifaceCount(1) != activeFd || !ifaceThreadsWithin(activeThreads))) {
                    sleep(Duration.millisecond * 10)
                }
                ownerJoined = joined && ifaceCount(1) == activeFd && ifaceThreadsWithin(activeThreads) && http.starts.load() == http.reaped.load()
                fixture.check(ownerJoined); fixture.check(peer.requests.load() == 1)
                fixture.check(notice.stop())
            }
            let settledDeadline = MonoTime.now() + Duration.second * 2
            while (MonoTime.now() < settledDeadline && (ifaceCount(1) != activeFd || !ifaceThreadsWithin(activeThreads))) {
                sleep(Duration.millisecond * 10)
            }
            let inventory = if (exists(fixture.journal)) {
                let value = managedRecoveryProbeRecords(fixture.journal, fixture.parent, fixture.binding, MonoTime.now() + Duration.second * 2)
                value.ok && value.terminal
            } else { mode == "absent" }
            formalActive = ownerJoined && http.starts.load() == 1 && http.reaped.load() == 1 && inventory &&
                ifaceCount(1) == activeFd && ifaceThreadsWithin(activeThreads) &&
                Directory.readFrom(fixture.home.join("requests")).isEmpty()
            fixture.check(formalActive)
            println("R-WATCHER-ACTIVE kind=${kind};ownerJoined=${ownerJoined};actualStarts=${http.starts.load()};actualReaped=${http.reaped.load()};activeFdBaseline=${activeFd};activeFdActual=${ifaceCount(1)};activeCjBaseline=${activeThreads[0]};activeCjActual=${getThreadCount()};inventory=${inventory};formal=${formalActive && !fixture.failed}")
        } finally {
            File.writeTo(fixture.home.join("watcher-formal-before-fallback"),
                "formal:${!fixture.failed && formalActive}\nownerJoined:${ownerJoined}\nstarts:${http.starts.load()}\nreaped:${http.reaped.load()}\n".toArray())
            peer.stop()
            try { worker.get(Duration.second * 3); workerJoined = peer.settled.load() }
            catch (_: Exception) { workerJoined = false }
            if (let Some(instance) <- app) { ownerJoined = instance.close() }
            if (let Some(notice) <- watcher) { ownerJoined = notice.stop() && ownerJoined }
            let deadline = MonoTime.now() + Duration.second * 2
            while (MonoTime.now() < deadline && (http.starts.load() != http.reaped.load() || !ifaceThreadsWithin(coldThreads))) {
                sleep(Duration.millisecond * 10)
            }
            ownerJoined = ownerJoined && http.starts.load() == http.reaped.load() && ifaceThreadsWithin(coldThreads)
            fixture.auxiliaryConsumersSettled = ownerJoined && workerJoined
            if (fixture.auxiliaryConsumersSettled) {
                let _ = setHttpProcessLaunchProvider(priorHttp); Config.modelRequestDir = oldRequests
            }
            fixture.check(fixture.auxiliaryConsumersSettled)
        }
        fixture.stable(coldFd, coldThreads); fixture.complete()
    })
}


@When[os == "macOS"]
private func appWatcherFeederSource(home: Path, directory: Path, parent: String, binding: String,
    nonce: String, owned: ManagedOwnedChild): Bool {
    let markerText = ifaceText(home.join("notice-first-request"))
    let marker = managedRecoveryParseFields(markerText).getOrThrow()
    if (marker.get("nonce") != Some(nonce)) { return false }
    let identity = parseProcessInstanceIdentity(marker.get("identity").getOrThrow()).getOrThrow()
    if (marker.get("pid") != Some(identity.pid.toString())) { return false }
    let first = probeProcessInstance(identity, MonoTime.now() + Duration.second)
    if (!first.conclusive || !first.alive || !owned.isAlive()) { return false }
    let group = Int64(unsafe { getpgid(Int32(identity.pid)) })
    if (group <= 1) { return false }
    let headerText = ifaceText(directory.join("inventory"))
    let header = managedRecoveryParseFields(headerText).getOrThrow()
    if (header.get("parent") != Some(parent) || header.get("binding") != Some(binding)) { return false }
    File.writeTo(home.join("notice-driver-header.proof"), headerText.toArray())
    File.writeTo(home.join("notice-driver-marker.proof"), markerText.toArray())
    for (entry in Directory.readFrom(directory)) {
        if (!entry.name.endsWith("-o-1.spawned") || !entry.isRegular() || entry.isSymbolicLink()) { continue }
        let ownerText = ifaceText(entry.path)
        let owner = managedRecoveryParseFields(ownerText).getOrThrow()
        if (owner.get("parent") != Some(parent) || owner.get("pid") != Some(group.toString()) ||
            owner.get("pgid") != Some(group.toString())) { continue }
        let key = owner.get("key").getOrThrow()
        if (entry.name != key + ".spawned") { return false }
        let rootKey = key.removeSuffix("-o-1")
        let helperText = ifaceText(directory.join(rootKey + ".spawned"))
        let helper = managedRecoveryParseFields(helperText).getOrThrow()
        if (helper.size != 6 || helper.get("parent") != Some(parent) || helper.get("key") != Some(rootKey) ||
            helper.get("phase") != Some("spawned") || helper.get("pid") != Some(owned.pid.toString()) ||
            helper.get("pgid") != Some("0") || helper.get("birth") != Some("")) { continue }
        let helperBirthText = ifaceText(directory.join(rootKey + ".birth"))
        let helperBirth = managedRecoveryParseFields(helperBirthText).getOrThrow()
        if (helperBirth.size != 6 || helperBirth.get("parent") != Some(parent) || helperBirth.get("key") != Some(rootKey) ||
            helperBirth.get("phase") != Some("birth") || helperBirth.get("pid") != Some(owned.pid.toString()) ||
            helperBirth.get("pgid") != Some("0")) { return false }
        let helperRecorded = parseProcessBirthIdentity(helperBirth.get("birth").getOrThrow()).getOrThrow()
        let helperObserved = observeProcessBirthIdentity(owned.pid)
        if (helperRecorded.pid != owned.pid || helperBirth.get("birth") != Some(helperRecorded.serialize()) ||
            helperObserved.isNone() || helperObserved.getOrThrow().serialize() != helperRecorded.serialize()) { return false }
        let birthText = ifaceText(directory.join(key + ".birth"))
        let birth = managedRecoveryParseFields(birthText).getOrThrow()
        if (birth.get("parent") != Some(parent) || birth.get("key") != Some(key)) { return false }
        let recorded = parseProcessBirthIdentity(birth.get("birth").getOrThrow()).getOrThrow()
        let observed = observeProcessBirthIdentity(group)
        if (observed.isNone() || observed.getOrThrow().serialize() != recorded.serialize()) { return false }
        File.writeTo(home.join("notice-driver-owner.proof"), ownerText.toArray())
        File.writeTo(home.join("notice-driver-owner-birth.proof"), birthText.toArray())
        File.writeTo(home.join("notice-driver-helper.proof"), helperText.toArray())
        File.writeTo(home.join("notice-driver-helper-birth.proof"), helperBirthText.toArray())
        let second = probeProcessInstance(identity, MonoTime.now() + Duration.second)
        let helperSecond = observeProcessBirthIdentity(owned.pid)
        return second.conclusive && second.alive && owned.isAlive() && helperSecond.isSome() &&
            helperSecond.getOrThrow().serialize() == helperRecorded.serialize() &&
            Int64(unsafe { getpgid(Int32(identity.pid)) }) == group
    }
    false
}

@When[os != "macOS"]
private func appWatcherFeederSource(_home: Path, _directory: Path, _parent: String, _binding: String,
    _nonce: String, _owned: ManagedOwnedChild): Bool { false }

private func runAppResourceChild(test: String, kind: String, mode: String, timeout!: Duration = Duration.second * 90): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Directory.createTemp("/private/tmp")
        let priorEnvironment = ArrayList<(String, Option<String>)>()
        for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT"]) {
            priorEnvironment.add((key, getVariable(key)))
        }
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(home.join("owned.marker"), nonce.toArray())
        if (kind.startsWith("embedded_")) { println("R-WRAP fixture=${home.fileName};nonce=${nonce};kind=${kind}") }
        let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        let directory = home.join("driver-inventory")
        let binding = "app-driver-" + nonce
        let reportDiagnostic = kind.startsWith("embedded_") && getVariable("METIS_EMBED_REPORT_DIAGNOSTIC") == Some("1")
        let childParallel = if (reportDiagnostic) { "--parallel=false" } else { "--parallel=1" }
        let environment = HashMap(getVariables())
        environment.remove("cjHeapSize")
        if (kind.startsWith("embedded_")) { environment.remove("MRT_REPORT") }
        if (reportDiagnostic) { environment["MRT_REPORT"] = home.join("app.report").toString() }
        let providerAliases = ArrayList<String>()
        for (descriptor in cliModelProviderCatalogDescriptors()) {
            for (alias in descriptor.apiKeyEnvAliases) { providerAliases.add(alias.toAsciiUpper()) }
        }
        for (key in environment.keys().toArray()) {
            let upper = key.toAsciiUpper()
            if (upper.contains("PROXY") || upper.endsWith("_TOKEN") || upper.endsWith("_API_KEY") ||
                upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") ||
                upper.endsWith("_ACCESS_KEY_ID") || providerAliases.contains(upper)) { environment.remove(key) }
        }
        environment["METIS_HOME"] = home.toString()
        if (kind.startsWith("watcher_")) {
            environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString()
        }
        environment["METIS_LOG_FILE"] = home.join("child.log").toString()
        environment["METIS_CJPM_ROOT"] = canonicalize(Path(".")).toString()
        environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = ""; environment["METIS_PROCESS_RECOVERY_PARENT"] = ""
        environment["METIS_APP_INTERFACE_OUTER"] = home.toString()
        environment["METIS_APP_INTERFACE_NONCE"] = nonce
        environment["METIS_APP_INTERFACE_CHILD"] = kind
        environment["METIS_APP_INTERFACE_MODE"] = mode
        var child = None<ManagedOwnedChild>
        var feeder = None<Future<Bool>>
        let feederSettled = AtomicBool(false); let stopFeeder = AtomicBool(false)
        var feederJoined = kind != "watcher_pending"
        var formal = false
        var reaped = false
        var terminal = false
        try {
            setVariable("METIS_STDIO_BROKER_SCRIPT", canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString())
            if (!managedRecoveryInitialize(directory, parent, binding)) { throw Exception("app_interface_driver_inventory_failed") }
            try (input = File("/dev/null", OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
                child = Some(managedRecoveryLaunchOwned(getCommand(), ["--filter=CliAppResourceTest.${test}", childParallel, "--no-progress", "--no-color", "--no-capture-output"],
                    environment: Some<Map<String, String>>(environment),
                    stdIn: if (kind == "watcher_pending") { ProcessRedirect.Pipe } else { ProcessRedirect.FromFile(input) },
                    stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
            }
            if (kind == "watcher_pending") {
                let owned = child.getOrThrow()
                feeder = Some(spawn {
                    try {
                        let deadline = MonoTime.now() + timeout
                        let ready = home.join("notice-first-request")
                        while (!stopFeeder.load() && !exists(ready) && owned.isAlive() && MonoTime.now() < deadline) {
                            sleep(Duration.millisecond * 5)
                        }
                        if (stopFeeder.load() || !exists(ready) || !owned.isAlive()) { return false }
                        // owned.pid is the Node helper; the actual test body can
                        // be a framework worker in its recorded owner's group.
                        if (!appWatcherFeederSource(home, directory, parent, binding, nonce, owned)) { return false }
                        if (!owned.isAlive()) { return false }
                        owned.stdInPipe.write([4u8, 4u8])
                        return owned.isAlive()
                    } finally { feederSettled.store(true) }
                })
            }
            let code = child.getOrThrow().wait(timeout: Some(timeout))
            let heap = JsonValue.fromStr(ifaceText(home.join("child-heap-baseline.json"))).asObject()
            println("R-APP-HEAP-PARENT envAbsent=${heap.get("envAbsent").getOrThrow().asBool().getValue()};childMaxHeapBytes=${heap.get("maxHeapBytes").getOrThrow().asInt().getValue()};parentMaxHeapBytes=${getMaxHeapSize()}")
            child.getOrThrow().closeStreams(); reaped = true
            if (let Some(inputWorker) <- feeder) { feederJoined = inputWorker.get(Duration.second * 3) && feederSettled.load() }
            let text = ifaceText(home.join("stdout")) + ifaceText(home.join("stderr"))
            let proof = JsonValue.fromStr(ifaceText(home.join("child-resource-result.json"))).asObject()
            let recorded = proof.get("formalRecordedBeforeFallback").getOrThrow().asBool().getValue()
            let business = proof.get("formalOk").getOrThrow().asBool().getValue()
            let resources = proof.get("terminalAfterFallback").getOrThrow().asBool().getValue()
            let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 3)
            terminal = source.ok && source.terminal
            formal = code == 0 && recorded && business && resources && terminal && feederJoined && !text.contains("syntheticsecret") && !text.contains("\"ok\"")
            if (kind == "tools_failure") { formal = formal && text.contains("continuing without MCP tools") }
            @Expect(formal, true)
            println("R-APP parentKind=${kind};mode=${mode};code=${code};formalBeforeFallback=${formal};actualChildReaped=${reaped};driverTerminal=${terminal}")
        } finally {
            File.writeTo(home.join("parent-formal-before-fallback"), "formal:${formal}\nreaped:${reaped}\nterminal:${terminal}\n".toArray())
            if (let Some(process) <- child) {
                if (process.isAlive()) { try { process.terminate(force: true) } catch (_: Exception) { () } }
                try { let _ = process.wait(timeout: Some(Duration.second * 3)); reaped = true } catch (_: Exception) { () }
                process.closeStreams()
            }
            stopFeeder.store(true)
            if (let Some(inputWorker) <- feeder) {
                try { feederJoined = inputWorker.get(Duration.second * 3) && feederSettled.load() }
                catch (_: Exception) { feederJoined = false }
            }
            let stopped = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5)
            let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 3)
            terminal = stopped && source.ok && source.terminal && reaped && feederJoined
            if (terminal) {
                for ((key, value) in priorEnvironment) {
                    match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                }
                if (formal && !reportDiagnostic) { remove(home, recursive: true) }
                else if (reportDiagnostic) { eprintln("app_report_diagnostic_evidence_retained") }
                else { eprintln("app_interface_failed_evidence_retained") }
            } else { eprintln("app_interface_cleanup_pending_evidence_retained") }
        }
    }
}

@When[os == "macOS"]
@Test
public class CliAppResourceTest {

    @TestCase
    public func rCliWatcherCancelledRetryJoinsWithAbsentAndBoundContext(): Unit {
        if (getVariable("METIS_APP_INTERFACE_CHILD").isSome()) {
            appWatcherResourceChild("watcher_direct", getVariable("METIS_APP_INTERFACE_MODE").getOrThrow()); return
        }
        for (mode in ["absent", "bound"]) {
            runAppResourceChild("rCliWatcherCancelledRetryJoinsWithAbsentAndBoundContext", "watcher_direct", mode, timeout: Duration.second * 60)
        }
    }
    @TestCase
    public func rAppWatcherPendingCloseRetainsProviderUntilRetry(): Unit {
        if (getVariable("METIS_APP_INTERFACE_CHILD").isSome()) { appWatcherResourceChild("watcher_pending", "bound"); return }
        runAppResourceChild("rAppWatcherPendingCloseRetainsProviderUntilRetry", "watcher_pending", "bound", timeout: Duration.second * 60)
    }

    @TestCase
    public func rAppP1ActualNormalCloseWithAbsentAndBoundContext(): Unit {
        if (getVariable("METIS_APP_INTERFACE_CHILD").isSome()) { appResourceChild("normal", getVariable("METIS_APP_INTERFACE_MODE").getOrThrow()); return }
        for (mode in ["absent", "bound"]) { runAppResourceChild("rAppP1ActualNormalCloseWithAbsentAndBoundContext", "normal", mode) }
    }
    @TestCase
    public func rAppN1ToolsFailureIsolatedDuringActualConstruction(): Unit {
        if (getVariable("METIS_APP_INTERFACE_CHILD").isSome()) { appResourceChild("tools_failure", "bound"); return }
        runAppResourceChild("rAppN1ToolsFailureIsolatedDuringActualConstruction", "tools_failure", "bound")
    }
    @TestCase
    public func rAppN2LateConstructorFailureClosesActualClient(): Unit {
        if (getVariable("METIS_APP_INTERFACE_CHILD").isSome()) { appResourceChild("late_failure", "bound"); return }
        runAppResourceChild("rAppN2LateConstructorFailureClosesActualClient", "late_failure", "bound")
    }
    @TestCase
    public func rAppN3PendingConsumerRetainsProviderUntilRetry(): Unit {
        if (getVariable("METIS_APP_INTERFACE_CHILD").isSome()) { appResourceChild("pending", "bound"); return }
        runAppResourceChild("rAppN3PendingConsumerRetainsProviderUntilRetry", "pending", "bound")
    }

    @TestCase
    public func rWrapEmbeddedEntryClosesActualClientOnReturnAndThrow(): Unit {
        if (let Some(kind) <- getVariable("METIS_APP_INTERFACE_CHILD")) {
            appEmbeddedResourceChild(kind, getVariable("METIS_APP_INTERFACE_MODE").getOrThrow()); return
        }
        for (kind in ["embedded_exit", "embedded_memory"]) {
            for (mode in ["absent", "bound"]) {
                runAppResourceChild("rWrapEmbeddedEntryClosesActualClientOnReturnAndThrow", kind, mode, timeout: Duration.second * 60)
            }
        }
    }
}

// Add to cli_app_resource_test.cj. This reuses its private real MCP fixture,
// not the raw-output thin actor and not an injected CliApp factory.
@When[os == "macOS"]
private func appEmbeddedResourceChild(kind: String, mode: String): Unit {
    withIfaceFixture({ fixture =>
        appRecordStandaloneHeap(fixture)
        let recordHeap = { phase: String, ordinal: Int64, event: String =>
            let used = getUsedHeapSize()
            let allocated = getAllocatedHeapSize()
            let maximum = getMaxHeapSize()
            let writerPid = getProcessId()
            let gcCount = getGCCount()
            let wallUnixNs = DateTime.now().toUnixTimeStamp().toNanoseconds()
            let text = "kind:${kind}\nmode:${mode}\nphase:${phase}\nordinal:${ordinal}\nevent:${event}\nwriterPid:${writerPid}\nwallUnixNs:${wallUnixNs}\ngcCount:${gcCount}\nusedHeapBytes:${used}\nallocatedHeapBytes:${allocated}\nmaxHeapBytes:${maximum}\n"
            File.writeTo(fixture.home.join("embedded-${phase}-${ordinal}-${event}.heap"), text.toArray())
            println("R-EMBED-HEAP kind=${kind};mode=${mode};phase=${phase};ordinal=${ordinal};event=${event};writerPid=${writerPid};wallUnixNs=${wallUnixNs};gcCount=${gcCount};usedHeapBytes=${used};allocatedHeapBytes=${allocated};maxHeapBytes=${maximum}")
        }
        CliConfig.internalSubagent = "explorer"; CliConfig.language = "general"
        CliConfig.commandDirs = ArrayList<Path>([fixture.home.join("commands")])
        for (key in cliProviderApiKeyEnvAliases("openai")) { setVariable(key, "fixture-only-key") }
        for (key in cliProviderBaseUrlEnvAliases("openai")) { setVariable(key, fixture.modelBaseUrl) }
        fixture.add("app", "normal")
        if (getVariable("METIS_EMBED_REPORT_DIAGNOSTIC") == Some("1")) {
            let server = fixture.servers.get("app").getOrThrow().asObject()
            let actorEnvironment = JsonObject()
            actorEnvironment.put("MRT_REPORT", JsonString(fixture.home.join("actor.report").toString()))
            server.put("env", actorEnvironment); fixture.servers.put("app", server); fixture.configure()
        }
        if (mode == "bound") { fixture.check(managedRecoveryInitialize(fixture.journal, fixture.parent, fixture.binding)) }
        else { let _ = setProcessLaunchProvider(None) }
        let receipt = fixture.home.join("app.receipt")
        for (warmup in 0..2) {
            recordHeap("warmup", warmup, "entered")
            if (exists(receipt)) { remove(receipt) }
            runEmbeddedPrompt("/exit")
            fixture.check(exists(receipt))
            if (exists(receipt)) { fixture.captureReceipt("app"); fixture.check(fixture.phase("app")) }
            fixture.check(fixture.sourceTerminal())
            recordHeap("warmup", warmup, "completed")
        }
        let fd = ifaceCount(1); let threadBaseline = ifaceThreadSnapshot()
        let memory = CliConfig.cwd.join("MEMORY.md")
        fixture.check(canonicalize(memory.parent).toString().startsWith(fixture.home.toString() + "/"))
        let invalid = [255u8, 254u8, 128u8, 0u8]
        var expectedFailure = ""
        try { let _ = String.fromUtf8(invalid) } catch (error: Exception) { expectedFailure = error.message }
        fixture.check(!expectedFailure.isEmpty())
        if (kind == "embedded_memory") { File.writeTo(memory, invalid) }
        var completed: Int64 = 0
        for (round in 0..32) {
            recordHeap("round", round, "entered")
            if (exists(receipt)) { remove(receipt) }
            var failure = ""
            try { runEmbeddedPrompt(if (kind == "embedded_memory") { "/memory" } else { "/exit" }) }
            catch (error: Exception) { failure = error.message }
            fixture.check(failure == if (kind == "embedded_memory") { expectedFailure } else { "" })
            // Fresh receipt is mandatory: otherwise an early ctor error cannot
            // pretend to prove entry finally after a live MCP client.
            fixture.check(exists(receipt))
            if (exists(receipt)) { fixture.captureReceipt("app"); fixture.check(fixture.phase("app")) }
            fixture.check(fixture.sourceTerminal())
            if (mode == "bound") { fixture.previous.calls = 0; fixture.check(appPreviousProviderRestored(fixture)) }
            else { fixture.check(setProcessLaunchProvider(None).isNone()) }
            fixture.stable(fd, threadBaseline); completed += 1
            recordHeap("round", round, "completed")
        }
        fixture.check(completed == 32)
        println("R-WRAP-EMBED actualRounds=${completed};mode=${mode};kind=${kind};sourceTerminal=${fixture.sourceTerminal()};formal=${!fixture.failed}")
        fixture.complete()
    })
}
