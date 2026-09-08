package metis.core.prompting

import std.collection.ArrayList

const METIS_BOOTSTRAP_READ_CHUNK_BYTES: Int64 = 64 * 1024
const METIS_BOOTSTRAP_RETAINED_PAYLOAD_BYTES: Int64 = 48 * 1024
private const BOUNDED_BOOTSTRAP_HEAD_BYTES: Int64 = 20 * 1024
private const BOUNDED_BOOTSTRAP_TAIL_BYTES: Int64 = 6 * 1024
private const BOUNDED_BOOTSTRAP_LINE_BYTES: Int64 = 160
private const BOUNDED_BOOTSTRAP_INDEX_ENTRIES: Int64 = 24
private const BOUNDED_BOOTSTRAP_INDEX_BYTES: Int64 = BOUNDED_BOOTSTRAP_LINE_BYTES * BOUNDED_BOOTSTRAP_INDEX_ENTRIES

public const DEFAULT_BOOTSTRAP_MAX_CHARS: Int64 = 20000
public const DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS: Int64 = 150000

private const MIN_BOOTSTRAP_FILE_BUDGET_CHARS: Int64 = 64
private const BOOTSTRAP_HEAD_RATIO_NUMERATOR: Int64 = 7
private const BOOTSTRAP_HEAD_RATIO_DENOMINATOR: Int64 = 10
private const BOOTSTRAP_TAIL_RATIO_NUMERATOR: Int64 = 2
private const BOOTSTRAP_TAIL_RATIO_DENOMINATOR: Int64 = 10
private const MISSING_CONTEXT_FILE_PREFIX = "[MISSING] Expected at:"
private const MEMORY_INDEX_LINE_MAX_CHARS: Int64 = 160
private const MEMORY_MIN_HEAD_CHARS: Int64 = 1024
private const MEMORY_MIN_TAIL_CHARS: Int64 = 256

public class MetisBootstrapTrimResult {
    public var content: String = ""
    public var truncated: Bool = false
    public var maxChars: Int64 = 0
    public var originalLength: Int64 = 0
    public init() {}
}

public class MetisBootstrapBudgetResult {
    public var files: Array<MetisContextFile> = []
    public var warnings: Array<String> = []
    public var totalChars: Int64 = 0
    public var originalTotalChars: Int64 = 0
    public var truncatedFiles: Int64 = 0
    public var missingFiles: Int64 = 0
    public var skippedFiles: Int64 = 0
    public init() {}
}

class MetisBoundedBootstrapSource {
    let path: String
    let content: String
    let failure: String
    let truncated: Bool
    let totalScannedBytes: Int64
    let normalizedOriginalBytes: Int64
    let maxReadCallBytes: Int64
    let maxRetainedPayloadBytes: Int64

    init(
        path: String,
        content: String,
        failure!: String = "",
        truncated!: Bool = false,
        totalScannedBytes!: Int64 = 0,
        normalizedOriginalBytes!: Int64 = 0,
        maxReadCallBytes!: Int64 = 0,
        maxRetainedPayloadBytes!: Int64 = 0
    ) {
        this.path = path
        this.content = content
        this.failure = failure
        this.truncated = truncated
        this.totalScannedBytes = totalScannedBytes
        this.normalizedOriginalBytes = normalizedOriginalBytes
        this.maxReadCallBytes = maxReadCallBytes
        this.maxRetainedPayloadBytes = maxRetainedPayloadBytes
    }
}

private func boundedBootstrapUtf8Length(lead: Byte): Int64 {
    if (lead <= 0x7fu8) { return 1 }
    if (lead >= 0xc2u8 && lead <= 0xdfu8) { return 2 }
    if (lead >= 0xe0u8 && lead <= 0xefu8) { return 3 }
    if (lead >= 0xf0u8 && lead <= 0xf4u8) { return 4 }
    0
}

private func boundedBootstrapUtf8SequenceValid(bytes: Array<Byte>, count: Int64): Bool {
    if (count <= 1) { return count == 1 && bytes[0] <= 0x7fu8 }
    for (index in 1..count) {
        if (bytes[index] < 0x80u8 || bytes[index] > 0xbfu8) { return false }
    }
    if (count == 3) {
        if (bytes[0] == 0xe0u8 && bytes[1] < 0xa0u8) { return false }
        if (bytes[0] == 0xedu8 && bytes[1] > 0x9fu8) { return false }
    }
    if (count == 4) {
        if (bytes[0] == 0xf0u8 && bytes[1] < 0x90u8) { return false }
        if (bytes[0] == 0xf4u8 && bytes[1] > 0x8fu8) { return false }
    }
    true
}

private func boundedBootstrapAsciiLower(byte: Byte): Byte {
    if (byte >= b'A' && byte <= b'Z') { return byte + 32u8 }
    byte
}

private func boundedBootstrapAsciiSpace(byte: Byte): Bool {
    byte == b' ' || byte == b'\t'
}

private class MetisBoundedBootstrapScanner {
    private let path: String
    private let memory: Bool
    private let head = Array<Byte>(BOUNDED_BOOTSTRAP_HEAD_BYTES, repeat: 0)
    private var headCount: Int64 = 0
    private let tail = Array<Byte>(BOUNDED_BOOTSTRAP_TAIL_BYTES, repeat: 0)
    private var tailHead: Int64 = 0
    private var tailCount: Int64 = 0
    private let line = Array<Byte>(BOUNDED_BOOTSTRAP_LINE_BYTES, repeat: 0)
    private var lineCount: Int64 = 0
    private var linePrefixStarted: Bool = false
    private var linePrefixFull: Bool = false
    private let indexBytes = Array<Byte>(BOUNDED_BOOTSTRAP_INDEX_BYTES, repeat: 0)
    private let indexStarts = Array<Int64>(BOUNDED_BOOTSTRAP_INDEX_ENTRIES, repeat: 0)
    private let indexLengths = Array<Int64>(BOUNDED_BOOTSTRAP_INDEX_ENTRIES, repeat: 0)
    private var indexBytesCount: Int64 = 0
    private var indexCount: Int64 = 0
    private let keywordWindow = Array<Byte>(9, repeat: 0)
    private let normalizedLf: Array<Byte> = [b'\n']
    private var keywordCount: Int64 = 0
    private var lineKeyword: Bool = false
    private var lineFirstPending: Byte = 0
    private var lineStructure: Bool = false
    private var pendingCr: Bool = false
    private let utf8Carry = Array<Byte>(4, repeat: 0)
    private var utf8CarryCount: Int64 = 0
    private var utf8Expected: Int64 = 0
    private var normalizedBytes: Int64 = 0
    private var scannedBytes: Int64 = 0
    private var maxReadBytes: Int64 = 0
    private var failed: Bool = false

    init(path: String) {
        this.path = path
        this.memory = isMemoryBootstrapPath(path)
    }

    private func retainedCapacity(): Int64 {
        BOUNDED_BOOTSTRAP_HEAD_BYTES + BOUNDED_BOOTSTRAP_TAIL_BYTES +
            BOUNDED_BOOTSTRAP_LINE_BYTES + BOUNDED_BOOTSTRAP_INDEX_BYTES + 9 + 4 + 4
    }

    private func tailByte(index: Int64): Byte {
        this.tail[(this.tailHead + index) % BOUNDED_BOOTSTRAP_TAIL_BYTES]
    }

    private func evictTailRune(): Unit {
        if (this.tailCount <= 0) { return }
        let length = boundedBootstrapUtf8Length(this.tailByte(0))
        let removed = if (length > 0 && length <= this.tailCount) { length } else { 1 }
        this.tailHead = (this.tailHead + removed) % BOUNDED_BOOTSTRAP_TAIL_BYTES
        this.tailCount -= removed
    }

    private func appendTail(bytes: Array<Byte>, count: Int64): Unit {
        while (this.tailCount + count > BOUNDED_BOOTSTRAP_TAIL_BYTES) {
            this.evictTailRune()
        }
        for (index in 0..count) {
            this.tail[(this.tailHead + this.tailCount) % BOUNDED_BOOTSTRAP_TAIL_BYTES] = bytes[index]
            this.tailCount += 1
        }
    }

    private func keywordMatches4(a: Byte, b: Byte, c: Byte, d: Byte): Bool {
        if (this.keywordCount < 4) { return false }
        let start = this.keywordCount - 4
        this.keywordWindow[start] == a && this.keywordWindow[start + 1] == b &&
            this.keywordWindow[start + 2] == c && this.keywordWindow[start + 3] == d
    }

    private func keywordMatches5(a: Byte, b: Byte, c: Byte, d: Byte, e: Byte): Bool {
        if (this.keywordCount < 5) { return false }
        let start = this.keywordCount - 5
        this.keywordWindow[start] == a && this.keywordWindow[start + 1] == b &&
            this.keywordWindow[start + 2] == c && this.keywordWindow[start + 3] == d &&
            this.keywordWindow[start + 4] == e
    }

    private func keywordMatchesImportant(): Bool {
        if (this.keywordCount < 9) { return false }
        this.keywordWindow[0] == b'i' && this.keywordWindow[1] == b'm' && this.keywordWindow[2] == b'p' &&
            this.keywordWindow[3] == b'o' && this.keywordWindow[4] == b'r' && this.keywordWindow[5] == b't' &&
            this.keywordWindow[6] == b'a' && this.keywordWindow[7] == b'n' && this.keywordWindow[8] == b't'
    }

    private func acceptKeywordByte(byte: Byte): Unit {
        let lower = boundedBootstrapAsciiLower(byte)
        if (this.keywordCount < 9) {
            this.keywordWindow[this.keywordCount] = lower
            this.keywordCount += 1
        } else {
            for (index in 1..9) { this.keywordWindow[index - 1] = this.keywordWindow[index] }
            this.keywordWindow[8] = lower
        }
        if (this.keywordMatches4(b't', b'o', b'd', b'o') || this.keywordMatches4(b'n', b'o', b't', b'e') ||
            this.keywordMatches5(b'f', b'i', b'x', b'm', b'e') || this.keywordMatchesImportant()) {
            this.lineKeyword = true
        }
    }

    private func acceptStructureByte(byte: Byte): Unit {
        if (this.lineStructure || this.lineFirstPending == 0xffu8) { return }
        if (this.lineFirstPending == b'-' || this.lineFirstPending == b'*') {
            this.lineStructure = byte == b' '
            this.lineFirstPending = 0xffu8
            return
        }
        if (boundedBootstrapAsciiSpace(byte)) { return }
        if (byte == b'#') {
            this.lineStructure = true
            this.lineFirstPending = 0xffu8
        } else if (byte == b'-' || byte == b'*') {
            this.lineFirstPending = byte
        } else {
            this.lineFirstPending = 0xffu8
        }
    }

    private func finishLine(): Unit {
        if (this.memory && this.indexCount < BOUNDED_BOOTSTRAP_INDEX_ENTRIES &&
            (this.lineStructure || this.lineKeyword)) {
            var start: Int64 = 0
            var end = this.lineCount
            while (start < end && boundedBootstrapAsciiSpace(this.line[start])) { start += 1 }
            if (!this.linePrefixFull) {
                while (end > start && boundedBootstrapAsciiSpace(this.line[end - 1])) { end -= 1 }
            }
            let length = end - start
            if (length > 0 && this.indexBytesCount + length <= BOUNDED_BOOTSTRAP_INDEX_BYTES) {
                this.indexStarts[this.indexCount] = this.indexBytesCount
                this.indexLengths[this.indexCount] = length
                for (index in start..end) {
                    this.indexBytes[this.indexBytesCount] = this.line[index]
                    this.indexBytesCount += 1
                }
                this.indexCount += 1
            }
        }
        this.lineCount = 0
        this.linePrefixStarted = false
        this.linePrefixFull = false
        this.keywordCount = 0
        this.lineKeyword = false
        this.lineFirstPending = 0
        this.lineStructure = false
    }

    private func acceptNormalizedRune(bytes: Array<Byte>, count: Int64): Unit {
        this.normalizedBytes += count
        if (this.headCount + count <= BOUNDED_BOOTSTRAP_HEAD_BYTES) {
            for (index in 0..count) {
                this.head[this.headCount] = bytes[index]
                this.headCount += 1
            }
        }
        this.appendTail(bytes, count)
        if (!this.memory) { return }
        let newline = count == 1 && bytes[0] == b'\n'
        let leadingSpace = !newline && !this.linePrefixStarted && count == 1 && boundedBootstrapAsciiSpace(bytes[0])
        if (!newline && !leadingSpace) { this.linePrefixStarted = true }
        let keepLineRune = !newline && this.linePrefixStarted && !this.linePrefixFull &&
            this.lineCount + count <= BOUNDED_BOOTSTRAP_LINE_BYTES
        if (!newline && this.linePrefixStarted && !this.linePrefixFull && !keepLineRune) { this.linePrefixFull = true }
        for (index in 0..count) {
            let byte = bytes[index]
            if (byte == b'\n') {
                this.finishLine()
            } else {
                if (keepLineRune) {
                    this.line[this.lineCount] = byte
                    this.lineCount += 1
                }
                this.acceptKeywordByte(byte)
                this.acceptStructureByte(byte)
            }
        }
    }

    private func acceptDecodedRune(bytes: Array<Byte>, count: Int64): Unit {
        if (count == 1 && bytes[0] == b'\r') {
            if (this.pendingCr) { this.acceptNormalizedRune(this.normalizedLf, 1) }
            this.pendingCr = true
            return
        }
        if (this.pendingCr) {
            this.acceptNormalizedRune(this.normalizedLf, 1)
            this.pendingCr = false
            if (count == 1 && bytes[0] == b'\n') { return }
        }
        this.acceptNormalizedRune(bytes, count)
    }

    private func acceptRawByte(byte: Byte): Unit {
        if (this.failed) { return }
        if (this.utf8CarryCount == 0) {
            this.utf8Expected = boundedBootstrapUtf8Length(byte)
            if (this.utf8Expected == 0) { this.failed = true; return }
        }
        this.utf8Carry[this.utf8CarryCount] = byte
        this.utf8CarryCount += 1
        if (this.utf8CarryCount < this.utf8Expected) { return }
        if (!boundedBootstrapUtf8SequenceValid(this.utf8Carry, this.utf8Expected)) {
            this.failed = true
            return
        }
        this.acceptDecodedRune(this.utf8Carry, this.utf8Expected)
        this.utf8CarryCount = 0
        this.utf8Expected = 0
    }

    func accept(buffer: Array<Byte>, count: Int64): Unit {
        this.scannedBytes += count
        this.maxReadBytes = max(this.maxReadBytes, count)
        for (index in 0..count) { this.acceptRawByte(buffer[index]) }
    }

    private func bytesToString(source: Array<Byte>, start: Int64, count: Int64): String {
        let out = ArrayList<Byte>()
        for (index in 0..count) { out.add(source[start + index]) }
        String.fromUtf8(out.toArray())
    }

    private func headString(limit: Int64): String {
        var count = min(this.headCount, limit)
        while (count > 0 && count < this.headCount && this.head[count] >= 0x80u8 && this.head[count] <= 0xbfu8) {
            count -= 1
        }
        this.bytesToString(this.head, 0, count)
    }

    private func tailString(limit: Int64): String {
        var skip = max(0, this.tailCount - limit)
        while (skip < this.tailCount && this.tailByte(skip) >= 0x80u8 && this.tailByte(skip) <= 0xbfu8) {
            skip += 1
        }
        let out = ArrayList<Byte>()
        for (index in skip..this.tailCount) { out.add(this.tailByte(index)) }
        String.fromUtf8(out.toArray())
    }

    private func indexString(budget: Int64): String {
        if (!this.memory || this.indexCount == 0 || budget <= 0) { return "" }
        let out = StringBuilder()
        out.append("## Memory Index\n")
        for (entry in 0..this.indexCount) {
            let value = this.bytesToString(this.indexBytes, this.indexStarts[entry], this.indexLengths[entry])
            let line = "- ${value}\n"
            if (out.size + line.size > budget) { break }
            out.append(line)
        }
        if (out.size > budget) { return "" }
        out.toString()
    }

    func finish(): MetisBoundedBootstrapSource {
        if (this.utf8CarryCount != 0) { this.failed = true }
        if (this.failed) {
            return MetisBoundedBootstrapSource(this.path, "", failure: "invalid_bootstrap_encoding",
                totalScannedBytes: this.scannedBytes, maxReadCallBytes: this.maxReadBytes,
                maxRetainedPayloadBytes: this.retainedCapacity())
        }
        if (this.pendingCr) {
            this.acceptNormalizedRune(this.normalizedLf, 1)
            this.pendingCr = false
        }
        if (this.memory && this.lineCount > 0) { this.finishLine() }
        if (this.normalizedBytes <= DEFAULT_BOOTSTRAP_MAX_CHARS) {
            return MetisBoundedBootstrapSource(this.path, this.headString(this.normalizedBytes),
                totalScannedBytes: this.scannedBytes, normalizedOriginalBytes: this.normalizedBytes,
                maxReadCallBytes: this.maxReadBytes, maxRetainedPayloadBytes: this.retainedCapacity())
        }
        let content = if (this.memory) {
            let head = this.headString(DEFAULT_BOOTSTRAP_MAX_CHARS * 9 / 20)
            let tail = this.tailString(DEFAULT_BOOTSTRAP_MAX_CHARS * 3 / 20)
            let marker = "\n[...memory bootstrap compressed: kept head, key index, and tail from ${bootstrapFileLabel(this.path)}; read the source file for full details...]\n"
            let indexBudget = max(0, DEFAULT_BOOTSTRAP_MAX_CHARS - head.size - tail.size - marker.size - 2)
            let index = this.indexString(indexBudget)
            if (index.isEmpty()) { head + marker + tail } else { head + "\n" + index + marker + tail }
        } else {
            let head = this.headString(DEFAULT_BOOTSTRAP_MAX_CHARS * 7 / 10)
            let tail = this.tailString(DEFAULT_BOOTSTRAP_MAX_CHARS * 2 / 10)
            let label = bootstrapFileLabel(this.path)
            head + "\n[...truncated, read ${label} for full content...]\n…(truncated ${label}: kept ${head.size}+${tail.size} chars of ${this.normalizedBytes})…\n" + tail
        }
        MetisBoundedBootstrapSource(this.path, MetisBootstrapBudget.clampToBudget(content, DEFAULT_BOOTSTRAP_MAX_CHARS),
            truncated: true, totalScannedBytes: this.scannedBytes,
            normalizedOriginalBytes: this.normalizedBytes, maxReadCallBytes: this.maxReadBytes,
            maxRetainedPayloadBytes: this.retainedCapacity())
    }

    func failRead(): MetisBoundedBootstrapSource {
        MetisBoundedBootstrapSource(this.path, "", failure: "unreadable_bootstrap_file",
            totalScannedBytes: this.scannedBytes, maxReadCallBytes: this.maxReadBytes,
            maxRetainedPayloadBytes: this.retainedCapacity())
    }
}

func metisScanBoundedBootstrapSource(path: String, read: (Array<Byte>) -> Int64): MetisBoundedBootstrapSource {
    let scanner = MetisBoundedBootstrapScanner(path)
    let buffer = Array<Byte>(METIS_BOOTSTRAP_READ_CHUNK_BYTES, repeat: 0)
    try {
        while (true) {
            let count = read(buffer)
            if (count == 0) { break }
            if (count < 0) { return scanner.failRead() }
            if (count > METIS_BOOTSTRAP_READ_CHUNK_BYTES) {
                return scanner.failRead()
            }
            scanner.accept(buffer, count)
        }
        scanner.finish()
    } catch (_: Exception) {
        scanner.failRead()
    }
}

private func normalizeBootstrapContent(content: String): String {
    content.replace("\r\n", "\n").replace("\r", "\n")
}

private func bootstrapUtf8PrefixWithinBytes(content: String, maxBytes: Int64): String {
    let budget = max(0, maxBytes)
    let out = StringBuilder()
    var used: Int64 = 0
    for (rune in content.toRuneArray()) {
        let piece = String([rune])
        if (used + piece.size > budget) {
            break
        }
        out.append(piece)
        used += piece.size
    }
    out.toString()
}

private func clampBoundedBootstrapToUtf8Bytes(content: String, budget: Int64): String {
    let safeBudget = max(0, budget)
    if (safeBudget <= 0) { return "" }
    if (content.size <= safeBudget) { return content }
    if (safeBudget < 3) { return bootstrapUtf8PrefixWithinBytes(content, safeBudget) }
    bootstrapUtf8PrefixWithinBytes(content, safeBudget - 3) + "…"
}

private func bootstrapUtf8SuffixWithinBytes(content: String, maxBytes: Int64): String {
    let budget = max(0, maxBytes)
    let runes = content.toRuneArray()
    var start = Int64(runes.size)
    var used: Int64 = 0
    var index = Int64(runes.size) - 1
    while (index >= 0) {
        let piece = String([runes[index]])
        if (used + piece.size > budget) {
            break
        }
        used += piece.size
        start = index
        index -= 1
    }
    let out = StringBuilder()
    for (i in start..runes.size) {
        out.append(runes[i])
    }
    out.toString()
}

private func bootstrapFileLabel(path: String): String {
    let normalized = path.replace("\\", "/").trimAscii()
    if (normalized.isEmpty()) {
        return "context file"
    }
    let pieces = normalized.split("/")
    if (pieces.size == 0) {
        return normalized
    }
    let last = pieces[pieces.size - 1].trimAscii()
    if (last.isEmpty()) {
        return normalized
    }
    last
}

private func bootstrapWarningTrimmed(filePath: String, originalLength: Int64, maxChars: Int64): String {
    "workspace bootstrap file ${bootstrapFileLabel(filePath)} is ${originalLength} chars (limit ${maxChars}); truncating in injected context"
}

private func isMemoryBootstrapPath(path: String): Bool {
    bootstrapFileLabel(path).toAsciiLower() == "memory.md"
}

private func clampBootstrapLine(line: String, maxChars: Int64): String {
    let trimmed = line.trimAscii()
    if (trimmed.isEmpty()) {
        return ""
    }
    if (trimmed.size <= maxChars) {
        return trimmed
    }
    MetisBootstrapBudget.clampToBudget(trimmed, maxChars)
}

private func shouldIncludeMemoryIndexLine(line: String): Bool {
    let trimmed = line.trimAscii()
    if (trimmed.isEmpty()) {
        return false
    }
    if (trimmed.startsWith("#") || trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
        return true
    }
    let upper = trimmed.toAsciiUpper()
    upper.contains("TODO") || upper.contains("NOTE") || upper.contains("FIXME") || upper.contains("IMPORTANT")
}

private func buildMemoryIndexSection(content: String, budget: Int64): String {
    if (budget <= 0) {
        return ""
    }
    let sb = StringBuilder()
    var lineCount: Int64 = 0
    for (line in content.lines()) {
        if (!shouldIncludeMemoryIndexLine(line)) {
            continue
        }
        let compacted = clampBootstrapLine(line, MEMORY_INDEX_LINE_MAX_CHARS)
        if (compacted.isEmpty()) {
            continue
        }
        let entry = "- ${compacted}\n"
        if (sb.size + entry.size > budget) {
            break
        }
        sb.append(entry)
        lineCount += 1
        if (lineCount >= 24) {
            break
        }
    }
    if (sb.size == 0) {
        return ""
    }
    let title = "## Memory Index\n"
    if (title.size + sb.size > budget) {
        return MetisBootstrapBudget.clampToBudget(sb.toString(), budget)
    }
    title + sb.toString()
}

private func trimMemoryContent(content: String, path: String, maxChars: Int64): MetisBootstrapTrimResult {
    let effectiveMax = max(1, maxChars)
    let normalized = normalizeBootstrapContent(content)
    let result = MetisBootstrapTrimResult()
    result.maxChars = effectiveMax
    result.originalLength = normalized.size
    if (normalized.size <= effectiveMax) {
        result.content = normalized
        return result
    }

    let headChars = min(normalized.size, max(MEMORY_MIN_HEAD_CHARS, effectiveMax * 9 / 20))
    let tailChars = min(max(0, normalized.size - headChars), max(MEMORY_MIN_TAIL_CHARS, effectiveMax * 3 / 20))
    let head = bootstrapUtf8PrefixWithinBytes(normalized, headChars)
    let tail = bootstrapUtf8SuffixWithinBytes(normalized, tailChars)
    let marker =
        "\n[...memory bootstrap compressed: kept head, key index, and tail from ${bootstrapFileLabel(path)}; read the source file for full details...]\n"
    let reservedChars = head.size + marker.size + tail.size + 2
    let indexBudget = max(0, effectiveMax - reservedChars)
    let indexSection = buildMemoryIndexSection(normalized, indexBudget)
    let contentWithIndex = if (indexSection.isEmpty()) {
        head + marker + tail
    } else {
        head + "\n" + indexSection + marker + tail
    }
    result.content = MetisBootstrapBudget.clampToBudget(contentWithIndex, effectiveMax)
    result.truncated = true
    result
}

public class MetisBootstrapBudget {
    public static func describe(result: MetisBootstrapBudgetResult): String {
        "bootstrapFiles=${result.files.size}, bootstrapChars=${result.totalChars}, bootstrapOriginalChars=${result.originalTotalChars}, bootstrapTruncatedFiles=${result.truncatedFiles}, bootstrapMissingFiles=${result.missingFiles}, bootstrapSkippedFiles=${result.skippedFiles}, bootstrapWarnings=${result.warnings.size}"
    }

    public static func clampToBudget(content: String, budget: Int64): String {
        let safeBudget = max(0, budget)
        if (safeBudget <= 0) {
            return ""
        }
        if (content.size <= safeBudget) {
            return content
        }
        if (safeBudget <= 1) {
            return bootstrapUtf8PrefixWithinBytes(content, safeBudget)
        }
        bootstrapUtf8PrefixWithinBytes(content, safeBudget - 1) + "…"
    }

    public static func trimContent(content: String, path!: String = "", maxChars!: Int64 = DEFAULT_BOOTSTRAP_MAX_CHARS): MetisBootstrapTrimResult {
        let effectiveMax = max(1, maxChars)
        let normalized = normalizeBootstrapContent(content)
        if (isMemoryBootstrapPath(path) && normalized.size > effectiveMax) {
            return trimMemoryContent(normalized, path, effectiveMax)
        }
        let result = MetisBootstrapTrimResult()
        result.maxChars = effectiveMax
        result.originalLength = normalized.size
        if (normalized.size <= effectiveMax) {
            result.content = normalized
            return result
        }

        let headChars = max(1, effectiveMax * BOOTSTRAP_HEAD_RATIO_NUMERATOR / BOOTSTRAP_HEAD_RATIO_DENOMINATOR)
        let tailChars = max(1, effectiveMax * BOOTSTRAP_TAIL_RATIO_NUMERATOR / BOOTSTRAP_TAIL_RATIO_DENOMINATOR)
        let safeHeadChars = min(headChars, normalized.size)
        let safeTailBudget = max(0, normalized.size - safeHeadChars)
        let safeTailChars = min(tailChars, safeTailBudget)
        let head = bootstrapUtf8PrefixWithinBytes(normalized, safeHeadChars)
        let tail = bootstrapUtf8SuffixWithinBytes(normalized, safeTailChars)
        let fileName = bootstrapFileLabel(path)
        let marker = "\n[...truncated, read ${fileName} for full content...]\n…(truncated ${fileName}: kept ${safeHeadChars}+${safeTailChars} chars of ${normalized.size})…\n"
        result.content = head + marker + tail
        result.truncated = true
        result
    }

    public static func buildContextFiles(
        files: Array<MetisContextFile>,
        maxChars!: Int64 = DEFAULT_BOOTSTRAP_MAX_CHARS,
        totalMaxChars!: Int64 = DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS
    ): MetisBootstrapBudgetResult {
        let effectiveMaxChars = max(1, maxChars)
        let effectiveTotalMaxChars = max(1, totalMaxChars)
        var remainingTotalChars = effectiveTotalMaxChars
        let result = MetisBootstrapBudgetResult()
        let out = ArrayList<MetisContextFile>()
        let warnings = ArrayList<String>()
        for (file in files) {
            result.originalTotalChars += normalizeBootstrapContent(file.content).size
            if (remainingTotalChars <= 0) {
                result.skippedFiles += 1
                break
            }
            let normalizedPath = file.path.trimAscii()
            if (normalizedPath.isEmpty()) {
                warnings.add("skipping bootstrap file with empty path")
                result.skippedFiles += 1
                continue
            }
            let normalizedContent = normalizeBootstrapContent(file.content)
            if (normalizedContent.startsWith(MISSING_CONTEXT_FILE_PREFIX)) {
                result.missingFiles += 1
                let cappedMissing = MetisBootstrapBudget.clampToBudget(normalizedContent, remainingTotalChars)
                if (cappedMissing.isEmpty()) {
                    result.skippedFiles += 1
                    break
                }
                remainingTotalChars = max(0, remainingTotalChars - cappedMissing.size)
                out.add(MetisContextFile(file.path, cappedMissing))
                continue
            }
            if (remainingTotalChars < MIN_BOOTSTRAP_FILE_BUDGET_CHARS) {
                warnings.add(
                    "remaining bootstrap budget is ${remainingTotalChars} chars (<${MIN_BOOTSTRAP_FILE_BUDGET_CHARS}); skipping additional bootstrap files"
                )
                break
            }
            let fileMaxChars = min(effectiveMaxChars, remainingTotalChars)
            let trimmed = MetisBootstrapBudget.trimContent(normalizedContent, path: file.path, maxChars: fileMaxChars)
            let contentWithinBudget = MetisBootstrapBudget.clampToBudget(trimmed.content, remainingTotalChars)
            if (contentWithinBudget.isEmpty()) {
                result.skippedFiles += 1
                continue
            }
            if (trimmed.truncated || contentWithinBudget.size < trimmed.content.size) {
                result.truncatedFiles += 1
                warnings.add(bootstrapWarningTrimmed(file.path, trimmed.originalLength, trimmed.maxChars))
            }
            remainingTotalChars = max(0, remainingTotalChars - contentWithinBudget.size)
            out.add(MetisContextFile(file.path, contentWithinBudget))
        }
        result.files = out.toArray()
        result.warnings = warnings.toArray()
        result.totalChars = effectiveTotalMaxChars - remainingTotalChars
        result
    }

    static func buildBoundedContextFiles(sources: Array<MetisBoundedBootstrapSource>): MetisBootstrapBudgetResult {
        var remainingTotalBytes = DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS
        let result = MetisBootstrapBudgetResult()
        let out = ArrayList<MetisContextFile>()
        let warnings = ArrayList<String>()
        for (source in sources) {
            let originalBytes = if (source.failure.isEmpty()) {
                source.normalizedOriginalBytes
            } else {
                Int64(source.content.size)
            }
            result.originalTotalChars += originalBytes
            if (remainingTotalBytes <= 0) {
                result.skippedFiles += 1
                break
            }
            if (source.path.trimAscii().isEmpty()) {
                warnings.add("skipping bootstrap file with empty path")
                result.skippedFiles += 1
                continue
            }
            if (source.content.startsWith(MISSING_CONTEXT_FILE_PREFIX)) {
                result.missingFiles += 1
            }
            if (!source.failure.isEmpty()) {
                warnings.add("workspace bootstrap load failed: ${source.failure}")
            }
            if (remainingTotalBytes < MIN_BOOTSTRAP_FILE_BUDGET_CHARS &&
                !source.content.startsWith(MISSING_CONTEXT_FILE_PREFIX)) {
                warnings.add(
                    "remaining bootstrap budget is ${remainingTotalBytes} chars (<${MIN_BOOTSTRAP_FILE_BUDGET_CHARS}); skipping additional bootstrap files"
                )
                break
            }
            let sourceExceedsRemaining = source.content.size > remainingTotalBytes
            let bounded = clampBoundedBootstrapToUtf8Bytes(source.content, remainingTotalBytes)
            if (bounded.isEmpty()) {
                result.skippedFiles += 1
                continue
            }
            if (source.truncated || sourceExceedsRemaining || bounded.size < source.content.size) {
                result.truncatedFiles += 1
                warnings.add(bootstrapWarningTrimmed(
                    source.path,
                    originalBytes,
                    min(DEFAULT_BOOTSTRAP_MAX_CHARS, remainingTotalBytes)
                ))
            }
            remainingTotalBytes -= Int64(bounded.size)
            out.add(MetisContextFile(source.path, bounded))
        }
        result.files = out.toArray()
        result.warnings = warnings.toArray()
        result.totalChars = DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS - remainingTotalBytes
        result
    }
}
