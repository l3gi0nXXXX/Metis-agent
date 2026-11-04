package metis.process

import std.collection.{ArrayList, HashMap, HashSet, Map}
import std.env.{getProcessId, getVariable, getVariables}
import std.fs.{Directory, File, Path, canonicalize, exists}
import std.io.InputStream
import std.process.ProcessRedirect
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.sync.AtomicBool
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func nativeGateRequire(ok: Bool): Unit {
    if (!ok) { throw Exception("native_gate_contract_failed") }
}

@When[os == "macOS"]
private func nativeGateOsThreads(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 6, 0, buffer, 32768) }
        nativeGateRequire(bytes > 0 && bytes < 32768 && bytes % 8 == 0)
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func nativeGateDrain(input: InputStream, destination: Path): Unit {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    try {
        while (true) {
            let count = input.read(buffer)
            if (count == 0) { break }
            for (index in 0..count) {
                if (bytes.size < 65536) { bytes.add(buffer[index]) }
            }
        }
    } finally { File.writeTo(destination, bytes.toArray()) }
}

private func nativeGateBool(frame: JsonObject, key: String): Bool {
    frame.get(key).getOrThrow().asBool().getValue()
}

private func nativeGateInt(frame: JsonObject, key: String): Int64 {
    frame.get(key).getOrThrow().asInt().getValue()
}

@When[os == "macOS"]
private func nativeGateReadProtocol(child: ManagedOwnedChild, home: Path, expected: Int64): Int64 {
    let births = HashMap<Int64, String>()
    let names = HashSet<String>()
    let transcript = ArrayList<Byte>()
    let line = ArrayList<Byte>()
    let byte = Array<Byte>(1, repeat: 0)
    var cases: Int64 = 0
    var done = false
    try {
        while (child.stdOutPipe.read(byte) != 0) {
            nativeGateRequire(byte[0] < 128 && transcript.size < 1048576 && line.size < 16384)
            transcript.add(byte[0])
            if (byte[0] != 10) { line.add(byte[0]); continue }
            let text = try { String.fromUtf8(line.toArray()) }
                catch (_: Exception) { throw Exception("native_gate_invalid_response_encoding") }
            line.clear()
            let frame = try { JsonValue.fromStr(text).asObject() }
                catch (_: Exception) { throw Exception("native_gate_malformed_json") }
            nativeGateRequire(!done)
            let event = frame.get("event").getOrThrow().asString().getValue()
            if (event == "gate" || event == "business") {
                let pid = nativeGateInt(frame, "pid")
                nativeGateRequire(pid > 1 && pid <= Int64(Int32.Max))
                let birth = observeProcessBirthIdentity(pid).getOrThrow().serialize()
                nativeGateRequire(Int64(unsafe { getpgid(Int32(pid)) }) == pid)
                if (event == "gate") {
                    nativeGateRequire(!births.contains(pid))
                    births[pid] = birth
                } else { nativeGateRequire(births.get(pid) == Some(birth)) }
                let action = if (event == "gate") { "gate-observed" } else { "business-observed" }
                child.stdInPipe.write(("{\"action\":\"${action}\",\"pid\":${pid},\"birth\":\"${birth}\"}\n").toArray())
                child.stdInPipe.flush()
            } else if (event == "case") {
                nativeGateRequire(nativeGateBool(frame, "formal") && nativeGateBool(frame, "childReaped") &&
                    nativeGateBool(frame, "groupGone") && nativeGateBool(frame, "streamsClosed"))
                let name = frame.get("name").getOrThrow().asString().getValue()
                nativeGateRequire(!name.isEmpty() && !names.contains(name))
                names.add(name)
                cases += 1
                nativeGateRequire(cases <= expected)
            } else if (event == "done") {
                nativeGateRequire(nativeGateBool(frame, "formal") && nativeGateInt(frame, "count") == expected && cases == expected)
                done = true
                child.closeInput()
            } else { throw Exception("native_gate_unexpected_event") }
        }
        nativeGateRequire(done && cases == expected && line.isEmpty())
        cases
    } finally { File.writeTo(home.join("driver.stdout.bin"), transcript.toArray()) }
}

@When[os == "macOS"]
private func nativeGateRun(mode: String, expected: Int64): Unit {
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    File.writeTo(home.join("owner"), "native-exec-gate-fixture-v1\n".toArray())
    File.writeTo(home.join("wrapper-nonce"), nonce.toArray())
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT") ?? "."))
    let fixture = project.join("test/fixtures/service_plugin/stdio_protocol/native_exec_gate_fixture.mjs")
    let gate = project.join("target/native/metis-exec-gate-v1")
    let node = managedStdioResolveNodeCommand()
    let environment = HashMap<String, String>()
    for ((key, value) in getVariables()) {
        if (["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH",
            "CANGJIE_HOME", "CANGJIE_PATH", "CANGJIE_STDX_PATH"].contains(key)) { environment[key] = value }
    }
    let fd = ownedTestFdCount()
    let osThreads = nativeGateOsThreads()
    let tasks = getThreadCount()
    let blocking = getBlockingThreadCount()
    var child = None<ManagedOwnedChild>
    var output = None<Future<Int64>>
    var error = None<Future<Unit>>
    let outputDone = AtomicBool(false)
    let errorDone = AtomicBool(false)
    var outputJoined = false
    var errorJoined = false
    var reaped = false
    var passed = false
    var count: Int64 = 0
    let proof = JsonObject()
    proof.put("nonce", JsonString(nonce)); proof.put("mode", JsonString(mode))
    proof.put("formal", JsonBool(false))
    println("R-NG fixture=${home.fileName};nonce=${nonce};mode=${mode}")
    try {
        nativeGateRequire(node.startsWith("/") && exists(Path(node)) && exists(fixture) && exists(gate))
        let driver = launchManagedRawChild(node, [fixture.toString(), gate.toString(), home.toString(), mode],
            environment: Some<Map<String, String>>(environment), workingDirectory: Some(project), newGeneration: true,
            stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
        child = Some(driver)
        let reader = spawn {
            try { nativeGateReadProtocol(driver, home, expected) } finally { outputDone.store(true) }
        }
        output = Some(reader)
        let stderr = spawn {
            try { nativeGateDrain(driver.stdErrPipe, home.join("driver.stderr.bin")) } finally { errorDone.store(true) }
        }
        error = Some(stderr)
        let deadline = MonoTime.now() + Duration.second * 90
        count = reader.get(deadline - MonoTime.now()); outputJoined = true
        let code = driver.wait(timeout: Some(deadline - MonoTime.now()))
        reaped = code >= 0 && code <= 255 && !driver.isAlive()
        nativeGateRequire(code == 0 && reaped && driver.wait() == 0)
        stderr.get(deadline - MonoTime.now()); errorJoined = true
        driver.closeStreams()
        nativeGateRequire(driver.streamsAreClosed() && count == expected)
        let settle = MonoTime.now() + Duration.second * 2
        while ((ownedTestFdCount() != fd || getThreadCount() > tasks || getBlockingThreadCount() > blocking) && MonoTime.now() < settle) {
            sleep(Duration.millisecond)
        }
        nativeGateRequire(ownedTestFdCount() == fd && getThreadCount() <= tasks && getBlockingThreadCount() <= blocking)
        passed = true
        @Expect(passed, true)
    } finally {
        proof.put("formal", JsonBool(passed)); proof.put("caseCount", JsonInt(count))
        proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("driverReapedBeforeFallback", JsonBool(reaped))
        proof.put("stdoutJoinedBeforeFallback", JsonBool(outputJoined)); proof.put("stderrJoinedBeforeFallback", JsonBool(errorJoined))
        proof.put("baselineFd", JsonInt(fd)); proof.put("formalFd", JsonInt(ownedTestFdCount()))
        proof.put("baselineOsThreads", JsonInt(osThreads)); proof.put("formalOsThreads", JsonInt(nativeGateOsThreads()))
        proof.put("baselineTasks", JsonInt(tasks)); proof.put("formalTasks", JsonInt(getThreadCount()))
        proof.put("baselineBlocking", JsonInt(blocking)); proof.put("formalBlocking", JsonInt(getBlockingThreadCount()))
        File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray())
        if (let Some(driver) <- child) {
            try {
                if (driver.isAlive()) { driver.terminate() }
                let code = driver.wait(timeout: Some(Duration.second * 2))
                reaped = code >= 0 && code <= 255 && !driver.isAlive()
            } catch (_: Exception) { reaped = false }
            driver.closeStreams()
        }
        if (let Some(reader) <- output) {
            try { let _ = reader.get(Duration.second * 2); outputJoined = true }
            catch (_: TimeoutException) { outputJoined = false }
            catch (_: Exception) { outputJoined = outputDone.load() }
        }
        if (let Some(reader) <- error) {
            try { reader.get(Duration.second * 2); errorJoined = true }
            catch (_: TimeoutException) { errorJoined = false }
            catch (_: Exception) { errorJoined = errorDone.load() }
        }
        let terminal = reaped && child.isSome() && child.getOrThrow().streamsAreClosed() && outputJoined && errorJoined
        println("R-NG owned_evidence_retained;formal=${passed};driverTerminal=${terminal}")
    }
}

@When[os == "macOS"]
@Test
public class ManagedExecGateTest {
    @TestCase
    public func nativeGateP1OriginalThirteenCases(): Unit { nativeGateRun("positive", 13) }

    @TestCase
    public func nativeGateN1InvalidAdmissionAndBrokenControl(): Unit { nativeGateRun("negative", 7) }
}
