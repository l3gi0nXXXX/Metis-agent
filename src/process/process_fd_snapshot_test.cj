package metis.process

import magic.config.Config
import magic.log.LogUtils
import std.collection.{ArrayList, HashMap}
import std.env.{getCommand, getVariable, getVariables}
import std.fs.{Directory, File, Path, remove}
import std.process.{launch, ProcessRedirect}
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign {
    func setrlimit(resource: Int32, limit: CPointer<UInt64>): Int32
}

@Test
public class ProcessFdSnapshotTest {
    @TestCase
    public func fdS2U1NativeLayoutCountsOnlyDescriptorKinds(): Unit {
        let rows: Array<UInt64> = [UInt64(1) << 32, UInt64(2) << 32, UInt64(6) << 32,
            UInt64(9) << 32, 0]
        let value = processFdSnapshotFromNativeResult(rows, 32, 32, 64)
        @Expect(value.status, "ok")
        @Expect(value.fdCount, 4)
        @Expect(value.vnodeCount, 1)
        @Expect(value.socketCount, 1)
        @Expect(value.pipeCount, 1)
        @Expect(value.otherCount, 1)
        @Expect(value.fdLimit, 64)
    }

    @TestCase
    public func fdS2B1ShortOverflowAndNativeFailureStayUnknown(): Unit {
        let records = Array<UInt64>(4, repeat: 0)
        @Expect(processFdSnapshotFromNativeResult(records, 7, 8, 64).status, "invalid_native_result")
        @Expect(processFdSnapshotFromNativeResult(records, -1, 8, 64).fdCount, -1)
        @Expect(processFdSnapshotFromNativeResult(records, 8, -1, 64).status, "probe_failed")
        @Expect(processFdSnapshotFromNativeResult(records, 8, 64, 64).status, "truncated")
        @Expect(processFdSnapshotFromNativeResult(records, 32, 32, 64).status, "truncated")
        @Expect(processFdSnapshotFromNativeResult([], 0, 0, 64).fdCount, 0)
    }

    @TestCase
    public func fdS2P1NativeSamplerHasNoRetainedDescriptor(): Unit {
        let before = captureCurrentProcessFdSnapshot()
        for (_ in 0..100) { let _ = captureCurrentProcessFdSnapshot() }
        let after = captureCurrentProcessFdSnapshot()
        if (before.status == "ok") {
            @Expect(after.status, "ok")
            @Expect(after.fdCount <= before.fdCount + 1, true)
            @Expect(after.fdLimit, before.fdLimit)
        } else {
            @Expect(before.status, "unsupported")
        }
    }

}

@When[os == "macOS"]
@Test
public class ProcessFdSnapshotNativeTest {
    @TestCase
    public func fdS0B1RealEmfileIsConfinedToOwnedChild(): Unit {
        if (getVariable("METIS_FD_EXHAUSTION_CHILD") == Some("1")) {
            processFdRunExhaustionFixture()
            return
        }
        let before = captureCurrentProcessFdSnapshot()
        let environment = HashMap(getVariables())
        environment["METIS_FD_EXHAUSTION_CHILD"] = "1"
        let child = launch(getCommand(), ["--filter=ProcessFdSnapshotNativeTest.fdS0B1RealEmfileIsConfinedToOwnedChild",
            "--parallel=1"], environment: environment, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
        let (exitCode, out, _) = child.waitOutput()
        @Expect(exitCode, 0)
        let text = try { String.fromUtf8(out) }
            catch (_: Exception) { throw Exception("owned_fixture_encoding_failed") }
        @Expect(text.contains("fixture_emfile_verified"), true)
        @Expect(captureCurrentProcessFdSnapshot().fdLimit, before.fdLimit)
    }
}

/** Real EMFILE and recovery, run only in an explicitly selected test subprocess. */
@When[os == "macOS"]
private func processFdRunExhaustionFixture(): Unit {
    let directory = Directory.createTemp("/tmp")
    let oldLogFile = Config.logFile
    try {
        Config.logFile = directory.join("owned-log.txt").toString()
        processFdRunLimitedFixture(directory)
    } finally {
        Config.logFile = oldLogFile
        remove(directory, recursive: true)
    }
}

@When[os == "macOS"]
private func processFdRunLimitedFixture(directory: Path): Unit {
    let path = directory.join("owned-state.json")
    File.writeTo(path, "{}".toArray())
    var original: VArray<UInt64, $2> = [0, 0]
    @Expect(unsafe { getrlimit(Int32(8), inout original) }, 0)
    var limited: VArray<UInt64, $2> = [min(original[0], UInt64(64)), original[1]]
    let streams = ArrayList<CPointer<Unit>>()
    let nullPath = unsafe { LibC.mallocCString("/dev/null") }
    let mode = unsafe { LibC.mallocCString("r") }
    var limitChanged = false
    try {
        @Expect(unsafe { setrlimit(Int32(8), inout limited) }, 0)
        limitChanged = true
        for (_ in 0..128) {
            let stream = unsafe { fopen(nullPath, mode) }
            if (stream.isNull()) { break }
            streams.add(stream)
        }
        @Expect(streams.size > 0, true)
        // proc_pidinfo/getrlimit need no extra open file or shell at EMFILE.
        let exhausted = captureCurrentProcessFdSnapshot()
        @Expect(exhausted.status, "ok")
        @Expect(exhausted.fdLimit, Int64(limited[0]))
        var emfile = false
        try { File.writeTo(path, "{\"消息\":\"中文😀\"}".toArray()) }
        catch (e: Exception) { emfile = e.message.contains("Too many open files") }
        @Expect(emfile, true)
        // The real exhausted file table must not turn a diagnostic into a crash.
        for (_ in 0..10) { LogUtils.error("owned-emfile-中文😀") }
    } finally {
        for (stream in streams) { let _ = unsafe { fclose(stream) } }
        if (limitChanged) { let _ = unsafe { setrlimit(Int32(8), inout original) } }
        unsafe { LibC.free(nullPath); LibC.free(mode) }
    }
    File.writeTo(path, "{\"recovered\":true}".toArray())
    LogUtils.error("owned-recovered-中文😀")
    let recovered = try { String.fromUtf8(File.readFrom(Config.logFile)) }
        catch (_: Exception) { throw Exception("owned_log_encoding_failed") }
    @Expect(recovered.contains("failedRecords=10"), true)
    @Expect(recovered.contains("owned-emfile"), false)
    @Expect(recovered.contains("owned-recovered-中文😀"), true)
    println("fixture_emfile_verified")
}
