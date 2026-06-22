package metis.core.support_surface_tests

import metis.core.*

import std.unittest.testmacro.*

@Test
public class TextSafetyTest {
    private func repeatText(text: String, count: Int64): String {
        let out = StringBuilder()
        for (_ in 0..count) {
            out.append(text)
        }
        out.toString()
    }

    @TestCase
    public func safePrefixKeepsUtf8RuneBoundaries(): Unit {
        let text = this.repeatText("中文🙂", 20)
        let clipped = metisSafeUtf8Prefix(text, 7, marker: "...[TRUNCATED]")
        @Expect(clipped.contains("中文"), true)
        @Expect(clipped.endsWith("...[TRUNCATED]"), true)
        @Expect(clipped.toRuneArray().size <= 7 + "...[TRUNCATED]".toRuneArray().size, true)
    }

    @TestCase
    public func safeRuneEllipsisKeepsUtf8RuneBoundaries(): Unit {
        let text = this.repeatText("阶段中文🙂👨‍👩‍👧", 20)
        let clipped = metisSafeRuneEllipsis(text, 12)
        @Expect(clipped.contains("阶段"), true)
        @Expect(clipped.endsWith("..."), true)
        @Expect(clipped.toRuneArray().size <= 12, true)
        @Expect(String.fromUtf8(clipped.toArray()), clipped)
        @Expect(metisSafeRuneEllipsis("abcdef", 5), "ab...")
    }

    @TestCase
    public func safeRuneEllipsisHandlesSmallWidthsAndShortText(): Unit {
        @Expect(metisSafeRuneEllipsis("abcdef", 0), "")
        @Expect(metisSafeRuneEllipsis("abcdef", 1), ".")
        @Expect(metisSafeRuneEllipsis("abcdef", 2), "..")
        @Expect(metisSafeRuneEllipsis("abcdef", 3), "...")
        @Expect(metisSafeRuneEllipsis("中文🙂", 3), "中文🙂")
        @Expect(metisSafeRuneEllipsis("中文🙂", 4), "中文🙂")
    }

    @TestCase
    public func safeUtf8DecodeReportsInvalidBytesWithoutThrowing(): Unit {
        let decoded = metisDecodeUtf8Bytes([255u8, 254u8, 65u8])
        @Expect(decoded.ok, false)
        @Expect(decoded.status, "invalid_response_encoding")
        @Expect(decoded.text, "")
        @Expect(decoded.diagnostic.toAsciiLower().contains("invalid"), true)
    }
}
