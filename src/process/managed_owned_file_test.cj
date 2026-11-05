package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.env.{getProcessId, getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, OpenMode, Path, exists, remove}
import std.io.{InputStream, SeekPosition}
import std.process.ProcessRedirect
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

@When[os == "macOS"]
private func ownedFileThreadCount(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 6, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("owned_file_thread_observation_failed") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func ownedFileReadAll(input: InputStream): Array<Byte> {
    let result = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = input.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { result.add(buffer[index]) }
    }
    result.toArray()
}

@When[os == "macOS"]
private class OwnedFileFixture {
    let home = Path("/private/tmp/metis-owned-file-${getProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let nonce = "borrowed-file-fixture"
    let children = ArrayList<ManagedOwnedChild>()
    var bound = false
    var passed = false
    var rawCount: Int64 = 0
    var boundCount: Int64 = 0
    var rejectedCount: Int64 = 0
    let baselineFd: Int64
    let baselineThreads: Int64

    init() {
        Directory.create(home)
        File.writeTo(home.join("owner"), "owned-file-fixture-v1\n".toArray())
        removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        removeVariable("METIS_PROCESS_RECOVERY_PARENT")
        baselineFd = ownedTestFdCount()
        baselineThreads = ownedFileThreadCount()
    }

    func check(value: Bool): Unit {
        @Expect(value, true)
        if (!value) { throw Exception("owned_file_contract_failed") }
    }

    func bind(): Unit {
        check(managedRecoveryInitialize(home.join("inventory"), parent, nonce))
        bound = true
        let context = managedRecoveryContext()
        check(context[0] == home.join("inventory").toString() && context[1] == parent)
    }

    func sourceTerminal(): Bool {
        if (!bound) { return true }
        let result = managedRecoveryProbeRecords(home.join("inventory"), parent, nonce, MonoTime.now() + Duration.second * 2)
        result.ok && result.terminal
    }

    func checkpoint(): Unit {
        check(sourceTerminal())
        check(ownedTestFdCount() == baselineFd)
        check(ownedFileThreadCount() <= baselineThreads)
    }

    func finish(): Unit {
        let proof = JsonObject()
        proof.put("formalBeforeFallback", JsonBool(passed))
        proof.put("rawSuccesses", JsonInt(rawCount)); proof.put("boundSuccesses", JsonInt(boundCount))
        proof.put("rejectedWithoutChild", JsonInt(rejectedCount))
        proof.put("returnedHandles", JsonInt(children.size))
        let source = try { sourceTerminal() } catch (_: Exception) { false }
        proof.put("sourceTerminalBeforeFallback", JsonBool(source))
        proof.put("warmFd", JsonInt(baselineFd)); proof.put("warmThreads", JsonInt(baselineThreads))
        var proofSaved = false
        try {
            File.writeTo(home.join("formal-result.json"), proof.toJsonString().toArray())
            proofSaved = true
        } finally {
            var terminal = true
            for (child in children) {
                try {
                    if (child.isAlive()) { child.terminate() }
                    let _ = child.wait(timeout: Some(Duration.second * 3))
                    child.closeStreams()
                    terminal = terminal && !child.isAlive() && child.streamsAreClosed()
                } catch (_: Exception) { terminal = false }
            }
            if (bound) {
                terminal = managedRecoveryStopOwnedChildren((home.join("inventory").toString(), parent), MonoTime.now() + Duration.second * 3) && terminal
                let sourceClosed = try { sourceTerminal() } catch (_: Exception) { false }
                terminal = sourceClosed && terminal
            }
            if (terminal) {
                match (oldDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value) case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
                match (oldParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value) case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
            }
            if (passed && proofSaved && terminal && exists(home)) { remove(home, recursive: true) }
            else { println("R-NATIVE-FILE owned_evidence_retained formal=${passed} terminal=${terminal}") }
        }
    }
}

@When[os == "macOS"]
private func ownedFileRound(fixture: OwnedFileFixture, bound: Bool, sequence: Int64): Unit {
    let prefix = if (bound) { "bound-${sequence}" } else { "raw-${sequence}" }
    let inputBytes = ArrayList<Byte>()
    inputBytes.add(all: "真实输入中文😀".toArray()); inputBytes.add(all: [0u8, 0xffu8, 0xfeu8, 0x80u8])
    let errorBytes = ArrayList<Byte>()
    errorBytes.add(all: "错误😀".toArray()); errorBytes.add(all: [0u8, 0xfeu8])
    let sentinel = "caller仍拥有😀".toArray()
    File.writeTo(fixture.home.join(prefix + ".input"), inputBytes.toArray())
    try (input = File(fixture.home.join(prefix + ".input"), OpenMode.ReadWrite),
        output = File(fixture.home.join(prefix + ".output"), OpenMode.ReadWrite),
        error = File(fixture.home.join(prefix + ".error"), OpenMode.ReadWrite)) {
        let environment = HashMap<String, String>()
        environment["PATH"] = "/usr/bin:/bin"; environment["LANG"] = "C"
        let arguments = ["-c", "cat; printf '错误😀\\000\\376' >&2; exit 7"]
        let child = if (bound) {
            managedRecoveryLaunchOwned("/bin/sh", arguments, workingDirectory: Some(fixture.home),
                environment: Some<Map<String, String>>(environment), stdIn: ProcessRedirect.FromFile(input),
                stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
        } else {
            launchManagedRawChild("/bin/sh", arguments, workingDirectory: Some(fixture.home),
                environment: Some<Map<String, String>>(environment), stdIn: ProcessRedirect.FromFile(input),
                stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error), newGeneration: true)
        }
        fixture.children.add(child)
        fixture.check(child.wait(timeout: Some(Duration.second * 5)) == 7)
        fixture.check(child.wait() == 7)
        child.closeInput(); child.closeStreams(); child.closeStreams()
        fixture.check(!child.isAlive() && child.streamsAreClosed())
        fixture.check(!input.isClosed() && !output.isClosed() && !error.isClosed())
        for (file in [input, output, error]) {
            fixture.check(unsafe { fcntl(Int32(file.fileDescriptor.fileHandle), 1) } >= 0)
        }
        let _ = input.seek(SeekPosition.Begin(0))
        fixture.check(ownedFileReadAll(input) == inputBytes.toArray())
        let _ = output.seek(SeekPosition.Begin(0))
        fixture.check(ownedFileReadAll(output) == inputBytes.toArray())
        let _ = error.seek(SeekPosition.Begin(0))
        fixture.check(ownedFileReadAll(error) == errorBytes.toArray())
        for (file in [output, error]) { let _ = file.seek(SeekPosition.End(0)); file.write(sentinel) }
        let expectedOutput = ArrayList<Byte>(inputBytes.toArray()); expectedOutput.add(all: sentinel)
        let expectedError = ArrayList<Byte>(errorBytes.toArray()); expectedError.add(all: sentinel)
        let _ = output.seek(SeekPosition.Begin(0)); let _ = error.seek(SeekPosition.Begin(0))
        fixture.check(ownedFileReadAll(output) == expectedOutput.toArray())
        fixture.check(ownedFileReadAll(error) == expectedError.toArray())
        fixture.check(fixture.sourceTerminal())
    }
    fixture.checkpoint()
    if (bound) { fixture.boundCount += 1 } else { fixture.rawCount += 1 }
}

@When[os == "macOS"]
private func ownedFileRejected(fixture: OwnedFileFixture, fault: ManagedNativeLaunchFault, closed: Bool, sequence: Int64): Unit {
    let prefix = "rejected-${sequence}"
    let marker = fixture.home.join(prefix + ".executed")
    let bytes = ArrayList<Byte>(); bytes.add(all: "借用中文😀".toArray()); bytes.add(all: [0u8, 0xffu8, 0xfeu8])
    File.writeTo(fixture.home.join(prefix + ".input"), bytes.toArray())
    try (input = File(fixture.home.join(prefix + ".input"), OpenMode.ReadWrite),
        output = File(fixture.home.join(prefix + ".output"), OpenMode.ReadWrite),
        error = File(fixture.home.join(prefix + ".error"), OpenMode.ReadWrite)) {
        if (closed) { input.close() }
        let before = ownedTestFdCount()
        var status = ""
        var returned = false
        try {
            let environment = HashMap<String, String>(); environment["PATH"] = "/usr/bin:/bin"
            let child = managedNativeLaunch("/bin/sh", ["-c", "touch \"$1\"; exit 0", "fixture", marker.toString()],
                Some(fixture.home), Some<Map<String, String>>(environment),
                [ProcessRedirect.FromFile(input), ProcessRedirect.FromFile(output), ProcessRedirect.FromFile(error)], fault: fault)
            fixture.children.add(child); returned = true
        } catch (failure: Exception) { status = failure.message }
        let expected = match (fault) {
            case ManagedNativeLaunchFault.InvalidProcessGroup => "owned_process_attributes_failed"
            case _ => "owned_process_actions_failed"
        }
        fixture.check(!returned && status == expected && !exists(marker))
        fixture.check(ownedTestFdCount() == before)
        fixture.check(!output.isClosed() && !error.isClosed())
        if (!closed) {
            fixture.check(!input.isClosed())
            let _ = input.seek(SeekPosition.Begin(0)); fixture.check(ownedFileReadAll(input) == bytes.toArray())
        } else { fixture.check(input.isClosed()) }
        for (file in [output, error]) {
            fixture.check(unsafe { fcntl(Int32(file.fileDescriptor.fileHandle), 1) } >= 0)
            file.write(bytes.toArray()); let _ = file.seek(SeekPosition.Begin(0))
            fixture.check(ownedFileReadAll(file) == bytes.toArray())
        }
    }
    fixture.checkpoint()
    fixture.rejectedCount += 1
}

@When[os == "macOS"]
@Test
public class ManagedOwnedFileTest {
    @TestCase
    public func nativeFileP1RawAndBoundBorrowedFilesRemainCallerOwned(): Unit {
        let fixture = OwnedFileFixture()
        try {
            for (sequence in 0..32) { ownedFileRound(fixture, false, sequence) }
            fixture.bind()
            for (sequence in 0..32) { ownedFileRound(fixture, true, sequence) }
            fixture.check(fixture.rawCount == 32 && fixture.boundCount == 32)
            fixture.passed = true
            println("R-NATIVE-FILE-P1 raw32=true bound32=true bytesExact=true borrowedOpen=true terminal=true")
        } finally { fixture.finish() }
    }

    @TestCase
    public func nativeFileN1ClosedAndActionFaultsNeverSpawnOrCloseBorrowedFiles(): Unit {
        let fixture = OwnedFileFixture()
        try {
            ownedFileRejected(fixture, ManagedNativeLaunchFault.NoFault, true, 0)
            ownedFileRejected(fixture, ManagedNativeLaunchFault.InvalidProcessGroup, false, 1)
            ownedFileRejected(fixture, ManagedNativeLaunchFault.InvalidDupAction, false, 2)
            fixture.check(fixture.rejectedCount == 3 && fixture.children.isEmpty())
            fixture.passed = true
            println("R-NATIVE-FILE-N1 rejected=3 returnedChildren=0 businessMarkers=0 borrowedOpen=true fdStable=true")
        } finally { fixture.finish() }
    }
}
