package metis.core.tools

import metis.core.{TavilySearchClient, TavilySearchHttpRequest, TavilySearchHttpResponse, setTavilySearchHttpRunnerForTest}
import metis.core.config.{CliConfig, MetisConfigManager, MetisProcessEnvironmentLock}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func withTavilyToolTempHome<T>(label: String, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        let oldKey = getVariable("TAVILY_API_KEY")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        try {
            return block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            match (oldKey) {
                case Some(value) => setVariable("TAVILY_API_KEY", value)
                case None => setVariable("TAVILY_API_KEY", "")
            }
            setTavilySearchHttpRunnerForTest(None<(TavilySearchHttpRequest) -> TavilySearchHttpResponse>)
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class TavilyToolTest {
    @TestCase
    public func emptyQueryFailsClosedBeforeAnyNetworkCall(): Unit {
        withTavilyToolTempHome("metis-tavily-empty-query", { =>
            setVariable("TAVILY_API_KEY", "test-key")
            var calls: Int64 = 0
            setTavilySearchHttpRunnerForTest(Some({ _request: TavilySearchHttpRequest =>
                calls += 1
                TavilySearchHttpResponse(200, body: "{}")
            }))
            let tool = TavilyTool()
            @Expect(tool.search(""), "Search query cannot be empty")
            @Expect(calls, 0)
        })
    }

    @TestCase
    public func missingApiKeyReportsCanonicalMetisConfigPath(): Unit {
        withTavilyToolTempHome("metis-tavily-missing-key", { =>
            setVariable("TAVILY_API_KEY", "")
            try {
                let _ = TavilyTool()
                @Assert(false)
            } catch (e: Exception) {
                @Expect(e.message.contains("tools.search.tavily.apiKey"), true)
                @Expect(e.message.contains("TAVILY_API_KEY"), true)
            }
        })
    }

    @TestCase
    public func m1u1FakeTavilySuccessKeepsLegacyRenderedFormat(): Unit {
        withTavilyToolTempHome("metis-tavily-fake-success", { =>
            setVariable("TAVILY_API_KEY", "test-key")
            setTavilySearchHttpRunnerForTest(Some({ request: TavilySearchHttpRequest =>
                @Expect(request.url, "https://api.tavily.com/search")
                @Expect(request.body.get("query").getOrThrow().asString().getValue(), "latest Cangjie news")
                @Expect(request.headers.get("Authorization").getOrThrow().startsWith("Bearer "), true)
                TavilySearchHttpResponse(
                    200,
                    body: "{\"query\":\"latest Cangjie news\",\"answer\":\"summary ok\",\"response_time\":0.25,\"results\":[{\"title\":\"Result A\",\"url\":\"https://example.com/a\",\"content\":\"content A\",\"score\":0.9}]}"
                )
            }))
            let out = TavilyTool().search("latest Cangjie news")
            @Expect(out.contains("=== Tavily Search Results ==="), true)
            @Expect(out.contains("Query: latest Cangjie news"), true)
            @Expect(out.contains("[AI Summary Answer]"), true)
            @Expect(out.contains("summary ok"), true)
            @Expect(out.contains("1. Result A"), true)
            @Expect(out.contains("URL: https://example.com/a"), true)
            @Expect(out.contains("Content: content A"), true)
        })
    }

    @TestCase
    public func m1b1BoundaryQueriesDoNotBreakUtf8OrRunnerPayload(): Unit {
        withTavilyToolTempHome("metis-tavily-boundary-query", { =>
            setVariable("TAVILY_API_KEY", "test-key")
            let unicodeQuery = "仓颉 新闻 🙂"
            setTavilySearchHttpRunnerForTest(Some({ request: TavilySearchHttpRequest =>
                @Expect(request.body.get("query").getOrThrow().asString().getValue(), unicodeQuery)
                TavilySearchHttpResponse(
                    200,
                    body: "{\"query\":\"仓颉 新闻 🙂\",\"answer\":null,\"response_time\":1,\"results\":[{\"title\":\"中文🙂\",\"url\":\"https://example.com/cj\",\"content\":\"内容🙂\",\"score\":1}]}"
                )
            }))
            let out = TavilyTool().search(unicodeQuery)
            @Expect(out.contains("中文🙂"), true)
            @Expect(out.contains("内容🙂"), true)
        })
    }

    @TestCase
    public func m1p1ClientParsesTavilyResultFields(): Unit {
        withTavilyToolTempHome("metis-tavily-client-parse", { =>
            let client = TavilySearchClient("test-key")
            setTavilySearchHttpRunnerForTest(Some({ _request: TavilySearchHttpRequest =>
                TavilySearchHttpResponse(
                    200,
                    body: "{\"query\":\"q\",\"answer\":\"a\",\"response_time\":2.5,\"results\":[{\"title\":\"T\",\"url\":\"https://example.com\",\"content\":\"C\",\"score\":0.7}]}"
                )
            }))
            let response = client.search("q")
            @Expect(response.query, "q")
            @Expect(response.answer.getOrThrow(), "a")
            @Expect(response.responseTime, 2.5)
            @Expect(response.results.size, 1)
            @Expect(response.results[0].title, "T")
            @Expect(response.results[0].url, "https://example.com")
            @Expect(response.results[0].content, "C")
            @Expect(response.results[0].score, 0.7)
        })
    }

    @TestCase
    public func m1n1FailuresAreStableAndDoNotLeakSecrets(): Unit {
        withTavilyToolTempHome("metis-tavily-negative", { =>
            setVariable("TAVILY_API_KEY", "secret-test-key")
            setTavilySearchHttpRunnerForTest(Some({ _request: TavilySearchHttpRequest =>
                TavilySearchHttpResponse(500, body: "{\"error\":\"bad\"}")
            }))
            let httpOut = TavilyTool().search("q")
            @Expect(httpOut.contains("Search failed: HTTP status 500"), true)
            @Expect(httpOut.contains("secret-test-key"), false)

            setTavilySearchHttpRunnerForTest(Some({ _request: TavilySearchHttpRequest =>
                TavilySearchHttpResponse(200, body: "{bad json")
            }))
            let jsonOut = TavilyTool().search("q")
            @Expect(jsonOut.contains("Search failed: JSON parsing failed"), true)
            @Expect(jsonOut.contains("secret-test-key"), false)

            setTavilySearchHttpRunnerForTest(Some({ _request: TavilySearchHttpRequest =>
                TavilySearchHttpResponse(0, error: "network unavailable Authorization: Bearer secret-test-key")
            }))
            let networkOut = TavilySearchClient("secret-test-key").searchAndRender("q")
            @Expect(networkOut.contains("Search failed:"), true)
            @Expect(networkOut.contains("secret-test-key"), false)
            @Expect(networkOut.contains("Authorization"), false)
        })
    }
}
