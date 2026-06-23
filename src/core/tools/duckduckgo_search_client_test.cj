package metis.core.tools

import metis.core.{DuckDuckGoSearchClient, DuckDuckGoSearchHttpRequest, DuckDuckGoSearchHttpResponse, setDuckDuckGoSearchHttpRunnerForTest}

import std.unittest.testmacro.*

@Test
public class DuckDuckGoSearchClientTest {
    @TestCase
    public func parsesDuckDuckGoHtmlResultsAndDecodesRedirectUrls(): Unit {
        setDuckDuckGoSearchHttpRunnerForTest(Some({ request: DuckDuckGoSearchHttpRequest =>
            @Expect(request.url.contains("q=Cangjie+%E6%96%B0%E9%97%BB"), true)
            let html =
                "<html><body>" +
                "<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x\">Cangjie &amp; News</a>" +
                "<a class=\"result__snippet\">First <b>snippet</b> with 中文🙂.</a>" +
                "<a class=\"result__a\" href=\"https://example.com/b\">Second Result</a>" +
                "<div class=\"result__snippet\">Second snippet</div>" +
                "</body></html>"
            DuckDuckGoSearchHttpResponse(200, bodyBytes: html.toArray())
        }))
        try {
            let response = DuckDuckGoSearchClient().search("Cangjie 新闻", limit: 2)

            @Expect(response.query, "Cangjie 新闻")
            @Expect(response.results.size, 2)
            @Expect(response.results[0].title, "Cangjie & News")
            @Expect(response.results[0].url, "https://example.com/a")
            @Expect(response.results[0].snippet.contains("中文🙂"), true)
            @Expect(response.results[1].url, "https://example.com/b")
        } finally {
            setDuckDuckGoSearchHttpRunnerForTest(None<(DuckDuckGoSearchHttpRequest) -> DuckDuckGoSearchHttpResponse>)
        }
    }

    @TestCase
    public func challengePageReturnsExplicitProviderChallengeDiagnostic(): Unit {
        setDuckDuckGoSearchHttpRunnerForTest(Some({ _request: DuckDuckGoSearchHttpRequest =>
            DuckDuckGoSearchHttpResponse(200, bodyBytes: "<html>captcha challenge verify you are a human</html>".toArray())
        }))
        try {
            try {
                let _ = DuckDuckGoSearchClient().search("today news")
                @Assert(false)
            } catch (e: Exception) {
                @Expect(e.message.contains("web_search_provider_challenge"), true)
            }
        } finally {
            setDuckDuckGoSearchHttpRunnerForTest(None<(DuckDuckGoSearchHttpRequest) -> DuckDuckGoSearchHttpResponse>)
        }
    }
}
