package metis.process

import std.fs.{Path, FileInfo, exists, remove}
import std.time.MonoTime

public class ExclusiveFilePublishResult {
    public let ok: Bool
    public let status: String

    public init(ok: Bool, status: String) {
        this.ok = ok
        this.status = status.trimAscii()
    }
}

foreign {
    func fopen(path: CString, mode: CString): CPointer<Unit>
    func fputs(text: CString, stream: CPointer<Unit>): Int32
    func fflush(stream: CPointer<Unit>): Int32
    func fclose(stream: CPointer<Unit>): Int32
}

@When[os == "macOS"]
func processOpenNativeFile(path: CString, flags: Int32, mode: UInt32): Int32 {
    unsafe { open(path, flags, mode) }
}

@When[os == "macOS"]
foreign {
    func open(path: CString, flags: Int32, ...): Int32
    func flock(fd: Int32, operation: Int32): Int32
    func close(fd: Int32): Int32
    func fchmod(fd: Int32, mode: UInt32): Int32
    func fdopen(fd: Int32, mode: CString): CPointer<Unit>
    func fileno(stream: CPointer<Unit>): Int32
    func fsync(fd: Int32): Int32
}

@When[os == "macOS"]
private func exclusiveFileOpen(path: CString, _mode: CString): CPointer<Unit> {
    let descriptor = unsafe { open(path, Int32(0x1 | 0x200 | 0x800 | 0x100 | 0x1000000), UInt32(0o600)) }
    if (descriptor < 0) { return CPointer<Unit>() }
    if (unsafe { fchmod(descriptor, UInt32(0o600)) } != 0) {
        let _ = unsafe { close(descriptor) }
        return CPointer<Unit>()
    }
    let mode = unsafe { LibC.mallocCString("w") }
    try {
        let stream = unsafe { fdopen(descriptor, mode) }
        if (stream.isNull()) { let _ = unsafe { close(descriptor) } }
        stream
    } finally { unsafe { LibC.free(mode) } }
}

@When[os != "macOS"]
private func exclusiveFileOpen(path: CString, mode: CString): CPointer<Unit> { unsafe { fopen(path, mode) } }

@When[os == "macOS"]
private func exclusiveFileSync(stream: CPointer<Unit>): Bool { unsafe { fsync(fileno(stream)) } == 0 }
@When[os != "macOS"]
private func exclusiveFileSync(_stream: CPointer<Unit>): Bool { true }

@When[os == "macOS"]
private func exclusiveDirectorySync(path: Path): Bool { syncFileDirectory(path) }
@When[os != "macOS"]
private func exclusiveDirectorySync(_path: Path): Bool { true }

/** Stable inode advisory lock. Never unlink this path: death releases its OS handle. */
public class ProcessFileClaim {
    public let ok: Bool
    public let status: String
    private var descriptor: Int32
    public init(ok: Bool, status: String, descriptor!: Int32 = -1) {
        this.ok = ok; this.status = status; this.descriptor = descriptor
    }
    @When[os == "macOS"]
    public func release(): Unit {
        if (this.descriptor >= 0) { let _ = unsafe { close(this.descriptor) }; this.descriptor = -1 }
    }
    @When[os != "macOS"]
    public func release(): Unit { () }
}

@When[os == "macOS"]
public func acquireProcessFileClaim(path: Path, deadline: MonoTime): ProcessFileClaim {
    var name = unsafe { LibC.mallocCString(path.toString()) }
    var descriptor: Int32 = -1
    try {
        if (FileInfo(path.parent).isSymbolicLink()) { return ProcessFileClaim(false, "unsafe_path") }
        // O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC; mode applies at creation, before publication.
        descriptor = unsafe { open(name, Int32(0x2 | 0x200 | 0x100 | 0x1000000), UInt32(0o600)) }
        if (descriptor < 0) { return ProcessFileClaim(false, "claim_open_failed") }
        if (!FileInfo(path).isRegular() || unsafe { fchmod(descriptor, UInt32(0o600)) } != 0) {
            let _ = unsafe { close(descriptor) }; descriptor = -1
            return ProcessFileClaim(false, "unsafe_path")
        }
        while (MonoTime.now() < deadline) {
            if (unsafe { flock(descriptor, Int32(2 | 4)) } == 0) {
                let result = ProcessFileClaim(true, "claimed", descriptor: descriptor)
                descriptor = -1
                return result
            }
            sleep(Duration.millisecond * 10)
        }
        let _ = unsafe { close(descriptor) }; descriptor = -1
        ProcessFileClaim(false, "claim_busy")
    } catch (_: Exception) {
        if (descriptor >= 0) { let _ = unsafe { close(descriptor) } }
        ProcessFileClaim(false, "claim_open_failed")
    } finally { unsafe { LibC.free(name) } }
}

@When[os != "macOS"]
public func acquireProcessFileClaim(_path: Path, _deadline: MonoTime): ProcessFileClaim {
    ProcessFileClaim(false, "claim_unsupported")
}

@When[os == "macOS"]
public func syncFileDirectory(path: Path): Bool {
    let name = unsafe { LibC.mallocCString(path.toString()) }
    var descriptor: Int32 = -1
    try {
        descriptor = unsafe { open(name, Int32(0x100 | 0x1000000), UInt32(0)) }
        descriptor >= 0 && unsafe { fsync(descriptor) } == 0
    } finally {
        if (descriptor >= 0) { let _ = unsafe { close(descriptor) } }
        unsafe { LibC.free(name) }
    }
}

@When[os != "macOS"]
public func syncFileDirectory(_path: Path): Bool { false }

/** Atomically claims a path and publishes a small UTF-8 control record. */
public func publishExclusiveUtf8File(path: Path, text: String): ExclusiveFilePublishResult {
    if (text.contains("\u{0}")) { return ExclusiveFilePublishResult(false, "invalid_text") }
    var pathCString = unsafe { LibC.mallocCString(path.toString()) }
    var modeCString = unsafe { LibC.mallocCString("wx") }
    var textCString = unsafe { LibC.mallocCString(text) }
    var stream = CPointer<Unit>()
    var created = false
    try {
        stream = exclusiveFileOpen(pathCString, modeCString)
        if (stream.isNull()) {
            return ExclusiveFilePublishResult(false, if (exists(path)) { "already_exists" } else { "create_failed" })
        }
        created = true
        let writeOk = unsafe { fputs(textCString, stream) } >= 0
        let flushOk = writeOk && unsafe { fflush(stream) } == 0
        let syncOk = flushOk && exclusiveFileSync(stream)
        let closeOk = unsafe { fclose(stream) } == 0
        stream = CPointer<Unit>()
        if (writeOk && flushOk && syncOk && closeOk && exclusiveDirectorySync(path.parent)) {
            return ExclusiveFilePublishResult(true, "published")
        }
        try { remove(path) } catch (_: Exception) { () }
        ExclusiveFilePublishResult(false, "write_failed")
    } catch (_: Exception) {
        if (!stream.isNull()) { let _ = unsafe { fclose(stream) } }
        if (created) { try { remove(path) } catch (_: Exception) { () } }
        ExclusiveFilePublishResult(false, "write_failed")
    } finally {
        unsafe {
            LibC.free(pathCString)
            LibC.free(modeCString)
            LibC.free(textCString)
        }
    }
}
