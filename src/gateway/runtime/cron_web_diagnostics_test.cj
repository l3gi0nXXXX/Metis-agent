package metis.gateway.runtime

import std.unittest.testmacro.*

@Test
public class CronWebDiagnosticsTest {
    @TestCase
    public func m5u1ParsesKnownWebDiagnosticsAndIgnoresPlainText(): Unit {
        let unavailable = cronWebDiagnosticFromText(
            "Status: error\nDiagnostic: code=web_provider_unavailable message=Real-time web search is unavailable."
        ).getOrThrow()
        @Expect(unavailable.code, "web_provider_unavailable")
        @Expect(unavailable.message.contains("Real-time web search"), true)

        let blocked = cronWebDiagnosticFromText(
            "Cron/headless shell execution blocked. Diagnostic: code=cron_tool_exec_blocked reason=deny.\nStatus: error\nDiagnostic: code=web_fetch_blocked_url message=URL host resolves to private network."
        ).getOrThrow()
        @Expect(blocked.code, "web_fetch_blocked_url")
        @Expect(blocked.message.contains("private network"), true)

        @Expect(cronWebDiagnosticFromText("normal cron answer without diagnostics").isNone(), true)
    }

    @TestCase
    public func m5b1WebDiagnosticRedactsAndSafelyTruncatesUtf8Message(): Unit {
        let longSecret = "中文🙂 Authorization: Bearer secret-token-never-visible token=raw-lower-secret https://user:pass@example.com/path "
        let text = "Status: error\nDiagnostic: code=invalid_response_encoding message=${longSecret}${longSecret}${longSecret}${longSecret}"
        let diagnostic = cronWebDiagnosticFromText(text).getOrThrow()

        @Expect(diagnostic.code, "invalid_response_encoding")
        @Expect(diagnostic.message.contains("中文🙂"), true)
        @Expect(diagnostic.message.contains("secret-token-never-visible"), false)
        @Expect(diagnostic.message.contains("raw-lower-secret"), false)
        @Expect(diagnostic.message.size < 320, true)
    }
}
