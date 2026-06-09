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
    public func safeUtf8DecodeReportsInvalidBytesWithoutThrowing(): Unit {
        let decoded = metisDecodeUtf8Bytes([255u8, 254u8, 65u8])
        @Expect(decoded.ok, false)
        @Expect(decoded.status, "invalid_response_encoding")
        @Expect(decoded.text, "")
        @Expect(decoded.diagnostic.toAsciiLower().contains("invalid"), true)
    }
}
