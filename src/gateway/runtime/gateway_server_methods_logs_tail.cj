package metis.gateway.runtime

import std.collection.ArrayList
import std.fs.{File, FileInfo, OpenMode, Path, exists}
import std.io.SeekPosition

class GatewayLogTailSlice {
    public let cursor: Int64
    public let size: Int64
    public let lines: Array<String>
    public let truncated: Bool
    public let reset: Bool

    public init(cursor: Int64, size: Int64, lines: Array<String>, truncated: Bool, reset: Bool) {
        this.cursor = cursor
        this.size = size
        this.lines = lines
        this.truncated = truncated
        this.reset = reset
    }
}

func gatewayReadLogTailSlice(path: Path, cursor: Int64, limitRaw: Int64, maxBytesRaw: Int64): GatewayLogTailSlice {
    let limit = if (limitRaw <= 0) { 500 } else { min(limitRaw, 5000) }
    let maxBytes = if (maxBytesRaw <= 0) { 250000 } else { min(maxBytesRaw, 1000000) }
    let size = try {
        let info = FileInfo(path)
        if (info.isRegular()) { info.size } else { 0 }
    } catch (_e: Exception) {
        0
    }
    if (size <= 0 || !exists(path)) {
        return GatewayLogTailSlice(0, 0, [], false, false)
    }

    var start: Int64 = 0
    var reset = false
    var truncated = false
    if (cursor >= 0) {
        if (cursor > size) {
            reset = true
            start = max(0, size - maxBytes)
            truncated = start > 0
        } else {
            start = cursor
            if (size - start > maxBytes) {
                reset = true
                truncated = true
                start = max(0, size - maxBytes)
            }
        }
    } else {
        start = max(0, size - maxBytes)
        truncated = start > 0
    }

    let readStart = if (start > 0) { start - 1 } else { start }
    let bytesToRead = size - readStart
    let window = gatewayReadLogWindow(path, readStart, bytesToRead)
    let decodeStart = start - readStart
    let text = gatewayLogUtf8TextFromBytes(window, decodeStart)
    let prevIsNewline = start <= 0 || (window.size > 0 && window[0] == b'\n')
    let lines = gatewayLogTailLines(text, limit, dropFirst: start > 0 && !prevIsNewline)
    GatewayLogTailSlice(size, size, lines, truncated, reset)
}

private func gatewayReadLogWindow(path: Path, start: Int64, maxBytes: Int64): Array<Byte> {
    let out = ArrayList<Byte>()
    if (maxBytes <= 0) {
        return out.toArray()
    }
    try (file = File(path, OpenMode.Read)) {
        file.seek(SeekPosition.Begin(start))
        var remaining = maxBytes
        while (remaining > 0) {
            let wanted = min(remaining, 8192)
            let buffer = Array<Byte>(wanted, repeat: 0)
            let n = file.read(buffer)
            if (n <= 0) {
                break
            }
            out.add(all: buffer[..n])
            remaining -= n
        }
    } catch (_e: Exception) {
        ()
    }
    out.toArray()
}

private func gatewayLogUtf8TextFromBytes(bytes: Array<Byte>, startRaw: Int64): String {
    let size = Int64(bytes.size)
    var start = max(0, min(startRaw, size))
    while (start < size) {
        try {
            return String.fromUtf8(bytes[start..])
        } catch (_e: Exception) {
            start += 1
        }
    }
    ""
}

private func gatewayLogTailLines(text: String, limit: Int64, dropFirst!: Bool): Array<String> {
    let all = text.split("\n")
    let lines = ArrayList<String>()
    var first: Int64 = if (dropFirst) { 1 } else { 0 }
    var end: Int64 = Int64(all.size)
    if (end > 0 && all[end - 1].isEmpty()) {
        end -= 1
    }
    if (first > end) {
        first = end
    }
    for (idx in first..end) {
        let line = all[idx].trimAscii()
        if (!line.isEmpty()) {
            lines.add(line)
        }
    }
    let kept = lines.toArray()
    let keptStart = max(0, Int64(kept.size) - limit)
    kept[keptStart..]
}
