package metis.gateway.tools

import std.runtime.{getThreadCount, getBlockingThreadCount}

import metis.core.config.cliModelProviderCatalogDescriptors

import std.collection.HashMap
import std.collection.Map
import std.convert.Parsable
import std.core.Duration
import std.env.getVariables
import std.env.getProcessId
import std.env.getCommand
import std.env.removeVariable
import std.fs.File
import std.fs.FileInfo
import std.fs.OpenMode
import std.fs.canonicalize
import std.fs.exists
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

import metis.core.{GatewayToolRuntimeContext, gatewayActionIsReadOnly, gatewayConfigPathIsProtected, gatewayWithToolRuntimeContext}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private func gatewayToolsetTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayToolsetTestHome(label: String): String {
    "/tmp/metis-gateway-gateway-toolset-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
}

private func gatewayToolsetResetEnv(oldHome: Option<String>, home: String): Unit {
    match (oldHome) {
        case Some(value) => setVariable("METIS_HOME", value)
        case None => setVariable("METIS_HOME", "")
    }
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    CliConfig.invalidatePathCache()
    try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
}

@Test
public class GatewayGatewayToolsetTest {
    @TestCase
    public func gatewayToolRecognizesReadOnlyActions(): Unit {
        @Expect(gatewayActionIsReadOnly("status"), true)
        @Expect(gatewayActionIsReadOnly("health"), true)
        @Expect(gatewayActionIsReadOnly("discover"), true)
        @Expect(gatewayActionIsReadOnly("discover.detail"), true)
        @Expect(gatewayActionIsReadOnly("config.get"), true)
        @Expect(gatewayActionIsReadOnly("config.schema.lookup"), true)
        @Expect(gatewayActionIsReadOnly("restart"), false)
    }

    @TestCase
    public func gatewayToolRecognizesAuthorizationRequirements(): Unit {
        @Expect(gatewayToolRequiresOwnerApproval("start"), true)
        @Expect(gatewayToolRequiresOwnerApproval("stop"), true)
        @Expect(gatewayToolRequiresOwnerApproval("restart"), true)
        @Expect(gatewayToolRequiresOwnerApproval("master_on"), true)
        @Expect(gatewayToolRequiresOwnerApproval("master_off"), true)
        @Expect(gatewayToolRequiresOwnerApproval("config.patch"), true)
        @Expect(gatewayToolRequiresOwnerApproval("config.apply"), true)
        @Expect(gatewayToolRequiresOwnerApproval("update.run"), true)
        @Expect(gatewayToolRequiresOwnerApproval("status"), false)

        @Expect(gatewayToolRequiresExplicitRequestApproval("config.patch"), true)
        @Expect(gatewayToolRequiresExplicitRequestApproval("config.apply"), true)
        @Expect(gatewayToolRequiresExplicitRequestApproval("update.run"), true)
        @Expect(gatewayToolRequiresExplicitRequestApproval("restart"), false)
    }

    @TestCase
    public func gatewayToolAutoOwnerApprovalOnlyAppliesToOperatorSurfaces(): Unit {
        @Expect(gatewayToolAutoOwnerApprovedForSource("cli"), true)
        @Expect(gatewayToolAutoOwnerApprovedForSource("control-ui"), true)
        @Expect(gatewayToolAutoOwnerApprovedForSource("dashboard"), true)
        @Expect(gatewayToolAutoOwnerApprovedForSource("cron"), true)
        @Expect(gatewayToolAutoOwnerApprovedForSource("gateway-rpc"), false)
        @Expect(gatewayToolAutoOwnerApprovedForSource("feishu"), false)
    }

    @TestCase
    public func gatewayToolRuntimeContextCanElevateOwnerByOperatorScope(): Unit {
        let context = GatewayToolRuntimeContext(
            "gateway-rpc",
            declaredUser: "operator:alice",
            operatorScopes: ["operator.admin"],
            prompt: "restart gateway"
        )
        @Expect(gatewayToolAutoOwnerApprovedForRuntimeContext(context), true)
    }

    @TestCase
    public func gatewayToolCanInferExplicitRequestsFromPrompt(): Unit {
        @Expect(gatewayToolInfersExplicitRequestFromPrompt("restart", "please restart gateway"), true)
        @Expect(gatewayToolInfersExplicitRequestFromPrompt("config.apply", "请应用配置到 gateway.auth.mode", path: Some("gateway.auth.mode")), true)
        @Expect(gatewayToolInfersExplicitRequestFromPrompt("update.run", "help me update metis"), true)
        @Expect(gatewayToolInfersExplicitRequestFromPrompt("config.apply", "show gateway status", path: Some("gateway.auth.mode")), false)
    }

    @TestCase
    public func gatewayToolDeniedActionJsonUsesDenyWithReasonContract(): Unit {
        let denied = gatewayToolDeniedActionJson(
            "config.apply",
            reasonCode: Some("owner_required"),
            ownerApproved: false,
            explicitRequest: false,
            path: Some("gateway.session.dmScope"),
            raw: Some("main")
        )
        @Expect(gatewayToolsetTestString(denied, "status"), "denied")
        @Expect(gatewayToolsetTestString(denied, "action"), "config.apply")
        @Expect(gatewayToolsetTestString(denied, "rejectionContract"), "deny-with-reason")
        @Expect(gatewayToolsetTestString(denied, "reasonCode"), "owner_required")
        @Expect(gatewayToolsetTestString(denied, "path"), "gateway.session.dmScope")
        @Expect(gatewayToolsetTestString(denied, "raw"), "main")
        @Expect(gatewayToolsetTestString(denied, "error").contains("authorization guard"), true)
    }

    @TestCase
    public func gatewayToolAuthorizationFailureJsonUsesOwnerAndExplicitRequestReasons(): Unit {
        let ownerDenied = gatewayToolAuthorizationFailureJson("restart").getOrThrow()
        @Expect(gatewayToolsetTestString(ownerDenied, "reasonCode"), "owner_required")
        @Expect(gatewayToolsetTestString(ownerDenied, "error").contains("owner approval"), true)

        let explicitDenied = gatewayToolAuthorizationFailureJson(
            "config.apply",
            ownerApproved: true,
            explicitRequest: false,
            path: Some("gateway"),
            raw: Some("{\"enabled\":true}")
        ).getOrThrow()
        @Expect(gatewayToolsetTestString(explicitDenied, "reasonCode"), "explicit_request_required")
        @Expect(gatewayToolsetTestString(explicitDenied, "error").contains("explicit user request"), true)
        @Expect(gatewayToolAuthorizationFailureJson("config.apply", ownerApproved: true, explicitRequest: true).isNone(), true)
    }

    @TestCase
    public func gatewayToolProtectsSensitiveConfigPaths(): Unit {
        @Expect(gatewayConfigPathIsProtected("gateway.controlUi.allowInsecureAuth"), true)
        @Expect(gatewayConfigPathIsProtected("gateway.auth.mode"), true)
        @Expect(gatewayConfigPathIsProtected("gateway.feishu.appId"), false)

        let denied = gatewayToolDeniedActionJson(
            "config.apply",
            errorMessage: Some("Gateway action `config.apply` cannot modify protected config path `gateway.controlUi.allowInsecureAuth` on the unified Gateway main runtime."),
            reasonCode: Some("protected_path"),
            ownerApproved: true,
            explicitRequest: true,
            path: Some("gateway.controlUi.allowInsecureAuth"),
            raw: Some("true")
        )
        @Expect(gatewayToolsetTestString(denied, "reasonCode"), "protected_path")
        @Expect(gatewayToolsetTestString(denied, "error").contains("protected config path"), true)
    }

    @TestCase
    public func gatewayToolAutoApprovesCliOwnerButStillRequiresExplicitMutationRequest(): Unit {
        let context = GatewayToolRuntimeContext("cli", channelName: "cli", prompt: "show gateway status")
        @Expect(gatewayToolAutoOwnerApprovedForRuntimeContext(context), true)
        @Expect(
            gatewayToolInfersExplicitRequestFromPrompt("config.apply", context.prompt, path: Some("gateway.auth.mode")),
            false
        )
        let denied = gatewayToolAuthorizationFailureJson(
            "config.apply",
            ownerApproved: gatewayToolAutoOwnerApprovedForRuntimeContext(context),
            explicitRequest: gatewayToolInfersExplicitRequestFromPrompt("config.apply", context.prompt, path: Some("gateway.auth.mode")),
            path: Some("gateway.auth.mode"),
            raw: Some("\"token\"")
        ).getOrThrow()
        @Expect(gatewayToolsetTestString(denied, "reasonCode"), "explicit_request_required")
    }

    @TestCase
    public func gatewayToolAutoContextAllowsCliMutationRequestButStillProtectsSensitivePath(): Unit {
        let context = GatewayToolRuntimeContext("cli", channelName: "cli", prompt: "请应用配置到 gateway.auth.mode")
        @Expect(gatewayToolAutoOwnerApprovedForRuntimeContext(context), true)
        @Expect(
            gatewayToolInfersExplicitRequestFromPrompt("config.apply", context.prompt, path: Some("gateway.auth.mode")),
            true
        )
        let denied = gatewayToolDeniedActionJson(
            "config.apply",
            errorMessage: Some("Gateway action `config.apply` cannot modify protected config path `gateway.auth.mode` on the unified Gateway main runtime."),
            reasonCode: Some("protected_path"),
            ownerApproved: gatewayToolAutoOwnerApprovedForRuntimeContext(context),
            explicitRequest: true,
            path: Some("gateway.auth.mode"),
            raw: Some("\"token\"")
        )
        @Expect(gatewayToolsetTestString(denied, "reasonCode"), "protected_path")
    }

    @TestCase
    public func gatewayToolChannelContextStaysNonOwnerByDefault(): Unit {
        let context = GatewayToolRuntimeContext("feishu", channelName: "feishu", senderId: "ou_123", prompt: "重启网关")
        @Expect(gatewayToolAutoOwnerApprovedForRuntimeContext(context), false)
        let denied = gatewayToolAuthorizationFailureJson("restart").getOrThrow()
        @Expect(gatewayToolsetTestString(denied, "reasonCode"), "owner_required")
    }

    @TestCase
    public func gatewayToolGatewayRpcContextUsesOperatorScopeAsOwnerSignal(): Unit {
        let context = GatewayToolRuntimeContext(
            "gateway-rpc",
            channelName: "gateway-rpc",
            declaredUser: "operator:bob",
            operatorScopes: ["operator.admin"],
            prompt: "restart gateway"
        )
        @Expect(gatewayToolAutoOwnerApprovedForRuntimeContext(context), true)
        @Expect(gatewayToolAuthorizationFailureJson("restart", ownerApproved: true).isNone(), true)
    }

    @TestCase
    public func gatewayToolReadOnlyActionUsesRuntimeHookWhenAvailable(): Unit {
        let calls = Array<String>(1, repeat: "")
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            gatewayCallHook: Some({ method: String, params: JsonObject =>
                calls[0] = "${method}:${gatewayToolsetTestString(params, "path")}"
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("status", JsonString("ok"))
                out.put("method", JsonString(method))
                out.put("path", JsonString(gatewayToolsetTestString(params, "path")))
                out
            })
        )

        let raw = gatewayWithToolRuntimeContext(context, { =>
            GatewayGatewayToolset().debugGatewayForTest("config.get", Some("gateway.feishu"))
        })
        let result = JsonValue.fromStr(raw).asObject()

        @Expect(gatewayToolsetTestString(result, "status"), "ok")
        @Expect(gatewayToolsetTestString(result, "method"), "config.get")
        @Expect(gatewayToolsetTestString(result, "path"), "gateway.feishu")
        @Expect(calls[0], "config.get:gateway.feishu")
    }

    @TestCase
    public func gatewayToolConfigGetWithoutRuntimeHookReadsInProcessWithoutExitCode(): Unit {
        let home = gatewayToolsetTestHome("config-get-in-process")
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()

        let root = JsonObject()
        let gateway = JsonObject()
        gateway.put("enabled", JsonBool(false))
        root.put("gateway", gateway)
        MetisConfigManager.writeRoot(root)
        CliSettingManager.invalidate()

        try {
            let raw = GatewayGatewayToolset().debugGatewayForTest("config.get", Some("gateway.enabled"))
            let result = JsonValue.fromStr(raw).asObject()
            let resultObj = result.get("result").getOrThrow().asObject()

            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(gatewayToolsetTestString(result, "method"), "config.get")
            @Expect(gatewayToolsetTestString(resultObj, "path"), "gateway.enabled")
            @Expect(resultObj.get("value").getOrThrow().asBool().getValue(), false)
            @Expect(result.get("exitCode").isNone(), true)
        } finally {
            gatewayToolsetResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func gatewayToolConfigSchemaLookupWithoutRuntimeHookReadsInProcessWithoutExitCode(): Unit {
        let raw = GatewayGatewayToolset().debugGatewayForTest("config.schema.lookup", Some("gateway.telegram"))
        let result = JsonValue.fromStr(raw).asObject()
        let resultObj = result.get("result").getOrThrow().asObject()

        @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(gatewayToolsetTestString(result, "method"), "config.schema.lookup")
        @Expect(gatewayToolsetTestString(resultObj, "path"), "gateway.telegram")
        @Expect(gatewayToolsetTestString(resultObj, "schema").contains("Telegram"), true)
        @Expect(result.get("exitCode").isNone(), true)
    }

    @TestCase
    public func gatewayToolReadOnlyStatusFailsFastWhenRuntimeHookMissing(): Unit {
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1"
        )

        let raw = gatewayWithToolRuntimeContext(context, { =>
            GatewayGatewayToolset().debugGatewayForTest("status", None<String>)
        })
        let result = JsonValue.fromStr(raw).asObject()

        @Expect(result.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(gatewayToolsetTestString(result, "errorCode"), "gateway_call_unavailable")
        @Expect(gatewayToolsetTestString(result, "method"), "status")
    }
}


@When[os == "macOS"]
private enum GwToolThinCaseSelection { Input0 | Input1 | Input2 | Input3 | Input4 | Input5 | Input6 }

@When[os == "macOS"]
private func gwToolThinSelections(): Array<GwToolThinCaseSelection> { [GwToolThinCaseSelection.Input0, GwToolThinCaseSelection.Input1, GwToolThinCaseSelection.Input2, GwToolThinCaseSelection.Input3, GwToolThinCaseSelection.Input4, GwToolThinCaseSelection.Input5, GwToolThinCaseSelection.Input6] }

@When[os == "macOS"]
private func gwToolThinKey(selected: GwToolThinCaseSelection): String {
    match (selected) {
        case GwToolThinCaseSelection.Input0 => "json"
        case GwToolThinCaseSelection.Input1 => "text"
        case GwToolThinCaseSelection.Input2 => "malformed"
        case GwToolThinCaseSelection.Input3 => "invalid"
        case GwToolThinCaseSelection.Input4 => "nonzero"
        case GwToolThinCaseSelection.Input5 => "invalid_error"
        case GwToolThinCaseSelection.Input6 => "long"
    }
}

@When[os == "macOS"]
private func gwToolThinSelect(raw: Option<String>): GwToolThinCaseSelection {
    match (raw) {
        case Some(value) => match (value) {
            case "json" => GwToolThinCaseSelection.Input0
            case "text" => GwToolThinCaseSelection.Input1
            case "malformed" => GwToolThinCaseSelection.Input2
            case "invalid" => GwToolThinCaseSelection.Input3
            case "nonzero" => GwToolThinCaseSelection.Input4
            case "invalid_error" => GwToolThinCaseSelection.Input5
            case "long" => GwToolThinCaseSelection.Input6
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
private func gwToolThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func gwToolThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), gwToolThinCount(6))
}

@When[os == "macOS"]
private func gwToolThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func gwToolThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func gwToolThinRead(stream: InputStream): Array<Byte> {
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
private func gwToolThinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class GwToolThinCase {
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
                let receipt = JsonValue.fromStr(gwToolThinText(entry.path)).asObject()
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
        while (MonoTime.now() < deadline && (!sourceTerminal() || gwToolThinCount(1) > fd || !gwToolThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(gwToolThinCount(1) == fd); check(gwToolThinThreadsWithin(threadBaseline))
        let currentThreads = gwToolThinThreadSnapshot()
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
private func gwToolThinCompileActor(home: Path,
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
        output = Some(spawn { gwToolThinRead(compiler.stdOutPipe) }); error = Some(spawn { gwToolThinRead(compiler.stdErrPipe) })
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
                let outputJoined = output.map({ worker => gwToolThinJoin(worker, cleanupDeadline) }) ?? true
                let errorJoined = error.map({ worker => gwToolThinJoin(worker, cleanupDeadline) }) ?? true
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
private func gwToolThinRun(filter: String, action: (GwToolThinCase) -> Unit, stdin!: Array<Byte> = []): Unit {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || gwToolThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let selected = gwToolThinSelect(getVariable("METIS_THIN_INPUT_CASE"))
        let fixture = GwToolThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        fixture.selectedCase = gwToolThinKey(selected)
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
            let artifact = gwToolThinCompileActor(outer); compilerReady = artifact[1]
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
                try { let _ = gwToolThinSelect(raw) }
                catch (failure: Exception) { if (failure.message == "thin_input_selector_invalid") { selectorRejections += 1 } }
            }
            if (selectorRejections != 2) { throw Exception("thin_input_selector_validation_failed") }
            let selections = gwToolThinSelections()
            if (selections.size != 7) { throw Exception("thin_input_matrix_incomplete") }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    let caseName = gwToolThinKey(selected)
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
                        let proof = JsonValue.fromStr(gwToolThinText(home.join("formal-before-fallback.json"))).asObject()
                        let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                        terminal = source.ok && source.terminal
                        childFormal = code == 0 && terminal && proof.get("formal").getOrThrow().asBool().getValue() &&
                            proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue() &&
                            proof.get("case").getOrThrow().asString().getValue() == caseName &&
                            proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                            proof.get("bound").getOrThrow().asBool().getValue() == (mode == "bound") &&
                            proof.get("warmRounds").getOrThrow().asInt().getValue() == 2 &&
                            proof.get("formalRounds").getOrThrow().asInt().getValue() == 32 &&
                            proof.get("negativeRounds").getOrThrow().asInt().getValue() == (if (caseName == "json") { 1 } else { 0 })
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
                    if (completedCases.get(mode + "-" + gwToolThinKey(selected)) != Some<Int64>(32)) { throw Exception("thin_input_matrix_incomplete") }
                }
            }
            if (completedCases.size != 14 || aggregateFormal != 448 || aggregateWarm != 28 || aggregateNegative != 2 ||
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
public class ThinGatewayToolResourceTest {
    @TestCase
    public func rWrapGatewayAuthorizedCallUsesActualOwnedBinary(): Unit {
        gwToolThinRun("ThinGatewayToolResourceTest.rWrapGatewayAuthorizedCallUsesActualOwnedBinary", { fixture =>
            let project = fixture.home.join("owned-project"); Directory.create(project)
            File.writeTo(project.join("cjpm.toml"), "[package]\nname=\"owned_fixture\"\nversion=\"1.0.0\"\n".toArray())
            let binaryDir = project.join("target/release/bin"); Directory.create(binaryDir, recursive: true)
            let binary = binaryDir.join("metis"); copy(fixture.actor, to: binary)
            fixture.check(chmod(binary.toString(), 0o700u32) == 0)
            setVariable("METIS_CJPM_ROOT", project.toString())
            let context = GatewayToolRuntimeContext("cli", channelName: "cli", prompt: "请重启gateway")
            let invoke = { =>
                let raw = gatewayWithToolRuntimeContext(context, { => GatewayGatewayToolset().debugGatewayForTest("restart", None<String>) })
                JsonValue.fromStr(raw).asObject()
            }
            for (warm in 0..2) {
                fixture.begin("warm-${warm}", [])
                fixture.route("metis", "main", "{\"ok\":true,\"result\":{\"message\":\"完成中文😀\"}}\n".toArray(), [], 0)
                fixture.check(invoke().get("ok").getOrThrow().asBool().getValue())
                fixture.warmRounds += 1
            }
            let fd = gwToolThinCount(1); let threadBaseline = gwToolThinThreadSnapshot()
            let cases: Array<(String, Array<Byte>, Array<Byte>, Int64)> = [
                ("json", "{\"ok\":true,\"result\":{\"message\":\"完成中文😀\"}}\n".toArray(), "诊断中文😀\n".toArray(), 0),
                ("text", "完成中文😀\n".toArray(), [], 0),
                ("malformed", "{malformed-中文😀\n".toArray(), [], 0),
                ("invalid", [255u8, 254u8, 128u8, 0u8], [], 0),
                ("nonzero", [], "失败中文😀\n".toArray(), 7),
                ("invalid_error", [], [255u8, 254u8, 128u8, 0u8], 7),
                ("long", (String(Array<Rune>(32768, repeat: r'中')) + "😀\n").toArray(), [], 0)]
            var completed: Int64 = 0
            for (item in cases) {
                if (item[0] != fixture.selectedCase) { continue }
                for (round in 0..32) {
                    fixture.begin(item[0] + "-${round}", [])
                    fixture.route("metis", "main", item[1], item[2], item[3])
                    let result = invoke()
                    fixture.check(result.get("ok").getOrThrow().asBool().getValue() == (item[3] == 0))
                    fixture.check(result.get("exitCode").getOrThrow().asInt().getValue() == item[3])
                    if (item[0] == "json") {
                        fixture.check(result.get("result").getOrThrow().asObject().get("message").getOrThrow().asString().getValue() == "完成中文😀")
                        fixture.check(result.get("stderr").getOrThrow().asString().getValue() == "诊断中文😀")
                    } else {
                        let stdout = try { String.fromUtf8(item[1]).trimAscii() } catch (_: Exception) { "" }
                        let stderr = try { String.fromUtf8(item[2]).trimAscii() } catch (_: Exception) { "" }
                        fixture.check(result.get("stdout").getOrThrow().asString().getValue() == stdout)
                        fixture.check(result.get("stderr").getOrThrow().asString().getValue() == stderr)
                    }
                    let receipts = fixture.receipts(); fixture.check(receipts.size == 1)
                    if (receipts.size == 1) {
                        let args = receipts[0].get("args").getOrThrow().asArray().getItems()
                        fixture.check(args.size == 3)
                        if (args.size == 3) {
                            fixture.check(args[0].asString().getValue() == "gateway" && args[1].asString().getValue() == "call" && args[2].asString().getValue() == "restart")
                        }
                        fixture.check(receipts[0].get("cwd").getOrThrow().asString().getValue() == canonicalize(project).toString())
                    }
                    fixture.stable(fd, threadBaseline); completed += 1; fixture.formalRounds += 1
                }
            }
            if (fixture.selectedCase == "json") {
                fixture.begin("eacces", [])
                fixture.check(chmod(binary.toString(), 0o600u32) == 0)
                let failed = invoke()
                fixture.check(!failed.get("ok").getOrThrow().asBool().getValue())
                fixture.check(failed.get("errorCode").getOrThrow().asString().getValue() == "gateway_call_failed")
                fixture.check(fixture.receipts().isEmpty()); fixture.stable(fd, threadBaseline)
                fixture.negativeRounds += 1
            }
            fixture.check(completed == 32 && fixture.formalRounds == 32 && fixture.warmRounds == 2 &&
                fixture.negativeRounds == (if (fixture.selectedCase == "json") { 1 } else { 0 }))
            println("R-WRAP-GWTOOL case=${fixture.selectedCase};actualRounds=${completed};bound=${fixture.bound};sourceTerminal=${fixture.terminal()};formal=${!fixture.failed}")
            fixture.finish()
        })
    }
}
