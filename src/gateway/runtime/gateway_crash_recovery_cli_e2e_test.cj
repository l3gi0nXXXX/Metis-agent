package metis.gateway.runtime

import magic.config.Config
import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import magic.utils.http.{HttpUtils, HttpProcessLaunchProvider, HttpProcessLaunchSpec, setHttpProcessLaunchProvider}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock,
    cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.process.{ManagedOwnedChild, launchManagedRawChild, ProcessInstanceIdentity, ProcessBirthIdentity, observeProcessBirthIdentity, probeProcessBirthIdentity,
    probeProcessInstance, currentProcessInstanceIdentity, parseProcessInstanceIdentity,
    managedRecoveryInitialize, managedRecoveryNativeIntent, managedRecoveryNativeSpawned,
    managedRecoveryParseFields, parseProcessBirthIdentity, managedRecoveryContext, managedRecoveryProbeRecords,
    managedRecoveryParseClosedCheckpoint, managedRecoveryLaunchOwned, managedRecoveryBinding, managedRecoveryReadExecError, managedStdioResolveNodeCommand}
import std.collection.{ArrayList, HashMap, HashSet, Map}
import std.convert.Parsable
import std.core.Duration
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists, remove}
import std.fs.copy as copyFile
import std.net.{TcpServerSocket, TcpSocket, IPSocketAddress, SocketTimeoutException}
import std.process.{SubProcess, ProcessRedirect, launch, executeWithOutput}
import std.posix.chmod
import std.time.{DateTime, MonoTime}
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.testmacro.*
import stdx.encoding.json.*

@When[os == "macOS"]
foreign {
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
    func getpgid(pid: Int32): Int32
    func fcntl(fd: Int32, command: Int32, ...): Int32
}

@When[os == "macOS"]
private func crCliFdCount(): Int64 {
    var descriptors = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout descriptors, 32768) }
    if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("fd_observation_failed") }
    Int64(bytes) / 8
}

@When[os == "macOS"]
private func crInitDescriptorIsNull(fd: Int32): Bool {
    let path = LibC.malloc<Byte>(count: 1024)
    if (path.isNull()) { return false }
    try {
        if (unsafe { fcntl(fd, 50, path) } != 0) { return false }
        let expected = "/dev/null".toArray()
        for (index in 0..expected.size) { if (unsafe { path.read(index) } != expected[index]) { return false } }
        unsafe { path.read(expected.size) } == 0
    } finally { unsafe { LibC.free(path) } }
}

@When[os == "macOS"]
private func crInitFdSummary(): String {
    var descriptors = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout descriptors, 32768) }
    if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("fd_observation_failed") }
    let entries = ArrayList<String>()
    var pipes: Int64 = 0; var sockets: Int64 = 0
    for (index in 0..Int64(bytes / 8)) {
        let value = descriptors[index]
        let kind = value >> 32
        let fd = Int32(value & 0xffffffff)
        if (kind == 6) { pipes += 1 }
        if (kind == 2) { sockets += 1 }
        entries.add("${fd}:${kind}:${crInitDescriptorIsNull(fd)}")
    }
    "entries=" + String.join(entries.toArray(), delimiter: ",") + ";pipes=${pipes};sockets=${sockets}"
}

private func crCliRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_response_encoding" }
}

private func crCliWait(millis: Int64, predicate: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.millisecond * millis
    while (MonoTime.now() < deadline) {
        if (predicate()) { return true }
        sleep(Duration.millisecond * 20)
    }
    predicate()
}

private func crCliPort(): Int64 {
    var port: Int64 = 0
    try (server = TcpServerSocket(bindAt: 0u16)) {
        server.bind()
        port = Int64((server.localAddress as IPSocketAddress)?.port ?? 0u16)
    }
    port
}

private func crCliListening(port: Int64): Bool {
    var listening = false
    try (socket = TcpSocket("127.0.0.1", UInt16(port))) {
        socket.connect(timeout: Duration.millisecond * 100)
        listening = true
    } catch (_: Exception) { () }
    listening
}

private func crCliNumber(text: String, field: String): Int64 {
    try { JsonValue.fromStr(text).asObject().get(field).getOrThrow().asInt().getValue() }
    catch (_: Exception) { 0 }
}

private func crCliMagicSource(): Path {
    let configured = getVariable("MAGIC_PATH").getOrThrow({ => Exception("formal_magic_source_missing") })
    if (configured.isEmpty()) { throw Exception("formal_magic_source_missing") }
    canonicalize(Path(configured))
}

private func crCliProductionSourcesFresh(directory: Path, artifact: DateTime): Bool {
    if (!exists(directory) || !FileInfo(directory).isDirectory() || FileInfo(directory).isSymbolicLink()) { return false }
    for (entry in Directory.readFrom(directory)) {
        if (entry.isSymbolicLink()) { return false }
        if (entry.isDirectory()) {
            if (!crCliProductionSourcesFresh(entry.path, artifact)) { return false }
        } else if (entry.name.endsWith(".cj") && !entry.name.endsWith("_test.cj") && entry.lastModificationTime > artifact) {
            return false
        }
    }
    true
}

private func crCliSameBytes(one: Array<Byte>, two: Array<Byte>): Bool {
    if (one.size != two.size) { return false }
    for (index in 0..one.size) { if (one[index] != two[index]) { return false } }
    true
}

private func crCliPendingReplacement(original: Array<Byte>, nonce: String, mode: String): Array<Byte> {
    if (mode == "invalid_utf8") { return [255u8, 254u8, 0u8, 128u8] }
    if (mode == "malformed") { return ("malformed-" + String(Array<Rune>(32768, repeat: r'中')) + "😀syntheticsecret").toArray() }
    let text = try { String.fromUtf8(original) } catch (_: Exception) { throw Exception("pending_fixture_original_encoding_invalid") }
    let changed = text.replace("nonce:${nonce}\n", "nonce:replacement-中文😀\n")
    if (changed == text) { throw Exception("pending_fixture_nonce_not_replaced") }
    changed.toArray()
}

private func crCliInterruptedArchiveMatches(home: Path, original: Array<Byte>): Bool {
    let history = home.join("gateway-serve.recovery-history")
    if (!exists(history)) { return false }
    for (entry in Directory.readFrom(history)) {
        if (!entry.isRegular() || entry.isSymbolicLink() || !entry.name.endsWith(".interrupted-completion")) { continue }
        if (!crCliSameBytes(File.readFrom(entry.path), original)) { continue }
        let base = entry.name.removeSuffix(".interrupted-completion")
        let facts = crCliRead(history.join("${base}.crash-evidence")).split("\n")
        if (facts.contains("kind:interrupted_shutdown") && facts.contains("completion:cleanup_pending") &&
            !facts.contains("completion:missing") && !facts.contains("completion:graceful")) { return true }
    }
    false
}

private func crCliRecordPendingProof(home: Path, name: String, formal: Bool, launchCount: Int64, sameLock: Bool,
    sameCompletion: Bool, sameInventory: Bool): Unit {
    let proof = JsonObject()
    proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("formalOk", JsonBool(formal))
    proof.put("launchCount", JsonInt(launchCount)); proof.put("sameLock", JsonBool(sameLock))
    proof.put("sameCompletion", JsonBool(sameCompletion)); proof.put("sameInventory", JsonBool(sameInventory))
    File.writeTo(home.join("${name}-formal.json"), proof.toJsonString().toArray())
}

private func crCliPendingInventorySnapshot(identity: GatewayServeIdentity): String {
    let resources = managedRecoveryProbeRecords(gatewayRecoveryInventoryPath(identity), identity.processIdentity.getOrThrow().serialize(),
        identity.nonce, MonoTime.now() + Duration.second * 3)
    if (!resources.ok || !resources.terminal) { throw Exception("pending_fixture_inventory_not_terminal") }
    resources.original
}

private func crCliSavePendingInputs(home: Path, name: String, original: Array<Byte>, expected: Array<Byte>): Unit {
    let directory = home.join("${name}-raw-evidence")
    if (!exists(directory)) { Directory.create(directory) }
    File.writeTo(directory.join("original-completion.bin"), original)
    File.writeTo(directory.join("expected-completion.bin"), expected)
    for (file in ["gateway-serve.stop-complete", "gateway-serve.lock"]) {
        let source = home.join(file)
        if (exists(source)) { File.writeTo(directory.join("${file}.observed.bin"), File.readFrom(source)) }
        else { File.writeTo(directory.join("${file}.observed-missing"), "missing".toArray()) }
    }
    let inventories = home.join("gateway-resource-inventory")
    if (exists(inventories)) {
        for (generation in Directory.readFrom(inventories)) {
            if (!generation.isDirectory() || generation.isSymbolicLink()) { continue }
            let copy = directory.join(generation.name)
            Directory.create(copy)
            for (fact in Directory.readFrom(generation.path)) {
                if (fact.isRegular() && !fact.isSymbolicLink()) { File.writeTo(copy.join(fact.name), File.readFrom(fact.path)) }
            }
        }
    }
}

private func crCliSnapshotFlat(source: Path, target: Path): Unit {
    if (!FileInfo(source).isDirectory() || FileInfo(source).isSymbolicLink()) { throw Exception("fixture_snapshot_source_unsafe") }
    Directory.create(target)
    for (entry in Directory.readFrom(source)) {
        if (!entry.isRegular() || entry.isSymbolicLink()) { throw Exception("fixture_snapshot_source_unknown") }
        File.writeTo(target.join(entry.name), File.readFrom(entry.path))
    }
}

private class CrCliFixture {
    let home: Path
    let project: Path
    let binary: Path
    let fixture: Path
    let port: Int64
    let environment: HashMap<String, String>
    let children = ArrayList<ManagedOwnedChild>()
    let identities = ArrayList<GatewayServeIdentity>()
    let births = ArrayList<ProcessBirthIdentity>()
    let pluginPorts = ArrayList<Int64>()
    let outputFiles = HashMap<Int64, Path>()
    let errorFiles = HashMap<Int64, Path>()
    private var formalVerified = false
    private var formalFailed = false
    private var foregroundLaunches: Int64 = 0
    private var installedRejectedBeforeGeneration: Int64 = 0
    private var pendingLaunch = false

    func markFormalResult(ok: Bool): Unit {
        if (!ok) { formalFailed = true }
        formalVerified = ok && !formalFailed
    }

    func formalPassed(): Bool { formalVerified && !formalFailed }
    func installedRejectedCount(): Int64 { installedRejectedBeforeGeneration }

    func expectFormal(ok: Bool): Unit {
        markFormalResult(ok)
        @Expect(ok, true)
    }

    init(home: Path) {
        this.home = home
        project = canonicalize(Path("."))
        binary = project.join("target/release/bin/metis")
        fixture = home.join("recovery-owner")
        port = crCliPort()
        environment = HashMap(getVariables())
        for (key in environment.keys().toArray()) {
            if (key.endsWith("_API_KEY") || key.endsWith("_TOKEN") ||
                ["METIS_LOG_FILE", "METIS_GATEWAY_CLI_MODE", "METIS_STDIO_BROKER_SCRIPT",
                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains(key)) {
                environment.remove(key)
            }
        }
        environment["METIS_HOME"] = home.toString()
        environment["METIS_CJPM_ROOT"] = project.toString()
        environment["METIS_STDIO_BROKER_SCRIPT"] = project.join("scripts/metis-stdio-broker.mjs").toString()
        environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = ""
        environment["METIS_PROCESS_RECOVERY_PARENT"] = ""
        environment["cjHeapSize"] = "2GB"
        let curl = home.join("curl")
        Directory.create(curl)
        File.writeTo(curl.join(".curlrc"), [])
        File.writeTo(curl.join("curlrc"), [])
        environment["CURL_HOME"] = curl.toString()
        environment["XDG_CONFIG_HOME"] = curl.toString()
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        for (key in cliProviderApiKeyEnvAliases("openai")) { environment[key] = "fixture-only-key" }
        for (key in cliProviderBaseUrlEnvAliases("openai")) { environment[key] = "http://127.0.0.1:${crCliPort()}/v1" }
    }

    func compileFixture(): Unit {
        assertFreshBinary()
        let magic = crCliMagicSource()
        let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
        let result = executeWithOutput("cjc", [project.join("test/fixtures/service_plugin/stdio_protocol/gateway_crash_recovery_owner_fixture.cj").toString(),
            "--import-path", stdx.toString(), "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options",
            "-rpath ${stdx.toString()}", "-o", fixture.toString()], workingDirectory: Some(home))
        expectFormal((result[0]) == (0))
        if (result[0] != 0 || !exists(fixture)) {
            let diagnostic = try { String.fromUtf8(result[2]) } catch (_: Exception) { "invalid_response_encoding" }
            println(diagnostic.replace(home.toString(), "<owned-home>").replace(project.toString(), "<task-project>").replace(stdx.toString(), "<task-stdx>"))
            throw Exception("owned_fixture_compile_failed")
        }
    }

    func configure(grandchild: Bool): Unit {
        let manifest = JsonObject()
        manifest.put("schema", JsonString("metis.servicePlugin.v1"))
        manifest.put("pluginId", JsonString("gitcode-monitor"))
        manifest.put("kind", JsonString("service")); manifest.put("protocolVersion", JsonString("1.0"))
        let entry = JsonObject()
        entry.put("command", JsonString(fixture.toString()))
        let args = JsonArray()
        for (arg in ["service", home.join("owner.pending").toString(), home.join("owner.initialized").toString(),
            home.join("initialize.release").toString(), home.join("owner.stop").toString(),
            home.join("grandchild.release").toString(), home.join("grandchild.ready").toString(),
            if (grandchild) { "grandchild" } else { "single" }]) { args.add(JsonString(arg)) }
        entry.put("args", args); manifest.put("entry", entry)
        let schema = JsonObject(); schema.put("type", JsonString("object")); manifest.put("configSchema", schema)
        let declarations = JsonArray()
        let capability = JsonObject()
        capability.put("capabilityId", JsonString("gateway.crash.fixture"))
        capability.put("kind", JsonString("controlAction")); declarations.add(capability)
        manifest.put("capabilityDeclarations", declarations)
        File.writeTo(home.join("owner.manifest.json"), manifest.toJsonString().toArray())
        let gateway = JsonObject()
        gateway.put("enabled", JsonBool(true)); gateway.put("port", JsonInt(port))
        let auth = JsonObject(); auth.put("mode", JsonString("token")); auth.put("token", JsonString("fixture-only-token"))
        gateway.put("auth", auth)
        let logging = JsonObject()
        logging.put("file", JsonString(home.join("gateway.log").toString())); logging.put("level", JsonString("info"))
        gateway.put("logging", logging)
        // A synthetic extension declaration enables the real default launch guard;
        // it performs no network work. The service plugin below supplies the live owner.
        let channels = JsonArray(); let channel = JsonObject()
        channel.put("id", JsonString("crash-recovery-fixture")); channel.put("enabled", JsonBool(true)); channels.add(channel)
        gateway.put("gatewayPlugins", channels)
        let services = JsonArray(); let plugin = JsonObject()
        plugin.put("pluginId", JsonString("gitcode-monitor")); plugin.put("enabled", JsonBool(true)); plugin.put("autostart", JsonBool(true))
        plugin.put("manifestPath", JsonString(home.join("owner.manifest.json").toString()))
        plugin.put("startupTimeoutMs", JsonInt(30000)); services.add(plugin); gateway.put("servicePlugins", services)
        let control = JsonObject(); control.put("enabled", JsonBool(false)); gateway.put("controlUi", control)
        let canvas = JsonObject(); canvas.put("enabled", JsonBool(false)); gateway.put("canvas", canvas)
        let enabled = JsonObject(); enabled.put("enabled", JsonBool(true))
        let endpoints = JsonObject(); endpoints.put("chatCompletions", enabled)
        let http = JsonObject(); http.put("endpoints", endpoints); gateway.put("http", http)
        let defaults = JsonObject(); defaults.put("workspace", JsonString(home.join("workspace").toString()))
        let model = JsonObject(); model.put("primary", JsonString("openai:fixture")); defaults.put("model", model)
        let agents = JsonObject(); agents.put("defaults", defaults)
        let root = JsonObject(); root.put("gateway", gateway); root.put("agents", agents)
        File.writeTo(home.join("metis.json"), root.toJsonString().toArray())
        File.writeTo(home.join("initialize.release"), "release".toArray())
    }

    func launchCli(args: Array<String>, name: String): ManagedOwnedChild {
        assertFreshBinary()
        if (args.size >= 2 && args[0] == "gateway" && ["run", "serve"].contains(args[1])) { foregroundLaunches += 1 }
        launchCommand(binary.toString(), args, name, environment)
    }

    private func assertFreshBinary(): Unit {
        if (!exists(binary) || !FileInfo(binary).isRegular() || FileInfo(binary).isSymbolicLink()) {
            throw Exception("formal_metis_binary_missing_or_stale")
        }
        let built = FileInfo(binary).lastModificationTime
        let broker = project.join("scripts/metis-stdio-broker.mjs")
        if (!crCliProductionSourcesFresh(project.join("src"), built) ||
            !crCliProductionSourcesFresh(crCliMagicSource().join("src"), built) ||
            !exists(broker) || !FileInfo(broker).isRegular() || FileInfo(broker).isSymbolicLink() || FileInfo(broker).lastModificationTime > built) {
            throw Exception("formal_metis_binary_missing_or_stale")
        }
    }

    func launchHook(mode: String): ManagedOwnedChild {
        let childEnv = environment.clone()
        childEnv["METIS_CRASH_CLI_HOOK_MODE"] = mode
        launchCommand(getCommand(), ["--filter=GatewayCrashRecoveryCliE2ETest.rS3N1HookFailuresRemainExplicitAndNeverLaunchUnknown",
            "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"], "hook-${mode}", childEnv)
    }

    func launchHttpComposition(): ManagedOwnedChild {
        let childEnv = environment.clone()
        childEnv["METIS_CRASH_HTTP_C3_CHILD"] = "1"
        launchCommand(getCommand(), ["--filter=GatewayCrashRecoveryCliE2ETest.rS1C3NativeHttpThousandRootsStayBounded",
            "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"], "http-c3", childEnv)
    }

    func launchPendingInventory(): ManagedOwnedChild {
        assertFreshBinary()
        let config = JsonValue.fromStr(crCliRead(home.join("metis.json"))).asObject()
        let gateway = config.get("gateway").getOrThrow().asObject()
        gateway.put("cronEnabled", JsonBool(false)); gateway.put("servicePlugins", JsonArray())
        let disabled = JsonObject(); disabled.put("enabled", JsonBool(false))
        for (key in ["controlUi", "canvas", "telegram", "feishu", "qq"]) { gateway.put(key, disabled) }
        let enabled = JsonObject(); enabled.put("enabled", JsonBool(true))
        let endpoints = JsonObject(); endpoints.put("chatCompletions", enabled)
        let http = JsonObject(); http.put("endpoints", endpoints); gateway.put("http", http)
        // Retain only the synthetic extension declaration for the actual CLI
        // launch guard. No extension implementation or network channel is added.
        File.writeTo(home.join("metis.json"), config.toJsonString().toArray())
        let childEnv = environment.clone()
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        childEnv["METIS_PENDING_INVENTORY_CHILD"] = "1"
        childEnv["METIS_PENDING_INVENTORY_NONCE"] = nonce
        childEnv["METIS_PENDING_INVENTORY_PORT"] = port.toString()
        childEnv["METIS_LOG_FILE"] = home.join("pending-gateway.log").toString()
        childEnv["METIS_CONSOLE_LEVEL"] = "off"
        File.writeTo(home.join("pending-inventory.owner"), ("pending-inventory-v1\n" + nonce).toArray())
        return launchCommand(getCommand(), ["--filter=GatewayCrashRecoveryPendingInventoryTest.realServeIncompleteIntentNeverPublishesTerminal",
            "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"], "pending-inventory", childEnv)
    }

    func producePendingCompletion(): (GatewayServeIdentity, Array<Byte>, String) {
        let child = launchPendingInventory()
        let code = child.wait(timeout: Some(Duration.second * 100))
        expectFormal((code) == (0))
        if (code != 0) { throw Exception("pending_fixture_child_failed") }
        let proof = JsonValue.fromStr(crCliRead(home.join("pending-inventory-formal.json"))).asObject()
        let recorded = proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue()
        let formal = proof.get("formalOk").getOrThrow().asBool().getValue()
        expectFormal((recorded && formal) == (true))
        if (!recorded || !formal) { throw Exception("pending_fixture_formal_proof_failed") }
        let old = identity().getOrThrow()
        let original = File.readFrom(home.join("gateway-serve.stop-complete"))
        let text = try { String.fromUtf8(original) } catch (_: Exception) { throw Exception("pending_fixture_original_encoding_invalid") }
        let completion = gatewayParseServeCompletion(text, old)
        let parent = probeProcessInstance(old.processIdentity.getOrThrow(), MonoTime.now() + Duration.second * 3)
        let resources = managedRecoveryProbeRecords(gatewayRecoveryInventoryPath(old), old.processIdentity.getOrThrow().serialize(),
            old.nonce, MonoTime.now() + Duration.second * 3)
        let terminal = parent.conclusive && !parent.alive && resources.ok && resources.terminal && !crCliListening(port)
        expectFormal((completion.found && completion.status == "cleanup_pending" && !completion.fullTerminal) == (true))
        expectFormal((terminal) == (true))
        if (!completion.found || completion.status != "cleanup_pending" || completion.fullTerminal || !terminal) {
            throw Exception("pending_fixture_source_not_terminal")
        }
        File.writeTo(home.join("pending-original-completion.bin"), original)
        File.writeTo(home.join("pending-original-lock.bin"), File.readFrom(home.join("gateway-serve.lock")))
        capture(old)
        println("R-S2-P4-SOURCE originalPending=true;fullTerminal=false;oldParentGone=${!parent.alive};inventoryTerminal=${resources.terminal};recordedBeforeFallback=${recorded}")
        (old, original, crCliRead(home.join("gateway-serve.lock")))
    }

    func launchInitializationProbe(mode: String, prior: String): ManagedOwnedChild {
        let childEnv = environment.clone()
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        childEnv["METIS_CRASH_INIT_MODE"] = mode
        childEnv["METIS_CRASH_INIT_PRIOR"] = prior
        childEnv["METIS_CRASH_INIT_NONCE"] = nonce
        childEnv["METIS_CRASH_INIT_PORT"] = port.toString()
        childEnv["METIS_LOG_FILE"] = home.join("init-probe.log").toString()
        childEnv["METIS_LOG_LEVEL"] = "debug"
        childEnv["METIS_CONSOLE_LEVEL"] = "off"
        File.writeTo(home.join("init-probe.owner"), ("owned-init-v1\n" + nonce).toArray())
        let config = JsonValue.fromStr(crCliRead(home.join("metis.json"))).asObject()
        config.get("gateway").getOrThrow().asObject().put("servicePlugins", JsonArray())
        File.writeTo(home.join("metis.json"), config.toJsonString().toArray())
        launchCommand(getCommand(), ["--filter=GatewayCrashRecoveryCliE2ETest.rS2InitRealServeFailuresRespectTerminalAndPendingScopes",
            "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"], "init-${mode}-${prior}", childEnv)
    }

    func launchUnconsumedExecFailure(): ManagedOwnedChild {
        assertFreshBinary()
        let config = JsonValue.fromStr(crCliRead(home.join("metis.json"))).asObject()
        let gateway = config.get("gateway").getOrThrow().asObject()
        gateway.put("cronEnabled", JsonBool(false)); gateway.put("servicePlugins", JsonArray())
        File.writeTo(home.join("metis.json"), config.toJsonString().toArray())
        let childEnv = environment.clone()
        childEnv["METIS_EXEC_UNCONSUMED_CHILD"] = "1"
        childEnv["METIS_EXEC_UNCONSUMED_PORT"] = port.toString()
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        childEnv["METIS_EXEC_UNCONSUMED_NONCE"] = nonce
        File.writeTo(home.join("exec-unconsumed.owner"), ("owned-exec-unconsumed-v1\n" + nonce).toArray())
        foregroundLaunches += 1
        launchCommand(getCommand(), ["--filter=GatewayCrashRecoveryCliE2ETest.rNgFactB1UnconsumedExecFailureAllowsActualCliRecovery",
            "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], "exec-unconsumed", childEnv)
    }

    private func launchCommand(command: String, args: Array<String>, name: String, childEnv: HashMap<String, String>,
        workingDirectory!: ?Path = None): ManagedOwnedChild {
        let out = home.join("${name}-${children.size}.stdout")
        let err = home.join("${name}-${children.size}.stderr")
        var result: Option<ManagedOwnedChild> = None
        try (input = File("/dev/null", OpenMode.Read), output = File(out, OpenMode.Write), error = File(err, OpenMode.Write)) {
            pendingLaunch = true
            let child = launchManagedRawChild(command, args, environment: Some<Map<String, String>>(childEnv),
                workingDirectory: Some(workingDirectory ?? project), newGeneration: true,
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            result = Some(child); children.add(child); pendingLaunch = false
            outputFiles[child.pid] = out; errorFiles[child.pid] = err
        }
        result.getOrThrow()
    }

    // Installed-runtime cases use the existing driver, with only child cwd/env changed.
    func launchInstalled(command: Path, args: Array<String>, name: String, cwd: Path): ManagedOwnedChild {
        let env = installedEnvironment()
        if (args.size >= 2 && args[0] == "gateway" && ["run", "serve"].contains(args[1])) { foregroundLaunches += 1 }
        launchCommand(command.toString(), args, name, env, workingDirectory: Some(cwd))
    }

    private func installedEnvironment(): HashMap<String, String> {
        let env = environment.clone()
        for (key in env.keys().toArray()) {
            let upper = key.toAsciiUpper()
            if (upper.contains("PROXY") || upper.contains("SECRET") || upper.contains("PASSWORD") ||
                upper.contains("CREDENTIAL") || upper.endsWith("_ACCESS_KEY_ID") || upper.endsWith("_TOKEN") ||
                upper.endsWith("_API_KEY") || key == "METIS_CJPM_ROOT" || key == "METIS_STDIO_BROKER_SCRIPT" ||
                key.startsWith("METIS_PROCESS_RECOVERY_")) { env.remove(key) }
        }
        env["HOME"] = home.toString(); env["TMPDIR"] = home.toString()
        env["METIS_STDIO_BROKER_NODE_COMMAND"] = managedStdioResolveNodeCommand()
        env["METIS_INSTALLED_UNICODE"] = "合成安装中文😀"
        env["METIS_INSTALLED_ENV_PROOF"] = home.join("installed-env-proof.json").toString()
        return env
    }

    func prepareInstalled(): (Path, Path) {
        assertFreshBinary()
        let root = home.join("package input 中文😀")
        let output = root.join("binary")
        Directory.create(output, recursive: true)
        let copies = [(binary, output.join("magic-cli")),
            (project.join("scripts/metis-stdio-broker.mjs"), root.join("scripts/metis-stdio-broker.mjs")),
            (project.join("build.cj"), root.join("build.cj")),
            (project.join("src/process/managed_exec_gate.c"), root.join("src/process/managed_exec_gate.c"))]
        for ((source, target) in copies) {
            expectFormal(FileInfo(source).isRegular() && !FileInfo(source).isSymbolicLink())
            if (!exists(target.parent)) { Directory.create(target.parent, recursive: true) }
            copyFile(source, to: target)
            expectFormal(crCliInstalledSameFiles(source, target))
        }
        let gate = project.join("target/native/metis-exec-gate-v1")
        expectFormal(FileInfo(gate).isRegular() && !FileInfo(gate).isSymbolicLink() &&
            FileInfo(gate).lastModificationTime >= FileInfo(project.join("build.cj")).lastModificationTime &&
            FileInfo(gate).lastModificationTime >= FileInfo(project.join("src/process/managed_exec_gate.c")).lastModificationTime)
        Directory.create(root.join("target/native"), recursive: true)
        copyFile(gate, to: root.join("target/native/metis-exec-gate-v1"))
        expectFormal(crCliInstalledSameFiles(gate, root.join("target/native/metis-exec-gate-v1")))
        for (path in [output.join("magic-cli"), root.join("target/native/metis-exec-gate-v1")]) {
            expectFormal(unsafe { chmod(path.toString(), 0o755) } == 0)
        }
        @When[arch == "aarch64"]
        let platform = "macos-aarch64"
        @When[arch == "x86_64"]
        let platform = "macos-x86_64"
        let stage = launchCommand("/bin/bash", [project.join("scripts/build-static/stage-managed-runtime.sh").toString(),
            root.toString(), output.toString(), platform], "installed-stage", environment)
        expectFormal(stage.wait(timeout: Some(Duration.second * 60)) == 0)
        stage.closeStreams(); expectFormal(stage.wait() == 0 && stage.streamsAreClosed())
        let installed = home.join("installed runtime 中文😀"); Directory.create(installed)
        let extract = launchCommand("/usr/bin/tar", ["-xzf", output.join("magic-cli-${platform}-runtime.tar.gz").toString(),
            "-C", installed.toString()], "installed-extract", environment)
        expectFormal(extract.wait(timeout: Some(Duration.second * 60)) == 0)
        extract.closeStreams(); expectFormal(extract.wait() == 0 && extract.streamsAreClosed())
        for ((source, target) in [(binary, installed.join("bin/magic-cli")),
            (project.join("scripts/metis-stdio-broker.mjs"), installed.join("scripts/metis-stdio-broker.mjs")),
            (gate, installed.join("libexec/metis-exec-gate-v1"))]) {
            expectFormal(FileInfo(target).isRegular() && !FileInfo(target).isSymbolicLink() && crCliInstalledSameFiles(source, target))
        }
        let unrelated = home.join("unrelated cwd 中文😀"); Directory.create(unrelated)
        expectFormal(!exists(unrelated.join("cjpm.toml")) && !exists(installed.join("cjpm.toml")))
        return (installed, unrelated)
    }

    func compileInstalledFixture(): Unit {
        assertFreshBinary()
        let source = project.join("test/fixtures/service_plugin/stdio_protocol/gateway_crash_recovery_owner_fixture.cj")
        let copied = home.join("installed-owner-source.cj")
        let original = crCliRead(source)
        let needle = "private func service(args: Array<String>): Int64 {"
        expectFormal(original.split(needle).size == 2)
        let injected = needle + "\n    let installedProof = JsonObject()\n" +
            "    installedProof.put(\"unicode\", JsonString(getVariable(\"METIS_INSTALLED_UNICODE\").getOrThrow()))\n" +
            "    installedProof.put(\"dyld\", JsonString(getVariable(\"DYLD_LIBRARY_PATH\").getOrDefault({ => \"\" })))\n" +
            "    File.writeTo(owned(getVariable(\"METIS_INSTALLED_ENV_PROOF\").getOrThrow()), installedProof.toJsonString().toArray())\n"
        File.writeTo(home.join("installed-owner-original.cj"), File.readFrom(source))
        File.writeTo(copied, original.replace(needle, injected).toArray())
        let hashes = launchCommand("/usr/bin/shasum", ["-a", "256", home.join("installed-owner-original.cj").toString(), copied.toString()], "installed-owner-sha", environment)
        expectFormal(hashes.wait(timeout: Some(Duration.second * 60)) == 0)
        hashes.closeStreams(); expectFormal(hashes.wait() == 0 && hashes.streamsAreClosed())
        let difference = launchCommand("/usr/bin/diff", ["-u", home.join("installed-owner-original.cj").toString(), copied.toString()], "installed-owner-diff", environment)
        expectFormal(difference.wait(timeout: Some(Duration.second * 60)) == 1)
        difference.closeStreams(); expectFormal(difference.wait() == 1 && difference.streamsAreClosed())
        let magic = crCliMagicSource()
        let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
        let compiler = Path(getVariable("CANGJIE_HOME").getOrThrow()).join("bin/cjc")
        let child = launchCommand(compiler.toString(), [copied.toString(), "--import-path", stdx.toString(), "-L", stdx.toString(),
            "-lstdx.encoding.json", "--link-options", "-rpath ${stdx.toString()}", "-o", fixture.toString()], "installed-compile-owner", environment)
        let code = child.wait(timeout: Some(Duration.second * 60))
        expectFormal(code == 0)
        child.closeStreams(); expectFormal(child.wait() == code && child.streamsAreClosed() && exists(fixture))
        if (code != 0 || !exists(fixture)) { throw Exception("installed_fixture_compile_failed") }
    }

    func output(process: ManagedOwnedChild): String { crCliRead(outputFiles[process.pid]) + crCliRead(errorFiles[process.pid]) }

    func initializationTerminal(): Bool {
        captureJournalBirths()
        let prior = home.join("prior-context")
        if (exists(prior)) {
            let fields = managedRecoveryParseFields(crCliRead(prior.join("inventory")))
            if (fields.isNone()) { return false }
            let header = fields.getOrThrow()
            let result = managedRecoveryProbeRecords(prior, header["parent"], header["binding"], MonoTime.now() + Duration.second)
            if (!result.ok || !result.terminal) { return false }
        }
        terminal()
    }
    func launchCount(process: ManagedOwnedChild): Int64 { output(process).split("[网关] 已请求在后台启动网关，正在等待就绪").size - 1 }
    func identity(): Option<GatewayServeIdentity> { gatewayParseServeIdentity(crCliRead(home.join("gateway-serve.lock"))) }
    func initializedCount(): Int64 {
        if (!exists(home.join("owner.initialized"))) { return 0 }
        var count: Int64 = 0
        for (line in crCliRead(home.join("owner.initialized")).split("\n")) { if (!line.isEmpty()) { count += 1 } }
        count
    }
    func generationCount(): Int64 {
        let directory = home.join("gateway-resource-inventory")
        if (!exists(directory)) { return 0 }
        var count: Int64 = 0
        for (entry in Directory.readFrom(directory)) { if (entry.isDirectory()) { count += 1 } }
        count
    }

    func capture(identity: GatewayServeIdentity): Unit {
        identities.add(identity)
        captureJournalBirths()
        let pending = crCliRead(home.join("owner.pending"))
        pluginPorts.add(crCliNumber(pending, "port"))
        for (pid in [crCliNumber(pending, "pid"), crCliNumber(pending, "grandchildPid")]) {
            if (pid > 1) {
                if (let Some(birth) <- observeProcessBirthIdentity(pid)) { births.add(birth) }
            }
        }
    }

    func awaitReady(previousNonce!: String = ""): GatewayServeIdentity {
        expectFormal((crCliWait(30000, { =>
            match (identity()) {
                case Some(value) =>
                    value.nonce != previousNonce && value.processIdentity.isSome() &&
                        exists(gatewayRecoveryInventoryPath(value).join("ready")) && crCliListening(port)
                case None => false
            }
        })) == (true))
        let value = identity().getOrThrow()
        expectFormal((gatewayAwaitRestartReady(MonoTime.now() + Duration.second, previousNonce: previousNonce)) == (true))
        capture(value)
        value
    }

    @When[os == "macOS"]
    func killParent(process: ManagedOwnedChild, identity: GatewayServeIdentity, abort: Bool): Unit {
        var returnedHandle = false
        for (owned in children) {
            if (refEq((owned as Object).getOrThrow(), (process as Object).getOrThrow())) { returnedHandle = true }
        }
        let probe = probeProcessInstance(identity.processIdentity.getOrThrow(), MonoTime.now() + Duration.second)
        if (!returnedHandle || process.pid != identity.pid || !probe.conclusive || !probe.alive || !process.isAlive()) {
            throw Exception("formal_direct_child_ownership_missing")
        }
        // A still-unreaped returned direct child cannot have its PID reused.
        // Birth/census records are never accepted as signal authority here.
        expectFormal((unsafe { kill(Int32(process.pid), if (abort) { Int32(6) } else { Int32(9) }) }) == (0))
        let _ = process.wait(timeout: Some(Duration.second * 5))
        expectFormal((process.isAlive()) == (false))
        expectFormal((exists(home.join("gateway-serve.stop-complete"))) == (false))
    }

    private func inventoryTerminal(directory: Path, requireParentGone: Bool): Bool {
        try {
            if (!FileInfo(directory).isDirectory() || FileInfo(directory).isSymbolicLink() ||
                !canonicalize(directory).toString().startsWith(canonicalize(home).toString() + "/")) { return false }
            let fields = managedRecoveryParseFields(crCliRead(directory.join("inventory"))).getOrThrow()
            let parent = fields.get("parent").getOrThrow()
            let binding = fields.get("binding").getOrThrow()
            let identity = parseProcessInstanceIdentity(parent).getOrThrow()
            if (binding.isEmpty()) { return false }
            if (requireParentGone) {
                let prefix = "${identity.pid}-"
                let name = directory.fileName
                if (!name.startsWith(prefix) || Int64.parse(name.removePrefix(prefix)) <= 0) { return false }
                for (known in identities) {
                    if (gatewayRecoveryInventoryPath(known) == directory &&
                        (known.nonce != binding || known.processIdentity.getOrThrow().serialize() != parent)) { return false }
                }
                if (let Some(current) <- this.identity()) {
                    if (gatewayRecoveryInventoryPath(current) == directory &&
                        (current.nonce != binding || current.processIdentity.getOrThrow().serialize() != parent)) { return false }
                }
                let state = probeProcessInstance(identity, MonoTime.now() + Duration.second)
                if (!state.conclusive || state.alive) { return false }
            }
            let proof = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second)
            proof.ok && proof.terminal
        } catch (_: Exception) { false }
    }

    // Only the installed negative fixture can prove that an attempted launch
    // exited before any Gateway generation was published.
    @When[os == "macOS"]
    func recordInstalledPreGenerationRejection(child: ManagedOwnedChild): Bool {
        let code = child.wait(timeout: Some(Duration.second * 3))
        child.closeStreams()
        let absent = identity().isNone() && generationCount() == 0 &&
            !exists(home.join("gateway-serve.lock")) && !exists(home.join("gateway-resource-inventory")) &&
            !exists(home.join("gateway-serve.stop-complete")) && !exists(home.join("owner.pending")) &&
            !exists(home.join("owner.initialized")) && !exists(home.join("installed-env-proof.json")) &&
            initializedCount() == 0 && !crCliListening(port)
        let groupGone = unsafe { kill(-Int32(child.pid), 0) } != 0 && unsafe { __error().read() } == 3
        let proven = code > 0 && code <= 255 && child.wait() == code && child.streamsAreClosed() &&
            !child.isAlive() && groupGone && absent && output(child).contains("owned_process_internal_asset_invalid")
        let proof = JsonObject(); proof.put("formal", JsonBool(proven)); proof.put("code", JsonInt(code))
        proof.put("attempts", JsonInt(foregroundLaunches)); proof.put("generations", JsonInt(generationCount()))
        proof.put("groupGone", JsonBool(groupGone)); proof.put("sourceAbsent", JsonBool(absent))
        proof.put("recordedBeforeFallback", JsonBool(true))
        File.writeTo(home.join("installed-pre-generation-rejection.json"), proof.toJsonString().toArray())
        if (proven && installedRejectedBeforeGeneration == 0 && foregroundLaunches == 1) {
            installedRejectedBeforeGeneration = 1
            return true
        }
        false
    }

    func terminal(): Bool {
        if (pendingLaunch) { return false }
        try {
            // This native handle caches a status only after exact waitpid(child).
            // Obtain that real receipt and close its streams before terminal.
            for (child in children) {
                if (child.isAlive()) { return false }
                let _ = child.wait(timeout: Some(Duration.second * 3))
                child.closeStreams()
                if (!child.streamsAreClosed()) { return false }
            }
            if (exists(home.join("gateway-serve.lock"))) {
                let current = identity().getOrThrow()
                if (current.processIdentity.isNone()) { return false }
                let state = probeProcessInstance(current.processIdentity.getOrThrow(), MonoTime.now() + Duration.second)
                if (!state.conclusive || state.alive) { return false }
            }
            for (value in identities) {
                let probe = probeProcessInstance(value.processIdentity.getOrThrow(), MonoTime.now() + Duration.second)
                if (!probe.conclusive || probe.alive) { return false }
            }
            for (birth in births) {
                let probe = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
                if (!probe.conclusive || probe.alive) { return false }
            }
            if (crCliListening(port)) { return false }
            for (port in pluginPorts) { if (port > 0 && crCliListening(port)) { return false } }
            var generations: Int64 = 0
            let inventory = home.join("gateway-resource-inventory")
            if (exists(inventory)) {
                if (FileInfo(inventory).isSymbolicLink()) { return false }
                for (entry in Directory.readFrom(inventory)) {
                    if (!entry.isDirectory() || entry.isSymbolicLink() || !inventoryTerminal(entry.path, true)) { return false }
                    generations += 1
                }
            }
            var requested = foregroundLaunches - installedRejectedBeforeGeneration
            for (child in children) { requested += launchCount(child) }
            // A new launch whose header/identity was never captured is unknown,
            // even when all previously captured observations happen to be empty.
            if (generations < requested) { return false }
            let composition = home.join("http-composition-inventory")
            if (exists(composition) && !inventoryTerminal(composition, false)) { return false }
            true
        } catch (_: Exception) { false }
    }

    func stopAndObserve(): Unit {
        captureJournalBirths()
        let stop = launchCli(["gateway", "stop"], "stop")
        expectFormal(stop.wait(timeout: Some(Duration.second * 65)) == 0)
        let gone = crCliWait(5000, { => terminal() })
        println("R-CLI formalTerminalBeforeFallback=${gone};generations=${generationCount()};initializations=${initializedCount()}")
        expectFormal(gone)
    }

    func fallback(): Unit {
        var firstError = None<Exception>
        try { captureJournalBirths() }
        catch (error: Exception) { firstError = Some(error) }
        for (name in ["initialize.release", "grandchild.release"]) {
            try { File.writeTo(home.join(name), "release".toArray()) }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        }
        try {
            if (let Some(value) <- identity()) {
                if (fallbackGenerationBound(value)) {
                    identities.add(value)
                    let _ = gatewayTryTerminateServeProcessUntil(value.pid, MonoTime.now() + Duration.second * 3)
                }
            }
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        for (child in children) {
            try { if (child.isAlive()) { child.terminate(force: true) } }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            try { let _ = child.wait(timeout: Some(Duration.second * 3)) }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try { child.closeStreams() }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
        }
        try {
            let complete = crCliWait(5000, { => terminal() })
            @Expect(complete, true)
            if (!complete) { throw Exception("cr_cli_cleanup_pending") }
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        if (let Some(error) <- firstError) { throw error }
    }

    private func fallbackGenerationBound(value: GatewayServeIdentity): Bool {
        try {
            if (value.pid == getProcessId() || value.processIdentity.isNone() || !home.toString().startsWith("/private/tmp/")) { return false }
            if (canonicalize(home) != canonicalize(CliConfig.dotDir)) { return false }
            let directory = gatewayRecoveryInventoryPath(value)
            if (!exists(directory) || FileInfo(directory).isSymbolicLink() ||
                !canonicalize(directory).toString().startsWith(canonicalize(home).toString() + "/")) { return false }
            let header = managedRecoveryParseFields(crCliRead(directory.join("inventory")))
            match (header) {
                case Some(fields) => fields.get("parent") == Some(value.processIdentity.getOrThrow().serialize()) && fields.get("binding") == Some(value.nonce)
                case None => false
            }
        } catch (_: Exception) { false }
    }

    private func captureJournalBirths(): Unit {
        let directories = ArrayList<Path>()
        let inventories = home.join("gateway-resource-inventory")
        if (exists(inventories)) {
            for (generation in Directory.readFrom(inventories)) {
                if (!generation.isDirectory()) { continue }
                directories.add(generation.path)
            }
        }
        let composition = home.join("http-composition-inventory")
        if (exists(composition)) { directories.add(composition) }
        for (directory in directories) {
                for (entry in Directory.readFrom(directory)) {
                    if (!entry.name.endsWith(".birth")) { continue }
                    let fields = managedRecoveryParseFields(crCliRead(entry.path))
                    if (let Some(value) <- fields) {
                        if (let Some(text) <- value.get("birth")) {
                            if (let Some(birth) <- parseProcessBirthIdentity(text)) { births.add(birth) }
                        }
                    }
                }
        }
    }
}

private class CrCliHookProbe {
    var launches: Int64 = 0
    var ready: Int64 = 0
}

private class CrInitPriorProcessProvider <: ProcessLaunchProvider {
    let calls = AtomicInt64(0)
    public func launch(_command: String, _args: Array<String>, _env: Array<(String, String)>, _redirectErr: Bool): ProcessHandle {
        this.calls.fetchAdd(1)
        throw Exception("owned_init_prior_provider")
    }
}

private class CrInitPriorHttpProvider <: HttpProcessLaunchProvider {
    let calls = AtomicInt64(0)
    public func prepare(_command: String, _args: Array<String>): HttpProcessLaunchSpec {
        this.calls.fetchAdd(1)
        throw Exception("owned_init_prior_provider")
    }
}

@When[os == "macOS"]
private func crCliInitializationChild(mode: String): Unit {
    let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
    let prior = getVariable("METIS_CRASH_INIT_PRIOR").getOrThrow()
    let nonce = getVariable("METIS_CRASH_INIT_NONCE").getOrThrow()
    if (!home.toString().startsWith("/private/tmp/") || !["early", "pending"].contains(mode) ||
        !["absent", "bound"].contains(prior) || nonce.isEmpty() ||
        crCliRead(home.join("init-probe.owner")) != "owned-init-v1\n" + nonce) {
        throw Exception("initialization_probe_not_owned")
    }
    let proof = JsonObject()
    proof.put("formalOk", JsonBool(false))
    let blocker = home.join(if (mode == "early") { "gateway-channel-runtime-state.json" } else { "gateway-rpc-state.json" })
    Directory.create(blocker)
    File.writeTo(blocker.join("sentinel"), "owned-init-blocker".toArray())
    CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    if (prior == "bound") {
        if (!managedRecoveryInitialize(home.join("prior-context"), parent, "owned-prior-context")) {
            throw Exception("initialization_prior_context_failed")
        }
    } else {
        removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        removeVariable("METIS_PROCESS_RECOVERY_PARENT")
    }
    let previousDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let previousParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let previousProcess = CrInitPriorProcessProvider()
    let previousHttp = CrInitPriorHttpProvider()
    let _ = setProcessLaunchProvider(Some<ProcessLaunchProvider>(previousProcess))
    let _ = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(previousHttp))
    let baseline = crCliFdCount()
    let baselineDescriptors = crInitFdSummary()
    try {
        let failed = try { runGatewayService() != 0 } catch (_: Exception) { true }
        let inventories = home.join("gateway-resource-inventory")
        var inventory = None<Path>
        var count: Int64 = 0
        for (entry in Directory.readFrom(inventories)) {
            if (entry.isDirectory() && !entry.isSymbolicLink()) { inventory = Some(entry.path); count += 1 }
        }
        let directory = inventory.getOrThrow()
        let header = managedRecoveryParseFields(crCliRead(directory.join("inventory"))).getOrThrow()
        let completionText = crCliRead(home.join("gateway-serve.stop-complete"))
        let identity = gatewayParseServeIdentity(completionText).getOrThrow()
        let completion = gatewayParseServeCompletion(completionText, identity)
        let resources = managedRecoveryProbeRecords(directory, parent, identity.nonce, MonoTime.now() + Duration.second * 5)
        let terminal = resources.ok && resources.terminal
        let priorTerminal = if (prior == "bound") {
            let result = managedRecoveryProbeRecords(home.join("prior-context"), parent, "owned-prior-context", MonoTime.now() + Duration.second)
            result.ok && result.terminal
        } else { true }
        let readyAbsent = !exists(directory.join("ready"))
        let port = Int64.parse(getVariable("METIS_CRASH_INIT_PORT").getOrThrow())
        let portGone = !crCliListening(port)
        let noPlugin = !exists(home.join("owner.initialized")) && !exists(home.join("owner.pending"))
        let originalBlocker = FileInfo(blocker).isDirectory() && crCliRead(blocker.join("sentinel")) == "owned-init-blocker"
        let log = crCliRead(home.join("init-probe.log"))
        let intendedPhase = if (mode == "early") {
            log.contains("Gateway.factory.timing: step=service-plugins-registered ") &&
                !log.contains("Gateway.factory.timing: step=bindings-primed ")
        } else {
            log.contains("Gateway.serve.timing: step=service-built ") &&
                !log.contains("Gateway.serve.timing: step=rpc-server-started ")
        }
        // Observe and immediately restore the exact same provider before probing.
        // This isolated child has already verified its inventory terminal; neither
        // rejecting probe starts a process or opens a network connection.
        let activeProcess = setProcessLaunchProvider(None<ProcessLaunchProvider>)
        let _ = setProcessLaunchProvider(activeProcess)
        let activeHttp = setHttpProcessLaunchProvider(None<HttpProcessLaunchProvider>)
        let _ = setHttpProcessLaunchProvider(activeHttp)
        let processRejection = try {
            let _ = activeProcess.getOrThrow().launch("/usr/bin/true", [], [], true)
            "unexpected_success"
        } catch (error: Exception) { error.message }
        let httpRejection = try {
            let _ = activeHttp.getOrThrow().prepare("/usr/bin/true", [])
            "unexpected_success"
        } catch (error: Exception) { error.message }
        let expectedCalls: Int64 = if (mode == "early") { 1 } else { 0 }
        let expectedRejection = if (mode == "early") { "owned_init_prior_provider" } else { "process_recovery_generation_closing" }
        let providers = previousProcess.calls.load() == expectedCalls && previousHttp.calls.load() == expectedCalls &&
            processRejection == expectedRejection && httpRejection == expectedRejection
        let restored = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY") == previousDirectory &&
            getVariable("METIS_PROCESS_RECOVERY_PARENT") == previousParent
        let retained = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY") == Some(directory.toString()) &&
            getVariable("METIS_PROCESS_RECOVERY_PARENT") == Some(parent)
        let scopeState = if (mode == "early") {
            restored && !exists(home.join("gateway-serve.lock")) && completion.fullTerminal
        } else {
            retained && exists(home.join("gateway-serve.lock")) && !completion.fullTerminal && completion.status == "cleanup_pending"
        }
        let finalFd = crCliFdCount()
        let finalDescriptors = crInitFdSummary()
        let formal = failed && intendedPhase && priorTerminal && count == 1 && header["parent"] == parent && header["binding"] == identity.nonce &&
            identity.pid == getProcessId() && completion.found && terminal && readyAbsent && portGone && noPlugin &&
            originalBlocker && providers && scopeState && finalFd <= baseline + 2
        proof.put("formalOk", JsonBool(formal))
        proof.put("intendedPhase", JsonBool(intendedPhase))
        proof.put("startupFailed", JsonBool(failed)); proof.put("resourceTerminal", JsonBool(terminal))
        proof.put("fullTerminal", JsonBool(completion.fullTerminal)); proof.put("scopeState", JsonBool(scopeState))
        proof.put("priorProviders", JsonBool(providers)); proof.put("readyAbsent", JsonBool(readyAbsent))
        proof.put("portGone", JsonBool(portGone)); proof.put("baselineFd", JsonInt(baseline)); proof.put("finalFd", JsonInt(finalFd))
        proof.put("baselineDescriptors", JsonString(baselineDescriptors)); proof.put("finalDescriptors", JsonString(finalDescriptors))
        println("R-S2INIT-FD mode=${mode};prior=${prior};before=${baselineDescriptors};after=${finalDescriptors}")
        @Expect(formal, true)
        println("R-S2INIT mode=${mode};prior=${prior};startupFailed=${failed};intendedPhase=${intendedPhase};resourceTerminal=${terminal};fullTerminal=${completion.fullTerminal};scopeState=${scopeState};priorProviders=${providers};readyAbsent=${readyAbsent};portGone=${portGone};baselineFd=${baseline};finalFd=${finalFd};formalBeforeFallback=${formal}")
    } finally {
        proof.put("recordedBeforeFallback", JsonBool(true))
        File.writeTo(home.join("init-formal.json"), proof.toJsonString().toArray())
    }
}

@When[os == "macOS"]
private class CrHttpC3Observation {
    let accepted = AtomicInt64(0)
    let stop = AtomicBool(false)
    let births = ArrayList<ProcessBirthIdentity>()
    let groups = HashSet<Int64>()

    func capture(directory: Path): Unit {
        for (entry in Directory.readFrom(directory)) {
            if (!entry.name.endsWith(".birth")) { continue }
            let fields = managedRecoveryParseFields(crCliRead(entry.path)).getOrThrow()
            let birth = parseProcessBirthIdentity(fields["birth"]).getOrThrow()
            births.add(birth)
            let pgid = Int64(unsafe { getpgid(Int32(birth.pid)) })
            @Expect(pgid, birth.pid)
            if (pgid <= 1 || pgid != birth.pid) { throw Exception("composition_detached_group_not_observed") }
            groups.add(pgid)
        }
    }

    func serve(listener: TcpServerSocket, directory: Path, body: String): Unit {
        while (!stop.load() && accepted.load() < 1000) {
            try (peer = listener.accept(timeout: Some(Duration.millisecond * 100))) {
                peer.readTimeout = Some(Duration.second * 5)
                let request = ArrayList<Byte>()
                let buffer = Array<Byte>(4096, repeat: 0)
                var complete = false
                while (!complete && request.size < 65536) {
                    let count = peer.read(buffer)
                    if (count == 0) { throw Exception("fixture_request_eof") }
                    for (index in 0..count) {
                        request.add(buffer[index])
                        let size = request.size
                        if (size >= 4 && request[size - 4] == 13 && request[size - 3] == 10 &&
                            request[size - 2] == 13 && request[size - 1] == 10) { complete = true; break }
                    }
                }
                if (!complete) { throw Exception("fixture_request_incomplete") }
                // Helper and curl identities are committed before the gate can
                // send this request. Capture them before the response permits
                // actual exit/reap and checkpoint compaction.
                capture(directory)
                accepted.fetchAdd(1)
                peer.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.toArray().size}\r\nConnection: close\r\n\r\n${body}".toArray())
            } catch (_: SocketTimeoutException) { () }
        }
    }
}

@When[os == "macOS"]
private func crHttpC3AllGone(observation: CrHttpC3Observation): Bool {
    for (birth in observation.births) {
        let state = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
        if (!state.conclusive || state.alive) { return false }
    }
    for (pgid in observation.groups) {
        if (unsafe { kill(Int32(-pgid), 0) } == 0 || unsafe { __error().read() } != 3) { return false }
    }
    true
}

@When[os == "macOS"]
private func crHttpC3Child(): Unit {
    let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
    if (!home.toString().startsWith("/private/tmp/")) { throw Exception("composition_home_not_owned") }
    let priorEnvironment = ArrayList<(String, Option<String>)>()
    for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT"]) {
        priorEnvironment.add((key, getVariable(key)))
    }
    let identity = currentProcessInstanceIdentity().getOrThrow()
    let directory = home.join("http-composition-inventory")
    let parent = identity.serialize()
    let binding = "http-c3-中文😀"
    let observation = CrHttpC3Observation()
    var installedProvider = None<GatewayHttpRecoveryLaunchProvider>
    var previousProvider = None<HttpProcessLaunchProvider>
    var providerInstalled = false
    var listenerResource = None<TcpServerSocket>
    var workerResource = None<Future<Unit>>
    var setupComplete = false
    var formalGone = false
    var workerJoined = false
    var firstError = None<Exception>
    try {
        let initialized = managedRecoveryInitialize(directory, parent, binding)
        @Expect(initialized, true)
        if (!initialized) { throw Exception("composition_inventory_initialization_failed") }
        let provider = GatewayHttpRecoveryLaunchProvider(managedRecoveryContext())
        installedProvider = Some(provider)
        previousProvider = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(provider))
        providerInstalled = true
        let listener = TcpServerSocket(bindAt: 0u16)
        listenerResource = Some(listener)
        listener.bind()
        let port = Int64((listener.localAddress as IPSocketAddress)?.port ?? 0u16)
        let body = "{malformed-json\n中文😀-raw-response"
        let worker = spawn { observation.serve(listener, directory, body) }
        workerResource = Some(worker)
        setupComplete = true
        var warm: Int64 = 0
        var peak: Int64 = 0
        var filePeak: Int64 = 0
        let batches = ArrayList<Int64>()
        for (round in 0..1000) {
            let response = HttpUtils.get("http://127.0.0.1:${port}/fixture", HashMap<String, String>(), None)
            @Expect(response, Some(body))
            if (response != Some(body)) { throw Exception("composition_response_changed") }
            if (round == 19) { warm = crCliFdCount() }
            var files: Int64 = 0
            for (_ in Directory.readFrom(directory)) { files += 1 }
            filePeak = max(filePeak, files)
            @Expect(files <= 16, true)
            if ((round + 1) % 100 == 0) {
                let count = crCliFdCount()
                batches.add(count); peak = max(peak, count)
                @Expect(count <= warm + 2, true)
            }
        }
        worker.get(Duration.second * 5)
        workerJoined = true
        @Expect(observation.accepted.load(), 1000)
        @Expect(observation.births.size, 2000)
        @Expect(observation.groups.size, 2000)
        let checkpoint = managedRecoveryParseClosedCheckpoint(crCliRead(directory.join("roots.closed")), "roots.closed", parent).getOrThrow()
        @Expect(checkpoint.issued, 1000)
        for (sequence in 1..=1000) { @Expect(checkpoint.covers("r-${sequence}"), true) }
        let proof = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 5)
        @Expect(proof.ok && proof.terminal, true)
        formalGone = proof.ok && proof.terminal && workerJoined &&
            crCliWait(5000, { => crHttpC3AllGone(observation) })
        @Expect(formalGone, true)
        let finalCount = crCliFdCount()
        @Expect(finalCount <= warm + 2, true)
        println("R-S1-C3 actualHttp=${observation.accepted.load()};issued=${checkpoint.issued};ranges=${checkpoint.ranges.size};births=${observation.births.size};groups=${observation.groups.size};warmFd=${warm};peakFd=${peak};finalFd=${finalCount};filePeak=${filePeak};batches=${batches};formalGoneBeforeFallback=${formalGone}")
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        var cleaned = false
        if (let Some(provider) <- installedProvider) {
            try { provider.closeAdmission() }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        }
        observation.stop.store(true)
        if (let Some(listener) <- listenerResource) {
            try { listener.close() }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        }
        if (let Some(worker) <- workerResource) {
            try { worker.get(Duration.second * 5); workerJoined = true }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        }
        try {
            // Read-only birth observations never authorize signaling a discovered PID.
            let workerJoinedSnapshot = workerJoined
            if (setupComplete) {
                cleaned = crCliWait(5000, { =>
                    let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second)
                    workerJoinedSnapshot && source.ok && source.terminal && crHttpC3AllGone(observation)
                })
            }
            File.writeTo(home.join("http-composition-cleanup.json"),
                ("{\"formalBeforeFallback\":${formalGone},\"workerJoined\":${workerJoined},\"sourceTerminal\":${cleaned}}").toArray())
            @Expect(cleaned, true)
            if (!cleaned) { throw Exception("composition_cleanup_pending") }
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        finally {
            if (providerInstalled) {
                try { let _ = setHttpProcessLaunchProvider(previousProvider) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
            for ((key, value) in priorEnvironment) {
                try { match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) } }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
        }
    }
    if (let Some(error) <- firstError) { throw error }
}

private func crCliHookChild(mode: String): Unit {
    let home = Path(getVariable("METIS_HOME").getOrThrow())
    CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
    let probe = CrCliHookProbe()
    var owner: Option<SubProcess> = None
    if (mode == "invalid_utf8" || mode == "malformed_json") {
        File.writeTo(home.join("metis.json"), if (mode == "invalid_utf8") { [255u8, 254u8] }
            else { ("{malformed-" + String(Array<Rune>(32768, repeat: r'中')) + "😀syntheticsecret").toArray() })
        MetisConfigManager.invalidate()
    }
    if (mode == "unknown" || mode == "owner_alive") {
        let current = currentProcessInstanceIdentity().getOrThrow()
        let identity = GatewayServeIdentity(987654321, 1000, "unit-crash-中文😀",
            processIdentity: Some(ProcessInstanceIdentity(current.platform, 987654321)))
        let text = "gateway-serve-active-v4\npid:${identity.pid}\nstartedAtMs:${identity.startedAtMs}\nnonce:${identity.nonce}\n" +
            "processIdentity:${identity.processIdentity.getOrThrow().serialize()}\ngracefulShutdownTimeoutMs:60000\n"
        File.writeTo(home.join("gateway-serve.lock"), text.toArray())
        @Expect(managedRecoveryInitialize(gatewayRecoveryInventoryPath(identity), identity.processIdentity.getOrThrow().serialize(), identity.nonce), true)
        if (mode == "unknown") {
            File.writeTo(gatewayRecoveryInventoryPath(identity).join("invalid.intent"), [255u8, 254u8])
        } else {
            let child = launch("/bin/sleep", ["90"], stdIn: ProcessRedirect.Inherit,
                stdOut: ProcessRedirect.Inherit, stdErr: ProcessRedirect.Inherit)
            owner = Some(child)
            let key = managedRecoveryNativeIntent()
            @Expect(managedRecoveryNativeSpawned(key, child.pid, 0), true)
        }
    }
    try {
        let code = gatewayExecuteRestartServe(launchServe: { => probe.launches += 1; mode == "ready_false" },
            awaitReady: { => probe.ready += 1; false })
        @Expect(code, 1)
        @Expect(probe.launches, if (mode == "launch_false" || mode == "ready_false") { 1 } else { 0 })
        @Expect(probe.ready, if (mode == "ready_false") { 1 } else { 0 })
        println("R-CLI-HOOK mode=${mode};code=${code};launch=${probe.launches};ready=${probe.ready}")
    } finally {
        var ownerReaped = owner.isNone()
        var ownerWaitCode = None<Int64>
        if (let Some(child) <- owner) {
            try {
                if (child.isAlive()) { child.terminate(force: true) }
                let code = child.wait(timeout: Some(Duration.second * 3))
                ownerWaitCode = Some(code)
                ownerReaped = code >= 0 && code <= 255 && !child.isAlive()
            } catch (_: Exception) { () }
        }
        let receipt = JsonObject()
        receipt.put("mode", JsonString(mode)); receipt.put("hadOwner", JsonBool(owner.isSome()))
        receipt.put("directOwnerWaitCompleted", JsonBool(ownerReaped))
        receipt.put("actualWaitCode", JsonInt(ownerWaitCode ?? -1))
        File.writeTo(home.join("hook-owner-wait.json"), receipt.toJsonString().toArray())
    }
}

/** Deliberately never calls ManagedRecoveryChild.wait: the real parent is hard-killed by its owner. */
@When[os == "macOS"]
private func crCliUnconsumedExecChild(): Unit {
    let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
    let nonce = getVariable("METIS_EXEC_UNCONSUMED_NONCE").getOrThrow()
    let port = Int64.parse(getVariable("METIS_EXEC_UNCONSUMED_PORT").getOrThrow())
    if (!home.toString().startsWith("/private/tmp/") || nonce.isEmpty() ||
        crCliRead(home.join("exec-unconsumed.owner")) != "owned-exec-unconsumed-v1\n" + nonce) {
        throw Exception("exec_unconsumed_child_not_owned")
    }
    CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
    CliConfig.model = "openai:fixture"
    let serve = spawn { runGatewayService() }
    if (!crCliWait(30000, { =>
        match (gatewayReadServeIdentity()) {
            case Some(value) => value.pid == getProcessId() && exists(gatewayRecoveryInventoryPath(value).join("ready")) && crCliListening(port) &&
                try { gatewayRuntimeSnapshot().get("lastPollAtMs").getOrThrow().asInt().getValue() > 0 }
                catch (_: Exception) { false }
            case None => false
        }
    })) { throw Exception("exec_unconsumed_ready_timeout") }
    let identity = gatewayReadServeIdentity().getOrThrow()
    let context = managedRecoveryContext()
    let binding = managedRecoveryBinding(context)
    let directory = Path(context[0])
    let failed = managedRecoveryLaunchOwned(home.join("missing-exec-business").toString(), [],
        stdIn: ProcessRedirect.Inherit, stdOut: ProcessRedirect.Inherit, stdErr: ProcessRedirect.Inherit)
    let ownerKeyState = ArrayList<String>([""])
    if (!crCliWait(5000, { =>
        for (entry in Directory.readFrom(directory)) {
            if (!entry.name.endsWith(".exec_error")) { continue }
            let key = entry.name.removeSuffix(".exec_error")
            let outcome = managedRecoveryReadExecError(directory, context[1], binding, key)
            if (outcome.isSome() && outcome.getOrThrow().phase == "exec" && outcome.getOrThrow().error == 2 &&
                outcome.getOrThrow().originalText.contains("\nhelper_pid:${failed.pid}\n") &&
                exists(directory.join("${key}.terminal"))) { ownerKeyState[0] = key; return true }
        }
        false
    })) { throw Exception("exec_unconsumed_fact_timeout") }
    let ownerKey = ownerKeyState[0]
    let original = File.readFrom(directory.join("${ownerKey}.exec_error"))
    File.writeTo(home.join("exec-unconsumed-original.bin"), original)
    let proof = JsonObject()
    proof.put("formalOk", JsonBool(true)); proof.put("outcomeConsumed", JsonBool(false))
    proof.put("nonce", JsonString(identity.nonce)); proof.put("ownerKey", JsonString(ownerKey))
    proof.put("helperPid", JsonInt(failed.pid)); proof.put("binding", JsonString(binding))
    File.writeTo(home.join("exec-unconsumed-ready.json"), proof.toJsonString().toArray())
    println("R-NG-FACT-B1 childReady=true;outcomeConsumed=false;helperPid=${failed.pid}")
    // No wait/poll/close on failed or serve. Parent uses only its still-owned direct handle.
    while (true) { sleep(Duration.millisecond * 50) }
}

private func withCrCliFixture(action: (CrCliFixture) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Directory.createTemp("/private/tmp")
        let previous = ArrayList<(String, Option<String>)>()
        for (key in ["METIS_HOME", "METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT"]) {
            previous.add((key, getVariable(key)))
        }
        let oldLog = Config.logFile
        var fixtureResource = None<CrCliFixture>
        var actionCompleted = false
        var firstError = None<Exception>
        try {
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", ""); setVariable("METIS_PROCESS_RECOVERY_PARENT", "")
            CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
            Config.logFile = home.join("test.log").toString(); gatewayLoggingResetForTest()
            let fixture = CrCliFixture(home)
            fixtureResource = Some(fixture)
            action(fixture); actionCompleted = true
        } catch (error: Exception) { firstError = Some(error) }
        finally {
            var terminalBeforeFallback = false
            var proofSaved = false
            var terminal = false
            var formal = false
            try {
                if (let Some(fixture) <- fixtureResource) {
                    if (!actionCompleted) { fixture.markFormalResult(false) }
                    formal = fixture.formalPassed()
                    terminalBeforeFallback = fixture.terminal()
                }
                File.writeTo(home.join("parent-formal-before-fallback.json"),
                    ("{\"recordedBeforeFallback\":true,\"actionCompleted\":${actionCompleted},\"formalOk\":${formal},\"terminalBeforeFallback\":${terminalBeforeFallback}}").toArray())
                proofSaved = true
            } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try {
                    if (let Some(fixture) <- fixtureResource) { fixture.fallback() }
                } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally {
                    try {
                        if (let Some(fixture) <- fixtureResource) { terminal = fixture.terminal() }
                    } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                    finally {
                        for ((key, value) in previous) {
                            try { match (value) { case Some(entry) => setVariable(key, entry) case None => removeVariable(key) } }
                            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                        }
                        try { CliConfig.invalidatePathCache() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                        try { MetisConfigManager.invalidate() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                        try { CliSettingManager.invalidate() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                        try { Config.logFile = oldLog } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                        try { gatewayLoggingResetForTest() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                    }
                }
            }
            if ((!proofSaved || !terminal || (actionCompleted && formal && proofSaved && !terminalBeforeFallback)) && firstError.isNone()) {
                firstError = Some(Exception("cr_cli_cleanup_pending"))
            }
            if (actionCompleted && formal && proofSaved && terminalBeforeFallback && terminal && firstError.isNone()) { remove(home, recursive: true) }
            else {
                try { eprintln("R-CLI formal_or_cleanup_incomplete_owned_evidence_retained") }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
        }
        if (let Some(error) <- firstError) { throw error }
    }
}

private func crCliInstalledReadBlock(file: File, buffer: Array<Byte>): Int64 {
    var used: Int64 = 0
    while (used < buffer.size) {
        let count = file.read(buffer[used..])
        if (count == 0) { break }
        used += count
    }
    used
}

private func crCliInstalledSameFiles(left: Path, right: Path): Bool {
    let leftBuffer = Array<Byte>(4096, repeat: 0)
    let rightBuffer = Array<Byte>(4096, repeat: 0)
    var equal = true
    try (leftFile = File(left, OpenMode.Read), rightFile = File(right, OpenMode.Read)) {
        while (equal) {
            let leftCount = crCliInstalledReadBlock(leftFile, leftBuffer)
            let rightCount = crCliInstalledReadBlock(rightFile, rightBuffer)
            if (leftCount != rightCount) { equal = false; break }
            if (leftCount == 0) { break }
            for (index in 0..leftCount) {
                if (leftBuffer[index] != rightBuffer[index]) { equal = false; break }
            }
        }
    }
    equal
}

@When[os == "macOS"]
private func crCliInstalledLease(fixture: CrCliFixture, expectedPid: Int64): Bool {
    try {
        let directory = fixture.home.join("service-plugin/runtime/gitcode-monitor")
        var count: Int64 = 0
        for (entry in Directory.readFrom(directory)) {
            if (!entry.name.endsWith(".lease.json")) { continue }
            if (!entry.isRegular() || entry.isSymbolicLink()) { return false }
            let lease = JsonValue.fromStr(crCliRead(entry.path)).asObject()
            if (lease.get("pid").getOrThrow().asInt().getValue() != expectedPid ||
                lease.get("state").getOrThrow().asString().getValue() != "running" ||
                lease.get("pluginId").getOrThrow().asString().getValue() != "gitcode-monitor") { return false }
            count += 1
        }
        count == 1
    } catch (_: Exception) { false }
}

@When[os == "macOS"]
private func crCliInstalledChild(kind: String): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = canonicalize(Path(getVariable("METIS_INSTALLED_HOME").getOrThrow()))
        let nonce = getVariable("METIS_INSTALLED_NONCE").getOrThrow()
        if (!home.toString().startsWith("/private/tmp/") ||
            crCliRead(home.join("installed.owner")) != "installed-runtime-v1\n" + nonce) {
            throw Exception("installed_runtime_owner_mismatch")
        }
        let oldLog = Config.logFile
        let previous = ArrayList<(String, Option<String>)>()
        for (key in ["METIS_HOME", "METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT"]) { previous.add((key, getVariable(key))) }
        setVariable("METIS_HOME", home.toString()); removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY"); removeVariable("METIS_PROCESS_RECOVERY_PARENT")
        CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
        Config.logFile = home.join("test.log").toString(); gatewayLoggingResetForTest()
        let fixture = CrCliFixture(home)
        fixture.environment["HOME"] = home.toString(); fixture.environment["TMPDIR"] = home.toString()
        var formal = false
        var terminalBeforeFallback = false
        try {
            fixture.compileInstalledFixture(); fixture.configure(false)
            let (installed, unrelated) = fixture.prepareInstalled()
            let executable = installed.join("bin/magic-cli")
            if (kind == "missing_broker") { remove(installed.join("scripts/metis-stdio-broker.mjs")) }
            if (kind == "missing_gate") { remove(installed.join("libexec/metis-exec-gate-v1")) }
            let baselineFd = crCliFdCount(); let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
            let serve = fixture.launchInstalled(executable, ["gateway", "serve"], "installed-serve", unrelated)
            var ready = false
            if (kind == "positive") { fixture.awaitReady(); ready = true }
            else {
                fixture.expectFormal(crCliWait(30000, { =>
                    let observed = fixture.identity()
                    (observed.isSome() && exists(gatewayRecoveryInventoryPath(observed.getOrThrow()).join("ready")) && crCliListening(fixture.port)) ||
                    crCliRead(home.join("gateway.log")).contains("service_plugin.process.start_failed") || !serve.isAlive()
                }))
                if (let Some(observed) <- fixture.identity()) {
                    ready = exists(gatewayRecoveryInventoryPath(observed).join("ready")) && crCliListening(fixture.port)
                    fixture.capture(observed)
                }
            }
            if (kind != "positive" && fixture.identity().isNone()) {
                let earlyRejected = fixture.recordInstalledPreGenerationRejection(serve)
                fixture.expectFormal(earlyRejected)
                File.writeTo(home.join("installed-observed-startup.json"),
                    ("{\"ready\":false,\"earlyRejected\":${earlyRejected},\"markerExecuted\":${exists(home.join("owner.pending"))}}").toArray())
                terminalBeforeFallback = fixture.terminal()
                fixture.expectFormal(terminalBeforeFallback)
                fixture.expectFormal(crCliWait(2000, { => crCliFdCount() == baselineFd &&
                    getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking }))
                formal = fixture.formalPassed()
                return
            }
            let identity = fixture.identity().getOrThrow()
            fixture.expectFormal(identity.pid == serve.pid && identity.processIdentity.isSome())
            if (kind == "positive") {
                fixture.expectFormal(crCliWait(30000, { => fixture.initializedCount() == 1 && exists(home.join("installed-env-proof.json")) }))
                let observed = JsonValue.fromStr(crCliRead(home.join("installed-env-proof.json"))).asObject()
                fixture.expectFormal(observed.get("unicode").getOrThrow().asString().getValue() == "合成安装中文😀")
                fixture.expectFormal(observed.get("dyld").getOrThrow().asString().getValue() == fixture.environment.get("DYLD_LIBRARY_PATH").getOrDefault({ => "" }))
                let pending = crCliNumber(crCliRead(home.join("owner.pending")), "pid")
                fixture.expectFormal(pending > 1 && crCliInstalledLease(fixture, pending))
                fixture.expectFormal(fixture.generationCount() == 1 && fixture.initializedCount() == 1)
            } else {
                fixture.expectFormal(crCliWait(30000, { =>
                    crCliRead(home.join("gateway.log")).contains("service_plugin.process.start_failed") ||
                    fixture.output(serve).contains("service_plugin.process.start_failed")
                }))
                fixture.expectFormal(!exists(home.join("owner.pending")) && !exists(home.join("owner.initialized")) &&
                    !exists(home.join("installed-env-proof.json")))
                fixture.expectFormal(fixture.initializedCount() == 0)
            }
            let stop = fixture.launchInstalled(executable, ["gateway", "stop"], "installed-stop", unrelated)
            fixture.expectFormal(stop.wait(timeout: Some(Duration.second * 65)) == 0)
            stop.closeStreams(); fixture.expectFormal(stop.wait() == 0 && stop.streamsAreClosed())
            let serveCode = serve.wait(timeout: Some(Duration.second * 3))
            fixture.expectFormal(serveCode >= 0 && serveCode <= 255 && (kind != "positive" || serveCode == 0))
            serve.closeStreams(); fixture.expectFormal(serve.wait() == serveCode && serve.streamsAreClosed())
            File.writeTo(home.join("installed-observed-startup.json"),
                ("{\"ready\":${ready},\"serveCode\":${serveCode},\"markerExecuted\":${exists(home.join("owner.pending"))}}").toArray())
            terminalBeforeFallback = fixture.terminal()
            fixture.expectFormal(terminalBeforeFallback)
            let completion = gatewayParseServeCompletion(crCliRead(home.join("gateway-serve.stop-complete")), identity)
            fixture.expectFormal(completion.found && completion.fullTerminal)
            fixture.expectFormal(crCliWait(2000, { => crCliFdCount() == baselineFd &&
                getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking }))
            formal = fixture.formalPassed()
        } finally {
            fixture.markFormalResult(formal)
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("kind", JsonString(kind))
            proof.put("terminalBeforeFallback", JsonBool(terminalBeforeFallback)); proof.put("recordedBeforeFallback", JsonBool(true))
            proof.put("retained", JsonBool(true)); proof.put("generations", JsonInt(fixture.generationCount()))
            proof.put("initializations", JsonInt(fixture.initializedCount()))
            proof.put("rejectedBeforeGeneration", JsonInt(fixture.installedRejectedCount()))
            File.writeTo(home.join("installed-formal-before-fallback.json"), proof.toJsonString().toArray())
            try { fixture.fallback() } finally {
                let terminal = fixture.terminal()
                File.writeTo(home.join("installed-cleanup.json"), ("{\"terminal\":${terminal},\"retained\":true}").toArray())
                if (terminal) {
                    for ((key, value) in previous) {
                        match (value) { case Some(entry) => setVariable(key, entry) case None => removeVariable(key) }
                    }
                    CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
                    gatewayLoggingResetForTest(); Config.logFile = oldLog
                }
            }
        }
    }
}

@When[os == "macOS"]
private func crCliInstalledParent(kind: String, method: String, seconds: Int64): Unit {
    let home = Directory.createTemp("/private/tmp")
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let childHome = home.join("installed child 中文😀"); Directory.create(childHome)
    File.writeTo(childHome.join("installed.owner"), ("installed-runtime-v1\n" + nonce).toArray())
    println("R-NG-B2 fixture=${home.fileName};nonce=${nonce};kind=${kind}")
    let env = HashMap<String, String>()
    for ((key, value) in getVariables()) {
        if (["PATH", "HOME", "TMPDIR", "LANG", "CANGJIE_HOME", "SDKROOT", "MAGIC_PATH", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "cjHeapSize"].contains(key)) { env[key] = value }
    }
    env["HOME"] = childHome.toString(); env["TMPDIR"] = childHome.toString()
    env["METIS_INSTALLED_CASE"] = kind; env["METIS_INSTALLED_HOME"] = childHome.toString()
    env["METIS_INSTALLED_NONCE"] = nonce; env["METIS_HOME"] = childHome.toString()
    env["METIS_CJPM_ROOT"] = canonicalize(Path(getVariable("METIS_CJPM_ROOT") ?? ".")).toString()
    env["METIS_STDIO_BROKER_NODE_COMMAND"] = managedStdioResolveNodeCommand()
    let inputPath = home.join("stdin"); File.writeTo(inputPath, [])
    var child = None<ManagedOwnedChild>
    var formal = false
    var reaped = false
    let baselineFd = crCliFdCount(); let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
    try {
        try (input = File(inputPath, OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
            let launched = launchManagedRawChild(getCommand(), ["--filter=GatewayCrashRecoveryCliE2ETest.${method}",
                "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], newGeneration: true,
                workingDirectory: Some(canonicalize(Path("."))), environment: Some<Map<String, String>>(env),
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            child = Some(launched)
            let code = launched.wait(timeout: Some(Duration.second * seconds))
            @Expect(code, 0)
            if (code != 0) { throw Exception("installed_runtime_child_failed") }
            launched.closeStreams(); reaped = launched.wait() == 0 && !launched.isAlive() && launched.streamsAreClosed()
            @Expect(reaped && !input.isClosed() && !output.isClosed() && !error.isClosed(), true)
        }
        let proof = JsonValue.fromStr(crCliRead(childHome.join("installed-formal-before-fallback.json"))).asObject()
        let cleanup = JsonValue.fromStr(crCliRead(childHome.join("installed-cleanup.json"))).asObject()
        formal = reaped && proof.get("formal").getOrThrow().asBool().getValue() &&
            proof.get("terminalBeforeFallback").getOrThrow().asBool().getValue() &&
            proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue() && cleanup.get("terminal").getOrThrow().asBool().getValue()
        @Expect(formal, true)
        let resourceReturn = crCliWait(2000, { => crCliFdCount() == baselineFd && getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking })
        @Expect(resourceReturn, true)
        if (!resourceReturn) { formal = false; throw Exception("installed_runtime_parent_resource_pending") }
    } finally {
        File.writeTo(home.join("formal-before-fallback.json"), ("{\"formal\":${formal},\"reapedBeforeFallback\":${reaped},\"recordedBeforeFallback\":true,\"retained\":true}").toArray())
        if (let Some(launched) <- child) {
            if (launched.isAlive()) { launched.terminate() }
            try { let _ = launched.wait(timeout: Some(Duration.second * 3)) } catch (_: Exception) { () }
            launched.closeStreams()
        }
    }
}

@When[os == "macOS"]
@Test
public class GatewayCrashRecoveryCliE2ETest {
    @TestCase
    public func rNgFactB1UnconsumedExecFailureAllowsActualCliRecovery(): Unit {
        if (getVariable("METIS_EXEC_UNCONSUMED_CHILD").getOrDefault({ => "" }) == "1") {
            crCliUnconsumedExecChild(); return
        }
        withCrCliFixture({ fixture =>
            fixture.configure(false)
            let baselineFd = crCliFdCount()
            let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
            let first = fixture.launchUnconsumedExecFailure()
            let old = fixture.awaitReady()
            fixture.expectFormal(crCliWait(5000, { => exists(fixture.home.join("exec-unconsumed-ready.json")) }))
            let ready = JsonValue.fromStr(crCliRead(fixture.home.join("exec-unconsumed-ready.json"))).asObject()
            fixture.expectFormal(ready.get("formalOk").getOrThrow().asBool().getValue())
            fixture.expectFormal(!ready.get("outcomeConsumed").getOrThrow().asBool().getValue())
            fixture.expectFormal(ready.get("nonce").getOrThrow().asString().getValue() == old.nonce)
            let original = File.readFrom(fixture.home.join("exec-unconsumed-original.bin"))
            let originalText = try { String.fromUtf8(original) } catch (_: Exception) { throw Exception("exec_unconsumed_original_encoding_invalid") }
            fixture.capture(old)
            fixture.killParent(first, old, false)
            let directory = gatewayRecoveryInventoryPath(old)
            let beforeRestartState = ArrayList<String>([""])
            let beforeRestartStatus = ArrayList<String>(["not_sampled"])
            let oldTerminal = crCliWait(5000, { =>
                let proof = managedRecoveryProbeRecords(directory, old.processIdentity.getOrThrow().serialize(), old.nonce,
                    MonoTime.now() + Duration.second)
                beforeRestartStatus[0] = proof.status
                if (!proof.ok || !proof.terminal || !proof.original.contains(originalText) || crCliListening(fixture.port)) { return false }
                beforeRestartState[0] = proof.original
                true
            })
            fixture.expectFormal(oldTerminal)
            if (!oldTerminal) {
                try {
                    let failure = JsonObject()
                    failure.put("recordedBeforeFallback", JsonBool(true))
                    failure.put("stage", JsonString("before_restart_source_terminal"))
                    failure.put("sourceStatus", JsonString(beforeRestartStatus[0]))
                    failure.put("formalOk", JsonBool(false))
                    File.writeTo(fixture.home.join("exec-unconsumed-first-failure.json"), failure.toJsonString().toArray())
                } catch (_: Exception) {
                    try { println("R-NG-FACT-B1 firstFailureProofSaved=false") } catch (_: Exception) { () }
                }
                throw Exception("exec_unconsumed_before_restart_source_pending")
            }
            let beforeRestart = beforeRestartState[0]
            fixture.expectFormal(!exists(fixture.home.join("gateway-serve.stop-complete")))
            File.writeTo(fixture.home.join("exec-unconsumed-old-inventory.bin"), beforeRestart.toArray())
            let restart = fixture.launchCli(["gateway", "restart"], "exec-unconsumed-restart")
            let code = restart.wait(timeout: Some(Duration.second * 90))
            fixture.expectFormal(code == 0)
            let current = fixture.awaitReady(previousNonce: old.nonce)
            fixture.expectFormal(current.nonce != old.nonce)
            fixture.expectFormal(fixture.launchCount(restart) == 1)
            fixture.expectFormal(fixture.generationCount() == 2)
            var archiveMatches = false
            for (entry in Directory.readFrom(fixture.home.join("gateway-serve.recovery-history"))) {
                if (!entry.name.endsWith(".crash-evidence")) { continue }
                let text = crCliRead(entry.path)
                if (text.contains(originalText) && text.contains("completion:missing\n") && !text.contains("completion:graceful")) {
                    archiveMatches = true
                }
            }
            fixture.expectFormal(archiveMatches)
            fixture.stopAndObserve()
            let resources = crCliWait(2000, { => crCliFdCount() == baselineFd &&
                getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking })
            fixture.expectFormal(resources)
            let proof = JsonObject()
            proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("formalOk", JsonBool(fixture.formalPassed()))
            proof.put("launchCount", JsonInt(fixture.launchCount(restart))); proof.put("archiveOriginal", JsonBool(archiveMatches))
            proof.put("oldOutcomeConsumed", JsonBool(false)); proof.put("resources", JsonBool(resources))
            File.writeTo(fixture.home.join("exec-unconsumed-formal.json"), proof.toJsonString().toArray())
            println("R-NG-FACT-B1 recovered=${fixture.formalPassed()};launchCount=${fixture.launchCount(restart)};oldOutcomeConsumed=false;archiveOriginal=${archiveMatches};resources=${resources}")
        })
    }


    @TestCase
    public func rS2InitRealServeFailuresRespectTerminalAndPendingScopes(): Unit {
        if (let Some(mode) <- getVariable("METIS_CRASH_INIT_MODE")) { crCliInitializationChild(mode); return }
        for (mode in ["early", "pending"]) {
            for (prior in ["absent", "bound"]) {
                withCrCliFixture({ fixture =>
                    fixture.configure(false)
                    let child = fixture.launchInitializationProbe(mode, prior)
                    let code = child.wait(timeout: Some(Duration.second * 75))
                    let proof = JsonValue.fromStr(crCliRead(fixture.home.join("init-formal.json"))).asObject()
                    let recorded = proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue()
                    let formal = proof.get("formalOk").getOrThrow().asBool().getValue()
                    let terminal = fixture.initializationTerminal()
                    @Expect(code, 0)
                    @Expect(recorded, true)
                    @Expect(formal, true)
                    @Expect(terminal, true)
                    fixture.markFormalResult(code == 0 && recorded && formal && terminal)
                    for (line in fixture.output(child).split("\n")) {
                        if (line.startsWith("R-S2INIT ")) { println(line) }
                    }
                })
            }
        }
    }

    @TestCase
    public func rS1C3NativeHttpThousandRootsStayBounded(): Unit {
        if (getVariable("METIS_CRASH_HTTP_C3_CHILD").getOrDefault({ => "" }) == "1") { crHttpC3Child(); return }
        withCrCliFixture({ fixture =>
            fixture.configure(false)
            let child = fixture.launchHttpComposition()
            fixture.expectFormal((child.wait(timeout: Some(Duration.second * 240))) == (0))
            let output = fixture.output(child)
            fixture.expectFormal((output.contains("R-S1-C3 actualHttp=1000;issued=1000")) == (true))
            fixture.expectFormal((output.contains("formalGoneBeforeFallback=true")) == (true))
            fixture.expectFormal((output.contains("evidence_pressure")) == (false))
            fixture.expectFormal((output.contains("fixture-only-key")) == (false))
            for (line in output.split("\n")) {
                if (line.startsWith("R-S1-C3 actualHttp=")) { println(line) }
            }
        })
    }

    @TestCase
    public func rS3N1EvidenceStatusesHaveFixedHumanDiagnostics(): Unit {
        let categories: Array<(Array<String>, String)> = [
            (["lock_invalid", "checkpoint_invalid", "checkpoint_owner_missing", "resource_intent_missing",
                "resource_identity_unknown", "inventory_invalid"], "所有权记录不完整或身份无法确认"),
            (["deadline_exceeded", "recovery_deadline_exceeded"], "核验等待超时"),
            (["claim_failed", "claim_timeout", "recovery_claim_failed"], "恢复互斥未取得"),
            (["archive_write_failed", "recovery_commit_failed"], "归档或恢复提交失败"),
            (["unsafe_path", "inventory_read_failed", "probe_failed", "permission_denied", "evidence_limit_exceeded"], "证据无法安全读取或核验")
        ]
        for ((statuses, expected) in categories) {
            for (status in statuses) {
                let output = gatewayStopOutcomeHumanText(status)
                @Expect(output.contains(expected), true)
                @Expect(output.contains("已拒绝启动"), true)
                @Expect(output.contains(status), false)
                @Expect(output.contains("\"ok\""), false)
                @Expect(output.contains("\"result\""), false)
            }
        }
        let external = String(Array<Rune>(32768, repeat: r'中')) + "😀syntheticsecret/private/fixture"
        let output = gatewayStopOutcomeHumanText(external)
        @Expect(output.contains("无法确认历史资源已全部停止"), true)
        @Expect(output.contains("syntheticsecret"), false)
        @Expect(output.contains("/private/fixture"), false)
    }

    @TestCase
    public func rS3N1HookFailuresRemainExplicitAndNeverLaunchUnknown(): Unit {
        let mode = getVariable("METIS_CRASH_CLI_HOOK_MODE").getOrDefault { "" }
        if (!mode.isEmpty()) { crCliHookChild(mode); return }
        for (kind in ["launch_false", "ready_false", "unknown", "invalid_utf8", "malformed_json", "owner_alive"]) {
            // Each negative scenario owns a distinct home and subprocess; no
            // previous malformed config/lock can contaminate the next scenario.
            withCrCliFixture({ childFixture =>
                childFixture.configure(false)
                let child = childFixture.launchHook(kind)
                childFixture.expectFormal((child.wait(timeout: Some(Duration.second * 70))) == (0))
                let output = childFixture.output(child)
                childFixture.expectFormal((output.contains("R-CLI-HOOK mode=${kind};code=1")) == (true))
                childFixture.expectFormal((output.contains("\"ok\"")) == (false))
                childFixture.expectFormal((output.contains("\"result\"")) == (false))
                childFixture.expectFormal((output.contains("syntheticsecret")) == (false))
                childFixture.expectFormal((output.contains(childFixture.home.toString())) == (false))
                if (kind == "ready_false") { childFixture.expectFormal((output.contains("未在期限内确认就绪")) == (true)) }
                if (kind == "launch_false") { childFixture.expectFormal((output.contains("启动") && output.contains("失败")) == (true)) }
                if (kind == "unknown" || kind == "owner_alive") { childFixture.expectFormal((output.contains("已拒绝启动")) == (true)) }
                if ((kind == "unknown" || kind == "owner_alive") && childFixture.formalPassed()) {
                    let receipt = JsonValue.fromStr(crCliRead(childFixture.home.join("hook-owner-wait.json"))).asObject()
                    let ownerReaped = receipt.get("directOwnerWaitCompleted").getOrThrow().asBool().getValue()
                    childFixture.expectFormal(ownerReaped && receipt.get("mode").getOrThrow().asString().getValue() == kind &&
                        receipt.get("hadOwner").getOrThrow().asBool().getValue() == (kind == "owner_alive"))
                    let seeded = childFixture.identity().getOrThrow()
                    let expected = ProcessInstanceIdentity(currentProcessInstanceIdentity().getOrThrow().platform, 987654321)
                    childFixture.expectFormal(seeded.pid == 987654321 && seeded.startedAtMs == 1000 && seeded.nonce == "unit-crash-中文😀" &&
                        seeded.processIdentity.getOrThrow().serialize() == expected.serialize())
                    if (childFixture.formalPassed()) {
                        let source = gatewayRecoveryInventoryPath(seeded)
                        let fields = managedRecoveryParseFields(crCliRead(source.join("inventory"))).getOrThrow()
                        childFixture.expectFormal(fields.get("parent") == Some(expected.serialize()) && fields.get("binding") == Some(seeded.nonce))
                        if (childFixture.formalPassed()) {
                            crCliSnapshotFlat(source, childFixture.home.join("hook-fault-inventory"))
                            File.writeTo(childFixture.home.join("hook-fault-lock.bin"), File.readFrom(childFixture.home.join("gateway-serve.lock")))
                            // This fixed synthetic parent was never an OS process.
                            // The real owner, if present, has its own wait receipt above.
                            remove(source, recursive: true)
                            remove(childFixture.home.join("gateway-serve.lock"))
                        }
                    }
                }
            })
        }
    }

    @TestCase
    public func e2eR01ActualAbortRestartReachesNewReady(): Unit {
        withCrCliFixture({ fixture =>
            fixture.compileFixture(); fixture.configure(false)
            let first = fixture.launchCli(["gateway", "run"], "serve")
            let old = fixture.awaitReady()
            fixture.killParent(first, old, true)
            let restart = fixture.launchCli(["gateway", "restart"], "restart")
            fixture.expectFormal((restart.wait(timeout: Some(Duration.second * 90))) == (0))
            let current = fixture.awaitReady(previousNonce: old.nonce)
            fixture.expectFormal((current.nonce != old.nonce) == (true))
            fixture.expectFormal((fixture.generationCount()) == (2)); fixture.expectFormal((fixture.initializedCount()) == (2))
            fixture.expectFormal((fixture.launchCount(restart)) == (1))
            println("E2E-R01 oldPid=${old.pid};newPid=${current.pid};nonceChanged=true;launchCount=${fixture.launchCount(restart)}")
            var archived = false
            for (entry in Directory.readFrom(fixture.home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".crash-evidence")) { archived = crCliRead(entry.path).contains("completion:missing") }
            }
            fixture.expectFormal((archived) == (true))
            fixture.expectFormal((fixture.output(restart).contains("主进程已退出但子进程清理未完成")) == (false))
            fixture.stopAndObserve()
        })
    }

    @TestCase
    public func rS3B1SecondRealCliDuringNewLockBeforeReadyLaunchesOnce(): Unit {
        withCrCliFixture({ fixture =>
            let checkStep = { step: String, ok: Bool =>
                println("R-S3-B1 step=${step};ok=${ok}")
                fixture.expectFormal(ok)
            }
            fixture.compileFixture(); fixture.configure(false)
            let first = fixture.launchCli(["gateway", "run"], "serve")
            let old = fixture.awaitReady()
            fixture.killParent(first, old, false)
            remove(fixture.home.join("initialize.release"))
            let one = fixture.launchCli(["gateway", "restart"], "restart-one")
            checkStep("new_lock_before_ready", (crCliWait(30000, { =>
                match (fixture.identity()) {
                    case Some(value) => value.nonce != old.nonce &&
                        crCliNumber(crCliRead(fixture.home.join("owner.pending")), "pid") !=
                            crCliNumber(crCliRead(fixture.home.join("owner.initialized")).split("\n")[0], "pid")
                    case None => false
                }
            })) == (true))
            let newNonce = fixture.identity().getOrThrow().nonce
            checkStep("first_ready_absent", (exists(gatewayRecoveryInventoryPath(fixture.identity().getOrThrow()).join("ready"))) == (false))
            let two = fixture.launchCli(["gateway", "restart"], "restart-two")
            // The normal progress line is emitted after nonce/epoch snapshot
            // and before the restart claim, so this proves the second CLI
            // entered precisely while the new generation is still unready.
            checkStep("second_entered_before_release", (crCliWait(5000, { => fixture.output(two).contains("正在核验并等待网关重启互斥") })) == (true))
            checkStep("second_alive_before_release", (two.isAlive()) == (true))
            checkStep("second_ready_absent", (exists(gatewayRecoveryInventoryPath(fixture.identity().getOrThrow()).join("ready"))) == (false))
            File.writeTo(fixture.home.join("initialize.release"), "release".toArray())
            checkStep("first_exit_zero", (one.wait(timeout: Some(Duration.second * 90))) == (0))
            checkStep("second_exit_zero", (two.wait(timeout: Some(Duration.second * 90))) == (0))
            checkStep("same_new_nonce", (fixture.awaitReady(previousNonce: old.nonce).nonce) == (newNonce))
            checkStep("two_generations", (fixture.generationCount()) == (2))
            checkStep("two_initializations", (fixture.initializedCount()) == (2))
            checkStep("one_new_launch", (fixture.launchCount(one) + fixture.launchCount(two)) == (1))
            println("R-S3-B1 cli1=${one.pid};cli2=${two.pid};launchCount=${fixture.launchCount(one) + fixture.launchCount(two)};generations=${fixture.generationCount()}")
            fixture.stopAndObserve()
        })
    }

    @TestCase
    public func e2eR02KillParentWaitsForGrandchildTreeBeforeReady(): Unit {
        withCrCliFixture({ fixture =>
            fixture.compileFixture(); fixture.configure(true)
            let first = fixture.launchCli(["gateway", "run"], "serve")
            let old = fixture.awaitReady()
            let child = crCliNumber(crCliRead(fixture.home.join("owner.pending")), "grandchildPid")
            let oldGroup = crCliNumber(crCliRead(fixture.home.join("owner.pending")), "pgid")
            fixture.expectFormal((child > 1) == (true))
            let childBirth = observeProcessBirthIdentity(child).getOrThrow()
            fixture.killParent(first, old, false)
            File.writeTo(fixture.home.join("old.pgid"), "${oldGroup}".toArray())
            let restart = fixture.launchCli(["gateway", "restart"], "restart")
            fixture.expectFormal((restart.wait(timeout: Some(Duration.second * 90))) == (0))
            fixture.awaitReady(previousNonce: old.nonce)
            let gone = probeProcessBirthIdentity(childBirth, MonoTime.now() + Duration.second)
            fixture.expectFormal((gone.conclusive && !gone.alive) == (true))
            fixture.expectFormal((exists(fixture.home.join("owner.overlap"))) == (false))
            fixture.expectFormal((fixture.generationCount()) == (2)); fixture.expectFormal((fixture.initializedCount()) == (2))
            fixture.expectFormal((fixture.launchCount(restart)) == (1))
            println("E2E-R02 oldPid=${old.pid};oldGrandchild=${child};oldPgid=${oldGroup};oldGoneAfterRestartReady=${gone.conclusive && !gone.alive}")
            fixture.stopAndObserve()
        })
    }

    @TestCase
    public func e2eR04LegacyWithoutInventoryBlocksActualCli(): Unit {
        withCrCliFixture({ fixture =>
            fixture.compileFixture(); fixture.configure(false)
            let first = fixture.launchCli(["gateway", "run"], "serve")
            let old = fixture.awaitReady()
            fixture.killParent(first, old, false)
            let original = crCliRead(fixture.home.join("gateway-serve.lock"))
            let inventory = gatewayRecoveryInventoryPath(old)
            let parent = probeProcessInstance(old.processIdentity.getOrThrow(), MonoTime.now() + Duration.second)
            let terminalBeforeRemoval = crCliWait(5000, { =>
                let resources = managedRecoveryProbeRecords(inventory, old.processIdentity.getOrThrow().serialize(), old.nonce,
                    MonoTime.now() + Duration.second)
                parent.conclusive && !parent.alive && resources.ok && resources.terminal
            })
            fixture.expectFormal(terminalBeforeRemoval)
            if (!terminalBeforeRemoval) { throw Exception("legacy_fixture_original_inventory_not_terminal") }
            let snapshot = fixture.home.join("legacy-original-inventory")
            crCliSnapshotFlat(inventory, snapshot)
            File.writeTo(fixture.home.join("legacy-original-terminal-proof"), "originalParentGone=true\noriginalInventoryTerminal=true\n".toArray())
            remove(inventory, recursive: true)
            File.writeTo(fixture.home.join("legacy-missing-scene"), "inventoryMissing=true\ncompletionMissing=true\n".toArray())
            let restart = fixture.launchCli(["gateway", "restart"], "legacy-restart")
            fixture.expectFormal((restart.wait(timeout: Some(Duration.second * 65))) == (1))
            fixture.expectFormal((fixture.output(restart).contains("旧版记录缺少资源清单")) == (true))
            fixture.expectFormal((crCliRead(fixture.home.join("gateway-serve.lock"))) == (original))
            fixture.expectFormal((fixture.initializedCount()) == (1)); fixture.expectFormal((fixture.generationCount()) == (0))
            fixture.expectFormal((fixture.launchCount(restart)) == (0))
            fixture.expectFormal((exists(fixture.home.join("gateway-serve.stop-complete"))) == (false))
            if (fixture.formalPassed()) {
                // Restore the exact pre-fault source bytes, never fabricate a
                // completion or terminal fact to make fixture cleanup succeed.
                Directory.create(inventory)
                for (entry in Directory.readFrom(snapshot)) { File.writeTo(inventory.join(entry.name), File.readFrom(entry.path)) }
                fixture.expectFormal(fixture.terminal())
            }
        })
    }

    @TestCase
    public func rS2P4InterruptedShutdownCompletionRestartsThroughActualCli(): Unit {
        withCrCliFixture({ fixture =>
            fixture.configure(false)
            let source = fixture.producePendingCompletion()
            let old = source[0]
            let before = fixture.generationCount()
            let proof = JsonObject(); proof.put("formalOk", JsonBool(false))
            try {
                let restart = fixture.launchCli(["gateway", "restart"], "pending-restart")
                let code = restart.wait(timeout: Some(Duration.second * 90))
                fixture.expectFormal((code) == (0))
                let current = fixture.awaitReady(previousNonce: old.nonce)
                let launches = fixture.launchCount(restart)
                let archiveMatches = crCliInterruptedArchiveMatches(fixture.home, source[1])
                let changed = current.nonce != old.nonce
                let added = fixture.generationCount() - before
                fixture.expectFormal((launches) == (1)); fixture.expectFormal((added) == (1)); fixture.expectFormal((changed) == (true))
                fixture.expectFormal((archiveMatches) == (true))
                fixture.expectFormal((exists(fixture.home.join("gateway-serve.stop-complete"))) == (false))
                fixture.stopAndObserve()
                let terminal = fixture.terminal()
                let formal = code == 0 && launches == 1 && added == 1 && changed && archiveMatches && terminal
                proof.put("formalOk", JsonBool(formal)); proof.put("archiveBytesMatch", JsonBool(archiveMatches))
                proof.put("newNonceReady", JsonBool(changed)); proof.put("launchCount", JsonInt(launches))
                proof.put("addedGenerations", JsonInt(added)); proof.put("ownedTerminal", JsonBool(terminal))
                fixture.expectFormal((formal) == (true))
                println("R-S2-P4 code=${code};launchCount=${launches};addedGenerations=${added};newNonceReady=${changed};archiveBytesMatch=${archiveMatches};ownedTerminalBeforeFallback=${terminal}")
            } finally {
                proof.put("recordedBeforeFallback", JsonBool(true))
                File.writeTo(fixture.home.join("pending-restart-formal.json"), proof.toJsonString().toArray())
            }
        })
    }

    @TestCase
    public func rS2N5InvalidPendingCompletionNeverLaunchesOrRetires(): Unit {
        for (mode in ["wrong_nonce", "malformed", "invalid_utf8"]) {
            withCrCliFixture({ fixture =>
                fixture.configure(false)
                let source = fixture.producePendingCompletion()
                let old = source[0]
                let directory = gatewayRecoveryInventoryPath(old)
                let header = File.readFrom(directory.join("inventory"))
                let inventory = crCliPendingInventorySnapshot(old)
                let before = fixture.generationCount()
                let replacement = crCliPendingReplacement(source[1], old.nonce, mode)
                let path = fixture.home.join("gateway-serve.stop-complete")
                File.writeTo(path, replacement)
                var child = None<ManagedOwnedChild>
                var formal = false
                var launches: Int64 = 0
                var sameLock = false
                var sameCompletion = false
                var sameInventory = false
                try {
                    let restart = fixture.launchCli(["gateway", "restart"], "invalid-pending-${mode}")
                    child = Some(restart)
                    let code = restart.wait(timeout: Some(Duration.second * 90))
                    let output = fixture.output(restart)
                    launches = fixture.launchCount(restart)
                    sameLock = crCliRead(fixture.home.join("gateway-serve.lock")) == source[2]
                    sameCompletion = crCliSameBytes(File.readFrom(path), replacement)
                    sameInventory = crCliSameBytes(File.readFrom(directory.join("inventory")), header) &&
                        crCliPendingInventorySnapshot(old) == inventory && fixture.generationCount() == before
                    let human = output.contains("已拒绝启动") && !output.contains("syntheticsecret") &&
                        !output.contains(fixture.home.toString()) && !output.contains("\"ok\"") && !output.contains("\"result\"") && output.size < 8192
                    let unchangedReady = fixture.identity().map({ value => value.matches(old) }).getOrDefault({ => false })
                    formal = code == 1 && launches == 0 && sameLock && sameCompletion && sameInventory && human && unchangedReady
                    fixture.expectFormal((code) == (1)); fixture.expectFormal((launches) == (0))
                    fixture.expectFormal((sameLock && sameCompletion && sameInventory && human && unchangedReady) == (true))
                    println("R-S2-N5-C mode=${mode};code=${code};launchCount=${launches};sameLock=${sameLock};sameCompletion=${sameCompletion};sameInventory=${sameInventory};humanBounded=${human};formalBeforeFallback=${formal}")
                } finally {
                    crCliRecordPendingProof(fixture.home, "pending-invalid-${mode}", formal, launches, sameLock, sameCompletion, sameInventory)
                    crCliSavePendingInputs(fixture.home, "pending-invalid-${mode}", source[1], replacement)
                    fixture.markFormalResult(formal)
                    if (let Some(process) <- child) {
                        if (process.isAlive()) { process.terminate(force: true) }
                        let _ = process.wait(timeout: Some(Duration.second * 3))
                        if (formal && !process.isAlive()) { File.writeTo(path, source[1]) }
                    }
                }
            })
        }
    }

    @TestCase
    public func rS2N5ReplacedPendingCompletionCannotBeRetired(): Unit {
        withCrCliFixture({ fixture =>
            fixture.configure(false)
            let source = fixture.producePendingCompletion()
            let old = source[0]
            let directory = gatewayRecoveryInventoryPath(old)
            let header = File.readFrom(directory.join("inventory"))
            let inventory = crCliPendingInventorySnapshot(old)
            let before = fixture.generationCount()
            let path = fixture.home.join("gateway-serve.stop-complete")
            let replacement = crCliPendingReplacement(source[1], old.nonce, "wrong_nonce")
            var formal = false
            var sameLock = false
            var sameCompletion = false
            var sameInventory = false
            try {
                let preview = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second * 5)
                fixture.expectFormal((preview.status) == ("recoverable"))
                fixture.expectFormal((preview.kind) == ("interrupted_shutdown"))
                let original = preview.originalCompletion.getOrThrow()
                fixture.expectFormal((crCliSameBytes(original.toArray(), source[1])) == (true))
                let result = gatewayCommitCrashRecovery(preview, MonoTime.now() + Duration.second * 5,
                    afterArchive: { => File.writeTo(path, replacement) })
                sameLock = crCliRead(fixture.home.join("gateway-serve.lock")) == source[2]
                sameCompletion = crCliSameBytes(File.readFrom(path), replacement)
                sameInventory = crCliSameBytes(File.readFrom(directory.join("inventory")), header) &&
                    crCliPendingInventorySnapshot(old) == inventory && fixture.generationCount() == before
                formal = !result.ok && sameLock && sameCompletion && sameInventory
                fixture.expectFormal((result.ok) == (false))
                fixture.expectFormal((sameLock && sameCompletion && sameInventory) == (true))
                println("R-S2-N5-U rejected=${!result.ok};launchCount=0;sameLock=${sameLock};sameCompletion=${sameCompletion};sameInventory=${sameInventory};formalBeforeFallback=${formal}")
            } finally {
                crCliRecordPendingProof(fixture.home, "pending-replaced", formal, 0, sameLock, sameCompletion, sameInventory)
                crCliSavePendingInputs(fixture.home, "pending-replaced", source[1], replacement)
                fixture.markFormalResult(formal)
                if (formal) { File.writeTo(path, source[1]) }
            }
        })
    }
    @TestCase
    public func rNgB2InstalledForegroundServeAndStop(): Unit {
        if (getVariable("METIS_INSTALLED_CASE") == Some("positive")) { crCliInstalledChild("positive"); return }
        crCliInstalledParent("positive", "rNgB2InstalledForegroundServeAndStop", 180)
    }

    @TestCase
    public func rNgB2MissingBrokerRefusesDependentLaunch(): Unit {
        if (getVariable("METIS_INSTALLED_CASE") == Some("missing_broker")) { crCliInstalledChild("missing_broker"); return }
        crCliInstalledParent("missing_broker", "rNgB2MissingBrokerRefusesDependentLaunch", 120)
    }

    @TestCase
    public func rNgB2MissingGateRefusesDependentLaunch(): Unit {
        if (getVariable("METIS_INSTALLED_CASE") == Some("missing_gate")) { crCliInstalledChild("missing_gate"); return }
        crCliInstalledParent("missing_gate", "rNgB2MissingGateRefusesDependentLaunch", 120)
    }

}
