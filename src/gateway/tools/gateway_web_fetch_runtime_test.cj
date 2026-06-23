package metis.gateway.tools

import std.collection.ArrayList
import std.unittest.testmacro.*

private func gatewayWebFetchRuntimeRepeat(part: String, count: Int64): String {
    let out = StringBuilder()
    for (_ in 0..count) {
        out.append(part)
    }
    out.toString()
}

private func gatewayWebFetchRuntimeRejects(url: String, code: String): Unit {
    let decision = gatewayWebValidateUrl(url)
    @Expect(decision.allowed, false)
    @Expect(decision.code, code)
}

private func gatewayWebFetchRuntimeFetch(
    url: String,
    maxBytes!: Int64 = 1_000_000,
    maxRedirects!: Int64 = 3
): GatewayWebFetchResult {
    gatewayWebFetchUrl(GatewayWebFetchRequest(url, maxBytes: maxBytes, timeoutMs: 1000, maxRedirects: maxRedirects))
}

@Test
public class GatewayWebFetchRuntimeTest {
    @TestCase
    public func m3u1UrlGuardAllowsPublicHttpAndRejectsUnsafeUrls(): Unit {
        // M3-U1
        let https = gatewayWebValidateUrl("https://example.com/a")
        @Expect(https.allowed, true)
        @Expect(https.code, "ok")
        @Expect(https.normalizedUrl, "https://example.com/a")
        @Expect(https.redactedUrl.contains("example.com"), true)

        let http = gatewayWebValidateUrl("http://example.com:80/a")
        @Expect(http.allowed, true)
        @Expect(http.code, "ok")

        gatewayWebFetchRuntimeRejects("file:///tmp/a", "web_fetch_invalid_url")
        gatewayWebFetchRuntimeRejects("ftp://example.com/a", "web_fetch_invalid_url")
        gatewayWebFetchRuntimeRejects("http://localhost/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://127.0.0.1/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://[::1]/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://10.1.2.3/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://172.16.0.1/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://192.168.0.1/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://169.254.169.254/latest", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://192.0.2.10/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://198.51.100.10/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("http://203.0.113.10/a", "web_fetch_blocked_url")
        gatewayWebFetchRuntimeRejects("https://example.com/a?token=secret", "web_fetch_secret_url")
        gatewayWebFetchRuntimeRejects("https://example.com/a?password=secret", "web_fetch_secret_url")
        gatewayWebFetchRuntimeRejects("https://example.com/a?auth=secret", "web_fetch_secret_url")
        gatewayWebFetchRuntimeRejects("https://user:secret@example.com/a", "web_fetch_secret_url")

        let secret = gatewayWebValidateUrl("https://example.com/a?access_token=never-print")
        @Expect(secret.allowed, false)
        @Expect(secret.redactedUrl.contains("never-print"), false)
        @Expect(secret.redactedUrl.contains("access_token"), false)
    }

    @TestCase
    public func m3b1BoundaryInputsAreSafeAndUtf8TruncationKeepsRuneBoundaries(): Unit {
        // M3-B1
        let longUrl = "https://example.com/" + gatewayWebFetchRuntimeRepeat("a", 4100)
        let longDecision = gatewayWebValidateUrl(longUrl)
        @Expect(longDecision.allowed, false)
        @Expect(longDecision.code, "web_fetch_invalid_url")

        let unicodeDecision = gatewayWebValidateUrl("https://example.com/新闻/🙂")
        @Expect(unicodeDecision.allowed, true)
        @Expect(unicodeDecision.code, "ok")

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(200, bodyBytes: [195u8, 40u8], contentType: "text/plain; charset=utf-8")
        }))
        try {
            let invalidFetch = gatewayWebFetchRuntimeFetch("https://example.com/invalid-utf8")
            @Expect(invalidFetch.ok, true)
            let invalidExtract = gatewayWebExtractText(invalidFetch, "text", 100)
            @Expect(invalidExtract.ok, false)
            @Expect(invalidExtract.code, "invalid_response_encoding")
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(200, bodyBytes: "abcdef".toArray(), contentType: "text/plain")
        }))
        try {
            let tooLarge = gatewayWebFetchRuntimeFetch("https://example.com/too-large", maxBytes: 4)
            @Expect(tooLarge.ok, false)
            @Expect(tooLarge.code, "web_fetch_response_too_large")
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(
                200,
                bodyBytes: "新闻🙂新闻🙂新闻🙂新闻🙂新闻🙂新闻🙂".toArray(),
                contentType: "text/plain; charset=utf-8"
            )
        }))
        try {
            let fetch = gatewayWebFetchRuntimeFetch("https://example.com/unicode")
            let extracted = gatewayWebExtractText(fetch, "text", 17)
            @Expect(extracted.ok, true)
            @Expect(extracted.text.contains("🙂"), true)
            @Expect(extracted.text.contains("[TRUNCATED]"), true)
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }
    }

    @TestCase
    public func m3p1FakeHtmlFetchExtractReturnsHumanReadableText(): Unit {
        // M3-P1
        let html = "<html><head><title>M3 新闻 🙂</title><style>.x{color:red}</style><script>hiddenToken()</script></head>" +
            "<body><h1>今日新闻</h1><p>正文包含中文和 emoji 🙂。</p></body></html>"
        setGatewayWebFetchHttpRunnerForTest(Some({ request: GatewayWebFetchHttpRequest =>
            @Expect(request.url, "https://example.com/news")
            GatewayWebFetchHttpResponse(200, bodyBytes: html.toArray(), contentType: "text/html; charset=utf-8")
        }))
        try {
            let fetch = gatewayWebFetchRuntimeFetch("https://example.com/news")
            @Expect(fetch.ok, true)
            @Expect(fetch.status, "ok")
            @Expect(fetch.statusCode, 200)
            @Expect(fetch.contentType.contains("text/html"), true)

            let extracted = gatewayWebExtractText(fetch, "text", 2000)
            @Expect(extracted.ok, true)
            @Expect(extracted.title, "M3 新闻 🙂")
            @Expect(extracted.text.contains("今日新闻"), true)
            @Expect(extracted.text.contains("正文包含中文和 emoji 🙂。"), true)
            @Expect(extracted.text.contains("hiddenToken"), false)
            @Expect(extracted.text.contains("color:red"), false)
            @Expect(extracted.wrappedText.contains("---BEGIN WEB CONTENT---"), true)
            @Expect(extracted.wrappedText.contains("Source: https://example.com/"), true)

            let rendered = gatewayWebRenderExtractResult(extracted)
            @Expect(rendered.contains("Status: ok"), true)
            @Expect(rendered.contains("\"ok\""), false)
            @Expect(rendered.contains("\"result\""), false)
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }
    }

    @TestCase
    public func m3n1NegativeFetchCasesReturnStableRedactedDiagnostics(): Unit {
        // M3-N1
        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(302, contentType: "text/html", location: "https://example.com/redirect")
        }))
        try {
            let redirectLimit = gatewayWebFetchRuntimeFetch("https://example.com/start", maxRedirects: 0)
            @Expect(redirectLimit.ok, false)
            @Expect(redirectLimit.code, "web_fetch_redirect_limit")
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(500, bodyBytes: "server error".toArray(), contentType: "text/html")
        }))
        try {
            let httpError = gatewayWebFetchRuntimeFetch("https://example.com/500")
            @Expect(httpError.ok, false)
            @Expect(httpError.code, "web_fetch_http_error")
            @Expect(httpError.statusCode, 500)
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(0, error: "connect failed Authorization: Bearer never token=never")
        }))
        try {
            let networkError = gatewayWebFetchRuntimeFetch("https://example.com/network")
            @Expect(networkError.ok, false)
            @Expect(networkError.code, "web_fetch_network_error")
            @Expect(networkError.message.contains("Authorization"), false)
            @Expect(networkError.message.contains("never"), false)
            @Expect(networkError.message.contains("token="), false)
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(0, error: "timeout while reading")
        }))
        try {
            let timeout = gatewayWebFetchRuntimeFetch("https://example.com/timeout")
            @Expect(timeout.ok, false)
            @Expect(timeout.code, "web_fetch_timeout")
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(200, bodyBytes: [137u8, 80u8, 78u8, 71u8], contentType: "image/png")
        }))
        try {
            let unsupported = gatewayWebFetchRuntimeFetch("https://example.com/image")
            @Expect(unsupported.ok, false)
            @Expect(unsupported.code, "web_fetch_unsupported_content_type")
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }

        setGatewayWebFetchHttpRunnerForTest(Some({ _request: GatewayWebFetchHttpRequest =>
            GatewayWebFetchHttpResponse(200, bodyBytes: [], contentType: "text/plain")
        }))
        try {
            let empty = gatewayWebFetchRuntimeFetch("https://example.com/empty")
            @Expect(empty.ok, false)
            @Expect(empty.code, "web_fetch_empty_body")
        } finally {
            setGatewayWebFetchHttpRunnerForTest(None<(GatewayWebFetchHttpRequest) -> GatewayWebFetchHttpResponse>)
        }
    }
}
