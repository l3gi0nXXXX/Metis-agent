package metis.core.prompting

import std.unittest.testmacro.*

private func repeatText(text: String, count: Int64): String {
    var out = ""
    for (_ in 0..count) {
        out += text
    }
    out
}

@Test
public class MetisBootstrapBudgetTest {
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
