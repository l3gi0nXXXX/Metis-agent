package metis.gateway.runtime

import metis.process.*
import magic.utils.http.{HttpUtils, HttpProcessLaunchProvider, HttpProcessLaunchSpec, setHttpProcessLaunchProvider}
import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, OpenMode, Path, SymbolicLink, canonicalize, exists}
import std.posix.chmod
import std.process.ProcessRedirect
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func attachedAssetCheck(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("attached_broker_asset_contract_failed") }
}
private func attachedAssetText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("attached_broker_fixture_invalid_encoding") }
}
private func attachedAssetRestore(key: String, value: ?String): Unit {
    match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
}
@When[os == "macOS"]
private func attachedAssetFd(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let size = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (size <= 0 || size >= 32768 || size % 8 != 0) { throw Exception("attached_asset_fd_probe_failed") }
        Int64(size / 8)
    } finally { unsafe { LibC.free(buffer) } }
}
@When[os == "macOS"]
private func attachedAssetGroupGone(pid: Int64): Bool {
    if (pid <= 1 || pid > 2147483647) { return false }
    unsafe { kill(-Int32(pid), 0) } != 0 && unsafe { __error().read() } == 3
}
private func attachedAssetWait(action: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.second * 5
    while (MonoTime.now() < deadline) { if (action()) { return true }; sleep(Duration.millisecond * 5) }
    action()
}
private class AttachedAssetHttpProvider <: HttpProcessLaunchProvider {
    let inner: GatewayHttpRecoveryLaunchProvider
    var actualScript = ""
    init(inner: GatewayHttpRecoveryLaunchProvider) { this.inner = inner }
    public func prepare(command: String, args: Array<String>): HttpProcessLaunchSpec {
        let spec = inner.prepare(command, args)
        actualScript = spec.args[0]
        spec
    }
}
@When[os == "macOS"]
private class AttachedAssetBirths {
    let births = ArrayList<ProcessBirthIdentity>()
    let groups = ArrayList<Int64>()
    func snapshot(home: Path, directory: Path, parent: String): Unit {
        for (key in ["r-1", "r-1-o-1"]) {
            let path = directory.join(key + ".birth")
            let raw = File.readFrom(path); File.writeTo(home.join(key + ".birth"), raw)
            let fields = HashMap<String, String>()
            for (line in attachedAssetText(path).split("\n")) {
                if (!line.contains(":")) { continue }
                let parts = line.split(":")
                attachedAssetCheck(parts.size >= 2 && !fields.contains(parts[0]))
                fields[parts[0]] = String.join(parts[1..], delimiter: ":")
            }
            attachedAssetCheck(fields["parent"] == parent && fields["key"] == key && fields["phase"] == "birth")
            let birth = parseProcessBirthIdentity(fields["birth"]).getOrThrow()
            attachedAssetCheck(birth.pid == Int64.parse(fields["pid"]) &&
                observeProcessBirthIdentity(birth.pid)?.serialize() == Some(birth.serialize()))
            let group = Int64(unsafe { getpgid(Int32(birth.pid)) })
            attachedAssetCheck(group == birth.pid)
            births.add(birth); groups.add(group)
        }
        attachedAssetCheck(Int64.parse(attachedAssetText(home.join("business-marker"))) == births[1].pid)
    }
    func gone(): Bool {
        if (births.size != 2 || groups.size != 2) { return false }
        for (birth in births) {
            let state = probeProcessBirthIdentity(birth, MonoTime.now() + Duration.second)
            if (!state.conclusive || state.alive) { return false }
        }
        for (group in groups) { if (!attachedAssetGroupGone(group)) { return false } }
        true
    }
}

@When[os == "macOS"]
private func attachedAssetChild(http: Bool): Unit {
    let home = canonicalize(Path(getVariable("METIS_ATTACHED_ASSET_HOME").getOrThrow()))
    let nonce = getVariable("METIS_ATTACHED_ASSET_NONCE").getOrThrow()
    attachedAssetCheck(home.toString().startsWith("/private/tmp/") && attachedAssetText(home.join("owner")) == "attached-asset-v1\n" + nonce)
    let old = ArrayList<(String, ?String)>()
    for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT", "METIS_STDIO_BROKER_NODE_COMMAND", "PATH"]) {
        old.add((key, getVariable(key)))
    }
    let actualBroker = canonicalize(Path(managedStdioResolveBrokerScriptPath())).toString()
    let actualNode = managedStdioResolveNodeCommand()
    let directory = home.join("inventory")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let binding = "asset-中文😀-" + nonce
    attachedAssetCheck(managedRecoveryInitialize(directory, parent, binding))
    let inner = GatewayHttpRecoveryLaunchProvider((directory.toString(), parent), binding: Some(binding))
    let provider = AttachedAssetHttpProvider(inner)
    let previous = setHttpProcessLaunchProvider(None)
    let _ = setHttpProcessLaunchProvider(previous)
    attachedAssetCheck(previous.isNone())
    let birth = AttachedAssetBirths()
    var child = None<ManagedOwnedChild>
    var worker = None<Future<Bool>>
    var joined = false
    var formal = false
    var terminal = false
    var envRestored = false
    var providerRestored = false
    var rejected: Int64 = 0
    var launchPending = false
    var firstError = None<Exception>
    let fd = attachedAssetFd(); let tasks = getThreadCount(); let blocking = getBlockingThreadCount()
    try {
        let missing = home.join("missing-broker.mjs")
        let asDirectory = home.join("directory-broker"); Directory.create(asDirectory)
        for (path in [missing, asDirectory]) {
            setVariable("METIS_STDIO_BROKER_SCRIPT", path.toString())
            var fixed = false
            var returned = false
            try {
                if (http) { let _ = inner.prepare("/usr/bin/touch", [home.join("unexpected-marker").toString()]); returned = true }
                else {
                    launchPending = true
                    let launched = managedRecoveryLaunchOwned("/usr/bin/touch", [home.join("unexpected-marker").toString()],
                        stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
                    child = Some(launched); launchPending = false; returned = true
                }
            } catch (error: Exception) { fixed = error.message == "owned_process_internal_asset_invalid" }
            var intent = false
            for (entry in Directory.readFrom(directory)) { if (entry.name.endsWith(".intent")) { intent = true } }
            let noIssued = !exists(directory.join(".issued"))
            let pass = fixed && !returned && !intent && noIssued && !exists(home.join("unexpected-marker"))
            let result = JsonObject(); result.put("formal", JsonBool(pass)); result.put("fixedError", JsonBool(fixed))
            result.put("returned", JsonBool(returned)); result.put("noIntent", JsonBool(!intent)); result.put("issuedZero", JsonBool(noIssued))
            result.put("beforeFallback", JsonBool(true))
            File.writeTo(home.join(if (path == missing) { "missing.formal.json" } else { "directory.formal.json" }), result.toJsonString().toArray())
            attachedAssetCheck(pass)
            rejected += 1
            attachedAssetRestore("METIS_STDIO_BROKER_SCRIPT", old[2][1])
            attachedAssetCheck(getVariable("METIS_STDIO_BROKER_SCRIPT") == old[2][1])
            attachedAssetCheck(attachedAssetFd() == fd && getThreadCount() <= tasks && getBlockingThreadCount() <= blocking)
        }
        let link = home.join("broker-link.mjs"); SymbolicLink.create(link, to: Path(actualBroker))
        setVariable("METIS_STDIO_BROKER_SCRIPT", link.toString())
        setVariable("METIS_STDIO_BROKER_NODE_COMMAND", actualNode)
        let release = home.join("release")
        let script = "printf '%s' \"$$\" > \"$METIS_ATTACHED_ASSET_HOME/business-marker\"; " +
            "while [ ! -f \"$METIS_ATTACHED_ASSET_HOME/release\" ]; do /bin/sleep 0.01; done; "
        if (http) {
            let bin = home.join("bin"); Directory.create(bin)
            let curl = bin.join("curl")
            File.writeTo(curl, ("#!/bin/sh\n" + script + "printf 'HTTP-asset-中文😀'; exit 0\n").toArray())
            chmod(curl.toString(), UInt32(0o755)); setVariable("PATH", bin.toString())
            let _ = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(provider))
            launchPending = true
            worker = Some(spawn { HttpUtils.get("http://127.0.0.1:9/owned-fake-no-network", HashMap<String, String>(), None) == Some("HTTP-asset-中文😀") })
            launchPending = false
        } else {
            launchPending = true
            let launched = managedRecoveryLaunchOwned("/bin/sh", ["-c", script + "printf 'owned-asset-中文😀'; exit 7"],
                stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Discard)
            child = Some(launched); launchPending = false
            worker = Some(spawn {
                let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(1024, repeat: 0)
                try {
                    while (true) { let count = launched.stdOutPipe.read(buffer); if (count == 0) { break }; bytes.add(all: buffer[..count]) }
                    let code = launched.wait(timeout: Some(Duration.second * 5))
                    code == 7 && launched.wait() == 7 && bytes.toArray() == "owned-asset-中文😀".toArray()
                } finally { launched.closeStreams() }
            })
        }
        attachedAssetCheck(attachedAssetWait({ => exists(home.join("business-marker")) }))
        birth.snapshot(home, directory, parent)
        if (http) { attachedAssetCheck(provider.actualScript == actualBroker) }
        File.writeTo(release, "release".toArray())
        attachedAssetCheck(worker.getOrThrow().get(Duration.second * 5)); joined = true
        if (let Some(value) <- child) { attachedAssetCheck(!value.isAlive() && value.streamsAreClosed()) }
        let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 5)
        attachedAssetCheck(source.ok && source.terminal && birth.gone() && File.readFrom(directory.join(".issued")) == ("managed-recovery-v1\nparent:${parent}\nissued:1\n").toArray())
        attachedAssetCheck(rejected == 2 && attachedAssetFd() == fd && getThreadCount() <= tasks && getBlockingThreadCount() <= blocking)
        formal = true
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        try {
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("beforeFallback", JsonBool(true))
            proof.put("negativeCount", JsonInt(rejected)); proof.put("positiveCount", JsonInt(if (formal) { 1 } else { 0 }))
            proof.put("workerJoined", JsonBool(joined)); proof.put("identitiesGone", JsonBool(birth.gone()))
            File.writeTo(home.join("child-formal-before-fallback.json"), proof.toJsonString().toArray())
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        finally {
            try { inner.closeAdmission() }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            // Release only this owned fixture's peer barrier, after recording formal truth.
            try { File.writeTo(home.join("release"), "release".toArray()) }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            if (let Some(value) <- child) {
                try { value.terminate() }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { let _ = value.wait(timeout: Some(Duration.second * 5)) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally {
                    try { value.closeStreams() }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
            }
            if (let Some(value) <- worker) {
                try { let _ = value.get(Duration.second * 5); joined = true }
                catch (error: Exception) { joined = false; if (firstError.isNone()) { firstError = Some(error) } }
            }
            try {
                let source = managedRecoveryProbeRecords(directory, parent, binding, MonoTime.now() + Duration.second * 5)
                terminal = !launchPending && joined && source.ok && source.terminal && birth.gone()
            } catch (error: Exception) { terminal = false; if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try {
                    let installed = setHttpProcessLaunchProvider(previous)
                    providerRestored = if (http) { installed.isSome() && refEq((installed.getOrThrow() as Object).getOrThrow(), (provider as Object).getOrThrow()) } else { installed.isNone() }
                    let verify = setHttpProcessLaunchProvider(previous)
                    providerRestored = providerRestored && verify.isNone()
                } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                envRestored = true
                for ((key, value) in old) {
                    try { attachedAssetRestore(key, value); envRestored = envRestored && getVariable(key) == value }
                    catch (error: Exception) { envRestored = false; if (firstError.isNone()) { firstError = Some(error) } }
                }
            }
        }
        try {
            let cleanup = JsonObject(); cleanup.put("terminal", JsonBool(terminal)); cleanup.put("envRestored", JsonBool(envRestored))
            cleanup.put("providerRestored", JsonBool(providerRestored))
            File.writeTo(home.join("child-cleanup.json"), cleanup.toJsonString().toArray())
            attachedAssetCheck(formal && terminal && envRestored && providerRestored)
        } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
    }
    if (let Some(error) <- firstError) { throw error }
}

@When[os == "macOS"]
private func attachedAssetParent(http: Bool, method: String): Unit {
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let home = Path("/private/tmp/metis-attached-asset-" + nonce); Directory.create(home); chmod(home.toString(), UInt32(0o700))
    File.writeTo(home.join("owner"), ("attached-asset-v1\n" + nonce).toArray())
    let environment = HashMap<String, String>(getVariables())
    for (key in environment.keys().toArray()) {
        let upper = key.toAsciiUpper()
        if (key.startsWith("METIS_PROCESS_RECOVERY_") || upper.contains("PROXY") || upper.contains("TOKEN") ||
            upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") || upper.endsWith("_API_KEY")) { environment.remove(key) }
    }
    for (key in ["BASH_ENV", "ENV", "NODE_OPTIONS", "NODE_V8_COVERAGE"]) { environment.remove(key) }
    environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString(); environment["METIS_HOME"] = home.toString()
    environment["METIS_ATTACHED_ASSET_HOME"] = home.toString(); environment["METIS_ATTACHED_ASSET_NONCE"] = nonce
    environment["METIS_ATTACHED_ASSET_KIND"] = if (http) { "http" } else { "owned" }
    let initialFd = attachedAssetFd(); let initialTasks = getThreadCount(); let initialBlocking = getBlockingThreadCount()
    var child = None<ManagedOwnedChild>
    var actualBirth = None<ProcessBirthIdentity>
    var formal = false
    var launchPending = false
    var firstError = None<Exception>
    var groupObserved = false
    var groupGone = false
    try {
        try (output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
            launchPending = true
            let launched = launchManagedRawChild(getCommand(), ["--filter=GatewayAttachedBrokerAssetTest.${method}",
                "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], newGeneration: true,
                environment: Some<Map<String, String>>(environment), stdIn: ProcessRedirect.Discard,
                stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            child = Some(launched); launchPending = false; actualBirth = observeProcessBirthIdentity(launched.pid)
            groupObserved = unsafe { getpgid(Int32(launched.pid)) } == Int32(launched.pid)
            attachedAssetCheck(groupObserved && actualBirth.isSome())
            attachedAssetCheck(launched.wait(timeout: Some(Duration.second * 60)) == 0 && launched.wait() == 0)
            launched.closeStreams(); groupGone = attachedAssetGroupGone(launched.pid)
            let state = probeProcessBirthIdentity(actualBirth.getOrThrow(), MonoTime.now() + Duration.second)
            attachedAssetCheck(!launched.isAlive() && launched.streamsAreClosed() && state.conclusive && !state.alive && groupGone)
            attachedAssetCheck(!output.isClosed() && !error.isClosed())
        }
        let proof = JsonValue.fromStr(attachedAssetText(home.join("child-formal-before-fallback.json"))).asObject()
        let cleanup = JsonValue.fromStr(attachedAssetText(home.join("child-cleanup.json"))).asObject()
        attachedAssetCheck(proof.get("formal").getOrThrow().asBool().getValue() &&
            cleanup.get("terminal").getOrThrow().asBool().getValue() && cleanup.get("envRestored").getOrThrow().asBool().getValue() &&
            cleanup.get("providerRestored").getOrThrow().asBool().getValue())
        attachedAssetCheck(attachedAssetFd() == initialFd && getThreadCount() <= initialTasks && getBlockingThreadCount() <= initialBlocking)
        formal = true
    } catch (error: Exception) { firstError = Some(error) }
    finally {
        var reaped = false
        try {
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("beforeFallback", JsonBool(true))
            proof.put("actualGroupObserved", JsonBool(groupObserved)); proof.put("actualGroupGone", JsonBool(groupGone))
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
                try { reaped = reaped && !launchPending && !value.isAlive() && value.streamsAreClosed() && attachedAssetGroupGone(value.pid) }
                catch (error: Exception) { reaped = false; if (firstError.isNone()) { firstError = Some(error) } }
            }
        }
        if ((!reaped || launchPending) && firstError.isNone()) { firstError = Some(Exception("attached_asset_cleanup_pending")) }
        try { println("R-NG-ASSET fixture=${home.fileName};formal=${formal};driverReaped=${reaped}") }
        catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
    }
    if (let Some(error) <- firstError) { throw error }
}

@When[os == "macOS"]
@Test
public class GatewayAttachedBrokerAssetTest {
    @TestCase
    public func ownedN1P1MissingDirectoryAndSymlink(): Unit {
        if (getVariable("METIS_ATTACHED_ASSET_KIND") == Some("owned")) { attachedAssetChild(false); return }
        attachedAssetParent(false, "ownedN1P1MissingDirectoryAndSymlink")
    }
    @TestCase
    public func httpN1P1MissingDirectoryAndSymlink(): Unit {
        if (getVariable("METIS_ATTACHED_ASSET_KIND") == Some("http")) { attachedAssetChild(true); return }
        attachedAssetParent(true, "httpN1P1MissingDirectoryAndSymlink")
    }
}
