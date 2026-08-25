package metis.process

import std.fs.{Path, exists, remove}

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

/** Atomically claims a path and publishes a small UTF-8 control record. */
public func publishExclusiveUtf8File(path: Path, text: String): ExclusiveFilePublishResult {
    var pathCString = unsafe { LibC.mallocCString(path.toString()) }
    var modeCString = unsafe { LibC.mallocCString("wx") }
    var textCString = unsafe { LibC.mallocCString(text) }
    var stream = CPointer<Unit>()
    var created = false
    try {
        stream = unsafe { fopen(pathCString, modeCString) }
        if (stream.isNull()) {
            return ExclusiveFilePublishResult(false, if (exists(path)) { "already_exists" } else { "create_failed" })
        }
        created = true
        let writeOk = unsafe { fputs(textCString, stream) } >= 0
        let flushOk = writeOk && unsafe { fflush(stream) } == 0
        let closeOk = unsafe { fclose(stream) } == 0
        stream = CPointer<Unit>()
        if (writeOk && flushOk && closeOk) {
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
