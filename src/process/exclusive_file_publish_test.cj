package metis.process

import std.core.Duration
import std.fs.{Directory, File, Path, exists, remove}
import std.sync.{Condition, Mutex}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

@When[os != "Windows"]
foreign {
    func fork(): Int32
    func pipe(fds: CPointer<Int32>): Int32
    func read(fd: Int32, buffer: CPointer<UInt8>, count: UIntNative): IntNative
    func write(fd: Int32, buffer: CPointer<UInt8>, count: UIntNative): IntNative
    func close(fd: Int32): Int32
    func waitpid(pid: Int32, status: CPointer<Int32>, options: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func _exit(status: Int32): Unit
}

@When[os != "Windows"]
private func exclusivePublishWaitChild(pid: Int32): Int32 {
    let status = unsafe { LibC.malloc<Int32>() }
    let deadline = MonoTime.now() + Duration.second * 3
    try {
        while (MonoTime.now() < deadline) {
            let waited = unsafe { waitpid(pid, status, 1) }
            if (waited == pid) {
                let value = unsafe { status.read() }
                return if ((value & 0x7f) == 0) { (value >> 8) & 0xff } else { -1 }
            }
            sleep(Duration.millisecond * 5)
        }
        let _ = unsafe { kill(pid, 9) }
        let _ = unsafe { waitpid(pid, status, 0) }
        -1
    } finally {
        unsafe { LibC.free(status) }
    }
}

@When[os != "Windows"]
private func exclusivePublishChild(readFd: Int32, writeFd: Int32, path: Path, text: String): Unit {
    let byte = unsafe { LibC.malloc<UInt8>() }
    let _ = unsafe { close(writeFd) }
    let opened = unsafe { read(readFd, byte, 1) } == 1
    let _ = unsafe { close(readFd) }
    unsafe { LibC.free(byte) }
    let result = if (opened) { publishExclusiveUtf8File(path, text) } else { ExclusiveFilePublishResult(false, "barrier_failed") }
    unsafe { _exit(if (result.ok) { 0 } else { 1 }) }
}

private class ExclusivePublishTestGate {
    private let lock = Mutex()
    private var condition: Condition
    private var entered: Int64 = 0
    private var released = false

    init() { synchronized(this.lock) { this.condition = this.lock.condition() } }

    func enterAndWait(): Unit {
        synchronized(this.lock) {
            this.entered += 1
            this.condition.notifyAll()
            while (!this.released) { this.condition.wait() }
        }
    }

    func releaseWhenBothReady(): Unit {
        synchronized(this.lock) {
            while (this.entered < 2) { let _ = this.condition.wait(timeout: Duration.second) }
            this.released = true
            this.condition.notifyAll()
        }
    }
}

@Test
public class ExclusiveFilePublishTest {
    @TestCase
    public func s4N1ConcurrentPublishHasExactlyOneWinnerAndNeverOverwrites(): Unit {
        let root = Path("/tmp/metis-exclusive-publish-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let path = root.join("gateway-serve.lock")
        let gate = ExclusivePublishTestGate()
        try {
            Directory.create(root, recursive: true)
            let left = spawn { gate.enterAndWait(); publishExclusiveUtf8File(path, "left-中文-🙂") }
            let right = spawn { gate.enterAndWait(); publishExclusiveUtf8File(path, "right") }
            gate.releaseWhenBothReady()
            let leftResult = left.get(Duration.second * 3)
            let rightResult = right.get(Duration.second * 3)
            @Expect((if (leftResult.ok) { 1 } else { 0 }) + (if (rightResult.ok) { 1 } else { 0 }), 1)
            let winner = if (leftResult.ok) { "left-中文-🙂" } else { "right" }
            let stored = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }
            @Expect(stored, winner)
            @Expect(publishExclusiveUtf8File(path, "replacement").ok, false)
            @Expect(try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }, winner)
        } finally {
            try { if (exists(root)) { remove(root, recursive: true) } } catch (_: Exception) { () }
        }
    }

}

@When[os != "Windows"]
@Test
public class ExclusiveFilePublishPosixTest {
    @TestCase
    public func s4N1TwoPosixProcessesPublishExactlyOnceWithoutOverwrite(): Unit {
        let root = Path("/tmp/metis-exclusive-publish-process-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let path = root.join("gateway-serve.lock")
        let pipeFds = unsafe { LibC.malloc<Int32>(count: 2) }
        var readFd: Int32 = -1
        var writeFd: Int32 = -1
        var leftPid: Int32 = -1
        var rightPid: Int32 = -1
        var leftReaped = false
        var rightReaped = false
        try {
            Directory.create(root, recursive: true)
            @Expect(unsafe { pipe(pipeFds) }, 0)
            readFd = unsafe { pipeFds.read() }
            writeFd = unsafe { (pipeFds + 1).read() }
            leftPid = unsafe { fork() }
            if (leftPid == 0) {
                exclusivePublishChild(readFd, writeFd, path, "left-中文-🙂")
                return
            }
            @Expect(leftPid > 0, true)
            rightPid = unsafe { fork() }
            if (rightPid == 0) {
                exclusivePublishChild(readFd, writeFd, path, "right")
                return
            }
            @Expect(rightPid > 0, true)
            let _ = unsafe { close(readFd) }
            readFd = -1
            let release = unsafe { LibC.malloc<UInt8>(count: 2) }
            unsafe {
                release.write(UInt8(1))
                (release + 1).write(UInt8(1))
            }
            let released = unsafe { write(writeFd, release, 2) }
            unsafe { LibC.free(release) }
            let _ = unsafe { close(writeFd) }
            writeFd = -1
            @Expect(released, 2)
            let leftExit = exclusivePublishWaitChild(leftPid)
            leftReaped = true
            let rightExit = exclusivePublishWaitChild(rightPid)
            rightReaped = true
            @Expect((if (leftExit == 0) { 1 } else { 0 }) + (if (rightExit == 0) { 1 } else { 0 }), 1)
            @Expect((leftExit == 1 || rightExit == 1), true)
            let winner = if (leftExit == 0) { "left-中文-🙂" } else { "right" }
            let stored = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }
            @Expect(stored, winner)
            @Expect(publishExclusiveUtf8File(path, "replacement").ok, false)
            @Expect(try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "" }, winner)
        } finally {
            if (readFd >= 0) { let _ = unsafe { close(readFd) } }
            if (writeFd >= 0) { let _ = unsafe { close(writeFd) } }
            if (leftPid > 0 && !leftReaped) { let _ = unsafe { kill(leftPid, 9) }; let _ = exclusivePublishWaitChild(leftPid) }
            if (rightPid > 0 && !rightReaped) { let _ = unsafe { kill(rightPid, 9) }; let _ = exclusivePublishWaitChild(rightPid) }
            unsafe { LibC.free(pipeFds) }
            try { if (exists(root)) { remove(root, recursive: true) } } catch (_: Exception) { () }
        }
    }
}
