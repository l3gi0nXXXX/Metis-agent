package metis.process

import std.collection.{ArrayList, HashMap}
import std.env.{getCommand, getVariable, getVariables}
import std.fs.{Directory, File, OpenMode, Path, canonicalize, exists, remove}
import std.io.InputStream
import std.process.{ProcessRedirect, SubProcess, launch}
import std.runtime.{gc, getGCCount}
import std.sync.AtomicBool
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func ownedGcRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_response_encoding" }
}

private func ownedGcReadAll(stream: InputStream): Array<Byte> {
    let result = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return result.toArray() }
        result.add(all: buffer[..count])
    }
    result.toArray()
}

@When[os == "macOS"]
private func ownedGcChild(mode: String): Unit {
    let home = canonicalize(Path(getVariable("METIS_OWNED_GC_HOME").getOrThrow()))
    let nonce = getVariable("METIS_OWNED_GC_NONCE").getOrThrow()
    if (!["read", "write"].contains(mode) || !home.toString().startsWith("/private/tmp/") || nonce.isEmpty() ||
        ownedGcRead(home.join("owner")) != "owned-gc-v1\n" + nonce) { throw Exception("owned_gc_scope_invalid") }
    let baseline = ownedTestFdCount()
    let child = managedNativeLaunch("/bin/cat", [], None, None,
        [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Discard])
    File.writeTo(home.join("cat.birth"), observeProcessBirthIdentity(child.pid).getOrThrow().serialize().toArray())
    let readBuffer = Array<Byte>(32, repeat: 0)
    let writeBytes = Array<Byte>(1024 * 1024, repeat: 90)
    let expectedRead = "唤醒😀".toArray()
    let done = AtomicBool(false)
    let state = { => if (mode == "read") { managedNativePipeStateForTest(child.stdOutPipe) }
        else { managedNativeOutputPipeStateForTest(child.stdInPipe) } }
    let resource = if (mode == "read") { (child.stdOutPipe as Resource).getOrThrow() }
        else { (child.stdInPipe as Resource).getOrThrow() }
    let originalFd = state()[1]
    let worker = spawn {
        try {
            if (mode == "read") { child.stdOutPipe.read(readBuffer) }
            else { child.stdInPipe.write(writeBytes); writeBytes.size }
        } finally { done.store(true) }
    }
    let nullName = unsafe { LibC.mallocCString("/dev/null") }
    var opened: Int32 = -1
    var replacement: Int32 = -1
    var drain = None<Future<Array<Byte>>>
    let proof = JsonObject()
    proof.put("formalOk", JsonBool(false)); proof.put("nonce", JsonString(nonce))
    try {
        let entered = MonoTime.now() + Duration.second * 2
        while (state()[0] != 1 && MonoTime.now() < entered) { sleep(Duration.millisecond) }
        @Expect(state()[0], 1)
        var timedOut = false
        try { let _ = worker.get(Duration.millisecond * 20) } catch (_: TimeoutException) { timedOut = true }
        @Expect(timedOut && !done.load(), true)
        resource.close()
        @Expect(state()[1], originalFd)
        opened = processOpenNativeFile(nullName, 0, 0)
        @Expect(opened >= 0 && opened != originalFd, true)
        File.writeTo(home.join("io-blocked"), nonce.toArray())
        let before = getGCCount()
        // This must finish while the peer still cannot unblock either real syscall.
        gc(heavy: true)
        let gcDeadline = MonoTime.now() + Duration.second * 2
        var after = getGCCount()
        while (after <= before && !done.load() && state()[0] == 1 && MonoTime.now() < gcDeadline) {
            sleep(Duration.millisecond)
            after = getGCCount()
        }
        let gcProof = JsonObject()
        gcProof.put("nonce", JsonString(nonce)); gcProof.put("before", JsonInt(before)); gcProof.put("after", JsonInt(after))
        gcProof.put("ioPending", JsonBool(!done.load() && state()[0] == 1 && state()[1] == originalFd))
        File.writeTo(home.join("gc-complete.json"), gcProof.toJsonString().toArray())
        File.writeTo(home.join("gc-published"), nonce.toArray())
        @Expect(after > before && !done.load() && state()[0] == 1, true)
        let releaseDeadline = MonoTime.now() + Duration.second * 10
        while (ownedGcRead(home.join("release")) != nonce && MonoTime.now() < releaseDeadline) { sleep(Duration.millisecond * 10) }
        if (ownedGcRead(home.join("release")) != nonce) { throw Exception("owned_gc_parent_release_missing") }
        if (mode == "read") {
            child.stdInPipe.write(expectedRead)
            @Expect(worker.get(Duration.second * 2), expectedRead.size)
            @Expect(readBuffer[..expectedRead.size], expectedRead)
            child.closeInput()
            @Expect(child.wait(timeout: Some(Duration.second * 2)), 0)
        } else {
            let reader = spawn { ownedGcReadAll(child.stdOutPipe) }
            drain = Some(reader)
            @Expect(worker.get(Duration.second * 2), writeBytes.size)
            child.closeInput()
            @Expect(child.wait(timeout: Some(Duration.second * 2)), 0)
            @Expect(reader.get(Duration.second * 2), writeBytes)
        }
        @Expect(state()[1], -1)
        replacement = managedNativeDuplicateAtLeast(opened, originalFd)
        @Expect(replacement, originalFd)
        child.closeStreams()
        @Expect(unsafe { fcntl(replacement, 1) } >= 0, true)
        let _ = unsafe { close(opened) }; opened = -1
        let _ = unsafe { close(replacement) }; replacement = -1
        @Expect(child.streamsAreClosed(), true)
        @Expect(ownedTestFdCount(), baseline)
        proof.put("formalOk", JsonBool(after > before && done.load() && child.streamsAreClosed() && ownedTestFdCount() == baseline))
        proof.put("gcIncreased", JsonBool(after > before)); proof.put("fdBaseline", JsonBool(ownedTestFdCount() == baseline))
    } finally {
        // Even assertion/cleanup failures retain their pre-fallback formal outcome.
        proof.put("recordedBeforeFallback", JsonBool(true))
        File.writeTo(home.join("child-formal.json"), proof.toJsonString().toArray())
        try { child.closeInput(); if (child.isAlive()) { child.terminate(force: true) }; let _ = child.wait(timeout: Some(Duration.second * 2)) }
        catch (_: Exception) { () }
        child.closeStreams()
        try { let _ = worker.get(Duration.second * 2) } catch (_: Exception) { () }
        if (let Some(reader) <- drain) { try { let _ = reader.get(Duration.second * 2) } catch (_: Exception) { () } }
        if (opened >= 0) { let _ = unsafe { close(opened) } }
        if (replacement >= 0) { let _ = unsafe { close(replacement) } }
        unsafe { LibC.free(nullName) }
    }
}

@When[os == "macOS"]
private func ownedGcParent(mode: String, testName: String): Unit {
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    File.writeTo(home.join("owner"), ("owned-gc-v1\n" + nonce).toArray())
    let environment = HashMap<String, String>(getVariables())
    for (key in environment.keys().toArray()) {
        if (key.startsWith("METIS_PROCESS_RECOVERY_") || key.endsWith("_API_KEY") || key.endsWith("_TOKEN")) { environment.remove(key) }
    }
    environment["METIS_OWNED_GC_MODE"] = mode; environment["METIS_OWNED_GC_HOME"] = home.toString()
    environment["METIS_OWNED_GC_NONCE"] = nonce; environment["METIS_HOME"] = home.toString()
    environment["METIS_LOG_FILE"] = home.join("test.log").toString()
    var process = None<SubProcess>
    var birth = None<ProcessBirthIdentity>
    var passed = false
    let formal = JsonObject(); formal.put("formalOk", JsonBool(false))
    try {
        try (input = File("/dev/null", OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write),
            error = File(home.join("stderr"), OpenMode.Write)) {
            let child = launch(getCommand(), ["--filter=ManagedOwnedChildGcTest.${testName}", "--parallel=1",
                "--no-progress", "--no-color", "--no-capture-output"], environment: environment,
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            process = Some(child); birth = observeProcessBirthIdentity(child.pid)
        }
        let child = process.getOrThrow()
        let deadline = MonoTime.now() + Duration.second * 10
        while (ownedGcRead(home.join("gc-published")) != nonce && child.isAlive() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (ownedGcRead(home.join("gc-published")) != nonce) { throw Exception("owned_gc_external_deadline_exceeded") }
        let progress = JsonValue.fromStr(ownedGcRead(home.join("gc-complete.json"))).asObject()
        let gcDone = child.isAlive() && ownedGcRead(home.join("io-blocked")) == nonce &&
            progress.get("nonce").getOrThrow().asString().getValue() == nonce &&
            progress.get("after").getOrThrow().asInt().getValue() > progress.get("before").getOrThrow().asInt().getValue() &&
            progress.get("ioPending").getOrThrow().asBool().getValue()
        if (!gcDone) { throw Exception("owned_gc_completed_without_blocked_io") }
        // Parent, not the potentially frozen child runtime, controls permission to unblock IO.
        File.writeTo(home.join("release"), nonce.toArray())
        let code = child.wait(timeout: Some(Duration.second * 10))
        @Expect(code, 0)
        let childProof = JsonValue.fromStr(ownedGcRead(home.join("child-formal.json"))).asObject()
        passed = code == 0 && childProof.get("formalOk").getOrThrow().asBool().getValue() &&
            childProof.get("recordedBeforeFallback").getOrThrow().asBool().getValue()
        @Expect(passed, true)
        formal.put("formalOk", JsonBool(passed)); formal.put("gcBeforeRelease", JsonBool(gcDone))
        println("R-S1-LGC mode=${mode};gcBeforeRelease=${gcDone};formalBeforeFallback=${passed}")
    } finally {
        formal.put("recordedBeforeFallback", JsonBool(true))
        File.writeTo(home.join("parent-formal.json"), formal.toJsonString().toArray())
        if (let Some(child) <- process) {
            if (child.isAlive() && birth.isSome() && observeProcessBirthIdentity(child.pid)?.serialize() == birth?.serialize() &&
                ownedGcRead(home.join("owner")) == "owned-gc-v1\n" + nonce) { child.terminate(force: true) }
            try { let _ = child.wait(timeout: Some(Duration.second * 2)) } catch (_: Exception) { () }
        }
        var terminal = process.isSome() && !process.getOrThrow().isAlive()
        let cat = parseProcessBirthIdentity(ownedGcRead(home.join("cat.birth")))
        if (cat.isSome()) {
            let result = probeProcessBirthIdentity(cat.getOrThrow(), MonoTime.now() + Duration.second * 2)
            terminal = terminal && result.conclusive && !result.alive
        } else { terminal = false }
        if (terminal && passed) { remove(home, recursive: true) }
        else { println("R-S1-LGC owned_failure_evidence_retained") }
        @Expect(terminal, true)
    }
}

@When[os == "macOS"]
@Test
public class ManagedOwnedChildGcTest {
    @TestCase
    public func rS1Lgc01BlockedReadCollectsBeforePeerRelease(): Unit {
        if (getVariable("METIS_OWNED_GC_MODE") == Some("read")) { ownedGcChild("read"); return }
        ownedGcParent("read", "rS1Lgc01BlockedReadCollectsBeforePeerRelease")
    }

    @TestCase
    public func rS1Lgc02BlockedWriteCollectsBeforePeerRelease(): Unit {
        if (getVariable("METIS_OWNED_GC_MODE") == Some("write")) { ownedGcChild("write"); return }
        ownedGcParent("write", "rS1Lgc02BlockedWriteCollectsBeforePeerRelease")
    }
}
