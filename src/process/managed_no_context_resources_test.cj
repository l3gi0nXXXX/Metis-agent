package metis.process

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists, rename}
import std.io.InputStream
import std.process.ProcessRedirect
import std.runtime.{getMaxHeapSize, getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func nxRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("no_context_resource_contract_failed") }
}
private func nxText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("no_context_fixture_invalid_encoding") }
}
private func nxJson(path: Path): JsonObject {
    try { JsonValue.fromStr(nxText(path)).asObject() }
    catch (_: Exception) { throw Exception("no_context_fixture_malformed_json") }
}
private func nxAtomic(path: Path, bytes: Array<Byte>): Unit {
    let pending = path.parent.join(path.fileName + ".pending")
    File.writeTo(pending, bytes); rename(pending, to: path)
}
private func nxUntil(deadline: MonoTime, check: () -> Bool): Bool {
    while (MonoTime.now() < deadline) { if (check()) { return true }; sleep(Duration.millisecond) }
    check()
}
private func nxRead(stream: InputStream): Array<Byte> {
    let result = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return result.toArray() }
        nxRequire(count > 0 && result.size + count <= 1048576); result.add(all: buffer[..count])
    }
    result.toArray()
}
private func nxBytes(error!: Bool = false): Array<Byte> {
    (if (error) { "错误😀" } else { "输出中文😀" }).toArray().concat([0u8, 0xffu8, 0xfeu8])
}
// Release only a directly owned, nonce-bound fixed fixture directory; never follow links.
private func nxReleaseBoundRun(home: Path, run: Path, nonce: String): Unit {
    nxRequire(canonicalize(home) == home && home.toString().startsWith("/private/tmp/") &&
        FileInfo(home).isDirectory() && !FileInfo(home).isSymbolicLink())
    let owner = home.join("owner")
    nxRequire(FileInfo(owner).isRegular() && !FileInfo(owner).isSymbolicLink() && nxText(owner) == "no-context-resource-v1\n" + nonce)
    var permitted = false
    for (index in 0..2) { permitted = permitted || run == home.join("warm-${index}") }
    for (index in 0..32) { permitted = permitted || run == home.join("round-${index}") }
    nxRequire(permitted && run.parent == home && FileInfo(run).isDirectory() && !FileInfo(run).isSymbolicLink() && canonicalize(run) == run)
    let binding = run.join("binding")
    nxRequire(FileInfo(binding).isRegular() && !FileInfo(binding).isSymbolicLink() && nxText(binding) == nonce)
    let release = run.join("release"); var released = false
    // Directory entries also expose dangling links; exists() alone cannot admit a write target.
    for (entry in Directory.readFrom(run)) {
        if (entry.name == "release" || entry.name == "release.pending") {
            nxRequire(entry.isRegular() && !entry.isSymbolicLink() && FileInfo(entry.path).size == nonce.toArray().size && File.readFrom(entry.path) == nonce.toArray())
            if (entry.name == "release") { released = true }
        }
    }
    if (!released) { nxAtomic(release, nonce.toArray()) }
}

@When[os == "macOS"]
private func nxGroupGone(pid: Int64): Bool { unsafe { kill(Int32(-pid), 0) } != 0 && unsafe { __error().read() } == 3 }

@When[os == "macOS"]
private class NxChild {
    let home = canonicalize(Path(getVariable("METIS_NOCTX_HOME").getOrThrow()))
    let nonce = getVariable("METIS_NOCTX_NONCE").getOrThrow()
    let kind = getVariable("METIS_NOCTX_KIND").getOrThrow()
    let handles = ArrayList<ManagedOwnedChild>()
    let readers = ArrayList<Future<Array<Byte>>>()
    let readerJoined = ArrayList<Bool>()
    let observers = ArrayList<Future<Bool>>()
    let observerJoined = ArrayList<Bool>()
    let broker: ManagedStdioBrokerClient
    var baselineFd: Int64 = 0
    var baselineTasks: Int64 = 0
    var baselineBlocking: Int64 = 0
    var calls: Int64 = 0
    var formal = false
    init() {
        nxRequire(home.toString().startsWith("/private/tmp/") && nxText(home.join("owner")) == "no-context-resource-v1\n" + nonce)
        nxRequire(getMaxHeapSize() == 67108864 && managedRecoveryContext()[0].isEmpty() && managedRecoveryContext()[1].isEmpty())
        let expectedWriterPath = home.join("expected-writer")
        nxRequire(nxUntil(MonoTime.now() + Duration.second * 5, { => exists(expectedWriterPath) }))
        let writer = nxJson(home.join("expected-writer"))
        nxRequire(writer.getFields().size == 3 && writer.get("nonce").getOrThrow().asString().getValue() == nonce &&
            writer.get("pid").getOrThrow().asInt().getValue() == getProcessId() &&
            observeProcessBirthIdentity(getProcessId())?.serialize() == Some(writer.get("birth").getOrThrow().asString().getValue()))
        nxRequire(unsafe { getpgid(Int32(getProcessId())) } == Int32(getProcessId()))
        broker = ManagedStdioBrokerClient(nodeCommand: getVariable("METIS_STDIO_BROKER_NODE_COMMAND").getOrThrow(),
            brokerScriptPath: getVariable("METIS_NOCTX_BROKER").getOrThrow())
    }
    func prepare(): Unit {
        for (index in 0..2) { run(index, warm: true) }
        calls = 0; baselineFd = ownedTestFdCount(); baselineTasks = getThreadCount(); baselineBlocking = getBlockingThreadCount()
    }
    func noSource(): Bool { managedRecoveryContext()[0].isEmpty() && managedRecoveryContext()[1].isEmpty() && !exists(home.join("inventory")) }
    func checkpoint(): Unit {
        let settled = nxUntil(MonoTime.now() + Duration.second * 2, { => noSource() && ownedTestFdCount() == baselineFd &&
            getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking })
        let row = JsonObject(); row.put("calls", JsonInt(calls)); row.put("fd", JsonInt(ownedTestFdCount())); row.put("baselineFd", JsonInt(baselineFd))
        row.put("tasks", JsonInt(getThreadCount())); row.put("baselineTasks", JsonInt(baselineTasks)); row.put("blocking", JsonInt(getBlockingThreadCount()))
        row.put("baselineBlocking", JsonInt(baselineBlocking)); row.put("sourceTerminal", JsonBool(noSource())); row.put("settled", JsonBool(settled))
        File.writeTo(home.join("resource-checkpoint.json"), row.toJsonString().toArray()); nxRequire(settled)
    }
    func observeBusiness(run: Path): Bool {
        nxRequire(nxUntil(MonoTime.now() + Duration.second * 5, { => exists(run.join("ready")) }))
        let pid = Int64.parse(nxText(run.join("ready"))); let birth = observeProcessBirthIdentity(pid).getOrThrow()
        nxRequire(unsafe { getpgid(Int32(pid)) } == Int32(getProcessId()) && observeProcessBirthIdentity(pid)?.serialize() == Some(birth.serialize()))
        let proof = JsonObject(); proof.put("pid", JsonInt(pid)); proof.put("birth", JsonString(birth.serialize())); proof.put("pgid", JsonInt(getProcessId()))
        File.writeTo(run.join("actual-business-birth.json"), proof.toJsonString().toArray()); nxReleaseBoundRun(home, run, nonce); true
    }
    func businessScript(): String {
        "printf '%s' \"$$\" > \"$1/ready.pending\"; /bin/mv \"$1/ready.pending\" \"$1/ready\"; " +
        "while [ ! -f \"$1/release\" ]; do /bin/sleep 0.005; done; " +
        "printf '输出中文😀\\000\\377\\376'; printf '错误😀\\000\\377\\376' >&2; exit 7"
    }
    func raw(run: Path): Unit {
        let child = launchManagedRawChild("/bin/sh", ["-c", businessScript(), "owned", run.toString()],
            stdIn: ProcessRedirect.Inherit, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
        handles.add(child)
        readers.add(spawn { nxRead(child.stdOutPipe) }); readerJoined.add(false)
        readers.add(spawn { nxRead(child.stdErrPipe) }); readerJoined.add(false)
        nxRequire(observeBusiness(run))
        let first = readers.size - 2; let stdout = readers[first].get(Duration.second * 5); readerJoined[first] = true
        let stderr = readers[first + 1].get(Duration.second * 5); readerJoined[first + 1] = true
        File.writeTo(run.join("stdout"), stdout); File.writeTo(run.join("stderr"), stderr)
        nxRequire(stdout == nxBytes() && stderr == nxBytes(error: true))
        let code = child.wait(timeout: Some(Duration.second * 5)); nxRequire(code == 7 && child.wait() == 7 && !child.isAlive())
        child.closeStreams(); nxRequire(child.streamsAreClosed() && observeProcessBirthIdentity(child.pid).isNone())
    }
    func observeHandoff(run: Path): Bool {
        var original = None<Exception>; var observed = false
        try { observed = observeBusiness(run) }
        catch (failure: Exception) {
            original = Some(failure)
            try { File.writeTo(run.join("observer-formal-before-release.json"),
                "{\"observed\":false,\"status\":\"observer_failed\",\"recordedBeforeFallbackRelease\":true}".toArray()) }
            catch (_: Exception) { @Expect(false, true) }
        } finally {
            try { nxReleaseBoundRun(home, run, nonce) }
            catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        }
        if (let Some(failure) <- original) { throw failure }
        observed
    }
    func handoff(run: Path): Unit {
        let observer = spawn { observeHandoff(run) }; observers.add(observer); observerJoined.add(false)
        let result = managedRecoveryExecuteHandoffWithOutput("/bin/sh", ["-c", businessScript(), "owned", run.toString()], workingDirectory: Some(home))
        File.writeTo(run.join("stdout"), result[1]); File.writeTo(run.join("stderr"), result[2])
        nxRequire(observer.get(Duration.second * 5)); observerJoined[observers.size - 1] = true
        nxRequire(result[0] == 7 && result[1] == nxBytes() && result[2] == nxBytes(error: true))
        let proof = nxJson(run.join("actual-business-birth.json")); let pid = proof.get("pid").getOrThrow().asInt().getValue()
        nxRequire(observeProcessBirthIdentity(pid).isNone())
    }
    func brokerRound(run: Path): Unit {
        let before = broker.snapshot(); let started = broker.ensureBrokerRunning()
        nxRequire(started.ok)
        let live = broker.snapshot(); let birth = observeProcessBirthIdentity(live.brokerPid).getOrThrow()
        nxRequire(live.running && live.responsive && live.generation == before.generation + 1 && live.ownerCount == 0 &&
            unsafe { getpgid(Int32(live.brokerPid)) } == Int32(getProcessId()) && observeProcessBirthIdentity(live.brokerPid)?.serialize() == Some(birth.serialize()))
        let identity = JsonObject(); identity.put("pid", JsonInt(live.brokerPid)); identity.put("birth", JsonString(birth.serialize())); identity.put("generation", JsonInt(live.generation))
        File.writeTo(run.join("actual-broker-birth.json"), identity.toJsonString().toArray())
        let closed = broker.close(); let final = broker.snapshot()
        nxRequire(closed.ok && closed.externalTerminal && closed.terminalBasis == "closed_ack_exit_observed" && !final.running && !final.responsive &&
            final.ownerCount == 0 && final.readerCount == 0 && final.dispatcherCount == 0 && observeProcessBirthIdentity(live.brokerPid).isNone())
        File.writeTo(run.join("protocol-terminal.json"), ("{\"hello\":true,\"closedAck\":true,\"actualExitObserved\":true,\"generation\":${live.generation}}").toArray())
    }
    func run(index: Int64, warm!: Bool = false): Unit {
        let run = home.join((if (warm) { "warm-" } else { "round-" }) + index.toString()); Directory.create(run)
        File.writeTo(run.join("binding"), nonce.toArray())
        if (kind == "raw") { raw(run) } else if (kind == "handoff") { handoff(run) } else if (kind == "broker") { brokerRound(run) }
        else { throw Exception("no_context_fixture_kind_invalid") }
        nxRequire(noSource())
        if (!warm) { calls += 1; checkpoint() }
    }
    func finish(): Unit {
        var proofSaved = false; var terminal = true
        try {
            try {
                var joined = true; for (value in readerJoined) { joined = joined && value }; for (value in observerJoined) { joined = joined && value }
                let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("calls", JsonInt(calls)); proof.put("kind", JsonString(kind)); proof.put("nonce", JsonString(nonce))
                proof.put("sourceTerminalBeforeFallback", JsonBool(noSource())); proof.put("workersJoined", JsonBool(joined)); proof.put("recordedBeforeFallback", JsonBool(true))
                proof.put("heapBytes", JsonInt(getMaxHeapSize())); File.writeTo(home.join("child-formal-before-fallback.json"), proof.toJsonString().toArray()); proofSaved = true
            } catch (_: Exception) { @Expect(false, true) }
        } finally {
            let deadline = MonoTime.now() + Duration.second * 3
            for (child in handles) {
                try {
                    if (child.isAlive()) { child.terminate() }
                    let left = deadline - MonoTime.now(); if (left <= Duration.Zero) { terminal = false; continue }
                    let code = child.wait(timeout: Some(left)); terminal = terminal && code >= 0 && code <= 255 && child.wait() == code && !child.isAlive() && observeProcessBirthIdentity(child.pid).isNone()
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
                finally { try { child.closeStreams(); terminal = terminal && child.streamsAreClosed() } catch (_: Exception) { terminal = false; @Expect(false, true) } }
            }
            for (index in 0..readers.size) {
                if (!readerJoined[index]) { let left = deadline - MonoTime.now(); if (left <= Duration.Zero) { terminal = false; continue }
                    try { let _ = readers[index].get(left); readerJoined[index] = true } catch (_: Exception) { terminal = false; @Expect(false, true) } }
            }
            for (index in 0..observers.size) {
                if (!observerJoined[index]) { let left = deadline - MonoTime.now(); if (left <= Duration.Zero) { terminal = false; continue }
                    try { let _ = observers[index].get(left); observerJoined[index] = true } catch (_: Exception) { terminal = false; @Expect(false, true) } }
            }
            try {
                let left = deadline - MonoTime.now()
                if (left <= Duration.Zero) { terminal = false } else { let result = broker.close(timeoutMs: left.toMilliseconds()); terminal = terminal && result.ok }
                let final = broker.snapshot(); terminal = terminal && !final.running && final.ownerCount == 0 && final.readerCount == 0 && final.dispatcherCount == 0 && noSource() && MonoTime.now() <= deadline
            } catch (_: Exception) { terminal = false; @Expect(false, true) }
            try { File.writeTo(home.join("child-cleanup.json"), ("{\"terminal\":${terminal},\"proofSaved\":${proofSaved},\"retained\":true}").toArray()) }
            catch (_: Exception) { @Expect(false, true) }
            @Expect(terminal, true); @Expect(proofSaved, true)
        }
    }
}

@When[os == "macOS"]
private func nxChild(): Unit {
    let fixture = NxChild()
    try { fixture.prepare(); for (index in 0..32) { fixture.run(index) }; nxRequire(fixture.calls == 32); fixture.formal = true }
    finally { fixture.finish() }
}

@When[os == "macOS"]
private func nxParent(kind: String, method: String): Unit {
    if (getVariable("METIS_NOCTX_KIND") == Some(kind)) { nxChild(); return }
    nxRequire(getMaxHeapSize() == 67108864)
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow())); let node = managedStdioResolveNodeCommand()
    nxRequire(Path(node).isAbsolute() && exists(Path(node)))
    let home = canonicalize(Directory.createTemp("/private/tmp")); let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    File.writeTo(home.join("owner"), ("no-context-resource-v1\n" + nonce).toArray())
    println("R-NOCTX fixture=${home.fileName};nonce=${nonce};kind=${kind}")
    let baselineFd = ownedTestFdCount(); let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
    let handles = ArrayList<ManagedOwnedChild>(); let births = ArrayList<ProcessBirthIdentity>()
    var formal = false; var proofSaved = false; var pendingLaunch = false
    try {
        let source = home.join("source-inputs"); Directory.create(source)
        for (name in ["src/process/managed_owned_child.cj", "src/process/managed_stdio_broker.cj", "src/process/managed_no_context_resources_test.cj", "scripts/metis-stdio-broker.mjs"]) {
            File.writeTo(source.join(Path(name).fileName), File.readFrom(project.join(name)))
        }
        let env = HashMap<String, String>()
        for ((name, value) in getVariables()) {
            if (["PATH", "LANG", "CANGJIE_HOME", "CANGJIE_PATH", "CANGJIE_STDX_PATH", "MAGIC_PATH", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SDKROOT", "cjHeapSize"].contains(name)) { env[name] = value }
        }
        env["HOME"] = home.toString(); env["TMPDIR"] = home.toString(); env["METIS_HOME"] = home.toString()
        env["METIS_NOCTX_KIND"] = kind; env["METIS_NOCTX_HOME"] = home.toString(); env["METIS_NOCTX_NONCE"] = nonce
        env["METIS_NOCTX_BROKER"] = project.join("scripts/metis-stdio-broker.mjs").toString(); env["METIS_STDIO_BROKER_NODE_COMMAND"] = node
        try (input = File(home.join("stdin"), OpenMode.ReadWrite), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
            pendingLaunch = true
            let child = launchManagedRawChild(getCommand(), ["--filter=ManagedNoContextResourcesTest.${method}", "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"],
                newGeneration: true, workingDirectory: Some(home), environment: env, stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            handles.add(child); pendingLaunch = false; let birth = observeProcessBirthIdentity(child.pid).getOrThrow(); births.add(birth)
            nxRequire(unsafe { getpgid(Int32(child.pid)) } == Int32(child.pid))
            let writer = JsonObject(); writer.put("nonce", JsonString(nonce)); writer.put("pid", JsonInt(child.pid)); writer.put("birth", JsonString(birth.serialize()))
            nxAtomic(home.join("expected-writer"), writer.toJsonString().toArray())
            let code = child.wait(timeout: Some(Duration.second * 60)); child.closeStreams()
            nxRequire(code == 0 && child.wait() == 0 && child.streamsAreClosed() && !child.isAlive() && observeProcessBirthIdentity(child.pid).isNone() && nxGroupGone(child.pid) &&
                !input.isClosed() && !output.isClosed() && !error.isClosed())
        }
        let proof = nxJson(home.join("child-formal-before-fallback.json")); let cleanup = nxJson(home.join("child-cleanup.json"))
        nxRequire(proof.get("formal").getOrThrow().asBool().getValue() && proof.get("nonce").getOrThrow().asString().getValue() == nonce && proof.get("kind").getOrThrow().asString().getValue() == kind &&
            proof.get("calls").getOrThrow().asInt().getValue() == 32 && proof.get("heapBytes").getOrThrow().asInt().getValue() == 67108864 && proof.get("sourceTerminalBeforeFallback").getOrThrow().asBool().getValue() &&
            proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue() && proof.get("workersJoined").getOrThrow().asBool().getValue() && cleanup.get("terminal").getOrThrow().asBool().getValue() && cleanup.get("proofSaved").getOrThrow().asBool().getValue())
        nxRequire(nxUntil(MonoTime.now() + Duration.second * 2, { => ownedTestFdCount() == baselineFd && getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking }))
        formal = true
    } finally {
        try {
            try { File.writeTo(home.join("parent-formal-before-fallback.json"), ("{\"formal\":${formal},\"recordedBeforeFallback\":true,\"retained\":true}").toArray()); proofSaved = true }
            catch (_: Exception) { @Expect(false, true) }
        } finally {
            let deadline = MonoTime.now() + Duration.second * 3; var terminal = !pendingLaunch
            for (prefix in ["warm-", "round-"]) {
                let count: Int64 = if (prefix == "warm-") { 2 } else { 32 }
                for (index in 0..count) {
                    let run = home.join(prefix + index.toString())
                    if (exists(run)) {
                        if (MonoTime.now() >= deadline) { terminal = false; continue }
                        try { nxReleaseBoundRun(home, run, nonce) }
                        catch (_: Exception) { terminal = false; @Expect(false, true) }
                    }
                }
            }
            for (index in 0..handles.size) {
                let child = handles[index]
                try {
                    if (child.isAlive() && index < births.size && observeProcessBirthIdentity(child.pid)?.serialize() == Some(births[index].serialize())) { child.terminate() }
                    let left = deadline - MonoTime.now(); if (left <= Duration.Zero) { terminal = false; continue }
                    let code = child.wait(timeout: Some(left)); terminal = terminal && code >= 0 && code <= 255 && child.wait() == code && !child.isAlive() && observeProcessBirthIdentity(child.pid).isNone() && nxGroupGone(child.pid)
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
                finally { try { child.closeStreams(); terminal = terminal && child.streamsAreClosed() } catch (_: Exception) { terminal = false; @Expect(false, true) } }
            }
            terminal = terminal && MonoTime.now() <= deadline
            try { File.writeTo(home.join("parent-cleanup.json"), ("{\"driverTerminal\":${terminal},\"proofSaved\":${proofSaved},\"retained\":true}").toArray()) }
            catch (_: Exception) { @Expect(false, true) }
            @Expect(terminal, true); @Expect(proofSaved, true)
        }
    }
}

@When[os == "macOS"]
@Test
public class ManagedNoContextResourcesTest {
    @TestCase public func rawNoContextThirtyTwoCapturesReleaseEveryOwnedResource(): Unit { nxParent("raw", "rawNoContextThirtyTwoCapturesReleaseEveryOwnedResource") }
    @TestCase public func handoffNoContextThirtyTwoCapturesKeepBytesAndResources(): Unit { nxParent("handoff", "handoffNoContextThirtyTwoCapturesKeepBytesAndResources") }
    @TestCase public func brokerNoContextThirtyTwoCloseRestartsKeepProtocolAndResources(): Unit { nxParent("broker", "brokerNoContextThirtyTwoCloseRestartsKeepProtocolAndResources") }
}
