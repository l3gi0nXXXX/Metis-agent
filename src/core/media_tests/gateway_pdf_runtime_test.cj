package metis.core.media_tests

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
import std.fs.exists
import std.fs.copy
import std.io.InputStream
import std.posix.chmod
import std.process.ProcessRedirect
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
import std.collection.HashSet

import metis.core.*
import metis.core.config.CliConfig

import magic.core.message.Message
import magic.core.model.{AsyncChatResponse, ChatModel, ChatRequest, ChatResponse}
import magic.model.ModelManager

import std.fs.{Directory, File, Path, remove}
import std.time.*
import std.unittest.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

private class GatewayPdfRuntimeFakeModel <: ChatModel {
    private var _maxTokens: Option<Int64> = None

    public prop provider: String {
        get() { "fake" }
    }

    public prop name: String {
        get() { "pdf-runtime" }
    }

    public prop contextLength: Int64 {
        get() { 8192 }
    }

    public mut prop maxTokens: Option<Int64> {
        get() { this._maxTokens }
        set(v) { this._maxTokens = v }
    }

    public func create(_request: ChatRequest): ChatResponse {
        ChatResponse(this.fullName, Message.assistant("pdf runtime model summary"))
    }

    public func asyncCreate(_request: ChatRequest): AsyncChatResponse {
        throw Exception("async not used in PDF runtime tests")
    }
}

private func pdfRuntimeTestTempRoot(label: String): Path {
    let root = Path("/tmp/metis-pdf-runtime-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func pdfRuntimeTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func restorePdfRuntimeTestConfig(
    oldModel: String,
    oldFallbacks: Array<String>,
    oldImageModel: String,
    oldImageFallbacks: Array<String>,
    oldPdfModel: String,
    oldPdfFallbacks: Array<String>
): Unit {
    if (oldModel.isEmpty()) {
        CliConfig.clearPrimaryModelForTest()
    } else {
        CliConfig.model = oldModel
    }
    CliConfig.fallbackModels = oldFallbacks
    if (oldImageModel.isEmpty()) {
        CliConfig.clearImageModelForTest()
    } else {
        CliConfig.imageModel = oldImageModel
    }
    CliConfig.imageFallbackModels = oldImageFallbacks
    if (oldPdfModel.isEmpty()) {
        CliConfig.clearPdfModelForTest()
    } else {
        CliConfig.pdfModel = oldPdfModel
    }
    CliConfig.pdfFallbackModels = oldPdfFallbacks
}

@Test
public class GatewayPdfRuntimeTest {
    @TestCase
    public func gatewayPdfAnalyzeLoadsLocalPdfExtractsTextAndRunsConfiguredModel(): Unit {
        let root = pdfRuntimeTestTempRoot("ok")
        let pdf = root.join("report.pdf")
        File.writeTo(pdf, "%PDF-1.7\nfake".toArray())

        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        let oldPdfModel = CliConfig.pdfModelOrEmpty()
        let oldPdfFallbacks = CliConfig.pdfFallbackModels
        ModelManager.registerChatModel("fake:pdf-runtime", { => GatewayPdfRuntimeFakeModel() })
        setPdfExtractorBridgeRunnerForTest(Some({ request: PdfExtractorBridgeRequest =>
            @Expect(request.inputPath, pdf.toString())
            @Expect(request.maxPages, 20)
            PdfExtractorProcessResult(
                0,
                stdout: "{\"ok\":true,\"status\":\"ok\",\"text\":\"extracted pdf text\",\"pageCount\":1,\"selectedPages\":[1]}",
                stderr: ""
            )
        }))
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []
            CliConfig.pdfModel = "fake:pdf-runtime"
            CliConfig.pdfFallbackModels = []

            let request = JsonObject()
            request.put("pdf", JsonString(pdf.toString()))
            request.put("prompt", JsonString("summarize"))

            let result = gatewayPdfAnalyze(request)

            @Expect(result.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(pdfRuntimeTestString(result, "status"), "ok")
            @Expect(pdfRuntimeTestString(result, "text"), "pdf runtime model summary")
            @Expect(pdfRuntimeTestString(result, "provider"), "fake")
            @Expect(pdfRuntimeTestString(result, "model"), "fake:pdf-runtime")
            @Expect(result.toJsonString().contains("\"details\""), true)
            @Expect(result.toJsonString().contains("\"ok\""), true)
        } finally {
            setPdfExtractorBridgeRunnerForTest(None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>)
            restorePdfRuntimeTestConfig(oldModel, oldFallbacks, oldImageModel, oldImageFallbacks, oldPdfModel, oldPdfFallbacks)
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func gatewayPdfAnalyzeReturnsReadableNotConfiguredWhenNoCandidatesExist(): Unit {
        let root = pdfRuntimeTestTempRoot("not-configured")
        let pdf = root.join("report.pdf")
        File.writeTo(pdf, "%PDF-1.7\nfake".toArray())

        let oldModel = CliConfig.modelOrEmpty()
        let oldFallbacks = CliConfig.fallbackModels
        let oldImageModel = CliConfig.imageModelOrEmpty()
        let oldImageFallbacks = CliConfig.imageFallbackModels
        let oldPdfModel = CliConfig.pdfModelOrEmpty()
        let oldPdfFallbacks = CliConfig.pdfFallbackModels
        try {
            CliConfig.clearPrimaryModelForTest()
            CliConfig.fallbackModels = []
            CliConfig.clearImageModelForTest()
            CliConfig.imageFallbackModels = []
            CliConfig.clearPdfModelForTest()
            CliConfig.pdfFallbackModels = []

            let request = JsonObject()
            request.put("pdf", JsonString(pdf.toString()))

            let result = gatewayPdfAnalyze(request)

            @Expect(result.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(pdfRuntimeTestString(result, "status"), "not_configured")
            @Expect(pdfRuntimeTestString(result, "error").contains("agents.defaults.pdfModel"), true)
            @Expect(result.toJsonString().contains("runtime_unavailable"), false)
        } finally {
            restorePdfRuntimeTestConfig(oldModel, oldFallbacks, oldImageModel, oldImageFallbacks, oldPdfModel, oldPdfFallbacks)
            try { remove(root, recursive: true) } catch (_: Exception) { () }
        }
    }
}


@When[os == "macOS"]
private enum PdfThinCaseSelection { Input0 | Input1 | Input2 | Input3 | Input4 }

@When[os == "macOS"]
private func pdfThinSelections(): Array<PdfThinCaseSelection> { [PdfThinCaseSelection.Input0, PdfThinCaseSelection.Input1, PdfThinCaseSelection.Input2, PdfThinCaseSelection.Input3, PdfThinCaseSelection.Input4] }

@When[os == "macOS"]
private func pdfThinKey(selected: PdfThinCaseSelection): String {
    match (selected) {
        case PdfThinCaseSelection.Input0 => "success"
        case PdfThinCaseSelection.Input1 => "invalid_success"
        case PdfThinCaseSelection.Input2 => "nonzero"
        case PdfThinCaseSelection.Input3 => "invalid_stderr"
        case PdfThinCaseSelection.Input4 => "long_error"
    }
}

@When[os == "macOS"]
private func pdfThinSelect(raw: Option<String>): PdfThinCaseSelection {
    match (raw) {
        case Some(value) => match (value) {
            case "success" => PdfThinCaseSelection.Input0
            case "invalid_success" => PdfThinCaseSelection.Input1
            case "nonzero" => PdfThinCaseSelection.Input2
            case "invalid_stderr" => PdfThinCaseSelection.Input3
            case "long_error" => PdfThinCaseSelection.Input4
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
private func pdfThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func pdfThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), pdfThinCount(6))
}

@When[os == "macOS"]
private func pdfThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func pdfThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func pdfThinRead(stream: InputStream): Array<Byte> {
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
private func pdfThinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class PdfThinCase {
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
                let receipt = JsonValue.fromStr(pdfThinText(entry.path)).asObject()
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
        while (MonoTime.now() < deadline && (!sourceTerminal() || pdfThinCount(1) > fd || !pdfThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(pdfThinCount(1) == fd); check(pdfThinThreadsWithin(threadBaseline))
        let currentThreads = pdfThinThreadSnapshot()
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
private func pdfThinCompileActor(home: Path,
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
        output = Some(spawn { pdfThinRead(compiler.stdOutPipe) }); error = Some(spawn { pdfThinRead(compiler.stdErrPipe) })
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
                let outputJoined = output.map({ worker => pdfThinJoin(worker, cleanupDeadline) }) ?? true
                let errorJoined = error.map({ worker => pdfThinJoin(worker, cleanupDeadline) }) ?? true
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
private func pdfThinRun(filter: String, action: (PdfThinCase) -> Unit, stdin!: Array<Byte> = []): Unit {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || pdfThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let selected = pdfThinSelect(getVariable("METIS_THIN_INPUT_CASE"))
        let fixture = PdfThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        fixture.selectedCase = pdfThinKey(selected)
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
        let aggregateDeadline = MonoTime.now() + Duration.second * 713
        var aggregateFormal: Int64 = 0
        var aggregateWarm: Int64 = 0
        var aggregateNegative: Int64 = 0
        let completedCases = HashMap<String, Int64>()
        try {
            let artifact = pdfThinCompileActor(outer); compilerReady = artifact[1]
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
                try { let _ = pdfThinSelect(raw) }
                catch (failure: Exception) { if (failure.message == "thin_input_selector_invalid") { selectorRejections += 1 } }
            }
            if (selectorRejections != 2) { throw Exception("thin_input_selector_validation_failed") }
            let selections = pdfThinSelections()
            if (selections.size != 5) { throw Exception("thin_input_matrix_incomplete") }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    let caseName = pdfThinKey(selected)
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
                        let proof = JsonValue.fromStr(pdfThinText(home.join("formal-before-fallback.json"))).asObject()
                        let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                        terminal = source.ok && source.terminal
                        childFormal = code == 0 && terminal && proof.get("formal").getOrThrow().asBool().getValue() &&
                            proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue() &&
                            proof.get("case").getOrThrow().asString().getValue() == caseName &&
                            proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                            proof.get("bound").getOrThrow().asBool().getValue() == (mode == "bound") &&
                            proof.get("warmRounds").getOrThrow().asInt().getValue() == 2 &&
                            proof.get("formalRounds").getOrThrow().asInt().getValue() == 32 &&
                            proof.get("negativeRounds").getOrThrow().asInt().getValue() == (if (caseName == "success") { 3 } else { 0 })
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
                    if (completedCases.get(mode + "-" + pdfThinKey(selected)) != Some<Int64>(32)) { throw Exception("thin_input_matrix_incomplete") }
                }
            }
            if (completedCases.size != 10 || aggregateFormal != 320 || aggregateWarm != 20 || aggregateNegative != 6 ||
                MonoTime.now() > aggregateDeadline) { throw Exception("thin_input_matrix_incomplete") }
            File.writeTo(outer.join("aggregate-formal.json"),
                ("{\"children\":${completedCases.size},\"formalRounds\":${aggregateFormal},\"warmRounds\":${aggregateWarm}," +
                    "\"negativeRounds\":${aggregateNegative},\"selectorRejections\":${selectorRejections},\"parentScheduleSeconds\":713}").toArray())

            formal = allCases
        } finally {
            if (formal && compilerReady) { remove(outer, recursive: true) }
            else { eprintln("thin_interface_failure_evidence_retained") }
        }
    }
}

@When[os == "macOS"]
private func pdfThinPdfDependency(snapshot: JsonObject, name: String): JsonObject {
    snapshot.get("dependencies").getOrThrow().asObject().get(name).getOrThrow().asObject()
}

// Insert in GatewayPdfRuntimeTest. No extractor/model runner is installed.

@When[os == "macOS"]
@Test
public class ThinPdfDependencyResourceTest {
    @TestCase
    public func rWrapPdfActualDependencyCaptureClassifiesRawResults(): Unit {
        pdfThinRun("ThinPdfDependencyResourceTest.rWrapPdfActualDependencyCaptureClassifiesRawResults", { fixture =>
            let project = fixture.home.join("owned-project")
            Directory.create(project)
            File.writeTo(project.join("cjpm.toml"), "[package]\nname=\"owned_fixture\"\nversion=\"1.0.0\"\n".toArray())
            setVariable("METIS_CJPM_ROOT", project.toString())
            let helper = project.join("tools/pdf_extract")
            // The public diagnostic has two actual managed node launches per call.
            if (fixture.selectedCase == "success") {
                let missingHelper = gatewayPdfDiagnosticSnapshot()
                for (name in ["pdfjsDist", "canvas"]) {
                    fixture.check(pdfThinPdfDependency(missingHelper, name).get("status").getOrThrow().asString().getValue() == "missing_helper")
                }
                fixture.negativeRounds += 1
            }
            Directory.create(helper, recursive: true)
            if (fixture.selectedCase == "success") {
                let missingPackage = gatewayPdfDiagnosticSnapshot()
                for (name in ["pdfjsDist", "canvas"]) {
                    fixture.check(pdfThinPdfDependency(missingPackage, name).get("status").getOrThrow().asString().getValue() == "missing_package_json")
                }
                fixture.negativeRounds += 1
            }
            File.writeTo(helper.join("package.json"), "{}".toArray())
            for (warm in 0..2) {
                fixture.begin("warm-${warm}", ["node"])
                fixture.route("node", "main", "owned-module/中文😀.js\n".toArray(), [], 0)
                let snapshot = gatewayPdfDiagnosticSnapshot()
                fixture.check(pdfThinPdfDependency(snapshot, "canvas").get("status").getOrThrow().asString().getValue() == "loadable")
                fixture.warmRounds += 1
            }
            let fd = pdfThinCount(1); let threadBaseline = pdfThinThreadSnapshot()
            let cases: Array<(String, Array<Byte>, Array<Byte>, Int64, String, Bool)> = [
                ("success", "owned-module/中文😀.js\n".toArray(), [], 0, "loadable", true),
                ("invalid_success", [255u8, 254u8, 128u8, 0u8], [], 0, "loadable", false),
                ("nonzero", [], "依赖不可用中文😀".toArray(), 7, "not_loadable", false),
                ("invalid_stderr", [], [255u8, 254u8, 128u8, 0u8], 7, "not_loadable", false),
                ("long_error", [], (String(Array<Rune>(32768, repeat: r'中')) + "😀").toArray(), 7, "not_loadable", false)]
            var completed: Int64 = 0
            for (item in cases) {
                if (item[0] != fixture.selectedCase) { continue }
                for (round in 0..32) {
                    fixture.begin(item[0] + "-${round}", ["node"])
                    fixture.route("node", "main", item[1], item[2], item[3])
                    let snapshot = gatewayPdfDiagnosticSnapshot()
                    for (name in ["pdfjsDist", "canvas"]) {
                        let dependency = pdfThinPdfDependency(snapshot, name)
                        fixture.check(dependency.get("status").getOrThrow().asString().getValue() == item[4])
                        fixture.check(dependency.get("loadable").getOrThrow().asBool().getValue() == (item[3] == 0))
                        fixture.check(dependency.get("resolved").isSome() == item[5])
                        if (item[5]) { fixture.check(dependency.get("resolved").getOrThrow().asString().getValue() == "owned-module/中文😀.js") }
                        if (item[0] == "invalid_stderr") { fixture.check(dependency.get("message").isNone()) }
                    }
                    let receipts = fixture.receipts(); fixture.check(receipts.size == 2)
                    let packages = HashSet<String>()
                    for (receipt in receipts) {
                        fixture.check(receipt.get("cwd").getOrThrow().asString().getValue() == canonicalize(helper).toString())
                        fixture.check(receipt.get("commandName").getOrThrow().asString().getValue() == "node")
                        let args = receipt.get("args").getOrThrow().asArray().getItems()
                        fixture.check(args.size == 2)
                        if (args.size == 2) { fixture.check(args[0].asString().getValue() == "-e"); packages.add(args[1].asString().getValue()) }
                    }
                    fixture.check(packages.contains("require.resolve(\"pdfjs-dist\")") && packages.contains("require.resolve(\"@napi-rs/canvas\")"))
                    fixture.stable(fd, threadBaseline); completed += 1; fixture.formalRounds += 1
                }
            }
            if (fixture.selectedCase == "success") {
                fixture.begin("missing_node", [])
                let missingNode = gatewayPdfDiagnosticSnapshot()
                for (name in ["pdfjsDist", "canvas"]) {
                    // SDK spawn failure category is the compatibility contract. A bound
                    // helper returning exit127 must fail this assertion, not redefine it.
                    fixture.check(pdfThinPdfDependency(missingNode, name).get("status").getOrThrow().asString().getValue() == "node_unavailable")
                }
                fixture.check(fixture.receipts().isEmpty()); fixture.stable(fd, threadBaseline)
                fixture.negativeRounds += 1
            }
            fixture.check(completed == 32 && fixture.formalRounds == 32 && fixture.warmRounds == 2 &&
                fixture.negativeRounds == (if (fixture.selectedCase == "success") { 3 } else { 0 }))
            println("R-WRAP-PDF case=${fixture.selectedCase};actualRounds=${completed};bound=${fixture.bound};sourceTerminal=${fixture.terminal()};formal=${!fixture.failed}")
            fixture.finish()
        })
    }
}
