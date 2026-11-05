package metis.gateway.runtime

import metis.process.*
import magic.utils.http.{HttpUtils, HttpProcessLaunchProvider, HttpProcessLaunchSpec, setHttpProcessLaunchProvider}
import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, OpenMode, Path, canonicalize, exists, remove}
import std.posix.chmod
import std.process.{ProcessException, ProcessRedirect}
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*


private func httpOutcomeCheck(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("http_recovery_outcome_contract_failed") }
}
private func httpOutcomeText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("http_recovery_fixture_invalid_encoding") }
}
private func httpOutcomeFields(text: String): HashMap<String, String> {
    let fields = HashMap<String, String>()
    for (line in text.split("\n")) {
        if (line.isEmpty() || !line.contains(":")) { continue }
        let parts = line.split(":")
        httpOutcomeCheck(parts.size >= 2 && !fields.contains(parts[0]))
        fields[parts[0]] = String.join(parts[1..], delimiter: ":")
    }
    fields
}
@When[os == "macOS"]
private func httpOutcomeFd(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("http_recovery_fd_probe_failed") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}
@When[os == "macOS"]
private func httpOutcomeGroupGone(pid: Int64): Bool {
    if (pid <= 1 || pid > 2147483647) { return false }
    unsafe { kill(-Int32(pid), 0) } != 0 && unsafe { __error().read() } == 3
}
private func httpOutcomeRestore(key: String, value: ?String): Unit {
    match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
}

/** Only a public spec wrapper: records actual facts before the provider consumes them. */
@When[os == "macOS"]
private class HttpOutcomeObserver <: HttpProcessLaunchProvider {
    let provider: GatewayHttpRecoveryLaunchProvider
    let context: (String, String)
    let binding: String
    let home: Path
    let births = ArrayList<ProcessBirthIdentity>()
    let groups = ArrayList<Int64>()
    var observed = false
    var spawned = false
    var reaped = false
    var phase = "absent"
    var errorCode: Int64 = 0
    var key = ""
    init(context: (String, String), binding: String, home: Path) {
        this.context = context; this.binding = binding; this.home = home
        this.provider = GatewayHttpRecoveryLaunchProvider(context, binding: Some(binding))
    }
    func reset(): Unit {
        observed = false; spawned = false; reaped = false; phase = "absent"; errorCode = 0; key = ""
        births.clear(); groups.clear()
    }
    public func prepare(command: String, args: Array<String>): HttpProcessLaunchSpec {
        let spec = provider.prepare(command, args)
        key = spec.environment["METIS_PROCESS_RECOVERY_BROKER_KEY"]
        let ownerKey = key + "-o-1"
        HttpProcessLaunchSpec(spec.command, spec.args, environment: spec.environment,
            detachedProcessGroup: spec.detachedProcessGroup,
            onSpawned: { pid =>
                let group = unsafe { getpgid(Int32(pid)) }
                let accepted = spec.onSpawned(pid)
                if (accepted && group == Int32(pid)) { groups.add(pid) }
                accepted
            }, requestStop: spec.requestStop,
            onTerminal: { pid, didSpawn, didReap =>
                spawned = didSpawn; reaped = didReap
                try {
                    let directory = Path(context[0])
                    let outcome = managedRecoveryReadExecError(directory, context[1], binding, ownerKey)
                    match (outcome) {
                        case Some(value) => phase = value.phase; errorCode = value.error
                        case None => phase = "absent"
                    }
                    for (entry in Directory.readFrom(directory)) {
                        if (entry.name.startsWith(key + ".") || entry.name.startsWith(ownerKey + ".")) {
                            let raw = File.readFrom(entry.path)
                            File.writeTo(home.join(entry.name), raw)
                            if (entry.name.endsWith(".birth")) {
                                let fields = httpOutcomeFields(httpOutcomeText(entry.path))
                                let birth = parseProcessBirthIdentity(fields["birth"]).getOrThrow()
                                births.add(birth)
                                let group = Int64.parse(fields["pgid"])
                                if (group > 1) { groups.add(group) }
                            }
                        }
                    }
                    if (births.size == 1 && exists(home.join(ownerKey + ".birth"))) {
                        let fields = httpOutcomeFields(httpOutcomeText(home.join(ownerKey + ".birth")))
                        births.add(parseProcessBirthIdentity(fields["birth"]).getOrThrow())
                        groups.add(Int64.parse(fields["pgid"]))
                    }
                    observed = true
                } catch (_: Exception) { observed = false }
                spec.onTerminal(pid, didSpawn, didReap)
            })
    }
    func gone(): Bool {
        for (birth in births) {
            let proof = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
            if (!proof.conclusive || proof.alive) { return false }
        }
        for (group in groups) {
            if (unsafe { kill(Int32(-group), 0) } == 0 || unsafe { __error().read() } != 3) { return false }
        }
        true
    }
}

@When[os == "macOS"]
private func httpOutcomeUnknownAsset(home: Path): Unit {
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
    let dev = home.join("private-dev")
    for (name in ["scripts", "src/process", "target/native"]) { Directory.create(dev.join(name), recursive: true) }
    for (name in ["scripts/metis-stdio-broker.mjs", "src/process/managed_exec_gate.c", "build.cj"]) {
        let bytes = File.readFrom(project.join(name)); File.writeTo(dev.join(name), bytes)
        httpOutcomeCheck(File.readFrom(dev.join(name)) == bytes)
    }
    let asset = dev.join("target/native/metis-exec-gate-v1")
    File.writeTo(asset, ("#!/bin/sh\n" +
        "journal=$METIS_PROCESS_RECOVERY_DIRECTORY\nkey=$METIS_PROCESS_RECOVERY_BROKER_KEY\n" +
        "while [ ! -f \"$journal/$key-o-1.birth\" ]; do /bin/sleep 0.01; done\n" +
        "printf 'METIS-EXEC-GATE:9:00000000000000000000000000000000\\n' >&3\n/bin/sleep 300\n").toArray())
    chmod(asset.toString(), UInt32(0o755))
    setVariable("METIS_STDIO_BROKER_SCRIPT", dev.join("scripts/metis-stdio-broker.mjs").toString())
}

@When[os == "macOS"]
private func httpOutcomeBindingNegatives(home: Path, observer: HttpOutcomeObserver, directory: Path): Unit {
    let header = directory.join("inventory")
    let original = File.readFrom(header)
    let originalText = httpOutcomeText(header)
    let issued = File.readFrom(directory.join(".issued"))
    for (missing in [false, true]) {
        let label = if (missing) { "missing-header" } else { "changed-binding" }
        let replacement = originalText.replace("binding:" + observer.binding, "binding:replaced-中文😀")
        httpOutcomeCheck(replacement != originalText)
        if (missing) { remove(header) } else { File.writeTo(header, replacement.toArray()) }
        var rejected = false
        var prepared = false
        try { let _ = observer.provider.prepare("/bin/true", []); prepared = true }
        catch (_: Exception) { rejected = true }
        let unchanged = File.readFrom(directory.join(".issued")) == issued
        let inputPreserved = if (missing) { !exists(header) } else { File.readFrom(header) == replacement.toArray() }
        let formal = rejected && !prepared && unchanged && inputPreserved
        if (!missing) { File.writeTo(home.join(label + ".original-input"), File.readFrom(header)) }
        let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("beforeMetadataRestore", JsonBool(true))
        proof.put("missing", JsonBool(missing)); proof.put("prepared", JsonBool(prepared)); proof.put("issuedUnchanged", JsonBool(unchanged))
        File.writeTo(home.join(label + ".formal.json"), proof.toJsonString().toArray())
        httpOutcomeCheck(formal)
        // Only this successful no-spawn metadata negative restores its own original bytes.
        // The injected fault and formal decision above remain retained independently.
        File.writeTo(header, original); chmod(header.toString(), UInt32(0o600))
        httpOutcomeCheck(managedRecoveryBinding(observer.context) == observer.binding)
    }
}

private class HttpOutcomeOperationState {
    var operation = None<Future<Bool>>
    var joined = false
    var calls: Int64 = 0
    var unknownActive = false
}

@When[os == "macOS"]
private func httpOutcomeChild(unknown: Bool): Unit {
    let home = canonicalize(Path(getVariable("METIS_HTTP_OUTCOME_HOME").getOrThrow()))
    let nonce = getVariable("METIS_HTTP_OUTCOME_NONCE").getOrThrow()
    httpOutcomeCheck(home.toString().startsWith("/private/tmp/") &&
        httpOutcomeText(home.join("owner")) == "http-outcome-v1\n" + nonce)
    let previousDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let previousParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let previousPath = getVariable("PATH")
    let previousNode = getVariable("METIS_STDIO_BROKER_NODE_COMMAND")
    let previousScript = getVariable("METIS_STDIO_BROKER_SCRIPT")
    let node = managedStdioResolveNodeCommand()
    let directory = home.join("inventory")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let binding = "http-outcome-中文😀-" + nonce
    httpOutcomeCheck(managedRecoveryInitialize(directory, parent, binding))
    let bin = home.join("bin"); Directory.create(bin)
    let curl = bin.join("curl")
    let observer = HttpOutcomeObserver((directory.toString(), parent), binding, home)
    let previous = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(observer))
    var formal = false
    var terminal = false
    var firstError = None<Exception>
    let state = HttpOutcomeOperationState()
    try {
        setVariable("PATH", bin.toString()); setVariable("METIS_STDIO_BROKER_NODE_COMMAND", node)
        let launch = { code: Int64, missing: Bool =>
            let marker = home.join("business-${state.calls}")
            if (!missing) {
                File.writeTo(curl, ("#!/bin/sh\nprintf done > \"$METIS_HTTP_OUTCOME_HOME/business-${state.calls}\"\n" +
                    "/bin/cat \"$METIS_PROCESS_RECOVERY_DIRECTORY/$METIS_PROCESS_RECOVERY_BROKER_KEY-o-1.birth\" > \"$METIS_HTTP_OUTCOME_HOME/$METIS_PROCESS_RECOVERY_BROKER_KEY-o-1.birth\" || exit 63\n" +
                    "printf 'fixture-response-中文😀'\nexit ${code}\n").toArray())
                chmod(curl.toString(), UInt32(0o755))
            } else { remove(curl) }
            observer.reset(); state.joined = false
            let worker = spawn {
                var failed = false
                var wrongType = false
                try { let _ = HttpUtils.get("http://127.0.0.1:9/owned-fake-no-network", HashMap<String, String>(), None) }
                catch (_: ProcessException) { wrongType = true }
                catch (_: Exception) { failed = true }
                failed && !wrongType
            }
            state.operation = Some(worker)
            httpOutcomeCheck(worker.get(Duration.second * 5)); state.joined = true
            httpOutcomeCheck(observer.observed && observer.spawned && observer.reaped)
            httpOutcomeCheck(if (missing || state.unknownActive) { !exists(marker) } else { exists(marker) })
            if (missing) { httpOutcomeCheck(observer.phase == "exec" && observer.errorCode > 0) }
            else if (state.unknownActive) { httpOutcomeCheck(observer.phase == "channel") }
            else { httpOutcomeCheck(observer.phase == "absent") }
            httpOutcomeCheck(observer.births.size == 2 && observer.groups.size == 2 && observer.gone())
            let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 2)
            httpOutcomeCheck(source.ok && source.terminal)
            httpOutcomeCheck(managedRecoveryParseClosedCheckpoint(httpOutcomeText(directory.join("roots.closed")), "roots.closed", parent).getOrThrow().covers(observer.key))
            state.calls += 1
        }
        launch(7, false)
        let fd = httpOutcomeFd(); let tasks = getThreadCount(); let blocking = getBlockingThreadCount()
        if (unknown) { httpOutcomeUnknownAsset(home); state.unknownActive = true; launch(7, false) }
        else { launch(7, false); launch(125, false); launch(126, false); launch(0, true) }
        httpOutcomeBindingNegatives(home, observer, directory)
        httpOutcomeCheck(httpOutcomeFd() == fd && getThreadCount() <= tasks && getBlockingThreadCount() <= blocking)
        httpOutcomeCheck(state.calls == if (unknown) { 2 } else { 5 })
        formal = true
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        try {
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("beforeFallback", JsonBool(true))
            proof.put("actualCalls", JsonInt(state.calls)); proof.put("joined", JsonBool(state.joined))
            proof.put("callbackObserved", JsonBool(observer.observed)); proof.put("actualSpawned", JsonBool(observer.spawned))
            proof.put("actualReaped", JsonBool(observer.reaped)); proof.put("phase", JsonString(observer.phase))
            File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray())
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        finally {
            try { observer.provider.closeAdmission() }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            if (let Some(worker) <- state.operation) {
                try { let _ = worker.get(Duration.second * 5); state.joined = true }
                catch (error: Exception) { state.joined = false; if (firstError.isNone()) { firstError = Some(error) } }
            }
            try {
                let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 5)
                terminal = state.joined && source.ok && source.terminal && observer.gone()
            } catch (error: Exception) { terminal = false; if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try { let _ = setHttpProcessLaunchProvider(previous) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                for ((key, value) in [("METIS_PROCESS_RECOVERY_DIRECTORY", previousDirectory), ("METIS_PROCESS_RECOVERY_PARENT", previousParent),
                    ("PATH", previousPath), ("METIS_STDIO_BROKER_NODE_COMMAND", previousNode), ("METIS_STDIO_BROKER_SCRIPT", previousScript)]) {
                    try { httpOutcomeRestore(key, value) }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
            }
        }
        try {
            let cleanup = JsonObject(); cleanup.put("terminal", JsonBool(terminal)); cleanup.put("formal", JsonBool(formal))
            File.writeTo(home.join("cleanup.json"), cleanup.toJsonString().toArray())
            println("R-NG-HTTP formal=${formal};calls=${state.calls};joined=${state.joined};terminal=${terminal}")
            httpOutcomeCheck(formal && terminal)
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
    }
    if (let Some(error) <- firstError) { throw error }
}

// Test-private admission: byte decoding and every external field fail closed without echoing input.
@When[os == "macOS"]
private func httpOutcomeDriverRecord(nonce: String, method: String, unknown: Bool,
    pid: Int64, birth: String, pgid: Int64): JsonObject {
    let value = JsonObject()
    value.put("schema", JsonString("http-outcome-driver-v1")); value.put("nonce", JsonString(nonce))
    value.put("method", JsonString(method)); value.put("mode", JsonString(if (unknown) { "unknown" } else { "codes" }))
    value.put("pid", JsonInt(pid)); value.put("birth", JsonString(birth)); value.put("pgid", JsonInt(pgid))
    value
}
@When[os == "macOS"]
private func httpOutcomeDriverAdmissionValid(raw: Array<UInt8>, owner: String, nonce: String,
    method: String, unknown: Bool, pid: Int64, birth: String, pgid: Int64): Bool {
    try {
        if (raw.isEmpty() || raw.size > 4096 || nonce.isEmpty() || nonce.size > 128 ||
            owner != "http-outcome-driver-v1\n" + nonce || pid <= 1 || pgid != pid) { return false }
        for (rune in nonce.runes()) { if (rune < r'0' || rune > r'9') { return false } }
        let expected = if (unknown) { "httpOutcomeN1RealVersionFailureRemainsUnknownAndRetires" }
            else { "httpOutcomeP1RealCurlCodesAndExecFailureRetire" }
        if (method != expected || parseProcessBirthIdentity(birth).getOrThrow().pid != pid) { return false }
        let value = JsonValue.fromStr(String.fromUtf8(raw)).asObject()
        value.size() == 7 && value.get("schema").getOrThrow().asString().getValue() == "http-outcome-driver-v1" &&
            value.get("nonce").getOrThrow().asString().getValue() == nonce &&
            value.get("method").getOrThrow().asString().getValue() == method &&
            value.get("mode").getOrThrow().asString().getValue() == (if (unknown) { "unknown" } else { "codes" }) &&
            value.get("pid").getOrThrow().asInt().getValue() == pid &&
            value.get("birth").getOrThrow().asString().getValue() == birth &&
            value.get("pgid").getOrThrow().asInt().getValue() == pgid
    } catch (_: Exception) { false }
}
@When[os == "macOS"]
private func httpOutcomeDriverObject(path: Path): JsonObject {
    try {
        let raw = File.readFrom(path)
        if (raw.isEmpty() || raw.size > 8192) { throw Exception("http_recovery_driver_receipt_invalid") }
        JsonValue.fromStr(String.fromUtf8(raw)).asObject()
    } catch (_: Exception) { throw Exception("http_recovery_driver_receipt_invalid") }
}
@When[os == "macOS"]
private func httpOutcomeDriverAdmissionNegatives(): Unit {
    let method = "httpOutcomeP1RealCurlCodesAndExecFailureRetire"
    let value = httpOutcomeDriverRecord("123", method, false, 2, "2:1:1", 2)
    let good = value.toJsonString().toArray()
    let invalidUtf8: Array<UInt8> = [0xff, 0xfe]
    httpOutcomeCheck(httpOutcomeDriverAdmissionValid(good, "http-outcome-driver-v1\n123", "123", method, false, 2, "2:1:1", 2))
    for ((raw, owner, nonce, birth) in [(good, "", "123", "2:1:1"),
        (good, "http-outcome-driver-v1\n124", "124", "2:1:1"),
        (good, "http-outcome-driver-v1\n123", "123", "2:1:2"),
        ("{".toArray(), "http-outcome-driver-v1\n123", "123", "2:1:1"),
        (invalidUtf8, "http-outcome-driver-v1\n123", "123", "2:1:1")]) {
        httpOutcomeCheck(!httpOutcomeDriverAdmissionValid(raw, owner, nonce, method, false, 2, birth, 2))
    }
    value.put("method", JsonString("中文😀"))
    httpOutcomeCheck(!httpOutcomeDriverAdmissionValid(value.toJsonString().toArray(), "http-outcome-driver-v1\n123", "123", method, false, 2, "2:1:1", 2))
    value.put("method", JsonString(String.join(Array<String>(1024, repeat: "中文😀"))))
    httpOutcomeCheck(!httpOutcomeDriverAdmissionValid(value.toJsonString().toArray(), "http-outcome-driver-v1\n123", "123", method, false, 2, "2:1:1", 2))
}

@When[os == "macOS"]
private func httpOutcomeParent(unknown: Bool, method: String): Unit {
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let home = Path("/private/tmp/metis-http-outcome-" + nonce)
    Directory.create(home); chmod(home.toString(), UInt32(0o700))
    File.writeTo(home.join("owner"), ("http-outcome-v1\n" + nonce).toArray())
    let outer = canonicalize(Path(getVariable("METIS_HTTP_OUTCOME_DRIVER_HOME").getOrThrow()))
    let outerNonce = getVariable("METIS_HTTP_OUTCOME_DRIVER_NONCE").getOrThrow()
    httpOutcomeCheck(httpOutcomeText(outer.join("owner")) == "http-outcome-driver-v1\n" + outerNonce)
    let locator = JsonObject(); locator.put("schema", JsonString("http-outcome-inner-v1"))
    locator.put("outerNonce", JsonString(outerNonce)); locator.put("innerNonce", JsonString(nonce))
    locator.put("innerHome", JsonString(home.toString())); locator.put("launchPending", JsonBool(false))
    File.writeTo(outer.join("inner-home.json"), locator.toJsonString().toArray())
    let environment = HashMap<String, String>(getVariables())
    for (key in environment.keys().toArray()) {
        let upper = key.toAsciiUpper()
        if (key.startsWith("METIS_PROCESS_RECOVERY_") || upper.contains("PROXY") || upper.contains("TOKEN") ||
            upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") || upper.endsWith("_API_KEY")) {
            environment.remove(key)
        }
    }
    for (key in ["BASH_ENV", "ENV", "NODE_OPTIONS", "NODE_V8_COVERAGE"]) { environment.remove(key) }
    environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString(); environment["METIS_HOME"] = home.toString()
    environment["METIS_HTTP_OUTCOME_HOME"] = home.toString(); environment["METIS_HTTP_OUTCOME_NONCE"] = nonce
    environment["METIS_HTTP_OUTCOME_KIND"] = if (unknown) { "unknown" } else { "codes" }
    let fd = httpOutcomeFd(); let tasks = getThreadCount(); let blocking = getBlockingThreadCount()
    var child = None<ManagedOwnedChild>
    var formal = false
    var launchPending = false
    var firstError = None<Exception>
    var actualGroupObserved = false
    var actualGroupGone = false
    var parentCurrentFd = None<Int64>
    var parentCurrentTasks = None<Int64>
    var parentCurrentBlocking = None<Int64>
    var parentFirstFailed = "not_sampled"
    try {
        try (output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
            launchPending = true
            locator.put("launchPending", JsonBool(true)); File.writeTo(outer.join("inner-home.json"), locator.toJsonString().toArray())
            let launched = launchManagedRawChild(getCommand(), ["--filter=GatewayHttpRecoveryOutcomeTest.${method}",
                "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"],
                environment: Some<Map<String, String>>(environment), newGeneration: true,
                stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            child = Some(launched); launchPending = false
            actualGroupObserved = unsafe { getpgid(Int32(launched.pid)) } == Int32(launched.pid)
            let nestedBirth = observeProcessBirthIdentity(launched.pid).getOrThrow().serialize()
            let nested = httpOutcomeDriverRecord(outerNonce, method, unknown, launched.pid, nestedBirth,
                Int64(unsafe { getpgid(Int32(launched.pid)) }))
            File.writeTo(outer.join("nested-handle.json"), nested.toJsonString().toArray())
            locator.put("launchPending", JsonBool(false)); File.writeTo(outer.join("inner-home.json"), locator.toJsonString().toArray())
            httpOutcomeCheck(actualGroupObserved)
            httpOutcomeCheck(launched.wait(timeout: Some(Duration.second * 60)) == 0)
            httpOutcomeCheck(launched.wait() == 0); launched.closeStreams()
            actualGroupGone = httpOutcomeGroupGone(launched.pid)
            httpOutcomeCheck(!launched.isAlive() && launched.streamsAreClosed() && actualGroupGone && !output.isClosed() && !error.isClosed())
        }
        let result = JsonValue.fromStr(httpOutcomeText(home.join("formal-before-fallback.json"))).asObject()
        let cleanup = JsonValue.fromStr(httpOutcomeText(home.join("cleanup.json"))).asObject()
        httpOutcomeCheck(result.get("formal").getOrThrow().asBool().getValue() &&
            cleanup.get("terminal").getOrThrow().asBool().getValue())
        var parentResourcesOk = false
        let currentFd = httpOutcomeFd()
        parentCurrentFd = Some(currentFd)
        if (currentFd != fd) {
            parentFirstFailed = "fd"
        } else {
            let currentTasks = getThreadCount()
            parentCurrentTasks = Some(currentTasks)
            if (currentTasks > tasks) {
                parentFirstFailed = "tasks"
            } else {
                let currentBlocking = getBlockingThreadCount()
                parentCurrentBlocking = Some(currentBlocking)
                if (currentBlocking > blocking) {
                    parentFirstFailed = "blocking"
                } else {
                    parentFirstFailed = "none"
                    parentResourcesOk = true
                }
            }
        }
        httpOutcomeCheck(parentResourcesOk)
        formal = true
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        var reaped = false
        try {
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("beforeFallback", JsonBool(true))
            proof.put("actualGroupObserved", JsonBool(actualGroupObserved)); proof.put("actualGroupGone", JsonBool(actualGroupGone))
            proof.put("resourceMode", JsonString(if (unknown) { "unknown" } else { "codes" }))
            proof.put("baselineFd", JsonInt(fd)); proof.put("baselineTasks", JsonInt(tasks)); proof.put("baselineBlocking", JsonInt(blocking))
            match (parentCurrentFd) {
                case Some(value) => proof.put("currentFd", JsonInt(value))
                case None => proof.put("currentFd", JsonString("not_sampled"))
            }
            match (parentCurrentTasks) {
                case Some(value) => proof.put("currentTasks", JsonInt(value))
                case None => proof.put("currentTasks", JsonString("not_sampled"))
            }
            match (parentCurrentBlocking) {
                case Some(value) => proof.put("currentBlocking", JsonInt(value))
                case None => proof.put("currentBlocking", JsonString("not_sampled"))
            }
            proof.put("firstFailed", JsonString(parentFirstFailed))
            File.writeTo(home.join("parent-formal-before-fallback.json"), proof.toJsonString().toArray())
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        finally {
            if (let Some(value) <- child) {
                try { value.terminate() }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { let code = value.wait(timeout: Some(Duration.second * 5)); reaped = code >= 0 && code <= 255 }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally {
                    try { value.closeStreams() }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
                try { reaped = reaped && !launchPending && !value.isAlive() && value.streamsAreClosed() && httpOutcomeGroupGone(value.pid) }
                catch (error: Exception) { reaped = false; if (firstError.isNone()) { firstError = Some(error) } }
            }
        }
        if ((!reaped || launchPending) && firstError.isNone()) { firstError = Some(Exception("http_recovery_cleanup_pending")) }
        try { println("R-NG-HTTP retained;formal=${formal};driverReaped=${reaped}") }
        catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
    }
    if (let Some(error) <- firstError) { throw error }
}

@When[os == "macOS"]
private func httpOutcomeIsolatedParent(unknown: Bool, method: String): Unit {
    let role = if (unknown) { "driver-unknown" } else { "driver-codes" }
    if (getVariable("METIS_HTTP_OUTCOME_KIND") == Some(role)) {
        // One fixture admission deadline; the suite outer keeps its independent authoritative overall90.
        let admissionDeadline = MonoTime.now() + Duration.second * 5
        try {
            let home = canonicalize(Path(getVariable("METIS_HTTP_OUTCOME_DRIVER_HOME").getOrThrow()))
            let nonce = getVariable("METIS_HTTP_OUTCOME_DRIVER_NONCE").getOrThrow()
            httpOutcomeCheck(home.toString() == "/private/tmp/metis-http-driver-" + nonce)
            while (!exists(home.join("admission.ready")) && MonoTime.now() < admissionDeadline) { sleep(Duration.millisecond * 10) }
            let birth = observeProcessBirthIdentity(getProcessId()).getOrThrow().serialize()
            if (MonoTime.now() >= admissionDeadline || !httpOutcomeDriverAdmissionValid(File.readFrom(home.join("admission.json")),
                httpOutcomeText(home.join("owner")), nonce, method, unknown, getProcessId(), birth,
                Int64(unsafe { getpgid(Int32(getProcessId())) }))) { throw Exception("http_recovery_driver_admission_invalid") }
        } catch (_: Exception) { throw Exception("http_recovery_driver_admission_invalid") }
        httpOutcomeParent(unknown, method); return
    }
    if (getVariable("METIS_HTTP_OUTCOME_KIND").isSome()) { throw Exception("http_recovery_driver_admission_invalid") }
    httpOutcomeDriverAdmissionNegatives()
    let deadline = MonoTime.now() + Duration.second * 90
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let home = Path("/private/tmp/metis-http-driver-" + nonce)
    Directory.create(home); chmod(home.toString(), UInt32(0o700))
    File.writeTo(home.join("owner"), ("http-outcome-driver-v1\n" + nonce).toArray())
    println("R-NG-HTTP-ISO fixture=${home.fileName};nonce=${nonce};mode=${if (unknown) { "unknown" } else { "codes" }}")
    let environment = HashMap<String, String>(getVariables())
    for (key in environment.keys().toArray()) {
        let upper = key.toAsciiUpper()
        if (key.startsWith("METIS_PROCESS_RECOVERY_") || key.startsWith("METIS_HTTP_OUTCOME_") ||
            upper.contains("PROXY") || upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD") ||
            upper.contains("CREDENTIAL") || upper.endsWith("_API_KEY") || upper.endsWith("_ACCESS_KEY_ID")) { environment.remove(key) }
    }
    for (key in ["BASH_ENV", "ENV", "NODE_OPTIONS", "NODE_V8_COVERAGE"]) { environment.remove(key) }
    environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString(); environment["METIS_HOME"] = home.toString()
    environment["METIS_HTTP_OUTCOME_KIND"] = role
    environment["METIS_HTTP_OUTCOME_DRIVER_HOME"] = home.toString(); environment["METIS_HTTP_OUTCOME_DRIVER_NONCE"] = nonce
    var child = None<ManagedOwnedChild>; var output = None<File>; var errorOutput = None<File>
    var launchPending = false; var formal = false; var nestedTerminal = false; var reaped = false
    var firstError = None<Exception>
    var waitCode = None<Int64>; var cachedCode = None<Int64>; var borrowedFilesClosed = false
    try {
        let outFile = File(home.join("stdout"), OpenMode.Write); output = Some(outFile)
        let errFile = File(home.join("stderr"), OpenMode.Write); errorOutput = Some(errFile)
        launchPending = true
        let actual = launchManagedRawChild(getCommand(), ["--filter=GatewayHttpRecoveryOutcomeTest.${method}",
            "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"],
            environment: Some<Map<String, String>>(environment), newGeneration: true,
            stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.FromFile(outFile), stdErr: ProcessRedirect.FromFile(errFile))
        child = Some(actual); launchPending = false
        let birth = observeProcessBirthIdentity(actual.pid).getOrThrow().serialize()
        let pgid = Int64(unsafe { getpgid(Int32(actual.pid)) })
        let admission = httpOutcomeDriverRecord(nonce, method, unknown, actual.pid, birth, pgid).toJsonString().toArray()
        httpOutcomeCheck(httpOutcomeDriverAdmissionValid(admission, httpOutcomeText(home.join("owner")), nonce, method, unknown, actual.pid, birth, pgid))
        File.writeTo(home.join("admission.json"), admission); File.writeTo(home.join("admission.ready"), nonce.toArray())
        let remaining = deadline - MonoTime.now(); httpOutcomeCheck(remaining > Duration.Zero)
        let actualCode = actual.wait(timeout: Some(remaining)); waitCode = Some(actualCode); httpOutcomeCheck(actualCode == 0)
        let actualCached = actual.wait(); cachedCode = Some(actualCached); httpOutcomeCheck(actualCached == 0)
        actual.closeStreams()
        httpOutcomeCheck(!actual.isAlive() && actual.streamsAreClosed() && httpOutcomeGroupGone(actual.pid) && !outFile.isClosed() && !errFile.isClosed())
        outFile.close(); errFile.close(); borrowedFilesClosed = outFile.isClosed() && errFile.isClosed(); httpOutcomeCheck(borrowedFilesClosed)
        let locator = httpOutcomeDriverObject(home.join("inner-home.json"))
        let innerNonce = locator.get("innerNonce").getOrThrow().asString().getValue()
        let inner = canonicalize(Path(locator.get("innerHome").getOrThrow().asString().getValue()))
        httpOutcomeCheck(locator.get("schema").getOrThrow().asString().getValue() == "http-outcome-inner-v1" &&
            locator.get("outerNonce").getOrThrow().asString().getValue() == nonce &&
            !locator.get("launchPending").getOrThrow().asBool().getValue() &&
            inner.toString() == "/private/tmp/metis-http-outcome-" + innerNonce &&
            httpOutcomeText(inner.join("owner")) == "http-outcome-v1\n" + innerNonce)
        let nestedRaw = File.readFrom(home.join("nested-handle.json"))
        let nested = httpOutcomeDriverObject(home.join("nested-handle.json"))
        let pid = nested.get("pid").getOrThrow().asInt().getValue()
        let nestedBirth = parseProcessBirthIdentity(nested.get("birth").getOrThrow().asString().getValue()).getOrThrow()
        httpOutcomeCheck(httpOutcomeDriverAdmissionValid(nestedRaw, httpOutcomeText(home.join("owner")), nonce, method, unknown,
            pid, nestedBirth.serialize(), nested.get("pgid").getOrThrow().asInt().getValue()))
        let source = httpOutcomeFields(httpOutcomeText(inner.join("inventory/inventory")))
        let identity = parseProcessInstanceIdentity(source["parent"]).getOrThrow()
        httpOutcomeCheck(identity.pid == pid && identity.value8 == nestedBirth.seconds && identity.value9 == nestedBirth.microseconds &&
            source["binding"] == "http-outcome-中文😀-" + innerNonce)
        let gone = probeProcessBirthIdentity(nestedBirth, deadline)
        let inventory = managedRecoveryProbeRecords(inner.join("inventory"), source["parent"], source["binding"], deadline)
        let parentProof = httpOutcomeDriverObject(inner.join("parent-formal-before-fallback.json"))
        let childProof = httpOutcomeDriverObject(inner.join("formal-before-fallback.json"))
        let cleanup = httpOutcomeDriverObject(inner.join("cleanup.json"))
        nestedTerminal = gone.conclusive && !gone.alive && httpOutcomeGroupGone(pid) && inventory.ok && inventory.terminal &&
            parentProof.get("formal").getOrThrow().asBool().getValue() && childProof.get("formal").getOrThrow().asBool().getValue() &&
            cleanup.get("terminal").getOrThrow().asBool().getValue()
        httpOutcomeCheck(nestedTerminal && MonoTime.now() <= deadline); formal = true
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        try {
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("beforeFallback", JsonBool(true))
            proof.put("nestedTerminal", JsonBool(nestedTerminal)); proof.put("launchPending", JsonBool(launchPending))
            proof.put("borrowedFilesClosed", JsonBool(borrowedFilesClosed))
            match (waitCode) { case Some(code) => proof.put("waitCode", JsonInt(code)) case None => proof.put("waitCode", JsonString("not_obtained")) }
            match (cachedCode) { case Some(code) => proof.put("cachedCode", JsonInt(code)) case None => proof.put("cachedCode", JsonString("not_obtained")) }
            File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray())
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        finally {
            if (let Some(actual) <- child) {
                try { actual.terminate() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try {
                    let remaining = deadline - MonoTime.now()
                    if (remaining <= Duration.Zero) { throw Exception("http_recovery_driver_deadline") }
                    let code = actual.wait(timeout: Some(remaining)); reaped = code >= 0 && code <= 255
                } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally { try { actual.closeStreams() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } } }
                try { reaped = reaped && !actual.isAlive() && actual.streamsAreClosed() && httpOutcomeGroupGone(actual.pid) }
                catch (error: Exception) { reaped = false; if (firstError.isNone()) { firstError = Some(error) } }
            }
            for (stream in [output, errorOutput]) {
                if (let Some(file) <- stream) {
                    try { file.close(); httpOutcomeCheck(file.isClosed()) }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
            }
        }
        let terminal = reaped && !launchPending && nestedTerminal && MonoTime.now() <= deadline
        try {
            let cleanup = JsonObject(); cleanup.put("terminal", JsonBool(terminal)); cleanup.put("driverReaped", JsonBool(reaped))
            cleanup.put("nestedTerminal", JsonBool(nestedTerminal)); cleanup.put("formal", JsonBool(formal))
            File.writeTo(home.join("cleanup.json"), cleanup.toJsonString().toArray())
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        if ((!formal || !terminal || MonoTime.now() > deadline) && firstError.isNone()) {
            firstError = Some(Exception("http_recovery_driver_cleanup_pending"))
        }
    }
    if (let Some(error) <- firstError) { throw error }
}

@When[os == "macOS"]
@Test
public class GatewayHttpRecoveryOutcomeTest {
    @TestCase
    public func httpOutcomeP1RealCurlCodesAndExecFailureRetire(): Unit {
        if (getVariable("METIS_HTTP_OUTCOME_KIND") == Some("codes")) { httpOutcomeChild(false); return }
        httpOutcomeIsolatedParent(false, "httpOutcomeP1RealCurlCodesAndExecFailureRetire")
    }
    @TestCase
    public func httpOutcomeN1RealVersionFailureRemainsUnknownAndRetires(): Unit {
        if (getVariable("METIS_HTTP_OUTCOME_KIND") == Some("unknown")) { httpOutcomeChild(true); return }
        httpOutcomeIsolatedParent(true, "httpOutcomeN1RealVersionFailureRemainsUnknownAndRetires")
    }
}
