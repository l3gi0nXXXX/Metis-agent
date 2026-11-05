package metis.gateway.runtime

import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import magic.utils.http.{HttpProcessLaunchProvider, HttpProcessLaunchSpec, setHttpProcessLaunchProvider}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager,
    cliProviderApiKeyEnvAliases, cliProviderBaseUrlEnvAliases}
import metis.process.{ProcessBirthIdentity, currentProcessInstanceIdentity, observeProcessBirthIdentity,
    managedRecoveryContext, managedRecoveryNativeIntent, managedRecoveryNativeTerminal,
    managedRecoveryProbeRecords, managedRecoveryParseFields}
import std.collection.HashMap
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, OpenMode, Path, canonicalize, exists, remove}
import std.net.{TcpServerSocket, TcpSocket, IPSocketAddress}
import std.process.{ProcessRedirect, SubProcess, launch}
import std.sync.AtomicInt64
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func pendingInventoryRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_response_encoding" }
}

private func pendingInventoryPort(): Int64 {
    var port: Int64 = 0
    try (server = TcpServerSocket(bindAt: 0u16)) {
        server.bind()
        port = Int64((server.localAddress as IPSocketAddress).getOrThrow().port)
    }
    port
}

private func pendingInventoryListening(port: Int64): Bool {
    var listening = false
    try (socket = TcpSocket("127.0.0.1", UInt16(port))) {
        socket.connect(timeout: Duration.millisecond * 100)
        listening = true
    } catch (_: Exception) { () }
    listening
}

private func pendingInventoryHealth(port: Int64): Bool {
    var healthy = false
    try (socket = TcpSocket("127.0.0.1", UInt16(port))) {
        socket.connect(timeout: Duration.millisecond * 200)
        socket.readTimeout = Some(Duration.millisecond * 500)
        socket.write("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".toArray())
        let buffer = Array<Byte>(1024, repeat: 0)
        let count = socket.read(buffer)
        let text = try { String.fromUtf8(buffer[..count]) } catch (_: Exception) { return false }
        healthy = text.startsWith("HTTP/1.1 200") || text.startsWith("HTTP/1.0 200")
    } catch (_: Exception) { () }
    healthy
}

private func pendingInventoryWait(millis: Int64, condition: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.millisecond * millis
    while (MonoTime.now() < deadline) {
        if (condition()) { return true }
        sleep(Duration.millisecond * 20)
    }
    condition()
}

private func pendingInventoryRequestStop(home: Path, identity: GatewayServeIdentity): Bool {
    let text = pendingInventoryRead(home.join("gateway-serve.lock"))
    let current = gatewayParseServeIdentity(text)
    if (current.isNone() || !current.getOrThrow().matches(identity)) { return false }
    // Copy the actual live generation identity; the fixture never invents an audit identity.
    File.writeTo(home.join("gateway-serve.stop-request"),
        (text + "requestedAtMs:${DateTime.now().toUnixTimeStamp().toMilliseconds()}\n").toArray())
    gatewayServeStopRequested(identity)
}

private class PendingInventoryPriorProcess <: ProcessLaunchProvider {
    let calls = AtomicInt64(0)
    public func launch(_command: String, _args: Array<String>, _env: Array<(String, String)>, _error: Bool): ProcessHandle {
        this.calls.fetchAdd(1)
        throw Exception("pending_inventory_prior_provider")
    }
}

private class PendingInventoryPriorHttp <: HttpProcessLaunchProvider {
    let calls = AtomicInt64(0)
    public func prepare(_command: String, _args: Array<String>): HttpProcessLaunchSpec {
        this.calls.fetchAdd(1)
        throw Exception("pending_inventory_prior_provider")
    }
}

@When[os == "macOS"]
private func pendingInventoryChild(): Unit {
    let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
    let nonce = getVariable("METIS_PENDING_INVENTORY_NONCE").getOrThrow()
    let port = Int64.parse(getVariable("METIS_PENDING_INVENTORY_PORT").getOrThrow())
    if (!home.toString().startsWith("/private/tmp/") || nonce.isEmpty() ||
        pendingInventoryRead(home.join("pending-inventory.owner")) != "pending-inventory-v1\n" + nonce) {
        throw Exception("pending_inventory_child_not_owned")
    }
    CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
    let priorProcess = PendingInventoryPriorProcess()
    let priorHttp = PendingInventoryPriorHttp()
    let previousProcess = setProcessLaunchProvider(Some<ProcessLaunchProvider>(priorProcess))
    let previousHttp = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(priorHttp))
    let previousDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let previousParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let proof = JsonObject()
    proof.put("formalOk", JsonBool(false))
    var reserved = ""
    var ownedContext = ("", "")
    var identity = None<GatewayServeIdentity>
    CliConfig.model = "openai:fixture"
    var serve = None<Future<Int64>>
    var launchPending = false
    var firstError = None<Exception>
    try {
        launchPending = true
        serve = Some(spawn { runGatewayService() })
        launchPending = false
        if (!pendingInventoryWait(20000, { =>
            match (gatewayReadServeIdentity()) {
                case Some(value) =>
                    value.pid == getProcessId() && exists(gatewayRecoveryInventoryPath(value).join("ready")) && pendingInventoryHealth(port)
                case None => false
            }
        })) { throw Exception("pending_inventory_ready_timeout") }
        let active = gatewayReadServeIdentity().getOrThrow()
        identity = Some(active)
        let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        let directory = gatewayRecoveryInventoryPath(active)
        let header = managedRecoveryParseFields(pendingInventoryRead(directory.join("inventory"))).getOrThrow()
        @Expect(header["parent"], parent)
        @Expect(header["binding"], active.nonce)
        @Expect(pendingInventoryRead(directory.join("ready")), "managed-recovery-ready-v1\nparent:${parent}\nbinding:${active.nonce}\n")
        ownedContext = managedRecoveryContext()
        @Expect(ownedContext[0], directory.toString())
        @Expect(ownedContext[1], parent)
        // Reserve a real intent, but never launch an OS resource for this key.
        reserved = managedRecoveryNativeIntent(context: ownedContext)
        @Expect(reserved.isEmpty(), false)
        @Expect(pendingInventoryRequestStop(home, active), true)
        let _ = serve.getOrThrow().get(Duration.second * 65)

        let inventory = managedRecoveryProbeRecords(directory, parent, active.nonce, MonoTime.now() + Duration.second * 3)
        let completionText = pendingInventoryRead(home.join("gateway-serve.stop-complete"))
        let completion = gatewayParseServeCompletion(completionText, active)
        let retained = gatewayReadServeIdentity().map({ value => value.matches(active) }).getOrDefault({ => false })
        let processProvider = setProcessLaunchProvider(None<ProcessLaunchProvider>)
        let _ = setProcessLaunchProvider(processProvider)
        let httpProvider = setHttpProcessLaunchProvider(None<HttpProcessLaunchProvider>)
        let _ = setHttpProcessLaunchProvider(httpProvider)
        let processStatus = try { let _ = processProvider.getOrThrow().launch("/usr/bin/true", [], [], true); "unexpected_success" }
            catch (error: Exception) { error.message }
        let httpStatus = try { let _ = httpProvider.getOrThrow().prepare("/usr/bin/true", []); "unexpected_success" }
            catch (error: Exception) { error.message }
        let fenced = processStatus == "process_recovery_generation_closing" && httpStatus == "process_recovery_generation_closing" &&
            priorProcess.calls.load() == 0 && priorHttp.calls.load() == 0
        let portGone = !pendingInventoryListening(port)
        let beforeCount = Directory.readFrom(home.join("gateway-resource-inventory")).size
        // A broken first shutdown must fail immediately, never start a second live serve.
        let secondRefused = if (completion.found && !completion.fullTerminal && retained && fenced) {
            runGatewayService() == 1
        } else { false }
        let afterCount = Directory.readFrom(home.join("gateway-resource-inventory")).size
        let sameProcess = setProcessLaunchProvider(None<ProcessLaunchProvider>)
        let _ = setProcessLaunchProvider(sameProcess)
        let sameHttp = setHttpProcessLaunchProvider(None<HttpProcessLaunchProvider>)
        let _ = setHttpProcessLaunchProvider(sameHttp)
        let unchanged = refEq((processProvider.getOrThrow() as Object).getOrThrow(), (sameProcess.getOrThrow() as Object).getOrThrow()) &&
            refEq((httpProvider.getOrThrow() as Object).getOrThrow(), (sameHttp.getOrThrow() as Object).getOrThrow()) && beforeCount == afterCount &&
            gatewayReadServeIdentity().map({ value => value.matches(active) }).getOrDefault({ => false }) &&
            priorProcess.calls.load() == 0 && priorHttp.calls.load() == 0
        let formal = !inventory.terminal && inventory.status == "resource_intent_incomplete" && completion.found && !completion.fullTerminal && completion.status == "cleanup_pending" &&
            retained && fenced && portGone && secondRefused && unchanged && managedRecoveryContext() == ownedContext
        proof.put("formalOk", JsonBool(formal))
        proof.put("fullTerminal", JsonBool(completion.fullTerminal))
        proof.put("inventoryTerminal", JsonBool(inventory.terminal))
        proof.put("lockRetained", JsonBool(retained)); proof.put("providerFenced", JsonBool(fenced))
        proof.put("portGone", JsonBool(portGone)); proof.put("secondRefused", JsonBool(secondRefused && unchanged))
        @Expect(formal, true)
        println("R-S2-N4 formalBeforeFallback=${formal};inventoryTerminal=${inventory.terminal};fullTerminal=${completion.fullTerminal};lockRetained=${retained};providerFenced=${fenced};portGone=${portGone};secondRefused=${secondRefused && unchanged}")
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        var joined = serve.isNone() && !launchPending
        try {
            proof.put("recordedBeforeFallback", JsonBool(true))
            File.writeTo(home.join("pending-inventory-formal.json"), proof.toJsonString().toArray())
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        finally {
            try {
                // Only this exact key was never spawned; retire it truthfully after formal evidence.
                if (!reserved.isEmpty()) { managedRecoveryNativeTerminal(reserved, 0, 0, false, true, context: ownedContext) }
            } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            try { if (let Some(value) <- identity) { let _ = pendingInventoryRequestStop(home, value) } }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            try { if (let Some(worker) <- serve) { let _ = worker.get(Duration.second * 5); joined = true } }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try { let _ = setProcessLaunchProvider(previousProcess) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { let _ = setHttpProcessLaunchProvider(previousHttp) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                for ((key, value) in [("METIS_PROCESS_RECOVERY_DIRECTORY", previousDirectory), ("METIS_PROCESS_RECOVERY_PARENT", previousParent)]) {
                    try { match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) } }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
            }
        }
        if ((!joined || launchPending) && firstError.isNone()) { firstError = Some(Exception("pending_inventory_cleanup_pending")) }
    }
    if (let Some(error) <- firstError) { throw error }
}

private func pendingInventoryConfiguration(home: Path, port: Int64): Unit {
    let gateway = JsonObject()
    gateway.put("enabled", JsonBool(true)); gateway.put("port", JsonInt(port)); gateway.put("bind", JsonString("loopback"))
    gateway.put("cronEnabled", JsonBool(false)); gateway.put("gatewayPlugins", JsonArray()); gateway.put("servicePlugins", JsonArray())
    let disabled = JsonObject(); disabled.put("enabled", JsonBool(false))
    for (key in ["controlUi", "canvas", "telegram", "feishu", "qq"]) { gateway.put(key, disabled) }
    let auth = JsonObject(); auth.put("mode", JsonString("token")); auth.put("token", JsonString("fixture-only-token")); gateway.put("auth", auth)
    let enabled = JsonObject(); enabled.put("enabled", JsonBool(true))
    let endpoints = JsonObject(); endpoints.put("chatCompletions", enabled)
    let http = JsonObject(); http.put("endpoints", endpoints); gateway.put("http", http)
    let defaults = JsonObject(); defaults.put("workspace", JsonString(home.join("workspace").toString()))
    let model = JsonObject(); model.put("primary", JsonString("openai:fixture")); defaults.put("model", model)
    let agents = JsonObject(); agents.put("defaults", defaults)
    let root = JsonObject(); root.put("gateway", gateway); root.put("agents", agents)
    File.writeTo(home.join("metis.json"), root.toJsonString().toArray())
}

@When[os == "macOS"]
@Test
public class GatewayCrashRecoveryPendingInventoryTest {
    @TestCase
    public func realServeIncompleteIntentNeverPublishesTerminal(): Unit {
        if (getVariable("METIS_PENDING_INVENTORY_CHILD").getOrDefault({ => "" }) == "1") { pendingInventoryChild(); return }
        let home = canonicalize(Directory.createTemp("/private/tmp"))
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        var port = pendingInventoryPort()
        while ([18080, 18788].contains(port)) { port = pendingInventoryPort() }
        pendingInventoryConfiguration(home, port)
        File.writeTo(home.join("pending-inventory.owner"), ("pending-inventory-v1\n" + nonce).toArray())
        let environment = HashMap<String, String>(getVariables())
        for (key in environment.keys().toArray()) {
            if (key.endsWith("_API_KEY") || key.endsWith("_TOKEN") || key.startsWith("METIS_PROCESS_RECOVERY_") ||
                ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                 "METIS_GATEWAY_CLI_MODE", "METIS_STDIO_BROKER_SCRIPT"].contains(key)) { environment.remove(key) }
        }
        let project = canonicalize(Path("."))
        environment["METIS_HOME"] = home.toString(); environment["METIS_LOG_FILE"] = home.join("gateway.log").toString()
        environment["METIS_CONSOLE_LEVEL"] = "off"; environment["METIS_CJPM_ROOT"] = project.toString()
        environment["METIS_STDIO_BROKER_SCRIPT"] = project.join("scripts/metis-stdio-broker.mjs").toString()
        environment["METIS_PENDING_INVENTORY_CHILD"] = "1"; environment["METIS_PENDING_INVENTORY_NONCE"] = nonce
        environment["METIS_PENDING_INVENTORY_PORT"] = port.toString(); environment["cjHeapSize"] = "2GB"
        let curl = home.join("curl"); Directory.create(curl)
        File.writeTo(curl.join(".curlrc"), []); File.writeTo(curl.join("curlrc"), [])
        environment["CURL_HOME"] = curl.toString(); environment["XDG_CONFIG_HOME"] = curl.toString()
        for (key in cliProviderApiKeyEnvAliases("openai")) { environment[key] = "fixture-only-key" }
        for (key in cliProviderBaseUrlEnvAliases("openai")) { environment[key] = "http://127.0.0.1:${port}/v1" }
        var child = None<SubProcess>
        var birth = None<ProcessBirthIdentity>
        var passed = false
        var reaped = false
        var launchPending = false
        var firstError = None<Exception>
        try {
            try (input = File("/dev/null", OpenMode.Read), output = File(home.join("child.stdout"), OpenMode.Write),
                error = File(home.join("child.stderr"), OpenMode.Write)) {
                launchPending = true
                let process = launch(getCommand(), ["--filter=GatewayCrashRecoveryPendingInventoryTest.realServeIncompleteIntentNeverPublishesTerminal",
                    "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"], environment: environment,
                    workingDirectory: Some(project), stdIn: ProcessRedirect.FromFile(input),
                    stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
                child = Some(process); launchPending = false; birth = observeProcessBirthIdentity(process.pid)
            }
            let childCode = child.getOrThrow().wait(timeout: Some(Duration.second * 100))
            reaped = childCode >= 0 && childCode <= 255
            @Expect(childCode, 0)
            let formal = JsonValue.fromStr(pendingInventoryRead(home.join("pending-inventory-formal.json"))).asObject()
            @Expect(formal.get("recordedBeforeFallback").getOrThrow().asBool().getValue(), true)
            @Expect(formal.get("formalOk").getOrThrow().asBool().getValue(), true)
            passed = childCode == 0 && formal.get("formalOk").getOrThrow().asBool().getValue() &&
                formal.get("recordedBeforeFallback").getOrThrow().asBool().getValue()
            println("R-S2-N4 childCode=${childCode};formalBeforeFallback=${passed}")
        } catch (error: Exception) { firstError = Some(error) }
        finally {
            var terminal = false
            try {
                File.writeTo(home.join("parent-formal-before-fallback.json"),
                    ("{\"formal\":${passed},\"recordedBeforeFallback\":true,\"reaped\":${reaped},\"launchPending\":${launchPending}}").toArray())
            } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                if (let Some(process) <- child) {
                    try {
                        if (!reaped && process.isAlive() && birth.isSome() && observeProcessBirthIdentity(process.pid)?.serialize() == birth?.serialize() &&
                            pendingInventoryRead(home.join("pending-inventory.owner")) == "pending-inventory-v1\n" + nonce) {
                            // Only the returned, still-unreaped direct handle is eligible.
                            process.terminate(force: true)
                        }
                    } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                    try {
                        if (!reaped) { let code = process.wait(timeout: Some(Duration.second * 5)); reaped = code >= 0 && code <= 255 }
                    } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
                try {
                    terminal = reaped && !launchPending && child.isSome() && !child.getOrThrow().isAlive() && !pendingInventoryListening(port)
                    let inventories = home.join("gateway-resource-inventory")
                    if (exists(inventories)) {
                        for (entry in Directory.readFrom(inventories)) {
                            let header = managedRecoveryParseFields(pendingInventoryRead(entry.path.join("inventory")))
                            if (header.isNone()) { terminal = false; continue }
                            let fields = header.getOrThrow()
                            let result = managedRecoveryProbeRecords(entry.path, fields["parent"], fields["binding"], MonoTime.now() + Duration.second * 3)
                            if (!result.ok || !result.terminal) { terminal = false }
                        }
                    }
                } catch (error: Exception) { terminal = false; if (firstError.isNone()) { firstError = Some(error) } }
            }
            @Expect(terminal, true)
            if (!terminal && firstError.isNone()) { firstError = Some(Exception("pending_inventory_cleanup_pending")) }
            if (terminal && passed && firstError.isNone()) { remove(home, recursive: true) }
            else {
                try { println("R-S2-N4 owned_failure_evidence_retained") }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
        }
        if (let Some(error) <- firstError) { throw error }
    }
}
