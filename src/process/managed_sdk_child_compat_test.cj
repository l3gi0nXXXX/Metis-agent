package metis.process

import std.collection.ArrayList
import std.env.{getProcessId, getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, OpenMode, Path, exists, remove}
import std.io.InputStream
import std.process.{ProcessRedirect, launch}
import std.time.DateTime
import std.unittest.testmacro.*

private func sdkCompatWithoutContext(action: () -> Unit): Unit {
    let directory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let parent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    removeVariable("METIS_PROCESS_RECOVERY_PARENT")
    try { action() } finally {
        match (directory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value) case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
        match (parent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value) case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
    }
}


private func sdkCompatLaunchOwned(command: String, arguments: Array<String>,
    stdIn!: ProcessRedirect = ProcessRedirect.Inherit, stdOut!: ProcessRedirect = ProcessRedirect.Inherit,
    stdErr!: ProcessRedirect = ProcessRedirect.Inherit): ManagedOwnedChild {
    ManagedSdkChild(launch(command, arguments, stdIn: stdIn, stdOut: stdOut, stdErr: stdErr), [stdIn, stdOut, stdErr])
}

@When[os == "macOS"]
private func sdkCompatPipeDescriptors(): Array<Int32> {
    let buffer = LibC.malloc<UInt64>(count: 4096)
    try {
        let size = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (size <= 0 || size >= 32768 || size % 8 != 0) { throw Exception("fixture_fd_snapshot_failed") }
        let result = ArrayList<Int32>()
        for (index in 0..Int64(size / 8)) {
            let record = unsafe { buffer.read(index) }
            if (record >> 32 == 6) { result.add(Int32(record & 0xffffffff)) }
        }
        result.toArray()
    } finally { unsafe { LibC.free(buffer) } }
}

private func sdkCompatReadAll(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        if (count < 0) { throw Exception("fixture_unexpected_stream_state") }
        bytes.add(all: buffer[..count])
    }
    bytes.toArray()
}

private func sdkCompatCleanup(child: ManagedOwnedChild): Unit {
    try {
        if (child.isAlive()) { child.terminate() }
        let _ = child.wait(timeout: Some(Duration.second * 3))
    } finally { child.closeStreams() }
}

@When[os == "macOS"]
@Test
public class ManagedSdkChildCompatTest {
    @TestCase
    public func sdkU1RealPipeClosureCachesActualExitAndPreservesRawBytes(): Unit {
        sdkCompatWithoutContext({ =>
            let before = sdkCompatPipeDescriptors()
            let child = sdkCompatLaunchOwned("/bin/sh",
                ["-c", "printf '中文😀\\000\\377'; printf '错误😀\\376' >&2; exit 7"],
                stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
            let owned = ArrayList<Int32>()
            for (fd in sdkCompatPipeDescriptors()) { if (!before.contains(fd)) { owned.add(fd) } }
            let stdout = spawn { sdkCompatReadAll(child.stdOutPipe) }
            let stderr = spawn { sdkCompatReadAll(child.stdErrPipe) }
            try {
                @Expect(owned.size, 3)
                @Expect((child.stdOutPipe as Resource).isNone(), true)
                let out = stdout.get(Duration.second * 2)
                let err = stderr.get(Duration.second * 2)
                let expectedOut = ArrayList<Byte>(); expectedOut.add(all: "中文😀".toArray()); expectedOut.add(all: [0u8, 0xffu8])
                let expectedErr = ArrayList<Byte>(); expectedErr.add(all: "错误😀".toArray()); expectedErr.add(0xfeu8)
                @Expect(out, expectedOut.toArray()); @Expect(err, expectedErr.toArray())
                @Expect(child.wait(timeout: Some(Duration.second * 2)), 7)
                @Expect(child.wait(), 7)
                @Expect(child.streamsAreClosed(), true)
                @Expect(child.isAlive(), false)
                for (fd in owned) { @Expect(unsafe { fcntl(fd, 1) }, -1) }
                child.terminate(force: true)
                @Expect(child.wait(), 7)
            } finally {
                sdkCompatCleanup(child)
                let _ = stdout.get(Duration.second * 2)
                let _ = stderr.get(Duration.second * 2)
            }
        })
    }

    @TestCase
    public func sdkU2FromFileRemainsCallerOwnedAfterWaitAndClose(): Unit {
        sdkCompatWithoutContext({ =>
            let home = Path("/private/tmp/metis-sdk-compat-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            Directory.create(home)
            File.writeTo(home.join("owner"), "sdk-compat-owned-v1\n".toArray())
            let file = File(home.join("borrowed"), OpenMode.Write)
            var formal = false
            try {
                let child = sdkCompatLaunchOwned("/usr/bin/true", [], stdOut: ProcessRedirect.FromFile(file))
                try {
                    child.closeInput(); child.closeStreams()
                    let initiallyOpen = !file.isClosed()
                    @Expect(initiallyOpen, true)
                    let code = child.wait(timeout: Some(Duration.second * 2))
                    @Expect(code, 0)
                    child.closeStreams()
                    file.write("sentinel中文😀".toArray())
                    formal = initiallyOpen && code == 0 && !file.isClosed() && child.streamsAreClosed() && !child.isAlive()
                    @Expect(formal, true)
                } finally { sdkCompatCleanup(child) }
            } finally { file.close() }
            let contentExact = File.readFrom(home.join("borrowed")) == "sentinel中文😀".toArray()
            @Expect(contentExact, true)
            formal = formal && contentExact
            if (formal && exists(home)) { remove(home, recursive: true) }
        })
    }

    @TestCase
    public func sdkU3TimeoutKeepsSameWaiterUntilActualTermination(): Unit {
        sdkCompatWithoutContext({ =>
            let child = sdkCompatLaunchOwned("/bin/sleep", ["30"],
                stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
            try {
                var timedOut = false
                try { let _ = child.wait(timeout: Some(Duration.millisecond * 5)) }
                catch (_: TimeoutException) { timedOut = true }
                @Expect(timedOut, true)
                @Expect(child.isAlive(), true)
                @Expect(child.streamsAreClosed(), false)
                child.terminate()
                @Expect(child.wait(timeout: Some(Duration.second * 2)), 15)
                @Expect(child.wait(), 15)
                @Expect(child.streamsAreClosed(), true)
                @Expect(child.isAlive(), false)
            } finally { sdkCompatCleanup(child) }
        })
    }

    @TestCase
    public func sdkU4ConcurrentWaitersJoinWithSameRealCode(): Unit {
        sdkCompatWithoutContext({ =>
            let child = sdkCompatLaunchOwned("/bin/sh", ["-c", "sleep 0.2; exit 7"],
                stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
            let first = spawn { child.wait(timeout: Some(Duration.second * 2)) }
            let second = spawn { child.wait(timeout: Some(Duration.second * 2)) }
            try {
                @Expect(first.get(Duration.second * 3), 7)
                @Expect(second.get(Duration.second * 3), 7)
                @Expect(child.wait(), 7)
                @Expect(child.streamsAreClosed(), true)
                @Expect(child.isAlive(), false)
            } finally {
                sdkCompatCleanup(child)
                let _ = first.get(Duration.second * 3)
                let _ = second.get(Duration.second * 3)
            }
        })
    }
}
