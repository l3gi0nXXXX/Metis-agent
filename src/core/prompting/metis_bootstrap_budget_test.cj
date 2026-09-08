package metis.core.prompting

import std.collection.ArrayList
import std.fs.{Directory, File, FileInfo, Path, exists, remove}
import std.unittest.testmacro.*

private class BootstrapInjectedReader {
    private let data: Array<Byte>
    private let readSizes: Array<Int64>
    private let failCall: Int64
    private var offset: Int64 = 0
    private var calls: Int64 = 0

    init(data: Array<Byte>, readSizes!: Array<Int64> = [METIS_BOOTSTRAP_READ_CHUNK_BYTES], failCall!: Int64 = 0) {
        this.data = data
        this.readSizes = readSizes
        this.failCall = failCall
    }

    func read(buffer: Array<Byte>): Int64 {
        this.calls += 1
        if (this.failCall > 0 && this.calls == this.failCall) { throw Exception("injected read failure") }
        if (this.offset >= Int64(this.data.size)) { return 0 }
        let requested = this.readSizes[(this.calls - 1) % Int64(this.readSizes.size)]
        let count = min(min(requested, Int64(buffer.size)), Int64(this.data.size) - this.offset)
        for (index in 0..count) { buffer[index] = this.data[this.offset + index] }
        this.offset += count
        count
    }
}

private class BootstrapNegativeAfterPartialReader {
    private let partial = "negative-read-partial-sentinel".toArray()
    private var calls: Int64 = 0

    func read(buffer: Array<Byte>): Int64 {
        this.calls += 1
        if (this.calls > 1) { return -1 }
        for (index in 0..Int64(this.partial.size)) { buffer[index] = this.partial[index] }
        Int64(this.partial.size)
    }

    func partialSize(): Int64 { Int64(this.partial.size) }
}

private func scanBootstrapBytes(path: String, bytes: Array<Byte>, readSizes!: Array<Int64> = [METIS_BOOTSTRAP_READ_CHUNK_BYTES], failCall!: Int64 = 0): MetisBoundedBootstrapSource {
    let reader = BootstrapInjectedReader(bytes, readSizes: readSizes, failCall: failCall)
    metisScanBoundedBootstrapSource(path, {buffer: Array<Byte> => reader.read(buffer)})
}

private func repeatText(text: String, count: Int64): String {
    var out = ""
    for (_ in 0..count) {
        out += text
    }
    out
}

private func repeatTextWithBuilder(text: String, count: Int64): String {
    let out = StringBuilder()
    for (_ in 0..count) { out.append(text) }
    out.toString()
}

@Test
public class MetisBootstrapBudgetTest {
    @TestCase
    public func s2B1U1StreamsTenMiBWithoutRetainingTheSource(): Unit {
        let root = Path("/tmp/metis-s2-b1-u1")
        let path = root.join("MEMORY.md")
        let noLinePath = root.join("AGENTS.md")
        try {
            if (exists(root)) { remove(root, recursive: true) }
            Directory.create(root, recursive: true)
            let chunkText = "# retained-head🙂\n" + "candidate-ten-mib-" + repeatTextWithBuilder("x", 60000) +
                "IMPORTANT after-retained-prefix\n"
            let chunk = chunkText.toArray()
            try (file = File.create(path)) {
                var written: Int64 = 0
                while (written < 10 * 1024 * 1024) {
                    let remaining = 10 * 1024 * 1024 - written
                    let count = min(remaining, Int64(chunk.size))
                    if (count == Int64(chunk.size)) {
                        file.write(chunk)
                    } else {
                        let last = Array<Byte>(count, repeat: b'x')
                        file.write(last)
                    }
                    written += count
                }
            }
            let noLineChunk = Array<Byte>(METIS_BOOTSTRAP_READ_CHUNK_BYTES, repeat: b'n')
            try (file = File.create(noLinePath)) {
                var written: Int64 = 0
                while (written < 10 * 1024 * 1024) {
                    let remaining = 10 * 1024 * 1024 - written
                    let count = min(remaining, METIS_BOOTSTRAP_READ_CHUNK_BYTES)
                    if (count == METIS_BOOTSTRAP_READ_CHUNK_BYTES) {
                        file.write(noLineChunk)
                    } else {
                        file.write(Array<Byte>(count, repeat: b'n'))
                    }
                    written += count
                }
            }
            let source = loadContextFile(path)
            let noLineSource = loadContextFile(noLinePath)
            @Expect(source.failure, "")
            @Expect(source.totalScannedBytes, FileInfo(path).size)
            @Expect(source.normalizedOriginalBytes, FileInfo(path).size)
            @Expect(source.maxReadCallBytes > 0 && source.maxReadCallBytes <= METIS_BOOTSTRAP_READ_CHUNK_BYTES, true)
            @Expect(source.maxRetainedPayloadBytes > 0 && source.maxRetainedPayloadBytes <= METIS_BOOTSTRAP_RETAINED_PAYLOAD_BYTES, true)
            @Expect(source.content.size <= DEFAULT_BOOTSTRAP_MAX_CHARS, true)
            @Expect(source.content.contains("## Memory Index"), true)
            @Expect(source.content.contains("candidate-ten-mib-"), true)
            @Expect(source.content.contains("IMPORTANT after-retained-prefix"), false)
            @Expect(source.content.split("\n- ").size, 25)
            @Expect(source.content.endsWith("x"), true)
            @Expect(noLineSource.failure, "")
            @Expect(noLineSource.totalScannedBytes, FileInfo(noLinePath).size)
            @Expect(noLineSource.normalizedOriginalBytes, FileInfo(noLinePath).size)
            @Expect(noLineSource.maxReadCallBytes, METIS_BOOTSTRAP_READ_CHUNK_BYTES)
            @Expect(noLineSource.maxRetainedPayloadBytes <= METIS_BOOTSTRAP_RETAINED_PAYLOAD_BYTES, true)
            @Expect(noLineSource.content.size <= DEFAULT_BOOTSTRAP_MAX_CHARS, true)
        } finally {
            if (exists(root)) { remove(root, recursive: true) }
        }
    }

    @TestCase
    public func s2B1B1HonorsChunkUtf8CrAndMemoryIndexBoundaries(): Unit {
        let content = "# 标题🙂\r\n" + "candidate-after-prefix-" + repeatTextWithBuilder("a", 170) +
            "IMPORTANT after-prefix\r" + "candidate-cross-chunk-" + repeatTextWithBuilder("b", 65400) +
            "FIXME cross-chunk🙂\n" + repeatTextWithBuilder("tail", 6000)
        let source = scanBootstrapBytes("MEMORY.md", content.toArray(), readSizes: [1, 2, 3, 65536, 17])
        @Expect(source.failure, "")
        @Expect(source.totalScannedBytes, Int64(content.size))
        @Expect(source.normalizedOriginalBytes, Int64(content.replace("\r\n", "\n").replace("\r", "\n").size))
        @Expect(source.maxReadCallBytes > 0 && source.maxReadCallBytes <= METIS_BOOTSTRAP_READ_CHUNK_BYTES, true)
        @Expect(source.maxRetainedPayloadBytes <= METIS_BOOTSTRAP_RETAINED_PAYLOAD_BYTES, true)
        @Expect(source.content.split("candidate-after-prefix-").size >= 3, true)
        @Expect(source.content.contains("candidate-cross-chunk-"), true)
        @Expect(source.content.size <= DEFAULT_BOOTSTRAP_MAX_CHARS, true)
        @Expect(String.fromUtf8(source.content.toArray()), source.content)

        let beforeKeyword = "candidate-split-keyword-" + repeatTextWithBuilder("q", 170) + "IMP"
        let splitKeywordContent = beforeKeyword + "ORTANT\n" + repeatTextWithBuilder("tail", 6000)
        let splitKeyword = scanBootstrapBytes(
            "MEMORY.md",
            splitKeywordContent.toArray(),
            readSizes: [Int64(beforeKeyword.size), 1, 2, 3]
        )
        @Expect(splitKeyword.failure, "")
        @Expect(splitKeyword.content.split("candidate-split-keyword-").size >= 3, true)

        let leadingSpaceLabel = "candidate-after-leading-space-"
        let leadingSpaceContent = repeatTextWithBuilder(" ", 400) + leadingSpaceLabel +
            repeatTextWithBuilder("l", 170) + "IMPORTANT\n" + repeatTextWithBuilder("tail", 6000)
        let leadingSpace = scanBootstrapBytes("MEMORY.md", leadingSpaceContent.toArray(), readSizes: [64, 257, 65536])
        @Expect(leadingSpace.failure, "")
        @Expect(leadingSpace.content.split(leadingSpaceLabel).size >= 3, true)

        let runeBoundaryLabel = "candidate-rune-boundary-"
        let expectedRuneBoundaryPrefix = runeBoundaryLabel +
            repeatTextWithBuilder("r", 159 - Int64(runeBoundaryLabel.size))
        let runeBoundaryContent = expectedRuneBoundaryPrefix + "🙂after-boundary TODO\n" +
            repeatTextWithBuilder("tail", 6000)
        let runeBoundary = scanBootstrapBytes("MEMORY.md", runeBoundaryContent.toArray(), readSizes: [159, 1, 2, 7])
        @Expect(runeBoundary.failure, "")
        @Expect(expectedRuneBoundaryPrefix.size, 159)
        @Expect(runeBoundary.content.contains("\n- ${expectedRuneBoundaryPrefix}\n"), true)
        @Expect(runeBoundary.content.contains("\n- ${expectedRuneBoundaryPrefix}a"), false)
        @Expect(String.fromUtf8(runeBoundary.content.toArray()), runeBoundary.content)
    }

    @TestCase
    public func s2B1P1KeepsLegacyAndBoundedBudgetContractsDistinct(): Unit {
        let exact = repeatTextWithBuilder("e", DEFAULT_BOOTSTRAP_MAX_CHARS)
        let over = exact + "🙂"
        let exactSource = scanBootstrapBytes("AGENTS.md", exact.toArray())
        let overSource = scanBootstrapBytes("TOOLS.md", over.toArray())
        let exactAggregateSources = ArrayList<MetisBoundedBootstrapSource>()
        let overAggregateSources = ArrayList<MetisBoundedBootstrapSource>()
        for (index in 0..7) {
            let source = scanBootstrapBytes("SOURCE-${index}.md", exact.toArray())
            exactAggregateSources.add(source)
            overAggregateSources.add(source)
        }
        exactAggregateSources.add(scanBootstrapBytes("LAST.md", repeatTextWithBuilder("z", 10000).toArray()))
        overAggregateSources.add(scanBootstrapBytes("LAST.md", repeatTextWithBuilder("z", 10001).toArray()))
        let boundedExact = MetisBootstrapBudget.buildBoundedContextFiles(exactAggregateSources.toArray())
        let boundedOver = MetisBootstrapBudget.buildBoundedContextFiles(overAggregateSources.toArray())
        let legacy = MetisBootstrapBudget.buildContextFiles([
            MetisContextFile("AGENTS.md", exact), MetisContextFile("TOOLS.md", over)
        ])
        @Expect(exactSource.content, exact)
        @Expect(exactSource.truncated, false)
        @Expect(overSource.truncated, true)
        @Expect(overSource.content.size <= DEFAULT_BOOTSTRAP_MAX_CHARS, true)
        @Expect(boundedExact.files.size, 8)
        @Expect(boundedExact.totalChars, DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS)
        @Expect(boundedExact.originalTotalChars, DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS)
        @Expect(boundedExact.files[7].content.size, 10000)
        @Expect(boundedOver.files.size, 8)
        @Expect(boundedOver.totalChars, DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS)
        @Expect(boundedOver.originalTotalChars, DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS + 1)
        @Expect(boundedOver.files[7].content.size, 10000)
        @Expect(boundedOver.files[7].content.endsWith("…"), true)
        @Expect(boundedOver.files[7].content, repeatTextWithBuilder("z", 9997) + "…")
        @Expect(String.fromUtf8(boundedOver.files[7].content.toArray()), boundedOver.files[7].content)
        @Expect(boundedOver.truncatedFiles, 1)
        @Expect(legacy.files.size, 2)
        @Expect(legacy.totalChars <= DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS, true)
    }

    @TestCase
    public func s2B1N1RejectsInvalidIncompleteAndReadFailureWithoutPartialContent(): Unit {
        let invalid = scanBootstrapBytes("AGENTS.md", [0x61u8, 0xf0u8, 0x28u8, 0x8cu8, 0x28u8])
        let incomplete = scanBootstrapBytes("AGENTS.md", [0x61u8, 0xe4u8, 0xb8u8])
        let failed = scanBootstrapBytes("AGENTS.md", (repeatText("discarded-payload", 100)).toArray(), readSizes: [7], failCall: 3)
        let negativeReader = BootstrapNegativeAfterPartialReader()
        let negative = metisScanBoundedBootstrapSource("AGENTS.md", {buffer: Array<Byte> => negativeReader.read(buffer)})
        let eofCr = scanBootstrapBytes("AGENTS.md", "中文🙂\r".toArray(), readSizes: [1])
        for (source in [invalid, incomplete, failed, negative]) {
            @Expect(source.content, "")
            @Expect(source.normalizedOriginalBytes, 0)
            @Expect(source.maxRetainedPayloadBytes <= METIS_BOOTSTRAP_RETAINED_PAYLOAD_BYTES, true)
        }
        @Expect(invalid.failure, "invalid_bootstrap_encoding")
        @Expect(incomplete.failure, "invalid_bootstrap_encoding")
        @Expect(failed.failure, "unreadable_bootstrap_file")
        @Expect(failed.totalScannedBytes, 14)
        @Expect(failed.content.contains("discarded-payload"), false)
        @Expect(negative.failure, "unreadable_bootstrap_file")
        @Expect(negative.totalScannedBytes, negativeReader.partialSize())
        @Expect(negative.content.contains("negative-read-partial-sentinel"), false)
        @Expect(eofCr.failure, "")
        @Expect(eofCr.content, "中文🙂\n")
    }

    @TestCase
    public func trimContentKeepsInputWhenAlreadyWithinLimit(): Unit {
        let result = MetisBootstrapBudget.trimContent("alpha\nbeta", path: "MEMORY.md", maxChars: 64)
        @Expect(result.truncated, false)
        @Expect(result.content, "alpha\nbeta")
        @Expect(result.originalLength, "alpha\nbeta".size)
        @Expect(result.maxChars, 64)
    }

    @TestCase
    public func trimContentAddsMarkerAndKeepsHeadTailWhenOverLimit(): Unit {
        let content = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let result = MetisBootstrapBudget.trimContent(content, path: "/tmp/AGENTS.md", maxChars: 20)
        @Expect(result.truncated, true)
        @Expect(result.originalLength, content.size)
        @Expect(result.content.startsWith("ABCDEFGHIJKLMN"), true)
        @Expect(result.content.contains("[...truncated, read AGENTS.md for full content...]"), true)
        @Expect(result.content.contains("kept 14+4 chars"), true)
        @Expect(result.content.endsWith("6789"), true)
    }

    @TestCase
    public func trimContentCompressesMemoryIntoHeadIndexAndTail(): Unit {
        let content =
            "# Goals\n" +
            "- keep telegram fast\n" +
            "body-body-body-body-body-body-body-body-body-body-body-body-body-body-body-body\n" +
            "## Notes\n" +
            "IMPORTANT: preserve runtime behavior\n" +
            repeatText("tail-", 500)
        let result = MetisBootstrapBudget.trimContent(content, path: "/tmp/MEMORY.md", maxChars: 1800)
        @Expect(result.truncated, true)
        @Expect(result.content.contains("## Memory Index"), true)
        @Expect(result.content.contains("keep telegram fast"), true)
        @Expect(result.content.contains("IMPORTANT: preserve runtime behavior"), true)
        @Expect(result.content.contains("memory bootstrap compressed"), true)
        @Expect(result.content.size <= 1800, true)
    }

    @TestCase
    public func clampToBudgetAddsEllipsisWhenNeeded(): Unit {
        @Expect(MetisBootstrapBudget.clampToBudget("abcdef", 0), "")
        @Expect(MetisBootstrapBudget.clampToBudget("abcdef", 1), "a")
        @Expect(MetisBootstrapBudget.clampToBudget("abcdef", 4), "abc…")
        @Expect(MetisBootstrapBudget.clampToBudget("abc", 8), "abc")
    }

    @TestCase
    public func clampToBudgetStopsAtChineseAndEmojiUtf8Boundaries(): Unit {
        let clipped = MetisBootstrapBudget.clampToBudget("A中文🙂Z", 9)
        @Expect(clipped, "A中文…")
        @Expect(String.fromUtf8(clipped.toArray()), clipped)
    }

    @TestCase
    public func trimContentKeepsUnicodeHeadAndTailWithinByteBudget(): Unit {
        let content = repeatText("前缀中文🙂body-", 300) + "结尾🙂"
        let result = MetisBootstrapBudget.trimContent(content, path: "AGENTS.md", maxChars: 2000)
        @Expect(result.truncated, true)
        @Expect(result.content.contains("[...truncated, read AGENTS.md for full content...]"), true)
        @Expect(result.content.endsWith("结尾🙂"), true)
        @Expect(result.content.size <= 2000, true)
        @Expect(String.fromUtf8(result.content.toArray()), result.content)
    }

    @TestCase
    public func trimMemoryContentKeepsUnicodeHeadAndTailWithinByteBudget(): Unit {
        let content =
            "# 中文目标🙂\n" +
            "- 保留索引🙂\n" +
            repeatText("正文中文🙂tail-", 400) +
            "最终尾部🙂"
        let result = MetisBootstrapBudget.trimContent(content, path: "MEMORY.md", maxChars: 1800)
        @Expect(result.truncated, true)
        @Expect(result.content.contains("memory bootstrap compressed"), true)
        @Expect(result.content.contains("中文目标🙂"), true)
        @Expect(result.content.endsWith("最终尾部🙂"), true)
        @Expect(result.content.size <= 1800, true)
        @Expect(String.fromUtf8(result.content.toArray()), result.content)
    }

    @TestCase
    public func buildContextFilesRespectsTotalBudgetAndCarriesWarnings(): Unit {
        let files = [
            MetisContextFile("agents.md", repeatText("a", 120)),
            MetisContextFile("memory.md", repeatText("b", 120))
        ]
        let result = MetisBootstrapBudget.buildContextFiles(files, maxChars: 80, totalMaxChars: 300)
        @Expect(result.files.size, 2)
        @Expect(result.totalChars <= 300, true)
        @Expect(result.files[0].content.isEmpty(), false)
        @Expect(result.files[1].content.isEmpty(), false)
        @Expect(result.warnings.size >= 2, true)
        @Expect(result.warnings[0].contains("agents.md"), true)
        @Expect(result.warnings[1].contains("memory.md"), true)
    }

    /*
    @TestCase
    public func buildContextFilesStopsWhenRemainingBudgetFallsBelowFileThreshold(): Unit {
        let files = [
            MetisContextFile("agents.md", repeatText("a", 120)),
            MetisContextFile("memory.md", repeatText("b", 120))
        ]
        let result = MetisBootstrapBudget.buildContextFiles(files, maxChars: 80, totalMaxChars: 80)
        @Expect(result.files.size, 1)
        @Expect(result.warnings.size >= 1, true)
        @Expect(result.warnings[result.warnings.size - 1].contains("remaining bootstrap budget is"), true)
    }
    */

    @TestCase
    public func buildContextFilesPreservesMissingPlaceholderEntries(): Unit {
        let missing = "[MISSING] Expected at: /tmp/workspace/MEMORY.md"
        let files = [MetisContextFile("/tmp/workspace/MEMORY.md", missing)]
        let result = MetisBootstrapBudget.buildContextFiles(files, maxChars: 32, totalMaxChars: 128)
        @Expect(result.files.size, 1)
        @Expect(result.files[0].content, missing)
        @Expect(result.warnings.size, 0)
    }

    @TestCase
    public func describeFormatsBootstrapStatsAsSingleSummaryLine(): Unit {
        let result = MetisBootstrapBudgetResult()
        result.files = [MetisContextFile("agents.md", "a"), MetisContextFile("memory.md", "b")]
        result.totalChars = 123
        result.originalTotalChars = 456
        result.truncatedFiles = 1
        result.missingFiles = 2
        result.skippedFiles = 3
        result.warnings = ["warning"]
        let summary = MetisBootstrapBudget.describe(result)
        @Expect(summary.contains("bootstrapFiles=2"), true)
        @Expect(summary.contains("bootstrapChars=123"), true)
        @Expect(summary.contains("bootstrapOriginalChars=456"), true)
        @Expect(summary.contains("bootstrapTruncatedFiles=1"), true)
        @Expect(summary.contains("bootstrapMissingFiles=2"), true)
        @Expect(summary.contains("bootstrapSkippedFiles=3"), true)
        @Expect(summary.contains("bootstrapWarnings=1"), true)
    }
}
